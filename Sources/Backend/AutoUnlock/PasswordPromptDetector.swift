// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import Carbon
import CoreGraphics
import Darwin

#if !STANDALONE_UNIT_TEST
@preconcurrency import ApplicationServices
#endif

enum PasswordPromptKind: String, Equatable, Sendable {
    case systemDialog
    case secureTextField
    case terminalPassword
}

struct DetectedWindowSnapshot: Equatable, Sendable {
    let windowNumber: Int
    let ownerPID: pid_t
    let ownerName: String
    let bundleIdentifier: String?
    let bounds: CGRect
    let alpha: Double
    let layer: Int
}

struct DetectedAuthProcessSnapshot: Equatable, Sendable {
    let pid: pid_t
    let processName: String
    let bundleIdentifier: String?
}

enum FocusedSecureFieldObservation: Equatable, Sendable {
    case none
    case systemAuthProcess(DetectedAuthProcessSnapshot)
    case nonSystemSecureField
    case plainTextInput
    case terminalSurface
}

struct TerminalProcessSnapshot: Equatable, Sendable {
    let pid: pid_t
    let ppid: pid_t
    let ruid: uid_t
    let tdev: dev_t
    let pgid: pid_t
    let tpgid: pid_t
    let comm: String
}

struct RemoteBiometricShortcut: Equatable, Hashable, Sendable {
    static let relevantModifierFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    static let requiredPrimaryModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    static let modifierOnlyKeyCodes: Set<Int64> = [
        0x36, // kVK_RightCommand
        0x37, // kVK_Command
        0x38, // kVK_Shift
        0x39, // kVK_CapsLock
        0x3A, // kVK_Option
        0x3B, // kVK_Control
        0x3C, // kVK_RightShift
        0x3D, // kVK_RightOption
        0x3E, // kVK_RightControl
        0x3F  // kVK_Function
    ]

    let keyCode: Int64
    let modifierMaskRawValue: UInt64

    var modifierFlags: CGEventFlags {
        CGEventFlags(rawValue: modifierMaskRawValue)
    }

    init?(keyCode: Int64, modifiers: CGEventFlags) {
        let normalized = modifiers.intersection(Self.relevantModifierFlags)
        guard keyCode >= 0,
              keyCode <= 0x7F,
              !Self.modifierOnlyKeyCodes.contains(keyCode),
              keyCode != BiometricShortcutFilter.keyCodeEscape,
              !normalized.intersection(Self.requiredPrimaryModifiers).isEmpty else {
            return nil
        }
        self.keyCode = keyCode
        self.modifierMaskRawValue = normalized.rawValue
    }

    init?(serialized: String?) {
        guard let raw = serialized?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              let parsedKeyCode = Int64(parts[1]) else {
            return nil
        }

        let modifierTokens = parts[0].split(separator: "+", omittingEmptySubsequences: false)
        guard !modifierTokens.isEmpty else {
            return nil
        }

        var flags: CGEventFlags = []
        var seenTokens = Set<String>()
        for tokenSub in modifierTokens {
            let token = String(tokenSub)
            guard !token.isEmpty, seenTokens.insert(token).inserted else {
                return nil
            }
            switch token {
            case "ctrl":
                flags.insert(.maskControl)
            case "opt":
                flags.insert(.maskAlternate)
            case "shift":
                flags.insert(.maskShift)
            case "cmd":
                flags.insert(.maskCommand)
            default:
                return nil
            }
        }

        self.init(keyCode: parsedKeyCode, modifiers: flags)
    }

    var serializedString: String {
        let flags = modifierFlags
        var tokens: [String] = []
        if flags.contains(.maskControl) { tokens.append("ctrl") }
        if flags.contains(.maskAlternate) { tokens.append("opt") }
        if flags.contains(.maskShift) { tokens.append("shift") }
        if flags.contains(.maskCommand) { tokens.append("cmd") }
        return "\(tokens.joined(separator: "+")):\(keyCode)"
    }

