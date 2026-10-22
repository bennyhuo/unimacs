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

private func assertAlmostEqual(
    _ actual: CGFloat,
    _ expected: CGFloat,
    tolerance: CGFloat = 0.01,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if abs(actual - expected) > tolerance {
        let failure = "[\(file):\(line)] Assertion failed: expected (\(expected) ± \(tolerance)), got (\(actual)). \(message)"
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
struct CGEventSerializerTestRunner {
    static func main() {
        print("=== Running Unimacs CGEventSerializer Unit Tests ===")

        let localMainDisplayHeight = CGFloat(Int(CGDisplayBounds(CGMainDisplayID()).height))

        runTest("testDirectModeClearsSenderCachedDisplayAndWindowFields") {
            guard let sourceEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: CGPoint(x: 55.5, y: -960.4),
                mouseButton: .left
            ) else {
                assertTrue(false, "Failed to create source CGEvent")
                return
            }

            // Simulate a controlling Mac with a different primary screen height (e.g. 1440pt or 1117pt)
            // and sender-side window metadata stamped onto SLSEventRecord.
            let simulatedRemoteMainHeight: Int64 = (Int64(localMainDisplayHeight) == 1117) ? 1440 : 1117
            sourceEvent.setIntegerValueField(CGEventSerializer.windowNumberField, value: 999)
            sourceEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 888)
            sourceEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: 777)
            sourceEvent.setIntegerValueField(CGEventSerializer.cachedWindowHeightField, value: 455)
            sourceEvent.setIntegerValueField(CGEventSerializer.cachedMainDisplayHeightField, value: simulatedRemoteMainHeight)

            assertEqual(
                sourceEvent.getIntegerValueField(CGEventSerializer.cachedMainDisplayHeightField),
                simulatedRemoteMainHeight
            )

            // Without sanitization, unflippedLocation.y uses the remote screen height instead of local
            sourceEvent.location = CGPoint(x: 72.0, y: 81.4)
            assertAlmostEqual(
                sourceEvent.unflippedLocation.y,
                CGFloat(simulatedRemoteMainHeight) - 81.4,
                "Raw event with stale field 107 flips Y against remote screen height"
            )

            // Serialize and deserialize in .direct mode
            guard let data = CGEventSerializer.serialize(sourceEvent, mode: .direct) else {
                assertTrue(false, "Direct serialization returned nil")
                return
            }

            let targetLocation = CGPoint(x: 72.0, y: 81.4)
            guard let deserialized = CGEventSerializer.deserialize(
                data,
                mode: .direct,
                eventSource: nil,
                currentMouseLocation: targetLocation
            ) else {
                assertTrue(false, "Direct deserialization returned nil")
                return
            }

            // All sender-cached geometry fields must be cleared immediately after deserialization
            assertEqual(deserialized.getIntegerValueField(CGEventSerializer.windowNumberField), 0)
            assertEqual(deserialized.getIntegerValueField(.mouseEventWindowUnderMousePointer), 0)
            assertEqual(deserialized.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent), 0)
            assertEqual(deserialized.getIntegerValueField(CGEventSerializer.cachedWindowHeightField), 0)
            assertEqual(deserialized.getIntegerValueField(CGEventSerializer.cachedMainDisplayHeightField), 0)

            // After updating location on the controlled Mac, unflippedLocation must use the local main display height
            deserialized.location = targetLocation
            assertAlmostEqual(deserialized.location.x, targetLocation.x)
            assertAlmostEqual(deserialized.location.y, targetLocation.y)
            assertAlmostEqual(deserialized.unflippedLocation.x, targetLocation.x)
            assertAlmostEqual(
                deserialized.unflippedLocation.y,
                localMainDisplayHeight - targetLocation.y,
                "Deserialized event must flip Y using local main display height (\(localMainDisplayHeight))"
            )
            assertEqual(
                deserialized.getIntegerValueField(CGEventSerializer.cachedMainDisplayHeightField),
                Int64(localMainDisplayHeight)
            )
        }

        runTest("testDirectModeBoundaryCoordinatesAndMouseTypes") {
            let testCoordinates: [CGPoint] = [
                .zero,
                CGPoint(x: 26.0, y: 18.4),
                CGPoint(x: -1920.0, y: 0.0),
                CGPoint(x: -500.0, y: -44.0),
                CGPoint(x: 3840.0, y: 2160.0)
            ]
            let mouseTypes: [CGEventType] = [
                .mouseMoved, .leftMouseDown, .leftMouseUp,
                .rightMouseDown, .rightMouseUp, .leftMouseDragged
            ]

            for (idx, coord) in testCoordinates.enumerated() {
                let mouseType = mouseTypes[idx % mouseTypes.count]
                guard let event = CGEvent(
                    mouseEventSource: nil,
                    mouseType: mouseType,
                    mouseCursorPosition: CGPoint(x: 10, y: 10),
                    mouseButton: .left
                ) else {
                    assertTrue(false, "Failed to create event for \(mouseType)")
                    continue
                }
                event.setIntegerValueField(CGEventSerializer.cachedMainDisplayHeightField, value: 9999)
                event.setIntegerValueField(CGEventSerializer.cachedWindowHeightField, value: 8888)

                guard let data = CGEventSerializer.serialize(event, mode: .direct),
                      let restored = CGEventSerializer.deserialize(data, mode: .direct, eventSource: nil, currentMouseLocation: coord) else {
                    assertTrue(false, "Failed round-trip for \(coord)")
                    continue
                }

                assertEqual(restored.getIntegerValueField(CGEventSerializer.cachedMainDisplayHeightField), 0)
                assertEqual(restored.getIntegerValueField(CGEventSerializer.cachedWindowHeightField), 0)

                restored.location = coord
                assertAlmostEqual(restored.location.x, coord.x)
                assertAlmostEqual(restored.location.y, coord.y)
                assertAlmostEqual(restored.unflippedLocation.x, coord.x)
                assertAlmostEqual(restored.unflippedLocation.y, localMainDisplayHeight - coord.y)
            }
        }

        runTest("testNullEmptyAndInvalidInputHandling") {
            // Non-CGEvent object passed to serialize must return nil
            assertNil(CGEventSerializer.serialize("not a CGEvent" as NSString, mode: .direct))
            assertNil(CGEventSerializer.serialize("not a CGEvent" as NSString, mode: .legacy))
            assertNil(CGEventSerializer.serialize(NSObject(), mode: .direct))

            // Empty Data passed to deserialize must return nil
            assertNil(
                CGEventSerializer.deserialize(
                    Data(),
                    mode: .direct,
                    eventSource: nil,
                    currentMouseLocation: .zero
                )
            )
            assertNil(
                CGEventSerializer.deserialize(
                    Data(),
                    mode: .legacy,
                    eventSource: nil,
                    currentMouseLocation: .zero
                )
            )

            // Corrupted / truncated payload in .direct mode must return nil safely
            let garbageData = Data([0x01, 0x02, 0x03, 0x04])
            assertNil(
                CGEventSerializer.deserialize(
                    garbageData,
                    mode: .direct,
                    eventSource: nil,
                    currentMouseLocation: .zero
                )
            )
        }

        runTest("testLegacyModeRoundTripMouseAndKeyboardEvents") {
            // 1. Mouse Down event in .legacy mode
            if let clickEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: CGPoint(x: 100, y: 200),
                mouseButton: .left
            ) {
                clickEvent.setIntegerValueField(.mouseEventNumber, value: 42)
                clickEvent.setIntegerValueField(.mouseEventClickState, value: 2)
                clickEvent.flags = [.maskShift, .maskCommand]

                let data = CGEventSerializer.serialize(clickEvent, mode: .legacy)
                assertNotNil(data)
                if let data = data {
                    let targetPos = CGPoint(x: 300, y: 400)
                    let restored = CGEventSerializer.deserialize(
                        data,
                        mode: .legacy,
                        eventSource: nil,
                        currentMouseLocation: targetPos
                    )
                    assertNotNil(restored)
                    if let restored = restored {
                        assertEqual(restored.type, .leftMouseDown)
                        assertEqual(restored.getIntegerValueField(.mouseEventNumber), 42)
                        assertEqual(restored.getIntegerValueField(.mouseEventClickState), 2)
                        assertTrue(restored.flags.contains(.maskShift))
                        assertTrue(restored.flags.contains(.maskCommand))
                        assertAlmostEqual(restored.location.x, targetPos.x)
                        assertAlmostEqual(restored.location.y, targetPos.y)
                    }
                }
            }

            // 2. Mouse Moved event in .legacy mode
            if let moveEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: 10, y: 20),
                mouseButton: .left
            ) {
                moveEvent.setIntegerValueField(.mouseEventDeltaX, value: -15)
                moveEvent.setIntegerValueField(.mouseEventDeltaY, value: 25)

                if let data = CGEventSerializer.serialize(moveEvent, mode: .legacy),
                   let restored = CGEventSerializer.deserialize(data, mode: .legacy, eventSource: nil, currentMouseLocation: CGPoint(x: 50, y: 60)) {
                    assertEqual(restored.type, .mouseMoved)
                    assertEqual(restored.getIntegerValueField(.mouseEventDeltaX), -15)
                    assertEqual(restored.getIntegerValueField(.mouseEventDeltaY), 25)
                } else {
                    assertTrue(false, "Legacy MouseMoved round-trip failed")
                }
            }

            // 3. KeyDown event in .legacy mode
            if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true) {
                keyEvent.flags = .maskCommand
                if let data = CGEventSerializer.serialize(keyEvent, mode: .legacy),
                   let restored = CGEventSerializer.deserialize(data, mode: .legacy, eventSource: nil, currentMouseLocation: .zero) {
                    assertEqual(restored.type, .keyDown)
                    assertEqual(restored.getIntegerValueField(.keyboardEventKeycode), 0x09)
                    assertTrue(restored.flags.contains(.maskCommand))
                } else {
                    assertTrue(false, "Legacy KeyDown round-trip failed")
                }
            }
        }

        print("=== Test Summary: \(totalTestsRun) tests (\(totalAssertions) assertions), \(failedTests.count) failures ===")
        if !failedTests.isEmpty {
            exit(1)
        }
    }
}

