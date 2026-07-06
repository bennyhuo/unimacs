// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

private let TPMsgProtocolVersionKey = "proto-version"
private let TPMsgHostDataKey = "host-data"

// MARK: - Internal SocketConnection Class

private class SocketConnection: NSObject, MessageChannelDelegate {
    private(set) var channel: MessageChannel?
    private(set) var host: TPRemoteHost
    private(set) var infoDict: [String: Any]?
    private(set) weak var delegate: TPClientConnectionsDelegate?
    private var connection: NetworkConnection?
    
    init?(connectionToHost remoteHost: TPRemoteHost, delegate: TPClientConnectionsDelegate?, infoDict: [String: Any]?) {
        self.host = remoteHost
        self.infoDict = infoDict
        self.delegate = delegate
        
        super.init()
        
        debugLog("SocketConnection init", module: .network)
        
        let channel = MessageTransportFactory.makeChannel()
        self.channel = channel
        channel.delegate = self
        channel.setNoDelay(true)
        
        guard let address = remoteHost.address,
              channel.connect(toHost: address, port: Int32(remoteHost.port)) else {
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
        
        let networkConnection = NetworkConnection(channel: channel, origin: .dialed)
        self.connection = networkConnection
        
        connection?.delegate = self
        let canonicalHost = TPHostsManager.shared.host(withIdentifier: host.identifier) ?? host
        let isPaired = TPConnectionsManager.believesPaired(with: canonicalHost)
        connection?.sendAsync(TPConnectionsManager.identificationMessage(isPaired: isPaired))
    }
    
    func channelDidFailToConnect(_ channel: MessageChannel) {
        debugLog("SocketConnection channelDidFailToConnect", module: .network)
        TPConnectionsManager.shared.socketConnectionFailed(self)
    }
    
    func channelDidDisconnect(_ channel: MessageChannel) {
        debugLog("SocketConnection channelDidDisconnect", module: .network)
        TPConnectionsManager.shared.socketConnectionFailed(self)
    }
    
    func channel(_ channel: MessageChannel, didReceiveData data: Data) {
        // Data is handled by `NetworkConnection` once it takes over as delegate.
    }
}

extension SocketConnection: NetworkConnectionDelegate {
    func connection(_ connection: NetworkConnection, receivedMessage message: TPMessage) {
        debugLog("SocketConnection receivedMessage", module: .network)
        
        if message.msgType == .identification {
            guard let infoDict = message.infoDict as? [String: Any] else { return }
            let protocolVersion = (infoDict[TPMsgProtocolVersionKey] as? NSNumber)?.intValue ?? 0
            
            if protocolVersion == PROTOCOL_VERSION {
                if let hostData = infoDict[TPMsgHostDataKey] as? Data {
                    let remoteHost = TPHostsManager.shared.updatedHost(from: hostData)
                    connection.connectedHost = remoteHost
                    TPConnectionsManager.shared.socketConnection(self, succeededWithNetworkConnection: connection)
                }
            } else {
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Wrong protocol version", comment: "Invalid protocol error title")
                    alert.informativeText = String(format: NSLocalizedString("The Mac you tried to control is using teleport protocol v%d, but you're using v%d.", comment: "Invalid protocol error message"), protocolVersion, PROTOCOL_VERSION)
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    
                    _ = TPMainController.shared().present(alert)
                }
                
                TPConnectionsManager.shared.socketConnectionFailed(self)
            }
        } else if message.msgType == .authenticationFailure {
            if let reason = message.infoDict["reason"] as? String, reason == "unpaired_by_peer",
               let remoteHost = connection.connectedHost {
                warningLog("[Handshake] Received unpaired_by_peer failure from server. Silently unpairing.", module: .network)
                Task { @MainActor in
                    DeviceConnectionManager.shared.handlePeerLifecycleMessage(message, on: connection)
                }
            }
            TPConnectionsManager.shared.socketConnectionFailed(self)
        } else {
            errorLog("received invalid msg type: \(message.msgType) (expected identification - \(TPMsgType.identification.rawValue))", module: .network)
            TPConnectionsManager.shared.socketConnectionFailed(self)
        }
    }
    
    func connectionDisconnected(_ connection: NetworkConnection) {
        TPConnectionsManager.shared.socketConnectionFailed(self)
    }
}

// MARK: - TPConnectionsManager

@objc class TPConnectionsManager: NSObject {
    
    @objc static let shared = TPConnectionsManager()
    
    private var connections = Set<NetworkConnection>()
    private var pendingConnections = [String: SocketConnection]()
    private var listener: MessageListener?
    private weak var listenDelegate: TPServerConnectionsDelegate?
    
    private override init() {
        super.init()
    }
    
    // MARK: - Identification Message
    
