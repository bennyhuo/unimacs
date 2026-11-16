// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import CryptoKit

enum AutoUnlockWireKey {
    static let requestId = "requestId"
    static let keyId = "keyId"
    static let pubKey = "pubKey"
    static let nonce = "nonce"
    static let hmac = "hmac"
    static let success = "success"
    static let alreadyUnlocked = "alreadyUnlocked"
    static let keyMismatch = "keyMismatch"
    static let reason = "reason"
}

enum AutoUnlockLogLevel {
    case info
    case success
    case warning
    case error
}

enum AutoUnlockLogAction {
    case openAutoUnlockSettings
    case openAccessibilitySettings
}

@MainActor
protocol AutoUnlockCoordinatorDelegate: AnyObject {
    var localHostId: String { get }
    func isLocalScreenLocked() -> Bool
    func isAutoUnlockEnabled() -> Bool
    func isAccessibilityTrusted() -> Bool
    func isPeerTrustedAndPaired(_ hostId: String) -> Bool
    func isAutoUnlockAllowedFromPeer(_ hostId: String) -> Bool
    func isHostConnected(_ hostId: String) -> Bool
    func peerDisplayName(_ hostId: String) -> String
    func sendAutoUnlockMessage(_ type: MsgType, infoDict: [AnyHashable: Any], to hostId: String)
    func requestWakeAndReconnect(to hostId: String)
    func verifyLocalPassword(_ password: String, completion: @escaping @MainActor @Sendable (PasswordVerificationResult) -> Void)
    func performScreenUnlock(password: String, completion: @escaping @MainActor @Sendable (ScreenUnlockOutcome) -> Void)
    func cancelActiveScreenUnlock()
    func logAutoUnlockEvent(
        level: AutoUnlockLogLevel,
        title: String,
        detail: String?,
        howToFix: String?,
        hostId: String?,
        action: AutoUnlockLogAction?
    )
}

/// Pure, deterministic protocol coordinator for key exchange, challenge-response
/// authentication, circuit breaker, loop suppression, and pending unlock intents.
@MainActor
final class AutoUnlockProtocolCoordinator {

    static let maxConsecutiveFailures = 2
    static let challengeTTL: TimeInterval = 10.0
    static let unlockIntentTTL: TimeInterval = 15.0
    static let keyExchangeTTL: TimeInterval = 10.0
    static let loopSuppressionCooldown: TimeInterval = 10.0
    static let maxActiveChallenges = 16

    private struct PendingKeyExchange {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let createdAt: TimeInterval
    }

    private struct OutboundUnlockRequest {
        let requestId: String
        let targetHostId: String
        let keyId: String
        let createdAt: TimeInterval
    }

    private struct ActiveChallenge {
        let requestId: String
        let requesterHostId: String
        let nonce: Data
        let createdAt: TimeInterval
        let expiresAt: TimeInterval
    }

    private struct PendingUnlockIntent {
        let hostId: String
        let expiresAt: TimeInterval
    }

    weak var delegate: AutoUnlockCoordinatorDelegate?
    let credentialStore: UnlockCredentialStore
    private let clock: () -> TimeInterval

    private var pendingKeyExchanges: [String: PendingKeyExchange] = [:]
    private var outboundRequests: [String: OutboundUnlockRequest] = [:]
    private var activeChallenges: [String: ActiveChallenge] = [:]
    private var pendingUnlockIntents: [String: PendingUnlockIntent] = [:]

    private(set) var consecutiveFailures: Int = 0
    private(set) var isPerformingInboundUnlock: Bool = false
    private var activeInboundAttemptId: UUID?
    private(set) var lastRemoteTriggeredUnlockAt: TimeInterval = Date.distantPast.timeIntervalSinceReferenceDate

