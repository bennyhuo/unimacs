// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

private let MsgProtocolVersionKey = "proto-version"
private let MsgHostDataKey = "host-data"

// MARK: - Internal SocketConnection Class

private class SocketConnection: NSObject, MessageChannelDelegate {
    private(set) var channel: MessageChannel?
    private(set) var host: RemoteHost
    private(set) var infoDict: [String: Any]?
    private(set) weak var delegate: ClientConnectionsDelegate?
    private(set) var failureReason: String?
    private var connection: NetworkConnection?
    private var didConnectTCP: Bool = false
    
    init?(connectionToHost remoteHost: RemoteHost, delegate: ClientConnectionsDelegate?, infoDict: [String: Any]?, immediateFailureReason: inout String?) {
        self.host = remoteHost
        self.infoDict = infoDict
        self.delegate = delegate
        
        super.init()
        
        debugLog("SocketConnection init", module: .network)
        
        let channel = MessageTransportFactory.makeChannel()
        self.channel = channel
        channel.delegate = self
        channel.setNoDelay(true)
        
        guard let address = remoteHost.address, !address.isEmpty else {
            immediateFailureReason = "No IP address known for device"
            channel.close()
            return nil
        }

        guard channel.connect(toHost: address, port: Int32(remoteHost.port)) else {
            immediateFailureReason = channel.lastFailureReason ?? "TCP connection failed"
            channel.close()
            return nil
        }
    }
    
    func close() {
        channel?.close()
    }
    
    // MARK: - MessageChannelDelegate
    
    func channelDidConnect(_ channel: MessageChannel) {
        debugLog("SocketConnection channelDidConnect", module: .network)
        didConnectTCP = true
        
        let networkConnection = NetworkConnection(channel: channel, origin: .dialed)
        self.connection = networkConnection
        
        connection?.delegate = self
        let canonicalHost = HostDevicesManager.shared.host(withIdentifier: host.identifier) ?? host
        let isPaired = ConnectionsManager.believesPaired(with: canonicalHost)
        connection?.sendAsync(ConnectionsManager.identificationMessage(isPaired: isPaired))
    }
    
    func channelDidFailToConnect(_ channel: MessageChannel) {
        debugLog("SocketConnection channelDidFailToConnect", module: .network)
        if failureReason == nil {
            failureReason = channel.lastFailureReason ?? "Connection timed out"
        }
        ConnectionsManager.shared.socketConnectionFailed(self)
    }
    
    func channelDidDisconnect(_ channel: MessageChannel) {
        debugLog("SocketConnection channelDidDisconnect", module: .network)
        if failureReason == nil {
            failureReason = channel.lastFailureReason ?? (didConnectTCP ? "Closed by peer during identification handshake" : "Connection closed")
        }
        ConnectionsManager.shared.socketConnectionFailed(self)
    }
    
    func channel(_ channel: MessageChannel, didReceiveData data: Data) {
        // Data is handled by `NetworkConnection` once it takes over as delegate.
    }
}

extension SocketConnection: NetworkConnectionDelegate {
    func connection(_ connection: NetworkConnection, receivedMessage message: Message) {
        debugLog("SocketConnection receivedMessage", module: .network)
        
        if message.msgType == .identification {
            guard let infoDict = message.infoDict as? [String: Any] else {
                failureReason = "Invalid identification response from peer"
                ConnectionsManager.shared.socketConnectionFailed(self)
                return
            }
            let protocolVersion = (infoDict[MsgProtocolVersionKey] as? NSNumber)?.intValue ?? 0
            
            if protocolVersion == PROTOCOL_VERSION {
                if let hostData = infoDict[MsgHostDataKey] as? Data {
                    let remoteHost = HostDevicesManager.shared.updatedHost(from: hostData)
                    connection.connectedHost = remoteHost
                    ConnectionsManager.shared.socketConnection(self, succeededWithNetworkConnection: connection)
                } else {
                    failureReason = "Missing host data in identification handshake"
                    ConnectionsManager.shared.socketConnectionFailed(self)
                }
            } else {
                let remoteHost: RemoteHost?
                if let hostData = infoDict[MsgHostDataKey] as? Data {
                    remoteHost = HostDevicesManager.shared.updatedHost(from: hostData)
                    connection.connectedHost = remoteHost
                } else {
                    remoteHost = connection.connectedHost
                }
                
                let errMsg = String(format: NSLocalizedString("Incompatible protocol version: Peer uses v%d, you use v%d.", comment: ""), protocolVersion, PROTOCOL_VERSION)
                failureReason = errMsg
                if let host = remoteHost {
                    Task { @MainActor in
                        host.lastError = errMsg
                    }
                }
                
                ConnectionsManager.shared.socketConnectionFailed(self)
            }
        } else if message.msgType == .authenticationFailure {
            if let reason = message.infoDict["reason"] as? String, reason == "unpaired_by_peer",
               let remoteHost = connection.connectedHost {
                failureReason = "Unpaired on remote Mac"
                warningLog("[Handshake] Received unpaired_by_peer failure from server. Silently unpairing.", module: .network)
                Task { @MainActor in
                    DeviceConnectionManager.shared.handlePeerLifecycleMessage(message, on: connection)
                }
            } else {
                failureReason = (message.infoDict["reason"] as? String) ?? "Authentication failed during handshake"
            }
            ConnectionsManager.shared.socketConnectionFailed(self)
        } else {
            failureReason = "Unexpected handshake message (\(message.msgType.rawValue))"
            errorLog("received invalid msg type: \(message.msgType) (expected identification - \(MsgType.identification.rawValue))", module: .network)
            ConnectionsManager.shared.socketConnectionFailed(self)
        }
    }
    
