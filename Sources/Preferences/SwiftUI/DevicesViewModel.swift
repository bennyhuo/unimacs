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
    let isConnected: Bool
    let isControlling: Bool
    let isBeingControlled: Bool
    let linkPhase: DeviceLinkPhase
    let reconnectSecondsRemaining: Int?
    let macAddresses: [String]
    let isPortable: Bool
    
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
        
        let manager = DeviceConnectionManager.shared
        self.linkPhase = manager.linkPhase(for: host)
        self.reconnectSecondsRemaining = manager.reconnectSecondsRemaining(for: host)
        
        let state = host.hostState
        self.isPaired = state.contains(.peeredOffline) ||
                       state.contains(.peeredOnline) ||
                       state.contains(.controlled) ||
                       state.contains(.peering)
        self.isConnected = linkPhase == .connected
        self.isControlling = state.contains(.controlled)
        self.isBeingControlled = false
        self.isPortable = host.hasCapability(.portable)
    }
    
    var systemIconName: String {
        isPortable ? "laptopcomputer" : "desktopcomputer"
    }
    
    var statusText: String {
        if isControlling {
            return "Controlling"
        }
        switch linkPhase {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting…"
        case .reconnecting:
            if let seconds = reconnectSecondsRemaining, seconds > 0 {
                return "Reconnecting in \(seconds)s…"
            }
            return "Connecting…"
        case .disconnected:
            return "Disconnected"
        case .unavailable:
            return "Unavailable"
        }
    }
    
    var connectionStatusText: String {
        if isControlling {
            return "Controlling this device"
        }
        switch linkPhase {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting…"
        case .reconnecting:
            if let seconds = reconnectSecondsRemaining, seconds > 0 {
                return "Reconnecting in \(seconds)s…"
            }
            return "Connecting…"
        case .disconnected:
            return "Disconnected"
        case .unavailable:
            return "Unavailable"
        }
    }
    
    var statusColor: Color {
        switch linkPhase {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected, .unavailable:
            return .gray
        }
    }
    
    var showsDisconnectAction: Bool {
        linkPhase == .connected
    }
    
    var showsConnectAction: Bool {
        linkPhase == .disconnected || linkPhase == .unavailable
    }
    
    var showsRetryAction: Bool {
        linkPhase == .reconnecting
    }
    
    static func == (lhs: DeviceInfo, rhs: DeviceInfo) -> Bool {
        lhs.id == rhs.id &&
        lhs.linkPhase == rhs.linkPhase &&
        lhs.reconnectSecondsRemaining == rhs.reconnectSecondsRemaining &&
        lhs.isConnected == rhs.isConnected &&
        lhs.isControlling == rhs.isControlling &&
        lhs.isPortable == rhs.isPortable
    }
}

// MARK: - Devices ViewModel

@MainActor
final class DevicesViewModel: ObservableObject {
    @Published var pairedDevices: [DeviceInfo] = []
    @Published var nearbyDevices: [DeviceInfo] = []
    @Published var isScanning: Bool = true
    
    // MARK: - Local Device Info
    @Published var localName: String = ""
    @Published var localOSVersion: String = ""
    @Published var localScreenCount: Int = 0
    @Published var localSystemIconName: String = "laptopcomputer"
    @Published var localIPAddresses: [String] = []
    @Published var localIPAddress: String = ""
    @Published var localPort: Int = 0
    
    // MARK: - Client (C) Status
    @Published var isClientControlling: Bool = false
    @Published var clientControlledHostName: String? = nil
    @Published var isClientConnecting: Bool = false
    @Published var clientConnectingHostName: String? = nil
    
    // MARK: - Server (S) Status
    @Published var isServerSharing: Bool = false
    @Published var isServerControlled: Bool = false
    @Published var serverControlledHostName: String? = nil
    
    private var cancellables = Set<AnyCancellable>()
    private var countdownTimer: AnyCancellable?
    
    init() {
        loadDevices()
    }
    
    // MARK: - Observation
    
