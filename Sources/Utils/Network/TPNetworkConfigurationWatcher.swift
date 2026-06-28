// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import SystemConfiguration

private let LOCAL_IP_ANY_ADDR = "0.0.0.0"
private let LOCAL_IP_KEY = "localIpAddress"

@MainActor
protocol TPNetworkConfigurationWatcherDelegate: AnyObject {
    func networkConfigurationDidChange(_ watcher: TPNetworkConfigurationWatcher)
}

@objc class TPNetworkConfigurationWatcher: NSObject {
    
    @objc static let shared = TPNetworkConfigurationWatcher()
    
    private var storeRef: SCDynamicStore?
    private var sourceRef: CFRunLoopSource?
    
    var delegate: TPNetworkConfigurationWatcherDelegate?
    
    @objc var localIpAddresses: [String] = []
    @objc var selectedLocalIpAddress: String = LOCAL_IP_ANY_ADDR
    
    private override init() {
        super.init()
        
        localIpAddresses = []
        updateLocalIpAddresses()
        
        if let savedAddress = TPPreferencesManager.sharedPreferencesManager().value(forKey: LOCAL_IP_KEY) as? String {
            selectedLocalIpAddress = savedAddress
        } else {
            selectedLocalIpAddress = LOCAL_IP_ANY_ADDR
        }
        
        if !localIpAddresses.contains(selectedLocalIpAddress) {
            debugLog("Previously selected ip address \(selectedLocalIpAddress) is invalid.")
            selectedLocalIpAddress = LOCAL_IP_ANY_ADDR
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
            "com.abyssoft.teleport" as CFString,
            { (store, changedKeys, info) in
                guard let info = info else { return }
                let watcher = Unmanaged<TPNetworkConfigurationWatcher>.fromOpaque(info).takeUnretainedValue()
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
        
		// As above, but for IPv6
		keys.append(SCDynamicStoreKeyCreateNetworkGlobalEntity(kCFAllocatorDefault, kSCDynamicStoreDomainState, kSCEntNetIPv6))

		// Watch for IPv4 interface configuration changes
		patterns.append(SCDynamicStoreKeyCreateNetworkInterfaceEntity(kCFAllocatorDefault, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetIPv4))

		// As above, but for IPv6
		patterns.append(SCDynamicStoreKeyCreateNetworkInterfaceEntity(kCFAllocatorDefault, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetIPv6))
		
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
        localIpAddresses.removeAll()
        localIpAddresses.append(LOCAL_IP_ANY_ADDR)
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            perror("getifaddrs")
            return
        }
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr != nil else { continue }
            
            let family = interface.ifa_addr.pointee.sa_family
            
            // Skip interfaces that are not UP or are LOOPBACK
            let flags = Int32(interface.ifa_flags)
            if (flags & IFF_UP) == 0 || (flags & IFF_LOOPBACK) != 0 {
                continue
            }
            
            if family == UInt8(AF_INET) {
                var addrBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                
                interface.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sockaddr_in_ptr in
                    var addr = sockaddr_in_ptr.pointee.sin_addr
                    inet_ntop(AF_INET, &addr, &addrBuf, socklen_t(addrBuf.count))
                }
                
                let infName = String(cString: interface.ifa_name)
                if infName.hasPrefix("en") || infName.hasPrefix("bridge") {
                    let ipAddress = String(cString: addrBuf)
                    localIpAddresses.append(ipAddress)
					networkDebugLog("\(String(cString: interface.ifa_name)) : \(ipAddress)")
                }
            }
        }
    }
    
	@MainActor
    @objc func selectLocalIpAddress(_ value: String) {
        guard selectedLocalIpAddress != value else { return }
        
        selectedLocalIpAddress = value
        TPPreferencesManager.sharedPreferencesManager().setValue(value, forKey: LOCAL_IP_KEY)
        networkChanged()
    }
    
    /// Interfaces teleport actually binds to (matches `updateLocalIpAddresses`). AWDL/AirDrop
    /// (`awdl*`, `llw*`), tunnels (`utun*`) and similar flap constantly — especially their IPv6
    /// keys — and must not drive reconnect/notification storms.
    private func isRelevantInterfaceKey(_ keyStr: String) -> Bool {
        let prefix = "State:/Network/Interface/"
        guard keyStr.hasPrefix(prefix) else { return false }
        let name = keyStr.dropFirst(prefix.count).prefix { $0 != "/" }
        return name.hasPrefix("en") || name.hasPrefix("bridge")
    }

    // MARK: - Network Change Callback
    @MainActor
    private func networkChangeCallback(store: SCDynamicStore, changedKeys: [String]) {
        networkDebugLog("_networkChangeCallBack triggered with \(changedKeys.count) changed keys")
        
        // Drop changes on interfaces we never bind to (awdl/llw/utun/IPv6 link-local churn).
        // Without this, AirDrop/AWDL interface flapping floods networkChanged() and starves the
        // main thread (the "potentially harmful notification post rate" warning).
        let changedKeys = changedKeys.filter { isRelevantInterfaceKey($0) }
        if changedKeys.isEmpty {
            networkDebugLog("  -> no relevant interface changes (ignoring awdl/llw/utun/IPv6 churn)")
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
        
        let isControlledAsServer = TPServerController.shared.isControlled
        let serverInterfaceName = TPServerController.shared.currentConnection?.networkInterfaceName
        
        let isControllingAsClient = TPClientController.shared.isControlling
        let clientInterfaceName = TPClientController.shared.currentConnection?.networkInterfaceName
        
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