    func connectionDisconnected(_ connection: NetworkConnection) {
        if failureReason == nil {
            failureReason = didConnectTCP ? "Closed by peer during identification handshake" : "Connection closed"
        }
        ConnectionsManager.shared.socketConnectionFailed(self)
    }
}

// MARK: - ConnectionsManager

@objc class ConnectionsManager: NSObject {
    
    @objc static let shared = ConnectionsManager()
    
    private var connections = Set<NetworkConnection>()
    private var pendingConnections = [String: SocketConnection]()
    private var listener: MessageListener?
    private weak var listenDelegate: ServerConnectionsDelegate?
    
    private override init() {
        super.init()
    }
    
    // MARK: - Identification Message
    
    fileprivate static func identificationMessage(isPaired: Bool = false) -> Message {
        let infoDict: [String: Any] = [
            MsgProtocolVersionKey: NSNumber(value: PROTOCOL_VERSION),
            MsgHostDataKey: LocalHost.shared.toData() as Any,
            "isPaired": isPaired
        ]
        return Message.create(with: .identification, andInfoDict: infoDict)
    }

    /// Whether this machine considers the remote host a paired peer for handshake purposes.
    /// Uses both the trust store and the persisted peered host table so reconnect after a
    /// manual disconnect does not fall back to a fresh pairing flow when cert comparison
    /// alone would fail.
    fileprivate static func believesPaired(with remoteHost: RemoteHost) -> Bool {
        HostDevicesManager.shared.isPaired(with: remoteHost)
    }
    
    // MARK: - Connect to Host
    
    @objc func connect(toHost host: RemoteHost, withDelegate delegate: ClientConnectionsDelegate?, infoDict: [String: Any]?) -> Bool {
        debugLog("ConnectionsManager connectToHost", module: .network)

        // Socket creation/connect must run on the network run loop so the socket's CFRunLoop
        // source is hosted off the main thread. We dispatch *asynchronously*: the blocking
        // `socket.connect` (up to the connection timeout) must never run while the caller's
        // thread (often the main actor) waits on it — doing so froze the main run loop.
        // All access to the pending/connections collections stays confined to this thread.
        // Immediate failures are reported through the delegate, which schedules a reconnect.
        NetworkRunLoopThread.shared.async {
            if self.pendingConnections[host.identifier] != nil {
                debugLog("connectToHost: \(host.identifier), pending...", module: .network)
                return
            }

            var immediateFailure: String?
            if let connection = SocketConnection(connectionToHost: host, delegate: delegate, infoDict: infoDict, immediateFailureReason: &immediateFailure) {
                self.pendingConnections[host.identifier] = connection
                debugLog("connectToHost: \(host.identifier), add to pendingConnections", module: .network)
            } else {
                debugLog("connectToHost: \(host.identifier), failed immediately (\(immediateFailure ?? "unknown"))", module: .network)
                var mergedInfo = infoDict ?? [:]
                if let immediateFailure {
                    mergedInfo["failureReason"] = immediateFailure
                }
                // Delegates may touch UI / main-actor state, so always report on main.
                DispatchQueue.main.async {
                    delegate?.connectionToServerFailed(host, infoDict: mergedInfo)
                }
            }
        }
        return true
    }

