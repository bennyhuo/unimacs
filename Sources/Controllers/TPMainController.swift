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
        // Enforce a single running instance before any controller, listener or
        // Bonjour service is brought up. Multiple instances share the same
        // network identity and cross-wire connections, so the duplicate must
        // surrender to the instance already running and quit immediately.
        guard TPSingleInstanceGuard.acquire() else {
            errorLog("Another instance of teleport is already running; terminating this duplicate.", module: .control)
            TPSingleInstanceGuard.activateExistingInstance()
            NSApp.terminate(nil)
            return
        }
        
        infoLog("=== Application Started/Restarted ===", module: .general)

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

		// Ensure server is listening and proactively connect to paired peers.
		if TPServerController.shared.allowControl {
			TPServerController.shared.startSharing()
		}
		DeviceConnectionManager.shared.autoConnectPairedDevices()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ModernSettingsLauncher.showSettings()
        return true
    }
    
    @objc private func showWarningDialogs() {
        checkAccessibility()
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
        
        // Only lock the machines we control (C -> S). Never broadcast: a server-role peer must
        // not relay its own auto-lock back onto the client that is still being used.
        sendMessageToControlledPeers(message)

        if TPServerController.shared.allowControl {
            TPServerController.shared.startSharing()
        }
    }
    
    @objc func screensDidSleep(_ notification: Notification) {
        debugLog("sleeping screens", module: .control)
        invalidateTimer()
        let message = TPMessage.create(with: .controlScreenSleep)
        
        // Only put the machines we control to sleep (C -> S), never the reverse.
        sendMessageToControlledPeers(message)

        if TPServerController.shared.allowControl {
            TPServerController.shared.startSharing()
        }
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
    }
    
    @objc func sessionDidBecomeActive(_ notification: Notification) {
        if TPServerController.shared.allowControl {
            TPServerController.shared.startSharing()
        }
    }
    
    @objc func computerWillSleep(_ notification: Notification) {
        let message = TPMessage.create(with: .controlDeviceSleep)
        
        // Only the controller propagates its sleep to the machines it controls (C -> S).
        sendMessageToControlledPeers(message)
        
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

		DomainBrowser.shared.restart()
		DeviceConnectionManager.shared.autoConnectPairedDevices()
        
        if TPServerController.shared.allowControl {
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
        TPClientController.shared.cancelControlAttempt()
        
        // Use DeviceConnectionManager as the unified connection management layer
        DeviceConnectionManager.shared.disconnectAll()
    }
    
    @objc func resetAllConnectionsIfNotInControl() {
        debugLog("Try to reset all connections: controlling?\(TPClientController.shared.isControlling), controlled?\(TPServerController.shared.isControlled)", module: .control)
        let client = TPClientController.shared
        let stuckWaitingForControl = client.isWaitingForControlAttempt
        if !DeviceConnectionManager.shared.isConnected || stuckWaitingForControl {
            if stuckWaitingForControl {
                client.cancelControlAttempt()
            }
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
        // Keep every paired peer we control awake while a persistent connection is up — even
        // when we are not actively driving it — so an idle remote screen does not auto-lock /
        // sleep underneath us. `controlWake` stays strictly one-directional (C -> S): it goes
        // only to peers in our peered host list, and the controlled side does not control us
        // back, so there is no wake ping-pong / storm.
        sendMessageToControlledPeers(TPMessage.create(with: .controlWake))
    }

    /// Send a control message strictly in the controller -> controlled (C -> S) direction:
    /// only to the peers this machine controls (its connected, peered hosts).
    ///
    /// Lock / sleep / wake notifications must never flow the other way. A connected machine
    /// that merely *shares* its screen (server role) should not be able to drive the screen
    /// state of the machine controlling it. Broadcasting to every connection let an idle server
    /// that auto-locked send `controlLock` back to the still-active client and lock it too.
    private func sendMessageToControlledPeers(_ message: TPMessage) {
        // If we are currently being controlled by someone else,
        // we must never propagate our own lock/sleep/wake events back or onto other peers.
        // Doing so would cause a feedback loop (lock/wake storm).
        guard !TPServerController.shared.isControlled else {
            debugLog("Skipping system notification propagation (\(message.msgType.displayName)) because we are being controlled by a remote peer", module: .control)
            return
        }

        let peeredHosts = TPHostsManager.shared.hosts(with: .peered) as? [TPRemoteHost] ?? []
        
        // If we are controlling a specific host, we only send to that host.
        if TPClientController.shared.isControlling,
           let controlledHost = TPClientController.shared.currentConnection?.connectedHost {
            if let connection = DeviceConnectionManager.shared.connection(for: controlledHost) {
                debugLog("Propagating system notification (\(message.msgType.displayName)) to controlled host \(controlledHost.computerName)", module: .control)
                connection.sendAsync(message)
            }
            return
        }
        
        // Otherwise (we are holding the cursor and idle), we propagate to all connected peered hosts
        for host in peeredHosts {
            guard let connection = DeviceConnectionManager.shared.connection(for: host) else { continue }
            debugLog("Propagating system notification (\(message.msgType.displayName)) to peer \(host.computerName)", module: .control)
            connection.sendAsync(message)
        }
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
    
    @objc private func prefDidChange(_ notification: Notification) {
        guard let prefKey = notification.object as? String else { return }
        
        if prefKey == CERTIFICATE_IDENTIFIER {
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
