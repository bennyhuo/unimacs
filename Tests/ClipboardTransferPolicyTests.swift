// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import CoreGraphics

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

private func runTest(_ name: String, _ block: () -> Void) {
    totalTestsRun += 1
    let failuresBefore = failedTests.count
    block()
    if failedTests.count == failuresBefore {
        print("  ✅ \(name)")
    }
}

// MARK: - Test Suite

@main
struct ClipboardTransferPolicyTestRunner {
    static func main() {
        print("=== Running Unimacs Clipboard Transfer Policy Unit Tests ===")

        let h0 = PasteboardContentHash(changeCount: 1, types: ["public.utf8-plain-text"])
        let h1 = PasteboardContentHash(changeCount: 2, types: ["public.utf8-plain-text"])
        let h2 = PasteboardContentHash(changeCount: 3, types: ["public.utf8-plain-text"])
        let emptyHash = PasteboardContentHash(changeCount: 4, types: [])
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        runTest("testShortcutDetectorClassificationAndBoundaries") {
            // Standard Cmd+V, Cmd+C, Cmd+X
            assertEqual(
                ClipboardShortcutDetector.classify(keyCode: ClipboardShortcutDetector.ansiKeyV, commandDown: true, controlDown: false),
                .paste
            )
            assertEqual(
                ClipboardShortcutDetector.classify(keyCode: ClipboardShortcutDetector.ansiKeyC, commandDown: true, controlDown: false),
                .copyOrCut
            )
            assertEqual(
                ClipboardShortcutDetector.classify(keyCode: ClipboardShortcutDetector.ansiKeyX, commandDown: true, controlDown: false),
                .copyOrCut
            )

            // Non-QWERTY layout character fallback (e.g. Dvorak)
            assertEqual(
                ClipboardShortcutDetector.classify(keyCode: 47, commandDown: true, controlDown: false, charactersIgnoringModifiers: "V"),
                .paste
            )
            assertEqual(
                ClipboardShortcutDetector.classify(keyCode: 31, commandDown: true, controlDown: false, charactersIgnoringModifiers: "c"),
                .copyOrCut
            )

            // Negative / boundary cases: no Command, Control held, key repeat, unrelated key
            assertNil(
                ClipboardShortcutDetector.classify(keyCode: ClipboardShortcutDetector.ansiKeyV, commandDown: false, controlDown: false)
            )
            assertNil(
                ClipboardShortcutDetector.classify(keyCode: ClipboardShortcutDetector.ansiKeyV, commandDown: true, controlDown: true)
            )
            assertNil(
                ClipboardShortcutDetector.classify(keyCode: ClipboardShortcutDetector.ansiKeyV, commandDown: true, controlDown: false, isRepeat: true)
            )
            assertNil(
                ClipboardShortcutDetector.classify(keyCode: 0x00, commandDown: true, controlDown: false, charactersIgnoringModifiers: "a")
            )

            // CGEvent classification (used on controlled Server Mac)
            if let cgPaste = CGEvent(keyboardEventSource: nil, virtualKey: ClipboardShortcutDetector.ansiKeyV, keyDown: true) {
                cgPaste.flags = .maskCommand
                assertEqual(ClipboardShortcutDetector.classify(cgEvent: cgPaste), .paste)

                // Key repeat on CGEvent should be ignored
                cgPaste.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
                assertNil(ClipboardShortcutDetector.classify(cgEvent: cgPaste))
            }
            if let cgKeyUp = CGEvent(keyboardEventSource: nil, virtualKey: ClipboardShortcutDetector.ansiKeyV, keyDown: false) {
                cgKeyUp.flags = .maskCommand
                assertNil(ClipboardShortcutDetector.classify(cgEvent: cgKeyUp))
            }
        }

        runTest("testNormalCopyAndImmediateSwitchSendsOnce") {
            var state = ClipboardTransferPolicyState()
            state.resetBaseline(with: h0)

            // No change -> .noChange
            assertEqual(
                state.evaluateBoundarySend(
                    hash: h0,
                    baseline: h0,
                    skipAfterLocalPaste: true,
                    enableTimeout: true,
                    timeoutInterval: 30,
                    now: t0
                ),
                .noChange
            )

            // Copy h1 at t0 + 1s, switch at t0 + 4s
            state.recordExternalChange(hash: h1, now: t0.addingTimeInterval(1))
            assertTrue(state.pasteboardDirtySinceBaseline)

            let decision = state.evaluateBoundarySend(
                hash: h1,
                baseline: h0,
                skipAfterLocalPaste: true,
                enableTimeout: true,
                timeoutInterval: 30,
                now: t0.addingTimeInterval(4)
            )
            assertEqual(decision, .send)

            // Once boundary is marked handled, subsequent checks for h1 return .noChange
            state.markBoundaryHandled(hash: h1)
            assertFalse(state.pasteboardDirtySinceBaseline)
            assertEqual(
                state.evaluateBoundarySend(
                    hash: h1,
                    baseline: h1,
                    skipAfterLocalPaste: true,
                    enableTimeout: true,
                    timeoutInterval: 30,
                    now: t0.addingTimeInterval(10)
                ),
                .noChange
            )
        }

        runTest("testSkipAfterLocalPasteToggleAndReCopyBehavior") {
            var state = ClipboardTransferPolicyState()
            state.resetBaseline(with: h0)

            // 1. Copy h1 on Mac A at t0 + 1s
            state.recordExternalChange(hash: h1, now: t0.addingTimeInterval(1))

            // 2. Paste h1 locally on Mac A at t0 + 2s
            state.recordLocalPaste(currentHash: h1, now: t0.addingTimeInterval(2))
            assertEqual(state.consumedByLocalPasteHash, h1)

            // 3a. With skipAfterLocalPaste == false (user turned off switch), it still sends
            assertEqual(
                state.evaluateBoundarySend(
                    hash: h1,
                    baseline: h0,
                    skipAfterLocalPaste: false,
                    enableTimeout: true,
                    timeoutInterval: 30,
                    now: t0.addingTimeInterval(5)
                ),
                .send
            )

            // 3b. With skipAfterLocalPaste == true (default), it skips transfer
            assertEqual(
                state.evaluateBoundarySend(
                    hash: h1,
                    baseline: h0,
                    skipAfterLocalPaste: true,
                    enableTimeout: true,
                    timeoutInterval: 30,
                    now: t0.addingTimeInterval(5)
                ),
                .skippedAfterLocalPaste
            )
            state.markBoundaryHandled(hash: h1)

            // 4. User copies again on Mac A (h2, new changeCount) and does NOT paste locally -> sends!
            state.recordExternalChange(hash: h2, now: t0.addingTimeInterval(8))
            assertNil(state.consumedByLocalPasteHash)
            assertEqual(
                state.evaluateBoundarySend(
                    hash: h2,
                    baseline: h1,
                    skipAfterLocalPaste: true,
                    enableTimeout: true,
                    timeoutInterval: 30,
                    now: t0.addingTimeInterval(10)
                ),
                .send
            )
        }

        runTest("testFastCopyAndPasteBeforePeriodicPollRaceCondition") {
            var state = ClipboardTransferPolicyState()
            state.resetBaseline(with: h0)

            // User presses Cmd+C (h1) and immediately Cmd+V 50ms later, BEFORE periodic poll runs:
            // recordLocalPaste runs first with h1, then periodic poll calls recordExternalChange(h1) 400ms later.
            state.recordLocalPaste(currentHash: h1, now: t0.addingTimeInterval(0.05))
            assertEqual(state.consumedByLocalPasteHash, h1)
            assertTrue(state.pasteboardDirtySinceBaseline)

            // Delayed periodic poll sees the same h1: must NOT clear consumedByLocalPasteHash
            state.recordExternalChange(hash: h1, now: t0.addingTimeInterval(0.45))
            assertEqual(state.consumedByLocalPasteHash, h1)

            assertEqual(
                state.evaluateBoundarySend(
                    hash: h1,
                    baseline: h0,
                    skipAfterLocalPaste: true,
                    enableTimeout: true,
                    timeoutInterval: 30,
                    now: t0.addingTimeInterval(2.0)
                ),
                .skippedAfterLocalPaste
            )
        }

        runTest("testFastUnpolledCopyDiscoveredAtConnectingBoundary") {
            var state = ClipboardTransferPolicyState()
            state.resetBaseline(with: h0)

            // User copies h1 and within 30ms crosses hot border (before periodic poll fires)
            state.beginConnectingToControl(currentHash: h1, now: t0.addingTimeInterval(1.0))
            state.didStartControllingRemote()

            assertEqual(
                state.evaluateBoundarySend(
                    hash: h1,
                    baseline: state.sessionBaselineHash,
                    skipAfterLocalPaste: true,
                    enableTimeout: true,
                    timeoutInterval: 30,
                    now: t0.addingTimeInterval(1.1)
                ),
                .send
            )
        }

        runTest("testClipboardTimeoutExpirationAndBoundaryConditions") {
            var state = ClipboardTransferPolicyState()
            state.resetBaseline(with: h0)

            // Copy h1 at t0 (testing default 60s and max 600s boundaries)
            state.recordExternalChange(hash: h1, now: t0)

            // Exact timeout boundary (elapsed == 60.0s, timeout == 60.0s) -> still sends
            assertEqual(
                state.evaluateBoundarySend(
                    hash: h1,
                    baseline: h0,
                    skipAfterLocalPaste: true,
                    enableTimeout: true,
                    timeoutInterval: 60.0,
                    now: t0.addingTimeInterval(60.0)
                ),
                .send
            )

            // Past timeout (elapsed == 60.1s > 60.0s) -> .skippedExpired
            let expiredDecision = state.evaluateBoundarySend(
                hash: h1,
                baseline: h0,
                skipAfterLocalPaste: true,
                enableTimeout: true,
                timeoutInterval: 60.0,
                now: t0.addingTimeInterval(60.1)
            )
            if case .skippedExpired(let elapsed, let timeout) = expiredDecision {
                assertTrue(abs(elapsed - 60.1) < 0.001)
                assertEqual(timeout, 60.0)
            } else {
                assertTrue(false, "Expected .skippedExpired, got \(expiredDecision)")
            }

            // Upper bound 600s check: elapsed 600.0s sends, 600.5s expires
            assertEqual(
                state.evaluateBoundarySend(
                    hash: h1,
                    baseline: h0,
                    skipAfterLocalPaste: true,
                    enableTimeout: true,
                    timeoutInterval: 600.0,
                    now: t0.addingTimeInterval(600.0)
                ),
                .send
            )
            assertEqual(
                state.evaluateBoundarySend(
                    hash: h1,
                    baseline: h0,
                    skipAfterLocalPaste: true,
                    enableTimeout: true,
                    timeoutInterval: 600.0,
                    now: t0.addingTimeInterval(600.5)
                ),
                .skippedExpired(elapsed: 600.5, timeout: 600.0)
            )

            // If enableTimeout is false, even after 900s it still sends
            assertEqual(
                state.evaluateBoundarySend(
                    hash: h1,
                    baseline: h0,
                    skipAfterLocalPaste: true,
                    enableTimeout: false,
                    timeoutInterval: 60.0,
                    now: t0.addingTimeInterval(900.0)
                ),
                .send
            )

            // If user copies a new item h2 at t0 + 100s, timestamp refreshes and h2 sends at t0 + 125s
            state.markBoundaryHandled(hash: h1)
            state.recordExternalChange(hash: h2, now: t0.addingTimeInterval(100.0))
            assertEqual(
                state.evaluateBoundarySend(
                    hash: h2,
                    baseline: h1,
                    skipAfterLocalPaste: true,
                    enableTimeout: true,
                    timeoutInterval: 60.0,
                    now: t0.addingTimeInterval(125.0)
                ),
                .send
            )
        }

        runTest("testControlledRemoteServerRoleAndEchoSuppression") {
            var state = ClipboardTransferPolicyState()
            state.didStartBeingControlled(baselineHash: h0)
            assertEqual(state.mode, .controlledByRemote)

            // Incoming pasteboard from Client A (h1) is applied on Server B -> must not echo back
            state.applyIncomingPasteboard(hash: h1)
            assertEqual(
                state.evaluateBoundarySend(
                    hash: h1,
                    baseline: state.sessionBaselineHash,
                    skipAfterLocalPaste: true,
                    enableTimeout: true,
                    timeoutInterval: 30.0,
                    now: t0.addingTimeInterval(2.0)
                ),
                .noChange
            )

            // User copies h2 on Server B while controlled, then pastes h2 on Server B -> skipped when returning to A
            state.recordExternalChange(hash: h2, now: t0.addingTimeInterval(5.0))
            state.recordLocalPaste(currentHash: h2, now: t0.addingTimeInterval(6.0))
            assertEqual(
                state.evaluateBoundarySend(
                    hash: h2,
                    baseline: state.sessionBaselineHash,
                    skipAfterLocalPaste: true,
                    enableTimeout: true,
                    timeoutInterval: 30.0,
                    now: t0.addingTimeInterval(8.0)
                ),
                .skippedAfterLocalPaste
            )

            // Empty pasteboard or paste during .controllingRemote is ignored
            state.didStartControllingRemote()
            state.recordLocalPaste(currentHash: h1, now: t0.addingTimeInterval(10.0))
            assertEqual(state.consumedByLocalPasteHash, h2)

            state.enterIdleMode()
            state.recordLocalPaste(currentHash: emptyHash, now: t0.addingTimeInterval(11.0))
            assertEqual(state.consumedByLocalPasteHash, h2)
        }

        print("=== Test Summary: \(totalTestsRun) tests (\(totalAssertions) assertions), \(failedTests.count) failures ===")
        if !failedTests.isEmpty {
            exit(1)
        }
    }
}
