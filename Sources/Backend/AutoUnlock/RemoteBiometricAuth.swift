// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import CryptoKit

#if !STANDALONE_UNIT_TEST
import Cocoa
import Carbon
import LocalAuthentication
#endif

enum BiometricWireKey {
    static let requestId = "requestId"
    static let keyId = "keyId"
    static let nonce = "nonce"
    static let hmac = "hmac"
    static let promptKind = "promptKind"
    static let manual = "manual"
    static let reason = "reason"
    static let success = "success"
    static let keyMismatch = "keyMismatch"
    static let aborted = "aborted"
}

enum BiometricAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

enum BiometricEvaluationResult: Equatable, Sendable {
    case authenticated
    case userCancelled
    case failed(String)
}

@MainActor
protocol RemoteBiometricAuthCoordinatorDelegate: AnyObject {
    var localHostId: String { get }
    var localDisplayName: String { get }
    func isLocalScreenLocked() -> Bool
    func isRemoteBiometricAuthEnabled() -> Bool
    func hasLocalSavedPassword() -> Bool
    func isAccessibilityTrusted() -> Bool
    func isPeerTrustedAndPaired(_ hostId: String) -> Bool
    func peerSupportsBiometricAuth(_ hostId: String) -> Bool
    func isHostConnected(_ hostId: String) -> Bool
    func isControllingHost(_ hostId: String) -> Bool
    func isBeingControlled(by hostId: String) -> Bool
    func peerDisplayName(_ hostId: String) -> String
    func initiatePeerKeyExchangeIfNeeded(with hostId: String, force: Bool)
    func sendBiometricMessage(_ type: MsgType, infoDict: [AnyHashable: Any], to hostId: String)
    func detectCurrentPasswordPrompt(allowNonSystemPrompts: Bool) -> DetectedPasswordPrompt?
    func isPasswordPromptStillActive(_ kind: PasswordPromptKind) -> Bool
    func biometricAvailability() -> BiometricAvailability
    func prepareControllerForegroundForBiometrics()
    func restoreControllerForegroundAfterBiometrics()
    func evaluateBiometrics(reason: String, completion: @escaping @MainActor @Sendable (BiometricEvaluationResult) -> Void)
    func cancelLocalBiometricEvaluation()
    func verifyLocalPassword(_ password: String, completion: @escaping @MainActor @Sendable (PasswordVerificationResult) -> Void)
    func performPromptAutofill(password: String, promptKind: PasswordPromptKind, completion: @escaping @MainActor @Sendable (PromptAutofillOutcome) -> Void)
    func cancelActivePromptAutofill()
    func showBezelNotification(title: String, subtitle: String, isWarning: Bool)
    func logBiometricEvent(
        level: AutoUnlockLogLevel,
        title: String,
        detail: String?,
        howToFix: String?,
        hostId: String?,
        action: AutoUnlockLogAction?
    )
}

/// Pure, deterministic protocol coordinator for remote Touch ID authentication
/// of password prompts across paired Macs without sending passwords over the wire.
@MainActor
final class RemoteBiometricAuthCoordinator {

    static let maxConsecutiveAutoFailures = 2
    static let challengeTTL: TimeInterval = 30.0
    static let requestTTL: TimeInterval = 10.0
    static let manualAttemptCooldown: TimeInterval = 1.0
    static let maxActiveChallenges = 16

    private struct OutboundManualRequest {
        let requestId: String
        let targetHostId: String
        let keyId: String
        let createdAt: TimeInterval
    }

    private struct ActiveControllerChallenge {
        let requestId: String
        let targetHostId: String
        let keyId: String
        let promptKind: PasswordPromptKind
        let isManual: Bool
        let receivedAt: TimeInterval
    }

    private struct ActiveControlledChallenge {
        let requestId: String
        let controllerHostId: String
        let nonce: Data
        let promptKind: PasswordPromptKind
        let sessionToken: String
        let isManual: Bool
        let createdAt: TimeInterval
        let expiresAt: TimeInterval
    }

    weak var delegate: RemoteBiometricAuthCoordinatorDelegate?
    let credentialStore: UnlockCredentialStore
    private let clock: () -> TimeInterval
    var onEvaluationStateChange: ((Bool) -> Void)?

    private var outboundRequests: [String: OutboundManualRequest] = [:]
    private var activeControllerChallenge: ActiveControllerChallenge? {
        didSet {
            let wasEvaluating = oldValue != nil
            let isNowEvaluating = activeControllerChallenge != nil
            if wasEvaluating != isNowEvaluating {
                onEvaluationStateChange?(isNowEvaluating)
            }
        }
    }
    private var activeControlledChallenges: [String: ActiveControlledChallenge] = [:]
    private var suppressedAutoSessionToken: String?

    private(set) var consecutiveAutoFailures: Int = 0
    private(set) var isPerformingAutofill: Bool = false
    private var activeAutofillAttemptId: UUID?
    private var activeAutofillControllerHostId: String?
    private var lastManualAttemptAt: TimeInterval = Date.distantPast.timeIntervalSinceReferenceDate
    private var isForegroundYieldedForBiometrics = false

    var isEvaluatingBiometricsOnController: Bool {
        activeControllerChallenge != nil
    }

    var shouldSuppressControllerAutoRefocus: Bool {
        isForegroundYieldedForBiometrics || isEvaluatingBiometricsOnController
    }

