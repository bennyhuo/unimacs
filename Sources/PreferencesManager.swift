// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

// MARK: - Constants

let CURRENT_PREFS_VERSION = Settings.currentPrefsVersion
let PREFS_VERSION = Settings.prefsVersionKey
let ALLOW_CONTROL = Settings.allowControlKey
let REQUIRE_KEY = Settings.requireKeyKey
let AUTOCHECK_VERSION = Settings.autocheckVersionKey
let TRUST_REQUEST_BEHAVIOR = Settings.trustRequestBehaviorKey
let ENABLED_ENCRYPTION = Settings.enabledEncryptionKey
let SWITCH_KEY_TAG = Settings.switchKeyTagKey
let INHIBITION_PERIOD = Settings.inhibitionPeriodKey
let SYNC_FIND_PASTEBOARD = Settings.syncFindPasteboardKey
let WARNED_ABOUT_ACCESSIBILITY = Settings.warnedAboutAccessibilityKey
let HIDE_CONTROL_BEZEL = Settings.hideControlBezelKey
let TRUST_LOCAL_CERTIFICATE = Settings.trustLocalCertificateKey
let CERTIFICATE_IDENTIFIER = Settings.certificateIdentifierKey
let SHOW_SWITCH_ANIMATION = Settings.showSwitchAnimationKey
let SHOW_TEXTUAL_STATUS = Settings.showTextualStatusKey
let ADD_TO_LOGIN_ITEMS = Settings.addToLoginItemsKey
let DISCONNECT_ON_NETWORK_CONFIG_CHANGE = Settings.disconnectOnNetworkConfigChangeKey
let WRAP_ON_STOP_CONTROL = Settings.wrapOnStopControlKey
let ENABLE_DEBUG_LOG = Settings.enableDebugLogKey
let APPLICATIONS_DISABLING_UNIMACS = Settings.applicationsDisablingUnimacsKey
let SYNC_MODIFIERS = Settings.syncModifiersKey
/// When enabled, the control connection uses the Swift Network.framework stack
/// (`NWConnection`/`NWListener`); when disabled it falls back to the legacy ObjC
/// CFSocket/SecureTransport implementation (`UMTCPSecureSocket`).
let USE_SWIFT_NETWORK_STACK = Settings.useSwiftNetworkStackKey
/// When enabled, input events are streamed directly to the remote host for full
/// gesture support. When disabled, the compatibility event-taps mode is used.
let USE_DIRECT_EVENT_TAPS = Settings.useDirectEventTapsKey
/// Cursor hiding strategy while controlling a remote machine. When enabled
/// (Scheme A, the default), Unimacs is brought to the foreground behind a
/// transparent shield window and the public `CGDisplayHideCursor` API is used —
/// this works reliably on macOS 26+. When disabled (Scheme B), the legacy
/// private `SetsCursorInBackground` background hack is used instead.
let USE_CURSOR_SHIELD_WINDOW = Settings.useCursorShieldWindowKey
let ALWAYS_OBSERVE_EVENTS = Settings.alwaysObserveEventsKey
let ENABLE_KEEP_AWAKE = Settings.enableKeepAwakeKey
let KEEP_AWAKE_INTERVAL = Settings.keepAwakeIntervalKey
let SYNC_LOCK_SLEEP = Settings.syncLockSleepKey
let SKIP_CLIPBOARD_AFTER_LOCAL_PASTE = Settings.skipClipboardAfterLocalPasteKey
let ENABLE_CLIPBOARD_TIMEOUT = Settings.enableClipboardTimeoutKey
let CLIPBOARD_TIMEOUT_INTERVAL = Settings.clipboardTimeoutIntervalKey


let COMMAND_PORT = Settings.commandPortKey
let TRANSFER_PORT = Settings.transferPortKey

let COMMAND_KEY_TAG = Settings.commandKeyTag
let ALT_KEY_TAG = Settings.altKeyTag
let CTRL_KEY_TAG = Settings.ctrlKeyTag
let SHIFT_KEY_TAG = Settings.shiftKeyTag
let CAPSLOCK_KEY_TAG = Settings.capslockKeyTag

