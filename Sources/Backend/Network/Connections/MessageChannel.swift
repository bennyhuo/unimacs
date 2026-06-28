// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  Transport abstraction for the control connection.
//  `NetworkConnection` (message framing) and `TPConnectionsManager` (connect /
//  listen orchestration) talk to the network through `MessageChannel` /
//  `MessageListener` instead of the concrete ObjC socket. Two implementations
//  exist behind a runtime switch (`USE_SWIFT_NETWORK_STACK`):
//    * `LegacySocketChannel` / `LegacyMessageListener` — thin adapters over the
//      proven ObjC `TPTCPSecureSocket` (CFSocket + SecureTransport).
//    * `NWMessageChannel`   / `NWMessageListener`      — Network.framework
//      (`NWConnection` / `NWListener`) implementation (see NWMessageChannel.swift).
//  The on-wire protocol (TPMessage framing + TLS) is identical for both, so the
//  two stacks interoperate across machines; the switch is per-process.
//  ┌─ STATUS (2026-06-23): the Swift Network.framework rewrite is PAUSED ────────┐
//  │ `USE_SWIFT_NETWORK_STACK` defaults to OFF, so production runs entirely on   │
//  │ `LegacySocketChannel` (the proven ObjC socket). The NW backend still needs  │
//  │ its TLS / encryption=true path validated before it can be the default.      │
//  │                                                                             │
//  │ This abstraction is intentionally the *seam* the transport sits behind, so  │
//  │ upper-layer work (DeviceConnectionManager / TPConnectionsManager refactor,  │
//  │ unifying the connection entry point) can proceed without touching the NW    │
//  │ rewrite. To avoid breaking either backend while refactoring:                │
//  │   • ALWAYS create transports via `MessageTransportFactory` — never `new`    │
//  │     a `TPTCPSecureSocket` / `NWConnection` directly in upper layers.        │
//  │   • Keep call sites typed as `MessageChannel` / `MessageListener`, not the  │
//  │     concrete classes, so the toggle keeps switching both implementations.   │
//  │   • Don't assume which thread delegate callbacks arrive on (legacy = the    │
//  │     network run loop; NW = its own dispatch queue). Hop explicitly if you   │
//  │     touch main-thread / shared state.                                       │
//  └─────────────────────────────────────────────────────────────────────────────┘

import Foundation
import Security

// MARK: - Delegates

/// Events for a single message channel (an outbound or accepted connection).
protocol MessageChannelDelegate: AnyObject {
    /// The channel finished connecting (TCP + optional TLS handshake done).
    func channelDidConnect(_ channel: MessageChannel)
    /// The channel failed before it ever became connected.
    func channelDidFailToConnect(_ channel: MessageChannel)
    /// A previously connected channel was closed/dropped.
    func channelDidDisconnect(_ channel: MessageChannel)
    /// Raw bytes arrived (already decrypted when encryption is on).
    func channel(_ channel: MessageChannel, didReceiveData data: Data)
}

/// Events for a listening socket.
protocol MessageListenerDelegate: AnyObject {
    /// A new inbound connection was accepted and is ready to use.
    func listener(_ listener: MessageListener, didAcceptChannel channel: MessageChannel)
    /// Whether encryption should be used for a peer at the given address.
    /// (Honoured by the legacy stack per-connection; the NW stack decides at
    /// listen time, see `NWMessageListener`.)
    func listenerShouldEnableEncryption(_ listener: MessageListener, forRemoteAddress address: String?) -> Bool
}

// MARK: - Channel / Listener protocols

/// A bidirectional byte channel carrying framed `TPMessage`s.
protocol MessageChannel: AnyObject {
    var delegate: MessageChannelDelegate? { get set }

    /// Current connection state (reuses the ObjC enum so existing call sites and
    /// logging keep working unchanged).
    var state: TPSocketState { get }

    var localAddress: String? { get }
    var remoteAddress: String? { get }

    /// The peer's leaf certificate captured during the TLS handshake (TOFU).
    var peerCertificate: SecCertificate? { get }

    /// Whether TLS is used. Must be set before `connect`.
    var enableEncryption: Bool { get set }

    /// Apply TCP_NODELAY. May be called before `connect`; implementations defer
    /// application until the underlying socket exists if needed.
    func setNoDelay(_ value: Bool)

    /// Begin an outbound connection. Returns `false` on immediate failure;
    /// otherwise success/failure is reported asynchronously via the delegate.
    @discardableResult
    func connect(toHost host: String, port: Int32) -> Bool

    /// Synchronously write bytes. Returns whether the write succeeded.
    @discardableResult
    func send(_ data: Data) -> Bool

    func close()
}

/// A listening socket that produces accepted `MessageChannel`s.
protocol MessageListener: AnyObject {
    var delegate: MessageListenerDelegate? { get set }

    /// Whether accepted connections use TLS. Must be set before `start`.
    var enableEncryption: Bool { get set }

    /// Start listening. `port` is in/out: on success it holds the bound port.
    /// `tries` consecutive ports are attempted starting from `*port`.
    @discardableResult
    func start(onPort port: UnsafeMutablePointer<Int32>, tries: Int) -> Bool

    func stop()
}

// MARK: - Factory

