// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import CoreGraphics
import CryptoKit
import Carbon

// MARK: - Lightweight Assertion Helpers

private var totalTestsRun = 0
private var totalAssertions = 0
private var failedTests: [String] = []

private func assertEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: @autoclosure () -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    let a = actual()
    let e = expected()
    if a != e {
        let failure = "[\(file):\(line)] Assertion failed: expected (\(e)), got (\(a)). \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertNotEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ notExpected: @autoclosure () -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    let a = actual()
    let n = notExpected()
    if a == n {
        let failure = "[\(file):\(line)] Assertion failed: expected not equal to (\(n)). \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertTrue(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if !condition() {
        let failure = "[\(file):\(line)] Assertion failed: expected true. \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertFalse(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if condition() {
        let failure = "[\(file):\(line)] Assertion failed: expected false. \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertNil<T>(
    _ value: @autoclosure () -> T?,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if let v = value() {
        let failure = "[\(file):\(line)] Assertion failed: expected nil, got \(v). \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertNotNil<T>(
    _ value: @autoclosure () -> T?,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if value() == nil {
        let failure = "[\(file):\(line)] Assertion failed: expected non-nil value. \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertThrows(_ message: String = "", _ block: () throws -> Void) {
    totalAssertions += 1
    do {
        try block()
        let failure = "Assertion failed: expected error to be thrown. \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    } catch {
        // Expected
    }
}

@MainActor
private func runTest(_ name: String, _ block: () throws -> Void) {
    totalTestsRun += 1
    let failuresBefore = failedTests.count
    do {
        try block()
    } catch {
        let failure = "Unexpected error in \(name): \(error)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
    if failedTests.count == failuresBefore {
        print("  ✅ \(name)")
    }
}

// MARK: - Test Mocks

private final class MockScreenUnlockDriver: ScreenUnlockingDriver, @unchecked Sendable {
    enum RecordedEvent: Equatable {
        case wake
        case keyCode(CGKeyCode, keyDown: Bool, flags: CGEventFlags, chars: [UniChar]?)
        case flagsChanged(CGEventFlags)
        case unicode([UniChar], keyDown: Bool)
    }

    var displayAsleep = false
    var locked = true
    var unlockAfterKeyDownCount: Int? = nil
    var recordedEvents: [RecordedEvent] = []
    private var keyDownCount = 0

    func wakeUpScreen() {
        recordedEvents.append(.wake)
        displayAsleep = false
    }

    func isDisplayAsleep() -> Bool {
        displayAsleep
    }

    func isScreenLockedLive() -> Bool {
        locked
    }

    func sleep(milliseconds: UInt64) {
        // No real wall-clock sleep in unit tests.
    }

    func postKeyCode(_ keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags, unicodeChars: [UniChar]?) -> Bool {
        recordedEvents.append(.keyCode(keyCode, keyDown: keyDown, flags: flags, chars: unicodeChars))
        if keyDown {
            keyDownCount += 1
            if let limit = unlockAfterKeyDownCount, keyDownCount >= limit {
                locked = false
            }
        }
        return true
    }

    func postFlagsChanged(_ flags: CGEventFlags) -> Bool {
        recordedEvents.append(.flagsChanged(flags))
        return true
    }

    func postUnicodeKey(_ chars: [UniChar], keyDown: Bool) -> Bool {
        recordedEvents.append(.unicode(chars, keyDown: keyDown))
        if keyDown {
            keyDownCount += 1
            if let limit = unlockAfterKeyDownCount, keyDownCount >= limit {
                locked = false
            }
        }
        return true
    }
}

@MainActor
private final class MockAutoUnlockPeerNode: AutoUnlockCoordinatorDelegate {
    let hostId: String
    let coordinator: AutoUnlockProtocolCoordinator
    var isLocked = false
    var autoUnlockEnabled = true
    var accessibilityTrusted = true
    var trustedPairedHosts: Set<String> = []
    var allowedFromPeerHosts: Set<String> = []
    var connectedHosts: Set<String> = []
    var verificationResult: PasswordVerificationResult = .valid
    var unlockOutcome: ScreenUnlockOutcome = .unlocked

    var sentMessages: [(target: String, type: MsgType, infoDict: [AnyHashable: Any])] = []
    var wakeRequests: [String] = []
    var verifyCallCount = 0
    var performUnlockCallCount = 0
    var cancelledUnlockCount = 0
    var loggedEvents: [(level: AutoUnlockLogLevel, title: String, action: AutoUnlockLogAction?)] = []

    /// Optional message interceptor for replay/tamper/drop testing.
    var routeHandler: ((_ from: String, _ to: String, _ type: MsgType, _ infoDict: [AnyHashable: Any]) -> Void)?

    init(hostId: String, store: UnlockCredentialStore, clock: @escaping () -> TimeInterval) {
        self.hostId = hostId
        self.coordinator = AutoUnlockProtocolCoordinator(credentialStore: store, clock: clock)
        self.coordinator.delegate = self
    }

    var localHostId: String { hostId }
    func isLocalScreenLocked() -> Bool { isLocked }
    func isAutoUnlockEnabled() -> Bool { autoUnlockEnabled }
    func isAccessibilityTrusted() -> Bool { accessibilityTrusted }
    func isPeerTrustedAndPaired(_ hostId: String) -> Bool { trustedPairedHosts.contains(hostId) }
    func isAutoUnlockAllowedFromPeer(_ hostId: String) -> Bool { allowedFromPeerHosts.contains(hostId) }
    func isHostConnected(_ hostId: String) -> Bool { connectedHosts.contains(hostId) }
    func peerDisplayName(_ hostId: String) -> String { hostId }

    func sendAutoUnlockMessage(_ type: MsgType, infoDict: [AnyHashable: Any], to targetHostId: String) {
        sentMessages.append((targetHostId, type, infoDict))
        routeHandler?(hostId, targetHostId, type, infoDict)
    }

    func requestWakeAndReconnect(to hostId: String) {
        wakeRequests.append(hostId)
    }

    func verifyLocalPassword(_ password: String, completion: @escaping @MainActor @Sendable (PasswordVerificationResult) -> Void) {
        verifyCallCount += 1
        completion(verificationResult)
    }

    func performScreenUnlock(password: String, completion: @escaping @MainActor @Sendable (ScreenUnlockOutcome) -> Void) {
        performUnlockCallCount += 1
        if unlockOutcome == .unlocked {
            isLocked = false
        }
        completion(unlockOutcome)
    }

    func cancelActiveScreenUnlock() {
        cancelledUnlockCount += 1
    }

    func logAutoUnlockEvent(
        level: AutoUnlockLogLevel,
        title: String,
        detail: String?,
        howToFix: String?,
        hostId: String?,
        action: AutoUnlockLogAction?
    ) {
        loggedEvents.append((level, title, action))
    }
}

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("unimacs-autounlock-test-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func posixPermissions(at url: URL) -> Int? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.posixPermissions] as? NSNumber)?.intValue
}

// MARK: - Test Runner

@main
struct AutoUnlockTestRunner {
    @MainActor
    static func main() {
        print("=== Running Unimacs Auto-Unlock Unit Tests ===")

        // 1. UnlockCredentialStore tests
        runTest("testCredentialStoreRoundTripFreshNonceAndPermissions") {
            let dir = try makeTempDir("store-roundtrip")
            defer { try? FileManager.default.removeItem(at: dir) }

            let store = UnlockCredentialStore(
                directoryURL: dir,
                platformUUIDProvider: { "HW-UUID-1" },
                uidProvider: { 501 },
                usernameProvider: { "alice" },
                postNotifications: false
            )

            assertFalse(store.hasSavedPassword)
            assertFalse(store.isPasswordInvalid)
            let initialLoaded = try store.loadPassword()
            assertNil(initialLoaded)

            // Empty password must be rejected
            assertThrows("Empty password should fail") {
                try store.savePassword("")
            }
            assertFalse(store.hasSavedPassword)

            let passwords = [
                "SimpleASCII!23",
                "密码🔐P@ssw0rd_éñ",
                String(repeating: "Ab3$Xy9!", count: 32)
            ]

            for pwd in passwords {
                try store.savePassword(pwd)
                assertTrue(store.hasSavedPassword)
                assertFalse(store.isPasswordInvalid)
                let loaded = try store.loadPassword()
                assertEqual(loaded, pwd)
            }

            // Fresh nonce check: saving the exact same password produces distinct ciphertext bytes
            let credURL = dir.appendingPathComponent("unlock_credential.json")
            let masterURL = dir.appendingPathComponent("master.key")
            try store.savePassword("SameSecret#42")
            let firstBytes = try Data(contentsOf: credURL)
            try store.savePassword("SameSecret#42")
            let secondBytes = try Data(contentsOf: credURL)
            assertNotEqual(firstBytes, secondBytes, "Each save must use a fresh random AES-GCM nonce")

            // Verify POSIX 0700 dir / 0600 files / Time Machine exclusion
            assertEqual(posixPermissions(at: dir), 0o700)
            assertEqual(posixPermissions(at: masterURL), 0o600)
            assertEqual(posixPermissions(at: credURL), 0o600)
            let resVals = try credURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
            assertEqual(resVals.isExcludedFromBackup, true)

            // Mark invalid and recover
            store.markPasswordInvalid()
            assertTrue(store.hasSavedPassword)
            assertTrue(store.isPasswordInvalid)
            try store.savePassword("UpdatedSecret#42")
            assertFalse(store.isPasswordInvalid)

            // Delete
            store.deletePassword()
            assertFalse(store.hasSavedPassword)
            assertFalse(store.isPasswordInvalid)
            let deletedLoaded = try store.loadPassword()
            assertNil(deletedLoaded)
        }

        runTest("testCredentialStoreHardwareAndAccountBindingAndTamperResilience") {
            let dir = try makeTempDir("store-binding")
            defer { try? FileManager.default.removeItem(at: dir) }

            let primary = UnlockCredentialStore(
                directoryURL: dir,
                platformUUIDProvider: { "HW-UUID-A" },
                uidProvider: { 501 },
                usernameProvider: { "alice" },
                postNotifications: false
            )
            try primary.savePassword("SecretPassword!")
            let peerSecret = Data(repeating: 0xAB, count: 32)
            try primary.savePeerSecret(peerSecret, for: "Peer Mac / 1 🔐 \"test\"")
            assertEqual(primary.loadPeerSecret(for: "Peer Mac / 1 🔐 \"test\""), peerSecret)

            let wrongUUID = UnlockCredentialStore(
                directoryURL: dir,
                platformUUIDProvider: { "HW-UUID-B" },
                uidProvider: { 501 },
                usernameProvider: { "alice" },
                postNotifications: false
            )
            assertFalse(wrongUUID.hasSavedPassword)
            assertThrows { _ = try wrongUUID.loadPassword() }
            assertNil(wrongUUID.loadPeerSecret(for: "Peer Mac / 1 🔐 \"test\""))

            let wrongUID = UnlockCredentialStore(
                directoryURL: dir,
                platformUUIDProvider: { "HW-UUID-A" },
                uidProvider: { 502 },
                usernameProvider: { "alice" },
                postNotifications: false
            )
            assertFalse(wrongUID.hasSavedPassword)
            assertThrows { _ = try wrongUID.loadPassword() }

            let wrongUser = UnlockCredentialStore(
                directoryURL: dir,
                platformUUIDProvider: { "HW-UUID-A" },
                uidProvider: { 501 },
                usernameProvider: { "bob" },
                postNotifications: false
            )
            assertFalse(wrongUser.hasSavedPassword)
            assertThrows { _ = try wrongUser.loadPassword() }

            // Corrupt credential ciphertext
            let credURL = dir.appendingPathComponent("unlock_credential.json")
            try Data("corrupted-json".utf8).write(to: credURL)
            assertFalse(primary.hasSavedPassword)
            assertThrows { _ = try primary.loadPassword() }

            // Corrupt master.key -> read fails safely, fresh write heals cleanly
            let masterURL = dir.appendingPathComponent("master.key")
            try Data([0x01, 0x02, 0x03]).write(to: masterURL)
            assertFalse(primary.hasSavedPassword)
            assertNil(primary.loadPeerSecret(for: "Peer Mac / 1 🔐 \"test\""))
            try primary.savePassword("RecoveredPassword!")
            assertTrue(primary.hasSavedPassword)
            let recovered = try primary.loadPassword()
            assertEqual(recovered, "RecoveredPassword!")

            // Peer secret validation & removal
            assertThrows("Empty hostId rejected") {
                try primary.savePeerSecret(peerSecret, for: "")
            }
            assertThrows("Wrong secret length rejected") {
                try primary.savePeerSecret(Data(repeating: 0x01, count: 16), for: "Mac-B")
            }
            try primary.savePeerSecret(peerSecret, for: "Mac-B")
            assertTrue(primary.hasPeerSecret(for: "Mac-B"))
            primary.removePeerSecret(for: "Mac-B")
            assertFalse(primary.hasPeerSecret(for: "Mac-B"))
        }

        // 2. AutoUnlockCrypto tests
        runTest("testAutoUnlockCryptoKeyAgreementAndChallengeHMAC") {
            let privA = AutoUnlockCrypto.generateKeyPair()
            let privB = AutoUnlockCrypto.generateKeyPair()

            let secretAB = try AutoUnlockCrypto.derivePeerSecret(
                privateKey: privA,
                peerPublicKeyBytes: Data(privB.publicKey.rawRepresentation),
                localHostId: "Alpha-Mac",
                remoteHostId: "Beta-Mac"
            )
            let secretBA = try AutoUnlockCrypto.derivePeerSecret(
                privateKey: privB,
                peerPublicKeyBytes: Data(privA.publicKey.rawRepresentation),
                localHostId: "Beta-Mac",
                remoteHostId: "Alpha-Mac"
            )
            assertEqual(secretAB.count, 32)
            assertEqual(secretAB, secretBA)
            assertEqual(AutoUnlockCrypto.keyId(for: secretAB), AutoUnlockCrypto.keyId(for: secretBA))
            assertEqual(AutoUnlockCrypto.keyId(for: secretAB).count, 16)

            // Invalid public keys rejected
            assertThrows { _ = try AutoUnlockCrypto.derivePeerSecret(privateKey: privA, peerPublicKeyBytes: Data(), localHostId: "A", remoteHostId: "B") }
            assertThrows { _ = try AutoUnlockCrypto.derivePeerSecret(privateKey: privA, peerPublicKeyBytes: Data(repeating: 0, count: 31), localHostId: "A", remoteHostId: "B") }
            assertThrows { _ = try AutoUnlockCrypto.derivePeerSecret(privateKey: privA, peerPublicKeyBytes: Data(repeating: 0, count: 32), localHostId: "A", remoteHostId: "B") }

            let nonce1 = try AutoUnlockCrypto.generateNonce()
            let nonce2 = try AutoUnlockCrypto.generateNonce()
            assertEqual(nonce1.count, 32)
            assertEqual(nonce2.count, 32)
            assertNotEqual(nonce1, nonce2)

            let hmac = try AutoUnlockCrypto.computeChallengeHMAC(
                secret: secretAB,
                requestId: "req-123",
                nonce: nonce1,
                requesterHostId: "Alpha-Mac",
                targetHostId: "Beta-Mac"
            )
            assertEqual(hmac.count, 32)
            assertTrue(
                AutoUnlockCrypto.verifyChallengeHMAC(
                    hmac,
                    secret: secretBA,
                    requestId: "req-123",
                    nonce: nonce1,
                    requesterHostId: "Alpha-Mac",
                    targetHostId: "Beta-Mac"
                )
            )

            // Negative verification checks
            var wrongSecret = secretBA
            wrongSecret[0] ^= 0xFF
            assertFalse(AutoUnlockCrypto.verifyChallengeHMAC(hmac, secret: wrongSecret, requestId: "req-123", nonce: nonce1, requesterHostId: "Alpha-Mac", targetHostId: "Beta-Mac"))
            assertFalse(AutoUnlockCrypto.verifyChallengeHMAC(hmac, secret: secretBA, requestId: "req-999", nonce: nonce1, requesterHostId: "Alpha-Mac", targetHostId: "Beta-Mac"))
            var flippedNonce = nonce1
            flippedNonce[5] ^= 0x01
            assertFalse(AutoUnlockCrypto.verifyChallengeHMAC(hmac, secret: secretBA, requestId: "req-123", nonce: flippedNonce, requesterHostId: "Alpha-Mac", targetHostId: "Beta-Mac"))
            // Swapped sender/target reflection check
            assertFalse(AutoUnlockCrypto.verifyChallengeHMAC(hmac, secret: secretBA, requestId: "req-123", nonce: nonce1, requesterHostId: "Beta-Mac", targetHostId: "Alpha-Mac"))
            assertFalse(AutoUnlockCrypto.verifyChallengeHMAC(Data(), secret: secretBA, requestId: "req-123", nonce: nonce1, requesterHostId: "Alpha-Mac", targetHostId: "Beta-Mac"))
        }

        // 3. AutoUnlockProtocolCoordinator tests
        runTest("testCoordinatorSimultaneousKeyExchangeAndLockedRejection") {
            let dirA = try makeTempDir("nodeA-kx")
            let dirB = try makeTempDir("nodeB-kx")
            defer {
                try? FileManager.default.removeItem(at: dirA)
                try? FileManager.default.removeItem(at: dirB)
            }

            let storeA = UnlockCredentialStore(directoryURL: dirA, platformUUIDProvider: { "UUID-A" }, postNotifications: false)
            let storeB = UnlockCredentialStore(directoryURL: dirB, platformUUIDProvider: { "UUID-B" }, postNotifications: false)
            let now: TimeInterval = 1000.0
            let nodeA = MockAutoUnlockPeerNode(hostId: "Alpha-Mac", store: storeA, clock: { now })
            let nodeB = MockAutoUnlockPeerNode(hostId: "Beta-Mac", store: storeB, clock: { now })

            nodeA.trustedPairedHosts = ["Beta-Mac"]
            nodeA.allowedFromPeerHosts = ["Beta-Mac"]
            nodeA.connectedHosts = ["Beta-Mac"]

            nodeB.trustedPairedHosts = ["Alpha-Mac"]
            nodeB.allowedFromPeerHosts = ["Alpha-Mac"]
            nodeB.connectedHosts = ["Alpha-Mac"]

            // Locked screen must refuse key exchange
            nodeB.isLocked = true
            nodeA.routeHandler = { from, _, type, info in
                nodeB.coordinator.handleMessage(type, infoDict: info, from: from)
            }
            nodeB.routeHandler = { from, _, type, info in
                nodeA.coordinator.handleMessage(type, infoDict: info, from: from)
            }
            nodeA.coordinator.initiateKeyExchange(with: "Beta-Mac")
            assertFalse(storeA.hasPeerSecret(for: "Beta-Mac"))
            assertFalse(storeB.hasPeerSecret(for: "Alpha-Mac"))

            // Simultaneous initiation while both unlocked (buffered delivery so both emit Init before processing)
            nodeB.isLocked = false
            var queued: [(to: String, from: String, type: MsgType, info: [AnyHashable: Any])] = []
            nodeA.routeHandler = { from, to, type, info in queued.append((to, from, type, info)) }
            nodeB.routeHandler = { from, to, type, info in queued.append((to, from, type, info)) }

            nodeA.coordinator.initiateKeyExchange(with: "Beta-Mac", force: true)
            nodeB.coordinator.initiateKeyExchange(with: "Alpha-Mac", force: true)

            while !queued.isEmpty {
                let msg = queued.removeFirst()
                if msg.to == "Beta-Mac" {
                    nodeB.coordinator.handleMessage(msg.type, infoDict: msg.info, from: msg.from)
                } else {
                    nodeA.coordinator.handleMessage(msg.type, infoDict: msg.info, from: msg.from)
                }
            }

            assertTrue(storeA.hasPeerSecret(for: "Beta-Mac"))
            assertTrue(storeB.hasPeerSecret(for: "Alpha-Mac"))
            assertEqual(storeA.loadPeerSecret(for: "Beta-Mac"), storeB.loadPeerSecret(for: "Alpha-Mac"))
        }

        runTest("testCoordinatorUnlockFlowReplayExpiryLoopSuppressionAndCircuitBreaker") {
            let dirA = try makeTempDir("nodeA-flow")
            let dirB = try makeTempDir("nodeB-flow")
            defer {
                try? FileManager.default.removeItem(at: dirA)
                try? FileManager.default.removeItem(at: dirB)
            }

            let storeA = UnlockCredentialStore(directoryURL: dirA, platformUUIDProvider: { "UUID-A" }, postNotifications: false)
            let storeB = UnlockCredentialStore(directoryURL: dirB, platformUUIDProvider: { "UUID-B" }, postNotifications: false)
            try storeB.savePassword("MacB-Pass!99")

            var currentTime: TimeInterval = 5000.0
            let nodeA = MockAutoUnlockPeerNode(hostId: "Alpha-Mac", store: storeA, clock: { currentTime })
            let nodeB = MockAutoUnlockPeerNode(hostId: "Beta-Mac", store: storeB, clock: { currentTime })

            nodeA.trustedPairedHosts = ["Beta-Mac"]
            nodeA.allowedFromPeerHosts = ["Beta-Mac"]
            nodeA.connectedHosts = ["Beta-Mac"]

            nodeB.trustedPairedHosts = ["Alpha-Mac"]
            nodeB.allowedFromPeerHosts = ["Alpha-Mac"]
            nodeB.connectedHosts = ["Alpha-Mac"]

            var capturedResponse: [AnyHashable: Any]? = nil
            nodeA.routeHandler = { from, _, type, info in
                if type == .autoUnlockResponse {
                    capturedResponse = info
                }
                nodeB.coordinator.handleMessage(type, infoDict: info, from: from)
            }
            nodeB.routeHandler = { from, _, type, info in
                nodeA.coordinator.handleMessage(type, infoDict: info, from: from)
            }

            // Key exchange first
            nodeA.coordinator.initiateKeyExchange(with: "Beta-Mac")
            assertTrue(storeA.hasPeerSecret(for: "Beta-Mac"))

            // 1. Happy path: Mac B locked -> Mac A unlocks -> Mac B unlocks
            nodeB.isLocked = true
            nodeA.isLocked = false
            nodeA.coordinator.handleLocalScreenUnlocked(
                wasPreviouslyLocked: true,
                connectedEligibleHostIds: ["Beta-Mac"],
                disconnectedEligibleHostIds: []
            )
            assertEqual(nodeB.verifyCallCount, 1)
            assertEqual(nodeB.performUnlockCallCount, 1)
            assertFalse(nodeB.isLocked)

            // 2. Loop suppression: Mac B receives local unlock notification right after remote-triggered unlock
            nodeA.isLocked = true
            nodeB.coordinator.handleLocalScreenUnlocked(
                wasPreviouslyLocked: true,
                connectedEligibleHostIds: ["Alpha-Mac"],
                disconnectedEligibleHostIds: []
            )
            assertEqual(nodeA.verifyCallCount, 0, "Mac B must not propagate unlock back to Mac A during cooldown")
            assertEqual(nodeA.performUnlockCallCount, 0)

            // 3. Single-use nonce replay rejection
            nodeB.isLocked = true
            if let capturedResponse = capturedResponse {
                nodeB.coordinator.handleMessage(.autoUnlockResponse, infoDict: capturedResponse, from: "Alpha-Mac")
            } else {
                assertTrue(false, "Expected captured .autoUnlockResponse")
            }
            assertEqual(nodeB.performUnlockCallCount, 1, "Replayed response must not trigger unlock")

            // 4. Expired challenge rejection (> 10s TTL)
            nodeA.routeHandler = { from, _, type, info in
                if type == .autoUnlockResponse {
                    currentTime += 11.0
                }
                nodeB.coordinator.handleMessage(type, infoDict: info, from: from)
            }
            nodeA.isLocked = false
            nodeB.isLocked = true
            nodeA.coordinator.handleLocalScreenUnlocked(
                wasPreviouslyLocked: true,
                connectedEligibleHostIds: ["Beta-Mac"],
                disconnectedEligibleHostIds: []
            )
            assertEqual(nodeB.performUnlockCallCount, 1, "Expired challenge response must not trigger unlock")

            // 5. Sender re-locked before challenge arrives
            nodeA.routeHandler = { from, _, type, info in
                nodeB.coordinator.handleMessage(type, infoDict: info, from: from)
            }
            nodeB.routeHandler = { from, _, type, info in
                if type == .autoUnlockChallenge {
                    nodeA.isLocked = true
                }
                nodeA.coordinator.handleMessage(type, infoDict: info, from: from)
            }
            let sentBefore = nodeA.sentMessages.count
            nodeA.isLocked = false
            nodeA.coordinator.handleLocalScreenUnlocked(
                wasPreviouslyLocked: true,
                connectedEligibleHostIds: ["Beta-Mac"],
                disconnectedEligibleHostIds: []
            )
            let sentAfter = nodeA.sentMessages.dropFirst(sentBefore)
            assertFalse(sentAfter.contains(where: { $0.type == .autoUnlockResponse }), "Locked requester must not sign challenge")

            // Restore normal routing
            nodeB.routeHandler = { from, _, type, info in
                nodeA.coordinator.handleMessage(type, infoDict: info, from: from)
            }

            // 6. Circuit breaker: 2 failed attempts pause auto-unlock, manual unlock resets
            nodeA.isLocked = false
            nodeB.isLocked = true
            nodeB.unlockOutcome = .timedOutStillLocked
            for _ in 0..<2 {
                nodeA.coordinator.handleLocalScreenUnlocked(
                    wasPreviouslyLocked: true,
                    connectedEligibleHostIds: ["Beta-Mac"],
                    disconnectedEligibleHostIds: []
                )
            }
            assertEqual(nodeB.coordinator.consecutiveFailures, 2)
            let callsAtBreakerTrip = nodeB.performUnlockCallCount
            nodeA.coordinator.handleLocalScreenUnlocked(
                wasPreviouslyLocked: true,
                connectedEligibleHostIds: ["Beta-Mac"],
                disconnectedEligibleHostIds: []
            )
            assertEqual(nodeB.performUnlockCallCount, callsAtBreakerTrip, "Circuit breaker must block 3rd attempt")

            // Manual unlock on Mac B resets circuit breaker
            currentTime += 20.0
            nodeB.isLocked = false
            nodeB.coordinator.handleLocalScreenUnlocked(
                wasPreviouslyLocked: true,
                connectedEligibleHostIds: [],
                disconnectedEligibleHostIds: []
            )
            assertEqual(nodeB.coordinator.consecutiveFailures, 0)

            // 7. Invalid OpenDirectory pre-check aborts with ZERO keystrokes typed and marks credential invalid
            nodeB.isLocked = true
            nodeB.verificationResult = .invalidCredentials
            let unlockCallsBeforeInvalid = nodeB.performUnlockCallCount
            nodeA.coordinator.handleLocalScreenUnlocked(
                wasPreviouslyLocked: true,
                connectedEligibleHostIds: ["Beta-Mac"],
                disconnectedEligibleHostIds: []
            )
            assertEqual(nodeB.performUnlockCallCount, unlockCallsBeforeInvalid, "Invalid OD pre-check must abort before typing")
            assertTrue(storeB.isPasswordInvalid)

            // 8. Already-unlocked short-circuit
            try storeB.savePassword("MacB-Pass!99")
            nodeB.verificationResult = .valid
            nodeB.unlockOutcome = .unlocked
            nodeB.isLocked = false
            let unlockCallsBeforeAlreadyUnlocked = nodeB.performUnlockCallCount
            nodeA.coordinator.handleLocalScreenUnlocked(
                wasPreviouslyLocked: true,
                connectedEligibleHostIds: ["Beta-Mac"],
                disconnectedEligibleHostIds: []
            )
            assertEqual(nodeB.performUnlockCallCount, unlockCallsBeforeAlreadyUnlocked)

            // 9. Pending unlock intent window (15s) on reconnect + expiry
            nodeA.connectedHosts = []
            nodeB.connectedHosts = []
            nodeB.isLocked = true
            nodeA.coordinator.handleLocalScreenUnlocked(
                wasPreviouslyLocked: true,
                connectedEligibleHostIds: [],
                disconnectedEligibleHostIds: ["Beta-Mac"]
            )
            assertEqual(nodeA.wakeRequests, ["Beta-Mac"])
            assertTrue(nodeA.coordinator.hasPendingUnlockIntent(for: "Beta-Mac"))

            currentTime += 5.0
            nodeA.connectedHosts = ["Beta-Mac"]
            nodeB.connectedHosts = ["Alpha-Mac"]
            nodeA.coordinator.handleConnectionEstablished(to: "Beta-Mac", isEligible: true)
            assertFalse(nodeB.isLocked, "Pending unlock intent within 15s must unlock on connection establishment")

            // Expired intent (> 15s)
            nodeA.connectedHosts = []
            nodeB.connectedHosts = []
            nodeB.isLocked = true
            nodeA.coordinator.handleLocalScreenUnlocked(
                wasPreviouslyLocked: true,
                connectedEligibleHostIds: [],
                disconnectedEligibleHostIds: ["Beta-Mac"]
            )
            currentTime += 16.0
            assertFalse(nodeA.coordinator.hasPendingUnlockIntent(for: "Beta-Mac"))
            nodeA.connectedHosts = ["Beta-Mac"]
            nodeB.connectedHosts = ["Alpha-Mac"]
            let callsBeforeExpiredReconnect = nodeB.performUnlockCallCount
            nodeA.coordinator.handleConnectionEstablished(to: "Beta-Mac", isEligible: true)
            assertEqual(nodeB.performUnlockCallCount, callsBeforeExpiredReconnect, "Expired pending intent must not unlock")

            // 10. Key mismatch clears stale secret on requester and re-syncs once both Macs are unlocked
            try storeB.savePeerSecret(Data(repeating: 0x33, count: 32), for: "Alpha-Mac")
            nodeB.isLocked = true
            nodeA.isLocked = false
            nodeA.coordinator.handleLocalScreenUnlocked(
                wasPreviouslyLocked: true,
                connectedEligibleHostIds: ["Beta-Mac"],
                disconnectedEligibleHostIds: []
            )
            assertFalse(storeA.hasPeerSecret(for: "Beta-Mac"), "Requester must clear mismatched peer secret")
            nodeB.isLocked = false
            nodeA.coordinator.initiateKeyExchange(with: "Beta-Mac", force: true)
            assertTrue(storeA.hasPeerSecret(for: "Beta-Mac"))
            assertEqual(storeA.loadPeerSecret(for: "Beta-Mac"), storeB.loadPeerSecret(for: "Alpha-Mac"))
        }

        // 4. ScreenUnlocker tests
        runTest("testScreenUnlockerKeyMappingAndLiveLockGuardAbort") {
            let ansiMap = ScreenUnlocker.usANSIKeyboardFallbackMap()
            let allPrintableASCII = String((0x20...0x7E).compactMap { UnicodeScalar($0).map(Character.init) })
            let asciiStrokes = ScreenUnlocker.resolveKeyStrokes(for: allPrintableASCII, keyboardMap: ansiMap)
            assertEqual(asciiStrokes.count, 95)

            for stroke in asciiStrokes {
                switch stroke {
                case .keyCode(_, let flags, _):
                    assertFalse(flags.contains(.maskAlphaShift), "Resolved stroke must never include Caps Lock flag")
                case .unicode:
                    assertTrue(false, "All printable ASCII characters must map to keyCode specs")
                }
            }

            let unicodeStrokes = ScreenUnlocker.resolveKeyStrokes(for: "a密码🔐Z", keyboardMap: ansiMap)
            assertEqual(unicodeStrokes.count, 5)
            if case .unicode = unicodeStrokes[1] { } else { assertTrue(false, "Non-ASCII char must use .unicode") }
            if case .unicode = unicodeStrokes[2] { } else { assertTrue(false, "Second CJK char must use .unicode") }
            if case .unicode = unicodeStrokes[3] { } else { assertTrue(false, "Emoji must use .unicode") }

            // Live lock-state guard: simulate unlocking mid-password after clearing + 2 chars
            let driver = MockScreenUnlockDriver()
            driver.displayAsleep = true
            // 3 clear presses (Delete, Cmd+A, Delete) + 2 typed chars = 5 keyDowns
            driver.unlockAfterKeyDownCount = 5
            let token = ScreenUnlockCancellationToken()
            let longStrokes = ScreenUnlocker.resolveKeyStrokes(for: "0123456789", keyboardMap: ansiMap)

            let outcome = ScreenUnlocker.performUnlock(keyStrokes: longStrokes, cancellationToken: token, driver: driver)
            assertEqual(outcome, .alreadyUnlocked)

            let keyDownCodes = driver.recordedEvents.compactMap { event -> CGKeyCode? in
                if case .keyCode(let code, let down, _, _) = event, down {
                    return code
                }
                return nil
            }
            assertEqual(keyDownCodes.count, 5, "Must abort immediately upon unlock and emit no trailing chars or Return")
            assertFalse(keyDownCodes.contains(0x24), "Must not emit Return key after session unlocks")

            // Cancellation token abort
            let cancelDriver = MockScreenUnlockDriver()
            let cancelledToken = ScreenUnlockCancellationToken()
            cancelledToken.cancel()
            assertEqual(
                ScreenUnlocker.performUnlock(keyStrokes: longStrokes, cancellationToken: cancelledToken, driver: cancelDriver),
                .cancelled
            )
            assertTrue(cancelDriver.recordedEvents.isEmpty)
        }

        // 5. WakeOnLanSender & NetworkInterfaceInfo broadcast tests
        runTest("testWakeOnLanMagicPacketAndBroadcastAddresses") {
            let macBytes: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
            let packet = WakeOnLanSender.buildMagicPacket(macBytes: macBytes)
            assertNotNil(packet)
            if let packet = packet {
                assertEqual(packet.count, 102)
                assertEqual(Array(packet.prefix(6)), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
                for idx in 0..<16 {
                    let start = 6 + idx * 6
                    assertEqual(Array(packet[start..<(start + 6)]), macBytes)
                }
            }

            // Invalid MAC rejections
            assertNil(WakeOnLanSender.buildMagicPacket(macBytes: []))
            assertNil(WakeOnLanSender.buildMagicPacket(macBytes: [0xAA, 0xBB, 0xCC]))
            assertNil(WakeOnLanSender.buildMagicPacket(macBytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
            assertNil(WakeOnLanSender.parseMacAddress("invalid-mac"))
            assertEqual(WakeOnLanSender.parseMacAddress("aa:bb:cc:dd:ee:ff"), macBytes)

            // Subnet broadcast computation
            let iface24 = NetworkInterfaceInfo(name: "en0", ipAddress: "192.168.1.42", subnetMask: "255.255.255.0")
            assertEqual(iface24.broadcastAddress, "192.168.1.255")

            let iface23 = NetworkInterfaceInfo(name: "en0", ipAddress: "10.2.132.50", subnetMask: "255.255.254.0")
            assertEqual(iface23.broadcastAddress, "10.2.133.255")

            let zeroMask = NetworkInterfaceInfo(name: "en0", ipAddress: "192.168.1.42", subnetMask: "0.0.0.0")
            assertNil(zeroMask.broadcastAddress)

            let invalidIP = NetworkInterfaceInfo(name: "en0", ipAddress: "999.168.1.42", subnetMask: "255.255.255.0")
            assertNil(invalidIP.broadcastAddress)
        }

        print("=== Test Summary: \(totalTestsRun) tests (\(totalAssertions) assertions), \(failedTests.count) failures ===")
        if !failedTests.isEmpty {
            exit(1)
        }
    }
}