    init(
        credentialStore: UnlockCredentialStore,
        clock: @escaping () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }
    ) {
        self.credentialStore = credentialStore
        self.clock = clock
    }

    // MARK: - State Inspection & Circuit Breaker

    func resetFailureCircuitBreaker() {
        consecutiveFailures = 0
    }

    func hasPendingUnlockIntent(for hostId: String) -> Bool {
        guard let intent = pendingUnlockIntents[hostId] else { return false }
        if clock() > intent.expiresAt {
            pendingUnlockIntents.removeValue(forKey: hostId)
            return false
        }
        return true
    }

    func removePeerState(for hostId: String) {
        credentialStore.removePeerSecret(for: hostId)
        pendingKeyExchanges.removeValue(forKey: hostId)
        pendingUnlockIntents.removeValue(forKey: hostId)
        outboundRequests = outboundRequests.filter { $0.value.targetHostId != hostId }
        activeChallenges = activeChallenges.filter { $0.value.requesterHostId != hostId }
    }

    func cancelActiveInboundUnlock(reason: String) {
        guard isPerformingInboundUnlock else { return }
        activeInboundAttemptId = nil
        isPerformingInboundUnlock = false
        delegate?.cancelActiveScreenUnlock()
        delegate?.logAutoUnlockEvent(
            level: .info,
            title: "Cancelled incoming auto-unlock",
            detail: "Reason: \(reason).",
            howToFix: nil,
            hostId: nil,
            action: nil
        )
    }

    func cancelAllPendingOperations(reason: String) {
        pendingKeyExchanges.removeAll()
        outboundRequests.removeAll()
        activeChallenges.removeAll()
        pendingUnlockIntents.removeAll()
        cancelActiveInboundUnlock(reason: reason)
    }

    // MARK: - Lifecycle Events

    func handleLocalScreenLocked() {
        pendingKeyExchanges.removeAll()
        outboundRequests.removeAll()
        pendingUnlockIntents.removeAll()
    }

    func handleLocalScreenUnlocked(
        wasPreviouslyLocked: Bool,
        connectedEligibleHostIds: [String],
        disconnectedEligibleHostIds: [String]
    ) {
        guard let delegate = delegate else { return }

        // A manual local unlock always clears the failure circuit breaker.
        consecutiveFailures = 0

        let now = clock()
        let inLoopCooldown = isPerformingInboundUnlock || (now - lastRemoteTriggeredUnlockAt) < Self.loopSuppressionCooldown

        for hostId in connectedEligibleHostIds {
            if !credentialStore.hasPeerSecret(for: hostId) {
                initiateKeyExchange(with: hostId)
            }
        }

        if inLoopCooldown {
            pendingUnlockIntents.removeAll()
            outboundRequests.removeAll()
            return
        }

        guard wasPreviouslyLocked, delegate.isAutoUnlockEnabled(), !delegate.isLocalScreenLocked() else {
            return
        }

        for hostId in connectedEligibleHostIds {
            guard delegate.isPeerTrustedAndPaired(hostId),
                  delegate.isAutoUnlockAllowedFromPeer(hostId),
                  let secret = credentialStore.loadPeerSecret(for: hostId) else {
                continue
            }
            sendAutoUnlockRequest(to: hostId, secret: secret)
        }

        for hostId in disconnectedEligibleHostIds {
            guard delegate.isPeerTrustedAndPaired(hostId),
                  delegate.isAutoUnlockAllowedFromPeer(hostId),
                  credentialStore.hasPeerSecret(for: hostId) else {
                continue
            }
            pendingUnlockIntents[hostId] = PendingUnlockIntent(
                hostId: hostId,
                expiresAt: now + Self.unlockIntentTTL
            )
            delegate.requestWakeAndReconnect(to: hostId)
        }
    }

    func handleConnectionEstablished(to hostId: String, isEligible: Bool) {
        guard let delegate = delegate else { return }
        guard isEligible,
              delegate.isAutoUnlockEnabled(),
              !delegate.isLocalScreenLocked(),
              delegate.isPeerTrustedAndPaired(hostId),
              delegate.isAutoUnlockAllowedFromPeer(hostId) else {
            return
        }

        if !credentialStore.hasPeerSecret(for: hostId) {
            initiateKeyExchange(with: hostId)
        }

        let now = clock()
        if let intent = pendingUnlockIntents.removeValue(forKey: hostId),
           now <= intent.expiresAt,
           !isPerformingInboundUnlock,
           (now - lastRemoteTriggeredUnlockAt) >= Self.loopSuppressionCooldown,
           let secret = credentialStore.loadPeerSecret(for: hostId) {
            sendAutoUnlockRequest(to: hostId, secret: secret)
        }
    }

    // MARK: - Key Exchange

    func initiateKeyExchange(with hostId: String, force: Bool = false) {
        guard let delegate = delegate else { return }
        guard !hostId.isEmpty, hostId != delegate.localHostId else { return }
        guard delegate.isAutoUnlockEnabled() else { return }
        guard !delegate.isLocalScreenLocked() else { return }
        guard delegate.isPeerTrustedAndPaired(hostId) else { return }
        guard delegate.isHostConnected(hostId) else { return }

        if !force && credentialStore.hasPeerSecret(for: hostId) {
            return
        }

        let now = clock()
        pruneExpiredKeyExchanges(now: now)

        if !force, pendingKeyExchanges[hostId] != nil {
            return
        }

        let privateKey = AutoUnlockCrypto.generateKeyPair()
        pendingKeyExchanges[hostId] = PendingKeyExchange(privateKey: privateKey, createdAt: now)

        delegate.sendAutoUnlockMessage(
            .autoUnlockKeyExchangeInit,
            infoDict: [AutoUnlockWireKey.pubKey: Data(privateKey.publicKey.rawRepresentation)],
            to: hostId
        )
    }

    private func handleKeyExchangeInit(from hostId: String, infoDict: [AnyHashable: Any]) {
        guard let delegate = delegate else { return }
        guard delegate.isPeerTrustedAndPaired(hostId) else { return }
        // Never negotiate or mutate peer keys while the local screen is locked.
        guard !delegate.isLocalScreenLocked() else { return }
        guard let peerPubKey = infoDict[AutoUnlockWireKey.pubKey] as? Data,
              peerPubKey.count == AutoUnlockCrypto.expectedKeyLength else {
            return
        }

        let now = clock()
        pruneExpiredKeyExchanges(now: now)

        if pendingKeyExchanges[hostId] != nil {
            if delegate.localHostId < hostId {
                // Deterministic tie-breaker: keep our in-flight initiation; peer will yield and send Ack.
                return
            } else {
                pendingKeyExchanges.removeValue(forKey: hostId)
            }
        }

        let ackPrivateKey = AutoUnlockCrypto.generateKeyPair()
        do {
            let secret = try AutoUnlockCrypto.derivePeerSecret(
                privateKey: ackPrivateKey,
                peerPublicKeyBytes: peerPubKey,
                localHostId: delegate.localHostId,
                remoteHostId: hostId
            )
            try credentialStore.savePeerSecret(secret, for: hostId)
            let keyId = AutoUnlockCrypto.keyId(for: secret)
            delegate.sendAutoUnlockMessage(
                .autoUnlockKeyExchangeAck,
                infoDict: [
                    AutoUnlockWireKey.pubKey: Data(ackPrivateKey.publicKey.rawRepresentation),
                    AutoUnlockWireKey.keyId: keyId
                ],
                to: hostId
            )
        } catch {
            delegate.logAutoUnlockEvent(
                level: .warning,
                title: "Auto-unlock key exchange failed with \(delegate.peerDisplayName(hostId))",
                detail: error.localizedDescription,
                howToFix: nil,
                hostId: hostId,
                action: nil
            )
        }
    }

    private func handleKeyExchangeAck(from hostId: String, infoDict: [AnyHashable: Any]) {
        guard let delegate = delegate else { return }
        guard delegate.isPeerTrustedAndPaired(hostId) else { return }
        guard !delegate.isLocalScreenLocked() else { return }

        let now = clock()
        guard let pending = pendingKeyExchanges.removeValue(forKey: hostId),
              now - pending.createdAt <= Self.keyExchangeTTL else {
            return
        }

        guard let peerPubKey = infoDict[AutoUnlockWireKey.pubKey] as? Data,
              peerPubKey.count == AutoUnlockCrypto.expectedKeyLength else {
            return
        }

        do {
            let secret = try AutoUnlockCrypto.derivePeerSecret(
                privateKey: pending.privateKey,
                peerPublicKeyBytes: peerPubKey,
                localHostId: delegate.localHostId,
                remoteHostId: hostId
            )
            let derivedKeyId = AutoUnlockCrypto.keyId(for: secret)
            if let remoteKeyId = infoDict[AutoUnlockWireKey.keyId] as? String,
               remoteKeyId != derivedKeyId {
                delegate.logAutoUnlockEvent(
                    level: .warning,
                    title: "Auto-unlock key verification mismatch with \(delegate.peerDisplayName(hostId))",
                    detail: "Derived key identifier did not match peer acknowledgment.",
                    howToFix: nil,
                    hostId: hostId,
                    action: nil
                )
                return
            }
            try credentialStore.savePeerSecret(secret, for: hostId)
        } catch {
            delegate.logAutoUnlockEvent(
                level: .warning,
                title: "Auto-unlock key exchange failed with \(delegate.peerDisplayName(hostId))",
                detail: error.localizedDescription,
                howToFix: nil,
                hostId: hostId,
                action: nil
            )
        }
    }

    // MARK: - Message Dispatch

    @discardableResult
    func handleMessage(_ type: MsgType, infoDict: [AnyHashable: Any], from hostId: String) -> Bool {
        switch type {
        case .autoUnlockKeyExchangeInit:
            handleKeyExchangeInit(from: hostId, infoDict: infoDict)
            return true
        case .autoUnlockKeyExchangeAck:
            handleKeyExchangeAck(from: hostId, infoDict: infoDict)
            return true
        case .autoUnlockRequest:
            handleAutoUnlockRequest(from: hostId, infoDict: infoDict)
            return true
        case .autoUnlockChallenge:
            handleAutoUnlockChallenge(from: hostId, infoDict: infoDict)
            return true
        case .autoUnlockResponse:
            handleAutoUnlockResponse(from: hostId, infoDict: infoDict)
            return true
        case .autoUnlockResult:
            handleAutoUnlockResult(from: hostId, infoDict: infoDict)
            return true
        default:
            return false
        }
    }

    // MARK: - Unlock Handshake (Requester & Target)

    private func sendAutoUnlockRequest(to hostId: String, secret: Data) {
        guard let delegate = delegate else { return }
        let now = clock()
        pruneExpiredOutboundRequests(now: now)

        let requestId = UUID().uuidString
        let keyId = AutoUnlockCrypto.keyId(for: secret)
        outboundRequests[requestId] = OutboundUnlockRequest(
            requestId: requestId,
            targetHostId: hostId,
            keyId: keyId,
            createdAt: now
        )

        delegate.sendAutoUnlockMessage(
            .autoUnlockRequest,
            infoDict: [
                AutoUnlockWireKey.requestId: requestId,
                AutoUnlockWireKey.keyId: keyId
            ],
            to: hostId
        )
    }

    private func handleAutoUnlockRequest(from hostId: String, infoDict: [AnyHashable: Any]) {
        guard let delegate = delegate else { return }
        guard delegate.isPeerTrustedAndPaired(hostId) else { return }
        guard let requestId = infoDict[AutoUnlockWireKey.requestId] as? String, !requestId.isEmpty,
              let peerKeyId = infoDict[AutoUnlockWireKey.keyId] as? String, !peerKeyId.isEmpty else {
            return
        }

        let peerName = delegate.peerDisplayName(hostId)

        guard delegate.isAutoUnlockEnabled(), delegate.isAutoUnlockAllowedFromPeer(hostId) else {
            sendResult(requestId: requestId, success: false, reason: "Auto-unlock is disabled on \(delegate.localHostId).", to: hostId)
            return
        }

        guard delegate.isLocalScreenLocked() else {
            sendResult(requestId: requestId, success: false, alreadyUnlocked: true, reason: "Screen is already unlocked.", to: hostId)
            return
        }

        guard consecutiveFailures < Self.maxConsecutiveFailures else {
            let reason = "Auto-unlock paused after \(Self.maxConsecutiveFailures) consecutive failed attempts. Unlock this Mac manually to reset."
            sendResult(requestId: requestId, success: false, reason: reason, to: hostId)
            delegate.logAutoUnlockEvent(
                level: .warning,
                title: "Auto-unlock paused on \(delegate.localHostId)",
                detail: reason,
                howToFix: "Unlock \(delegate.localHostId) manually and verify the saved login password in Settings → Security.",
                hostId: hostId,
                action: .openAutoUnlockSettings
            )
            return
        }

        guard credentialStore.hasSavedPassword, !credentialStore.isPasswordInvalid else {
            let reason = credentialStore.isPasswordInvalid
                ? "Saved login password needs to be updated on \(delegate.localHostId)."
                : "No login password is saved on \(delegate.localHostId)."
            sendResult(requestId: requestId, success: false, reason: reason, to: hostId)
            delegate.logAutoUnlockEvent(
                level: .warning,
                title: "Cannot auto-unlock from \(peerName)",
                detail: reason,
                howToFix: "Open Settings → Security on \(delegate.localHostId) and save your current macOS login password.",
                hostId: hostId,
                action: .openAutoUnlockSettings
            )
            return
        }

        guard delegate.isAccessibilityTrusted() else {
            let reason = "Accessibility permission is required on \(delegate.localHostId) to type the unlock password."
            sendResult(requestId: requestId, success: false, reason: reason, to: hostId)
            delegate.logAutoUnlockEvent(
                level: .error,
                title: "Cannot auto-unlock from \(peerName) — Accessibility not granted",
                detail: reason,
                howToFix: "Grant Accessibility permission to Unimacs in System Settings → Privacy & Security → Accessibility.",
                hostId: hostId,
                action: .openAccessibilitySettings
            )
            return
        }

        guard !isPerformingInboundUnlock else {
            sendResult(requestId: requestId, success: false, reason: "An auto-unlock attempt is already in progress.", to: hostId)
            return
        }

        guard let secret = credentialStore.loadPeerSecret(for: hostId),
              AutoUnlockCrypto.keyId(for: secret) == peerKeyId else {
            sendResult(
                requestId: requestId,
                success: false,
                keyMismatch: true,
                reason: "Auto-unlock peer key mismatch. Re-sync keys while both Macs are unlocked.",
                to: hostId
            )
            return
        }

        let now = clock()
        pruneExpiredChallenges(now: now)
        if activeChallenges.count >= Self.maxActiveChallenges,
           let oldestKey = activeChallenges.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            activeChallenges.removeValue(forKey: oldestKey)
        }

        do {
            let nonce = try AutoUnlockCrypto.generateNonce(byteCount: 32)
            activeChallenges[requestId] = ActiveChallenge(
                requestId: requestId,
                requesterHostId: hostId,
                nonce: nonce,
                createdAt: now,
                expiresAt: now + Self.challengeTTL
            )
            delegate.sendAutoUnlockMessage(
                .autoUnlockChallenge,
                infoDict: [
                    AutoUnlockWireKey.requestId: requestId,
                    AutoUnlockWireKey.nonce: nonce
                ],
                to: hostId
            )
        } catch {
            sendResult(requestId: requestId, success: false, reason: error.localizedDescription, to: hostId)
        }
    }

    private func handleAutoUnlockChallenge(from hostId: String, infoDict: [AnyHashable: Any]) {
        guard let delegate = delegate else { return }
        guard let requestId = infoDict[AutoUnlockWireKey.requestId] as? String, !requestId.isEmpty,
              let nonce = infoDict[AutoUnlockWireKey.nonce] as? Data, nonce.count >= 16 else {
            return
        }

        let now = clock()
        guard let pendingReq = outboundRequests.removeValue(forKey: requestId),
              pendingReq.targetHostId == hostId,
              now <= pendingReq.createdAt + Self.unlockIntentTTL else {
            return
        }

        guard !delegate.isLocalScreenLocked(),
              delegate.isAutoUnlockEnabled(),
              delegate.isPeerTrustedAndPaired(hostId),
              delegate.isAutoUnlockAllowedFromPeer(hostId) else {
            return
        }

        guard let secret = credentialStore.loadPeerSecret(for: hostId),
              AutoUnlockCrypto.keyId(for: secret) == pendingReq.keyId else {
            return
        }

        do {
            let hmac = try AutoUnlockCrypto.computeChallengeHMAC(
                secret: secret,
                requestId: requestId,
                nonce: nonce,
                requesterHostId: delegate.localHostId,
                targetHostId: hostId
            )
            delegate.sendAutoUnlockMessage(
                .autoUnlockResponse,
                infoDict: [
                    AutoUnlockWireKey.requestId: requestId,
                    AutoUnlockWireKey.hmac: hmac
                ],
                to: hostId
            )
        } catch {
            delegate.logAutoUnlockEvent(
                level: .warning,
                title: "Failed to sign auto-unlock challenge for \(delegate.peerDisplayName(hostId))",
                detail: error.localizedDescription,
                howToFix: nil,
                hostId: hostId,
                action: nil
            )
        }
    }

    private func handleAutoUnlockResponse(from hostId: String, infoDict: [AnyHashable: Any]) {
        guard let delegate = delegate else { return }
        guard let requestId = infoDict[AutoUnlockWireKey.requestId] as? String, !requestId.isEmpty,
              let hmac = infoDict[AutoUnlockWireKey.hmac] as? Data else {
            return
        }

        // Single-use nonce: always remove immediately upon lookup.
        guard let challenge = activeChallenges.removeValue(forKey: requestId) else {
            sendResult(requestId: requestId, success: false, reason: "Unknown or already used auto-unlock challenge.", to: hostId)
            return
        }

        guard challenge.requesterHostId == hostId else {
            sendResult(requestId: requestId, success: false, reason: "Auto-unlock challenge requester mismatch.", to: hostId)
            return
        }

        let now = clock()
        guard now <= challenge.expiresAt else {
            sendResult(requestId: requestId, success: false, reason: "Auto-unlock challenge expired.", to: hostId)
            return
        }

        guard delegate.isPeerTrustedAndPaired(hostId),
              delegate.isAutoUnlockEnabled(),
              delegate.isAutoUnlockAllowedFromPeer(hostId) else {
            sendResult(requestId: requestId, success: false, reason: "Auto-unlock is disabled or host is not trusted.", to: hostId)
            return
        }

        guard consecutiveFailures < Self.maxConsecutiveFailures else {
            sendResult(requestId: requestId, success: false, reason: "Auto-unlock paused after consecutive failures.", to: hostId)
            return
        }

        guard delegate.isAccessibilityTrusted() else {
            sendResult(requestId: requestId, success: false, reason: "Accessibility permission is required.", to: hostId)
            return
        }

        guard delegate.isLocalScreenLocked() else {
            sendResult(requestId: requestId, success: false, alreadyUnlocked: true, reason: "Screen is already unlocked.", to: hostId)
            return
        }

        guard let secret = credentialStore.loadPeerSecret(for: hostId),
              AutoUnlockCrypto.verifyChallengeHMAC(
                  hmac,
                  secret: secret,
                  requestId: requestId,
                  nonce: challenge.nonce,
                  requesterHostId: hostId,
                  targetHostId: delegate.localHostId
              ) else {
            let peerName = delegate.peerDisplayName(hostId)
            sendResult(requestId: requestId, success: false, reason: "Challenge HMAC verification failed.", to: hostId)
            delegate.logAutoUnlockEvent(
                level: .warning,
                title: "Rejected unauthenticated unlock attempt from \(peerName)",
                detail: "Challenge HMAC signature did not match the shared peer secret.",
                howToFix: nil,
                hostId: hostId,
                action: nil
            )
            return
        }

        guard !isPerformingInboundUnlock else {
            sendResult(requestId: requestId, success: false, reason: "An auto-unlock attempt is already in progress.", to: hostId)
            return
        }

        guard !credentialStore.isPasswordInvalid,
              let password = try? credentialStore.loadPassword(),
              !password.isEmpty else {
            sendResult(requestId: requestId, success: false, reason: "No valid saved login password available.", to: hostId)
            delegate.logAutoUnlockEvent(
                level: .warning,
                title: "Cannot auto-unlock — missing or invalid saved password",
                detail: "Update your macOS login password in Settings → Security.",
                howToFix: "Open Settings → Security and re-enter your macOS login password.",
                hostId: hostId,
                action: .openAutoUnlockSettings
            )
            return
        }

        let attemptId = UUID()
        isPerformingInboundUnlock = true
        activeInboundAttemptId = attemptId

        delegate.verifyLocalPassword(password) { [weak self] verificationResult in
            guard let self = self, let delegate = self.delegate else { return }

            guard self.activeInboundAttemptId == attemptId, self.isPerformingInboundUnlock else {
                self.sendResult(requestId: requestId, success: false, reason: "Auto-unlock was cancelled.", to: hostId)
                return
            }

            switch verificationResult {
            case .invalidCredentials:
                self.activeInboundAttemptId = nil
                self.isPerformingInboundUnlock = false
                self.credentialStore.markPasswordInvalid()
                self.consecutiveFailures += 1
                let reason = "Saved password no longer matches the local macOS account password."
                self.sendResult(requestId: requestId, success: false, reason: reason, to: hostId)
                delegate.logAutoUnlockEvent(
                    level: .error,
                    title: "Auto-unlock aborted — saved password is incorrect",
                    detail: "Local password verification failed before typing, so no keystrokes were entered on the Lock Screen.",
                    howToFix: "Open Settings → Security and update your saved macOS login password.",
                    hostId: hostId,
                    action: .openAutoUnlockSettings
                )
                return

            case .unavailable(let message):
                self.activeInboundAttemptId = nil
                self.isPerformingInboundUnlock = false
                let reason = "Unable to verify local password before unlock: \(message)"
                self.sendResult(requestId: requestId, success: false, reason: reason, to: hostId)
                delegate.logAutoUnlockEvent(
                    level: .warning,
                    title: "Auto-unlock skipped — password check unavailable",
                    detail: reason,
                    howToFix: nil,
                    hostId: hostId,
                    action: nil
                )
                return

            case .valid:
                break
            }

            guard delegate.isLocalScreenLocked() else {
                self.activeInboundAttemptId = nil
                self.isPerformingInboundUnlock = false
                self.lastRemoteTriggeredUnlockAt = self.clock()
                self.consecutiveFailures = 0
                self.sendResult(requestId: requestId, success: false, alreadyUnlocked: true, reason: "Screen is already unlocked.", to: hostId)
                return
            }

            delegate.performScreenUnlock(password: password) { [weak self] outcome in
                guard let self = self, let delegate = self.delegate else { return }
                if self.activeInboundAttemptId == attemptId {
                    self.activeInboundAttemptId = nil
                    self.isPerformingInboundUnlock = false
                }
                self.handleUnlockOutcome(outcome, requestId: requestId, from: hostId, delegate: delegate)
            }
        }
    }

    private func handleUnlockOutcome(
        _ outcome: ScreenUnlockOutcome,
        requestId: String,
        from hostId: String,
        delegate: AutoUnlockCoordinatorDelegate
    ) {
        let peerName = delegate.peerDisplayName(hostId)
        switch outcome {
        case .unlocked:
            lastRemoteTriggeredUnlockAt = clock()
            consecutiveFailures = 0
            sendResult(requestId: requestId, success: true, reason: nil, to: hostId)
            delegate.logAutoUnlockEvent(
                level: .success,
                title: "Automatically unlocked this Mac from \(peerName)",
                detail: "Verified challenge response and unlocked the local session.",
                howToFix: nil,
                hostId: hostId,
                action: nil
            )

        case .alreadyUnlocked:
            lastRemoteTriggeredUnlockAt = clock()
            consecutiveFailures = 0
            sendResult(requestId: requestId, success: false, alreadyUnlocked: true, reason: "Screen is already unlocked.", to: hostId)

        case .cancelled:
            sendResult(requestId: requestId, success: false, reason: "Auto-unlock cancelled.", to: hostId)

        case .timedOutStillLocked:
            consecutiveFailures += 1
            let reason = "Password was entered, but the screen remained locked."
            sendResult(requestId: requestId, success: false, reason: reason, to: hostId)
            delegate.logAutoUnlockEvent(
                level: .warning,
                title: "Auto-unlock timed out (\(consecutiveFailures)/\(Self.maxConsecutiveFailures))",
                detail: reason,
                howToFix: consecutiveFailures >= Self.maxConsecutiveFailures
                    ? "Auto-unlock has been paused to prevent account lockout. Unlock manually and check your saved password."
                    : "Ensure the password input field on the Lock Screen is active.",
                hostId: hostId,
                action: .openAutoUnlockSettings
            )

        case .failed(let message):
            consecutiveFailures += 1
            sendResult(requestId: requestId, success: false, reason: message, to: hostId)
            delegate.logAutoUnlockEvent(
                level: .error,
                title: "Auto-unlock failed (\(consecutiveFailures)/\(Self.maxConsecutiveFailures))",
                detail: message,
                howToFix: "Check Accessibility permissions and your saved login password in Settings → Security.",
                hostId: hostId,
                action: .openAutoUnlockSettings
            )
        }
    }

    private func handleAutoUnlockResult(from hostId: String, infoDict: [AnyHashable: Any]) {
        guard let delegate = delegate else { return }
        guard delegate.isPeerTrustedAndPaired(hostId) else { return }

        if let requestId = infoDict[AutoUnlockWireKey.requestId] as? String {
            outboundRequests.removeValue(forKey: requestId)
        }
        pendingUnlockIntents.removeValue(forKey: hostId)

        let success = (infoDict[AutoUnlockWireKey.success] as? Bool) ?? false
        let alreadyUnlocked = (infoDict[AutoUnlockWireKey.alreadyUnlocked] as? Bool) ?? false
        let keyMismatch = (infoDict[AutoUnlockWireKey.keyMismatch] as? Bool) ?? false
        let reason = infoDict[AutoUnlockWireKey.reason] as? String
        let peerName = delegate.peerDisplayName(hostId)

        if keyMismatch {
            credentialStore.removePeerSecret(for: hostId)
            if !delegate.isLocalScreenLocked() && delegate.isAutoUnlockEnabled() {
                initiateKeyExchange(with: hostId, force: true)
            }
        }

        if success {
            delegate.logAutoUnlockEvent(
                level: .success,
                title: "Auto-unlocked \(peerName)",
                detail: "Remote Mac \(peerName) unlocked automatically after local unlock.",
                howToFix: nil,
                hostId: hostId,
                action: nil
            )
        } else if !alreadyUnlocked {
            delegate.logAutoUnlockEvent(
                level: .warning,
                title: "Could not auto-unlock \(peerName)",
                detail: reason ?? "Remote Mac declined or could not complete auto-unlock.",
                howToFix: keyMismatch
                    ? "Keep both Macs unlocked and connected for a few seconds to refresh Auto-Unlock keys."
                    : nil,
                hostId: hostId,
                action: nil
            )
        }
    }

    private func sendResult(
        requestId: String,
        success: Bool,
        alreadyUnlocked: Bool = false,
        keyMismatch: Bool = false,
        reason: String?,
        to hostId: String
    ) {
        var info: [AnyHashable: Any] = [
            AutoUnlockWireKey.requestId: requestId,
            AutoUnlockWireKey.success: success,
            AutoUnlockWireKey.alreadyUnlocked: alreadyUnlocked,
            AutoUnlockWireKey.keyMismatch: keyMismatch
        ]
        if let reason = reason, !reason.isEmpty {
            info[AutoUnlockWireKey.reason] = reason
        }
        delegate?.sendAutoUnlockMessage(.autoUnlockResult, infoDict: info, to: hostId)
    }

    // MARK: - Pruning

    private func pruneExpiredKeyExchanges(now: TimeInterval) {
        pendingKeyExchanges = pendingKeyExchanges.filter { now - $0.value.createdAt <= Self.keyExchangeTTL }
    }

    private func pruneExpiredOutboundRequests(now: TimeInterval) {
        outboundRequests = outboundRequests.filter { now - $0.value.createdAt <= Self.unlockIntentTTL }
    }

    private func pruneExpiredChallenges(now: TimeInterval) {
        activeChallenges = activeChallenges.filter { now <= $0.value.expiresAt }
    }
}

