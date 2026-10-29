// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import Foundation
import CoreGraphics

// MARK: - MainController

@MainActor
@objc(MainController)
@objcMembers
class MainController: NSObject, NSApplicationDelegate, NetworkConfigurationWatcherDelegate {
    
    // MARK: - Properties
    
    private static var _sharedController: MainController?
    
    private var previousFrontApp: NSRunningApplication?
    private var wakeTimer: Timer?
    private var hasPendingNetworkReset = false
    
    // MARK: - Singleton
    
    @objc static func shared() -> MainController {
        return _sharedController!
    }
    
    /// ObjC compatibility - maps to +[MainController sharedController]
    @objc static func sharedController() -> MainController {
        return _sharedController!
    }
    
    // MARK: - Host Control Checks
    
    @objc func canBeControlledByHost(withIdentifier identifier: String) -> Bool {
        if ClientController.shared.isControlling {
            if let controlledHost = ClientController.shared.currentConnection?.connectedHost {
                return controlledHost.identifier != identifier
            }
        }
        return true
    }
    
    @objc func canControlHost(withIdentifier identifier: String) -> Bool {
        if ServerController.shared.isControlled {
            if let controllingHost = ServerController.shared.currentConnection?.connectedHost {
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
        guard SingleInstanceGuard.acquire() else {
            errorLog("Another instance of Unimacs is already running; terminating this duplicate.", module: .control)
            SingleInstanceGuard.activateExistingInstance()
            NSApp.terminate(nil)
            return
        }
        
        infoLog("=== Application Started/Restarted ===", module: .general)

        MainController._sharedController = self
        
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
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityStatusDidChange),
            name: .TPAccessibilityStatusDidChange,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(connectionStateDidChange(_:)),
            name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
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
        _ = PreferencesManager.shared()
        _ = EventsController.shared
        _ = ClientController.shared
        _ = ServerController.shared
        _ = StatusItemController.default
        
        if PreferencesManager.shared().bool(forPref: Settings.alwaysObserveEventsKey) {
            _ = EventTapListener.shared.start()
        }
        
        // Data loading
        HostDevicesManager.shared.loadHosts()
        AuthenticationManager.default.loadHosts()
        
        // Browse on Bonjour
        DomainBrowser.shared.start()
        
        // Misc
        TransfersManager.shared.setDelegate(TransferProgressController.shared)
        
        // Warning dialogs
        perform(#selector(showWarningDialogs), with: nil, afterDelay: 0.0)
        
        // Setup initial host borders
        ClientController.shared.updateTriggersAndShowVisualHint(true)
        
        // Notify that we're ready
        HostDevicesManager.shared.notifyChanges()
        
		let peeredHosts = HostDevicesManager.shared.hosts(with: .peered)
        if (peeredHosts.count == 0 && !PreferencesManager.shared().bool(forPref: ALLOW_CONTROL)) || !AccessibilityManager.isTrusted {
            ModernSettingsLauncher.showSettings()
        }
        
        SystemStatusObserver.shared.register()
        
		// Watch the network configuration
		let watcher = NetworkConfigurationWatcher.shared
		watcher.delegate = self
		watcher.startWatching()
		
        PasteboardMonitor.shared.start()

        // Sync login item registration with the stored preference
        let addToLogin = PreferencesManager.shared().bool(forPref: Settings.addToLoginItemsKey)
        LoginItemManager.updateRegistration(enabled: addToLogin)

		// Ensure server is listening and proactively connect to paired peers.
		if ServerController.shared.allowControl {
			ServerController.shared.startSharing()
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
        HostDevicesManager.shared.saveHosts()
        AuthenticationManager.default.saveHosts()
        
        if ClientController.shared.isControlling {
            ClientController.shared.stopControl()
        }
        
        if ServerController.shared.allowControl {
            ServerController.shared.stopSharing()
        }
    }
    
    func applicationWillResignActive(_ aNotification: Notification) {
        if ClientController.shared.isControlling {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    func applicationDidChangeScreenParameters(_ aNotification: Notification) {
        HostDevicesManager.shared.notifyChanges()
        
        if ServerController.shared.allowControl {
            Publisher.shared.updateTXTRecord()
        }
        
        ClientController.shared.updateTriggersAndShowVisualHint(true)
    }
    
    @objc func screenDidLock(_ notification: Notification) {
        let clientController = ClientController.shared
        if clientController.isControlling {
            clientController.stopControl()
        }
        
        debugLog("locking screens", module: .control)
        let message = Message.create(with: .controlLock)
        
        if shouldPropagateLockSleep(messageType: .controlLock) {
            sendMessageToControlledPeers(message)
        }

        if ServerController.shared.allowControl {
            ServerController.shared.startSharing()
        }
    }
    
    @objc func screensDidSleep(_ notification: Notification) {
        debugLog("sleeping screens", module: .control)
        invalidateTimer()
        let message = Message.create(with: .controlScreenSleep)
        
        if shouldPropagateLockSleep(messageType: .controlScreenSleep) {
            sendMessageToControlledPeers(message)
        }

        if ServerController.shared.allowControl {
            ServerController.shared.startSharing()
        }
    }
    
    @objc func screensDidWake(_ notification: Notification) {
        debugLog("waking screens", module: .control)
        setupTimer()
        sendWakeEvent()
    }
    
    @objc func sessionDidResignActive(_ notification: Notification) {
        let clientController = ClientController.shared
        if clientController.isControlling {
            clientController.stopControl()
        } else {
            clientController.currentConnection = nil
        }
        
        let serverController = ServerController.shared
        if serverController.isControlled {
            serverController.stopControl()
        } else {
            serverController.currentConnection = nil
        }
    }
    
    @objc func sessionDidBecomeActive(_ notification: Notification) {
        if ServerController.shared.allowControl {
            ServerController.shared.startSharing()
        }
    }
    
    @objc func computerWillSleep(_ notification: Notification) {
        invalidateTimer()
        
        let message = Message.create(with: .controlDeviceSleep)
        
        if shouldPropagateLockSleep(messageType: .controlDeviceSleep) {
            sendMessageToControlledPeers(message)
        }
        
        if ClientController.shared.isControlling {
            ClientController.shared.stopControl()
        }
        
        if ServerController.shared.allowControl {
            ServerController.shared.stopSharing()
        }
        
        HostDevicesManager.shared.saveHosts()
        AuthenticationManager.default.saveHosts()
    }
    
    @objc func computerDidWake(_ notification: Notification) {
        HostDevicesManager.shared.notifyChanges()
        ClientController.shared.updateTriggersAndShowVisualHint(true)

		DomainBrowser.shared.restart()
		DeviceConnectionManager.shared.autoConnectPairedDevices()
        
        if ServerController.shared.allowControl {
            ServerController.shared.startSharing()
        }
    }
    
    func networkConfigurationDidChange(_ watcher: NetworkConfigurationWatcher) {
        debugLog("Network configuration did change", module: .control)
        
        if PreferencesManager.shared().bool(forPref: DISCONNECT_ON_NETWORK_CONFIG_CHANGE) {
            let activeConnection = ClientController.shared.currentConnection ?? ServerController.shared.currentConnection
            let activeInterface = activeConnection?.networkInterfaceName
            let persistentInterfaceDown = activeConnection == nil && DeviceConnectionManager.shared.allConnections.contains { conn in
                guard let iface = conn.networkInterfaceName else { return false }
                return !NetworkUtils.isInterfaceUp(iface)
            }
            
            if let activeInterface = activeInterface, !NetworkUtils.isInterfaceUp(activeInterface) {
                debugLog("Active connection interface \(activeInterface) went DOWN, resetting immediately", module: .control)
                BezelController.default().showText("Network disconnected, attempting to reconnect...", withDuration: 3.0)
                hasPendingNetworkReset = false
                resetAllConnections()
            } else if persistentInterfaceDown {
                debugLog("Persistent connection interface went DOWN while idle, resetting immediately", module: .control)
                hasPendingNetworkReset = false
                resetAllConnections()
            } else if DeviceConnectionManager.shared.isConnected {
                debugLog("Active connection present, deferring network reset until disconnected", module: .control)
                hasPendingNetworkReset = true
            } else {
                resetAllConnectionsIfNotInControl()
            }
        } else {
            // Even if DISCONNECT_ON_NETWORK_CONFIG_CHANGE is false, if we are not connected,
            // refresh Bonjour publishing and browsing so we bind to any newly available network interfaces.
            resetAllConnectionsIfNotInControl()
        }
    }
    
    @objc private func connectionStateDidChange(_ notification: Notification) {
        if DeviceConnectionManager.shared.isConnected {
            if hasPendingNetworkReset {
                debugLog("Connection established or active, clearing pending network reset flag", module: .control)
                hasPendingNetworkReset = false
            }
        } else if hasPendingNetworkReset {
            debugLog("Executing deferred network reset after all connections disconnected", module: .control)
            hasPendingNetworkReset = false
            resetAllConnections()
        }
    }
    
    @objc func resetAllConnections() {
        let server = ServerController.shared
        if server.allowControl {
            server.stopSharing()
            server.startSharing()
        }
        
        DomainBrowser.shared.restart()
        
        ClientController.shared.stopControl()
        ClientController.shared.cancelControlAttempt()
        
        // Use DeviceConnectionManager as the unified connection management layer
        DeviceConnectionManager.shared.disconnectAll()
    }
    
    @objc func resetAllConnectionsIfNotInControl() {
        debugLog("Try to reset all connections: controlling?\(ClientController.shared.isControlling), controlled?\(ServerController.shared.isControlled)", module: .control)
        let client = ClientController.shared
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
        guard PreferencesManager.shared().bool(forPref: Settings.enableKeepAwakeKey) else {
            invalidateTimer()
            return
        }
        
        let interval = Double(PreferencesManager.shared().float(forPref: Settings.keepAwakeIntervalKey))
        let timeInterval = interval > 0 ? interval : 30.0
        
        if wakeTimer == nil {
            wakeTimer = Timer.scheduledTimer(
                timeInterval: timeInterval,
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
        guard PreferencesManager.shared().bool(forPref: Settings.enableKeepAwakeKey) else {
            invalidateTimer()
            return
        }
        
        guard DeviceConnectionManager.shared.isConnected else {
            return
        }
        
        let isControlling = ClientController.shared.isControlling
        let idleTime = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        
        let interval = Double(PreferencesManager.shared().float(forPref: Settings.keepAwakeIntervalKey))
        let timeInterval = interval > 0 ? interval : 30.0
        
        guard isControlling || idleTime < timeInterval else {
            debugLog("Skipping wake event propagation because this machine is idle (idleTime: \(idleTime)s) and not controlling", module: .control)
            return
        }
        
        sendWakeEvent()
    }
    
    private func sendWakeEvent() {
        guard PreferencesManager.shared().bool(forPref: Settings.enableKeepAwakeKey) else { return }
        
        guard !SystemStatusObserver.shared.isLocked else {
            debugLog("Skipping wake event propagation because this machine is locked", module: .control)
            return
        }
        
        // Keep every paired peer we control awake while a persistent connection is up — even
        // when we are not actively driving it — so an idle remote screen does not auto-lock /
        // sleep underneath us. `controlWake` stays strictly one-directional (C -> S): it goes
        // only to peers in our peered host list, and the controlled side does not control us
        // back, so there is no wake ping-pong / storm.
        sendMessageToControlledPeers(Message.create(with: .controlWake))
    }
    
    private func shouldPropagateLockSleep(messageType: MsgType) -> Bool {
        guard PreferencesManager.shared().bool(forPref: Settings.syncLockSleepKey) else {
            debugLog("Suppressing propagation of \(messageType.displayName) because lock/sleep synchronization is disabled", module: .control)
            return false
        }
        
        let idleTime = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idleTime < 5.0 else {
            debugLog("Suppressing propagation of \(messageType.displayName) because it was triggered by idle inactivity (idleTime: \(idleTime)s)", module: .control)
            return false
        }
        
        return true
    }

    /// Send a control message strictly in the controller -> controlled (C -> S) direction:
    /// only to the peers this machine controls (its connected, peered hosts).
    ///
    /// Lock / sleep / wake notifications must never flow the other way. A connected machine
    /// that merely *shares* its screen (server role) should not be able to drive the screen
    /// state of the machine controlling it. Broadcasting to every connection let an idle server
    /// that auto-locked send `controlLock` back to the still-active client and lock it too.
    private func sendMessageToControlledPeers(_ message: Message) {
        // If we are currently being controlled by someone else,
        // we must never propagate our own lock/sleep/wake events back or onto other peers.
        // Doing so would cause a feedback loop (lock/wake storm).
        guard !ServerController.shared.isControlled else {
            debugLog("Skipping system notification propagation (\(message.msgType.displayName)) because we are being controlled by a remote peer", module: .control)
            return
        }

        let peeredHosts = HostDevicesManager.shared.hosts(with: .peered) as? [RemoteHost] ?? []
        
        // If we are controlling a specific host, we only send to that host.
        if ClientController.shared.isControlling,
           let controlledHost = ClientController.shared.currentConnection?.connectedHost {
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
        _ = AccessibilityManager.checkAccessibility()
    }
    
    @objc private func prefDidChange(_ notification: Notification) {
        guard let prefKey = notification.object as? String else { return }
        
        if prefKey == CERTIFICATE_IDENTIFIER {
            IdentityManager.reloadIdentity()
        } else if prefKey == Settings.alwaysObserveEventsKey {
            let alwaysObserve = PreferencesManager.shared().bool(forPref: Settings.alwaysObserveEventsKey)
            if alwaysObserve {
                _ = EventTapListener.shared.start()
            } else if !ClientController.shared.isControlling {
                EventTapListener.shared.stop()
            }
        } else if prefKey == Settings.enableKeepAwakeKey || prefKey == Settings.keepAwakeIntervalKey {
            invalidateTimer()
            setupTimer()
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
        let frontApp = NSWorkspace.shared.frontmostApplication
        if frontApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousFrontApp = frontApp
            debugLog("Saved previous frontmost app: \(frontApp?.localizedName ?? "unknown")", module: .control)
        }
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func leaveFrontmost() {
        if let app = previousFrontApp {
            app.activate(options: [])
            debugLog("Switched back to previous frontmost app: \(app.localizedName ?? "unknown")", module: .control)
            previousFrontApp = nil
        }
    }
    
    @objc func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        goFrontmost()
        let result = alert.runModal()
        leaveFrontmost()
        return result
    }
    
    @objc private func accessibilityStatusDidChange() {
        if !AccessibilityManager.isTrusted {
            EventTapListener.shared.stop()
        } else {
            if PreferencesManager.shared().bool(forPref: Settings.alwaysObserveEventsKey) {
                _ = EventTapListener.shared.start()
            }
        }
    }
}
