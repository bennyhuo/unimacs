// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

class Settings {
    // MARK: - Versioning
    static let currentPrefsVersion: Int = 7
    static let prefsVersionKey: String = "prefsVersion"

    // MARK: - Core Features (General Settings)

    static let allowControlKey: String = "allowControl"
    static let requireKeyKey: String = "requireKey"
    static let tigerBehaviorKey: String = "tigerBehavior"
    static let hideControlBezelKey: String = "hideControlBezel"
    static let showSwitchAnimationKey: String = "showSwitchAnimation"
    static let showTextualStatusKey: String = "showTextualStatus"
    static let addToLoginItemsKey: String = "addToLoginItems"
    static let disconnectOnNetworkConfigChangeKey: String = "disconnectOnNetworkConfigChange"
    static let wrapOnStopControlKey: String = "wrapOnStopControl"

    /// When enabled, input events are streamed directly to the remote (full gesture
    /// support). When disabled, the compatibility event-taps mode is used instead.
    static let useDirectEventTapsKey: String = "useDirectEventTaps"

    /// When enabled (Scheme A, the default), the local cursor is hidden by bringing
    /// Unimacs to the foreground behind a transparent shield window and using the
    /// public cursor API (works on macOS 26+). When disabled (Scheme B), the legacy
    /// private background hack is used instead.
    static let useCursorShieldWindowKey: String = "useCursorShieldWindow"

	
    // MARK: - Switching Behavior

    static let delayedSwitchKey: String = "delayedSwitch"
    static let switchDelayKey: String = "switchDelay"
    static let switchKeyTagKey: String = "switchKeyTag"

    // MARK: - Security & Encryption

    static let enabledEncryptionKey: String = "enableEncryption"  // Note: Original misspelling retained
    static let trustLocalCertificateKey: String = "trustLocalCertificate"
    static let certificateIdentifierKey: String = "certificateIdentifier"
    static let trustRequestBehaviorKey: String = "trustRequestBehavior"

    // MARK: - Status & Debug

    static let autocheckVersionKey: String = "autocheckVersion"
    static let warnedAboutAccessibilityKey: String = "warnedAboutAccessibility"
    static let enableDebugLogKey: String = "enableLogging"
    static let logLevelKey: String = "logLevel"
    static let applicationsDisablingUnimacsKey: String = "appIdentifiersDisablingUnimacs"
    static let inhibitionPeriodKey: String = "hotBorderActivationDelay"
    static let syncModifiersKey: String = "syncModifiers"
    static let syncFindPasteboardKey: String = "syncFindPasteboard"
    static let visibleBordersKey: String = "visibleBorders"
    static let hotBorderStyleKey: String = "hotBorderStyle"
    static let alwaysObserveEventsKey: String = "alwaysObserveEvents"
    static let layoutShowConnectedOnlyKey: String = "layoutShowConnectedOnly"
    
    // MARK: - Keep Awake & Sync Settings
    static let enableKeepAwakeKey: String = "enableKeepAwake"
    static let keepAwakeIntervalKey: String = "keepAwakeInterval"
    static let syncLockSleepKey: String = "syncLockSleep"


	
    // MARK: - Networking Ports

    static let commandPortKey: String = "commandPort"
    static let transferPortKey: String = "transferPort"
    static let useSwiftNetworkStackKey: String = "useSwiftNetworkStack"
    
    // MARK: - Transfer Settings
    
    /// Minimum transfer size (in KB) to show progress dialog. Transfers smaller than this are silent.
    static let transferProgressThresholdKey: String = "transferProgressThreshold"
    static let transferProgressThresholdDefault: Int = 100  // 100 KB

    /// When enabled, if the user copies content and pastes it locally on the same Mac,
    /// that clipboard content will not be transferred when moving the cursor to another Mac.
    static let skipClipboardAfterLocalPasteKey: String = "skipClipboardAfterLocalPaste"

    /// When enabled, newly copied clipboard content expires for cross-Mac transfer
    /// if the user does not switch to another Mac within `clipboardTimeoutIntervalKey` seconds.
    static let enableClipboardTimeoutKey: String = "enableClipboardTimeout"
    static let clipboardTimeoutIntervalKey: String = "clipboardTimeoutInterval"
    static let clipboardTimeoutIntervalDefault: Double = 60.0
    static let clipboardTimeoutIntervalMin: Double = 30.0
    static let clipboardTimeoutIntervalMax: Double = 600.0

    // MARK: - Key Tags (Numeric Constants)

    static let commandKeyTag: Int = 20
    static let altKeyTag: Int = 19
    static let ctrlKeyTag: Int = 18
    static let shiftKeyTag: Int = 17
    static let capslockKeyTag: Int = 16
}
