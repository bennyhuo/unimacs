// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import Foundation

// MARK: - C Function Declarations

// Private CGS types and functions for process switching
private struct CPSProcessSerNum {
    var hi: UInt32 = 0
    var lo: UInt32 = 0
}

@_silgen_name("CPSGetFrontProcess")
private func CPSGetFrontProcess(_ psn: UnsafeMutablePointer<CPSProcessSerNum>) -> CGError

@_silgen_name("CPSSetFrontProcess")
private func CPSSetFrontProcess(_ psn: UnsafePointer<CPSProcessSerNum>) -> CGError

// MARK: - TPMainController

@MainActor
@objc(TPMainController)
@objcMembers
class TPMainController: NSObject, NSApplicationDelegate, TPNetworkConfigurationWatcherDelegate {
    
    // MARK: - Properties
    
    private static var _sharedController: TPMainController?
    
    private var frontProcessNum = CPSProcessSerNum()
    private var wakeTimer: Timer?
    
    // MARK: - Singleton
    
    @objc static func shared() -> TPMainController {
        return _sharedController!
    }
    
    /// ObjC compatibility - maps to +[TPMainController sharedController]
    @objc static func sharedController() -> TPMainController {
        return _sharedController!
    }
    
    // MARK: - Host Control Checks
    
    @objc func canBeControlledByHost(withIdentifier identifier: String) -> Bool {
        if TPClientController.shared.isControlling {
            if let controlledHost = TPClientController.shared.currentConnection?.connectedHost {
                return controlledHost.identifier != identifier
            }
        }
        return true
    }
    
    @objc func canControlHost(withIdentifier identifier: String) -> Bool {
        if TPServerController.shared.isControlled {
            if let controllingHost = TPServerController.shared.currentConnection?.connectedHost {
                return controllingHost.identifier != identifier
            }
        }
        return true
    }
    
    // MARK: - Application Delegate
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        TPMainController._sharedController = self
        frontProcessNum.lo = 0
        
