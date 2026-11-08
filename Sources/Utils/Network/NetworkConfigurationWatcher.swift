// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import SystemConfiguration

private let LOCAL_IP_ANY_ADDR = NetworkUtils.anyIPv4Address
private let LOCAL_IP_KEY = "localIpAddress"

@MainActor
protocol NetworkConfigurationWatcherDelegate: AnyObject {
    func networkConfigurationDidChange(_ watcher: NetworkConfigurationWatcher)
}

@objc class NetworkConfigurationWatcher: NSObject {
    
    @objc static let shared = NetworkConfigurationWatcher()
    
    private var storeRef: SCDynamicStore?
    private var sourceRef: CFRunLoopSource?
    
    var delegate: NetworkConfigurationWatcherDelegate?
    
    @objc var localIpAddresses: [String] = []
    @objc var selectedLocalIpAddress: String = LOCAL_IP_ANY_ADDR
    private var lastKnownInterfaces: [NetworkInterfaceInfo] = []
    private var hasInitializedInterfaces = false

    /// Active local IPv4 addresses excluding the wildcard `"0.0.0.0"` entry.
    var nonWildcardLocalIpAddresses: [String] {
        localIpAddresses.filter { NetworkUtils.isSpecificBindableIP($0) }
    }
    
    private override init() {
        super.init()
        
        localIpAddresses = []
        updateLocalIpAddresses()
        
        if let savedAddress = PreferencesManager.shared().value(forKey: LOCAL_IP_KEY) as? String {
            selectedLocalIpAddress = savedAddress
        } else {
            selectedLocalIpAddress = LOCAL_IP_ANY_ADDR
        }
        
        if !localIpAddresses.contains(selectedLocalIpAddress) {
            let invalidIP = selectedLocalIpAddress
            debugLog("Previously selected ip address \(invalidIP) is invalid.")
            selectedLocalIpAddress = LOCAL_IP_ANY_ADDR
            Task { @MainActor in
                ActivityLogManager.shared.log(
                    level: .warning,
                    category: .network,
                    title: "Bound local IP \(invalidIP) is no longer active — switched to All Interfaces",
                    detail: "The previously selected network interface IP (\(invalidIP)) is not available on this Mac. Unimacs is now binding to all active interfaces (0.0.0.0)."
                )
            }
        }
    }
    
    @objc func startWatching() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        guard let store = SCDynamicStoreCreate(
            kCFAllocatorDefault,
            "com.bennyhuo.unimacs" as CFString,
            { (store, changedKeys, info) in
                guard let info = info else { return }
                let watcher = Unmanaged<NetworkConfigurationWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.networkChangeCallback(store: store, changedKeys: changedKeys as! [String])
            },
            &context
        ) else {
            NSLog("Error creating the dynamic store")
            return
        }
        
        storeRef = store
        
        var keys: [CFString] = []
        var patterns: [CFString] = []
        
        // Watch for IPv4 configuration changes (e.g. new default route)
		keys.append(SCDynamicStoreKeyCreateNetworkGlobalEntity(kCFAllocatorDefault, kSCDynamicStoreDomainState, kSCEntNetIPv4))

		// Watch for IPv4 interface configuration changes
		patterns.append(SCDynamicStoreKeyCreateNetworkInterfaceEntity(kCFAllocatorDefault, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetIPv4))
		