    var displayString: String {
        let flags = modifierFlags
        var result = ""
        if flags.contains(.maskControl) { result.append("⌃") }
        if flags.contains(.maskAlternate) { result.append("⌥") }
        if flags.contains(.maskShift) { result.append("⇧") }
        if flags.contains(.maskCommand) { result.append("⌘") }
        result.append(Self.keyLabel(for: keyCode))
        return result
    }

    static func cgEventFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        return result
    }

    private static func keyLabel(for keyCode: Int64) -> String {
        keyLabelsByCode[keyCode] ?? String(format: "Key%02X", keyCode)
    }

    private static let keyLabelsByCode: [Int64: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
        0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x24: "↩",
        0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\",
        0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x30: "⇥",
        0x31: "␣", 0x32: "`", 0x33: "⌫",
        0x40: "F17", 0x41: "KP.", 0x43: "KP*", 0x45: "KP+", 0x47: "KPClear",
        0x4B: "KP/", 0x4C: "KPEnter", 0x4E: "KP-", 0x4F: "F18", 0x50: "F19",
        0x51: "KP=", 0x52: "KP0", 0x53: "KP1", 0x54: "KP2", 0x55: "KP3",
        0x56: "KP4", 0x57: "KP5", 0x58: "KP6", 0x59: "KP7", 0x5A: "F20",
        0x5B: "KP8", 0x5C: "KP9",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x63: "F3", 0x64: "F8", 0x65: "F9",
        0x67: "F11", 0x69: "F13", 0x6A: "F16", 0x6B: "F14", 0x6D: "F10",
        0x6F: "F12", 0x71: "F15", 0x73: "↖", 0x74: "⇞", 0x75: "⌦",
        0x76: "F4", 0x77: "↘", 0x78: "F2", 0x79: "⇟", 0x7A: "F1",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑"
    ]
}

struct DetectedPasswordPrompt: Equatable, Sendable {
    let kind: PasswordPromptKind
    let sessionToken: String
}

enum PasswordPromptClassifier {

    static let systemAuthBundleIDs: Set<String> = [
        "com.apple.SecurityAgent",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.LocalAuthenticationRemoteService",
        "com.apple.AuthenticationServices.Helper",
        "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent",
        "com.apple.UserNotificationCenter"
    ]