    init(
        credentialStore: UnlockCredentialStore,
        clock: @escaping () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }
    ) {
        self.credentialStore = credentialStore
        self.clock = clock
    }

    // MARK: - Lifecycle & State Management

    func resetFailureCircuitBreaker() {
        consecutiveAutoFailures = 0
    }

    func removePeerState(for hostId: String) {
        handlePeerDisconnected(hostId)
    }

    func handlePeerDisconnected(_ hostId: String) {
        outboundRequests = outboundRequests.filter { $0.value.targetHostId != hostId }

        if activeControllerChallenge?.targetHostId == hostId {
            activeControllerChallenge = nil
            endForegroundYieldIfNeeded()
            delegate?.cancelLocalBiometricEvaluation()
        }

        let removedChallenges = activeControlledChallenges.values.filter { $0.controllerHostId == hostId }
        for challenge in removedChallenges {
            activeControlledChallenges.removeValue(forKey: challenge.requestId)
        }
        if removedChallenges.contains(where: { !$0.isManual }) {
            suppressedAutoSessionToken = nil
        }

        if activeAutofillControllerHostId == hostId {
            cancelActiveAutofill(reason: "peerDisconnected")
        }
    }

    func handleServerControlDidStop(reason: String) {
        let controllerHosts = Set(activeControlledChallenges.values.map { $0.controllerHostId })
        for challenge in activeControlledChallenges.values {
            sendCancel(requestId: challenge.requestId, reason: reason, to: challenge.controllerHostId)
        }
        activeControlledChallenges.removeAll()
        suppressedAutoSessionToken = nil

        if !controllerHosts.isEmpty || isPerformingAutofill {
            cancelActiveAutofill(reason: reason)
        }
    }

    func handleClientControlDidStop(reason: String) {
        outboundRequests.removeAll()
        if let active = activeControllerChallenge {
            activeControllerChallenge = nil
            endForegroundYieldIfNeeded()
            delegate?.cancelLocalBiometricEvaluation()
            sendCancel(requestId: active.requestId, reason: reason, to: active.targetHostId)
        } else {
            endForegroundYieldIfNeeded()
        }
    }

    func cancelAllPendingOperations(reason: String) {
        handleClientControlDidStop(reason: reason)
        handleServerControlDidStop(reason: reason)
    }

    private func cancelActiveAutofill(reason: String) {
        guard isPerformingAutofill else { return }
        activeAutofillAttemptId = nil
        activeAutofillControllerHostId = nil
        isPerformingAutofill = false
        delegate?.cancelActivePromptAutofill()
        delegate?.logBiometricEvent(
            level: .info,
            title: "Cancelled Touch ID password entry",
            detail: "Reason: \(reason).",
            howToFix: nil,
            hostId: nil,
            action: nil
        )
    }

    // MARK: - Controller Manual Trigger & Cancel

    @discardableResult
    func triggerManualAuthFromController(targetHostId: String) -> Bool {
        guard let delegate = delegate else { return false }
        guard delegate.isRemoteBiometricAuthEnabled(),
              !delegate.isLocalScreenLocked(),
              delegate.isPeerTrustedAndPaired(targetHostId),
              delegate.peerSupportsBiometricAuth(targetHostId),
              delegate.isHostConnected(targetHostId),
              delegate.isControllingHost(targetHostId) else {
            return false
        }

        if case .unavailable(let reason) = delegate.biometricAvailability() {
            delegate.showBezelNotification(
                title: "Touch ID Unavailable",
                subtitle: reason,
                isWarning: true
            )
            delegate.logBiometricEvent(
                level: .warning,
                title: "Touch ID unavailable on this Mac",
                detail: reason,
                howToFix: nil,
                hostId: targetHostId,
                action: nil
            )
            return false
        }

        guard activeControllerChallenge == nil else {
            return false
        }

        let now = clock()
        guard now - lastManualAttemptAt >= Self.manualAttemptCooldown else {
            return false
        }

        let peerName = delegate.peerDisplayName(targetHostId)
        guard let secret = credentialStore.loadPeerSecret(for: targetHostId) else {
            delegate.showBezelNotification(
                title: "Touch ID Not Ready",
                subtitle: "Security keys are still syncing with \(peerName).",
                isWarning: true
            )
            delegate.logBiometricEvent(
                level: .warning,
                title: "Cannot authenticate \(peerName) — security keys not synced",
                detail: "No shared security key has been established with \(peerName).",
                howToFix: "Ensure both Macs are unlocked and connected for a few seconds so keys can sync.",
                hostId: targetHostId,
                action: nil
            )
            delegate.initiatePeerKeyExchangeIfNeeded(with: targetHostId, force: false)
            return false
        }

        pruneExpiredOutboundRequests(now: now)
        let requestId = UUID().uuidString
        let keyId = AutoUnlockCrypto.keyId(for: secret)
        outboundRequests[requestId] = OutboundManualRequest(
            requestId: requestId,
            targetHostId: targetHostId,
            keyId: keyId,
            createdAt: now
        )
        lastManualAttemptAt = now

        delegate.sendBiometricMessage(
            .biometricAuthRequest,
            infoDict: [
                BiometricWireKey.requestId: requestId,
                BiometricWireKey.keyId: keyId,
                BiometricWireKey.manual: true
            ],
            to: targetHostId
        )
        return true
    }

    func cancelControllerEvaluationByUser() {
        guard let active = activeControllerChallenge else { return }
        activeControllerChallenge = nil
        endForegroundYieldIfNeeded()
        delegate?.cancelLocalBiometricEvaluation()
        sendCancel(requestId: active.requestId, reason: "Cancelled by user.", to: active.targetHostId)
    }

    private func beginForegroundYieldIfNeeded() {
        guard !isForegroundYieldedForBiometrics else { return }
        isForegroundYieldedForBiometrics = true
        delegate?.prepareControllerForegroundForBiometrics()
    }

    private func endForegroundYieldIfNeeded() {
        guard isForegroundYieldedForBiometrics else { return }
        isForegroundYieldedForBiometrics = false
        delegate?.restoreControllerForegroundAfterBiometrics()
    }

    // MARK: - Controlled-Side Polling (Auto-Detection)

    func pollControlledPromptState(controllerHostId: String) {
        guard let delegate = delegate else { return }
        let now = clock()
        pruneExpiredControlledChallenges(now: now)

        let systemPrompt = delegate.detectCurrentPasswordPrompt(allowNonSystemPrompts: false)

        // Cancel any active challenge if its underlying prompt has disappeared.
        let challengesForController = activeControlledChallenges.values.filter {
            $0.controllerHostId == controllerHostId
        }
        for challenge in challengesForController {
            let promptStillValid: Bool
            if challenge.promptKind == .systemDialog {
                promptStillValid = (systemPrompt?.sessionToken == challenge.sessionToken)
                    && delegate.isPasswordPromptStillActive(.systemDialog)
            } else {
                promptStillValid = delegate.isPasswordPromptStillActive(challenge.promptKind)
            }

            if !promptStillValid {
                activeControlledChallenges.removeValue(forKey: challenge.requestId)
                sendCancel(
                    requestId: challenge.requestId,
                    reason: "Password prompt closed.",
                    to: challenge.controllerHostId
                )
            }
        }

        guard let prompt = systemPrompt, prompt.kind == .systemDialog else {
            suppressedAutoSessionToken = nil
            return
        }

        guard prompt.sessionToken != suppressedAutoSessionToken else {
            return
        }

        guard !activeControlledChallenges.values.contains(where: { $0.controllerHostId == controllerHostId }) else {
            return
        }
        guard !isPerformingAutofill else {
            return
        }
        guard delegate.isRemoteBiometricAuthEnabled(),
              !delegate.isLocalScreenLocked(),
              delegate.isPeerTrustedAndPaired(controllerHostId),
              delegate.peerSupportsBiometricAuth(controllerHostId),
              delegate.isHostConnected(controllerHostId),
              delegate.isBeingControlled(by: controllerHostId) else {
            return
        }

        let peerName = delegate.peerDisplayName(controllerHostId)

        guard consecutiveAutoFailures < Self.maxConsecutiveAutoFailures else {
            suppressedAutoSessionToken = prompt.sessionToken
            delegate.logBiometricEvent(
                level: .warning,
                title: "Automatic Touch ID prompts paused on \(delegate.localDisplayName)",
                detail: "Paused after \(Self.maxConsecutiveAutoFailures) consecutive failures. Trigger Touch ID manually or update your saved password to reset.",
                howToFix: "Open Settings → Security on \(delegate.localDisplayName) and verify your saved login password.",
                hostId: controllerHostId,
                action: .openAutoUnlockSettings
            )
            return
        }

        guard credentialStore.hasSavedPassword && !credentialStore.isPasswordInvalid else {
            suppressedAutoSessionToken = prompt.sessionToken
            let reason = credentialStore.isPasswordInvalid
                ? "Saved login password needs to be updated on \(delegate.localDisplayName)."
                : "No login password is saved on \(delegate.localDisplayName)."
            delegate.logBiometricEvent(
                level: .warning,
                title: "Cannot prompt Touch ID for \(peerName)",
                detail: reason,
                howToFix: "Open Settings → Security on \(delegate.localDisplayName) and save your current macOS login password.",
                hostId: controllerHostId,
                action: .openAutoUnlockSettings
            )
            return
        }

        guard delegate.isAccessibilityTrusted() else {
            suppressedAutoSessionToken = prompt.sessionToken
            delegate.logBiometricEvent(
                level: .error,
                title: "Cannot prompt Touch ID — Accessibility not granted",
                detail: "Accessibility permission is required on \(delegate.localDisplayName) to type the password.",
                howToFix: "Grant Accessibility permission to Unimacs in System Settings → Privacy & Security → Accessibility.",
                hostId: controllerHostId,
                action: .openAccessibilitySettings
            )
            return
        }

        guard credentialStore.loadPeerSecret(for: controllerHostId) != nil else {
            suppressedAutoSessionToken = prompt.sessionToken
            delegate.initiatePeerKeyExchangeIfNeeded(with: controllerHostId, force: false)
            return
        }

        suppressedAutoSessionToken = prompt.sessionToken
        let requestId = UUID().uuidString
        issueChallenge(
            to: controllerHostId,
            prompt: prompt,
            requestId: requestId,
            isManual: false,
            now: now
        )
    }

    // MARK: - Message Dispatch

    @discardableResult
    func handleMessage(_ type: MsgType, infoDict: [AnyHashable: Any], from hostId: String) -> Bool {
        switch type {
        case .biometricAuthRequest:
            handleBiometricAuthRequest(from: hostId, infoDict: infoDict)
            return true
        case .biometricAuthChallenge:
            handleBiometricAuthChallenge(from: hostId, infoDict: infoDict)
            return true
        case .biometricAuthResponse:
            handleBiometricAuthResponse(from: hostId, infoDict: infoDict)
            return true
        case .biometricAuthCancel:
            handleBiometricAuthCancel(from: hostId, infoDict: infoDict)
            return true
        case .biometricAuthResult:
            handleBiometricAuthResult(from: hostId, infoDict: infoDict)
            return true
        default:
            return false
        }
    }

    // MARK: - Controlled Handlers (Request & Response)

    private func handleBiometricAuthRequest(from hostId: String, infoDict: [AnyHashable: Any]) {
        guard let delegate = delegate else { return }
        guard delegate.isPeerTrustedAndPaired(hostId) else { return }
        guard let requestId = infoDict[BiometricWireKey.requestId] as? String, !requestId.isEmpty,
              let peerKeyId = infoDict[BiometricWireKey.keyId] as? String, !peerKeyId.isEmpty else {
            return
        }

        let peerName = delegate.peerDisplayName(hostId)

        guard delegate.isRemoteBiometricAuthEnabled() else {
            sendResult(
                requestId: requestId,
                success: false,
                reason: "Touch ID authentication for password prompts is disabled on \(delegate.localDisplayName).",
                to: hostId
            )
            return
        }

        guard delegate.isBeingControlled(by: hostId) else {
            sendResult(
                requestId: requestId,
                success: false,
                reason: "\(delegate.localDisplayName) is not currently controlled by \(peerName).",
                to: hostId
            )
            return
        }

        guard !delegate.isLocalScreenLocked() else {
            sendResult(
                requestId: requestId,
                success: false,
                reason: "Screen is locked on \(delegate.localDisplayName).",
                to: hostId
            )
            return
        }

        guard credentialStore.hasSavedPassword else {
            let reason = "No login password is saved on \(delegate.localDisplayName)."
            sendResult(requestId: requestId, success: false, reason: reason, to: hostId)
            delegate.logBiometricEvent(
                level: .warning,
                title: "Cannot authenticate from \(peerName)",
                detail: reason,
                howToFix: "Open Settings → Security on \(delegate.localDisplayName) and save your current macOS login password.",
                hostId: hostId,
                action: .openAutoUnlockSettings
            )
            return
        }

        guard delegate.isAccessibilityTrusted() else {
            let reason = "Accessibility permission is required on \(delegate.localDisplayName) to enter the password."
            sendResult(requestId: requestId, success: false, reason: reason, to: hostId)
            delegate.logBiometricEvent(
                level: .error,
                title: "Cannot authenticate from \(peerName) — Accessibility not granted",
                detail: reason,
                howToFix: "Grant Accessibility permission to Unimacs in System Settings → Privacy & Security → Accessibility.",
                hostId: hostId,
                action: .openAccessibilitySettings
            )
            return
        }

        guard !isPerformingAutofill else {
            sendResult(requestId: requestId, success: false, reason: "A password entry is already in progress.", to: hostId)
            return
        }

        guard let secret = credentialStore.loadPeerSecret(for: hostId),
              AutoUnlockCrypto.keyId(for: secret) == peerKeyId else {
            sendResult(
                requestId: requestId,
                success: false,
                keyMismatch: true,
                reason: "Security key mismatch with \(delegate.localDisplayName). Re-syncing keys…",
                to: hostId
            )
            return
        }

        guard let prompt = delegate.detectCurrentPasswordPrompt(allowNonSystemPrompts: true) else {
            sendResult(
                requestId: requestId,
                success: false,
                reason: "No masked password input or terminal password prompt is focused on \(delegate.localDisplayName).",
                to: hostId
            )
            return
        }

        issueChallenge(
            to: hostId,
            prompt: prompt,
            requestId: requestId,
            isManual: true,
            now: clock()
        )
    }

    private func issueChallenge(
        to controllerHostId: String,
        prompt: DetectedPasswordPrompt,
        requestId: String,
        isManual: Bool,
        now: TimeInterval
    ) {
        guard let delegate = delegate else { return }
        pruneExpiredControlledChallenges(now: now)
        if activeControlledChallenges.count >= Self.maxActiveChallenges,
           let oldestKey = activeControlledChallenges.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            activeControlledChallenges.removeValue(forKey: oldestKey)
        }

        do {
            let nonce = try AutoUnlockCrypto.generateNonce(byteCount: 32)
            activeControlledChallenges[requestId] = ActiveControlledChallenge(
                requestId: requestId,
                controllerHostId: controllerHostId,
                nonce: nonce,
                promptKind: prompt.kind,
                sessionToken: prompt.sessionToken,
                isManual: isManual,
                createdAt: now,
                expiresAt: now + Self.challengeTTL
            )
            delegate.sendBiometricMessage(
                .biometricAuthChallenge,
                infoDict: [
                    BiometricWireKey.requestId: requestId,
                    BiometricWireKey.nonce: nonce,
                    BiometricWireKey.promptKind: prompt.kind.rawValue,
                    BiometricWireKey.manual: isManual
                ],
                to: controllerHostId
            )
        } catch {
            sendResult(requestId: requestId, success: false, reason: error.localizedDescription, to: controllerHostId)
        }
    }

    private func handleBiometricAuthResponse(from hostId: String, infoDict: [AnyHashable: Any]) {
        guard let delegate = delegate else { return }
        guard let requestId = infoDict[BiometricWireKey.requestId] as? String, !requestId.isEmpty,
              let hmac = infoDict[BiometricWireKey.hmac] as? Data else {
            return
        }

        // Single-use nonce: always remove immediately upon lookup.
        guard let challenge = activeControlledChallenges.removeValue(forKey: requestId) else {
            sendResult(requestId: requestId, success: false, reason: "Unknown or already used authentication challenge.", to: hostId)
            return
        }

        guard challenge.controllerHostId == hostId else {
            sendResult(requestId: requestId, success: false, reason: "Authentication challenge requester mismatch.", to: hostId)
            return
        }

        let now = clock()
        guard now <= challenge.expiresAt else {
            sendResult(requestId: requestId, success: false, reason: "Touch ID authentication challenge expired.", to: hostId)
            return
        }

        guard delegate.isPeerTrustedAndPaired(hostId),
              delegate.isRemoteBiometricAuthEnabled(),
              delegate.isBeingControlled(by: hostId) else {
            sendResult(requestId: requestId, success: false, reason: "Remote Touch ID authentication is disabled or session ended.", to: hostId)
            return
        }

        guard !delegate.isLocalScreenLocked() else {
            sendResult(requestId: requestId, success: false, aborted: true, reason: "Screen locked before password entry.", to: hostId)
            return
        }

        guard delegate.isAccessibilityTrusted() else {
            sendResult(requestId: requestId, success: false, reason: "Accessibility permission is required.", to: hostId)
            return
        }

        guard delegate.isPasswordPromptStillActive(challenge.promptKind) else {
            sendResult(requestId: requestId, success: false, aborted: true, reason: "Password prompt closed before entry.", to: hostId)
            return
        }

        guard let secret = credentialStore.loadPeerSecret(for: hostId),
              AutoUnlockCrypto.verifyBiometricChallengeHMAC(
                  hmac,
                  secret: secret,
                  requestId: requestId,
                  nonce: challenge.nonce,
                  controllerHostId: hostId,
                  targetHostId: delegate.localHostId,
                  promptKindRaw: challenge.promptKind.rawValue,
                  isManual: challenge.isManual
              ) else {
            let peerName = delegate.peerDisplayName(hostId)
            sendResult(requestId: requestId, success: false, reason: "Authentication HMAC verification failed.", to: hostId)
            delegate.logBiometricEvent(
                level: .warning,
                title: "Rejected unauthenticated Touch ID response from \(peerName)",
                detail: "Challenge HMAC signature did not match the shared peer secret.",
                howToFix: nil,
                hostId: hostId,
                action: nil
            )
            return
        }

        guard !isPerformingAutofill else {
            sendResult(requestId: requestId, success: false, reason: "A password entry is already in progress.", to: hostId)
            return
        }

        let canUseStoredPassword = challenge.isManual || !credentialStore.isPasswordInvalid
        guard canUseStoredPassword,
              let password = try? credentialStore.loadPassword(),
              !password.isEmpty else {
            sendResult(requestId: requestId, success: false, reason: "No valid saved login password available.", to: hostId)
            delegate.logBiometricEvent(
                level: .warning,
                title: "Cannot enter password — missing or invalid saved password",
                detail: "Update your macOS login password in Settings → Security.",
                howToFix: "Open Settings → Security and re-enter your macOS login password.",
                hostId: hostId,
                action: .openAutoUnlockSettings
            )
            return
        }

        let attemptId = UUID()
        isPerformingAutofill = true
        activeAutofillAttemptId = attemptId
        activeAutofillControllerHostId = hostId

        delegate.verifyLocalPassword(password) { [weak self] verificationResult in
            guard let self = self, let delegate = self.delegate else { return }

            guard self.activeAutofillAttemptId == attemptId, self.isPerformingAutofill else {
                self.sendResult(requestId: requestId, success: false, aborted: true, reason: "Password entry was cancelled.", to: hostId)
                return
            }

            switch verificationResult {
            case .invalidCredentials:
                self.clearAutofillAttempt(attemptId)
                self.credentialStore.markPasswordInvalid()
                if !challenge.isManual {
                    self.consecutiveAutoFailures += 1
                }
                let reason = "Saved password no longer matches the local macOS account password."
                self.sendResult(requestId: requestId, success: false, reason: reason, to: hostId)
                delegate.logBiometricEvent(
                    level: .error,
                    title: "Password entry aborted — saved password is incorrect",
                    detail: "Local password verification failed before typing, so no keystrokes were entered.",
                    howToFix: "Open Settings → Security and update your saved macOS login password.",
                    hostId: hostId,
                    action: .openAutoUnlockSettings
                )
                return

            case .unavailable(let message):
                self.clearAutofillAttempt(attemptId)
                let reason = "Unable to verify local password: \(message)"
                self.sendResult(requestId: requestId, success: false, reason: reason, to: hostId)
                delegate.logBiometricEvent(
                    level: .warning,
                    title: "Password entry skipped — password check unavailable",
                    detail: reason,
                    howToFix: nil,
                    hostId: hostId,
                    action: nil
                )
                return

            case .valid:
                if self.credentialStore.isPasswordInvalid {
                    self.credentialStore.clearPasswordInvalidFlag()
                }
            }

            guard delegate.isBeingControlled(by: hostId),
                  !delegate.isLocalScreenLocked(),
                  delegate.isPasswordPromptStillActive(challenge.promptKind) else {
                self.clearAutofillAttempt(attemptId)
                self.sendResult(requestId: requestId, success: false, aborted: true, reason: "Password prompt closed before entry.", to: hostId)
                return
            }

            delegate.performPromptAutofill(password: password, promptKind: challenge.promptKind) { [weak self] outcome in
                guard let self = self, let delegate = self.delegate else { return }
                self.clearAutofillAttempt(attemptId)
                self.handleAutofillOutcome(
                    outcome,
                    requestId: requestId,
                    isManual: challenge.isManual,
                    from: hostId,
                    delegate: delegate
                )
            }
        }
    }

    private func clearAutofillAttempt(_ attemptId: UUID) {
        if activeAutofillAttemptId == attemptId {
            activeAutofillAttemptId = nil
            activeAutofillControllerHostId = nil
            isPerformingAutofill = false
        }
    }

    private func handleAutofillOutcome(
        _ outcome: PromptAutofillOutcome,
        requestId: String,
        isManual: Bool,
        from hostId: String,
        delegate: RemoteBiometricAuthCoordinatorDelegate
    ) {
        let peerName = delegate.peerDisplayName(hostId)
        switch outcome {
        case .typedAndSubmitted:
            consecutiveAutoFailures = 0
            sendResult(requestId: requestId, success: true, reason: nil, to: hostId)
            delegate.logBiometricEvent(
                level: .success,
                title: "Entered password via Touch ID from \(peerName)",
                detail: "Verified Touch ID challenge and submitted password prompt.",
                howToFix: nil,
                hostId: hostId,
                action: nil
            )

        case .abortedPromptClosed:
            sendResult(requestId: requestId, success: false, aborted: true, reason: "Password prompt closed before entry finished.", to: hostId)
            delegate.logBiometricEvent(
                level: .info,
                title: "Aborted Touch ID password entry",
                detail: "The target password prompt closed before typing completed.",
                howToFix: nil,
                hostId: hostId,
                action: nil
            )

        case .abortedScreenLocked:
            sendResult(requestId: requestId, success: false, aborted: true, reason: "Screen locked before entry finished.", to: hostId)
            delegate.logBiometricEvent(
                level: .warning,
                title: "Aborted Touch ID password entry",
                detail: "The screen locked before password entry completed.",
                howToFix: nil,
                hostId: hostId,
                action: nil
            )

        case .cancelled:
            sendResult(requestId: requestId, success: false, aborted: true, reason: "Password entry cancelled.", to: hostId)

        case .failed(let message):
            if !isManual {
                consecutiveAutoFailures += 1
            }
            sendResult(requestId: requestId, success: false, reason: message, to: hostId)
            delegate.logBiometricEvent(
                level: .error,
                title: "Touch ID password entry failed",
                detail: message,
                howToFix: "Check Accessibility permissions and your saved login password in Settings → Security.",
                hostId: hostId,
                action: .openAutoUnlockSettings
            )
        }
    }

    // MARK: - Controller Handlers (Challenge, Cancel, Result)

    private func handleBiometricAuthChallenge(from hostId: String, infoDict: [AnyHashable: Any]) {
        guard let delegate = delegate else { return }
        guard delegate.isPeerTrustedAndPaired(hostId) else { return }
        guard let requestId = infoDict[BiometricWireKey.requestId] as? String, !requestId.isEmpty,
              let nonce = infoDict[BiometricWireKey.nonce] as? Data, nonce.count >= 16,
              let promptKindRaw = infoDict[BiometricWireKey.promptKind] as? String,
              let promptKind = PasswordPromptKind(rawValue: promptKindRaw) else {
            return
        }

        let isManual = (infoDict[BiometricWireKey.manual] as? Bool) ?? false
        let now = clock()

        if isManual {
            guard let pendingReq = outboundRequests.removeValue(forKey: requestId),
                  pendingReq.targetHostId == hostId,
                  now <= pendingReq.createdAt + Self.requestTTL else {
                sendCancel(requestId: requestId, reason: "Stale or unexpected manual Touch ID challenge.", to: hostId)
                return
            }
        }

        guard delegate.isRemoteBiometricAuthEnabled(),
              !delegate.isLocalScreenLocked(),
              delegate.peerSupportsBiometricAuth(hostId),
              delegate.isControllingHost(hostId),
              activeControllerChallenge == nil else {
            sendCancel(requestId: requestId, reason: "Controller is not ready for Touch ID prompt.", to: hostId)
            return
        }

        if case .unavailable(let reason) = delegate.biometricAvailability() {
            sendCancel(requestId: requestId, reason: reason, to: hostId)
            if isManual {
                delegate.showBezelNotification(title: "Touch ID Unavailable", subtitle: reason, isWarning: true)
                delegate.logBiometricEvent(
                    level: .warning,
                    title: "Touch ID unavailable on this Mac",
                    detail: reason,
                    howToFix: nil,
                    hostId: hostId,
                    action: nil
                )
            }
            return
        }

        guard let secret = credentialStore.loadPeerSecret(for: hostId) else {
            sendCancel(requestId: requestId, reason: "Missing shared security key.", to: hostId)
            delegate.initiatePeerKeyExchangeIfNeeded(with: hostId, force: false)
            return
        }

        let keyId = AutoUnlockCrypto.keyId(for: secret)
        activeControllerChallenge = ActiveControllerChallenge(
            requestId: requestId,
            targetHostId: hostId,
            keyId: keyId,
            promptKind: promptKind,
            isManual: isManual,
            receivedAt: now
        )

        let peerName = delegate.peerDisplayName(hostId)
        let reason = "authenticate on \(peerName)"

        beginForegroundYieldIfNeeded()

        delegate.evaluateBiometrics(reason: reason) { [weak self] result in
            guard let self = self, let delegate = self.delegate else { return }
            guard let active = self.activeControllerChallenge, active.requestId == requestId else {
                // Challenge was already cancelled remotely or by user Escape key.
                return
            }
            self.activeControllerChallenge = nil
            self.endForegroundYieldIfNeeded()

            switch result {
            case .authenticated:
                guard delegate.isRemoteBiometricAuthEnabled(),
                      !delegate.isLocalScreenLocked(),
                      delegate.isControllingHost(hostId),
                      let currentSecret = self.credentialStore.loadPeerSecret(for: hostId),
                      AutoUnlockCrypto.keyId(for: currentSecret) == active.keyId else {
                    self.sendCancel(requestId: requestId, reason: "Control state changed during Touch ID evaluation.", to: hostId)
                    return
                }

                do {
                    let hmac = try AutoUnlockCrypto.computeBiometricChallengeHMAC(
                        secret: currentSecret,
                        requestId: requestId,
                        nonce: nonce,
                        controllerHostId: delegate.localHostId,
                        targetHostId: hostId,
                        promptKindRaw: promptKind.rawValue,
                        isManual: isManual
                    )
                    delegate.sendBiometricMessage(
                        .biometricAuthResponse,
                        infoDict: [
                            BiometricWireKey.requestId: requestId,
                            BiometricWireKey.hmac: hmac
                        ],
                        to: hostId
                    )
                } catch {
                    self.sendCancel(requestId: requestId, reason: error.localizedDescription, to: hostId)
                }

            case .userCancelled:
                self.sendCancel(requestId: requestId, reason: "Touch ID authentication cancelled.", to: hostId)

            case .failed(let message):
                self.sendCancel(requestId: requestId, reason: message, to: hostId)
                delegate.showBezelNotification(title: "Touch ID Failed", subtitle: message, isWarning: true)
                delegate.logBiometricEvent(
                    level: .warning,
                    title: "Touch ID failed while authenticating \(peerName)",
                    detail: message,
                    howToFix: nil,
                    hostId: hostId,
                    action: nil
                )
            }
        }
    }

    private func handleBiometricAuthCancel(from hostId: String, infoDict: [AnyHashable: Any]) {
        guard let delegate = delegate else { return }
        guard delegate.isPeerTrustedAndPaired(hostId) else { return }
        guard let requestId = infoDict[BiometricWireKey.requestId] as? String, !requestId.isEmpty else {
            return
        }

        outboundRequests.removeValue(forKey: requestId)

        if let active = activeControllerChallenge,
           active.requestId == requestId,
           active.targetHostId == hostId {
            activeControllerChallenge = nil
            endForegroundYieldIfNeeded()
            delegate.cancelLocalBiometricEvaluation()
        }

        if let challenge = activeControlledChallenges[requestId],
           challenge.controllerHostId == hostId {
            activeControlledChallenges.removeValue(forKey: requestId)
        }
    }

    private func handleBiometricAuthResult(from hostId: String, infoDict: [AnyHashable: Any]) {
        guard let delegate = delegate else { return }
        guard delegate.isPeerTrustedAndPaired(hostId) else { return }

        if let requestId = infoDict[BiometricWireKey.requestId] as? String {
            outboundRequests.removeValue(forKey: requestId)
        }

        let success = (infoDict[BiometricWireKey.success] as? Bool) ?? false
        let keyMismatch = (infoDict[BiometricWireKey.keyMismatch] as? Bool) ?? false
        let aborted = (infoDict[BiometricWireKey.aborted] as? Bool) ?? false
        let reason = infoDict[BiometricWireKey.reason] as? String
        let peerName = delegate.peerDisplayName(hostId)

        if keyMismatch {
            credentialStore.removePeerSecret(for: hostId)
            if !delegate.isLocalScreenLocked() && delegate.isRemoteBiometricAuthEnabled() {
                delegate.initiatePeerKeyExchangeIfNeeded(with: hostId, force: true)
            }
        }

        if success {
            delegate.logBiometricEvent(
                level: .success,
                title: "Authenticated \(peerName) with Touch ID",
                detail: "Remote password prompt on \(peerName) was filled via Touch ID.",
                howToFix: nil,
                hostId: hostId,
                action: nil
            )
        } else if !aborted {
            let detail = reason ?? "Remote Mac could not complete Touch ID password entry."
            delegate.showBezelNotification(title: "Touch ID Auth Failed", subtitle: detail, isWarning: true)
            delegate.logBiometricEvent(
                level: .warning,
                title: "Could not authenticate \(peerName) with Touch ID",
                detail: detail,
                howToFix: keyMismatch
                    ? "Keep both Macs unlocked and connected for a few seconds to refresh security keys."
                    : nil,
                hostId: hostId,
                action: nil
            )
        }
    }

    // MARK: - Wire Helpers & Pruning

    private func sendCancel(requestId: String, reason: String, to hostId: String) {
        delegate?.sendBiometricMessage(
            .biometricAuthCancel,
            infoDict: [
                BiometricWireKey.requestId: requestId,
                BiometricWireKey.reason: reason
            ],
            to: hostId
        )
    }

    private func sendResult(
        requestId: String,
        success: Bool,
        keyMismatch: Bool = false,
        aborted: Bool = false,
        reason: String?,
        to hostId: String
    ) {
        var info: [AnyHashable: Any] = [
            BiometricWireKey.requestId: requestId,
            BiometricWireKey.success: success,
            BiometricWireKey.keyMismatch: keyMismatch,
            BiometricWireKey.aborted: aborted
        ]
        if let reason = reason, !reason.isEmpty {
            info[BiometricWireKey.reason] = reason
        }
        delegate?.sendBiometricMessage(.biometricAuthResult, infoDict: info, to: hostId)
    }

    private func pruneExpiredOutboundRequests(now: TimeInterval) {
        outboundRequests = outboundRequests.filter { now - $0.value.createdAt <= Self.requestTTL }
    }

    private func pruneExpiredControlledChallenges(now: TimeInterval) {
        activeControlledChallenges = activeControlledChallenges.filter { now <= $0.value.expiresAt }
    }
}