    /// Drop an in-flight outbound dial to `hostId` so it does not race an inbound accept from the same peer.
    func cancelPendingOutbound(forHostIdentifier hostId: String) {
        NetworkRunLoopThread.shared.async {
            if let pending = self.pendingConnections.removeValue(forKey: hostId) {
                debugLog("cancelled pending outbound dial to \(hostId)", module: .network)
                pending.close()
            }
        }
    }
    
    // MARK: - Listening
    
    @objc func startListening(withDelegate delegate: ServerConnectionsDelegate?, onPort port: UnsafeMutablePointer<Int32>) -> Bool {
        return NetworkRunLoopThread.shared.sync { [self] in
            if self.listener != nil {
                return true
            }

            self.listenDelegate = delegate

            let listener = MessageTransportFactory.makeListener()
            listener.delegate = self
            self.listener = listener

            // For the legacy stack, listening on the network run loop binds every
            // accepted child socket's callbacks to this thread, off the main run
            // loop. The NW stack uses its own dispatch queues.
            return listener.start(onPort: port, tries: 50)
        }
    }
    
    @objc func stopListening() {
        NetworkRunLoopThread.shared.async {
            self.listener?.stop()
            self.listener = nil
        }
    }
    
    // MARK: - Socket Connection Callbacks

    // Channel delegate callbacks may arrive on the legacy network run loop or on
    // a Network.framework dispatch queue, so confine all access to the pending /
    // connections collections to the network run loop.
    
    fileprivate func socketConnectionFailed(_ socketConnection: SocketConnection) {
        NetworkRunLoopThread.shared.async {
            let host = socketConnection.host
            let identifier = host.identifier

            if self.pendingConnections[identifier] === socketConnection {
                var mergedInfo = socketConnection.infoDict ?? [:]
                if let reason = socketConnection.failureReason ?? socketConnection.channel?.lastFailureReason {
                    mergedInfo["failureReason"] = reason
                }
                socketConnection.delegate?.connectionToServerFailed(host, infoDict: mergedInfo)
                self.pendingConnections.removeValue(forKey: identifier)
            }
        }
    }
    
    fileprivate func socketConnection(_ socketConnection: SocketConnection, succeededWithNetworkConnection networkConnection: NetworkConnection) {
        NetworkRunLoopThread.shared.async {
            let host = socketConnection.host
            let identifier = host.identifier

            if self.pendingConnections[identifier] === socketConnection {
                socketConnection.delegate?.connectionToServerSucceeded(networkConnection, infoDict: socketConnection.infoDict)
                self.pendingConnections.removeValue(forKey: identifier)
            }
        }
    }
    
    // MARK: - Reset
    
    @objc func reset() {
        NetworkRunLoopThread.shared.async {
            for connection in self.connections {
                connection.disconnect()
            }
            self.connections.removeAll()

            for connection in self.pendingConnections.values {
                connection.close()
            }
            self.pendingConnections.removeAll()
        }
    }
}

// MARK: - MessageListenerDelegate

extension ConnectionsManager: MessageListenerDelegate {

    func listener(_ listener: MessageListener, didAcceptChannel channel: MessageChannel) {
        // Must attach NetworkConnection on the network thread immediately. Deferring
        // via async dropped Identification messages that arrived within ~80 ms while
        // the run loop queue was busy, and left accept-side SSL negotiating against
        // a plaintext peer during pairing.
        NetworkRunLoopThread.shared.sync {
            debugLog("connection accepted on \(channel.remoteAddress ?? "nil")", module: .network)

            guard channel.state == .connectedState else {
                warningLog("accepted channel not connected (state=\(channel.state.rawValue)); closing inbound link", module: .network)
                channel.close()
                return
            }

            // Wire NetworkConnection before enabling socket read callbacks so the
            // first Identification bytes are not dropped on accepted legacy sockets.
            let connection = NetworkConnection(channel: channel, origin: .accepted)
            connection.delegate = self
            self.connections.insert(connection)
            channel.activateReceiveCallbacks()
            channel.setNoDelay(true)

            if let address = channel.remoteAddress,
               let host = HostDevicesManager.shared.host(withAddress: address) {
                if let pending = self.pendingConnections[host.identifier] {
                    let userInitiated = (pending.infoDict?["ignoreIdRule"] as? Bool) == true
                    if userInitiated {
                        warningLog("Rejecting inbound from \(address); local user-initiated outbound to \(host.identifier) takes priority", module: .network)
                        connection.disconnect()
                        return
                    }
                    debugLog("cancelled pending outbound dial to \(host.identifier)", module: .network)
                    self.pendingConnections.removeValue(forKey: host.identifier)
                    pending.close()
                }
                Task { @MainActor in
                    DeviceConnectionManager.shared.notePeerInboundDial(to: host)
                }
            }
        }
    }

