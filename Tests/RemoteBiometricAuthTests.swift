// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import Cocoa
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

private final class MockPromptDriver: ScreenUnlockingDriver, @unchecked Sendable {
    enum RecordedEvent: Equatable {
        case wake
        case keyCode(CGKeyCode, keyDown: Bool, flags: CGEventFlags, chars: [UniChar]?)
        case flagsChanged(CGEventFlags)
        case unicode([UniChar], keyDown: Bool)
    }

    var locked = false
    var promptActive = true
    var closePromptAfterKeyDownCount: Int? = nil
    var lockAfterKeyDownCount: Int? = nil
    var recordedEvents: [RecordedEvent] = []
    private var keyDownCount = 0

    func wakeUpScreen() {
        recordedEvents.append(.wake)
    }

    func isDisplayAsleep() -> Bool {
        false
    }

    func isScreenLockedLive() -> Bool {
        locked
    }

    func isPasswordPromptActiveLive(_ kind: PasswordPromptKind) -> Bool {
        promptActive
    }

    func sleep(milliseconds: UInt64) {
        // No wall-clock sleep in unit tests.
    }

    func postKeyCode(_ keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags, unicodeChars: [UniChar]?) -> Bool {
        recordedEvents.append(.keyCode(keyCode, keyDown: keyDown, flags: flags, chars: unicodeChars))
        if keyDown {
            keyDownCount += 1
            if let limit = closePromptAfterKeyDownCount, keyDownCount >= limit {
                promptActive = false
            }
            if let lockLimit = lockAfterKeyDownCount, keyDownCount >= lockLimit {
                locked = true
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
            if let limit = closePromptAfterKeyDownCount, keyDownCount >= limit {
                promptActive = false
            }
            if let lockLimit = lockAfterKeyDownCount, keyDownCount >= lockLimit {
                locked = true
            }
        }
        return true
    }
}

@MainActor
private final class MockBiometricPeerNode: RemoteBiometricAuthCoordinatorDelegate {
    let hostId: String
    let store: UnlockCredentialStore
    let coordinator: RemoteBiometricAuthCoordinator

    var isLocked = false
    var biometricAuthEnabled = true
    var accessibilityTrusted = true
    var trustedPairedHosts: Set<String> = []
    var biometricCapableHosts: Set<String> = []
    var connectedHosts: Set<String> = []
    var controllingHostId: String? = nil
    var controlledByHostId: String? = nil

    var currentAutoPrompt: DetectedPasswordPrompt? = nil
    var currentManualPrompt: DetectedPasswordPrompt? = nil
    var activePromptKinds: Set<PasswordPromptKind> = []

    var availability: BiometricAvailability = .available
    var nextBiometricResult: BiometricEvaluationResult = .authenticated
    var deferBiometricCompletion = false
    var pendingBiometricCompletion: (@MainActor @Sendable (BiometricEvaluationResult) -> Void)? = nil

    var verificationResult: PasswordVerificationResult = .valid
    var autofillOutcome: PromptAutofillOutcome = .typedAndSubmitted

    var sentMessages: [(target: String, type: MsgType, infoDict: [AnyHashable: Any])] = []
    var evaluateBiometricsCallCount = 0
    var cancelledBiometricsCount = 0
    var keyExchangeRequests: [(hostId: String, force: Bool)] = []
    var verifyCallCount = 0
    var performAutofillCallCount = 0
    var lastAutofillKind: PasswordPromptKind? = nil
    var cancelledAutofillCount = 0
    var bezelNotifications: [(title: String, subtitle: String, isWarning: Bool)] = []
    var loggedEvents: [(level: AutoUnlockLogLevel, title: String, action: AutoUnlockLogAction?)] = []
    var evaluationStateHistory: [Bool] = []
    var prepareForegroundCount = 0
    var restoreForegroundCount = 0
    var isForegroundCurrentlyYielded = false
    var foregroundYieldedAtEvaluateStart: [Bool] = []
    var autoRefocusSuppressedAtPrepare: [Bool] = []
    var autoRefocusSuppressedAtEvaluateStart: [Bool] = []
    var autoRefocusSuppressedAtRestore: [Bool] = []
    var bezelWhileYieldedCount = 0

    var routeHandler: ((_ from: String, _ to: String, _ type: MsgType, _ infoDict: [AnyHashable: Any]) -> Void)?

    init(hostId: String, store: UnlockCredentialStore, clock: @escaping () -> TimeInterval) {
        self.hostId = hostId
        self.store = store
        self.coordinator = RemoteBiometricAuthCoordinator(credentialStore: store, clock: clock)
        self.coordinator.delegate = self
        self.coordinator.onEvaluationStateChange = { [weak self] isEvaluating in
            self?.evaluationStateHistory.append(isEvaluating)
        }
    }

    var localHostId: String { hostId }
    var localDisplayName: String { hostId }
    func isLocalScreenLocked() -> Bool { isLocked }
    func isRemoteBiometricAuthEnabled() -> Bool { biometricAuthEnabled }
    func hasLocalSavedPassword() -> Bool { store.hasSavedPassword }
    func isAccessibilityTrusted() -> Bool { accessibilityTrusted }
    func isPeerTrustedAndPaired(_ hostId: String) -> Bool { trustedPairedHosts.contains(hostId) }
    func peerSupportsBiometricAuth(_ hostId: String) -> Bool { biometricCapableHosts.contains(hostId) }
    func isHostConnected(_ hostId: String) -> Bool { connectedHosts.contains(hostId) }
    func isControllingHost(_ hostId: String) -> Bool { controllingHostId == hostId }
    func isBeingControlled(by hostId: String) -> Bool { controlledByHostId == hostId }
    func peerDisplayName(_ hostId: String) -> String { hostId }

    func initiatePeerKeyExchangeIfNeeded(with hostId: String, force: Bool) {
        keyExchangeRequests.append((hostId, force))
    }

    func sendBiometricMessage(_ type: MsgType, infoDict: [AnyHashable: Any], to targetHostId: String) {
        sentMessages.append((targetHostId, type, infoDict))
        routeHandler?(hostId, targetHostId, type, infoDict)
    }

    func detectCurrentPasswordPrompt(allowNonSystemPrompts: Bool) -> DetectedPasswordPrompt? {
        if isLocked { return nil }
        return allowNonSystemPrompts ? (currentManualPrompt ?? currentAutoPrompt) : currentAutoPrompt
    }

    func isPasswordPromptStillActive(_ kind: PasswordPromptKind) -> Bool {
        !isLocked && activePromptKinds.contains(kind)
    }

    func biometricAvailability() -> BiometricAvailability {
        availability
    }

    func prepareControllerForegroundForBiometrics() {
        assertFalse(isForegroundCurrentlyYielded, "prepareControllerForegroundForBiometrics must not double-yield")
        isForegroundCurrentlyYielded = true
        prepareForegroundCount += 1
        autoRefocusSuppressedAtPrepare.append(coordinator.shouldSuppressControllerAutoRefocus)
    }

    func restoreControllerForegroundAfterBiometrics() {
        assertTrue(isForegroundCurrentlyYielded, "restoreControllerForegroundAfterBiometrics must balance a prior yield")
        isForegroundCurrentlyYielded = false
        restoreForegroundCount += 1
        autoRefocusSuppressedAtRestore.append(coordinator.shouldSuppressControllerAutoRefocus)
    }

    func evaluateBiometrics(reason: String, completion: @escaping @MainActor @Sendable (BiometricEvaluationResult) -> Void) {
        evaluateBiometricsCallCount += 1
        foregroundYieldedAtEvaluateStart.append(isForegroundCurrentlyYielded)
        autoRefocusSuppressedAtEvaluateStart.append(coordinator.shouldSuppressControllerAutoRefocus)
        if deferBiometricCompletion {
            pendingBiometricCompletion = completion
        } else {
            completion(nextBiometricResult)
        }
    }

    func finishPendingBiometric(_ result: BiometricEvaluationResult) {
        let cb = pendingBiometricCompletion
        pendingBiometricCompletion = nil
        cb?(result)
    }

    func cancelLocalBiometricEvaluation() {
        cancelledBiometricsCount += 1
        let cb = pendingBiometricCompletion
        pendingBiometricCompletion = nil
        cb?(.userCancelled)
    }

    func verifyLocalPassword(_ password: String, completion: @escaping @MainActor @Sendable (PasswordVerificationResult) -> Void) {
        verifyCallCount += 1
        completion(verificationResult)
    }

    func performPromptAutofill(
        password: String,
        promptKind: PasswordPromptKind,
        completion: @escaping @MainActor @Sendable (PromptAutofillOutcome) -> Void
    ) {
        performAutofillCallCount += 1
        lastAutofillKind = promptKind
        completion(autofillOutcome)
    }

    func cancelActivePromptAutofill() {
        cancelledAutofillCount += 1
    }

    func showBezelNotification(title: String, subtitle: String, isWarning: Bool) {
        if isForegroundCurrentlyYielded {
            bezelWhileYieldedCount += 1
        }
        bezelNotifications.append((title, subtitle, isWarning))
    }

