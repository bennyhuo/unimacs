// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Protocol for receiving connection events
@objc protocol NetworkConnectionDelegate: AnyObject {
    @objc func connectionDisconnected(_ connection: NetworkConnection)
    @objc func connection(_ connection: NetworkConnection, receivedMessage message: TPMessage)
}

/// Result type for message sending operations
enum SendMessageResult {
    case success
    case queued
    case failed(Error)
    case notConnected
}

/// Error types for network connection operations
enum NetworkConnectionError: Error, LocalizedError {
    case socketNotConnected
    case sendFailed
    case invalidState
    
    var errorDescription: String? {
        switch self {
        case .socketNotConnected:
            return "Socket is not connected"
        case .sendFailed:
            return "Failed to send message"
        case .invalidState:
            return "Connection is in an invalid state"
        }
    }
}

/// Swift implementation of TPNetworkConnection with async/await support
/// This class manages a network connection and provides async message sending
@objcMembers
class NetworkConnection: NSObject, TPTCPSocketDelegate {
    
    // MARK: - Properties
    
    /// The underlying socket
    private let _socket: TPTCPSocket
    var socket: TPTCPSocket { _socket }
    
    /// Unique identifier for this connection
    let connectionId: String
    
    /// Network interface name for this connection
    private(set) var networkInterfaceName: String?
    
    /// The connected remote host
    var connectedHost: TPRemoteHost? {
        didSet {
            if let host = connectedHost, let remoteAddress = _socket.remoteAddress {
                host.address = remoteAddress
            }
        }
    }
    
    /// Local host capabilities at connection time
    private let _capabilities: TPHostCapability
    var localHostCapabilities: TPHostCapability { _capabilities }
    
    /// Connection delegate for receiving events
    weak var delegate: NetworkConnectionDelegate?
    
    /// Transfers manager for this connection
    private(set) var transfersManager: TPTransfersManager?
    
    // MARK: - Private Properties
    
    /// Buffer for incoming message data
    private var msgBuffer = Data()
    
    /// Actor-based manager for pending messages (thread-safe)
    private let pendingMessagesManager = PendingMessagesManager()
    
    /// Serial queue for thread-safe message sending
    private let sendQueue = DispatchQueue(label: "com.teleport.networkconnection.send", qos: .userInitiated)
    
    /// Continuation for async send operations
    private var sendContinuations: [CheckedContinuation<Bool, Never>] = []
    
    // MARK: - Initialization
    
    init(socket: TPTCPSocket) {
        self._socket = socket
        self.connectionId = Self.generateConnectionId()
        self._capabilities = TPLocalHost.shared.capabilities
        
        super.init()
        
        _socket.delegate = self
		networkInterfaceName = NetworkUtils.interfaceName(forIPAddress: _socket.localAddress)
        
        infoLog("[Conn:\(connectionId)] Connection initialized, local=\(_socket.localAddress ?? "nil"), remote=\(_socket.remoteAddress ?? "nil")")
    }
    
    // MARK: - Static Methods
    
    private static func generateConnectionId() -> String {
        let uuid = UUID().uuidString
        return String(uuid.prefix(8))
    }
    
    // MARK: - Public Methods
    
    /// Check if connection is valid for the given host
    func isValid(for host: TPRemoteHost?) -> Bool {
        guard let host = host, let connectedHost = connectedHost else {
            return false
        }
        guard connectedHost.isEqual(host) else {
            return false
        }
        guard localHostCapabilities == TPLocalHost.shared.capabilities else {
            return false
        }
        guard _socket.remoteAddress == host.address else {
            return false
        }
        return true
    }
    
    /// Whether the socket is currently connected
    var isConnected: Bool {
        return _socket.socketState == .connectedState
    }
    
    /// Disconnect the connection
    func disconnect() {
        let hostName = connectedHost?.computerName ?? "unknown"
        let socketState = _socket.socketState
        debugLog("[Conn:\(connectionId)] disconnect() called, host=\(hostName), socketState=\(socketState.rawValue)", module: .network)
        _socket.close()
        Task {
            await pendingMessagesManager.clear()
        }
    }
    
    // MARK: - Message Sending (Async)
    
