// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

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
    let reconnectAttempt: Int
    let maxReconnectAttempts: Int
    let failureDiagnosis: ConnectionFailureDiagnosis?
    let macAddresses: [String]
    let isPortable: Bool
    let lastError: String?
    let shareOutput: Bool
    let shareInput: Bool
    let hasSpeakerHardware: Bool
    let hasMicHardware: Bool
    
    // Reference to the actual remote host
    weak var remoteHost: RemoteHost?
    
    @MainActor
    init(from host: RemoteHost) {
        self.id = host.identifier
        self.name = host.computerName
        self.address = host.address ?? ""
        self.port = host.port
        self.screenCount = host.screens.count
        self.hasCertificate = host.isCertified
        self.osVersion = host.osVersion
        self.remoteHost = host
        self.macAddresses = host.macAddresses.map { $0.description }
        self.shareOutput = host.shareOutput
        self.shareInput = host.shareInput
        self.hasSpeakerHardware = host.hasSpeakerHardware
        self.hasMicHardware = host.hasMicHardware

        let manager = DeviceConnectionManager.shared
        let isBonjourOnline = host.isInState(.peeredOnline)
        self.linkPhase = manager.linkPhase(for: host)
        self.reconnectSecondsRemaining = manager.reconnectSecondsRemaining(for: host)
        self.reconnectAttempt = manager.reconnectAttemptCount(for: host)
        self.maxReconnectAttempts = manager.maxReconnectAttemptsCount
        self.lastError = isBonjourOnline ? host.lastError : nil
        self.failureDiagnosis = isBonjourOnline ? manager.lastDiagnosis(for: host) : nil
        
        let state = host.hostState
        self.isPaired = host.isInState(.peered) || state.contains(.peering)
        self.isConnected = linkPhase == .connected
        self.isControlling = state.contains(.controlled)
        self.isBeingControlled = false
        self.isPortable = host.isPortable
    }
    
    var systemIconName: String {
        isPortable ? "laptopcomputer" : "desktopcomputer"
    }
    
    var statusText: String {
        formattedStatusText(controllingText: "Controlling")
    }
    
    var connectionStatusText: String {
        formattedStatusText(controllingText: "Controlling this device")
    }
    
    private func formattedStatusText(controllingText: String) -> String {
        if isControlling {
            return controllingText
        }
        if let error = lastError, linkPhase == .disconnected || linkPhase == .unavailable {
            return error
        }
        switch linkPhase {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting…"
        case .reconnecting:
            let attemptSuffix = reconnectAttempt > 0 ? " (\(reconnectAttempt)/\(maxReconnectAttempts))" : ""
            let reasonSuffix = (lastError ?? failureDiagnosis?.shortReason).map { " — \($0)" } ?? ""
            if let seconds = reconnectSecondsRemaining, seconds > 0 {
                return "Reconnecting in \(seconds)s\(attemptSuffix)\(reasonSuffix)"
            }
            return "Reconnecting\(attemptSuffix)\(reasonSuffix)"
        case .disconnected:
            return "Disconnected"
        case .unavailable:
            return "Unavailable"
        }
    }
    
    var statusColor: Color {
        if lastError != nil, linkPhase == .disconnected || linkPhase == .unavailable {
            return .red
        }
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
        lhs.reconnectAttempt == rhs.reconnectAttempt &&
        lhs.failureDiagnosis == rhs.failureDiagnosis &&
        lhs.isConnected == rhs.isConnected &&
        lhs.isControlling == rhs.isControlling &&
        lhs.isPortable == rhs.isPortable &&
        lhs.lastError == rhs.lastError &&
        lhs.shareOutput == rhs.shareOutput &&
        lhs.shareInput == rhs.shareInput &&
        lhs.hasSpeakerHardware == rhs.hasSpeakerHardware &&
        lhs.hasMicHardware == rhs.hasMicHardware
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
    @Published var isAccessibilityTrusted: Bool = AccessibilityManager.isTrusted
    
    private var cancellables = Set<AnyCancellable>()
    private var countdownTimer: AnyCancellable?
    
    init() {
        loadDevices()
    }
    
    // MARK: - Observation
    
    func startObserving() {
        NotificationCenter.default.publisher(for: NSNotification.Name("HostDeviceDidUpdateNotification"))
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

        NotificationCenter.default.publisher(for: NSNotification.Name(HostDevicesManager.HostDevicesConfigurationDidChangeNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadDevices()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: NSNotification.Name("HostDeviceDidBecomeActivatedNotification"))
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
        
        NotificationCenter.default.publisher(for: .TPAccessibilityStatusDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.isAccessibilityTrusted = AccessibilityManager.shared.isTrustedState
                self.loadDevices()
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
        isAccessibilityTrusted = AccessibilityManager.isTrusted
        let hostsManager = HostDevicesManager.shared
        
        let peeredHosts = hostsManager.hosts(with: .peered) as? [RemoteHost] ?? []
        pairedDevices = peeredHosts
            .filter { !$0.computerName.isEmpty }
            .map { DeviceInfo(from: $0) }
            .sorted { lhs, rhs in
                let lhsRank = linkPhaseSortRank(lhs.linkPhase)
                let rhsRank = linkPhaseSortRank(rhs.linkPhase)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.name < rhs.name
            }
        
        let sharedHosts = hostsManager.hosts(with: .shared) as? [RemoteHost] ?? []
        nearbyDevices = sharedHosts
            .filter { !$0.isInState(.peered) && !$0.computerName.isEmpty }
            .map { DeviceInfo(from: $0) }
            
        // Load Local Device Details
        let localHost = LocalHost.shared
        localName = localHost.computerName
        localOSVersion = localHost.formattedOSVersion
        localScreenCount = localHost.screens.count
        localSystemIconName = localHost.systemIconName
        
        let watcher = NetworkConfigurationWatcher.shared
        let addresses = watcher.nonWildcardLocalIpAddresses
        localIPAddresses = addresses.isEmpty ? ["Offline"] : addresses
        localPort = Int(PreferencesManager.shared().port(forPref: COMMAND_PORT))
        
        // Client Status
        let clientController = ClientController.shared
        isClientControlling = clientController.isControlling
        clientControlledHostName = clientController.currentConnection?.connectedHost?.computerName
        isClientConnecting = clientController.isWaitingForControlAttempt
        clientConnectingHostName = pairedDevices.first { $0.linkPhase == .connecting || $0.linkPhase == .reconnecting }?.name
        
        // Server Status
        let serverController = ServerController.shared
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
    
    private func linkPhaseSortRank(_ phase: DeviceLinkPhase) -> Int {
        switch phase {
        case .connected: return 0
        case .connecting, .reconnecting: return 1
        case .disconnected, .unavailable: return 2
        }
    }
    
    // MARK: - Local Device Actions
    
    func toggleServerSharing() {
        let current = ServerController.shared.allowControl
        ServerController.shared.allowControl = !current
        loadDevices()
    }
    
    func stopClientControl() {
        ClientController.shared.stopControl()
        loadDevices()
    }
    
    func stopServerControl() {
        ServerController.shared.stopControl()
        loadDevices()
    }
    
    // MARK: - Actions
    
    func pair(with device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        host.lastError = nil
        AuthenticationManager.default.requestAuthentication(on: host)
    }
    
    func unpair(device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        
        if device.isConnected {
            if let connection = DeviceConnectionManager.shared.connection(for: host) {
                connection.sendAsync(Message.create(with: .unpairNotification)) { [weak self] in
                    self?.disconnect(from: device)
                }
            } else {
                disconnect(from: device)
            }
        } else {
            disconnect(from: device)
        }
        
        HostDevicesManager.shared.unpairHost(host)
        loadDevices()
    }
    
    func connect(to device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        host.lastError = nil
        DeviceConnectionManager.shared.connect(to: host, resetRetryBudget: true, ignoreIdRule: true)
    }
    
    func disconnect(from device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        DeviceConnectionManager.shared.disconnect(from: host)
    }
    
    func clearError(for device: DeviceInfo) {
        guard let host = device.remoteHost ?? findHost(by: device.id) else { return }
        host.lastError = nil
        DeviceConnectionManager.shared.clearLastDiagnosis(for: host.identifier)
        loadDevices()
    }
    
    func updateAudioSharingState(for host: RemoteHost) {
        ClientController.shared.updateAudioSharingState(for: host)
        loadDevices()
    }
    
    // MARK: - Helper
    
    func device(withId id: String) -> DeviceInfo? {
        pairedDevices.first { $0.id == id } ?? nearbyDevices.first { $0.id == id }
    }

    private func findHost(by identifier: String) -> RemoteHost? {
        return HostDevicesManager.shared.host(withIdentifier: identifier)
    }
}

