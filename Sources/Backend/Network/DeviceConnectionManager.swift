// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

// MARK: - Link Phase (UI / reachability)

enum DeviceLinkPhase: Equatable {
    case connected
    case connecting
    case reconnecting
    case disconnected
    case unavailable
}

// MARK: - DeviceConnectionDelegate Protocol

/// Delegate protocol for receiving connection events from DeviceConnectionManager
/// Supports both broadcast (all delegates notified) and exclusive (first handler wins) patterns
@MainActor
@objc protocol DeviceConnectionDelegate: AnyObject {
    // MARK: - Broadcast Notifications (all delegates receive these)
    
    /// Called when a connection is established (either as client or from incoming connection)
    @objc optional func connectionDidEstablish(to host: RemoteHost, connection: NetworkConnection)
    
    /// Called when a connection is disconnected
    @objc optional func connectionDidDisconnect(from host: RemoteHost)
    
    /// Called when a connection attempt fails
    @objc optional func connectionDidFail(to host: RemoteHost)
    
    // MARK: - Exclusive Notifications (first handler that returns true wins)
    
    /// Handle incoming message. Return true if the message was handled (stops propagation to other delegates)
    @objc optional func handleMessage(_ message: Message, from host: RemoteHost, connection: NetworkConnection) -> Bool
}

// MARK: - DeviceConnectionManager

/// Manages persistent connections to paired devices
/// Serves as the single source of truth for all network connections
@MainActor
@objcMembers
final class DeviceConnectionManager: NSObject, ObservableObject {
    static let shared = DeviceConnectionManager()
    
    @Published private(set) var connectedHosts: Set<String> = []
    
    private var connections: [String: NetworkConnection] = [:]
    private var keepAliveTimers: [String: Timer] = [:]
    
    // MARK: - Multiple Delegates Support
    
    /// Ordered list of delegates (processed in registration order for exclusive notifications)
    private var delegates: [WeakDelegateWrapper] = []
    
    /// Wrapper to hold weak references to delegates
    private class WeakDelegateWrapper {
        weak var delegate: DeviceConnectionDelegate?
        init(_ delegate: DeviceConnectionDelegate) {
            self.delegate = delegate
        }
    }
    
    // MARK: - Reconnection Properties
    
    /// Hosts that should be auto-reconnected
    private var reconnectingHosts: Set<String> = []
    /// Retry count for each host
    private var reconnectRetryCount: [String: Int] = [:]
    /// Reconnect timers for each host
    private var reconnectTimers: [String: Timer] = [:]
    /// Scheduled wall-clock time for the next reconnect attempt
    private var reconnectNextRetryAt: [String: Date] = [:]
    /// Outbound connect in flight (awaiting TCP handshake / identification)
    private var connectingHosts: Set<String> = []
    /// Hosts that were manually disconnected locally (no auto-reconnect; reject inbound until local Connect)
    private var manuallyDisconnectedHosts: Set<String> = []
    /// Hosts whose peer sent a manual disconnect notification (no auto-reconnect; still accept inbound Connect)
    private var peerDisconnectedHosts: Set<String> = []
    /// Timers for passive probe checks
    private var passiveProbeTimers: [String: Timer] = [:]
    
    /// Base delay for automatic reconnection (seconds); doubles each attempt.
    private let baseReconnectDelay: TimeInterval = 5.0
    /// Maximum automatic reconnection attempts before giving up until manual Connect.
    private let maxReconnectAttempts = 5
    
    /// Whether the server is currently listening for incoming connections
    private(set) var isListening: Bool = false
	
	var isConnected: Bool {
		return connections.first { (key: String, value: NetworkConnection) in
			value.isConnected
		} != nil
	}
    
    private override init() {
        super.init()
    }
    
    // MARK: - Delegate Management
    
    /// Register a delegate to receive connection events
    /// - Parameter delegate: The delegate to register
    func addDelegate(_ delegate: DeviceConnectionDelegate) {
        // Remove any existing nil references
        cleanupDelegates()
        
        // Check if already registered
        if delegates.contains(where: { $0.delegate === delegate }) {
            return
        }
        
        delegates.append(WeakDelegateWrapper(delegate))
        NSLog("DeviceConnectionManager: Added delegate \(type(of: delegate))")
    }
    
    /// Unregister a delegate
    /// - Parameter delegate: The delegate to unregister
    func removeDelegate(_ delegate: DeviceConnectionDelegate) {
        delegates.removeAll { $0.delegate === delegate }
        cleanupDelegates()
        NSLog("DeviceConnectionManager: Removed delegate \(type(of: delegate))")
    }
    
    /// Clean up nil delegate references
    private func cleanupDelegates() {
        delegates.removeAll { $0.delegate == nil }
    }
    
    // MARK: - Delegate Notification Methods
    
    /// Broadcast a notification to all delegates (all receive it)
    private func broadcastConnectionEstablished(to host: RemoteHost, connection: NetworkConnection) {
        cleanupDelegates()
        for wrapper in delegates {
            wrapper.delegate?.connectionDidEstablish?(to: host, connection: connection)
        }
    }
    
    /// Broadcast a disconnection notification to all delegates
    private func broadcastConnectionDisconnected(from host: RemoteHost) {
        cleanupDelegates()
        for wrapper in delegates {
            wrapper.delegate?.connectionDidDisconnect?(from: host)
        }
    }
    