    static let systemAuthOwnerNames: Set<String> = [
        "SecurityAgent",
        "coreautha",
        "CoreAuthUI",
        "LocalAuthenticationRemoteService",
        // CGWindowListCopyWindowInfo truncates owner names to 31 characters.
        "LocalAuthenticationRemoteServic",
        "AuthenticationServicesHelper",
        "AuthenticationServicesAgent",
        "UserNotificationCenter"
    ]

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.tabby",
        "com.raphaelamorim.rio"
    ]

    static let terminalOwnerNames: Set<String> = [
        "Terminal",
        "iTerm2",
        "Warp",
        "Ghostty",
        "kitty",
        "Alacritty",
        "WezTerm",
        "Hyper",
        "Tabby",
        "Rio"
    ]

    static let terminalPromptProcessNames: Set<String> = [
        "sudo",
        "su",
        "login",
        "security",
        "passwd",
        "doas",
        "dscl",
        "ssh",
        "ssh-add",
        "scp",
        "sftp"
    ]

    static func isSystemAuthProcess(bundleId: String?, processName: String?) -> Bool {
        if let bundleId = bundleId, systemAuthBundleIDs.contains(bundleId) {
            return true
        }
        guard let trimmedName = processName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedName.isEmpty else {
            return false
        }
        return systemAuthOwnerNames.contains(trimmedName)
            || trimmedName.hasPrefix("AuthenticationServicesHelper")
            || trimmedName.hasPrefix("LocalAuthenticationRemoteService")
    }

    static func isSystemAuthWindow(_ window: DetectedWindowSnapshot) -> Bool {
        guard window.alpha > 0.01,
              window.bounds.width >= 100,
              window.bounds.height >= 24 else {
            return false
        }
        return isSystemAuthProcess(bundleId: window.bundleIdentifier, processName: window.ownerName)
    }

    /// Detects active ViewBridge-hosted auth windows in `.optionAll`, while filtering out idle warmup hosts.
    static func isActiveViewBridgeAuthWindow(_ window: DetectedWindowSnapshot) -> Bool {
        guard window.alpha > 0.01 else {
            return false
        }
        if window.bundleIdentifier == "com.apple.LocalAuthenticationRemoteService"
            || window.ownerName.hasPrefix("LocalAuthenticationRemoteServic") {
            return window.bounds.width >= 100
                && window.bounds.height >= 18
                && window.bounds.height <= 120
        }
        if window.bundleIdentifier == "com.apple.AuthenticationServices.Helper"
            || window.ownerName.hasPrefix("AuthenticationServicesHelper") {
            return window.bounds.width >= 120 && window.bounds.height >= 50
        }
        return false
    }

    static func isTerminalApp(bundleId: String?, ownerName: String?) -> Bool {
        if let bundleId = bundleId, terminalBundleIDs.contains(bundleId) {
            return true
        }
        if let ownerName = ownerName, terminalOwnerNames.contains(ownerName) {
            return true
        }
        return false
    }

    static func hasOwnedTerminalPasswordPrompt(
        uid: uid_t,
        frontmostPID: pid_t,
        frontmostBundleId: String?,
        isDedicatedTerminal: Bool,
        canonicalNoEchoTTYs: Set<dev_t>,
        rawNoEchoTTYs: Set<dev_t>,
        processes: [TerminalProcessSnapshot]
    ) -> Bool {
        guard frontmostPID > 0,
              !canonicalNoEchoTTYs.isEmpty || !rawNoEchoTTYs.isEmpty else {
            return false
        }

        var parentByPID: [pid_t: pid_t] = [:]
        var commByPID: [pid_t: String] = [:]
        var parentPIDs = Set<pid_t>()
        parentByPID.reserveCapacity(processes.count)
        commByPID.reserveCapacity(processes.count)

        for proc in processes {
            parentByPID[proc.pid] = proc.ppid
            commByPID[proc.pid] = proc.comm
            parentPIDs.insert(proc.ppid)
        }

        func isDescendant(of ancestorPID: pid_t, pid: pid_t) -> Bool {
            var current = pid
            var hops = 0
            while current > 1 && hops < 16 {
                if current == ancestorPID {
                    return true
                }
                guard let parent = parentByPID[current], parent != current else {
                    return false
                }
                current = parent
                hops += 1
            }
            return current == ancestorPID
        }

        func hasAncestorCommPrefix(_ prefix: String, pid: pid_t) -> Bool {
            var current = pid
            var hops = 0
            while current > 1 && hops < 16 {
                if let comm = commByPID[current], comm.hasPrefix(prefix) {
                    return true
                }
                guard let parent = parentByPID[current], parent != current else {
                    return false
                }
                current = parent
                hops += 1
            }
            return false
        }

        let frontmostHasMultiplexerClient = isDedicatedTerminal && processes.contains { proc in
            (proc.comm == "tmux" || proc.comm == "screen" || proc.comm.hasPrefix("tmux:"))
                && isDescendant(of: frontmostPID, pid: proc.pid)
        }
        let allowITermServer = (frontmostBundleId == "com.googlecode.iterm2")

        for proc in processes {
            guard proc.ruid == uid,
                  proc.tdev != -1,
                  proc.pgid == proc.tpgid,
                  !parentPIDs.contains(proc.pid) else {
                continue
            }

            let isOwned = isDescendant(of: frontmostPID, pid: proc.pid)
                || (allowITermServer && hasAncestorCommPrefix("iTermServer", pid: proc.pid))
                || (frontmostHasMultiplexerClient && (
                    hasAncestorCommPrefix("tmux", pid: proc.pid)
                    || hasAncestorCommPrefix("screen", pid: proc.pid)
                ))

            guard isOwned else {
                continue
            }

            if canonicalNoEchoTTYs.contains(proc.tdev) {
                return true
            }
            if rawNoEchoTTYs.contains(proc.tdev) && terminalPromptProcessNames.contains(proc.comm) {
                return true
            }
        }

        return false
    }

    static func classify(
        isScreenLocked: Bool,
        isSecureInputEnabled: Bool,
        windows: [DetectedWindowSnapshot],
        allWindows: [DetectedWindowSnapshot] = [],
        focusedObservation: FocusedSecureFieldObservation = .none,
        frontmostBundleId: String?,
        frontmostOwnerName: String?,
        hasTerminalPasswordPrompt: Bool,
        allowNonSystemPrompts: Bool
    ) -> DetectedPasswordPrompt? {
        guard !isScreenLocked else {
            return nil
        }

        if isSecureInputEnabled {
            if let systemWindow = windows.first(where: isSystemAuthWindow) {
                return DetectedPasswordPrompt(
                    kind: .systemDialog,
                    sessionToken: "sys:\(systemWindow.ownerPID):\(systemWindow.windowNumber)"
                )
            }

            // Use a canonical token across AX and ViewBridge signals so poll transitions do not cancel challenges.
            let embeddedToken = "sys-sheet:\(frontmostBundleId ?? frontmostOwnerName ?? "embedded")"
            if case .systemAuthProcess = focusedObservation {
                return DetectedPasswordPrompt(
                    kind: .systemDialog,
                    sessionToken: embeddedToken
                )
            }

            if focusedObservation == .none,
               !isTerminalApp(bundleId: frontmostBundleId, ownerName: frontmostOwnerName),
               allWindows.contains(where: isActiveViewBridgeAuthWindow) {
                return DetectedPasswordPrompt(
                    kind: .systemDialog,
                    sessionToken: embeddedToken
                )
            }
        }

        guard allowNonSystemPrompts else {
            return nil
        }

        // Never type passwords into plaintext UI inputs such as browser address bars or Find bars.
        if focusedObservation == .plainTextInput {
            return nil
        }

        let isDedicatedTerminal = isTerminalApp(bundleId: frontmostBundleId, ownerName: frontmostOwnerName)
        if hasTerminalPasswordPrompt, (isDedicatedTerminal || focusedObservation == .terminalSurface) {
            return DetectedPasswordPrompt(
                kind: .terminalPassword,
                sessionToken: "terminal-pwd"
            )
        }

        // Guard against terminals with "Secure Keyboard Entry" enabled while idle at a shell prompt.
        if isDedicatedTerminal {
            return nil
        }

        if isSecureInputEnabled, focusedObservation == .nonSystemSecureField {
            return DetectedPasswordPrompt(
                kind: .secureTextField,
                sessionToken: "secure-field"
            )
        }

        return nil
    }
}

