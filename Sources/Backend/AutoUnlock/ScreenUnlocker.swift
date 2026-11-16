// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import Carbon
import CoreGraphics

enum KeyStrokeSpec: Equatable, Sendable {
    case keyCode(CGKeyCode, flags: CGEventFlags, char: UniChar)
    case unicode([UniChar])
}

enum ScreenUnlockOutcome: Equatable, Sendable {
    case unlocked
    case alreadyUnlocked
    case cancelled
    case timedOutStillLocked
    case failed(String)
}

final class ScreenUnlockCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

protocol ScreenUnlockingDriver: Sendable {
    func wakeUpScreen()
    func isDisplayAsleep() -> Bool
    func isScreenLockedLive() -> Bool
    func sleep(milliseconds: UInt64)
    @discardableResult
    func postKeyCode(_ keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags, unicodeChars: [UniChar]?) -> Bool
    @discardableResult
    func postFlagsChanged(_ flags: CGEventFlags) -> Bool
    @discardableResult
    func postUnicodeKey(_ chars: [UniChar], keyDown: Bool) -> Bool
}

final class SystemScreenUnlockDriver: ScreenUnlockingDriver, @unchecked Sendable {
    private let eventSource: CGEventSource? = CGEventSource(stateID: .hidSystemState)

    func wakeUpScreen() {
        #if !STANDALONE_UNIT_TEST
        SystemPowerManager.wakeUpScreen()
        #endif
    }

    func isDisplayAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    func isScreenLockedLive() -> Bool {
        ScreenUnlocker.isScreenLockedLive()
    }

    func sleep(milliseconds: UInt64) {
        Thread.sleep(forTimeInterval: TimeInterval(milliseconds) / 1000.0)
    }

    @discardableResult
    func postKeyCode(_ keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags, unicodeChars: [UniChar]?) -> Bool {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: keyDown) else {
            return false
        }
        event.flags = flags.intersection([.maskShift, .maskAlternate, .maskControl, .maskCommand])
        if let unicodeChars = unicodeChars, !unicodeChars.isEmpty {
            var mutableChars = unicodeChars
            event.keyboardSetUnicodeString(stringLength: mutableChars.count, unicodeString: &mutableChars)
        }
        event.setIntegerValueField(.eventSourceUserData, value: ScreenUnlocker.injectedEventUserDataTag)
        event.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    func postFlagsChanged(_ flags: CGEventFlags) -> Bool {
        guard let event = CGEvent(source: eventSource) else {
            return false
        }
        event.type = .flagsChanged
        event.flags = flags.intersection([.maskShift, .maskAlternate, .maskControl, .maskCommand])
        event.setIntegerValueField(.eventSourceUserData, value: ScreenUnlocker.injectedEventUserDataTag)
        event.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    func postUnicodeKey(_ chars: [UniChar], keyDown: Bool) -> Bool {
        guard !chars.isEmpty,
              let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: keyDown) else {
            return false
        }
        event.flags = []
        var mutableChars = chars
        event.keyboardSetUnicodeString(stringLength: mutableChars.count, unicodeString: &mutableChars)
        event.setIntegerValueField(.eventSourceUserData, value: ScreenUnlocker.injectedEventUserDataTag)
        event.post(tap: .cghidEventTap)
        return true
    }
}

enum ScreenUnlocker {

    /// Matches `EventsController.injectedEventUserDataTag` (`0x554D_4556`).
    static let injectedEventUserDataTag: Int64 = 0x554D_4556

    private static let keyCodeDelete: CGKeyCode = 0x33
    private static let keyCodeA: CGKeyCode = 0x00
    private static let keyCodeReturn: CGKeyCode = 0x24