    /// Broadcast a connection failure notification to all delegates
    private func broadcastConnectionFailed(to host: RemoteHost) {
        cleanupDelegates()
        for wrapper in delegates {
            wrapper.delegate?.connectionDidFail?(to: host)
        }
    }
    
    /// Send message to delegates exclusively (first handler that returns true stops propagation)
    /// - Returns: true if any delegate handled the message
    private func notifyMessageExclusively(_ message: Message, from host: RemoteHost, connection: NetworkConnection) -> Bool {
        cleanupDelegates()
        for wrapper in delegates {
            if let handled = wrapper.delegate?.handleMessage?(message, from: host, connection: connection), handled {
                return true
            }
        }
        return false
    }
    
    // MARK: - Connection State
    
    func isConnected(to host: RemoteHost) -> Bool {
        guard connectedHosts.contains(host.identifier) else { return false }
        
        // Also verify the actual socket is connected
        if let connection = connections[host.identifier] {
            if !connection.isConnected {
                // Socket is disconnected, clean up stale state
                warningLog("isConnected check found stale connection for \(host.computerName), socket disconnected", module: .network)
                Task { @MainActor in
                    self.cleanupStaleConnection(for: host.identifier)
                }
                return false
            }
            return true
        }
        return false
    }

    func linkPhase(for host: RemoteHost) -> DeviceLinkPhase {
        let hostId = host.identifier
        
        if isConnected(to: host) {
            return .connected
        }
        if manuallyDisconnectedHosts.contains(hostId) {
            return .disconnected
        }
        if connectingHosts.contains(hostId) {
            return .connecting
        }
        if reconnectTimers[hostId] != nil || reconnectingHosts.contains(hostId) {
            return .reconnecting
        }
        if host.isInState(.peeredOnline) {
            return .disconnected
        }
        return .unavailable
    }
    
    func reconnectSecondsRemaining(for host: RemoteHost) -> Int? {
        guard let retryAt = reconnectNextRetryAt[host.identifier] else { return nil }
        return max(0, Int(ceil(retryAt.timeIntervalSinceNow)))
    }
    
    func isManuallyDisconnected(_ host: RemoteHost) -> Bool {
        manuallyDisconnectedHosts.contains(host.identifier)
    }

    /// Bonjour may drop while a persistent TCP link to a paired host is still up (e.g. server locked).
    func isReachableForControl(_ host: RemoteHost) -> Bool {
        // A live persistent TCP link is the source of truth for control reachability. Bonjour state
        // (peeredOnline/offline) churns on flaky/link-local networks; relying on it tore the hot
        // border down even though the connection was healthy.
        if isConnected(to: host) {
            return true
        }
        // Once automatic reconnection has been exhausted the host is effectively unavailable
        // (`linkPhase` reports `.unavailable` and the UI greys it out). Keep the hot border /
        // control trigger consistent with that: otherwise Bonjour's lingering `.peeredOnline`
        // keeps the edge live, so crossing it spawns a doomed connect that only produces a
        // "connection failed" popup. Recovery is via an explicit Connect (which resets the budget).
        if hasExhaustedReconnectAttempts(for: host.identifier) {
            return false
        }
        if host.isInState(.peeredOnline) {
            return true
        }
        return false
    }
    
    /// Get connection for a specific host
    /// Returns nil if connection doesn't exist or socket is not connected
    func connection(for host: RemoteHost) -> NetworkConnection? {
        guard let connection = connections[host.identifier] else { return nil }
        
        // Verify the actual socket is connected and capabilities match
        if !connection.isConnected || !connection.isValid(for: host) {
			warningLog("Connection for \(host.computerName) is invalid or has disconnected socket, cleaning up", module: .network)
            connection.disconnect()
            Task { @MainActor in
                self.cleanupStaleConnection(for: host.identifier)
            }
            return nil
        }
        return connection
    }
    
    /// Get connection for a specific host identifier
    /// Returns nil if connection doesn't exist or socket is not connected
    /// Whether this connection is owned by the persistent connection pool (must not be closed by control session teardown).
    func managesConnection(_ connection: NetworkConnection) -> Bool {
        guard let hostId = connection.connectedHost?.identifier else { return false }
        return connections[hostId] === connection
    }

    func connection(forHostId hostId: String) -> NetworkConnection? {
        guard let connection = connections[hostId] else { return nil }
        let host = HostDevicesManager.shared.host(withIdentifier: hostId)
        
        // Verify the actual socket is connected and valid
        if !connection.isConnected || !connection.isValid(for: host) {
            warningLog("Connection for host \(hostId) is invalid or has disconnected socket, cleaning up", module: .network)
            connection.disconnect()
            Task { @MainActor in
                self.cleanupStaleConnection(for: hostId)
            }
            return nil
        }
        return connection
    }
    /// Clean up stale connection state when socket is found to be disconnected
    private func cleanupStaleConnection(for hostId: String) {
        guard connectedHosts.contains(hostId) else { return }
        
		warningLog("Cleaning up stale connection for hostId=\(hostId)", module: .network)
        
        let host = connections[hostId]?.connectedHost ?? HostDevicesManager.shared.host(withIdentifier: hostId)
        
        connections.removeValue(forKey: hostId)
        connectedHosts.remove(hostId)
        stopKeepAlive(for: hostId)
        
        if let host = host {
            broadcastConnectionDisconnected(from: host)
        }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
            object: host
        )
        
