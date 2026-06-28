// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

// MARK: - Preference Keys (shared between ObjC and Swift)

@objc
public class TPConstants: NSObject {
    
    // MARK: - Version
    
    /// Current preferences version
    @objc public static let currentPrefsVersion = 7
    
    // MARK: - Preference Keys
    
    @objc public static let prefsVersionKey = "prefsVersion"
    @objc public static let allowControlKey = "allowControl"
    @objc public static let requireKeyKey = "requireKey"
    @objc public static let autocheckVersionKey = "autocheckVersion"
    @objc public static let trustRequestBehaviorKey = "trustRequestBehavior"
    @objc public static let enableEncryptionKey = "enableEncryption"
    @objc public static let switchKeyTagKey = "switchKeyTag"
    @objc public static let inhibitionPeriodKey = "hotBorderActivationDelay"
    @objc public static let syncFindPasteboardKey = "syncFindPasteboard"
    @objc public static let warnedAboutAccessibilityKey = "warnedAboutAccessibility"
    @objc public static let hideControlBezelKey = "hideControlBezel"
    @objc public static let trustLocalCertificateKey = "trustLocalCertificate"
    @objc public static let certificateIdentifierKey = "certificateIdentifier"
    @objc public static let showSwitchAnimationKey = "showSwitchAnimation"
    @objc public static let showTextualStatusKey = "showTextualStatus"
    @objc public static let addToLoginItemsKey = "addToLoginItems"
    @objc public static let disconnectOnNetworkConfigChangeKey = "disconnectOnNetworkConfigChange"
    @objc public static let wrapOnStopControlKey = "wrapOnStopControl"
    @objc public static let playSwitchSoundKey = "playSwitchSound"
    @objc public static let enableDebugLogKey = "enableLogging"
    @objc public static let switchSoundPathKey = "switchSoundPath"
    @objc public static let applicationsDisablingTeleportKey = "appIdentifiersDisablingTeleport"
    @objc public static let syncModifiersKey = "syncModifiers"
    @objc public static let useSwiftNetworkStackKey = "useSwiftNetworkStack"
    @objc public static let useDirectEventTapsKey = "useDirectEventTaps"
    @objc public static let useCursorShieldWindowKey = "useCursorShieldWindow"
    
    @objc public static let commandPortKey = "commandPort"
    @objc public static let transferPortKey = "transferPort"
    
    // MARK: - Key Tags
    
    @objc public static let commandKeyTag = 20
    @objc public static let altKeyTag = 19
    @objc public static let ctrlKeyTag = 18
    @objc public static let shiftKeyTag = 17
    @objc public static let capslockKeyTag = 16
    
    // MARK: - Trust Request Behavior
    
    @objc public static let trustRequestAsk = 0
    @objc public static let trustRequestReject = 1
    @objc public static let trustRequestAccept = 2
    
    // MARK: - Notification Names
    
    #if DEBUG
    @objc public static let defaultsWillChangeNotification = "TPDefaultsWillChangeDebugNotification"
    @objc public static let defaultsDidChangeNotification = "TPDefaultsDidChangeDebugNotification"
    @objc public static let defaultsChangeNotification = "TPDefaultsChangeDebugNotification"
    @objc public static let preferencesDidUpgradeNotification = "TPPreferencesDidUpgradeDebugNotification"
    #else
    @objc public static let defaultsWillChangeNotification = "TPDefaultsWillChangeNotification"
    @objc public static let defaultsDidChangeNotification = "TPDefaultsDidChangeNotification"
    @objc public static let defaultsChangeNotification = "TPDefaultsChangeNotification"
    @objc public static let preferencesDidUpgradeNotification = "TPPreferencesDidUpgradeNotification"
    #endif
    
    @objc public static let preferencesPreviousVersionKey = "TPPreferencesPreviousVersionKey"
    