// Legacy constants for ObjC compatibility
let TRUST_REQUEST_ASK: Int32 = 0
let TRUST_REQUEST_REJECT: Int32 = 1
let TRUST_REQUEST_ACCEPT: Int32 = 2

// MARK: - Notifications

#if DEBUG || PRERELEASE_BUILD
let TPDefaultsWillChangeNotification = "TPDefaultsWillChangeDebugNotification"
let TPDefaultsDidChangeNotification = "TPDefaultsDidChangeDebugNotification"
let TPDefaultsChangeNotification = "TPDefaultsChangeDebugNotification"
let TPPreferencesDidUpgradeNotification = "TPPreferencesDidUpgradeDebugNotification"
#else
let TPDefaultsWillChangeNotification = "TPDefaultsWillChangeNotification"
let TPDefaultsDidChangeNotification = "TPDefaultsDidChangeNotification"
let TPDefaultsChangeNotification = "TPDefaultsChangeNotification"
let TPPreferencesDidUpgradeNotification = "TPPreferencesDidUpgradeNotification"
#endif

let TPPreferencesPreviousVersionKey = "TPPreferencesPreviousVersionKey"

// MARK: - NSNotification.Name Extension

extension NSNotification.Name {
    static let TPDefaultsWillChange = NSNotification.Name(TPDefaultsWillChangeNotification)
    static let TPDefaultsDidChange = NSNotification.Name(TPDefaultsDidChangeNotification)
    static let TPDefaultsChange = NSNotification.Name(TPDefaultsChangeNotification)
    static let TPPreferencesDidUpgrade = NSNotification.Name(TPPreferencesDidUpgradeNotification)
}

// MARK: - NSObject Extension for Preferences Binding

@objc extension NSObject {
    func bind(_ binding: String, toPref prefKey: String) {
        self.bind(NSBindingName(binding), to: PreferencesManager.shared(), withKeyPath: prefKey, options: nil)
    }
}

// MARK: - PreferencesManager

@objc(UMPreferencesManager)
@objcMembers
class PreferencesManager: NSObject {
    
    // MARK: - Singleton
    
    private static let _shared = PreferencesManager()
    
    @objc static func shared() -> PreferencesManager {
        return _shared
    }
    
    // For ObjC compatibility
    @objc class func sharedPreferencesManager() -> PreferencesManager {
        return _shared
    }
    
    // MARK: - Properties
    