        NSLog("DeviceConnectionManager: Cleaned up stale connection for \(host?.computerName ?? hostId)")
        
        // Schedule reconnection attempt
        scheduleReconnect(for: hostId)
    }
    
    // MARK: - Send Message to Connected Devices
    
    /// Send a message to all connected devices via persistent connections
    /// - Parameter message: The message to send
    /// - Returns: Number of devices the message was sent to
    @discardableResult
    func sendMessageToAllConnectedDevices(_ message: Message) -> Int {
        var sentCount = 0
        for (hostId, connection) in connections {
            if connectedHosts.contains(hostId) {
                // Fire and forget - broadcast messages
                debugLog("[SEND] Broadcast to \(hostId): \(message.debugInfo)", module: .network, connectionId: connection.connectionId)
                connection.sendAsync(message)
                sentCount += 1
            }
        }
        return sentCount
    }
    
    /// Send a message to a specific connected device
    /// - Parameters:
    ///   - message: The message to send
    ///   - hostId: The identifier of the host to send to
    /// - Returns: Whether the message was sent successfully
    @discardableResult
    func sendMessage(_ message: Message, toHost hostId: String) -> Bool {
        guard let connection = connections[hostId], connectedHosts.contains(hostId) else {
            warningLog("[SEND] Failed to send to \(hostId): not connected. \(message.debugInfo)", module: .network)
            return false
        }
        // Fire and forget
        debugLog("[SEND] To \(hostId): \(message.debugInfo)", module: .network, connectionId: connection.connectionId)
        connection.sendAsync(message)
        return true
    }
    
    /// Get all active connections (for Objective-C interoperability)
    var allConnections: [NetworkConnection] {
        return connections.values.filter { connection in
            if let host = connection.connectedHost {
                return connectedHosts.contains(host.identifier)
            }
            return false
        }
    }
    
    // MARK: - Server Listening (for incoming connections)
    
    /// Start listening for incoming connections (server mode)
    /// - Parameter port: The port to listen on (will be modified if the port is in use)
    /// - Returns: Whether listening started successfully
    @discardableResult
    func startListening(onPort port: inout Int32) -> Bool {
        guard !isListening else { return true }
        
        let success = ConnectionsManager.shared.startListening(withDelegate: self, onPort: &port)
        if success {
            isListening = true
            NSLog("DeviceConnectionManager: Started listening on port \(port)")
        } else {
            errorLog("DeviceConnectionManager: Failed to start listening on port \(port)", module: .network)
        }
        return success
    }
    
    /// The peer dialed us inbound; stop any competing outbound dial / reconnect to that host.
    func notePeerInboundDial(to host: RemoteHost) {
        let hostId = host.identifier
        connectingHosts.remove(hostId)
        passiveProbeTimers[hostId]?.invalidate()
        passiveProbeTimers.removeValue(forKey: hostId)
        reconnectTimers[hostId]?.invalidate()
        reconnectTimers.removeValue(forKey: hostId)
        reconnectNextRetryAt.removeValue(forKey: hostId)
        reconnectingHosts.remove(hostId)
        peerDisconnectedHosts.remove(hostId)
        ConnectionsManager.shared.cancelPendingOutbound(forHostIdentifier: hostId)
        debugLog("Peer \(host.computerName) dialed us inbound; cancelled competing outbound/reconnect", module: .network)
    }

    /// Stop listening for incoming connections
    func stopListening() {
        guard isListening else { return }
        
        ConnectionsManager.shared.stopListening()
        isListening = false
        NSLog("DeviceConnectionManager: Stopped listening")
    }
    
    // MARK: - Connect (Client Mode)

    /// Check whether we should initiate an outbound connection to the given remote host.
    /// Under the Unified Cursor Space design, only the host with the lexicographically smaller
    /// identifier is responsible for dialing to avoid duplicate connections.
    private func shouldInitiateOutboundConnection(to host: RemoteHost) -> Bool {
        let localName = LocalHost.shared.computerName
        let remoteName = host.computerName
        return localName < remoteName
    }

    /// Whether this machine still treats the remote host as a paired peer.
    private func believesPairedLocally(with host: RemoteHost) -> Bool {
        if AuthenticationManager.default.isHostTrusted(host) {
            return true
        }
        if let knownHost = HostDevicesManager.shared.host(withIdentifier: host.identifier),
           knownHost.isInState(.peered) {
            return true
        }
        return false
    }

    /// Restore DCM as the message delegate for a connection already in the persistent pool.
    func restorePersistentDelegate(for connection: NetworkConnection) {
        guard let hostId = connection.connectedHost?.identifier,
              connections[hostId] === connection else { return }
        connection.delegate = self
    }

    /// Handle peer lifecycle messages even when another delegate (e.g. auth manager) still owns the socket.
    @MainActor
    func handlePeerLifecycleMessage(_ message: Message, on connection: NetworkConnection) {
        restorePersistentDelegate(for: connection)
        guard let host = connection.connectedHost else { return }

        switch message.msgType {
        case .unpairNotification:
            warningLog("[RECV] received unpairNotification message from \(host.computerName)", module: .network)
            finalizeRemoteUnpair(from: host, connection: connection)
        case .authenticationFailure:
            if let reason = message.infoDict["reason"] as? String, reason == "unpaired_by_peer" {
                warningLog("[RECV] received unpaired_by_peer authenticationFailure message from \(host.computerName). Silently unpairing.", module: .network)
                finalizeRemoteUnpair(from: host, connection: connection)
            }
        case .disconnectNotification:
            warningLog("[RECV] received disconnectNotification from \(host.computerName)", module: .network)
            peerDisconnectedHosts.insert(host.identifier)
            cancelReconnect(for: host.identifier)
            finalizePeerDisconnect(from: host, connection: connection)
        default:
            break
        }
    }

    /// Whether a paired host is eligible for an outbound persistent connection attempt.
    private func isConnectable(_ host: RemoteHost) -> Bool {
        if host.identifier == LocalHost.shared.identifier {
            return false
        }
        if host.isInState(.peeredOnline) {
            return true
        }
        if host.isInState(.peeredOffline), let address = host.address, !address.isEmpty, host.port > 0 {
            return true
        }
        return false
    }

    /// Promote an established socket (e.g. after pairing) into the persistent connection pool.
    func adoptConnection(_ connection: NetworkConnection) {
        guard let host = connection.connectedHost else { return }
        guard host.identifier != LocalHost.shared.identifier else {
            connection.disconnect()
            return
        }
        guard !isConnected(to: host) else {
            connection.disconnect()
            return
        }
        connection.delegate = self
        registerConnection(connection, for: host)
        NSLog("DeviceConnectionManager: Adopted connection to \(host.computerName)")
    }
    
    private func beginOutboundConnect(to host: RemoteHost) {
        let hostId = host.identifier
        manuallyDisconnectedHosts.remove(hostId)
        peerDisconnectedHosts.remove(hostId)
        reconnectTimers[hostId]?.invalidate()
        reconnectTimers.removeValue(forKey: hostId)
        reconnectNextRetryAt.removeValue(forKey: hostId)
        reconnectingHosts.remove(hostId)
        connectingHosts.insert(hostId)
        NSLog("DeviceConnectionManager: Connecting to \(host.computerName)")
        notifyReachabilityChanged(for: host)
    }

    @discardableResult
    func connect(to host: RemoteHost, resetRetryBudget: Bool = false, ignoreIdRule: Bool = false) -> Bool {
        guard host.identifier != LocalHost.shared.identifier else { return false }
        guard !isConnected(to: host) else { return true }
        guard isConnectable(host) else { return false }
        guard ignoreIdRule || shouldInitiateOutboundConnection(to: host) else {
            debugLog("Skipping outbound connect to \(host.computerName) because local identifier (\(LocalHost.shared.identifier)) >= remote identifier (\(host.identifier)) (waiting for remote to dial us). Scheduling passive probe.", module: .network)
            self.schedulePassiveProbe(for: host)
            return false
        }

        let hostId = host.identifier
        if connectingHosts.contains(hostId) {
            return true
        }

        if resetRetryBudget {
            reconnectRetryCount.removeValue(forKey: hostId)
        }

        beginOutboundConnect(to: host)

        Task { @MainActor in
            var infoDict: [String: Any] = ["persistent": true]
            if ignoreIdRule {
                infoDict["ignoreIdRule"] = true
            }
            let success = ConnectionsManager.shared.connect(
                toHost: host,
                withDelegate: DeviceConnectionManager.shared,
                infoDict: infoDict
            )
            if !success {
                connectingHosts.remove(hostId)
                scheduleReconnect(for: hostId)
            }
        }
        return true
    }
    
    func disconnect(from host: RemoteHost) {
        peerDisconnectedHosts.remove(host.identifier)
        cancelReconnect(for: host.identifier)

        guard let connection = connections.removeValue(forKey: host.identifier) else { return }

        manuallyDisconnectedHosts.insert(host.identifier)
        connectedHosts.remove(host.identifier)
        stopKeepAlive(for: host.identifier)

        connection.sendAsync(Message.create(with: .disconnectNotification)) { [weak self] in
            Task { @MainActor in
                connection.disconnect()
                self?.broadcastConnectionDisconnected(from: host)
                NotificationCenter.default.post(
                    name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
                    object: host
                )
                NSLog("DeviceConnectionManager: Disconnected from \(host.computerName)")
                self?.notifyReachabilityChanged(for: host)
            }
        }
    }

    private func finalizePeerDisconnect(from host: RemoteHost, connection: NetworkConnection) {
        connection.disconnect()
        guard connections[host.identifier] === connection else { return }

        connections.removeValue(forKey: host.identifier)
        connectedHosts.remove(host.identifier)
        stopKeepAlive(for: host.identifier)

        broadcastConnectionDisconnected(from: host)

        NotificationCenter.default.post(
            name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
            object: host
        )

        NSLog("DeviceConnectionManager: Peer manually disconnected from \(host.computerName)")
        notifyReachabilityChanged(for: host)
    }

    /// Apply unpair state from a peer notification and refresh UI immediately.
    private func finalizeRemoteUnpair(from host: RemoteHost, connection: NetworkConnection) {
        AuthenticationManager.default.host(host, setTrusted: false)
        if host.isInState(.online) {
            host.hostState = .shared
        } else {
            host.hostState = []
        }
        HostDevicesManager.shared.saveHosts()

        cancelReconnect(for: host.identifier)
        manuallyDisconnectedHosts.remove(host.identifier)
        peerDisconnectedHosts.remove(host.identifier)

        if let registered = connections.removeValue(forKey: host.identifier) {
            connectedHosts.remove(host.identifier)
            stopKeepAlive(for: host.identifier)
            if registered !== connection {
                registered.disconnect()
            }
        }

        if connection.isConnected {
            connection.sendAsync(Message.create(with: .disconnectNotification)) {
                Task { @MainActor in
                    connection.disconnect()
                }
            }
        } else {
            connection.disconnect()
        }

        broadcastConnectionDisconnected(from: host)
        notifyReachabilityChanged(for: host)
        NotificationCenter.default.post(
            name: NSNotification.Name("HostDeviceDidUpdateNotification"),
            object: host
        )
        HostDevicesManager.shared.notifyChangesNow()
        NSLog("DeviceConnectionManager: Peer unpaired from \(host.computerName)")
    }
    
    /// Disconnect all connections and stop listening
    func disconnectAll() {
        let hostIdsToReconnect = connections.keys.filter { hostId in
            guard !manuallyDisconnectedHosts.contains(hostId) else { return false }
            guard !peerDisconnectedHosts.contains(hostId) else { return false }
            guard let host = connections[hostId]?.connectedHost
                ?? HostDevicesManager.shared.host(withIdentifier: hostId) else { return false }
            return host.isInState(.peered)
        }
        connectingHosts.removeAll()

        // Disconnect all connections
        for (hostId, connection) in connections {
            stopKeepAlive(for: hostId)
            connection.disconnect()
            
            if let host = connection.connectedHost {
                broadcastConnectionDisconnected(from: host)
            }
        }
        
        connections.removeAll()
        connectedHosts.removeAll()
        
        // Notify
        NotificationCenter.default.post(
            name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
            object: nil
        )
        
        NSLog("DeviceConnectionManager: Disconnected all connections")
		
		ConnectionsManager.shared.reset()

        for hostId in hostIdsToReconnect {
            reconnectRetryCount.removeValue(forKey: hostId)
            scheduleReconnect(for: hostId)
        }
    }
    
    // MARK: - Auto-Connect
    
    func autoConnectPairedDevices() {
        let peeredHosts = HostDevicesManager.shared.hosts(with: .peered) as? [RemoteHost] ?? []
        
        for host in peeredHosts {
            let hostId = host.identifier
            if hostId == LocalHost.shared.identifier { continue }
            if !isConnected(to: host),
               isConnectable(host),
               !hasExhaustedReconnectAttempts(for: hostId),
               !manuallyDisconnectedHosts.contains(hostId),
               !peerDisconnectedHosts.contains(hostId) {
                connect(to: host)
            }
        }
    }
    
    // MARK: - Reconnection
    
    /// Schedule a reconnection attempt for the given host
    private func scheduleReconnect(for hostId: String) {
        guard hostId != LocalHost.shared.identifier else { return }
        // Don't reconnect if manually disconnected locally or by peer notification
        guard !manuallyDisconnectedHosts.contains(hostId) else {
            NSLog("DeviceConnectionManager: Skipping reconnect for \(hostId) - manually disconnected")
            return
        }
        guard !peerDisconnectedHosts.contains(hostId) else {
            NSLog("DeviceConnectionManager: Skipping reconnect for \(hostId) - peer manually disconnected")
            return
        }

        guard let host = HostDevicesManager.shared.host(withIdentifier: hostId) else {
            cleanupReconnectState(for: hostId)
            return
        }

        guard shouldInitiateOutboundConnection(to: host) else {
            debugLog("Skipping reconnect schedule for \(host.computerName) because we wait for remote to dial us", module: .network)
            cleanupReconnectState(for: hostId)
            return
        }

        // Auto-retry is gated on the host being online (Bonjour-visible). An offline host has no
        // live route — its cached address either won't resolve or only yields a tunnel/middlebox
        // that fakes a TCP handshake — so retrying just spams doomed attempts. Drop straight to
        // `.unavailable`; the offline→online transition re-triggers connect() (see addBonjourHost).
        guard host.isInState(.peeredOnline) else {
            NSLog("DeviceConnectionManager: \(host.computerName) is offline; not scheduling reconnect (marking unavailable)")
            cleanupReconnectState(for: hostId)
            return
        }

        let currentRetry = reconnectRetryCount[hostId] ?? 0

        guard currentRetry < maxReconnectAttempts else {
            stopReconnectAfterMaxAttempts(for: hostId)
            return
        }

        let delay = baseReconnectDelay * pow(2.0, Double(currentRetry))
        
        NSLog("DeviceConnectionManager: Scheduling reconnect for \(host.computerName) in \(delay)s (attempt \(currentRetry + 1)/\(maxReconnectAttempts))")
        
        reconnectingHosts.insert(hostId)
        reconnectRetryCount[hostId] = currentRetry + 1
        
        // Cancel existing timer if any
        reconnectTimers[hostId]?.invalidate()
        reconnectNextRetryAt[hostId] = Date().addingTimeInterval(delay)
        
        // Schedule reconnection
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.attemptReconnect(for: hostId)
            }
        }
        reconnectTimers[hostId] = timer
        notifyReachabilityChanged(for: host)
    }
    
    /// Attempt to reconnect to the given host
    private func attemptReconnect(for hostId: String) {
        guard reconnectingHosts.contains(hostId) else { return }
        guard !manuallyDisconnectedHosts.contains(hostId) else {
            cleanupReconnectState(for: hostId)
            return
        }
        
        guard let host = HostDevicesManager.shared.host(withIdentifier: hostId) else {
            NSLog("DeviceConnectionManager: Host \(hostId) not found, canceling reconnect")
            cleanupReconnectState(for: hostId)
            return
        }
        
        // Retry only while the host is online; if it went offline since scheduling, give up and
        // fall back to `.unavailable` (recovery happens via the online auto-connect path).
        guard host.isInState(.peeredOnline) else {
            NSLog("DeviceConnectionManager: \(host.computerName) went offline; canceling reconnect (marking unavailable)")
            cleanupReconnectState(for: hostId)
            return
        }
        
        NSLog("DeviceConnectionManager: Attempting reconnect to \(host.computerName)")
        _ = connect(to: host)
    }
    
    // MARK: - Passive Probing
    
    /// Schedule a passive probe attempt for a host we are waiting to connect to us.
    /// If the host remains disconnected after a timeout, we bypass the ID rule to check its pairing/connection status.
    private func schedulePassiveProbe(for host: RemoteHost) {
        let hostId = host.identifier
        guard hostId != LocalHost.shared.identifier else { return }
        
        // Don't schedule if manually disconnected
        guard !manuallyDisconnectedHosts.contains(hostId) else { return }
        guard !peerDisconnectedHosts.contains(hostId) else { return }
        
        // Already have a probe scheduled or in-flight?
        guard passiveProbeTimers[hostId] == nil else { return }
        
        NSLog("DeviceConnectionManager: Scheduling passive probe for \(host.computerName) in 10.0s")
        
        let timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.executePassiveProbe(for: hostId)
            }
        }
        passiveProbeTimers[hostId] = timer
    }
    
    private func executePassiveProbe(for hostId: String) {
        passiveProbeTimers.removeValue(forKey: hostId)
        
        guard !manuallyDisconnectedHosts.contains(hostId) else { return }
        guard let host = HostDevicesManager.shared.host(withIdentifier: hostId) else { return }
        guard !isConnected(to: host) else { return }
        guard isConnectable(host) else { return }
        
        NSLog("DeviceConnectionManager: Passive probe timer fired for \(host.computerName). Bypassing ID rule to probe connection.")
        _ = connect(to: host, resetRetryBudget: false, ignoreIdRule: true)
    }
    
    /// Cancel pending reconnection for a host
    private func cancelReconnect(for hostId: String) {
        reconnectTimers[hostId]?.invalidate()
        reconnectTimers.removeValue(forKey: hostId)
        cleanupReconnectState(for: hostId)
    }
    
    private func hasExhaustedReconnectAttempts(for hostId: String) -> Bool {
        (reconnectRetryCount[hostId] ?? 0) >= maxReconnectAttempts
    }

    /// Stop automatic reconnect after the retry budget is used up; manual Connect resets the counter.
    private func stopReconnectAfterMaxAttempts(for hostId: String) {
        guard let host = HostDevicesManager.shared.host(withIdentifier: hostId) else {
            cleanupReconnectState(for: hostId)
            return
        }
        NSLog("DeviceConnectionManager: Max reconnect attempts (\(maxReconnectAttempts)) reached for \(host.computerName)")
        reconnectingHosts.remove(hostId)
        reconnectTimers[hostId]?.invalidate()
        reconnectTimers.removeValue(forKey: hostId)
        reconnectNextRetryAt.removeValue(forKey: hostId)
        connectingHosts.remove(hostId)
        reconnectRetryCount[hostId] = maxReconnectAttempts
        notifyReachabilityChanged(for: host)
    }

    /// Clean up reconnection state for a host
    private func cleanupReconnectState(for hostId: String) {
        reconnectingHosts.remove(hostId)
        reconnectRetryCount.removeValue(forKey: hostId)
        reconnectTimers[hostId]?.invalidate()
        reconnectTimers.removeValue(forKey: hostId)
        reconnectNextRetryAt.removeValue(forKey: hostId)
        connectingHosts.remove(hostId)
        
        passiveProbeTimers[hostId]?.invalidate()
        passiveProbeTimers.removeValue(forKey: hostId)
        
        notifyReachabilityChanged(for: HostDevicesManager.shared.host(withIdentifier: hostId))
    }
    
    /// Reset reconnection state after successful connection
    private func resetReconnectState(for hostId: String) {
        reconnectingHosts.remove(hostId)
        reconnectRetryCount.removeValue(forKey: hostId)
        reconnectTimers[hostId]?.invalidate()
        reconnectTimers.removeValue(forKey: hostId)
        reconnectNextRetryAt.removeValue(forKey: hostId)
        connectingHosts.remove(hostId)
        
        passiveProbeTimers[hostId]?.invalidate()
        passiveProbeTimers.removeValue(forKey: hostId)
    }
    
    private func notifyReachabilityChanged(for host: RemoteHost?) {
        NotificationCenter.default.post(
            name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
            object: host
        )
    }
    
    // MARK: - Keep-Alive
    
    private func startKeepAlive(for hostId: String) {
        stopKeepAlive(for: hostId)
        
        let timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendKeepAlive(for: hostId)
            }
        }
        keepAliveTimers[hostId] = timer
    }
    
    private func stopKeepAlive(for hostId: String) {
        keepAliveTimers[hostId]?.invalidate()
        keepAliveTimers.removeValue(forKey: hostId)
    }
    
    private func sendKeepAlive(for hostId: String) {
        guard let connection = connections[hostId] else {
            // Connection lost, clean up
            warningLog("[KeepAlive] Connection lost for \(hostId), cleaning up", module: .network)
            connectedHosts.remove(hostId)
            connections.removeValue(forKey: hostId)
            stopKeepAlive(for: hostId)
            
            NotificationCenter.default.post(
                name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
                object: nil
            )
            return
        }
        
        // Check if socket is still connected
        let socketState = connection.channelState
        let isConnected = connection.isConnected
        debugLog("[KeepAlive] hostId=\(hostId) socketState=\(socketState.rawValue) isConnected=\(isConnected)", module: .network, connectionId: connection.connectionId)
        
        if !isConnected {
            warningLog("[KeepAlive] Socket disconnected for \(hostId), triggering cleanup", module: .network, connectionId: connection.connectionId)
            cleanupStaleConnection(for: hostId)
        }
    }
    
    // MARK: - Internal Connection Handling
    
    /// Register a connection (called when connection is established)
    fileprivate func registerConnection(_ connection: NetworkConnection, for host: RemoteHost) {
        guard host.identifier != LocalHost.shared.identifier else {
            connection.disconnect()
            return
        }
        guard connection.isConnected else {
            warningLog("Skipping registerConnection for \(host.computerName); socket not connected (state=\(connection.channelState.rawValue))", module: .network)
            return
        }
        if let existing = connections[host.identifier], existing !== connection {
            if !existing.isConnected {
                // Drop a stale registry entry whose socket already died.
            } else if connection.origin == .accepted && existing.origin == .dialed {
                // Peer dialed us while our outbound link is still registered (common after
                // disconnect/reconnect races). Prefer the peer-initiated inbound leg.
                warningLog("Replacing outbound with peer inbound for \(host.computerName) (existing=\(existing.connectionId), new=\(connection.connectionId))", module: .network)
                existing.disconnect()
            } else {
                warningLog("Duplicate connection to \(host.computerName); keeping the established link (existing=\(existing.connectionId), new=\(connection.connectionId))", module: .network)
                connection.disconnect()
                return
            }
        }

        connections[host.identifier] = connection
        connectedHosts.insert(host.identifier)
        
        if host.hostState == .peeredOffline {
            host.hostState = .peeredOnline
        }
        
        // Reset reconnection state on successful connection
        resetReconnectState(for: host.identifier)
        
        // Clear manual / peer disconnect state since we are now connected!
        manuallyDisconnectedHosts.remove(host.identifier)
        peerDisconnectedHosts.remove(host.identifier)
        
        // Start keep-alive
        startKeepAlive(for: host.identifier)
        
        // Notify delegates
        broadcastConnectionEstablished(to: host, connection: connection)
        
        // Notify via notification center
        NotificationCenter.default.post(
            name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
            object: host
        )
        
        // Send our current layout to the newly connected peer
        let currentVer = HostDevicesManager.shared.layoutVersion()
        if let desktop = HostDevicesManager.shared.currentUnifiedDesktop(version: currentVer) {
            if let data = desktop.toData() {
                let msg = Message.create(with: .layoutUpdate, andData: data)
                warningLog("[LayoutSync] Sending current layout (version=\(currentVer)) to \(host.computerName) on connection register", module: .network)
                connection.sendAsync(msg)
            }
        }
        
        NSLog("DeviceConnectionManager: Registered connection to \(host.computerName)")
        notifyReachabilityChanged(for: host)
    }
    
    /// Handle connection disconnection
    fileprivate func handleDisconnection(for hostId: String, host: RemoteHost?) {
        connections.removeValue(forKey: hostId)
        connectedHosts.remove(hostId)
        stopKeepAlive(for: hostId)
        
        if let host = host {
            broadcastConnectionDisconnected(from: host)
        }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
            object: host
        )
        
        NSLog("DeviceConnectionManager: Connection lost to \(host?.computerName ?? hostId)")
        
        // Schedule reconnection attempt (only if not manually disconnected)
        scheduleReconnect(for: hostId)
    }
}