enum BiometricShortcutAction: Equatable, Sendable {
    case passThrough
    case swallowOnly
    case triggerBiometricAuthAndSwallow
    case cancelBiometricAuthAndSwallow
}

/// Thread-safe key-event state machine for intercepting the configured trigger shortcut
/// and plain `Esc` (cancel active Touch ID prompt) without leaking key-up events.
final class BiometricShortcutFilter: @unchecked Sendable {

    static let keyCodeBackslash: Int64 = 0x2A
    static let keyCodeEscape: Int64 = 53
    private static let relevantModifiers: CGEventFlags = RemoteBiometricShortcut.relevantModifierFlags

    private let lock = NSLock()
    private var configuredShortcut: RemoteBiometricShortcut?
    private var swallowingTriggerKeyCode: Int64?
    private var swallowingCancelEscKeyUp = false

    init(shortcut: RemoteBiometricShortcut? = nil) {
        self.configuredShortcut = shortcut
    }

    var shortcut: RemoteBiometricShortcut? {
        lock.lock()
        defer { lock.unlock() }
        return configuredShortcut
    }

    func setShortcut(_ shortcut: RemoteBiometricShortcut?) {
        lock.lock()
        configuredShortcut = shortcut
        lock.unlock()
    }

    func reset() {
        lock.lock()
        swallowingTriggerKeyCode = nil
        swallowingCancelEscKeyUp = false
        lock.unlock()
    }

