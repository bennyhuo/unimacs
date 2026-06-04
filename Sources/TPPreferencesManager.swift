// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

// MARK: - Constants

let CURRENT_PREFS_VERSION = 7
let PREFS_VERSION = "prefsVersion"
let ALLOW_CONTROL = "allowControl"
let REQUIRE_KEY = "requireKey"
let AUTOCHECK_VERSION = "autocheckVersion"
let TRUST_REQUEST_BEHAVIOR = "trustRequestBehavior"
let ENABLED_ENCRYPTION = "enableEncryption"
let SWITCH_KEY_TAG = "switchKeyTag"
let INHIBITION_PERIOD = "hotBorderActivationDelay"
let SYNC_FIND_PASTEBOARD = "syncFindPasteboard"
let WARNED_ABOUT_ACCESSIBILITY = "warnedAboutAccessibility"
let HIDE_CONTROL_BEZEL = "hideControlBezel"
let TRUST_LOCAL_CERTIFICATE = "trustLocalCertificate"
let CERTIFICATE_IDENTIFIER = "certificateIdentifier"
let SHOW_SWITCH_ANIMATION = "showSwitchAnimation"
let SHOW_TEXTUAL_STATUS = "showTextualStatus"
let ADD_TO_LOGIN_ITEMS = "addToLoginItems"
let DISCONNECT_ON_NETWORK_CONFIG_CHANGE = "disconnectOnNetworkConfigChange"
let WRAP_ON_STOP_CONTROL = "wrapOnStopControl"
let PLAY_SWITCH_SOUND = "playSwitchSound"
let ENABLE_DEBUG_LOG = "enableLogging"
let SWITCH_SOUND_PATH = "switchSoundPath"
let APPLICATIONS_DISABLING_TELEPORT = "appIdentifiersDisablingTeleport"
let SYNC_MODIFIERS = "syncModifiers"

let COMMAND_PORT = "commandPort"
let TRANSFER_PORT = "transferPort"

let COMMAND_KEY_TAG = 20
let ALT_KEY_TAG = 19
let CTRL_KEY_TAG = 18
let SHIFT_KEY_TAG = 17
let CAPSLOCK_KEY_TAG = 16

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
        self.bind(NSBindingName(binding), to: TPPreferencesManager.shared(), withKeyPath: prefKey, options: nil)
    }
}

// MARK: - TPPreferencesManager

@objc(TPPreferencesManager)
@objcMembers
class TPPreferencesManager: NSObject {
    
    // MARK: - Singleton
    
    private static let _shared = TPPreferencesManager()
    
    @objc static func shared() -> TPPreferencesManager {
        return _shared
    }
    
    // For ObjC compatibility
    @objc class func sharedPreferencesManager() -> TPPreferencesManager {
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
        let commandPort = 44276
        let transferPort = 44277
        #else
        let commandPort = 44176
        let transferPort = 44177
        #endif
        
        controller.initialValues = [
            ALLOW_CONTROL: false,
            REQUIRE_KEY: false,
            AUTOCHECK_VERSION: true,
            // Secret stuff
            HIDE_CONTROL_BEZEL: false,
            "visibleBorders": false,
            INHIBITION_PERIOD: 0.2,
            SYNC_FIND_PASTEBOARD: false,
            WARNED_ABOUT_ACCESSIBILITY: false,
            COMMAND_PORT: commandPort,
            TRANSFER_PORT: transferPort,
            TRUST_REQUEST_BEHAVIOR: TrustRequestBehavior.ask.rawValue,
            ENABLED_ENCRYPTION: IdentityManager.hasIdentity(),
            SWITCH_KEY_TAG: ALT_KEY_TAG,
            TRUST_LOCAL_CERTIFICATE: true,
            SHOW_SWITCH_ANIMATION: true,
            SHOW_TEXTUAL_STATUS: true,
            ADD_TO_LOGIN_ITEMS: true,
            DISCONNECT_ON_NETWORK_CONFIG_CHANGE: true,
            WRAP_ON_STOP_CONTROL: true,
            PLAY_SWITCH_SOUND: false,
            ENABLE_DEBUG_LOG: false,
            SYNC_MODIFIERS: true
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
    
    @objc private func defaultsWillChange(_ notification: Notification) {
        guard let keyPath = notification.object as? String else { return }
        willChangeValue(forKey: keyPath)
    }
    
    @objc private func defaultsDidChange(_ notification: Notification) {
        guard let keyPath = notification.object as? String else { return }
        defaultsController.defaults.synchronize()
        didChangeValue(forKey: keyPath)
    }
}
