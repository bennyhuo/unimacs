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
        
        let enableEncryption = TPLocalHost.shared.pairWith(host: remoteHost, hasCapability: .encryption)
        let channel = MessageTransportFactory.makeChannel(enableEncryption: enableEncryption)
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
        
        // Trust-on-first-use: capture the peer certificate after the handshake.
        if channel.enableEncryption, let certRef = channel.peerCertificate {
            host.certificate = certRef
        }
        
        let networkConnection = NetworkConnection(channel: channel)
        self.connection = networkConnection
        
        connection?.delegate = self
        // Fire and forget - identification message
        connection?.sendAsync(TPConnectionsManager.identificationMessage())
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
    
    fileprivate static func identificationMessage() -> TPMessage {
        let infoDict: [String: Any] = [
            TPMsgProtocolVersionKey: NSNumber(value: PROTOCOL_VERSION),
            TPMsgHostDataKey: TPLocalHost.shared.toData() as Any
        ]
        return TPMessage.create(with: .identification, andInfoDict: infoDict)
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
    
    // MARK: - Listening
    
    @objc func startListening(withDelegate delegate: TPServerConnectionsDelegate?, onPort port: UnsafeMutablePointer<Int32>) -> Bool {
        return NetworkRunLoopThread.shared.sync { [self] in
            if self.listener != nil {
                return true
            }

            self.listenDelegate = delegate

            let enableEncryption = TPLocalHost.shared.hasCapability(.encryption)
            let listener = MessageTransportFactory.makeListener(enableEncryption: enableEncryption)
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

            if self.pendingConnections[identifier] != nil {
                socketConnection.delegate?.connectionToServerFailed(host, infoDict: socketConnection.infoDict)
                self.pendingConnections.removeValue(forKey: identifier)
            }
        }
    }
    
    fileprivate func socketConnection(_ socketConnection: SocketConnection, succeededWithNetworkConnection networkConnection: NetworkConnection) {
        NetworkRunLoopThread.shared.async {
            let host = socketConnection.host
            let identifier = host.identifier

            if self.pendingConnections[identifier] != nil {
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
        NetworkRunLoopThread.shared.async {
            debugLog("connection accepted on \(channel.remoteAddress ?? "nil")", module: .network)

            channel.setNoDelay(true)

            let connection = NetworkConnection(channel: channel)
            connection.delegate = self
            // Fire and forget - identification message
            connection.sendAsync(TPConnectionsManager.identificationMessage())
            self.connections.insert(connection)
        }
    }

    func listenerShouldEnableEncryption(_ listener: MessageListener, forRemoteAddress address: String?) -> Bool {
        shouldEnableEncryption(forRemoteAddress: address)
    }
}

extension TPConnectionsManager {
    /// Decide whether to use encryption for a peer at the given address, based on
    /// the shared encryption capability. Also used by file transfers (which keep
    /// running on the legacy `TPTCPSecureSocket` regardless of the control stack).
    @objc func shouldEnableEncryption(forRemoteAddress address: String?) -> Bool {
        guard let remoteAddress = address else {
            let encryptionActive = TPPreferencesManager.shared().bool(forPref: ENABLED_ENCRYPTION)
            warningLog("could not determine remote address, will\(encryptionActive ? "" : " NOT") use encryption as it is configured so locally", module: .network)
            return encryptionActive
        }

        if let remoteHost = TPHostsManager.shared.host(withAddress: remoteAddress) {
            return TPLocalHost.shared.pairWith(host: remoteHost, hasCapability: .encryption)
        } else {
            let encryptionActive = TPPreferencesManager.shared().bool(forPref: ENABLED_ENCRYPTION)
            warningLog("could not determine which host has IP \(remoteAddress), will\(encryptionActive ? "" : " NOT") use encryption as it is configured so locally", module: .network)
            return encryptionActive
        }
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
                    listenDelegate?.connectionFromClientAccepted(connection)
                }
            } else {
                errorLog("received message with invalid protocol (\(protocolVersion) vs \(PROTOCOL_VERSION))", module: .network)
            }
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
