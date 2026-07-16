// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import Security

// MARK: - Delegates

/// Events for a single message channel (an outbound or accepted connection).
protocol MessageChannelDelegate: AnyObject {
    func channelDidConnect(_ channel: MessageChannel)
    func channelDidFailToConnect(_ channel: MessageChannel)
    func channelDidDisconnect(_ channel: MessageChannel)
    func channel(_ channel: MessageChannel, didReceiveData data: Data)
}

/// Events for a listening socket.
protocol MessageListenerDelegate: AnyObject {
    func listener(_ listener: MessageListener, didAcceptChannel channel: MessageChannel)
    /// Legacy hook retained for API compatibility; always ignored (no TLS).
    func listenerShouldEnableEncryption(_ listener: MessageListener, forRemoteAddress address: String?) -> Bool
}

// MARK: - Channel / Listener protocols

protocol MessageChannel: AnyObject {
    var delegate: MessageChannelDelegate? { get set }
    var state: TPSocketState { get }
    var localAddress: String? { get }
    var remoteAddress: String? { get }
    var peerCertificate: SecCertificate? { get }
    var enableEncryption: Bool { get set }
    func setNoDelay(_ value: Bool)
    /// Begin delivering inbound data on accepted legacy sockets (after delegate wiring).
    func activateReceiveCallbacks()
    @discardableResult
    func connect(toHost host: String, port: Int32) -> Bool
    @discardableResult
    func send(_ data: Data) -> Bool
    func close()
}

protocol MessageListener: AnyObject {
    var delegate: MessageListenerDelegate? { get set }
    var enableEncryption: Bool { get set }
    @discardableResult
    func start(onPort port: UnsafeMutablePointer<Int32>, tries: Int) -> Bool
    func stop()
}

// MARK: - Factory

enum MessageTransportFactory {

    static var usesSwiftStack: Bool {
        PreferencesManager.shared().bool(forPref: USE_SWIFT_NETWORK_STACK)
    }

    static func makeChannel(enableEncryption: Bool = false) -> MessageChannel {
        let channel: MessageChannel = usesSwiftStack
            ? NWMessageChannel()
            : LegacySocketChannel()
        channel.enableEncryption = false
        return channel
    }

    static func makeListener(enableEncryption: Bool = false) -> MessageListener {
        let listener: MessageListener = usesSwiftStack
            ? NWMessageListener()
            : LegacyMessageListener()
        listener.enableEncryption = false
        return listener
    }
}

// MARK: - Legacy adapter (plain UMTCPSocket)

final class LegacySocketChannel: NSObject, MessageChannel, UMTCPSocketDelegate {

    private var tcpSocket: UMTCPSocket!
    private var pendingNoDelay: Bool?
    private let isAccepted: Bool

    weak var delegate: MessageChannelDelegate?

    override init() {
        self.isAccepted = false
        super.init()
        self.tcpSocket = UMTCPSocket(delegate: self)
    }

    init(acceptedSocket: UMTCPSocket) {
        self.isAccepted = true
        super.init()
        self.tcpSocket = acceptedSocket
        tcpSocket.delegate = self
    }

    var enableEncryption: Bool {
        get { false }
        set { /* TLS removed */ }
    }

    var state: TPSocketState { tcpSocket.socketState }
    var localAddress: String? { tcpSocket.localAddress }
    var remoteAddress: String? { tcpSocket.remoteAddress }
    var peerCertificate: SecCertificate? { nil }

    func setNoDelay(_ value: Bool) {
        if tcpSocket.socketState == .connectedState || tcpSocket.socketState == .connectingState {
            tcpSocket.setNoDelay(value)
        } else {
            pendingNoDelay = value
        }
    }

    @discardableResult
    func connect(toHost host: String, port: Int32) -> Bool {
        let ok = tcpSocket.connect(toHost: host, onPort: port)
        if ok, let pending = pendingNoDelay {
            tcpSocket.setNoDelay(pending)
            pendingNoDelay = nil
        }
        return ok
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        tcpSocket.send(data)
    }

    func close() {
        tcpSocket.close()
    }

    func activateReceiveCallbacks() {
        tcpSocket.activateReceiveCallbacks()
        if let pending = pendingNoDelay {
            tcpSocket.setNoDelay(pending)
            pendingNoDelay = nil
        }
    }

    func tcpSocketConnectionSucceeded(_ tcpSocket: UMTCPSocket) {
        delegate?.channelDidConnect(self)
    }

    func tcpSocketConnectionFailed(_ tcpSocket: UMTCPSocket) {
        delegate?.channelDidFailToConnect(self)
    }

    func tcpSocketConnectionClosed(_ tcpSocket: UMTCPSocket) {
        delegate?.channelDidDisconnect(self)
    }

    func tcpSocket(_ tcpSocket: UMTCPSocket, gotData data: Data) {
        delegate?.channel(self, didReceiveData: data)
    }
}

final class LegacyMessageListener: NSObject, MessageListener, UMTCPSocketDelegate {

    private var listenSocket: UMTCPSocket!
    weak var delegate: MessageListenerDelegate?

    override init() {
        super.init()
        self.listenSocket = UMTCPSocket(delegate: self)
    }

    var enableEncryption: Bool {
        get { false }
        set { /* TLS removed */ }
    }

    @discardableResult
    func start(onPort port: UnsafeMutablePointer<Int32>, tries: Int) -> Bool {
        listenSocket.listen(onPort: port, tries: Int32(tries))
    }

    func stop() {
        listenSocket.close()
    }

    func tcpSocket(_ listenSocket: UMTCPSocket, connectionAccepted childSocket: UMTCPSocket) {
        let channel = LegacySocketChannel(acceptedSocket: childSocket)
        delegate?.listener(self, didAcceptChannel: channel)
    }
}