/// Creates channels/listeners for the currently selected network stack.
///
/// IMPORTANT: this is the single place that decides legacy-vs-NW. Every outbound
/// connection and listener MUST be created here so the `USE_SWIFT_NETWORK_STACK`
/// toggle keeps working. When refactoring the upper layers, route new connection
/// creation through `makeChannel` / `makeListener` rather than instantiating a
/// concrete socket — otherwise you silently pin the app to one backend.
enum MessageTransportFactory {

    /// Whether the Swift Network.framework stack is selected.
    /// NOTE: the NW backend is paused/unverified (TLS path), so this is OFF by
    /// default; today this returns `true` only if the user flips the hidden toggle.
    static var usesSwiftStack: Bool {
        TPPreferencesManager.shared().bool(forPref: USE_SWIFT_NETWORK_STACK)
    }

    /// An outbound channel, not yet connected.
    static func makeChannel(enableEncryption: Bool) -> MessageChannel {
        let channel: MessageChannel = usesSwiftStack
            ? NWMessageChannel()
            : LegacySocketChannel()
        channel.enableEncryption = enableEncryption
        return channel
    }

    /// A listener, not yet started.
    static func makeListener(enableEncryption: Bool) -> MessageListener {
        let listener: MessageListener = usesSwiftStack
            ? NWMessageListener()
            : LegacyMessageListener()
        listener.enableEncryption = enableEncryption
        return listener
    }
}

// MARK: - Legacy adapter (TPTCPSecureSocket)

/// Adapts the ObjC `TPTCPSecureSocket` to `MessageChannel`.
final class LegacySocketChannel: NSObject, MessageChannel, TPTCPSecureSocketDelegate {

    private var secureSocket: TPTCPSecureSocket!
    private var pendingNoDelay: Bool?
    /// Accepted children arrive already connected; outbound channels start idle.
    private let isAccepted: Bool

    weak var delegate: MessageChannelDelegate?

    /// Outbound channel.
    override init() {
        self.isAccepted = false
        super.init()
        self.secureSocket = TPTCPSecureSocket(delegate: self)
    }

    /// Wrap a child socket handed up by the listen socket (already connected).
    init(acceptedSocket: TPTCPSecureSocket) {
        self.isAccepted = true
        super.init()
        self.secureSocket = acceptedSocket
        secureSocket.delegate = self
    }

    var enableEncryption: Bool {
        get { secureSocket.enableEncryption }
        set { secureSocket.enableEncryption = newValue }
    }

    var state: TPSocketState { secureSocket.socketState }
    var localAddress: String? { secureSocket.localAddress }
    var remoteAddress: String? { secureSocket.remoteAddress }
    var peerCertificate: SecCertificate? {
        secureSocket.enableEncryption ? secureSocket.copyPeerCertificate : nil
    }

    func setNoDelay(_ value: Bool) {
        // The legacy socket can only set the option once its native socket exists.
        if secureSocket.socketState == .connectedState || secureSocket.socketState == .connectingState {
            secureSocket.setNoDelay(value)
        } else {
            pendingNoDelay = value
        }
    }

    @discardableResult
    func connect(toHost host: String, port: Int32) -> Bool {
        let ok = secureSocket.connect(toHost: host, onPort: port)
        if ok, let pending = pendingNoDelay {
            secureSocket.setNoDelay(pending)
            pendingNoDelay = nil
        }
        return ok
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        secureSocket.send(data)
    }

    func close() {
        secureSocket.close()
    }

    // MARK: TPTCPSocketDelegate

    func tcpSocketConnectionSucceeded(_ tcpSocket: TPTCPSocket) {
        delegate?.channelDidConnect(self)
    }

    func tcpSocketConnectionFailed(_ tcpSocket: TPTCPSocket) {
        delegate?.channelDidFailToConnect(self)
    }

    func tcpSocketConnectionClosed(_ tcpSocket: TPTCPSocket) {
        delegate?.channelDidDisconnect(self)
    }

    func tcpSocket(_ tcpSocket: TPTCPSocket, gotData data: Data) {
        delegate?.channel(self, didReceiveData: data)
    }
}

/// Adapts the ObjC `TPTCPSecureSocket` listen socket to `MessageListener`.
final class LegacyMessageListener: NSObject, MessageListener, TPTCPSecureSocketDelegate {

    private var listenSocket: TPTCPSecureSocket!
    weak var delegate: MessageListenerDelegate?

    override init() {
        super.init()
        self.listenSocket = TPTCPSecureSocket(delegate: self)
    }

    var enableEncryption: Bool {
        get { listenSocket.enableEncryption }
        set { listenSocket.enableEncryption = newValue }
    }

    @discardableResult
    func start(onPort port: UnsafeMutablePointer<Int32>, tries: Int) -> Bool {
        listenSocket.listen(onPort: port, tries: Int32(tries))
    }

    func stop() {
        listenSocket.close()
    }

    // MARK: TPTCPSecureSocketDelegate

    func tcpSocket(_ listenSocket: TPTCPSocket, connectionAccepted childSocket: TPTCPSocket) {
        guard let secureChild = childSocket as? TPTCPSecureSocket else { return }
        let channel = LegacySocketChannel(acceptedSocket: secureChild)
        delegate?.listener(self, didAcceptChannel: channel)
    }

    func tcpSecureSocketShouldEnableEncryption(_ tcpSocket: TPTCPSecureSocket) -> Bool {
        delegate?.listenerShouldEnableEncryption(self, forRemoteAddress: tcpSocket.remoteAddress) ?? false
    }
}
