// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  ViewModel for device management - handles pairing, connecting, and device state.

import SwiftUI
import Combine

// MARK: - Device Info Model

struct DeviceInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
    let port: Int
    let screenCount: Int
    let hasCertificate: Bool
    let osVersion: Int
    let isPaired: Bool
    let isOnline: Bool
    let isConnected: Bool
    let isControlling: Bool
    let isBeingControlled: Bool
    let macAddresses: [String]
    let isWakeable: Bool
    
    // Reference to the actual remote host
    weak var remoteHost: TPRemoteHost?
    
    @MainActor
    init(from host: TPRemoteHost) {
        self.id = host.identifier
        self.name = host.computerName
        self.address = host.address ?? ""
        self.port = host.port
        self.screenCount = host.screens.count
        self.hasCertificate = host.isCertified
        self.osVersion = host.osVersion
        self.remoteHost = host
        self.macAddresses = host.macAddresses.map { $0.description }
        self.isWakeable = host.wakeable
        
        let state = host.hostState
        // A device is paired if it's in any peered state (offline, online, controlled, or peering)
        // Check each individual state that makes up peeredState
        self.isPaired = state.contains(.peeredOffline) || 
                       state.contains(.peeredOnline) || 
                       state.contains(.controlled) ||
                       state.contains(.peering)
        // A device is online if it's in any of the online states
        // onlineState is a composite: sharedState | peeredOnlineState | controlledState | incompatibleState | peeringState
        self.isOnline = state.contains(.shared) ||
                       state.contains(.peeredOnline) || 
                       state.contains(.controlled) ||
                       state.contains(.peering)
        self.isConnected = state.contains(.controlled) || 
                          (state.contains(.peeredOnline) && DeviceConnectionManager.shared.connectedHosts.contains(host.identifier))
        self.isControlling = state.contains(.controlled)
        self.isBeingControlled = false // Will be set by server controller
    }
    
    var statusText: String {
        if isControlling {
            return "Controlling"
        } else if isConnected {
            return "Connected"
        } else if isOnline {
            return "Online"
        } else if isPaired {
            return "Offline"
        } else {
            return address
        }
    }
    
    /// Connection status text for detail view (more descriptive)
    var connectionStatusText: String {
        if isControlling {
            return "Controlling this device"
        } else if isConnected {
            return "Connected"
        } else if isOnline {
            return "Available"
        } else if isPaired {
            return "Offline"
        } else {
            return "Not connected"
        }
    }
    
    var statusColor: Color {
        if isControlling || isConnected {
            return .green
        } else if isOnline {
            return .blue
        } else {
            return .gray
        }
    }
    
    static func == (lhs: DeviceInfo, rhs: DeviceInfo) -> Bool {
        lhs.id == rhs.id &&
        lhs.isOnline == rhs.isOnline &&
        lhs.isConnected == rhs.isConnected &&
        lhs.isControlling == rhs.isControlling &&
        lhs.isWakeable == rhs.isWakeable
    }
}

// MARK: - Devices ViewModel

@MainActor
final class DevicesViewModel: ObservableObject {
    @Published var pairedDevices: [DeviceInfo] = []
    @Published var nearbyDevices: [DeviceInfo] = []
    @Published var isScanning: Bool = true
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        loadDevices()
    }
    
    // MARK: - Observation
    
    func startObserving() {
        // Observe host state changes
        NotificationCenter.default.publisher(for: NSNotification.Name("TPHostDidUpdateNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadDevices()
            }
            .store(in: &cancellables)
        
        // Observe connection changes
        NotificationCenter.default.publisher(for: NSNotification.Name("TPConnectionStateDidChangeNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadDevices()
            }
            .store(in: &cancellables)
        
        // Observe pairing changes
        NotificationCenter.default.publisher(for: NSNotification.Name("TPHostDidBecomeActivatedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadDevices()
            }
            .store(in: &cancellables)
        
        loadDevices()
    }
    
    func stopObserving() {
        cancellables.removeAll()
    }
    
    // MARK: - Load Devices
    
    func loadDevices() {
        let hostsManager = TPHostsManager.shared
        
        // Get paired devices (peered state)
        let peeredHosts = hostsManager.hosts(with: .peered) as? [TPRemoteHost] ?? []
        pairedDevices = peeredHosts
            .filter { !$0.computerName.isEmpty }  // Filter out devices with empty names
            .map { DeviceInfo(from: $0) }
            .sorted { $0.isOnline && !$1.isOnline }
        
        // Get nearby unpaired devices (shared state only, not peered)
        let sharedHosts = hostsManager.hosts(with: .shared) as? [TPRemoteHost] ?? []
        nearbyDevices = sharedHosts
            .filter { !$0.isInState(.peered) && !$0.computerName.isEmpty }  // Filter out peered and empty names
            .map { DeviceInfo(from: $0) }
    }
    
    // MARK: - Actions
    
    func pair(with device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        
        // Request authentication/pairing
        TPAuthenticationManager.default.requestAuthentication(on: host)
    }
    
    func unpair(device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        
        // Disconnect first if connected
        if device.isConnected {
            disconnect(from: device)
        }
        
        // Remove from trusted hosts
        TPAuthenticationManager.default.host(host, setTrusted: false)
        
        // Reset host state
        if host.isInState(.online) {
            host.hostState = .shared
        } else {
            host.hostState = []
        }
        
        // Save changes
        TPHostsManager.shared.saveHosts()
        
        loadDevices()
    }
    
    func connect(to device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        
        // Use the new connection manager to establish persistent connection
        DeviceConnectionManager.shared.connect(to: host)
    }
    
    func disconnect(from device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        
        // Disconnect using the connection manager
        DeviceConnectionManager.shared.disconnect(from: host)
    }
    
    func wakeUp(device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        guard host.wakeable else { return }
        
        WakeOnLan.wakeUpHost(with: host.macAddresses)
    }
    
    // MARK: - Helper
    
    private func findHost(by identifier: String) -> TPRemoteHost? {
        return TPHostsManager.shared.host(withIdentifier: identifier)
    }
}


