// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import Security

// MARK: - Socket State

enum SocketState: Int {
    case disconnectedState = 0
    case listeningState
    case connectingState
    case connectedState
    case errorState
}

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
    var state: SocketState { get }
    var localAddress: String? { get }
    var remoteAddress: String? { get }
    var lastFailureReason: String? { get }
    var peerCertificate: SecCertificate? { get }
    var enableEncryption: Bool { get set }
    func setNoDelay(_ value: Bool)
    /// Begin delivering inbound data on accepted channels (after delegate wiring).
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

    static func makeChannel(enableEncryption: Bool = false) -> MessageChannel {
        let channel = NWMessageChannel()
        channel.enableEncryption = enableEncryption
        return channel
    }

    static func makeListener(enableEncryption: Bool = false) -> MessageListener {
        let listener = NWMessageListener()
        listener.enableEncryption = enableEncryption
        return listener
    }
}