#if !STANDALONE_UNIT_TEST

@MainActor
final class AutoUnlockManager: NSObject, DeviceConnectionDelegate, AutoUnlockCoordinatorDelegate {

    static let shared = AutoUnlockManager()

    private let coordinator: AutoUnlockProtocolCoordinator
    private let passwordVerifier: UnlockPasswordVerifying
    private let typingQueue = DispatchQueue(label: "com.unimacs.autounlock.typing", qos: .userInteractive)
    private var activeCancellationToken: ScreenUnlockCancellationToken?
    private var reconnectRetryWorkItems: [String: [DispatchWorkItem]] = [:]

    private override init() {
        self.coordinator = AutoUnlockProtocolCoordinator(credentialStore: UnlockCredentialStore.shared)
        self.passwordVerifier = OpenDirectoryPasswordVerifier()
        super.init()
        self.coordinator.delegate = self
        DeviceConnectionManager.shared.addDelegate(self)
    }

    // MARK: - Public Lifecycle & Settings Hooks

    func handleLocalScreenLocked() {
        cancelReconnectRetryTimers()
        coordinator.handleLocalScreenLocked()
    }

    func handleLocalScreenUnlocked(wasPreviouslyLocked: Bool) {
        let peeredHosts = HostDevicesManager.shared.hosts(with: .peered) as? [RemoteHost] ?? []
        var connectedEligibleIds: [String] = []
        var disconnectedEligibleIds: [String] = []

        for host in peeredHosts {
            guard host.identifier != LocalHost.shared.identifier else { continue }
            guard host.allowAutoUnlock, HostDevicesManager.shared.isPaired(with: host) else { continue }

            if DeviceConnectionManager.shared.isConnected(to: host) {
                if host.hasCapability(.autoUnlock) {
                    connectedEligibleIds.append(host.identifier)
                }
            } else {
                disconnectedEligibleIds.append(host.identifier)
            }
        }

        coordinator.handleLocalScreenUnlocked(
            wasPreviouslyLocked: wasPreviouslyLocked,
            connectedEligibleHostIds: connectedEligibleIds,
            disconnectedEligibleHostIds: disconnectedEligibleIds
        )
    }