// MARK: - ClientConnectionsDelegate (for outgoing connections)

extension DeviceConnectionManager: ClientConnectionsDelegate {
    nonisolated func connectionToServerSucceeded(_ connection: NetworkConnection, infoDict: [String: Any]?) {
        Task { @MainActor in
            guard let host = connection.connectedHost else { return }
            guard connection.isConnected else {
                warningLog("Ignoring succeeded outbound handshake to \(host.computerName); socket already disconnected", module: .network)
                return
            }
            guard believesPairedLocally(with: host) else {
                warningLog("Ignoring succeeded outbound handshake to \(host.computerName); host no longer paired", module: .network)
                connection.disconnect()
                return
            }
            
            connection.delegate = self
            
            registerConnection(connection, for: host)
        }
    }
    
    nonisolated func connectionToServerFailed(_ host: RemoteHost, infoDict: [String: Any]?) {
        Task { @MainActor in
            // Prevent concurrent connection failure from destroying an already successfully accepted connection
            if let activeConnection = connections[host.identifier], activeConnection.isConnected {
                connectingHosts.remove(host.identifier)
                reconnectingHosts.remove(host.identifier)
                NotificationCenter.default.post(
                    name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
                    object: host
                )
                return
            }
            
            connections.removeValue(forKey: host.identifier)
            connectedHosts.remove(host.identifier)
            connectingHosts.remove(host.identifier)
            
            NSLog("DeviceConnectionManager: Connection failed to \(host.computerName)")
            
            // Notify delegates
            broadcastConnectionFailed(to: host)
            
            // Schedule reconnection attempt
            scheduleReconnect(for: host.identifier)
        }
    }
}