    func logBiometricEvent(
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
        .appendingPathComponent("unimacs-biometric-test-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
private func makePairedNodes(
    dirController: URL,
    dirControlled: URL,
    clock: @escaping () -> TimeInterval
) throws -> (controller: MockBiometricPeerNode, controlled: MockBiometricPeerNode, sharedSecret: Data) {
    let storeA = UnlockCredentialStore(
        directoryURL: dirController,
        platformUUIDProvider: { "UUID-MBP" },
        uidProvider: { 501 },
        usernameProvider: { "benny" },
        postNotifications: false
    )
    let storeB = UnlockCredentialStore(
        directoryURL: dirControlled,
        platformUUIDProvider: { "UUID-MINI" },
        uidProvider: { 501 },
        usernameProvider: { "benny" },
        postNotifications: false
    )

    try storeB.savePassword("MiniLoginPass!99")

    let keyA = AutoUnlockCrypto.generateKeyPair()
    let keyB = AutoUnlockCrypto.generateKeyPair()
    let secretA = try AutoUnlockCrypto.derivePeerSecret(
        privateKey: keyA,
        peerPublicKeyBytes: Data(keyB.publicKey.rawRepresentation),
        localHostId: "MBP",
        remoteHostId: "MINI"
    )
    let secretB = try AutoUnlockCrypto.derivePeerSecret(
        privateKey: keyB,
        peerPublicKeyBytes: Data(keyA.publicKey.rawRepresentation),
        localHostId: "MINI",
        remoteHostId: "MBP"
    )
    assertEqual(secretA, secretB)
    try storeA.savePeerSecret(secretA, for: "MINI")
    try storeB.savePeerSecret(secretB, for: "MBP")

    let controller = MockBiometricPeerNode(hostId: "MBP", store: storeA, clock: clock)
    let controlled = MockBiometricPeerNode(hostId: "MINI", store: storeB, clock: clock)

    controller.trustedPairedHosts = ["MINI"]
    controller.biometricCapableHosts = ["MINI"]
    controller.connectedHosts = ["MINI"]
    controller.controllingHostId = "MINI"

    controlled.trustedPairedHosts = ["MBP"]
    controlled.biometricCapableHosts = ["MBP"]
    controlled.connectedHosts = ["MBP"]
    controlled.controlledByHostId = "MBP"

    let router: @MainActor (String, String, MsgType, [AnyHashable: Any]) -> Void = { sender, target, type, info in
        if target == "MINI" {
            controlled.coordinator.handleMessage(type, infoDict: info, from: sender)
        } else if target == "MBP" {
            controller.coordinator.handleMessage(type, infoDict: info, from: sender)
        }
    }
    controller.routeHandler = router
    controlled.routeHandler = router

    return (controller, controlled, secretA)
}

// MARK: - Test Runner

@main
struct RemoteBiometricAuthTestRunner {
    @MainActor
    static func main() {
        print("=== Running Unimacs Remote Biometric Auth Unit Tests ===")

        // 1. Cryptographic domain separation & tamper resistance
        runTest("testBiometricCryptoDomainSeparationAndTamperRejection") {
            let keyA = AutoUnlockCrypto.generateKeyPair()
            let keyB = AutoUnlockCrypto.generateKeyPair()
            let secret = try AutoUnlockCrypto.derivePeerSecret(
                privateKey: keyA,
                peerPublicKeyBytes: Data(keyB.publicKey.rawRepresentation),
                localHostId: "MBP",
                remoteHostId: "MINI"
            )
            let nonce = try AutoUnlockCrypto.generateNonce()

            let bioHMAC = try AutoUnlockCrypto.computeBiometricChallengeHMAC(
                secret: secret,
                requestId: "req-1",
                nonce: nonce,
                controllerHostId: "MBP",
                targetHostId: "MINI",
                promptKindRaw: PasswordPromptKind.systemDialog.rawValue,
                isManual: false
            )

            assertTrue(
                AutoUnlockCrypto.verifyBiometricChallengeHMAC(
                    bioHMAC,
                    secret: secret,
                    requestId: "req-1",
                    nonce: nonce,
                    controllerHostId: "MBP",
                    targetHostId: "MINI",
                    promptKindRaw: PasswordPromptKind.systemDialog.rawValue,
                    isManual: false
                )
            )

            // Domain separation: auto-unlock screen HMAC must NEVER verify as biometric prompt HMAC and vice versa
            let unlockHMAC = try AutoUnlockCrypto.computeChallengeHMAC(
                secret: secret,
                requestId: "req-1",
                nonce: nonce,
                requesterHostId: "MBP",
                targetHostId: "MINI",
                isManual: false
            )
            assertFalse(
                AutoUnlockCrypto.verifyBiometricChallengeHMAC(
                    unlockHMAC,
                    secret: secret,
                    requestId: "req-1",
                    nonce: nonce,
                    controllerHostId: "MBP",
                    targetHostId: "MINI",
                    promptKindRaw: PasswordPromptKind.systemDialog.rawValue,
                    isManual: false
                ),
                "Screen unlock HMAC must not be accepted for biometric prompt auth"
            )
            assertFalse(
                AutoUnlockCrypto.verifyChallengeHMAC(
                    bioHMAC,
                    secret: secret,
                    requestId: "req-1",
                    nonce: nonce,
                    requesterHostId: "MBP",
                    targetHostId: "MINI",
                    isManual: false
                ),
                "Biometric HMAC must not be accepted for screen unlock"
            )

            // Tamper checks
            assertFalse(
                AutoUnlockCrypto.verifyBiometricChallengeHMAC(
                    bioHMAC,
                    secret: secret,
                    requestId: "req-1",
                    nonce: nonce,
                    controllerHostId: "MBP",
                    targetHostId: "MINI",
                    promptKindRaw: PasswordPromptKind.terminalPassword.rawValue,
                    isManual: false
                ),
                "Changing promptKind must fail HMAC verification"
            )
            assertFalse(
                AutoUnlockCrypto.verifyBiometricChallengeHMAC(
                    bioHMAC,
                    secret: secret,
                    requestId: "req-1",
                    nonce: nonce,
                    controllerHostId: "MBP",
                    targetHostId: "MINI",
                    promptKindRaw: PasswordPromptKind.systemDialog.rawValue,
                    isManual: true
                ),
                "Changing isManual must fail HMAC verification"
            )
            assertFalse(
                AutoUnlockCrypto.verifyBiometricChallengeHMAC(
                    bioHMAC,
                    secret: Data(repeating: 0x11, count: 16),
                    requestId: "req-1",
                    nonce: nonce,
                    controllerHostId: "MBP",
                    targetHostId: "MINI",
                    promptKindRaw: PasswordPromptKind.systemDialog.rawValue,
                    isManual: false
                ),
                "Short secret must be rejected"
            )
            assertThrows("Short secret must throw when signing") {
                _ = try AutoUnlockCrypto.computeBiometricChallengeHMAC(
                    secret: Data(repeating: 0x01, count: 16),
                    requestId: "req-1",
                    nonce: nonce,
                    controllerHostId: "MBP",
                    targetHostId: "MINI",
                    promptKindRaw: PasswordPromptKind.systemDialog.rawValue,
                    isManual: false
                )
            }
        }

        // 2. PasswordPromptClassifier tests
        runTest("testPasswordPromptClassifierSafetyAndTriggers") {
            let securityAgentWindow = DetectedWindowSnapshot(
                windowNumber: 42,
                ownerPID: 901,
                ownerName: "SecurityAgent",
                bundleIdentifier: "com.apple.SecurityAgent",
                bounds: CGRect(x: 400, y: 300, width: 420, height: 220),
                alpha: 1.0,
                layer: 100
            )
            let coreAuthWindow = DetectedWindowSnapshot(
                windowNumber: 77,
                ownerPID: 902,
                ownerName: "coreautha",
                bundleIdentifier: "com.apple.LocalAuthentication.UIAgent",
                bounds: CGRect(x: 400, y: 300, width: 380, height: 180),
                alpha: 1.0,
                layer: 100
            )
            let tinyHiddenSecurityAgent = DetectedWindowSnapshot(
                windowNumber: 12,
                ownerPID: 901,
                ownerName: "SecurityAgent",
                bundleIdentifier: "com.apple.SecurityAgent",
                bounds: CGRect(x: 0, y: 0, width: 20, height: 20),
                alpha: 1.0,
                layer: 100
            )
            let safariWindow = DetectedWindowSnapshot(
                windowNumber: 100,
                ownerPID: 500,
                ownerName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                bounds: CGRect(x: 0, y: 0, width: 1200, height: 800),
                alpha: 1.0,
                layer: 0
            )

            // Locked screen always returns nil
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: true,
                    isSecureInputEnabled: true,
                    windows: [securityAgentWindow],
                    frontmostBundleId: "com.apple.SecurityAgent",
                    frontmostOwnerName: "SecurityAgent",
                    hasTerminalPasswordPrompt: true,
                    allowNonSystemPrompts: true
                )
            )

            // Auto-detection matches genuine SecurityAgent / coreautha when Secure Input is on
            let autoSys = PasswordPromptClassifier.classify(
                isScreenLocked: false,
                isSecureInputEnabled: true,
                windows: [safariWindow, tinyHiddenSecurityAgent, securityAgentWindow],
                frontmostBundleId: "com.apple.SecurityAgent",
                frontmostOwnerName: "SecurityAgent",
                hasTerminalPasswordPrompt: false,
                allowNonSystemPrompts: false
            )
            assertEqual(autoSys, DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:42"))

            let autoCoreAuth = PasswordPromptClassifier.classify(
                isScreenLocked: false,
                isSecureInputEnabled: true,
                windows: [coreAuthWindow],
                frontmostBundleId: "com.apple.LocalAuthentication.UIAgent",
                frontmostOwnerName: "coreautha",
                hasTerminalPasswordPrompt: false,
                allowNonSystemPrompts: false
            )
            assertEqual(autoCoreAuth, DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:902:77"))

            // Auto-detection ignores SecurityAgent if Secure Event Input is false
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: false,
                    windows: [securityAgentWindow],
                    frontmostBundleId: "com.apple.SecurityAgent",
                    frontmostOwnerName: "SecurityAgent",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: false
                )
            )

            // Auto-detection ignores non-system secure fields and terminal sudo
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: true,
                    windows: [safariWindow],
                    frontmostBundleId: "com.apple.Safari",
                    frontmostOwnerName: "Safari",
                    hasTerminalPasswordPrompt: true,
                    allowNonSystemPrompts: false
                )
            )

            // Manual mode detects terminal sudo prompt
            assertEqual(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: false,
                    windows: [],
                    frontmostBundleId: "com.apple.Terminal",
                    frontmostOwnerName: "Terminal",
                    hasTerminalPasswordPrompt: true,
                    allowNonSystemPrompts: true
                ),
                DetectedPasswordPrompt(kind: .terminalPassword, sessionToken: "terminal-pwd")
            )