        // Setup Notifications
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(prefDidChange(_:)),
			name: .TPDefaultsDidChange,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(prefsDidUpgrade(_:)),
			name: .TPPreferencesDidUpgrade,
            object: nil
        )
        
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidLock(_:)),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(computerWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(computerDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        
        setupTimer()
        
        // Waken controllers
        _ = TPPreferencesManager.shared()
        _ = TPClientController.shared
        _ = TPServerController.shared
        _ = TPStatusItemController.default
        
        // Data loading
        TPHostsManager.shared.loadHosts()
        TPAuthenticationManager.default.loadHosts()
        
        // Browse on Bonjour
        DomainBrowser.shared.start()
        
        // Misc
        TPTransfersManager.shared.setDelegate(TPTransferProgressController.shared)
        
        // Warning dialogs
        perform(#selector(showWarningDialogs), with: nil, afterDelay: 0.0)
        
        // Setup initial host borders
        TPClientController.shared.updateTriggersAndShowVisualHint(true)
        
        // Notify that we're ready
        TPHostsManager.shared.notifyChanges()
        
		let peeredHosts = TPHostsManager.shared.hosts(with: .peered)
        if peeredHosts.count == 0 && !TPPreferencesManager.shared().bool(forPref: ALLOW_CONTROL) {
            ModernSettingsLauncher.showSettings()
        }
        
        SystemStatusObserver.shared.register()
        
		// Watch the network configuration
		let watcher = TPNetworkConfigurationWatcher.shared
		watcher.delegate = self
		watcher.startWatching()
		
        PasteboardMonitor.shared.start()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ModernSettingsLauncher.showSettings()
        return true
    }
    
    @objc private func showWarningDialogs() {
        checkAccessibility()
        checkEncryption()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        TPHostsManager.shared.saveHosts()
        TPAuthenticationManager.default.saveHosts()
        
        if TPClientController.shared.isControlling {
            TPClientController.shared.stopControl()
        }
        
        if TPServerController.shared.allowControl {
            TPServerController.shared.stopSharing()
        }
    }
    
    func applicationWillResignActive(_ aNotification: Notification) {
        if TPClientController.shared.isControlling {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    func applicationDidChangeScreenParameters(_ aNotification: Notification) {
        TPHostsManager.shared.notifyChanges()
        
        if TPServerController.shared.allowControl {
            Publisher.shared.updateTXTRecord()
        }
        
        TPClientController.shared.updateTriggersAndShowVisualHint(true)
    }
    
    @objc func screenDidLock(_ notification: Notification) {
        let clientController = TPClientController.shared
        if clientController.isControlling {
            clientController.stopControl()
        }
        
        debugLog("locking screens", module: .control)
        let message = TPMessage.create(with: .controlLock)
        
        // Send via DeviceConnectionManager (unified connection management)
        DeviceConnectionManager.shared.sendMessageToAllConnectedDevices(message)
    }
    
    @objc func screensDidSleep(_ notification: Notification) {
        debugLog("sleeping screens", module: .control)
        invalidateTimer()
        let message = TPMessage.create(with: .controlScreenSleep)
        
        // Send via DeviceConnectionManager (unified connection management)
        DeviceConnectionManager.shared.sendMessageToAllConnectedDevices(message)
    }
    
    @objc func screensDidWake(_ notification: Notification) {
        debugLog("waking screens", module: .control)
        setupTimer()
        sendWakeEvent()
    }
    
    @objc func sessionDidResignActive(_ notification: Notification) {
        let clientController = TPClientController.shared
        if clientController.isControlling {
            clientController.stopControl()
        } else {
            clientController.currentConnection = nil
        }
        
        let serverController = TPServerController.shared
        if serverController.isControlled {
            serverController.stopControl()
        } else {
            serverController.currentConnection = nil
        }
        
        if serverController.allowControl {
            serverController.stopSharing()
        }
    }
    
    @objc func sessionDidBecomeActive(_ notification: Notification) {
        if TPServerController.shared.allowControl {
            TPServerController.shared.startSharing()
        }
    }
    
    @objc func computerWillSleep(_ notification: Notification) {
        let message = TPMessage.create(with: .controlDeviceSleep)
        
        // Send via DeviceConnectionManager (unified connection management)
        DeviceConnectionManager.shared.sendMessageToAllConnectedDevices(message)
        
        if TPClientController.shared.isControlling {
            TPClientController.shared.stopControl()
        }
        
        if TPServerController.shared.allowControl {
            TPServerController.shared.stopSharing()
        }
        
        TPHostsManager.shared.saveHosts()
        TPAuthenticationManager.default.saveHosts()
    }
    
    @objc func computerDidWake(_ notification: Notification) {
        TPHostsManager.shared.notifyChanges()
        TPClientController.shared.updateTriggersAndShowVisualHint(true)
        
        if let sessionInfoDict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let onConsole = sessionInfoDict[kCGSessionOnConsoleKey as String] as? Bool,
           onConsole,
           TPServerController.shared.allowControl {
            TPServerController.shared.startSharing()
        }
    }
    
    func networkConfigurationDidChange(_ watcher: TPNetworkConfigurationWatcher) {
        debugLog("Network configuration did change", module: .control)
        
        if TPPreferencesManager.shared().bool(forPref: DISCONNECT_ON_NETWORK_CONFIG_CHANGE) {
            resetAllConnectionsIfNotInControl()
        }
    }
    
    @objc func resetAllConnections() {
        let server = TPServerController.shared
        if server.allowControl {
            server.stopSharing()
            server.startSharing()
        }
        
        DomainBrowser.shared.restart()
        
        TPClientController.shared.stopControl()
        
        // Use DeviceConnectionManager as the unified connection management layer
        DeviceConnectionManager.shared.disconnectAll()
    }
    
    @objc func resetAllConnectionsIfNotInControl() {
        debugLog("Try to reset all connections: controlling?\(TPClientController.shared.isControlling), controlled?\(TPServerController.shared.isControlled)", module: .control)
        if !DeviceConnectionManager.shared.isConnected {
            resetAllConnections()
        }
    }
    
    // MARK: - Timer
    
    private func setupTimer() {
        if wakeTimer == nil {
            wakeTimer = Timer.scheduledTimer(
                timeInterval: 50.0,
                target: self,
                selector: #selector(triggerTimer(_:)),
                userInfo: nil,
                repeats: true
            )
            wakeTimer?.tolerance = 8.0
        }
    }
    
    private func invalidateTimer() {
        wakeTimer?.invalidate()
        wakeTimer = nil
    }
    
    @objc private func triggerTimer(_ timer: Timer) {
        sendWakeEvent()
    }
    
    private func sendWakeEvent() {
        let message = TPMessage.create(with: .controlWake)
        
        // Send via DeviceConnectionManager (unified connection management)
        DeviceConnectionManager.shared.sendMessageToAllConnectedDevices(message)
    }
    
    // MARK: - Accessibility & Encryption Checks
    
    private func checkAccessibility() {
        if !AccessibilityManager.checkAccessibility() {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Disabled access for assistive devices", comment: "Text in dialog about accessibility")
            alert.informativeText = NSLocalizedString("The access for assistive devices has been disabled although teleport needs this to operate.\nPlease allow teleport and launch it again.", comment: "Explanation in dialog for accessibility")
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "Button title"))
            
            _ = present(alert)
            
            NSApp.terminate(nil)
        }
    }
    
    private func checkEncryption() {
        if TPPreferencesManager.shared().bool(forPref: ENABLED_ENCRYPTION) {
            if !IdentityManager.hasIdentity() {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Encryption requires a certificate", comment: "Text in dialog for certificate missing error")
                alert.informativeText = NSLocalizedString("In order to activate encryption, teleport needs a valid certificate, but couldn't find one in your Keychain.\nYou'll need to create a certificate and re-activate encryption. Note that the certificate algorithm and key size must match between the server and the clients.\n\nWould you like to launch Certificate Assistant to create a new self-signed certificate?\nRecommended settings: RSA 1024 bits, all others to default values.", comment: "Explanation in dialog for certificate missing error")
                alert.addButton(withTitle: NSLocalizedString("Launch Assistant", comment: "Button title"))
                alert.addButton(withTitle: NSLocalizedString("Disable Encryption", comment: "Button title"))
                
                let returnCode = present(alert)
                
                TPPreferencesManager.shared().setValue(NSNumber(value: false), forKey: ENABLED_ENCRYPTION)
                
                if returnCode == NSApplication.ModalResponse.alertFirstButtonReturn {
                    NSWorkspace.shared.launchApplication(
                        withBundleIdentifier: "com.apple.CertificateAssistant",
                        options: .default,
                        additionalEventParamDescriptor: nil,
                        launchIdentifier: nil
                    )
                }
            }
        } else {
            IdentityManager.setIdentity(nil)
        }
    }
    
    @objc private func prefDidChange(_ notification: Notification) {
        guard let prefKey = notification.object as? String else { return }
        
        if prefKey == ENABLED_ENCRYPTION {
            checkEncryption()
            TPLocalHost.shared.notifyChange()
        } else if prefKey == CERTIFICATE_IDENTIFIER {
            IdentityManager.reloadIdentity()
        }
    }
    
    private let TPTerminateDaemonNotification = "TPTerminateDaemonNotification"
    
    @objc private func prefsDidUpgrade(_ notification: Notification) {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(TPTerminateDaemonNotification),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
    
    // MARK: - UI
    
    @objc func goFrontmost() {
        let result = CPSGetFrontProcess(&frontProcessNum)
        if result != CGError.success {
            frontProcessNum.lo = 0
            debugLog("get front process failed", module: .control)
        } else {
            debugLog("get front process succeded: hi=\(frontProcessNum.hi) low=\(frontProcessNum.lo)", module: .control)
        }
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func leaveFrontmost() {
        if frontProcessNum.lo > 0 {
            _ = CPSSetFrontProcess(&frontProcessNum)
            debugLog("switched back to process hi=\(frontProcessNum.hi) low=\(frontProcessNum.lo)", module: .control)
            frontProcessNum.lo = 0
        }
    }
    
    @objc func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        goFrontmost()
        let result = alert.runModal()
        leaveFrontmost()
        return result
    }
}