    func listenerShouldEnableEncryption(_ listener: MessageListener, forRemoteAddress address: String?) -> Bool {
        false
    }
}

extension ConnectionsManager {
    /// Retained for file-transfer call sites; control connections are always plaintext.
    @objc func shouldEnableEncryption(forRemoteAddress address: String?) -> Bool {
        false
    }
}

// MARK: - NetworkConnectionDelegate

extension ConnectionsManager: NetworkConnectionDelegate {
    
    func connection(_ connection: NetworkConnection, receivedMessage message: Message) {
        if message.msgType == .identification {
            guard let infoDict = message.infoDict as? [String: Any] else { return }
            let protocolVersion = (infoDict[MsgProtocolVersionKey] as? NSNumber)?.intValue ?? 0
            
            if protocolVersion == PROTOCOL_VERSION {
                if let hostData = infoDict[MsgHostDataKey] as? Data {
                    let remoteHost = HostDevicesManager.shared.updatedHost(from: hostData)
                    connection.connectedHost = remoteHost
                    HostDevicesManager.shared.addClientHost(remoteHost)
                    
                    // Check for stale pairing
                    let peerBelievesPaired: Bool
                    if let nsNum = infoDict["isPaired"] as? NSNumber {
                        peerBelievesPaired = nsNum.boolValue
                    } else {
                        peerBelievesPaired = infoDict["isPaired"] as? Bool ?? false
                    }
                    
                    let knownHost = HostDevicesManager.shared.host(withIdentifier: remoteHost.identifier)
                    let localBelievesPaired = ConnectionsManager.believesPaired(with: remoteHost)

                    connection.sendAsync(ConnectionsManager.identificationMessage(isPaired: localBelievesPaired))
                    
                    if peerBelievesPaired && !localBelievesPaired {
                        let isPeered = knownHost?.isInState(.peered) ?? false
                        let isTrusted = AuthenticationManager.default.isHostTrusted(remoteHost)
                        warningLog("[Handshake] Peer \(remoteHost.computerName) believes paired but is not paired/trusted locally (isPeered=\(isPeered), isTrusted=\(isTrusted)). Rejecting.", module: .network)
                        Task { @MainActor in
                            ActivityLogManager.shared.log(
                                level: .warning,
                                category: .connection,
                                title: "Rejected incoming connection from unpaired device \(remoteHost.computerName)",
                                detail: "\"\(remoteHost.computerName)\" tried to connect as a paired device, but it is not paired on this Mac. Click Re-pair to re-establish trust.",
                                hostId: remoteHost.identifier,
                                hostName: remoteHost.computerName,
                                actions: [.repairDevice(hostId: remoteHost.identifier, hostName: remoteHost.computerName)]
                            )
                        }
                        let failureMsg = Message.create(with: .authenticationFailure, andInfoDict: ["reason": "unpaired_by_peer"])
                        connection.sendAsync(failureMsg)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            connection.disconnect()
                        }
                        return
                    }
                    
                    listenDelegate?.connectionFromClientAccepted(connection)
                }
            } else {
                errorLog("received message with invalid protocol (\(protocolVersion) vs \(PROTOCOL_VERSION))", module: .network)
            }
        } else if message.msgType == .disconnectNotification {
            debugLog("received disconnectNotification before handshake completed; closing link", module: .network)
            connection.disconnect()
        } else {
            errorLog("received invalid msg type: \(message.msgType) (expected identification - \(MsgType.identification.rawValue))", module: .network)
        }
    }
    
    func connectionDisconnected(_ connection: NetworkConnection) {
        NetworkRunLoopThread.shared.async {
            self.connections.remove(connection)
        }
    }
}