    // Backwards compatibility - expose old #define names as class properties
    @objc public static var PREFS_VERSION: String { prefsVersionKey }
    @objc public static var ALLOW_CONTROL: String { allowControlKey }
    @objc public static var REQUIRE_KEY: String { requireKeyKey }
    @objc public static var AUTOCHECK_VERSION: String { autocheckVersionKey }
    @objc public static var TRUST_REQUEST_BEHAVIOR: String { trustRequestBehaviorKey }
    @objc public static var ENABLED_ENCRYPTION: String { enableEncryptionKey }
    @objc public static var SWITCH_KEY_TAG: String { switchKeyTagKey }
    @objc public static var INHIBITION_PERIOD: String { inhibitionPeriodKey }
    @objc public static var SYNC_FIND_PASTEBOARD: String { syncFindPasteboardKey }
    @objc public static var WARNED_ABOUT_ACCESSIBILITY: String { warnedAboutAccessibilityKey }
    @objc public static var HIDE_CONTROL_BEZEL: String { hideControlBezelKey }
    @objc public static var TRUST_LOCAL_CERTIFICATE: String { trustLocalCertificateKey }
    @objc public static var CERTIFICATE_IDENTIFIER: String { certificateIdentifierKey }
    @objc public static var SHOW_SWITCH_ANIMATION: String { showSwitchAnimationKey }
    @objc public static var SHOW_TEXTUAL_STATUS: String { showTextualStatusKey }
    @objc public static var ADD_TO_LOGIN_ITEMS: String { addToLoginItemsKey }
    @objc public static var DISCONNECT_ON_NETWORK_CONFIG_CHANGE: String { disconnectOnNetworkConfigChangeKey }
    @objc public static var WRAP_ON_STOP_CONTROL: String { wrapOnStopControlKey }
    @objc public static var PLAY_SWITCH_SOUND: String { playSwitchSoundKey }
    @objc public static var ENABLE_DEBUG_LOG: String { enableDebugLogKey }
    @objc public static var SWITCH_SOUND_PATH: String { switchSoundPathKey }
    @objc public static var APPLICATIONS_DISABLING_TELEPORT: String { applicationsDisablingTeleportKey }
    @objc public static var SYNC_MODIFIERS: String { syncModifiersKey }
    @objc public static var USE_SWIFT_NETWORK_STACK: String { useSwiftNetworkStackKey }
    @objc public static var USE_DIRECT_EVENT_TAPS: String { useDirectEventTapsKey }
    @objc public static var USE_CURSOR_SHIELD_WINDOW: String { useCursorShieldWindowKey }
    
    @objc public static var COMMAND_PORT: String { commandPortKey }
    @objc public static var TRANSFER_PORT: String { transferPortKey }
    
    @objc public static var CURRENT_PREFS_VERSION: Int { currentPrefsVersion }
    @objc public static var COMMAND_KEY_TAG: Int { commandKeyTag }
    @objc public static var ALT_KEY_TAG: Int { altKeyTag }
    @objc public static var CTRL_KEY_TAG: Int { ctrlKeyTag }
    @objc public static var SHIFT_KEY_TAG: Int { shiftKeyTag }
    @objc public static var CAPSLOCK_KEY_TAG: Int { capslockKeyTag }
    
    @objc public static var TRUST_REQUEST_ASK: Int { trustRequestAsk }
    @objc public static var TRUST_REQUEST_REJECT: Int { trustRequestReject }
    @objc public static var TRUST_REQUEST_ACCEPT: Int { trustRequestAccept }
    
    @objc public static var TPDefaultsWillChangeNotification: String { defaultsWillChangeNotification }
    @objc public static var TPDefaultsDidChangeNotification: String { defaultsDidChangeNotification }
    @objc public static var TPDefaultsChangeNotification: String { defaultsChangeNotification }
    @objc public static var TPPreferencesDidUpgradeNotification: String { preferencesDidUpgradeNotification }
    @objc public static var TPPreferencesPreviousVersionKey: String { preferencesPreviousVersionKey }
}