    func processEvent(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        isAutorepeat: Bool,
        userData: Int64,
        isControlling: Bool,
        isBiometricEvaluationActive: Bool
    ) -> BiometricShortcutAction {
        if userData == ScreenUnlocker.injectedEventUserDataTag {
            return .passThrough
        }

        lock.lock()
        defer { lock.unlock() }

        guard isControlling else {
            swallowingTriggerKeyCode = nil
            swallowingCancelEscKeyUp = false
            return .passThrough
        }

        guard type == .keyDown || type == .keyUp else {
            return .passThrough
        }

        if type == .keyUp, let swallowedCode = swallowingTriggerKeyCode, keyCode == swallowedCode {
            swallowingTriggerKeyCode = nil
            return .swallowOnly
        }

        if let trigger = configuredShortcut, keyCode == trigger.keyCode, type == .keyDown {
            let activeModifiers = flags.intersection(Self.relevantModifiers)
            if activeModifiers == trigger.modifierFlags {
                swallowingTriggerKeyCode = keyCode
                return isAutorepeat ? .swallowOnly : .triggerBiometricAuthAndSwallow
            }
        }

        if keyCode == Self.keyCodeEscape {
            if type == .keyDown {
                let hasModifiers = !flags.intersection(Self.relevantModifiers).isEmpty
                if !hasModifiers && isBiometricEvaluationActive {
                    swallowingCancelEscKeyUp = true
                    return isAutorepeat ? .swallowOnly : .cancelBiometricAuthAndSwallow
                }
            } else if swallowingCancelEscKeyUp {
                swallowingCancelEscKeyUp = false
                return .swallowOnly
            }
        }

        return .passThrough
    }
}

#if !STANDALONE_UNIT_TEST

enum SystemPasswordPromptInspector {

    private static let axMessagingTimeoutSeconds: Float = 0.08

    static func inspect(allowNonSystemPrompts: Bool) -> DetectedPasswordPrompt? {
        guard !ScreenUnlocker.isScreenLockedLive() else {
            return nil
        }

        let isSecureInput = IsSecureEventInputEnabled()
        if !allowNonSystemPrompts && !isSecureInput {
            // Fast path: avoid CGWindowListCopyWindowInfo overhead when Secure Event Input is off.
            return nil
        }

        var bundleIdCache: [pid_t: String] = [:]
        let onScreenWindows = currentWindows(
            options: [.optionOnScreenOnly, .excludeDesktopElements],
            bundleIdCache: &bundleIdCache
        )
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontBundleId = frontApp?.bundleIdentifier
        let frontOwnerName = frontApp?.localizedName
        let isDedicatedTerminal = PasswordPromptClassifier.isTerminalApp(
            bundleId: frontBundleId,
            ownerName: frontOwnerName
        )

        var focusedObservation: FocusedSecureFieldObservation = .none
        var allWindows: [DetectedWindowSnapshot] = []
        let hasOnScreenSystemWindow = isSecureInput
            && onScreenWindows.contains(where: PasswordPromptClassifier.isSystemAuthWindow)
        if !hasOnScreenSystemWindow {
            focusedObservation = inspectFocusedSecureElement(
                frontmostPID: frontApp?.processIdentifier,
                frontmostBundleId: frontBundleId,
                frontmostOwnerName: frontOwnerName,
                inspectWindowSheets: isSecureInput
            )
            if isSecureInput, focusedObservation == .none {
                allWindows = currentWindows(options: [.optionAll], bundleIdCache: &bundleIdCache)
            }
        }

        let hasTerminalPrompt: Bool
        if allowNonSystemPrompts,
           focusedObservation != .plainTextInput,
           isDedicatedTerminal || focusedObservation == .terminalSurface {
            hasTerminalPrompt = hasActiveTerminalPasswordPrompt(
                frontmostPID: frontApp?.processIdentifier,
                frontmostBundleId: frontBundleId,
                isDedicatedTerminal: isDedicatedTerminal
            )
        } else {
            hasTerminalPrompt = false
        }

        return PasswordPromptClassifier.classify(
            isScreenLocked: false,
            isSecureInputEnabled: isSecureInput,
            windows: onScreenWindows,
            allWindows: allWindows,
            focusedObservation: focusedObservation,
            frontmostBundleId: frontBundleId,
            frontmostOwnerName: frontOwnerName,
            hasTerminalPasswordPrompt: hasTerminalPrompt,
            allowNonSystemPrompts: allowNonSystemPrompts
        )
    }