    func cancelActiveInboundUnlock(reason: String) {
        coordinator.cancelActiveInboundUnlock(reason: reason)
    }

    func cancelAllPendingOperations(reason: String) {
        cancelReconnectRetryTimers()
        coordinator.cancelAllPendingOperations(reason: reason)
    }

    func removePeerState(forHostId hostId: String) {
        cancelReconnectRetryTimers(for: hostId)
        coordinator.removePeerState(for: hostId)
    }

    func resetFailureCircuitBreaker() {
        coordinator.resetFailureCircuitBreaker()
    }

    func hasPeerKey(forHostId hostId: String) -> Bool {
        UnlockCredentialStore.shared.hasPeerSecret(for: hostId)
    }

    func ensurePeerKeyExchanged(with host: RemoteHost, on connection: NetworkConnection? = nil) {
        guard host.hasCapability(.autoUnlock),
              host.allowAutoUnlock,
              HostDevicesManager.shared.isPaired(with: host) else {
            return
        }
        guard connection?.isConnected ?? DeviceConnectionManager.shared.isConnected(to: host) else {
            return
        }
        coordinator.initiateKeyExchange(with: host.identifier)
    }

    func ensurePeerKeysWithConnectedHosts() {
        let peeredHosts = HostDevicesManager.shared.hosts(with: .peered) as? [RemoteHost] ?? []
        for host in peeredHosts {
            if DeviceConnectionManager.shared.isConnected(to: host) {
                ensurePeerKeyExchanged(with: host)
            }
        }
    }

