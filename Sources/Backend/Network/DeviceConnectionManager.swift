// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  Manages persistent connections to paired devices.
//  Serves as the single source of truth for all network connections.

import Foundation

// MARK: - DeviceConnectionDelegate Protocol

/// Delegate protocol for receiving connection events from DeviceConnectionManager
/// Supports both broadcast (all delegates notified) and exclusive (first handler wins) patterns
@MainActor
@objc protocol DeviceConnectionDelegate: AnyObject {
    // MARK: - Broadcast Notifications (all delegates receive these)
    
    /// Called when a connection is established (either as client or from incoming connection)
    @objc optional func connectionDidEstablish(to host: TPRemoteHost, connection: NetworkConnection)
    
    /// Called when a connection is disconnected
    @objc optional func connectionDidDisconnect(from host: TPRemoteHost)
    
    /// Called when a connection attempt fails
    @objc optional func connectionDidFail(to host: TPRemoteHost)
    
    // MARK: - Exclusive Notifications (first handler that returns true wins)
    
    /// Handle incoming message. Return true if the message was handled (stops propagation to other delegates)
    @objc optional func handleMessage(_ message: TPMessage, from host: TPRemoteHost, connection: NetworkConnection) -> Bool
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
    /// Hosts that were manually disconnected (should not auto-reconnect)
    private var manuallyDisconnectedHosts: Set<String> = []
    
    /// Maximum number of reconnect attempts
    private let maxReconnectAttempts = 5
    /// Base delay for reconnection (seconds)
    private let baseReconnectDelay: TimeInterval = 2.0
    /// Maximum delay for reconnection (seconds)
    private let maxReconnectDelay: TimeInterval = 30.0
    
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
    private func broadcastConnectionEstablished(to host: TPRemoteHost, connection: NetworkConnection) {
        cleanupDelegates()
        for wrapper in delegates {
            wrapper.delegate?.connectionDidEstablish?(to: host, connection: connection)
        }
    }
    
    /// Broadcast a disconnection notification to all delegates
    private func broadcastConnectionDisconnected(from host: TPRemoteHost) {
        cleanupDelegates()
        for wrapper in delegates {
            wrapper.delegate?.connectionDidDisconnect?(from: host)
        }
    }
    
    /// Broadcast a connection failure notification to all delegates
    private func broadcastConnectionFailed(to host: TPRemoteHost) {
        cleanupDelegates()
        for wrapper in delegates {
            wrapper.delegate?.connectionDidFail?(to: host)
        }
    }
    
    /// Send message to delegates exclusively (first handler that returns true stops propagation)
    /// - Returns: true if any delegate handled the message
    private func notifyMessageExclusively(_ message: TPMessage, from host: TPRemoteHost, connection: NetworkConnection) -> Bool {
        cleanupDelegates()
        for wrapper in delegates {
            if let handled = wrapper.delegate?.handleMessage?(message, from: host, connection: connection), handled {
                return true
            }
        }
        return false
    }
    
    // MARK: - Connection State
    