    static func isPromptKindStillActiveLive(_ kind: PasswordPromptKind) -> Bool {
        guard !ScreenUnlocker.isScreenLockedLive() else {
            return false
        }

        switch kind {
        case .systemDialog, .secureTextField:
            return IsSecureEventInputEnabled()
        case .terminalPassword:
            let frontApp = NSWorkspace.shared.frontmostApplication
            let isDedicated = PasswordPromptClassifier.isTerminalApp(
                bundleId: frontApp?.bundleIdentifier,
                ownerName: frontApp?.localizedName
            )
            return hasActiveTerminalPasswordPrompt(
                frontmostPID: frontApp?.processIdentifier,
                frontmostBundleId: frontApp?.bundleIdentifier,
                isDedicatedTerminal: isDedicated
            )
        }
    }

    private static func currentWindows(
        options: CGWindowListOption,
        bundleIdCache: inout [pid_t: String]
    ) -> [DetectedWindowSnapshot] {
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return rawList.compactMap { entry in
            let ownerPID = pid_t((entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
            let windowNumber = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0

            var bounds = CGRect.zero
            if let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
               let parsed = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                bounds = parsed
            }

            let bundleId: String?
            if ownerPID > 0 {
                if let cached = bundleIdCache[ownerPID] {
                    bundleId = cached.isEmpty ? nil : cached
                } else {
                    let resolved = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
                    bundleIdCache[ownerPID] = resolved ?? ""
                    bundleId = resolved
                }
            } else {
                bundleId = nil
            }

            return DetectedWindowSnapshot(
                windowNumber: windowNumber,
                ownerPID: ownerPID,
                ownerName: ownerName,
                bundleIdentifier: bundleId,
                bounds: bounds,
                alpha: alpha,
                layer: layer
            )
        }
    }

    private static func inspectFocusedSecureElement(
        frontmostPID: pid_t?,
        frontmostBundleId: String?,
        frontmostOwnerName: String?,
        inspectWindowSheets: Bool
    ) -> FocusedSecureFieldObservation {
        guard AccessibilityManager.isTrusted else {
            return .none
        }

        var nonSystemObservation: FocusedSecureFieldObservation = .none
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, axMessagingTimeoutSeconds)

        if let focusedElem = copyAXElementAttribute(systemWide, attribute: kAXFocusedUIElementAttribute as CFString) {
            AXUIElementSetMessagingTimeout(focusedElem, axMessagingTimeoutSeconds)
            var focusedPID: pid_t = 0
            if AXUIElementGetPid(focusedElem, &focusedPID) == .success,
               let snapshot = authProcessIfSystem(pid: focusedPID) {
                return .systemAuthProcess(snapshot)
            }

            if let childSnapshot = findSystemAuthProcessInSubtree(
                root: focusedElem,
                attributes: [kAXChildrenAttribute as CFString],
                maxDepth: 2,
                maxVisited: 12,
                ignorePID: nil
            ) {
                return .systemAuthProcess(childSnapshot)
            }

            let role = copyAXStringAttribute(focusedElem, attribute: kAXRoleAttribute as CFString)
            let subrole = copyAXStringAttribute(focusedElem, attribute: kAXSubroleAttribute as CFString)
            if subrole == (kAXSecureTextFieldSubrole as String) {
                nonSystemObservation = .nonSystemSecureField
            } else if subrole == (kAXSearchFieldSubrole as String)
                || role == (kAXTextFieldRole as String)
                || role == (kAXComboBoxRole as String) {
                nonSystemObservation = .plainTextInput
            } else if role == (kAXTextAreaRole as String) {
                if PasswordPromptClassifier.isTerminalApp(bundleId: frontmostBundleId, ownerName: frontmostOwnerName)
                    || isTerminalSurfaceElement(focusedElem) {
                    nonSystemObservation = .terminalSurface
                } else {
                    nonSystemObservation = .plainTextInput
                }
            } else if isTerminalSurfaceElement(focusedElem) {
                nonSystemObservation = .terminalSurface
            }
        }

        if inspectWindowSheets, let frontPID = frontmostPID, frontPID > 0 {
            if let frontAuth = authProcessIfSystem(pid: frontPID) {
                return .systemAuthProcess(frontAuth)
            }

            let appElem = AXUIElementCreateApplication(frontPID)
            AXUIElementSetMessagingTimeout(appElem, axMessagingTimeoutSeconds)

            var candidateWindows: [AXUIElement] = []
            for attr in [kAXFocusedWindowAttribute as CFString, kAXMainWindowAttribute as CFString] {
                if let window = copyAXElementAttribute(appElem, attribute: attr),
                   !candidateWindows.contains(where: { CFEqual($0, window) }) {
                    candidateWindows.append(window)
                }
            }

            for window in candidateWindows {
                AXUIElementSetMessagingTimeout(window, axMessagingTimeoutSeconds)
                let windowChildren = copyAXElementsAttribute(window, attribute: kAXChildrenAttribute as CFString)
                var sheets = copyAXElementsAttribute(window, attribute: "AXSheets" as CFString)
                for child in windowChildren where copyAXStringAttribute(child, attribute: kAXRoleAttribute as CFString) == (kAXSheetRole as String) {
                    if !sheets.contains(where: { CFEqual($0, child) }) {
                        sheets.append(child)
                    }
                }
                for sheet in sheets {
                    if let snapshot = findSystemAuthProcessInSubtree(
                        root: sheet,
                        attributes: [
                            "AXSheets" as CFString,
                            kAXChildrenAttribute as CFString,
                            kAXContentsAttribute as CFString
                        ],
                        maxDepth: 4,
                        maxVisited: 32,
                        ignorePID: frontPID
                    ) {
                        return .systemAuthProcess(snapshot)
                    }
                }

                if let snapshot = findSystemAuthProcessInSubtree(
                    root: window,
                    attributes: [
                        kAXChildrenAttribute as CFString,
                        kAXContentsAttribute as CFString
                    ],
                    maxDepth: 2,
                    maxVisited: 16,
                    ignorePID: frontPID
                ) {
                    return .systemAuthProcess(snapshot)
                }
            }
        }

        return nonSystemObservation
    }