    /// Send a message asynchronously (non-blocking)
    /// - Parameter message: The message to send
    /// - Returns: Whether the message was sent/queued successfully
    @discardableResult
    func sendMessageAsync(_ message: TPMessage) async -> Bool {
        let state = _socket.socketState
        
        switch state {
case .connectedState:
            return await withCheckedContinuation { continuation in
                sendQueue.async { [weak self] in
                    guard let self = self else {
                        continuation.resume(returning: false)
                        return
                    }
                    
                    let msgTypeDesc = self.messageTypeDescription(message.msgType)
                    let infoDesc = self.messageInfoDescription(message)
                    debugLog("[Conn:\(self.connectionId)] Sending message: type=\(msgTypeDesc)\(infoDesc)", module: .network)
                    
                    let result = self._socket.send(message.rawData)
                    
                    if result {
                        debugLog("[Conn:\(self.connectionId)] Message sent successfully: type=\(msgTypeDesc)", module: .network)
                    } else {
                        let socketState = self._socket.socketState
                        errorLog("[Conn:\(self.connectionId)] Failed to send message: type=\(msgTypeDesc), socketState=\(socketState.rawValue)", module: .network)
                        // Notify delegate on main thread
                        DispatchQueue.main.async { [weak self] in
                            guard let self = self else { return }
                            self.delegate?.connectionDisconnected(self)
                        }
                    }
                    
                    continuation.resume(returning: result)
                }
            }
            
case .connectingState:
            debugLog("[Conn:\(connectionId)] Queuing pending message: \(message)")
            await pendingMessagesManager.append(message)
            return true
            
        default:
            warningLog("[Conn:\(connectionId)] Cannot send message, socket not connected (state=\(state.rawValue))", module: .network)
            return false
        }
    }
    