            // Manual mode guards against Terminal "Secure Keyboard Entry" when at a bare shell prompt
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: true,
                    windows: [],
                    frontmostBundleId: "com.googlecode.iterm2",
                    frontmostOwnerName: "iTerm2",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: true
                ),
                "Must not autofill into a bare terminal shell prompt even if Secure Keyboard Entry is enabled"
            )

            // Manual mode rejects unverified Secure Event Input (fail-closed)
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: true,
                    windows: [safariWindow],
                    focusedObservation: .none,
                    frontmostBundleId: "com.apple.Safari",
                    frontmostOwnerName: "Safari",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: true
                ),
                "Must not autofill unverified Secure Event Input without AXSecureTextField"
            )

            // Manual mode detects non-terminal AXSecureTextField when Secure Event Input is active
            assertEqual(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: true,
                    windows: [safariWindow],
                    focusedObservation: .nonSystemSecureField,
                    frontmostBundleId: "com.apple.Safari",
                    frontmostOwnerName: "Safari",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: true
                ),
                DetectedPasswordPrompt(kind: .secureTextField, sessionToken: "secure-field")
            )

            // Manual mode rejects plain chat/editor windows
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: false,
                    windows: [safariWindow],
                    focusedObservation: .plainTextInput,
                    frontmostBundleId: "com.apple.Notes",
                    frontmostOwnerName: "Notes",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: true
                )
            )
        }

        // 3. BiometricShortcutFilter tests
        runTest("testBiometricShortcutFilterTriggerSwallowAndEscCancel") {
            let filter = BiometricShortcutFilter()
            let chord: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
            assertNil(filter.shortcut, "Default Touch ID shortcut must be None")

            // With default shortcut = None, Ctrl+Opt+Cmd+\ passes through untouched
            assertEqual(
                filter.processEvent(
                    type: .keyDown,
                    keyCode: BiometricShortcutFilter.keyCodeBackslash,
                    flags: chord,
                    isAutorepeat: false,
                    userData: 0,
                    isControlling: true,
                    isBiometricEvaluationActive: false
                ),
                .passThrough
            )

            // Esc cancellation still works even when trigger shortcut is None
            assertEqual(
                filter.processEvent(
                    type: .keyDown,
                    keyCode: BiometricShortcutFilter.keyCodeEscape,
                    flags: [],
                    isAutorepeat: false,
                    userData: 0,
                    isControlling: true,
                    isBiometricEvaluationActive: true
                ),
                .cancelBiometricAuthAndSwallow
            )
            assertEqual(
                filter.processEvent(
                    type: .keyUp,
                    keyCode: BiometricShortcutFilter.keyCodeEscape,
                    flags: [],
                    isAutorepeat: false,
                    userData: 0,
                    isControlling: true,
                    isBiometricEvaluationActive: false
                ),
                .swallowOnly
            )

            // Configure custom trigger shortcut
            let trigger = RemoteBiometricShortcut(keyCode: BiometricShortcutFilter.keyCodeBackslash, modifiers: chord)
            assertNotNil(trigger)
            filter.setShortcut(trigger)
            assertEqual(filter.shortcut, trigger)

            // Not controlling -> passThrough
            assertEqual(
                filter.processEvent(
                    type: .keyDown,
                    keyCode: BiometricShortcutFilter.keyCodeBackslash,
                    flags: chord,
                    isAutorepeat: false,
                    userData: 0,
                    isControlling: false,
                    isBiometricEvaluationActive: false
                ),
                .passThrough
            )

            // Injected synthetic event -> passThrough
            assertEqual(
                filter.processEvent(
                    type: .keyDown,
                    keyCode: BiometricShortcutFilter.keyCodeBackslash,
                    flags: chord,
                    isAutorepeat: false,
                    userData: ScreenUnlocker.injectedEventUserDataTag,
                    isControlling: true,
                    isBiometricEvaluationActive: false
                ),
                .passThrough
            )

            // Trigger chord keyDown + autorepeat + keyUp after modifiers released
            assertEqual(
                filter.processEvent(
                    type: .keyDown,
                    keyCode: BiometricShortcutFilter.keyCodeBackslash,
                    flags: chord,
                    isAutorepeat: false,
                    userData: 0,
                    isControlling: true,
                    isBiometricEvaluationActive: false
                ),
                .triggerBiometricAuthAndSwallow
            )
            assertEqual(
                filter.processEvent(
                    type: .keyDown,
                    keyCode: BiometricShortcutFilter.keyCodeBackslash,
                    flags: chord,
                    isAutorepeat: true,
                    userData: 0,
                    isControlling: true,
                    isBiometricEvaluationActive: false
                ),
                .swallowOnly
            )

            // Changing or clearing shortcut while key is still held down still swallows its keyUp cleanly
            let newShortcut = RemoteBiometricShortcut(keyCode: 0x23, modifiers: [.maskAlternate, .maskCommand]) // ⌥⌘P
            filter.setShortcut(newShortcut)
            assertEqual(
                filter.processEvent(
                    type: .keyUp,
                    keyCode: BiometricShortcutFilter.keyCodeBackslash,
                    flags: [],
                    isAutorepeat: false,
                    userData: 0,
                    isControlling: true,
                    isBiometricEvaluationActive: false
                ),
                .swallowOnly
            )

            // New shortcut fires, then clearing back to nil disables trigger
            assertEqual(
                filter.processEvent(
                    type: .keyDown,
                    keyCode: 0x23,
                    flags: [.maskAlternate, .maskCommand],
                    isAutorepeat: false,
                    userData: 0,
                    isControlling: true,
                    isBiometricEvaluationActive: false
                ),
                .triggerBiometricAuthAndSwallow
            )
            filter.setShortcut(nil)
            assertEqual(
                filter.processEvent(
                    type: .keyUp,
                    keyCode: 0x23,
                    flags: [],
                    isAutorepeat: false,
                    userData: 0,
                    isControlling: true,
                    isBiometricEvaluationActive: false
                ),
                .swallowOnly
            )
            assertEqual(
                filter.processEvent(
                    type: .keyDown,
                    keyCode: 0x23,
                    flags: [.maskAlternate, .maskCommand],
                    isAutorepeat: false,
                    userData: 0,
                    isControlling: true,
                    isBiometricEvaluationActive: false
                ),
                .passThrough
            )

            // Modifier mismatch (e.g. Shift added) passes through when configured
            filter.setShortcut(trigger)
            assertEqual(
                filter.processEvent(
                    type: .keyDown,
                    keyCode: BiometricShortcutFilter.keyCodeBackslash,
                    flags: [.maskControl, .maskAlternate, .maskCommand, .maskShift],
                    isAutorepeat: false,
                    userData: 0,
                    isControlling: true,
                    isBiometricEvaluationActive: false
                ),
                .passThrough
            )

            // Plain Esc passes through when biometric evaluation is inactive
            assertEqual(
                filter.processEvent(
                    type: .keyDown,
                    keyCode: BiometricShortcutFilter.keyCodeEscape,
                    flags: [],
                    isAutorepeat: false,
                    userData: 0,
                    isControlling: true,
                    isBiometricEvaluationActive: false
                ),
                .passThrough
            )
        }

        // 4. ScreenUnlocker.performPromptAutofill tests
        runTest("testScreenUnlockerPromptAutofillClearingAndSafetyAborts") {
            let ansiMap = ScreenUnlocker.usANSIKeyboardFallbackMap()
            let strokes = ScreenUnlocker.resolveKeyStrokes(for: "Ab1!", keyboardMap: ansiMap)
            let token = ScreenUnlockCancellationToken()

            // System dialog emits flagsChanged([]), Cmd+A, Delete, 4 chars, Return
            let sysDriver = MockPromptDriver()
            let sysOutcome = ScreenUnlocker.performPromptAutofill(
                keyStrokes: strokes,
                promptKind: .systemDialog,
                cancellationToken: token,
                driver: sysDriver
            )
            assertEqual(sysOutcome, .typedAndSubmitted)
            let sysKeyDowns = sysDriver.recordedEvents.compactMap { event -> (CGKeyCode, CGEventFlags)? in
                if case .keyCode(let code, let down, let flags, _) = event, down {
                    return (code, flags)
                }
                return nil
            }
            assertEqual(sysKeyDowns.count, 7, "Cmd+A + Delete + 4 password chars + Return")
            assertEqual(sysKeyDowns[0].0, 0x00)
            assertTrue(sysKeyDowns[0].1.contains(.maskCommand))
            assertEqual(sysKeyDowns[1].0, 0x33)
            assertEqual(sysKeyDowns.last?.0, 0x24)

            // Terminal password skips Cmd+A and Delete completely!
            let termDriver = MockPromptDriver()
            let termOutcome = ScreenUnlocker.performPromptAutofill(
                keyStrokes: strokes,
                promptKind: .terminalPassword,
                cancellationToken: token,
                driver: termDriver
            )
            assertEqual(termOutcome, .typedAndSubmitted)
            let termKeyDowns = termDriver.recordedEvents.compactMap { event -> (CGKeyCode, CGEventFlags)? in
                if case .keyCode(let code, let down, let flags, _) = event, down {
                    return (code, flags)
                }
                return nil
            }
            assertEqual(termKeyDowns.count, 5, "4 password chars + Return, without Cmd+A or Delete")
            assertFalse(termKeyDowns.contains(where: { $0.1.contains(.maskCommand) }))
            assertEqual(termKeyDowns.last?.0, 0x24)

            // Mid-typing prompt close aborts immediately without trailing Return
            let closeDriver = MockPromptDriver()
            closeDriver.closePromptAfterKeyDownCount = 2 // Aborts after 2 terminal chars
            let closeOutcome = ScreenUnlocker.performPromptAutofill(
                keyStrokes: strokes,
                promptKind: .terminalPassword,
                cancellationToken: token,
                driver: closeDriver
            )
            assertEqual(closeOutcome, .abortedPromptClosed)
            let closeKeyDownCodes = closeDriver.recordedEvents.compactMap { event -> CGKeyCode? in
                if case .keyCode(let code, let down, _, _) = event, down { return code }
                return nil
            }
            assertEqual(closeKeyDownCodes.count, 2)
            assertFalse(closeKeyDownCodes.contains(0x24))

            // Mid-typing screen lock aborts immediately
            let lockDriver = MockPromptDriver()
            lockDriver.lockAfterKeyDownCount = 2
            let lockOutcome = ScreenUnlocker.performPromptAutofill(
                keyStrokes: strokes,
                promptKind: .terminalPassword,
                cancellationToken: token,
                driver: lockDriver
            )
            assertEqual(lockOutcome, .abortedScreenLocked)

            // Empty keystrokes fail
            assertEqual(
                ScreenUnlocker.performPromptAutofill(
                    keyStrokes: [],
                    promptKind: .systemDialog,
                    cancellationToken: token,
                    driver: MockPromptDriver()
                ),
                .failed("Password keystroke sequence is empty.")
            )
        }

        // 5. End-to-end auto-detected system dialog flow + suppression + re-arm
        runTest("testCoordinatorAutoSystemDialogFlowSuppressionAndRearm") {
            let dirA = try makeTempDir("auto-sys-A")
            let dirB = try makeTempDir("auto-sys-B")
            defer {
                try? FileManager.default.removeItem(at: dirA)
                try? FileManager.default.removeItem(at: dirB)
            }

            var clockNow: TimeInterval = 1000.0
            let (controller, controlled, _) = try makePairedNodes(dirController: dirA, dirControlled: dirB, clock: { clockNow })

            // Dialog appears on controlled Mac
            let dialog1 = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:100")
            controlled.currentAutoPrompt = dialog1
            controlled.activePromptKinds = [.systemDialog]
            controller.nextBiometricResult = .authenticated

            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertEqual(controller.evaluateBiometricsCallCount, 1)
            assertEqual(controlled.verifyCallCount, 1)
            assertEqual(controlled.performAutofillCallCount, 1)
            assertEqual(controlled.lastAutofillKind, .systemDialog)
            assertTrue(controller.loggedEvents.contains(where: { $0.level == .success }))

            // Polling again while same dialog window is still present must NOT re-trigger
            clockNow += 0.4
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertEqual(controller.evaluateBiometricsCallCount, 1)

            // User can still manually override on the same dialog via Ctrl+Opt+Cmd+\
            assertTrue(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            assertEqual(controller.evaluateBiometricsCallCount, 2)
            assertEqual(controlled.performAutofillCallCount, 2)

            // Dialog disappears -> re-arms auto detection
            controlled.currentAutoPrompt = nil
            controlled.activePromptKinds = []
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")

            // New dialog appears -> auto-triggers again, and user cancels Touch ID
            controlled.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:101")
            controlled.activePromptKinds = [.systemDialog]
            controller.nextBiometricResult = .userCancelled
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertEqual(controller.evaluateBiometricsCallCount, 3)
            assertEqual(controlled.performAutofillCallCount, 2, "Cancelled Touch ID must not autofill")
            // Polling same dialog again stays suppressed after user cancel
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertEqual(controller.evaluateBiometricsCallCount, 3)
        }

        // 6. Remote prompt dismissal cancels in-flight Touch ID on controller + Esc cancel
        runTest("testRemotePromptDismissalAndEscCancelInFlightTouchID") {
            let dirA = try makeTempDir("cancel-A")
            let dirB = try makeTempDir("cancel-B")
            defer {
                try? FileManager.default.removeItem(at: dirA)
                try? FileManager.default.removeItem(at: dirB)
            }

            let clockNow: TimeInterval = 2000.0
            let (controller, controlled, _) = try makePairedNodes(dirController: dirA, dirControlled: dirB, clock: { clockNow })

            // Deferred biometric evaluation so it stays open mid-flight
            controller.deferBiometricCompletion = true
            controlled.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:200")
            controlled.activePromptKinds = [.systemDialog]

            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertTrue(controller.coordinator.isEvaluatingBiometricsOnController)
            assertEqual(controller.evaluationStateHistory, [true])

            // Remote dialog disappears before user touches Touch ID -> sends biometricAuthCancel
            controlled.currentAutoPrompt = nil
            controlled.activePromptKinds = []
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")

            assertFalse(controller.coordinator.isEvaluatingBiometricsOnController)
            assertEqual(controller.cancelledBiometricsCount, 1)
            assertEqual(controlled.performAutofillCallCount, 0)
            assertEqual(controller.evaluationStateHistory, [true, false])

            // Now test user pressing Esc on controller to cancel active Touch ID
            controlled.currentManualPrompt = DetectedPasswordPrompt(kind: .terminalPassword, sessionToken: "terminal-pwd")
            controlled.activePromptKinds = [.terminalPassword]
            assertTrue(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            assertTrue(controller.coordinator.isEvaluatingBiometricsOnController)

            controller.coordinator.cancelControllerEvaluationByUser()
            assertFalse(controller.coordinator.isEvaluatingBiometricsOnController)
            assertEqual(controller.cancelledBiometricsCount, 2)
            assertEqual(controlled.performAutofillCallCount, 0)
        }

        // 7. Manual terminal sudo happy path, missing prompt rejection, toggle & clamshell checks
        runTest("testManualTerminalSudoMissingPromptToggleAndClamshell") {
            let dirA = try makeTempDir("manual-A")
            let dirB = try makeTempDir("manual-B")
            defer {
                try? FileManager.default.removeItem(at: dirA)
                try? FileManager.default.removeItem(at: dirB)
            }

            var clockNow: TimeInterval = 3000.0
            let (controller, controlled, _) = try makePairedNodes(dirController: dirA, dirControlled: dirB, clock: { clockNow })

            // Terminal sudo happy path
            controlled.currentManualPrompt = DetectedPasswordPrompt(kind: .terminalPassword, sessionToken: "terminal-pwd")
            controlled.activePromptKinds = [.terminalPassword]
            assertTrue(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            assertEqual(controlled.performAutofillCallCount, 1)
            assertEqual(controlled.lastAutofillKind, .terminalPassword)

            // Rejection when no prompt is active on controlled Mac
            clockNow += 2.0
            controlled.currentManualPrompt = nil
            controlled.activePromptKinds = []
            assertTrue(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            assertEqual(controlled.performAutofillCallCount, 1)
            assertTrue(controller.bezelNotifications.contains(where: { $0.isWarning && $0.title == "Touch ID Auth Failed" }))

            // Remote toggle disabled rejects manual request
            clockNow += 2.0
            controlled.biometricAuthEnabled = false
            controlled.currentManualPrompt = DetectedPasswordPrompt(kind: .terminalPassword, sessionToken: "terminal-pwd")
            controlled.activePromptKinds = [.terminalPassword]
            assertTrue(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            assertEqual(controlled.performAutofillCallCount, 1)

            // Controller toggle disabled blocks manual trigger immediately
            controlled.biometricAuthEnabled = true
            controller.biometricAuthEnabled = false
            clockNow += 2.0
            assertFalse(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            controller.biometricAuthEnabled = true

            // Clamshell / Touch ID unavailable: manual warns on bezel; auto stays quiet on bezel
            controller.availability = .unavailable("Touch ID is unavailable while the lid is closed.")
            clockNow += 2.0
            let bezelCountBeforeManual = controller.bezelNotifications.count
            assertFalse(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            assertEqual(controller.bezelNotifications.count, bezelCountBeforeManual + 1)

            let bezelCountBeforeAuto = controller.bezelNotifications.count
            controlled.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:300")
            controlled.activePromptKinds = [.systemDialog]
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertEqual(controller.bezelNotifications.count, bezelCountBeforeAuto, "Auto-trigger must not pop noisy bezel when Touch ID unavailable")
            assertEqual(controlled.performAutofillCallCount, 1)
        }

        // 8. Expiry, single-use replay rejection, key mismatch recovery, and OpenDirectory circuit breaker
        runTest("testSecurityBoundariesExpiryReplayMismatchAndCircuitBreaker") {
            let dirA = try makeTempDir("sec-A")
            let dirB = try makeTempDir("sec-B")
            defer {
                try? FileManager.default.removeItem(at: dirA)
                try? FileManager.default.removeItem(at: dirB)
            }

            var clockNow: TimeInterval = 4000.0
            let (controller, controlled, _) = try makePairedNodes(dirController: dirA, dirControlled: dirB, clock: { clockNow })

            // Capture response so we can test replay and expiry
            var capturedResponse: [AnyHashable: Any]?
            controlled.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:400")
            controlled.activePromptKinds = [.systemDialog]
            controller.routeHandler = { sender, target, type, info in
                if type == .biometricAuthResponse {
                    capturedResponse = info
                }
                if target == "MINI" {
                    controlled.coordinator.handleMessage(type, infoDict: info, from: sender)
                }
            }
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertEqual(controlled.performAutofillCallCount, 1)

            // Replay exact same response -> must be rejected (single-use nonce consumed)
            if let replay = capturedResponse {
                controlled.coordinator.handleMessage(.biometricAuthResponse, infoDict: replay, from: "MBP")
                assertEqual(controlled.performAutofillCallCount, 1, "Replayed HMAC response must be rejected")
            } else {
                assertTrue(false, "Expected biometricAuthResponse to be captured")
            }

            // Challenge TTL expiration (> 30s)
            controller.routeHandler = { sender, target, type, info in
                if target == "MINI" {
                    controlled.coordinator.handleMessage(type, infoDict: info, from: sender)
                } else {
                    controller.coordinator.handleMessage(type, infoDict: info, from: sender)
                }
            }
            controller.deferBiometricCompletion = true
            controlled.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:401")
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertTrue(controller.coordinator.isEvaluatingBiometricsOnController)

            clockNow += RemoteBiometricAuthCoordinator.challengeTTL + 1.0
            controller.finishPendingBiometric(.authenticated)
            assertEqual(controlled.performAutofillCallCount, 1, "Expired challenge response must be rejected")

            // Key mismatch clears controller peer secret and triggers key re-sync
            controller.deferBiometricCompletion = false
            clockNow += 2.0
            try? controller.store.savePeerSecret(Data(repeating: 0xAB, count: 32), for: "MINI")
            controlled.currentManualPrompt = DetectedPasswordPrompt(kind: .terminalPassword, sessionToken: "terminal-pwd")
            controlled.activePromptKinds = [.terminalPassword]
            assertTrue(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            assertNil(controller.store.loadPeerSecret(for: "MINI"), "Stale peer secret should be cleared on keyMismatch")
            assertTrue(controller.keyExchangeRequests.contains(where: { $0.hostId == "MINI" && $0.force == true }))

            // Restore matching keys for OpenDirectory circuit breaker test
            let (controller2, controlled2, _) = try makePairedNodes(dirController: dirA, dirControlled: dirB, clock: { clockNow })
            controlled2.verificationResult = .invalidCredentials
            controlled2.activePromptKinds = [.systemDialog]

            controlled2.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:501")
            controlled2.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertEqual(controlled2.verifyCallCount, 1)
            assertEqual(controlled2.performAutofillCallCount, 0, "Invalid password must abort before typing")
            assertTrue(controlled2.store.isPasswordInvalid)
            assertEqual(controlled2.coordinator.consecutiveAutoFailures, 1)

            // Even if invalid flag cleared externally, second auto failure trips circuit breaker (max 2)
            controlled2.store.clearPasswordInvalidFlag()
            controlled2.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:502")
            controlled2.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertEqual(controlled2.coordinator.consecutiveAutoFailures, 2)

            // Third auto dialog must be paused by circuit breaker without calling verifyLocalPassword
            controlled2.store.clearPasswordInvalidFlag()
            controlled2.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:503")
            controlled2.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertEqual(controlled2.verifyCallCount, 2, "Circuit breaker must pause further auto prompts")

            // Resetting circuit breaker after saving valid password restores auto prompts
            controlled2.verificationResult = .valid
            controlled2.coordinator.resetFailureCircuitBreaker()
            controlled2.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:504")
            controlled2.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertEqual(controlled2.verifyCallCount, 3)
            assertEqual(controlled2.performAutofillCallCount, 1)
            assertEqual(controlled2.coordinator.consecutiveAutoFailures, 0)
            _ = controller2
        }

        // 9. Controller foreground yield & restore balance across all exit paths
        runTest("testControllerForegroundYieldAndRestoreBalanceAcrossAllExitPaths") {
            let dirA = try makeTempDir("yield-A")
            let dirB = try makeTempDir("yield-B")
            defer {
                try? FileManager.default.removeItem(at: dirA)
                try? FileManager.default.removeItem(at: dirB)
            }

            var clockNow: TimeInterval = 5000.0
            let (controller, controlled, _) = try makePairedNodes(dirController: dirA, dirControlled: dirB, clock: { clockNow })
            controller.deferBiometricCompletion = true
            controlled.activePromptKinds = [.systemDialog]

            // Path 1: Success completion restores foreground after evaluation finishes
            controlled.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:601")
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertTrue(controller.isForegroundCurrentlyYielded)
            assertEqual(controller.prepareForegroundCount, 1)
            assertEqual(controller.restoreForegroundCount, 0)
            assertEqual(controller.foregroundYieldedAtEvaluateStart, [true])

            controller.finishPendingBiometric(.authenticated)
            assertFalse(controller.isForegroundCurrentlyYielded)
            assertEqual(controller.prepareForegroundCount, 1)
            assertEqual(controller.restoreForegroundCount, 1)

            // Path 2: Failure completion restores foreground BEFORE showing bezel notification
            controlled.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:602")
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertTrue(controller.isForegroundCurrentlyYielded)
            controller.finishPendingBiometric(.failed("Sensor failed"))
            assertFalse(controller.isForegroundCurrentlyYielded)
            assertEqual(controller.prepareForegroundCount, 2)
            assertEqual(controller.restoreForegroundCount, 2)
            assertEqual(controller.bezelWhileYieldedCount, 0, "Bezel notifications must happen after restoring bezel suspension")

            // Path 3: Remote prompt dismissal cancels Touch ID and restores foreground immediately
            controlled.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:603")
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertTrue(controller.isForegroundCurrentlyYielded)
            controlled.currentAutoPrompt = nil
            controlled.activePromptKinds = []
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertFalse(controller.isForegroundCurrentlyYielded)
            assertEqual(controller.prepareForegroundCount, 3)
            assertEqual(controller.restoreForegroundCount, 3)

            // Path 4: Esc cancel restores immediately; late callback does not double-restore
            controlled.activePromptKinds = [.terminalPassword]
            controlled.currentManualPrompt = DetectedPasswordPrompt(kind: .terminalPassword, sessionToken: "terminal-pwd")
            assertTrue(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            assertTrue(controller.isForegroundCurrentlyYielded)
            controller.coordinator.cancelControllerEvaluationByUser()
            assertFalse(controller.isForegroundCurrentlyYielded)
            assertEqual(controller.prepareForegroundCount, 4)
            assertEqual(controller.restoreForegroundCount, 4)

            // Path 5: Control stop restores immediately
            clockNow += 2.0
            assertTrue(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            assertTrue(controller.isForegroundCurrentlyYielded)
            controller.coordinator.handleClientControlDidStop(reason: "clientStoppedControl")
            assertFalse(controller.isForegroundCurrentlyYielded)
            assertEqual(controller.prepareForegroundCount, 5)
            assertEqual(controller.restoreForegroundCount, 5)

            // Path 6: Peer disconnect while Touch ID is open restores immediately
            clockNow += 2.0
            assertTrue(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            assertTrue(controller.isForegroundCurrentlyYielded)
            controller.coordinator.handlePeerDisconnected("MINI")
            assertFalse(controller.isForegroundCurrentlyYielded)
            assertEqual(controller.prepareForegroundCount, 6)
            assertEqual(controller.restoreForegroundCount, 6)
        }

        // 10. Passkey & ViewBridge system auth prompt detection (Signal 1, 2, 3 & zero false positives)
        runTest("testPasskeyAndViewBridgeSystemPromptClassification") {
            let edgeSheetWindow = DetectedWindowSnapshot(
                windowNumber: 0x8bf,
                ownerPID: 1398,
                ownerName: "Microsoft Edge",
                bundleIdentifier: "com.microsoft.edgemac",
                bounds: CGRect(x: 300, y: 200, width: 460, height: 340),
                alpha: 1.0,
                layer: 0
            )
            let remotePasswordBarWindow = DetectedWindowSnapshot(
                windowNumber: 2011,
                ownerPID: 20223,
                ownerName: "LocalAuthenticationRemoteServic",
                bundleIdentifier: "com.apple.LocalAuthenticationRemoteService",
                bounds: CGRect(x: 420, y: 310, width: 240, height: 35),
                alpha: 1.0,
                layer: 0
            )
            let idleRemoteWarmupWindow = DetectedWindowSnapshot(
                windowNumber: 2011,
                ownerPID: 20223,
                ownerName: "LocalAuthenticationRemoteServic",
                bundleIdentifier: "com.apple.LocalAuthenticationRemoteService",
                bounds: CGRect(x: 0, y: 580, width: 500, height: 500),
                alpha: 1.0,
                layer: 0
            )
            let idleHelperMarshalWindow = DetectedWindowSnapshot(
                windowNumber: 2005,
                ownerPID: 20194,
                ownerName: "AuthenticationServicesHelper",
                bundleIdentifier: "com.apple.AuthenticationServices.Helper",
                bounds: CGRect(x: -1920, y: 1080, width: 0, height: 0),
                alpha: 1.0,
                layer: 0
            )
            let activeHelperSheetWindow = DetectedWindowSnapshot(
                windowNumber: 2006,
                ownerPID: 20194,
                ownerName: "AuthenticationServicesHelper",
                bundleIdentifier: "com.apple.AuthenticationServices.Helper",
                bounds: CGRect(x: 320, y: 220, width: 380, height: 260),
                alpha: 1.0,
                layer: 0
            )
            let compactCoreAuthWindow = DetectedWindowSnapshot(
                windowNumber: 88,
                ownerPID: 902,
                ownerName: "coreautha",
                bundleIdentifier: "com.apple.LocalAuthentication.UIAgent",
                bounds: CGRect(x: 400, y: 300, width: 240, height: 35),
                alpha: 1.0,
                layer: 100
            )
            let invisibleRemoteBar = DetectedWindowSnapshot(
                windowNumber: 2012,
                ownerPID: 20223,
                ownerName: "LocalAuthenticationRemoteServic",
                bundleIdentifier: "com.apple.LocalAuthenticationRemoteService",
                bounds: CGRect(x: 420, y: 310, width: 240, height: 35),
                alpha: 0.0,
                layer: 0
            )
            let remoteServiceAXSnapshot = DetectedAuthProcessSnapshot(
                pid: 20223,
                processName: "LocalAuthenticationRemoteService (AuthenticationServicesHelper (Microsoft Edge))",
                bundleIdentifier: "com.apple.LocalAuthenticationRemoteService"
            )
            let helperAXSnapshot = DetectedAuthProcessSnapshot(
                pid: 20194,
                processName: "AuthenticationServicesHelper (Microsoft Edge)",
                bundleIdentifier: "com.apple.AuthenticationServices.Helper"
            )
            let agentAXSnapshot = DetectedAuthProcessSnapshot(
                pid: 1446,
                processName: "AuthenticationServicesAgent",
                bundleIdentifier: "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent"
            )

            let expectedToken = "sys-sheet:com.microsoft.edgemac"

            // Signal 2: AX focused element or sheet inside LocalAuthenticationRemoteService / AuthenticationServicesHelper / Agent
            let byRemoteServiceAX = PasswordPromptClassifier.classify(
                isScreenLocked: false,
                isSecureInputEnabled: true,
                windows: [edgeSheetWindow],
                allWindows: [],
                focusedObservation: .systemAuthProcess(remoteServiceAXSnapshot),
                frontmostBundleId: "com.microsoft.edgemac",
                frontmostOwnerName: "Microsoft Edge",
                hasTerminalPasswordPrompt: false,
                allowNonSystemPrompts: false
            )
            assertEqual(byRemoteServiceAX, DetectedPasswordPrompt(kind: .systemDialog, sessionToken: expectedToken))

            let byHelperAX = PasswordPromptClassifier.classify(
                isScreenLocked: false,
                isSecureInputEnabled: true,
                windows: [edgeSheetWindow],
                allWindows: [],
                focusedObservation: .systemAuthProcess(helperAXSnapshot),
                frontmostBundleId: "com.microsoft.edgemac",
                frontmostOwnerName: "Microsoft Edge",
                hasTerminalPasswordPrompt: false,
                allowNonSystemPrompts: false
            )
            assertEqual(byHelperAX, DetectedPasswordPrompt(kind: .systemDialog, sessionToken: expectedToken))

            let byAgentAX = PasswordPromptClassifier.classify(
                isScreenLocked: false,
                isSecureInputEnabled: true,
                windows: [edgeSheetWindow],
                allWindows: [],
                focusedObservation: .systemAuthProcess(agentAXSnapshot),
                frontmostBundleId: "com.microsoft.edgemac",
                frontmostOwnerName: "Microsoft Edge",
                hasTerminalPasswordPrompt: false,
                allowNonSystemPrompts: false
            )
            assertEqual(byAgentAX, DetectedPasswordPrompt(kind: .systemDialog, sessionToken: expectedToken))

            // Signal 3: ViewBridge fallback via resized LocalAuthenticationRemoteService bar or active Helper sheet
            let byRemoteBarWindow = PasswordPromptClassifier.classify(
                isScreenLocked: false,
                isSecureInputEnabled: true,
                windows: [edgeSheetWindow],
                allWindows: [idleHelperMarshalWindow, remotePasswordBarWindow],
                focusedObservation: .none,
                frontmostBundleId: "com.microsoft.edgemac",
                frontmostOwnerName: "Microsoft Edge",
                hasTerminalPasswordPrompt: false,
                allowNonSystemPrompts: false
            )
            assertEqual(byRemoteBarWindow, DetectedPasswordPrompt(kind: .systemDialog, sessionToken: expectedToken))

            let byHelperSheetWindow = PasswordPromptClassifier.classify(
                isScreenLocked: false,
                isSecureInputEnabled: true,
                windows: [edgeSheetWindow],
                allWindows: [idleRemoteWarmupWindow, activeHelperSheetWindow],
                focusedObservation: .none,
                frontmostBundleId: "com.microsoft.edgemac",
                frontmostOwnerName: "Microsoft Edge",
                hasTerminalPasswordPrompt: false,
                allowNonSystemPrompts: false
            )
            assertEqual(byHelperSheetWindow, DetectedPasswordPrompt(kind: .systemDialog, sessionToken: expectedToken))

            // Signal 2 -> Signal 3 transition across poll ticks preserves identical sessionToken
            assertEqual(byRemoteServiceAX?.sessionToken, byRemoteBarWindow?.sessionToken)

            // Signal 1: Compact 35pt on-screen coreautha/remote service window matches isSystemAuthWindow
            let compactSignal1 = PasswordPromptClassifier.classify(
                isScreenLocked: false,
                isSecureInputEnabled: true,
                windows: [compactCoreAuthWindow],
                allWindows: [],
                focusedObservation: .none,
                frontmostBundleId: "com.microsoft.edgemac",
                frontmostOwnerName: "Microsoft Edge",
                hasTerminalPasswordPrompt: false,
                allowNonSystemPrompts: false
            )
            assertEqual(compactSignal1, DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:902:88"))

            // Negative / Zero False Positive Cases:
            // Idle 500x500 warmup + 0x0 marshal windows without AXSecureTextField -> nil in both auto and manual modes
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: true,
                    windows: [edgeSheetWindow],
                    allWindows: [idleHelperMarshalWindow, idleRemoteWarmupWindow, invisibleRemoteBar],
                    focusedObservation: .none,
                    frontmostBundleId: "com.microsoft.edgemac",
                    frontmostOwnerName: "Microsoft Edge",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: false
                ),
                "Idle ViewBridge warmup windows must NOT auto-trigger Touch ID on regular password fields"
            )
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: true,
                    windows: [edgeSheetWindow],
                    allWindows: [idleHelperMarshalWindow, idleRemoteWarmupWindow],
                    focusedObservation: .none,
                    frontmostBundleId: "com.microsoft.edgemac",
                    frontmostOwnerName: "Microsoft Edge",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: true
                ),
                "Manual mode must fail closed when Secure Event Input lacks AXSecureTextField"
            )
            assertEqual(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: true,
                    windows: [edgeSheetWindow],
                    allWindows: [idleHelperMarshalWindow, idleRemoteWarmupWindow],
                    focusedObservation: .nonSystemSecureField,
                    frontmostBundleId: "com.microsoft.edgemac",
                    frontmostOwnerName: "Microsoft Edge",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: true
                ),
                DetectedPasswordPrompt(kind: .secureTextField, sessionToken: "secure-field")
            )

            // Non-system focused secure field suppresses Signal 3 even if an active Helper window exists elsewhere
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: true,
                    windows: [edgeSheetWindow],
                    allWindows: [activeHelperSheetWindow, remotePasswordBarWindow],
                    focusedObservation: .nonSystemSecureField,
                    frontmostBundleId: "com.microsoft.edgemac",
                    frontmostOwnerName: "Microsoft Edge",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: false
                )
            )
            assertEqual(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: true,
                    windows: [edgeSheetWindow],
                    allWindows: [activeHelperSheetWindow, remotePasswordBarWindow],
                    focusedObservation: .nonSystemSecureField,
                    frontmostBundleId: "com.microsoft.edgemac",
                    frontmostOwnerName: "Microsoft Edge",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: true
                ),
                DetectedPasswordPrompt(kind: .secureTextField, sessionToken: "secure-field")
            )

            // Locked screen / disabled secure input / terminal app suppress Passkey sheet signals
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: true,
                    isSecureInputEnabled: true,
                    windows: [edgeSheetWindow],
                    allWindows: [activeHelperSheetWindow],
                    focusedObservation: .systemAuthProcess(remoteServiceAXSnapshot),
                    frontmostBundleId: "com.microsoft.edgemac",
                    frontmostOwnerName: "Microsoft Edge",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: true
                )
            )
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: false,
                    windows: [edgeSheetWindow],
                    allWindows: [activeHelperSheetWindow],
                    focusedObservation: .systemAuthProcess(remoteServiceAXSnapshot),
                    frontmostBundleId: "com.microsoft.edgemac",
                    frontmostOwnerName: "Microsoft Edge",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: false
                )
            )
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: true,
                    windows: [],
                    allWindows: [activeHelperSheetWindow, remotePasswordBarWindow],
                    focusedObservation: .none,
                    frontmostBundleId: "com.apple.Terminal",
                    frontmostOwnerName: "Terminal",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: false
                )
            )
        }

        // 11. Controller auto-refocus suppression flag prevents stealing focus from Touch ID across all paths
        runTest("testControllerAutoRefocusSuppressionPreventsFocusSteal") {
            let dirA = try makeTempDir("refocus-A")
            let dirB = try makeTempDir("refocus-B")
            defer {
                try? FileManager.default.removeItem(at: dirA)
                try? FileManager.default.removeItem(at: dirB)
            }

            var clockNow: TimeInterval = 6000.0
            let (controller, controlled, _) = try makePairedNodes(dirController: dirA, dirControlled: dirB, clock: { clockNow })
            controller.deferBiometricCompletion = true
            controlled.activePromptKinds = [.systemDialog]

            assertFalse(controller.coordinator.shouldSuppressControllerAutoRefocus)

            // Path 1: Success completion keeps refocus suppressed while dialog is up, clears BEFORE restore
            controlled.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys-sheet:com.microsoft.edgemac")
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertTrue(controller.coordinator.shouldSuppressControllerAutoRefocus)
            assertEqual(controller.autoRefocusSuppressedAtPrepare, [true])
            assertEqual(controller.autoRefocusSuppressedAtEvaluateStart, [true])
            assertEqual(controller.autoRefocusSuppressedAtRestore, [])

            controller.finishPendingBiometric(.authenticated)
            assertFalse(controller.coordinator.shouldSuppressControllerAutoRefocus)
            assertEqual(controller.autoRefocusSuppressedAtRestore, [false])

            // Path 2: Failure completion clears BEFORE restore
            controlled.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:701")
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertTrue(controller.coordinator.shouldSuppressControllerAutoRefocus)
            controller.finishPendingBiometric(.failed("UI lost focus"))
            assertFalse(controller.coordinator.shouldSuppressControllerAutoRefocus)
            assertEqual(controller.autoRefocusSuppressedAtRestore, [false, false])

            // Path 3: Remote prompt closed cancels Touch ID and clears BEFORE restore
            controlled.currentAutoPrompt = DetectedPasswordPrompt(kind: .systemDialog, sessionToken: "sys:901:702")
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertTrue(controller.coordinator.shouldSuppressControllerAutoRefocus)
            controlled.currentAutoPrompt = nil
            controlled.activePromptKinds = []
            controlled.coordinator.pollControlledPromptState(controllerHostId: "MBP")
            assertFalse(controller.coordinator.shouldSuppressControllerAutoRefocus)
            assertEqual(controller.autoRefocusSuppressedAtRestore, [false, false, false])

            // Path 4: Esc cancel clears BEFORE restore
            controlled.activePromptKinds = [.secureTextField]
            controlled.currentManualPrompt = DetectedPasswordPrompt(kind: .secureTextField, sessionToken: "secure-field")
            assertTrue(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            assertTrue(controller.coordinator.shouldSuppressControllerAutoRefocus)
            controller.coordinator.cancelControllerEvaluationByUser()
            assertFalse(controller.coordinator.shouldSuppressControllerAutoRefocus)
            assertEqual(controller.autoRefocusSuppressedAtRestore, [false, false, false, false])

            // Path 5: Stopping control clears BEFORE restore
            clockNow += 2.0
            assertTrue(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            assertTrue(controller.coordinator.shouldSuppressControllerAutoRefocus)
            controller.coordinator.handleClientControlDidStop(reason: "clientStoppedControl")
            assertFalse(controller.coordinator.shouldSuppressControllerAutoRefocus)
            assertEqual(controller.autoRefocusSuppressedAtRestore, [false, false, false, false, false])

            // Path 6: Peer disconnect clears BEFORE restore
            clockNow += 2.0
            assertTrue(controller.coordinator.triggerManualAuthFromController(targetHostId: "MINI"))
            assertTrue(controller.coordinator.shouldSuppressControllerAutoRefocus)
            controller.coordinator.handlePeerDisconnected("MINI")
            assertFalse(controller.coordinator.shouldSuppressControllerAutoRefocus)
            assertEqual(controller.autoRefocusSuppressedAtRestore, [false, false, false, false, false, false])

            assertEqual(controller.autoRefocusSuppressedAtPrepare, [true, true, true, true, true, true])
            assertEqual(controller.autoRefocusSuppressedAtEvaluateStart, [true, true, true, true, true, true])
        }

        // 12. RemoteBiometricShortcut validation, serialization, NSEvent conversion, and display formatting
        runTest("testRemoteBiometricShortcutValidationSerializationAndDisplay") {
            let s1 = RemoteBiometricShortcut(keyCode: 0x2A, modifiers: [.maskControl, .maskAlternate, .maskCommand])
            assertNotNil(s1)
            assertEqual(s1?.serializedString, "ctrl+opt+cmd:42")
            assertEqual(s1?.displayString, "⌃⌥⌘\\")
            assertEqual(RemoteBiometricShortcut(serialized: s1?.serializedString), s1)

            let s2 = RemoteBiometricShortcut(keyCode: 0x23, modifiers: [.maskAlternate, .maskCommand])
            assertNotNil(s2)
            assertEqual(s2?.serializedString, "opt+cmd:35")
            assertEqual(s2?.displayString, "⌥⌘P")
            assertEqual(RemoteBiometricShortcut(serialized: " opt+cmd:35 "), s2)

            let s3 = RemoteBiometricShortcut(keyCode: 0x31, modifiers: [.maskControl, .maskShift])
            assertNotNil(s3)
            assertEqual(s3?.serializedString, "ctrl+shift:49")
            assertEqual(s3?.displayString, "⌃⇧␣")
            assertEqual(RemoteBiometricShortcut(serialized: s3?.serializedString), s3)

            let s4 = RemoteBiometricShortcut(keyCode: 0x6F, modifiers: [.maskCommand, .maskSecondaryFn])
            assertNotNil(s4)
            assertEqual(s4?.serializedString, "cmd:111")
            assertEqual(s4?.displayString, "⌘F12")
            assertEqual(RemoteBiometricShortcut(serialized: s4?.serializedString), s4)

            // NSEvent.ModifierFlags conversion preserves only relevant modifiers
            let convertedFlags = RemoteBiometricShortcut.cgEventFlags(from: [.control, .option, .shift, .command, .capsLock])
            assertEqual(convertedFlags, [.maskControl, .maskAlternate, .maskShift, .maskCommand])

            // Reject invalid inputs (empty/nil, bare key, Shift-only, Esc, modifier-only, out of range, malformed serialization)
            assertNil(RemoteBiometricShortcut(serialized: nil))
            assertNil(RemoteBiometricShortcut(serialized: ""))
            assertNil(RemoteBiometricShortcut(serialized: "   "))
            assertNil(RemoteBiometricShortcut(serialized: "42"))
            assertNil(RemoteBiometricShortcut(serialized: ":42"))
            assertNil(RemoteBiometricShortcut(serialized: "shift:42"))
            assertNil(RemoteBiometricShortcut(serialized: "cmd+cmd:42"))
            assertNil(RemoteBiometricShortcut(serialized: "meta:42"))
            assertNil(RemoteBiometricShortcut(serialized: "cmd:abc"))
            assertNil(RemoteBiometricShortcut(serialized: "cmd:42:1"))

            assertNil(RemoteBiometricShortcut(keyCode: 0x00, modifiers: []))
            assertNil(RemoteBiometricShortcut(keyCode: 0x00, modifiers: [.maskShift]))
            assertNil(RemoteBiometricShortcut(keyCode: BiometricShortcutFilter.keyCodeEscape, modifiers: [.maskCommand]))
            assertNil(RemoteBiometricShortcut(keyCode: 0x37, modifiers: [.maskCommand]))
            assertNil(RemoteBiometricShortcut(keyCode: -1, modifiers: [.maskCommand]))
            assertNil(RemoteBiometricShortcut(keyCode: 0x80, modifiers: [.maskCommand]))
        }

        // 13. Strict masked-input-only enforcement and frontmost-owned terminal prompt verification
        runTest("testStrictMaskedInputEnforcementAndOwnedTerminalDetection") {
            let browserWindow = DetectedWindowSnapshot(
                windowNumber: 101,
                ownerPID: 1398,
                ownerName: "Microsoft Edge",
                bundleIdentifier: "com.microsoft.edgemac",
                bounds: CGRect(x: 0, y: 0, width: 1200, height: 800),
                alpha: 1.0,
                layer: 0
            )
            let activeHelperWindow = DetectedWindowSnapshot(
                windowNumber: 102,
                ownerPID: 20194,
                ownerName: "AuthenticationServicesHelper",
                bundleIdentifier: "com.apple.AuthenticationServices.Helper",
                bounds: CGRect(x: 320, y: 220, width: 380, height: 260),
                alpha: 1.0,
                layer: 0
            )

            // Browser URL bar (.plainTextInput) is hard-blocked in ALL modes, even if Secure Input, terminal prompt, and ViewBridge windows are present
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: true,
                    windows: [browserWindow],
                    allWindows: [activeHelperWindow],
                    focusedObservation: .plainTextInput,
                    frontmostBundleId: "com.microsoft.edgemac",
                    frontmostOwnerName: "Microsoft Edge",
                    hasTerminalPasswordPrompt: true,
                    allowNonSystemPrompts: true
                ),
                "Browser URL bar / search field must NEVER receive password autofill"
            )
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: true,
                    windows: [browserWindow],
                    allWindows: [activeHelperWindow],
                    focusedObservation: .plainTextInput,
                    frontmostBundleId: "com.microsoft.edgemac",
                    frontmostOwnerName: "Microsoft Edge",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: false
                ),
                "Plaintext input suppresses Signal 3 ViewBridge fallback in auto mode as well"
            )

            // Plain webpage input (.none) with leaked Secure Event Input must NOT allow manual trigger
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: true,
                    windows: [browserWindow],
                    allWindows: [],
                    focusedObservation: .none,
                    frontmostBundleId: "com.microsoft.edgemac",
                    frontmostOwnerName: "Microsoft Edge",
                    hasTerminalPasswordPrompt: false,
                    allowNonSystemPrompts: true
                )
            )

            // Dedicated terminal Find bar (.plainTextInput) is rejected even while sudo waits in the terminal pane
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: false,
                    windows: [],
                    allWindows: [],
                    focusedObservation: .plainTextInput,
                    frontmostBundleId: "com.apple.Terminal",
                    frontmostOwnerName: "Terminal",
                    hasTerminalPasswordPrompt: true,
                    allowNonSystemPrompts: true
                ),
                "Terminal Find/search bar must block terminal password autofill"
            )

            // Non-terminal IDE (Cursor) code editor (.plainTextInput / .none) is rejected, whereas integrated terminal (.terminalSurface) is allowed
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: false,
                    windows: [],
                    allWindows: [],
                    focusedObservation: .plainTextInput,
                    frontmostBundleId: "com.todesktop.230313mzl4w4u92",
                    frontmostOwnerName: "Cursor",
                    hasTerminalPasswordPrompt: true,
                    allowNonSystemPrompts: true
                )
            )
            assertNil(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: false,
                    windows: [],
                    allWindows: [],
                    focusedObservation: .none,
                    frontmostBundleId: "com.todesktop.230313mzl4w4u92",
                    frontmostOwnerName: "Cursor",
                    hasTerminalPasswordPrompt: true,
                    allowNonSystemPrompts: true
                )
            )
            assertEqual(
                PasswordPromptClassifier.classify(
                    isScreenLocked: false,
                    isSecureInputEnabled: false,
                    windows: [],
                    allWindows: [],
                    focusedObservation: .terminalSurface,
                    frontmostBundleId: "com.todesktop.230313mzl4w4u92",
                    frontmostOwnerName: "Cursor",
                    hasTerminalPasswordPrompt: true,
                    allowNonSystemPrompts: true
                ),
                DetectedPasswordPrompt(kind: .terminalPassword, sessionToken: "terminal-pwd")
            )

            // Terminal process ownership checks
            let uid: uid_t = 501
            let warpPID: pid_t = 1423
            let terminalAppPID: pid_t = 1500
            let browserPID: pid_t = 1398
            let iTermPID: pid_t = 1600
            let ttyWarp: dev_t = 1001
            let ttyReadSecret: dev_t = 1002
            let ttyVim: dev_t = 1003
            let ttyITerm: dev_t = 1004
            let ttyTmux: dev_t = 1005

            let processes: [TerminalProcessSnapshot] = [
                TerminalProcessSnapshot(pid: browserPID, ppid: 1, ruid: uid, tdev: -1, pgid: browserPID, tpgid: -1, comm: "Microsoft Edge"),
                // Warp -> terminal-server -> zsh -> sudo (foreground raw no-echo prompt)
                TerminalProcessSnapshot(pid: warpPID, ppid: 1, ruid: uid, tdev: -1, pgid: warpPID, tpgid: -1, comm: "stable"),
                TerminalProcessSnapshot(pid: 2899, ppid: warpPID, ruid: uid, tdev: -1, pgid: 2899, tpgid: -1, comm: "terminal-server"),
                TerminalProcessSnapshot(pid: 41372, ppid: 2899, ruid: uid, tdev: ttyWarp, pgid: 41372, tpgid: 42000, comm: "zsh"),
                TerminalProcessSnapshot(pid: 42000, ppid: 41372, ruid: uid, tdev: ttyWarp, pgid: 42000, tpgid: 42000, comm: "sudo"),
                // Warp running vim in raw no-echo mode (must NOT be mistaken for a password prompt)
                TerminalProcessSnapshot(pid: 2900, ppid: 2899, ruid: uid, tdev: ttyVim, pgid: 2900, tpgid: 42001, comm: "zsh"),
                TerminalProcessSnapshot(pid: 42001, ppid: 2900, ruid: uid, tdev: ttyVim, pgid: 42001, tpgid: 42001, comm: "vim"),
                // Terminal.app -> login (ruid 0) -> zsh (canonical read -s, zsh itself is foreground)
                TerminalProcessSnapshot(pid: terminalAppPID, ppid: 1, ruid: uid, tdev: -1, pgid: terminalAppPID, tpgid: -1, comm: "Terminal"),
                TerminalProcessSnapshot(pid: 5100, ppid: terminalAppPID, ruid: 0, tdev: ttyReadSecret, pgid: 5100, tpgid: 5101, comm: "login"),
                TerminalProcessSnapshot(pid: 5101, ppid: 5100, ruid: uid, tdev: ttyReadSecret, pgid: 5101, tpgid: 5101, comm: "zsh"),
                // iTerm2 with iTermServer daemon (ppid == 1) -> zsh -> sudo
                TerminalProcessSnapshot(pid: iTermPID, ppid: 1, ruid: uid, tdev: -1, pgid: iTermPID, tpgid: -1, comm: "iTerm2"),
                TerminalProcessSnapshot(pid: 6100, ppid: 1, ruid: uid, tdev: -1, pgid: 6100, tpgid: -1, comm: "iTermServer-3.5"),
                TerminalProcessSnapshot(pid: 6101, ppid: 6100, ruid: uid, tdev: ttyITerm, pgid: 6101, tpgid: 6102, comm: "zsh"),
                TerminalProcessSnapshot(pid: 6102, ppid: 6101, ruid: uid, tdev: ttyITerm, pgid: 6102, tpgid: 6102, comm: "sudo"),
                // Warp attached to tmux client while tmux: server (ppid == 1) hosts sudo
                TerminalProcessSnapshot(pid: 7000, ppid: 2899, ruid: uid, tdev: ttyTmux, pgid: 7000, tpgid: 7000, comm: "tmux"),
                TerminalProcessSnapshot(pid: 7001, ppid: 1, ruid: uid, tdev: -1, pgid: 7001, tpgid: -1, comm: "tmux: server"),
                TerminalProcessSnapshot(pid: 7002, ppid: 7001, ruid: uid, tdev: ttyTmux, pgid: 7002, tpgid: 7003, comm: "zsh"),
                TerminalProcessSnapshot(pid: 7003, ppid: 7002, ruid: uid, tdev: ttyTmux, pgid: 7003, tpgid: 7003, comm: "sudo")
            ]

            // Foreground Warp with sudo -> true
            assertTrue(
                PasswordPromptClassifier.hasOwnedTerminalPasswordPrompt(
                    uid: uid,
                    frontmostPID: warpPID,
                    frontmostBundleId: "dev.warp.Warp-Stable",
                    isDedicatedTerminal: true,
                    canonicalNoEchoTTYs: [],
                    rawNoEchoTTYs: [ttyWarp],
                    processes: processes
                )
            )
            // Background Warp with sudo while Edge is frontmost -> false
            assertFalse(
                PasswordPromptClassifier.hasOwnedTerminalPasswordPrompt(
                    uid: uid,
                    frontmostPID: browserPID,
                    frontmostBundleId: "com.microsoft.edgemac",
                    isDedicatedTerminal: false,
                    canonicalNoEchoTTYs: [ttyReadSecret],
                    rawNoEchoTTYs: [ttyWarp, ttyITerm, ttyTmux],
                    processes: processes
                )
            )
            // Foreground Terminal.app with canonical no-echo read -s (walking through root login) -> true
            assertTrue(
                PasswordPromptClassifier.hasOwnedTerminalPasswordPrompt(
                    uid: uid,
                    frontmostPID: terminalAppPID,
                    frontmostBundleId: "com.apple.Terminal",
                    isDedicatedTerminal: true,
                    canonicalNoEchoTTYs: [ttyReadSecret],
                    rawNoEchoTTYs: [],
                    processes: processes
                )
            )
            // Foreground Warp running vim (non-canonical no-echo, non-password process) -> false
            assertFalse(
                PasswordPromptClassifier.hasOwnedTerminalPasswordPrompt(
                    uid: uid,
                    frontmostPID: warpPID,
                    frontmostBundleId: "dev.warp.Warp-Stable",
                    isDedicatedTerminal: true,
                    canonicalNoEchoTTYs: [],
                    rawNoEchoTTYs: [ttyVim],
                    processes: processes
                )
            )
            // Foreground iTerm2 via iTermServer -> true
            assertTrue(
                PasswordPromptClassifier.hasOwnedTerminalPasswordPrompt(
                    uid: uid,
                    frontmostPID: iTermPID,
                    frontmostBundleId: "com.googlecode.iterm2",
                    isDedicatedTerminal: true,
                    canonicalNoEchoTTYs: [],
                    rawNoEchoTTYs: [ttyITerm],
                    processes: processes
                )
            )
            // Foreground Warp with tmux client -> true; iTerm2 without tmux client -> false
            assertTrue(
                PasswordPromptClassifier.hasOwnedTerminalPasswordPrompt(
                    uid: uid,
                    frontmostPID: warpPID,
                    frontmostBundleId: "dev.warp.Warp-Stable",
                    isDedicatedTerminal: true,
                    canonicalNoEchoTTYs: [],
                    rawNoEchoTTYs: [ttyTmux],
                    processes: processes
                )
            )
            assertFalse(
                PasswordPromptClassifier.hasOwnedTerminalPasswordPrompt(
                    uid: uid,
                    frontmostPID: iTermPID,
                    frontmostBundleId: "com.googlecode.iterm2",
                    isDedicatedTerminal: true,
                    canonicalNoEchoTTYs: [],
                    rawNoEchoTTYs: [ttyTmux],
                    processes: processes
                )
            )
        }

        print("=== Test Summary: \(totalTestsRun) tests (\(totalAssertions) assertions), \(failedTests.count) failures ===")
        if !failedTests.isEmpty {
            exit(1)
        }
    }
}