    private static func isTerminalSurfaceElement(_ element: AXUIElement) -> Bool {
        let attributes: [CFString] = [
            kAXDescriptionAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXRoleDescriptionAttribute as CFString,
            kAXIdentifierAttribute as CFString,
            kAXHelpAttribute as CFString
        ]
        for attribute in attributes {
            if let value = copyAXStringAttribute(element, attribute: attribute),
               value.localizedCaseInsensitiveContains("terminal") {
                return true
            }
        }
        return false
    }

    private static func findSystemAuthProcessInSubtree(
        root: AXUIElement,
        attributes: [CFString],
        maxDepth: Int,
        maxVisited: Int,
        ignorePID: pid_t?
    ) -> DetectedAuthProcessSnapshot? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited: [AXUIElement] = [root]
        var index = 0

        while index < queue.count {
            let current = queue[index]
            index += 1

            var pid: pid_t = 0
            if AXUIElementGetPid(current.element, &pid) == .success,
               pid != ignorePID,
               let snapshot = authProcessIfSystem(pid: pid) {
                return snapshot
            }

            guard current.depth < maxDepth, visited.count < maxVisited else {
                continue
            }

            AXUIElementSetMessagingTimeout(current.element, axMessagingTimeoutSeconds)
            for attribute in attributes {
                for child in copyAXElementsAttribute(current.element, attribute: attribute) {
                    guard visited.count < maxVisited else {
                        return nil
                    }
                    if !visited.contains(where: { CFEqual($0, child) }) {
                        visited.append(child)
                        queue.append((child, current.depth + 1))
                    }
                }
            }
        }