    private lazy var defaultsController: NSUserDefaultsController = {
        let appDomainName = Bundle.main.bundleIdentifier ?? ""
        let domainName = Bundle(for: type(of: self)).bundleIdentifier ?? ""
        let defaults = UserDefaults()
        
        if appDomainName != domainName {
            defaults.removeSuite(named: appDomainName)
            defaults.addSuite(named: domainName)
        }
        
        let controller = NSUserDefaultsController(defaults: defaults, initialValues: nil)
        
        #if DEBUG || PRERELEASE_BUILD
        var commandPort = 44276
        var transferPort = 44277
        #else
        var commandPort = 44176
        var transferPort = 44177
        #endif
        

        
        controller.initialValues = [
            ALLOW_CONTROL: false,
            REQUIRE_KEY: false,
            AUTOCHECK_VERSION: true,
            // Secret stuff
            HIDE_CONTROL_BEZEL: false,
            Settings.visibleBordersKey: false,
            Settings.hotBorderStyleKey: 0,
            INHIBITION_PERIOD: 0.2,
            SYNC_FIND_PASTEBOARD: false,
            WARNED_ABOUT_ACCESSIBILITY: false,
            COMMAND_PORT: commandPort,
            TRANSFER_PORT: transferPort,
            TRUST_REQUEST_BEHAVIOR: TrustRequestBehavior.ask.rawValue,
            ENABLED_ENCRYPTION: false,
            SWITCH_KEY_TAG: ALT_KEY_TAG,
            TRUST_LOCAL_CERTIFICATE: true,
            SHOW_SWITCH_ANIMATION: true,
            SHOW_TEXTUAL_STATUS: true,
            ADD_TO_LOGIN_ITEMS: true,
            DISCONNECT_ON_NETWORK_CONFIG_CHANGE: true,
            WRAP_ON_STOP_CONTROL: false,
            ENABLE_DEBUG_LOG: false,
            SYNC_MODIFIERS: true,
            USE_SWIFT_NETWORK_STACK: false,
            USE_DIRECT_EVENT_TAPS: true,
            USE_CURSOR_SHIELD_WINDOW: true,
            ALWAYS_OBSERVE_EVENTS: true,
            ENABLE_KEEP_AWAKE: true,
            KEEP_AWAKE_INTERVAL: 30.0,
            SYNC_LOCK_SLEEP: true,
            SKIP_CLIPBOARD_AFTER_LOCAL_PASTE: true,
            ENABLE_CLIPBOARD_TIMEOUT: true,
            CLIPBOARD_TIMEOUT_INTERVAL: Settings.clipboardTimeoutIntervalDefault
        ]
       
        return controller
    }()
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        
		DistributedNotificationCenter.default().addObserver(
			self,
			selector: #selector(changeDefault(_:)),
			name: NSNotification.Name(TPDefaultsChangeNotification),
			object: nil
		)
    }
    
    deinit {
		DistributedNotificationCenter.default().removeObserver(
			self,
			name: NSNotification.Name(TPDefaultsChangeNotification),
			object: nil
		)
    }
    
    // MARK: - KVO Support
    
    override func value(forKey key: String) -> Any? {
        return defaultsController.value(forKeyPath: "values.\(key)")
    }
    
    override func setValue(_ value: Any?, forKey key: String) {
		willChangeValue(forKey: key)
		DistributedNotificationCenter.default().postNotificationName(
			NSNotification.Name(TPDefaultsWillChangeNotification),
			object: key,
			userInfo: nil,
			deliverImmediately: true
		)
		defaultsController.setValue(value, forKeyPath: "values.\(key)")
		defaultsController.defaults.synchronize()
		DistributedNotificationCenter.default().postNotificationName(
			NSNotification.Name(TPDefaultsDidChangeNotification),
			object: key,
			userInfo: nil,
			deliverImmediately: true
		)
		didChangeValue(forKey: key)
    }
    
    // MARK: - Preference Getters
    
    // Swift-style methods (primary)
    @objc(boolForPref:)
    func bool(forPref pref: String) -> Bool {
        guard let value = value(forKey: pref) else { return false }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        if let stringValue = value as? String {
            return stringValue.boolValue
        }
        return false
    }
    
    @objc(intForPref:)
    func int(forPref pref: String) -> Int32 {
        guard let value = value(forKey: pref) else { return 0 }
        if let intValue = value as? Int32 {
            return intValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.int32Value
        }
        return 0
    }
    
    @objc(floatForPref:)
    func float(forPref pref: String) -> Float {
        guard let value = value(forKey: pref) else { return 0.0 }
        if let floatValue = value as? Float {
            return floatValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.floatValue
        }
        return 0.0
    }
    
    @objc(valueForPref:)
    func value(forPref pref: String) -> Any? {
        return value(forKey: pref)
    }
    
    @objc(portForPref:)
    func port(forPref pref: String) -> Int32 {
        if pref == TRANSFER_PORT {
            return port(forPref: COMMAND_PORT) + 1
        }
        return int(forPref: pref)
    }
    
    // MARK: - Event Handling
    
    @objc func event(_ event: NSEvent, hasRequiredKeyIfNeeded boolPref: String, withTag tagPref: String) -> Bool {
        if !bool(forPref: boolPref) {
            return true
        }
        
        let keyTag = int(forPref: tagPref)
        let keyMask = NSEvent.ModifierFlags(rawValue: 1 << UInt(keyTag))
        return event.modifierFlags.contains(keyMask)
    }
    
    // MARK: - Notification Handlers
    
    @objc private func changeDefault(_ notification: Notification) {
        guard let key = notification.object as? String,
              let userInfo = notification.userInfo,
              let value = userInfo[key] else { return }
        setValue(value, forKey: key)
    }
}