    fileprivate static func identificationMessage(isPaired: Bool = false) -> TPMessage {
        let infoDict: [String: Any] = [
            TPMsgProtocolVersionKey: NSNumber(value: PROTOCOL_VERSION),
            TPMsgHostDataKey: TPLocalHost.shared.toData() as Any,
            "isPaired": isPaired
        ]
        return TPMessage.create(with: .identification, andInfoDict: infoDict)
    }

    /// Whether this machine considers the remote host a paired peer for handshake purposes.
    /// Uses both the trust store and the persisted peered host table so reconnect after a
    /// manual disconnect does not fall back to a fresh pairing flow when cert comparison
    /// alone would fail.
    fileprivate static func believesPaired(with remoteHost: TPRemoteHost) -> Bool {
        if TPAuthenticationManager.default.isHostTrusted(remoteHost) {
            return true
        }
        if let knownHost = TPHostsManager.shared.host(withIdentifier: remoteHost.identifier),
           knownHost.isInState(.peered) {
            return true
        }
        return false
    }
    
    // MARK: - Connect to Host
    
    @objc func connect(toHost host: TPRemoteHost, withDelegate delegate: TPClientConnectionsDelegate?, infoDict: [String: Any]?) -> Bool {
        debugLog("TPConnectionsManager connectToHost", module: .network)

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

            if let connection = SocketConnection(connectionToHost: host, delegate: delegate, infoDict: infoDict) {
                self.pendingConnections[host.identifier] = connection
                debugLog("connectToHost: \(host.identifier), add to pendingConnections", module: .network)
            } else {
                debugLog("connectToHost: \(host.identifier), failed immediately", module: .network)
                // Delegates may touch UI / main-actor state, so always report on main.
                DispatchQueue.main.async {
                    delegate?.connectionToServerFailed(host, infoDict: infoDict)
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
    
    @objc func startListening(withDelegate delegate: TPServerConnectionsDelegate?, onPort port: UnsafeMutablePointer<Int32>) -> Bool {
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
                socketConnection.delegate?.connectionToServerFailed(host, infoDict: socketConnection.infoDict)
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

extension TPConnectionsManager: MessageListenerDelegate {

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
               let host = TPHostsManager.shared.host(withAddress: address) {
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

extension TPConnectionsManager {
    /// Retained for file-transfer call sites; control connections are always plaintext.
    @objc func shouldEnableEncryption(forRemoteAddress address: String?) -> Bool {
        false
    }
}

// MARK: - NetworkConnectionDelegate

extension TPConnectionsManager: NetworkConnectionDelegate {
    
    func connection(_ connection: NetworkConnection, receivedMessage message: TPMessage) {
        if message.msgType == .identification {
            guard let infoDict = message.infoDict as? [String: Any] else { return }
            let protocolVersion = (infoDict[TPMsgProtocolVersionKey] as? NSNumber)?.intValue ?? 0
            
            if protocolVersion == PROTOCOL_VERSION {
                if let hostData = infoDict[TPMsgHostDataKey] as? Data {
                    let remoteHost = TPHostsManager.shared.updatedHost(from: hostData)
                    connection.connectedHost = remoteHost
                    TPHostsManager.shared.addClientHost(remoteHost)
                    
                    // Check for stale pairing
                    let peerBelievesPaired: Bool
                    if let nsNum = infoDict["isPaired"] as? NSNumber {
                        peerBelievesPaired = nsNum.boolValue
                    } else {
                        peerBelievesPaired = infoDict["isPaired"] as? Bool ?? false
                    }
                    
                    let knownHost = TPHostsManager.shared.host(withIdentifier: remoteHost.identifier)
                    let localBelievesPaired = TPConnectionsManager.believesPaired(with: remoteHost)

                    connection.sendAsync(TPConnectionsManager.identificationMessage(isPaired: localBelievesPaired))
                    
                    if peerBelievesPaired && !localBelievesPaired {
                        let isPeered = knownHost?.isInState(.peered) ?? false
                        let isTrusted = TPAuthenticationManager.default.isHostTrusted(remoteHost)
                        warningLog("[Handshake] Peer \(remoteHost.computerName) believes paired but is not paired/trusted locally (isPeered=\(isPeered), isTrusted=\(isTrusted)). Rejecting.", module: .network)
                        let failureMsg = TPMessage.create(with: .authenticationFailure, andInfoDict: ["reason": "unpaired_by_peer"])
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
            errorLog("received invalid msg type: \(message.msgType) (expected identification - \(TPMsgType.identification.rawValue))", module: .network)
        }
    }
    
    func connectionDisconnected(_ connection: NetworkConnection) {
        NetworkRunLoopThread.shared.async {
            self.connections.remove(connection)
        }
    }
}