        return nil
    }

    private static func copyAXElementAttribute(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let ref = value,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return nil
        }
        return (ref as! AXUIElement)
    }

    private static func copyAXElementsAttribute(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let array = value as? [AnyObject] else {
            return []
        }
        return array.compactMap { item in
            let ref: CFTypeRef = item
            return CFGetTypeID(ref) == AXUIElementGetTypeID() ? (ref as! AXUIElement) : nil
        }
    }

    private static func copyAXStringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func authProcessIfSystem(pid: pid_t) -> DetectedAuthProcessSnapshot? {
        guard pid > 0 else {
            return nil
        }
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleId = app?.bundleIdentifier
        let processName = app?.localizedName ?? processCommandName(for: pid) ?? ""
        guard PasswordPromptClassifier.isSystemAuthProcess(bundleId: bundleId, processName: processName) else {
            return nil
        }
        return DetectedAuthProcessSnapshot(
            pid: pid,
            processName: processName,
            bundleIdentifier: bundleId
        )
    }

    private static func processCommandName(for pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return name.isEmpty ? nil : name
    }

    static func hasActiveTerminalPasswordPrompt(
        frontmostPID: pid_t?,
        frontmostBundleId: String?,
        isDedicatedTerminal: Bool
    ) -> Bool {
        guard let frontPID = frontmostPID, frontPID > 0 else {
            return false
        }

        let uid = getuid()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else {
            return false
        }

        var canonicalNoEchoTTYs = Set<dev_t>()
        var rawNoEchoTTYs = Set<dev_t>()
        for name in entries where name.hasPrefix("ttys") {
            let suffix = name.dropFirst(4)
            guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else {
                continue
            }

            let path = "/dev/\(name)"
            var st = stat()
            guard stat(path, &st) == 0, st.st_uid == uid else {
                continue
            }

            let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY)
            guard fd >= 0 else {
                continue
            }
            defer { close(fd) }

            var term = termios()
            guard tcgetattr(fd, &term) == 0 else {
                continue
            }

            let isEcho = (term.c_lflag & tcflag_t(ECHO)) != 0
            guard !isEcho else {
                continue
            }

            let isCanonical = (term.c_lflag & tcflag_t(ICANON)) != 0
            if isCanonical {
                canonicalNoEchoTTYs.insert(st.st_rdev)
            } else {
                rawNoEchoTTYs.insert(st.st_rdev)
            }
        }

        guard !canonicalNoEchoTTYs.isEmpty || !rawNoEchoTTYs.isEmpty else {
            return false
        }

        return PasswordPromptClassifier.hasOwnedTerminalPasswordPrompt(
            uid: uid,
            frontmostPID: frontPID,
            frontmostBundleId: frontmostBundleId,
            isDedicatedTerminal: isDedicatedTerminal,
            canonicalNoEchoTTYs: canonicalNoEchoTTYs,
            rawNoEchoTTYs: rawNoEchoTTYs,
            processes: collectProcessSnapshots()
        )
    }

    private static func collectProcessSnapshots() -> [TerminalProcessSnapshot] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }

        let capacity = (size / MemoryLayout<kinfo_proc>.stride) + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var actualSize = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &actualSize, nil, 0) == 0, actualSize > 0 else {
            return []
        }

        let count = actualSize / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(count).map { proc in
            let comm = withUnsafeBytes(of: proc.kp_proc.p_comm) { raw -> String in
                let bytes = raw.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
            return TerminalProcessSnapshot(
                pid: proc.kp_proc.p_pid,
                ppid: proc.kp_eproc.e_ppid,
                ruid: proc.kp_eproc.e_pcred.p_ruid,
                tdev: dev_t(proc.kp_eproc.e_tdev),
                pgid: proc.kp_eproc.e_pgid,
                tpgid: proc.kp_eproc.e_tpgid,
                comm: comm
            )
        }
    }
}

#endif