    func startObserving() {
        NotificationCenter.default.publisher(for: NSNotification.Name("TPHostDidUpdateNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadDevices()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: NSNotification.Name("TPConnectionStateDidChangeNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadDevices()
                self?.updateCountdownTimer()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSNotification.Name(TPHostsManager.TPHostsConfigurationDidChangeNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadDevices()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: NSNotification.Name("TPHostDidBecomeActivatedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadDevices()
            }
            .store(in: &cancellables)
            
        DistributedNotificationCenter.default().publisher(for: NSNotification.Name("TPDefaultsDidChangeNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadDevices()
            }
            .store(in: &cancellables)
        
        loadDevices()
        updateCountdownTimer()
    }
    
    func stopObserving() {
        cancellables.removeAll()
        countdownTimer = nil
    }
    
    private func updateCountdownTimer() {
        let needsCountdown = pairedDevices.contains { $0.linkPhase == .reconnecting }
        
        if needsCountdown, countdownTimer == nil {
            countdownTimer = Timer.publish(every: 1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    self?.loadDevices()
                }
        } else if !needsCountdown {
            countdownTimer = nil
        }
    }
    
    // MARK: - Load Devices
    
    func loadDevices() {
        let hostsManager = TPHostsManager.shared
        
        let peeredHosts = hostsManager.hosts(with: .peered) as? [TPRemoteHost] ?? []
        pairedDevices = peeredHosts
            .filter { !$0.computerName.isEmpty }
            .map { DeviceInfo(from: $0) }
            .sorted { lhs, rhs in
                let lhsRank = linkPhaseSortRank(lhs.linkPhase)
                let rhsRank = linkPhaseSortRank(rhs.linkPhase)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.name < rhs.name
            }
        
        let sharedHosts = hostsManager.hosts(with: .shared) as? [TPRemoteHost] ?? []
        nearbyDevices = sharedHosts
            .filter { !$0.isInState(.peered) && !$0.computerName.isEmpty }
            .map { DeviceInfo(from: $0) }
            
        // Load Local Device Details
        let localHost = TPLocalHost.shared
        localName = localHost.computerName
        localOSVersion = formatOSVersion(localHost.osVersion)
        localScreenCount = localHost.screens.count
        localSystemIconName = localHost.hasCapability(.portable) ? "laptopcomputer" : "desktopcomputer"
        
        let watcher = TPNetworkConfigurationWatcher.shared
        let addresses = watcher.localIpAddresses.filter { $0 != "0.0.0.0" }
        localIPAddresses = addresses.isEmpty ? ["Offline"] : addresses
        localPort = Int(TPPreferencesManager.shared().port(forPref: COMMAND_PORT))
        
        // Client Status
        let clientController = TPClientController.shared
        isClientControlling = clientController.isControlling
        clientControlledHostName = clientController.currentConnection?.connectedHost?.computerName
        isClientConnecting = clientController.isWaitingForControlAttempt
        clientConnectingHostName = pairedDevices.first { $0.linkPhase == .connecting || $0.linkPhase == .reconnecting }?.name
        
        // Server Status
        let serverController = TPServerController.shared
        isServerSharing = serverController.allowControl
        isServerControlled = serverController.isControlled
        serverControlledHostName = serverController.currentConnection?.connectedHost?.computerName
        
        // Determine displayed IP address
        let clientConn = clientController.currentConnection
        let serverConn = serverController.currentConnection
        let activeIP: String? = (clientConn?.localAddress ?? serverConn?.localAddress)
        
        if let activeIP = activeIP, !activeIP.isEmpty {
            localIPAddress = activeIP
        } else {
            localIPAddress = localIPAddresses.first ?? "Offline"
        }
        
        updateCountdownTimer()
    }
    
    private func formatOSVersion(_ version: Int) -> String {
        let major = version / 100
        let minor = version % 100
        return "macOS \(major).\(minor)"
    }
    
    private func linkPhaseSortRank(_ phase: DeviceLinkPhase) -> Int {
        switch phase {
        case .connected: return 0
        case .connecting, .reconnecting: return 1
        case .disconnected, .unavailable: return 2
        }
    }
    
    // MARK: - Local Device Actions
    
    func toggleServerSharing() {
        let current = TPServerController.shared.allowControl
        TPServerController.shared.allowControl = !current
        loadDevices()
    }
    
    func stopClientControl() {
        TPClientController.shared.stopControl()
        loadDevices()
    }
    
    func stopServerControl() {
        TPServerController.shared.stopControl()
        loadDevices()
    }
    
    // MARK: - Actions
    
    func pair(with device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        TPAuthenticationManager.default.requestAuthentication(on: host)
    }
    
    func unpair(device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        
        if device.isConnected {
            if let connection = DeviceConnectionManager.shared.connection(for: host) {
                connection.sendAsync(TPMessage.create(with: .unpairNotification)) { [weak self] in
                    self?.disconnect(from: device)
                }
            } else {
                disconnect(from: device)
            }
        } else {
            disconnect(from: device)
        }
        
        TPAuthenticationManager.default.host(host, setTrusted: false)
        
        if host.isInState(.online) {
            host.hostState = .shared
        } else {
            host.hostState = []
        }
        
        TPHostsManager.shared.saveHosts()
        loadDevices()
    }
    
    func connect(to device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        DeviceConnectionManager.shared.connect(to: host, resetRetryBudget: true, ignoreIdRule: true)
    }
    
    func disconnect(from device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        DeviceConnectionManager.shared.disconnect(from: host)
    }
    
    // MARK: - Helper
    
    func device(withId id: String) -> DeviceInfo? {
        pairedDevices.first { $0.id == id } ?? nearbyDevices.first { $0.id == id }
    }

    private func findHost(by identifier: String) -> TPRemoteHost? {
        return TPHostsManager.shared.host(withIdentifier: identifier)
    }
}