// MARK: - ServerConnectionsDelegate (for incoming connections)

extension DeviceConnectionManager: ServerConnectionsDelegate {
    nonisolated func connectionFromClientAccepted(_ connection: NetworkConnection) {
        Task { @MainActor in
            guard let host = connection.connectedHost else { return }

            if manuallyDisconnectedHosts.contains(host.identifier) {
                // Manual disconnect blocks auto-reconnect on this machine, but an inbound dial from
                // the peer is an explicit Connect on their side — accept it and clear the local flag.
                debugLog("Accepting inbound from \(host.computerName); clearing local manual disconnect (peer initiated connect)", module: .network)
                manuallyDisconnectedHosts.remove(host.identifier)
            }

            peerDisconnectedHosts.remove(host.identifier)
            notePeerInboundDial(to: host)

            connection.delegate = self
            registerConnection(connection, for: host)
        }
    }
}

// MARK: - NetworkConnectionDelegate

extension DeviceConnectionManager: NetworkConnectionDelegate {
    nonisolated func connection(_ connection: NetworkConnection, receivedMessage message: Message) {
        Task { @MainActor in
            guard let host = connection.connectedHost else { return }
            
            debugLog("[RECV] From \(host.computerName): \(message.debugInfo)", module: .network, connectionId: connection.connectionId)
            
            if message.msgType == .disconnectNotification {
                warningLog("[RECV] received disconnectNotification from \(host.computerName)", module: .network)
                peerDisconnectedHosts.insert(host.identifier)
                cancelReconnect(for: host.identifier)
                finalizePeerDisconnect(from: host, connection: connection)
                return
            }

            if message.msgType == .unpairNotification {
                finalizeRemoteUnpair(from: host, connection: connection)
                return
            }
            
            if message.msgType == .authenticationFailure,
               let reason = message.infoDict["reason"] as? String,
               reason == "unpaired_by_peer" {
                warningLog("[RECV] received unpaired_by_peer authenticationFailure message from \(host.computerName). Silently unpairing.", module: .network)
                finalizeRemoteUnpair(from: host, connection: connection)
                return
            }
            
            if message.msgType == .layoutUpdate {
                warningLog("[RECV] received layoutUpdate message from \(host.computerName) (dataLen=\(message.data?.count ?? 0))", module: .network)
                if let data = message.data {
                    if let desktop = UnifiedDesktop.from(data: data) {
                        warningLog("[RECV] successfully decoded layout update version=\(desktop.version) with \(desktop.screens.count) screens", module: .network)
                        _ = HostDevicesManager.shared.applyUnifiedDesktop(desktop)
                    } else {
                        warningLog("[RECV] failed to decode layout update from data", module: .network)
                    }
                } else {
                    warningLog("[RECV] layoutUpdate message has no data", module: .network)
                }
                return
            }
            
            // Try to dispatch to delegates exclusively
            let handled = notifyMessageExclusively(message, from: host, connection: connection)
            
            if !handled {
                // Log unhandled messages for debugging
                warningLog("[RECV] Unhandled message: \(message.debugInfo) from \(host.computerName)", module: .network, connectionId: connection.connectionId)
            }
        }
    }
    
    nonisolated func connectionDisconnected(_ connection: NetworkConnection) {
        Task { @MainActor in
            let host = connection.connectedHost
            let hostId = host?.identifier ?? ""
            
            warningLog("[DISCONNECTED] host=\(host?.computerName ?? "unknown") hostId=\(hostId) socketState=\(connection.channelState.rawValue)", module: .network, connectionId: connection.connectionId)
            
            guard !hostId.isEmpty else { return }
            
            // Only tear down host-level state if this is the connection we actually track.
            // A stale/duplicate link (the other dial direction, or a connection already replaced
            // by a reconnect) dropping must not wipe out a live registered connection — otherwise
            // the menu-bar icon and hot border flip to "disconnected" while control is still up.
            guard connections[hostId] === connection else {
                warningLog("[DISCONNECTED] ignoring stale/duplicate connection for \(hostId); a live connection is still registered", module: .network, connectionId: connection.connectionId)
                return
            }
            
            handleDisconnection(for: hostId, host: host)
        }
    }
}