#if !STANDALONE_UNIT_TEST

@MainActor
final class RemoteBiometricAuthManager: NSObject, DeviceConnectionDelegate, RemoteBiometricAuthCoordinatorDelegate {

    static let shared = RemoteBiometricAuthManager()

    /// Lock-free snapshot read on the CGEventTap thread to support `Esc` cancellation.
    nonisolated(unsafe) static var isEvaluatingSnapshot: Bool = false

    private static let pollInterval: TimeInterval = 0.35
    private static let coreAuthAgentBundleId = "com.apple.LocalAuthentication.UIAgent"

    private let coordinator: RemoteBiometricAuthCoordinator
    private let passwordVerifier: UnlockPasswordVerifying
    private let typingQueue = DispatchQueue(label: "com.unimacs.biometric.typing", qos: .userInteractive)
    private var activeCancellationToken: ScreenUnlockCancellationToken?
    private var activeLAContext: LAContext?
    private var focusAssistWorkItems: [DispatchWorkItem] = []
    private var pollTimer: Timer?
    private var activeControllerHostId: String?
    private(set) var isYieldingForegroundForBiometrics = false

    var shouldSuppressControllerAutoRefocus: Bool {
        isYieldingForegroundForBiometrics || coordinator.shouldSuppressControllerAutoRefocus
    }