    func isConnected(to host: TPRemoteHost) -> Bool {
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
    
    /// Get connection for a specific host
    /// Returns nil if connection doesn't exist or socket is not connected
    func connection(for host: TPRemoteHost) -> NetworkConnection? {
        guard let connection = connections[host.identifier] else { return nil }
        
        // Verify the actual socket is connected
        if !connection.isConnected {
			warningLog("Connection for \(host.computerName) has disconnected socket (socketState=\(connection.socket.socketState.rawValue)), cleaning up", module: .network)
            Task { @MainActor in
                self.cleanupStaleConnection(for: host.identifier)
            }
            return nil
        }
        return connection
    }
    
    /// Get connection for a specific host identifier
    /// Returns nil if connection doesn't exist or socket is not connected
    func connection(forHostId hostId: String) -> NetworkConnection? {
        guard let connection = connections[hostId] else { return nil }
        
        // Verify the actual socket is connected
        if !connection.isConnected {
            warningLog("Connection for host \(hostId) has disconnected socket (socketState=\(connection.socket.socketState.rawValue)), cleaning up", module: .network)
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
        
        let host = connections[hostId]?.connectedHost ?? TPHostsManager.shared.host(withIdentifier: hostId)
        
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
    func sendMessageToAllConnectedDevices(_ message: TPMessage) -> Int {
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
    func sendMessage(_ message: TPMessage, toHost hostId: String) -> Bool {
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
        
        let success = TPConnectionsManager.shared.startListening(withDelegate: self, onPort: &port)
        if success {
            isListening = true
            NSLog("DeviceConnectionManager: Started listening on port \(port)")
        }
        return success
    }
    
    /// Stop listening for incoming connections
    func stopListening() {
        guard isListening else { return }
        
        TPConnectionsManager.shared.stopListening()
        isListening = false
        NSLog("DeviceConnectionManager: Stopped listening")
    }
    
    // MARK: - Connect (Client Mode)
    
    func connect(to host: TPRemoteHost) {
        guard !isConnected(to: host) else { return }
        guard host.isInState(.peeredOnline) else { return }
        
        // Clear manual disconnect flag when user initiates connection
        manuallyDisconnectedHosts.remove(host.identifier)
        
        // Establish connection
        let success = TPConnectionsManager.shared.connect(
            toHost: host,
            withDelegate: self,
            infoDict: ["persistent": true]
        )
        
        if success {
            NSLog("DeviceConnectionManager: Connecting to \(host.computerName)")
        }
    }
    
    func disconnect(from host: TPRemoteHost) {
        // Mark as manually disconnected to prevent auto-reconnect
        manuallyDisconnectedHosts.insert(host.identifier)
        
        // Cancel any pending reconnection
        cancelReconnect(for: host.identifier)
        
        guard let connection = connections[host.identifier] else { return }
        
        // Stop keep-alive
        stopKeepAlive(for: host.identifier)
        
        // Disconnect
        connection.disconnect()
        connections.removeValue(forKey: host.identifier)
        connectedHosts.remove(host.identifier)
        
        // Notify delegates
        broadcastConnectionDisconnected(from: host)
        
        // Notify via notification center
        NotificationCenter.default.post(
            name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
            object: host
        )
        
        NSLog("DeviceConnectionManager: Disconnected from \(host.computerName)")
    }
    
    /// Disconnect all connections and stop listening
    func disconnectAll() {
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
		
		TPConnectionsManager.shared.reset()
    }
    
    // MARK: - Auto-Connect
    
    func autoConnectPairedDevices() {
        let peeredOnlineHosts = TPHostsManager.shared.hosts(with: .peeredOnline) as? [TPRemoteHost] ?? []
        
        for host in peeredOnlineHosts {
            if !isConnected(to: host) {
                connect(to: host)
            }
        }
    }
    
    // MARK: - Reconnection
    
    /// Schedule a reconnection attempt for the given host
    private func scheduleReconnect(for hostId: String) {
        // Don't reconnect if manually disconnected
        guard !manuallyDisconnectedHosts.contains(hostId) else {
            NSLog("DeviceConnectionManager: Skipping reconnect for \(hostId) - manually disconnected")
            return
        }
        
        // Check if we've exceeded max attempts
        let currentRetry = reconnectRetryCount[hostId] ?? 0
        guard currentRetry < maxReconnectAttempts else {
            NSLog("DeviceConnectionManager: Max reconnect attempts reached for \(hostId)")
            cleanupReconnectState(for: hostId)
            return
        }
        
        // Check if host is still online
        guard let host = TPHostsManager.shared.host(withIdentifier: hostId),
              host.isInState(.peeredOnline) else {
            NSLog("DeviceConnectionManager: Host \(hostId) is offline, skipping reconnect")
            cleanupReconnectState(for: hostId)
            return
        }
        
        // Calculate delay with exponential backoff
        let delay = min(baseReconnectDelay * pow(2.0, Double(currentRetry)), maxReconnectDelay)
        
        NSLog("DeviceConnectionManager: Scheduling reconnect for \(host.computerName) in \(delay)s (attempt \(currentRetry + 1)/\(maxReconnectAttempts))")
        
        reconnectingHosts.insert(hostId)
        reconnectRetryCount[hostId] = currentRetry + 1
        
        // Cancel existing timer if any
        reconnectTimers[hostId]?.invalidate()
        
        // Schedule reconnection
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.attemptReconnect(for: hostId)
            }
        }
        reconnectTimers[hostId] = timer
    }
    
    /// Attempt to reconnect to the given host
    private func attemptReconnect(for hostId: String) {
        guard reconnectingHosts.contains(hostId) else { return }
        guard !manuallyDisconnectedHosts.contains(hostId) else {
            cleanupReconnectState(for: hostId)
            return
        }
        
        guard let host = TPHostsManager.shared.host(withIdentifier: hostId) else {
            NSLog("DeviceConnectionManager: Host \(hostId) not found, canceling reconnect")
            cleanupReconnectState(for: hostId)
            return
        }
        
        guard host.isInState(.peeredOnline) else {
            NSLog("DeviceConnectionManager: Host \(host.computerName) is offline, canceling reconnect")
            cleanupReconnectState(for: hostId)
            return
        }
        
        NSLog("DeviceConnectionManager: Attempting reconnect to \(host.computerName)")
        
        // Clear the timer reference since we're executing
        reconnectTimers.removeValue(forKey: hostId)
        
        // Try to connect
        let success = TPConnectionsManager.shared.connect(
            toHost: host,
            withDelegate: self,
            infoDict: ["persistent": true, "reconnect": true]
        )
        
        if !success {
            // Schedule another attempt
            scheduleReconnect(for: hostId)
        }
    }
    
    /// Cancel pending reconnection for a host
    private func cancelReconnect(for hostId: String) {
        reconnectTimers[hostId]?.invalidate()
        reconnectTimers.removeValue(forKey: hostId)
        cleanupReconnectState(for: hostId)
    }
    
    /// Clean up reconnection state for a host
    private func cleanupReconnectState(for hostId: String) {
        reconnectingHosts.remove(hostId)
        reconnectRetryCount.removeValue(forKey: hostId)
        reconnectTimers[hostId]?.invalidate()
        reconnectTimers.removeValue(forKey: hostId)
    }
    
    /// Reset reconnection state after successful connection
    private func resetReconnectState(for hostId: String) {
        reconnectingHosts.remove(hostId)
        reconnectRetryCount.removeValue(forKey: hostId)
        reconnectTimers[hostId]?.invalidate()
        reconnectTimers.removeValue(forKey: hostId)
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
        let socketState = connection.socket.socketState
        let isConnected = connection.isConnected
        debugLog("[KeepAlive] hostId=\(hostId) socketState=\(socketState.rawValue) isConnected=\(isConnected)", module: .network, connectionId: connection.connectionId)
        
        if !isConnected {
            warningLog("[KeepAlive] Socket disconnected for \(hostId), triggering cleanup", module: .network, connectionId: connection.connectionId)
            cleanupStaleConnection(for: hostId)
        }
    }
    
    // MARK: - Internal Connection Handling
    
    /// Register a connection (called when connection is established)
    fileprivate func registerConnection(_ connection: NetworkConnection, for host: TPRemoteHost) {
        connections[host.identifier] = connection
        connectedHosts.insert(host.identifier)
        
        // Reset reconnection state on successful connection
        resetReconnectState(for: host.identifier)
        
        // Start keep-alive
        startKeepAlive(for: host.identifier)
        
        // Notify delegates
        broadcastConnectionEstablished(to: host, connection: connection)
        
        // Notify via notification center
        NotificationCenter.default.post(
            name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
            object: host
        )
        
        NSLog("DeviceConnectionManager: Registered connection to \(host.computerName)")
    }
    
    /// Handle connection disconnection
    fileprivate func handleDisconnection(for hostId: String, host: TPRemoteHost?) {
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

// MARK: - TPClientConnectionsDelegate (for outgoing connections)

extension DeviceConnectionManager: TPClientConnectionsDelegate {
    nonisolated func connectionToServerSucceeded(_ connection: NetworkConnection, infoDict: [String: Any]?) {
        Task { @MainActor in
            guard let host = connection.connectedHost else { return }
            
            // Set ourselves as the delegate for this connection
            connection.delegate = self
            
            registerConnection(connection, for: host)
        }
    }
    
    nonisolated func connectionToServerFailed(_ host: TPRemoteHost, infoDict: [String: Any]?) {
        Task { @MainActor in
            connections.removeValue(forKey: host.identifier)
            connectedHosts.remove(host.identifier)
            
            NSLog("DeviceConnectionManager: Connection failed to \(host.computerName)")
            
            // Notify delegates
            broadcastConnectionFailed(to: host)
            
            // Schedule reconnection attempt
            scheduleReconnect(for: host.identifier)
        }
    }
}

// MARK: - TPServerConnectionsDelegate (for incoming connections)

extension DeviceConnectionManager: TPServerConnectionsDelegate {
    nonisolated func connectionFromClientAccepted(_ connection: NetworkConnection) {
        Task { @MainActor in
            guard let host = connection.connectedHost else { return }
            
            // Set ourselves as the delegate for this connection
            connection.delegate = self
            
            registerConnection(connection, for: host)
        }
    }
}

// MARK: - NetworkConnectionDelegate

extension DeviceConnectionManager: NetworkConnectionDelegate {
    nonisolated func connection(_ connection: NetworkConnection, receivedMessage message: TPMessage) {
        Task { @MainActor in
            guard let host = connection.connectedHost else { return }
            
            debugLog("[RECV] From \(host.computerName): \(message.debugInfo)", module: .network, connectionId: connection.connectionId)
            
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
            
            warningLog("[DISCONNECTED] host=\(host?.computerName ?? "unknown") hostId=\(hostId) socketState=\(connection.socket.socketState.rawValue)", module: .network, connectionId: connection.connectionId)
            
            guard !hostId.isEmpty else { return }
            
            handleDisconnection(for: hostId, host: host)
        }
    }
}