    // MARK: - DeviceConnectionDelegate

    func connectionDidEstablish(to host: RemoteHost, connection: NetworkConnection) {
        cancelReconnectRetryTimers(for: host.identifier)
        let eligible = host.hasCapability(.autoUnlock)
            && host.allowAutoUnlock
            && HostDevicesManager.shared.isPaired(with: host)
        coordinator.handleConnectionEstablished(to: host.identifier, isEligible: eligible)
    }

    func handleMessage(_ message: Message, from host: RemoteHost, connection: NetworkConnection) -> Bool {
        coordinator.handleMessage(message.msgType, infoDict: message.infoDict, from: host.identifier)
    }

    // MARK: - AutoUnlockCoordinatorDelegate

    var localHostId: String {
        LocalHost.shared.identifier
    }

    func isLocalScreenLocked() -> Bool {
        ScreenUnlocker.isScreenLockedLive()
    }

    func isAutoUnlockEnabled() -> Bool {
        PreferencesManager.shared().bool(forPref: Settings.enableAutoUnlockKey)
    }

    func isAccessibilityTrusted() -> Bool {
        AccessibilityManager.shared.refreshNow()
        return AccessibilityManager.isTrusted
    }

    func isPeerTrustedAndPaired(_ hostId: String) -> Bool {
        guard let host = HostDevicesManager.shared.host(withIdentifier: hostId) else {
            return false
        }
        return HostDevicesManager.shared.isPaired(with: host)
    }