    private override init() {
        self.coordinator = RemoteBiometricAuthCoordinator(credentialStore: UnlockCredentialStore.shared)
        self.passwordVerifier = OpenDirectoryPasswordVerifier()
        super.init()
        self.coordinator.delegate = self
        self.coordinator.onEvaluationStateChange = { isEvaluating in
            RemoteBiometricAuthManager.isEvaluatingSnapshot = isEvaluating
        }
        DeviceConnectionManager.shared.addDelegate(self)
    }

    // MARK: - Public Lifecycle & Trigger Hooks

    @discardableResult
    func triggerManualBiometricAuth() -> Bool {
        guard ClientController.shared.isControlling,
              let hostId = ClientController.shared.currentConnection?.connectedHost?.identifier else {
            return false
        }
        if coordinator.isEvaluatingBiometricsOnController {
            yieldActivationToBiometricAgent(forceActivateAgent: true)
            return false
        }
        return coordinator.triggerManualAuthFromController(targetHostId: hostId)
    }

    func cancelControllerEvaluationByUser() {
        coordinator.cancelControllerEvaluationByUser()
    }

    func handleServerControlDidStart(by controllerHostId: String) {
        stopPolling()
        activeControllerHostId = controllerHostId
        coordinator.pollControlledPromptState(controllerHostId: controllerHostId)

        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let hostId = self.activeControllerHostId else { return }
                self.coordinator.pollControlledPromptState(controllerHostId: hostId)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func handleServerControlDidStop(reason: String) {
        stopPolling()
        coordinator.handleServerControlDidStop(reason: reason)
    }

    func handleClientControlDidStop(reason: String) {
        coordinator.handleClientControlDidStop(reason: reason)
    }

    func handleLocalScreenLocked() {
        stopPolling()
        coordinator.cancelAllPendingOperations(reason: "screenLocked")
    }

    func cancelAllPendingOperations(reason: String) {
        stopPolling()
        coordinator.cancelAllPendingOperations(reason: reason)
    }

    func removePeerState(forHostId hostId: String) {
        if activeControllerHostId == hostId {
            stopPolling()
        }
        coordinator.removePeerState(for: hostId)
    }

    func resetFailureCircuitBreaker() {
        coordinator.resetFailureCircuitBreaker()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        activeControllerHostId = nil
    }

    // MARK: - DeviceConnectionDelegate

    func connectionDidDisconnect(from host: RemoteHost) {
        guard !DeviceConnectionManager.shared.isConnected(to: host) else { return }
        if activeControllerHostId == host.identifier {
            stopPolling()
        }
        coordinator.handlePeerDisconnected(host.identifier)
    }

    func handleMessage(_ message: Message, from host: RemoteHost, connection: NetworkConnection) -> Bool {
        coordinator.handleMessage(message.msgType, infoDict: message.infoDict, from: host.identifier)
    }

    // MARK: - RemoteBiometricAuthCoordinatorDelegate

    var localHostId: String {
        LocalHost.shared.identifier
    }

    var localDisplayName: String {
        LocalHost.shared.computerName
    }

    func isLocalScreenLocked() -> Bool {
        ScreenUnlocker.isScreenLockedLive()
    }

    func isRemoteBiometricAuthEnabled() -> Bool {
        PreferencesManager.shared().bool(forPref: Settings.enableRemoteBiometricAuthKey)
    }

    func hasLocalSavedPassword() -> Bool {
        UnlockCredentialStore.shared.hasSavedPassword
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

    func peerSupportsBiometricAuth(_ hostId: String) -> Bool {
        guard let host = HostDevicesManager.shared.host(withIdentifier: hostId) else {
            return false
        }
        return host.hasCapability(.biometricAuth)
    }

    func isHostConnected(_ hostId: String) -> Bool {
        guard let host = HostDevicesManager.shared.host(withIdentifier: hostId) else {
            return false
        }
        return DeviceConnectionManager.shared.isConnected(to: host)
    }

    func isControllingHost(_ hostId: String) -> Bool {
        ClientController.shared.isControlling
            && ClientController.shared.currentConnection?.connectedHost?.identifier == hostId
    }

    func isBeingControlled(by hostId: String) -> Bool {
        ServerController.shared.isControlled
            && ServerController.shared.currentConnection?.connectedHost?.identifier == hostId
    }

    func peerDisplayName(_ hostId: String) -> String {
        HostDevicesManager.shared.host(withIdentifier: hostId)?.computerName ?? hostId
    }

    func initiatePeerKeyExchangeIfNeeded(with hostId: String, force: Bool) {
        AutoUnlockManager.shared.initiatePeerKeyExchangeIfNeeded(with: hostId, force: force)
    }

    func sendBiometricMessage(_ type: MsgType, infoDict: [AnyHashable: Any], to hostId: String) {
        let message = Message.create(with: type, andInfoDict: infoDict)
        _ = DeviceConnectionManager.shared.sendMessage(message, toHost: hostId)
    }

    func detectCurrentPasswordPrompt(allowNonSystemPrompts: Bool) -> DetectedPasswordPrompt? {
        SystemPasswordPromptInspector.inspect(allowNonSystemPrompts: allowNonSystemPrompts)
    }

    func isPasswordPromptStillActive(_ kind: PasswordPromptKind) -> Bool {
        switch kind {
        case .systemDialog:
            return SystemPasswordPromptInspector.inspect(allowNonSystemPrompts: false)?.kind == .systemDialog
        case .secureTextField:
            return SystemPasswordPromptInspector.inspect(allowNonSystemPrompts: true)?.kind == .secureTextField
        case .terminalPassword:
            return SystemPasswordPromptInspector.inspect(allowNonSystemPrompts: true)?.kind == .terminalPassword
        }
    }

    func biometricAvailability() -> BiometricAvailability {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return .available
        }
        return .unavailable(error?.localizedDescription ?? "Touch ID is unavailable on this Mac.")
    }

    func prepareControllerForegroundForBiometrics() {
        isYieldingForegroundForBiometrics = true
        cancelFocusAssistWorkItems()
        BezelController.default().setTemporarilySuspended(true)
        CursorVisibilityController.shared.suspendShieldsForSystemPrompt()
        yieldActivationToBiometricAgent(forceActivateAgent: false)

        // coreautha presents its panel asynchronously via XPC; assist only if its visible window is unfocused.
        for delay in [0.12, 0.30, 0.60] {
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self, self.activeLAContext != nil else { return }
                    self.yieldActivationToBiometricAgent(forceActivateAgent: true)
                }
            }
            focusAssistWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    func restoreControllerForegroundAfterBiometrics() {
        isYieldingForegroundForBiometrics = false
        cancelFocusAssistWorkItems()
        CursorVisibilityController.shared.resumeShieldsAfterSystemPrompt()
        BezelController.default().setTemporarilySuspended(false)
    }

    private func cancelFocusAssistWorkItems() {
        for item in focusAssistWorkItems {
            item.cancel()
        }
        focusAssistWorkItems.removeAll()
    }

    private func yieldActivationToBiometricAgent(forceActivateAgent: Bool) {
        let agents = NSRunningApplication.runningApplications(withBundleIdentifier: Self.coreAuthAgentBundleId)
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: Self.coreAuthAgentBundleId)
            for agent in agents {
                NSApp.yieldActivation(to: agent)
            }
        }
        if forceActivateAgent {
            for agent in agents where !agent.isActive && Self.processHasOnScreenWindow(agent.processIdentifier) {
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(to: agent)
                }
                _ = agent.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
        }
    }

    private static func processHasOnScreenWindow(_ pid: pid_t) -> Bool {
        guard pid > 0,
              let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return rawList.contains { entry in
            guard let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == pid else {
                return false
            }
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            guard alpha > 0.01,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                return false
            }
            return bounds.width >= 100 && bounds.height >= 50
        }
    }

    func evaluateBiometrics(reason: String, completion: @escaping @MainActor @Sendable (BiometricEvaluationResult) -> Void) {
        activeLAContext?.invalidate()
        let context = LAContext()
        context.localizedFallbackTitle = ""
        context.localizedCancelTitle = "Cancel"
        activeLAContext = context

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { [weak self, weak context] success, error in
            let mappedResult: BiometricEvaluationResult
            if success {
                mappedResult = .authenticated
            } else if let laError = error as? LAError {
                switch laError.code {
                case .userCancel, .systemCancel, .appCancel:
                    mappedResult = .userCancelled
                default:
                    mappedResult = .failed(laError.localizedDescription)
                }
            } else {
                mappedResult = .failed(error?.localizedDescription ?? "Touch ID authentication failed.")
            }

            Task { @MainActor [weak self] in
                if let self = self, let context = context, self.activeLAContext === context {
                    self.activeLAContext = nil
                }
                completion(mappedResult)
            }
        }
    }

    func cancelLocalBiometricEvaluation() {
        activeLAContext?.invalidate()
        activeLAContext = nil
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

    func performPromptAutofill(
        password: String,
        promptKind: PasswordPromptKind,
        completion: @escaping @MainActor @Sendable (PromptAutofillOutcome) -> Void
    ) {
        activeCancellationToken?.cancel()
        let token = ScreenUnlockCancellationToken()
        activeCancellationToken = token

        let keyStrokes = ScreenUnlocker.resolveKeyStrokes(for: password)

        typingQueue.async {
            let outcome = ScreenUnlocker.performPromptAutofill(
                keyStrokes: keyStrokes,
                promptKind: promptKind,
                cancellationToken: token
            )
            Task { @MainActor [weak self] in
                if self?.activeCancellationToken === token {
                    self?.activeCancellationToken = nil
                }
                completion(outcome)
            }
        }
    }

    func cancelActivePromptAutofill() {
        activeCancellationToken?.cancel()
        activeCancellationToken = nil
    }

    func showBezelNotification(title: String, subtitle: String, isWarning: Bool) {
        BezelController.default().setMode(.notification(
            title: title,
            subtitle: subtitle,
            icon: isWarning ? .warning : .key,
            duration: 2.5
        ))
    }

    func logBiometricEvent(
        level: AutoUnlockLogLevel,
        title: String,
        detail: String?,
        howToFix: String?,
        hostId: String?,
        action: AutoUnlockLogAction?
    ) {
        ActivityLogManager.shared.log(
            level: level.activityLogLevel,
            category: .control,
            title: title,
            detail: detail,
            howToFix: howToFix,
            hostId: hostId,
            hostName: hostId.map { peerDisplayName($0) },
            actions: action.map { [$0.activityFixAction] } ?? []
        )
    }
}

#endif