		// Watch for DNS interface configuration changes
		keys.append(SCDynamicStoreKeyCreateNetworkGlobalEntity(kCFAllocatorDefault, kSCDynamicStoreDomainState, kSCEntNetDNS))
        
        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            NSLog("Error creating the dynamic store runloop source")
            return
        }
        
        sourceRef = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        
        if !SCDynamicStoreSetNotificationKeys(store, keys as CFArray, patterns as CFArray) {
            NSLog("Error setting the dynamic store notification keys")
        }
    }
    
    @objc func stopWatching() {
        if let source = sourceRef {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
            sourceRef = nil
        }
        storeRef = nil
    }
    
	@MainActor
    func networkChanged() {
        networkDebugLog("Network change detected, scheduling notification in 1.0s")
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notifyNetworkChanged), object: nil)
        perform(#selector(notifyNetworkChanged), with: nil, afterDelay: 1.0)
    }
    
	@MainActor
    @objc private func notifyNetworkChanged() {
        networkDebugLog("Notifying delegate of network configuration change")
        delegate?.networkConfigurationDidChange(self)
    }
    
    @objc func updateLocalIpAddresses() {
        let currentInterfaces = NetworkUtils.activeIPv4Interfaces(onlySupported: true)
        let previousInterfaces = lastKnownInterfaces
        let wasInitialized = hasInitializedInterfaces
        lastKnownInterfaces = currentInterfaces
        hasInitializedInterfaces = true

        localIpAddresses.removeAll()
        localIpAddresses.append(LOCAL_IP_ANY_ADDR)
        
        for interface in currentInterfaces {
            localIpAddresses.append(interface.ipAddress)
            networkDebugLog("\(interface.name) : \(interface.ipAddress)")
        }

        if wasInitialized,
           let change = NetworkChangeFormatter.describeChange(previous: previousInterfaces, current: currentInterfaces) {
            Task { @MainActor in
                var actions: [ActivityFixAction] = []
                if change.level == .error || change.level == .warning {
                    actions.append(.openNetworkSettings)
                    actions.append(.resetAllConnections)
                }
                ActivityLogManager.shared.log(
                    level: change.level,
                    category: .network,
                    title: change.title,
                    detail: change.detail,
                    actions: actions
                )
            }
        }
    }
    
	@MainActor
    @objc func selectLocalIpAddress(_ value: String) {
        guard selectedLocalIpAddress != value else { return }
        
        let oldValue = selectedLocalIpAddress
        selectedLocalIpAddress = value
        PreferencesManager.shared().setValue(value, forKey: LOCAL_IP_KEY)
        let displayNew = value == LOCAL_IP_ANY_ADDR ? "All Interfaces (0.0.0.0)" : value
        let displayOld = oldValue == LOCAL_IP_ANY_ADDR ? "All Interfaces (0.0.0.0)" : oldValue
        ActivityLogManager.shared.log(
            level: .info,
            category: .network,
            title: "Bound local IP changed to \(displayNew)",
            detail: "Previous bind address: \(displayOld). Resetting listeners and Bonjour broadcast."
        )
        networkChanged()
    }
    
    /// Interfaces Unimacs actually binds to (matches `updateLocalIpAddresses`). AWDL/AirDrop
    /// (`awdl*`, `llw*`), tunnels (`utun*`) and similar flap constantly and must not drive
    /// reconnect/notification storms.
    private func isRelevantInterfaceKey(_ keyStr: String) -> Bool {
        let prefix = "State:/Network/Interface/"
        guard keyStr.hasPrefix(prefix) else { return false }
        let name = String(keyStr.dropFirst(prefix.count).prefix { $0 != "/" })
        return NetworkUtils.isSupportedInterfaceName(name)
    }

    // MARK: - Network Change Callback
    @MainActor
    private func networkChangeCallback(store: SCDynamicStore, changedKeys: [String]) {
        networkDebugLog("_networkChangeCallBack triggered with \(changedKeys.count) changed keys")
        
        // Drop changes on interfaces we never bind to (awdl/llw/utun churn).
        // Without this, AirDrop/AWDL interface flapping floods networkChanged() and starves the
        // main thread (the "potentially harmful notification post rate" warning).
        let changedKeys = changedKeys.filter { isRelevantInterfaceKey($0) }
        if changedKeys.isEmpty {
            networkDebugLog("  -> no relevant interface changes (ignoring awdl/llw/utun churn)")
            return
        }
        
        for (index, keyStr) in changedKeys.enumerated() {
            networkDebugLog("  Changed key[\(index)]: \(keyStr)")
            if keyStr.hasPrefix("State:/Network/Interface/") && keyStr.hasSuffix("IPv4") {
                networkDebugLog("  -> IPv4 interface change detected, updating local IP addresses")
                updateLocalIpAddresses()
                break
            }
        }
        
        let isControlledAsServer = ServerController.shared.isControlled
        let serverInterfaceName = ServerController.shared.currentConnection?.networkInterfaceName
        
        let isControllingAsClient = ClientController.shared.isControlling
        let clientInterfaceName = ClientController.shared.currentConnection?.networkInterfaceName
        
        debugLog("Network changed: server(\(serverInterfaceName ?? "nil"), \(isControlledAsServer)); client(\(clientInterfaceName ?? "nil"), \(isControllingAsClient))")
        
        let activeServerInterface = isControlledAsServer ? serverInterfaceName : nil
        let activeClientInterface = isControllingAsClient ? clientInterfaceName : nil
        
        networkDebugLog("Active connections - serverInterface: \(activeServerInterface ?? "(none)"), clientInterface: \(activeClientInterface ?? "(none)")")
        
        // Connections in use
        if activeServerInterface != nil || activeClientInterface != nil {
            for keyStr in changedKeys {
                let key = keyStr as CFString
                let value = SCDynamicStoreCopyValue(store, key)
                
                networkDebugLog("  Checking key: \(keyStr), hasValue: \(value != nil ? "YES" : "NO")")
                
                if value == nil {
                    // No value for this inf, should be disconnected.
                    let matchesServer = activeServerInterface != nil && keyStr.hasPrefix("State:/Network/Interface/\(activeServerInterface!)")
                    let matchesClient = activeClientInterface != nil && keyStr.hasPrefix("State:/Network/Interface/\(activeClientInterface!)")
                    
                    if matchesServer || matchesClient {
                        // Only notify changes when the corresponding network interface is down.
                        networkDebugLog("  -> Interface DOWN detected! key=\(keyStr), matchesServer=\(matchesServer), matchesClient=\(matchesClient) - triggering network change")
                        networkChanged()
                        return
                    }
                }
            }
            networkDebugLog("No relevant interface changes detected for active connections")
        } else {
            networkDebugLog("No active connections, notifying network change")
            networkChanged()
        }
    }
}