    func isAutoUnlockAllowedFromPeer(_ hostId: String) -> Bool {
        guard let host = HostDevicesManager.shared.host(withIdentifier: hostId) else {
            return false
        }
        return host.allowAutoUnlock
    }

    func isHostConnected(_ hostId: String) -> Bool {
        guard let host = HostDevicesManager.shared.host(withIdentifier: hostId) else {
            return false
        }
        return DeviceConnectionManager.shared.isConnected(to: host)
    }

    func peerDisplayName(_ hostId: String) -> String {
        HostDevicesManager.shared.host(withIdentifier: hostId)?.computerName ?? hostId
    }

    func sendAutoUnlockMessage(_ type: MsgType, infoDict: [AnyHashable: Any], to hostId: String) {
        let message = Message.create(with: type, andInfoDict: infoDict)
        _ = DeviceConnectionManager.shared.sendMessage(message, toHost: hostId)
    }

    func requestWakeAndReconnect(to hostId: String) {
        guard let host = HostDevicesManager.shared.host(withIdentifier: hostId) else { return }

        if !host.macAddresses.isEmpty {
            WakeOnLanSender.sendWakePackets(to: host.macAddresses)
        }
        _ = DeviceConnectionManager.shared.connect(to: host, resetRetryBudget: true, ignoreIdRule: true)

        cancelReconnectRetryTimers(for: hostId)
        var workItems: [DispatchWorkItem] = []
        for delay in [2.5, 6.0] {
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    guard self.coordinator.hasPendingUnlockIntent(for: hostId),
                          !self.isLocalScreenLocked(),
                          let targetHost = HostDevicesManager.shared.host(withIdentifier: hostId),
                          !DeviceConnectionManager.shared.isConnected(to: targetHost) else {
                        return
                    }
                    if !targetHost.macAddresses.isEmpty {
                        WakeOnLanSender.sendWakePackets(to: targetHost.macAddresses)
                    }
                    _ = DeviceConnectionManager.shared.connect(to: targetHost, resetRetryBudget: true, ignoreIdRule: true)
                }
            }
            workItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
        reconnectRetryWorkItems[hostId] = workItems
    }

    func verifyLocalPassword(_ password: String, completion: @escaping @MainActor @Sendable (PasswordVerificationResult) -> Void) {
        let verifier = passwordVerifier
        let username = NSUserName()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = verifier.verify(password: password, username: username)
            Task { @MainActor in
                completion(result)
            }
        }
    }

    func performScreenUnlock(password: String, completion: @escaping @MainActor @Sendable (ScreenUnlockOutcome) -> Void) {
        activeCancellationToken?.cancel()
        let token = ScreenUnlockCancellationToken()
        activeCancellationToken = token

        let keyStrokes = ScreenUnlocker.resolveKeyStrokes(for: password)

        typingQueue.async {
            let outcome = ScreenUnlocker.performUnlock(keyStrokes: keyStrokes, cancellationToken: token)
            Task { @MainActor [weak self] in
                if self?.activeCancellationToken === token {
                    self?.activeCancellationToken = nil
                }
                completion(outcome)
            }
        }
    }

    func cancelActiveScreenUnlock() {
        activeCancellationToken?.cancel()
        activeCancellationToken = nil
    }

    func logAutoUnlockEvent(
        level: AutoUnlockLogLevel,
        title: String,
        detail: String?,
        howToFix: String?,
        hostId: String?,
        action: AutoUnlockLogAction?
    ) {
        let mappedLevel: ActivityLogLevel
        switch level {
        case .info: mappedLevel = .info
        case .success: mappedLevel = .success
        case .warning: mappedLevel = .warning
        case .error: mappedLevel = .error
        }

        let actions: [ActivityFixAction]
        switch action {
        case .openAutoUnlockSettings:
            actions = [.openAutoUnlockSettings]
        case .openAccessibilitySettings:
            actions = [.openAccessibilitySettings]
        case nil:
            actions = []
        }

        let hostName = hostId.map { peerDisplayName($0) }
        ActivityLogManager.shared.log(
            level: mappedLevel,
            category: .control,
            title: title,
            detail: detail,
            howToFix: howToFix,
            hostId: hostId,
            hostName: hostName,
            actions: actions
        )
    }

    // MARK: - Retry Timer Cleanup

    private func cancelReconnectRetryTimers(for hostId: String? = nil) {
        if let hostId = hostId {
            reconnectRetryWorkItems.removeValue(forKey: hostId)?.forEach { $0.cancel() }
        } else {
            for items in reconnectRetryWorkItems.values {
                items.forEach { $0.cancel() }
            }
            reconnectRetryWorkItems.removeAll()
        }
    }
}

#endif
