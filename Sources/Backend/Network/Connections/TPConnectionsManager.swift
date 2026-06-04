// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

private let TPMsgProtocolVersionKey = "proto-version"
private let TPMsgHostDataKey = "host-data"

// MARK: - Internal SocketConnection Class

private class SocketConnection: NSObject, TPTCPSecureSocketDelegate {
    private(set) var socket: TPTCPSecureSocket?
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
        
        let socket = TPTCPSecureSocket(delegate: self)
        self.socket = socket
        
        let enableEncryption = TPLocalHost.shared.pairWith(host: remoteHost, hasCapability: .encryption)
        socket.enableEncryption = enableEncryption
        
        if socket.connect(toHost: remoteHost.address, onPort: Int32(remoteHost.port)) {
            socket.setNoDelay(true)
        } else {
            socket.close()
            return nil
        }
    }
    
    func close() {
        socket?.close()
    }
    
    // MARK: - TPTCPSecureSocketDelegate
    
    func tcpSocketConnectionSucceeded(_ tcpSocket: TPTCPSocket) {
        debugLog("SocketConnection tcpSocketConnectionSucceeded", module: .network)
        
        // If this is a secure socket, save the peer certificate
        if let secureSocket = tcpSocket as? TPTCPSecureSocket, secureSocket.enableEncryption {
            if let certRef = secureSocket.copyPeerCertificate {
                host.certificate = certRef
            }
        }
        
        let networkConnection = NetworkConnection(socket: tcpSocket)
        self.connection = networkConnection
        
        connection?.delegate = self
        // Fire and forget - identification message
        connection?.sendAsync(TPConnectionsManager.identificationMessage())
    }
    
    func tcpSocketConnectionFailed(_ tcpSocket: TPTCPSocket) {
        debugLog("SocketConnection tcpSocketConnectionFailed", module: .network)
        TPConnectionsManager.shared.socketConnectionFailed(self)
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
        // Handle disconnection if needed
    }
}

// MARK: - TPConnectionsManager

@objc class TPConnectionsManager: NSObject {
    
    @objc static let shared = TPConnectionsManager()
    
    private var connections = Set<NetworkConnection>()
    private var pendingConnections = [String: SocketConnection]()
    private var listenSocket: TPTCPSecureSocket?
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
        
        if pendingConnections[host.identifier] != nil {
            debugLog("connectToHost: \(host.identifier), pending...", module: .network)
            return true
        }
        
        if let connection = SocketConnection(connectionToHost: host, delegate: delegate, infoDict: infoDict) {
            pendingConnections[host.identifier] = connection
            debugLog("connectToHost: \(host.identifier), add to pendingConnections", module: .network)
            return true
        } else {
            debugLog("connectToHost: \(host.identifier), failed immediately", module: .network)
            return false
        }
    }
    
    // MARK: - Listening
    
    @objc func startListening(withDelegate delegate: TPServerConnectionsDelegate?, onPort port: UnsafeMutablePointer<Int32>) -> Bool {
        if listenSocket != nil {
            return true
        }
        
        listenDelegate = delegate
        
        let enableEncryption = TPLocalHost.shared.hasCapability(.encryption)
        let socket = TPTCPSecureSocket(delegate: self)
        socket.enableEncryption = enableEncryption
        listenSocket = socket
        
        return socket.listen(onPort: port, tries: 50)
    }
    
    @objc func stopListening() {
        listenSocket?.close()
        listenSocket = nil
    }
    
    // MARK: - Socket Connection Callbacks
    
    fileprivate func socketConnectionFailed(_ socketConnection: SocketConnection) {
        let host = socketConnection.host
        let identifier = host.identifier
        
        if pendingConnections[identifier] != nil {
            socketConnection.delegate?.connectionToServerFailed(host, infoDict: socketConnection.infoDict)
            pendingConnections.removeValue(forKey: identifier)
        }
    }
    
    fileprivate func socketConnection(_ socketConnection: SocketConnection, succeededWithNetworkConnection networkConnection: NetworkConnection) {
        let host = socketConnection.host
        let identifier = host.identifier
        
        if pendingConnections[identifier] != nil {
            socketConnection.delegate?.connectionToServerSucceeded(networkConnection, infoDict: socketConnection.infoDict)
            pendingConnections.removeValue(forKey: identifier)
        }
    }
    
    // MARK: - Reset
    
    @objc func reset() {
        for connection in connections {
            connection.disconnect()
        }
        connections.removeAll()
        
        for connection in pendingConnections.values {
            connection.close()
        }
        pendingConnections.removeAll()
    }
}

// MARK: - TPTCPSecureSocketDelegate

extension TPConnectionsManager: TPTCPSecureSocketDelegate {
    
    func tcpSocket(_ listenSocket: TPTCPSocket, connectionAccepted childSocket: TPTCPSocket) {
        debugLog("connection accepted from \(listenSocket) on \(childSocket)", module: .network)
        
        childSocket.setNoDelay(true)
        
        let connection = NetworkConnection(socket: childSocket)
        connection.delegate = self
        // Fire and forget - identification message
        connection.sendAsync(TPConnectionsManager.identificationMessage())
        connections.insert(connection)
    }
    
    func tcpSecureSocketShouldEnableEncryption(_ tcpSocket: TPTCPSecureSocket) -> Bool {
        guard let remoteAddress = tcpSocket.remoteAddress else {
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
    
    func tcpSocketConnectionSucceeded(_ tcpSocket: TPTCPSocket) {
        // Not used for listen socket
    }
    
    func tcpSocketConnectionFailed(_ tcpSocket: TPTCPSocket) {
        // Not used for listen socket
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
        connections.remove(connection)
    }
}