    /// Send a message synchronously (for backward compatibility with ObjC)
    /// Note: This may block the calling thread
    /// - Parameter message: The message to send
    /// - Returns: Whether the message was sent/queued successfully
    @discardableResult
    func send(_ message: TPMessage) -> Bool {
        let state = _socket.socketState
        
        switch state {
case .connectedState:
            let msgTypeDesc = messageTypeDescription(message.msgType)
            let infoDesc = messageInfoDescription(message)
            debugLog("[Conn:\(connectionId)] Sending message (sync): type=\(msgTypeDesc)\(infoDesc)", module: .network)
            
            let result = _socket.send(message.rawData)
            
            if result {
                debugLog("[Conn:\(connectionId)] Message sent successfully (sync): type=\(msgTypeDesc)", module: .network)
            } else {
                let socketState = _socket.socketState
                errorLog("[Conn:\(connectionId)] Failed to send message (sync): type=\(msgTypeDesc), socketState=\(socketState.rawValue)", module: .network)
                delegate?.connectionDisconnected(self)
            }
            
            return result
            
case .connectingState:
            debugLog("[Conn:\(connectionId)] Queuing pending message: \(message)")
            // Use synchronous wrapper for backward compatibility
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await pendingMessagesManager.append(message)
                semaphore.signal()
            }
            semaphore.wait()
            return true
            
        default:
            warningLog("[Conn:\(connectionId)] Cannot send message, socket not connected (state=\(state.rawValue))", module: .network)
            return false
        }
    }
    
    /// Send pending messages after connection is established
    /// - Returns: Whether all pending messages were sent successfully
    @discardableResult
    func sendPendingMessages() async -> Bool {
        let messages = await pendingMessagesManager.takeAll()
        
        guard !messages.isEmpty else { return true }
        
        debugLog("[Conn:\(connectionId)] Sending \(messages.count) pending messages")
        
        var success = true
        for message in messages {
            if await !sendMessageAsync(message) {
                success = false
                errorLog("[Conn:\(connectionId)] Error sending pending message: \(message)", module: .network)
            }
        }
        
        return success
    }
    
    /// Send pending messages synchronously (for backward compatibility)
    @discardableResult
    func sendPendingMessagesSync() -> Bool {
        var messages: [TPMessage] = []
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            messages = await pendingMessagesManager.takeAll()
            semaphore.signal()
        }
        semaphore.wait()
        
        guard !messages.isEmpty else { return true }
        
        debugLog("[Conn:\(connectionId)] Sending \(messages.count) pending messages")
        
        var success = true
        for message in messages {
            if !send(message) {
                success = false
                errorLog("[Conn:\(connectionId)] Error sending pending message: \(message)", module: .network)
            }
        }
        
        return success
    }
    
    // MARK: - Fire and Forget
    
    /// Send a message without waiting for result (fire and forget)
    /// This is the preferred method for control messages that don't need confirmation
    func sendAsync(_ message: TPMessage) {
        Task {
            await sendMessageAsync(message)
        }
    }
    
    // MARK: - TPTCPSocketDelegate
    
    func tcpSocket(_ tcpSocket: TPTCPSocket, gotData data: Data) {
        debugLog("[Conn:\(connectionId)] Got raw data (\(data.count) bytes), buffer size=\(msgBuffer.count)", module: .network)
        
        guard !data.isEmpty else {
            warningLog("[Conn:\(connectionId)] Received empty data from socket", module: .network)
            return
        }
        
        msgBuffer.append(data)
        
        var cont = true
        while msgBuffer.count >= TPMessageHeaderLength && cont {
			guard let message = TPMessage(rawData: msgBuffer) else {
				cont = false
				continue
			}
			let msgLength = Int(message.msgLength)
			if msgLength > 0 {
				let msgTypeDesc = messageTypeDescription(message.msgType)
				let infoDesc = messageInfoDescription(message)
				debugLog("[Conn:\(connectionId)] Received message: type=\(msgTypeDesc), length=\(msgLength)\(infoDesc)", module: .network)
				msgBuffer.removeSubrange(0..<msgLength)
				delegate?.connection(self, receivedMessage: message)
			} else {
				cont = false
			}
        }
    }
    
    func tcpSocketConnectionClosed(_ tcpSocket: TPTCPSocket) {
        let hostName = connectedHost?.computerName ?? "unknown"
        let remoteAddr = _socket.remoteAddress ?? "nil"
        let socketState = _socket.socketState
        warningLog("[Conn:\(connectionId)] Connection closed by socket callback, host=\(hostName), remote=\(remoteAddr), socketState=\(socketState.rawValue), bufferSize=\(msgBuffer.count)", module: .network)
        msgBuffer.removeAll()
        
        delegate?.connectionDisconnected(self)
        disconnect()
    }
    
    // MARK: - Message Logging Helpers
    
    /// Get human-readable description of message type
    private func messageTypeDescription(_ msgType: TPMsgType) -> String {
        switch msgType {
        case .identification: return "Identification"
        case .authenticationRequest: return "AuthenticationRequest"
        case .authenticationInProgress: return "AuthenticationInProgress"
        case .authenticationAbort: return "AuthenticationAbort"
        case .authenticationSuccess: return "AuthenticationSuccess"
        case .authenticationFailure: return "AuthenticationFailure"
        case .controlRequest: return "ControlRequest"
        case .controlSuccess: return "ControlSuccess"
        case .controlFailure: return "ControlFailure"
        case .controlStop: return "ControlStop"
        case .controlWake: return "ControlWake"
        case .controlScreenSleep: return "ControlScreenSleep"
        case .controlDeviceSleep: return "ControlDeviceSleep"
        case .controlLock: return "ControlLock"
        case .event: return "Event"
        case .transferRequest: return "TransferRequest"
        case .transferSuccess: return "TransferSuccess"
        case .transferFailure: return "TransferFailure"
        @unknown default: return "Unknown(\(msgType.rawValue))"
        }
    }
    
    /// Get readable description of message info dict
    private func messageInfoDescription(_ message: TPMessage) -> String {
        let msgType = message.msgType
        
        // Skip detailed info for high-frequency event messages
        if msgType == .event {
            return ", dataLen=\(message.dataLength)"
        }
        
        let infoDict = message.infoDict
        guard !infoDict.isEmpty else {
            return ""
        }
        
        // Extract readable fields from infoDict
        var parts: [String] = []
        for (key, value) in infoDict {
            let keyStr = "\(key)"
            // Skip binary data fields, show their presence instead
            if value is Data || value is NSData {
                parts.append("\(keyStr)=<data>")
            } else {
                parts.append("\(keyStr)=\(value)")
            }
        }
        
        if parts.isEmpty {
            return ""
        }
        return ", info={\(parts.joined(separator: ", "))}"
    }
}

// MARK: - Pending Messages Manager Actor

/// Actor to manage pending messages with thread-safe access
private actor PendingMessagesManager {
    private var messages: [TPMessage] = []
    
    func append(_ message: TPMessage) {
        messages.append(message)
    }
    
    func takeAll() -> [TPMessage] {
        let result = messages
        messages.removeAll()
        return result
    }
    
    func clear() {
        messages.removeAll()
    }
}

// MARK: - ObjC Compatibility Extension

extension NetworkConnection {
    /// For ObjC compatibility - alias for send(_:)
    @objc(sendMessage:)
    func sendMessage(_ message: TPMessage) -> Bool {
        return send(message)
    }
}