    static func isScreenLockedLive() -> Bool {
        guard let sessionInfo = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (sessionInfo["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    @MainActor
    static func resolveKeyStrokes(
        for password: String,
        keyboardMap: [Character: (CGKeyCode, CGEventFlags)]? = nil
    ) -> [KeyStrokeSpec] {
        let map = keyboardMap ?? currentASCIICapableKeyboardMap()
        return password.map { ch in
            if let mapped = map[ch],
               let scalar = ch.unicodeScalars.first,
               ch.unicodeScalars.count == 1,
               scalar.value <= UInt32(UniChar.max) {
                let sanitizedFlags = mapped.1.intersection([.maskShift, .maskAlternate, .maskControl, .maskCommand])
                return .keyCode(mapped.0, flags: sanitizedFlags, char: UniChar(scalar.value))
            }
            return .unicode(Array(String(ch).utf16))
        }
    }

    @MainActor
    static func currentASCIICapableKeyboardMap() -> [Character: (CGKeyCode, CGEventFlags)] {
        var map = usANSIKeyboardFallbackMap()

        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return map
        }

        let layoutData = unsafeBitCast(rawPtr, to: CFData.self) as Data
        var translatedMap: [Character: (CGKeyCode, CGEventFlags)] = [:]

        layoutData.withUnsafeBytes { rawBuf in
            guard let layoutPtr = rawBuf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return
            }

            let modCombos: [(UInt32, CGEventFlags)] = [
                (0, []),
                (UInt32(shiftKey >> 8) & 0xFF, .maskShift),
                (UInt32(optionKey >> 8) & 0xFF, .maskAlternate),
                (UInt32((shiftKey | optionKey) >> 8) & 0xFF, [.maskShift, .maskAlternate])
            ]
            let keyboardType = UInt32(LMGetKbdType())

            for (modMask, cgFlags) in modCombos {
                for keyCode: UInt16 in 0..<128 {
                    var deadKeyState: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var actualLen = 0
                    let status = UCKeyTranslate(
                        layoutPtr,
                        keyCode,
                        UInt16(kUCKeyActionDown),
                        modMask,
                        keyboardType,
                        UInt32(kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState,
                        chars.count,
                        &actualLen,
                        &chars
                    )
                    if status == noErr,
                       actualLen == 1,
                       let scalar = UnicodeScalar(chars[0]),
                       scalar.value >= 0x20,
                       scalar.value != 0x7F {
                        let ch = Character(scalar)
                        if translatedMap[ch] == nil {
                            translatedMap[ch] = (CGKeyCode(keyCode), cgFlags)
                        }
                    }
                }
            }
        }

        for (char, binding) in translatedMap {
            map[char] = binding
        }
        return map
    }

    static func performUnlock(
        keyStrokes: [KeyStrokeSpec],
        cancellationToken: ScreenUnlockCancellationToken,
        driver: ScreenUnlockingDriver = SystemScreenUnlockDriver()
    ) -> ScreenUnlockOutcome {
        guard !keyStrokes.isEmpty else {
            return .failed("Password keystroke sequence is empty.")
        }

        if cancellationToken.isCancelled {
            return .cancelled
        }
        if !driver.isScreenLockedLive() {
            return .alreadyUnlocked
        }

        let wasDisplayAsleep = driver.isDisplayAsleep()
        driver.wakeUpScreen()

        var waitedDisplayMs: UInt64 = 0
        while driver.isDisplayAsleep() && waitedDisplayMs < 2500 {
            if cancellationToken.isCancelled {
                return .cancelled
            }
            if !driver.isScreenLockedLive() {
                return .alreadyUnlocked
            }
            driver.sleep(milliseconds: 80)
            waitedDisplayMs += 80
        }

        driver.sleep(milliseconds: wasDisplayAsleep ? 350 : 120)

        if cancellationToken.isCancelled {
            return .cancelled
        }
        if !driver.isScreenLockedLive() {
            return .alreadyUnlocked
        }

        // Clear any stray characters in the Lock Screen password field before typing.
        if let earlyOutcome = postKeyPress(
            keyCode: keyCodeDelete,
            flags: [],
            unicodeChars: [0x08],
            cancellationToken: cancellationToken,
            driver: driver
        ) {
            return earlyOutcome
        }
        driver.sleep(milliseconds: 80)

        if let earlyOutcome = postKeyPress(
            keyCode: keyCodeA,
            flags: .maskCommand,
            unicodeChars: [0x61],
            cancellationToken: cancellationToken,
            driver: driver
        ) {
            return earlyOutcome
        }
        driver.sleep(milliseconds: 15)

        if let earlyOutcome = postKeyPress(
            keyCode: keyCodeDelete,
            flags: [],
            unicodeChars: [0x08],
            cancellationToken: cancellationToken,
            driver: driver
        ) {
            return earlyOutcome
        }
        driver.sleep(milliseconds: 40)

        for stroke in keyStrokes {
            if cancellationToken.isCancelled {
                return .cancelled
            }
            if !driver.isScreenLockedLive() {
                return .alreadyUnlocked
            }

            switch stroke {
            case .keyCode(let code, let flags, let char):
                if let earlyOutcome = postKeyPress(
                    keyCode: code,
                    flags: flags,
                    unicodeChars: [char],
                    cancellationToken: cancellationToken,
                    driver: driver
                ) {
                    return earlyOutcome
                }
            case .unicode(let chars):
                if cancellationToken.isCancelled {
                    return .cancelled
                }
                if !driver.isScreenLockedLive() {
                    return .alreadyUnlocked
                }
                guard driver.postUnicodeKey(chars, keyDown: true) else {
                    return .failed("Failed to create Unicode key-down event.")
                }
                driver.sleep(milliseconds: 12)
                if cancellationToken.isCancelled {
                    _ = driver.postUnicodeKey(chars, keyDown: false)
                    return .cancelled
                }
                if !driver.isScreenLockedLive() {
                    return .alreadyUnlocked
                }
                guard driver.postUnicodeKey(chars, keyDown: false) else {
                    return .failed("Failed to create Unicode key-up event.")
                }
            }

            driver.sleep(milliseconds: 18)
        }

        if cancellationToken.isCancelled {
            return .cancelled
        }
        if !driver.isScreenLockedLive() {
            return .alreadyUnlocked
        }

        driver.sleep(milliseconds: 30)

        if let earlyOutcome = postKeyPress(
            keyCode: keyCodeReturn,
            flags: [],
            unicodeChars: [0x0D],
            cancellationToken: cancellationToken,
            driver: driver
        ) {
            return earlyOutcome
        }

        var waitedUnlockMs: UInt64 = 0
        while waitedUnlockMs < 4000 {
            if !driver.isScreenLockedLive() {
                return .unlocked
            }
            if cancellationToken.isCancelled {
                return .cancelled
            }
            driver.sleep(milliseconds: 150)
            waitedUnlockMs += 150
        }

        return driver.isScreenLockedLive() ? .timedOutStillLocked : .unlocked
    }

    private static func postKeyPress(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        unicodeChars: [UniChar]?,
        cancellationToken: ScreenUnlockCancellationToken,
        driver: ScreenUnlockingDriver
    ) -> ScreenUnlockOutcome? {
        if cancellationToken.isCancelled {
            return .cancelled
        }
        if !driver.isScreenLockedLive() {
            return .alreadyUnlocked
        }

        let hasModifiers = !flags.isEmpty
        if hasModifiers {
            guard driver.postFlagsChanged(flags) else {
                return .failed("Failed to post modifier key-down event.")
            }
        }

        guard driver.postKeyCode(keyCode, keyDown: true, flags: flags, unicodeChars: unicodeChars) else {
            if hasModifiers { _ = driver.postFlagsChanged([]) }
            return .failed("Failed to post key-down event.")
        }

        driver.sleep(milliseconds: 12)

        if cancellationToken.isCancelled {
            _ = driver.postKeyCode(keyCode, keyDown: false, flags: flags, unicodeChars: unicodeChars)
            if hasModifiers { _ = driver.postFlagsChanged([]) }
            return .cancelled
        }
        if !driver.isScreenLockedLive() {
            // Release held modifiers cleanly without emitting further keystrokes.
            if hasModifiers { _ = driver.postFlagsChanged([]) }
            return .alreadyUnlocked
        }

        guard driver.postKeyCode(keyCode, keyDown: false, flags: flags, unicodeChars: unicodeChars) else {
            if hasModifiers { _ = driver.postFlagsChanged([]) }
            return .failed("Failed to post key-up event.")
        }

        if hasModifiers {
            _ = driver.postFlagsChanged([])
        }
        return nil
    }

    static func usANSIKeyboardFallbackMap() -> [Character: (CGKeyCode, CGEventFlags)] {
        let lowerLetters: [(Character, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
            ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
            ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37),
            ("j", 38), ("k", 40), ("n", 45), ("m", 46)
        ]
        var map: [Character: (CGKeyCode, CGEventFlags)] = [
            " ": (49, []),
            "0": (29, []), "1": (18, []), "2": (19, []), "3": (20, []), "4": (21, []),
            "5": (23, []), "6": (22, []), "7": (26, []), "8": (28, []), "9": (25, []),
            "-": (27, []), "=": (24, []), "[": (33, []), "]": (30, []), "\\": (42, []),
            ";": (41, []), "'": (39, []), ",": (43, []), ".": (47, []), "/": (44, []),
            "`": (50, []),
            ")": (29, .maskShift), "!": (18, .maskShift), "@": (19, .maskShift),
            "#": (20, .maskShift), "$": (21, .maskShift), "%": (23, .maskShift),
            "^": (22, .maskShift), "&": (26, .maskShift), "*": (28, .maskShift),
            "(": (25, .maskShift), "_": (27, .maskShift), "+": (24, .maskShift),
            "{": (33, .maskShift), "}": (30, .maskShift), "|": (42, .maskShift),
            ":": (41, .maskShift), "\"": (39, .maskShift), "<": (43, .maskShift),
            ">": (47, .maskShift), "?": (44, .maskShift), "~": (50, .maskShift)
        ]
        for (ch, code) in lowerLetters {
            map[ch] = (code, [])
            let upper = Character(ch.uppercased())
            map[upper] = (code, .maskShift)
        }
        return map
    }
}
