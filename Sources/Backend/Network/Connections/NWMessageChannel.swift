// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  Network.framework implementation of the control-connection transport
//  (`MessageChannel` / `MessageListener`). Selected at runtime when
//  `USE_SWIFT_NETWORK_STACK` is enabled.
//  TLS is configured to match the legacy `TPTCPSecureSocket` semantics so the
//  two stacks interoperate on the wire:
//    * mutual authentication — both ends present a local identity
//      (`sec_protocol_options_set_local_identity` + peer auth required),
//    * certificate verification is delegated to the app (trust-on-first-use):
//      the verify block accepts every chain and captures the peer leaf cert,
//    * minimum TLS 1.2, so there is a common version with SecureTransport.
//  STATUS (2026-06-23): PAUSED / not the default. `USE_SWIFT_NETWORK_STACK` is OFF
//  in production. Known-working: plaintext (encryption=false) control + transfers.
//  NOT yet validated: the TLS path (encryption=true, mutual auth, TOFU capture) and
//  cross-stack interop (one end NW, the other legacy). Treat this file as
//  experimental until those are verified — see docs/network-connection-plan.md.

import Foundation
import Network
import Security

// MARK: - TLS configuration

private enum NWTLSConfigurator {

    /// Build TCP options for a control channel.
    static func tcpOptions(noDelay: Bool) -> NWProtocolTCP.Options {
        let options = NWProtocolTCP.Options()
        options.noDelay = noDelay
        options.enableKeepalive = true
        options.keepaliveIdle = 10
        options.keepaliveInterval = 5
        options.keepaliveCount = 3
        return options
    }

    /// Build TLS options replicating the legacy mutual-auth / TOFU behaviour.
    /// `onPeerCertificate` is invoked during the handshake with the peer leaf cert.
    static func tlsOptions(verifyQueue: DispatchQueue,
                           onPeerCertificate: @escaping (SecCertificate) -> Void) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions

        // Present our identity for mutual authentication and require the peer's.
        if let identity = IdentityManager.identity(),
           let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(sec, secIdentity)
        } else {
            warningLog("[NW] No local identity available; TLS handshake will likely fail", module: .network)
        }
        sec_protocol_options_set_peer_authentication_required(sec, true)

        // Common floor with the legacy SecureTransport stack.
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)

        // Trust-on-first-use: accept any chain, capture the peer leaf certificate.
        sec_protocol_options_set_verify_block(sec, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            if let cert = leafCertificate(from: trust) {
                onPeerCertificate(cert)
            }
            complete(true)
        }, verifyQueue)

        return options
    }

    private static func leafCertificate(from trust: SecTrust) -> SecCertificate? {
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
            return chain.first
        }
        return nil
    }

    /// Helper: extract a bare IP/host string from an endpoint (legacy returns IP only).
    static func ipString(from endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _)? = endpoint else { return nil }
        let raw: String
        switch host {
        case .ipv4(let address): raw = "\(address)"
        case .ipv6(let address): raw = "\(address)"
        case .name(let name, _): raw = name
        @unknown default: return nil
        }
        // Strip a possible IPv6 zone id, e.g. "fe80::1%en0".
        return raw.components(separatedBy: "%").first
    }
}

// MARK: - NWMessageChannel

final class NWMessageChannel: MessageChannel {

    private static let connectionTimeout: TimeInterval = 5.0

    /// How long an *established* connection may stay parked in `.waiting` (path lost) before we
    /// give up and tear it down. NWConnection tries to recover transparently across transient
    /// network changes by entering `.waiting`; the legacy socket stack fails fast instead, and the
    /// rest of the app relies on the channel state flipping to disconnected so keep-alive / reset /
    /// re-publish logic can run. Without this, a `.waiting` connection lingers forever in
    /// `connectedState` and becomes a zombie that blocks all self-healing.
    private static let waitingGracePeriod: TimeInterval = 6.0

    /// Max time `send` blocks waiting for NWConnection to process the bytes. Guards against a
    /// `.waiting`/stuck connection never invoking the `.contentProcessed` completion.
    private static let sendTimeout: TimeInterval = 5.0

    private let queue = DispatchQueue(label: "com.teleport.nwchannel", qos: .userInitiated)
    private var connection: NWConnection?

    /// Guards the scalar properties below. Must NOT be the connection `queue`.
    ///
    /// ⚠️ DO NOT "simplify" these getters back to `queue.sync { _state }`. The NWConnection
    /// state/receive handlers run *on* `queue` and synchronously call delegates (e.g.
    /// `channelDidConnect` → `NetworkConnection.sendAsync` → reads `state`); a `queue.sync`
    /// getter would then re-enter `queue` from within `queue` and deadlock on connect.
    /// Keep state behind this lightweight lock, held only for the trivial get/set (never
    /// across a delegate callback). Regression fixed in commit e9756b0.
    private let stateLock = NSLock()
    private var _state: TPSocketState = .disconnectedState
    private var _noDelay = false
    private var _peerCertificate: SecCertificate?

    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
    private var hasBecomeReady = false
    private var didReportTermination = false
    private var timeoutWorkItem: DispatchWorkItem?
    /// Pending `.waiting` grace timer; non-nil means a countdown to termination is in flight.
    private var waitingWorkItem: DispatchWorkItem?

    /// Buffers inbound data that arrives before a delegate is attached.
    private var pendingInbound = Data()

    /// For accepted channels: notified (instead of `delegate.channelDidConnect`)
    /// once the connection is ready, so the listener can hand it up.
    private var onReady: ((NWMessageChannel) -> Void)?
    private let isAccepted: Bool

    var enableEncryption: Bool = true

    weak var delegate: MessageChannelDelegate? {
        didSet { flushPendingInbound() }
    }

    /// Outbound channel.
    init() {
        self.isAccepted = false
    }

    /// Wrap an inbound `NWConnection` produced by `NWListener`.
    init(acceptedConnection: NWConnection, enableEncryption: Bool, onReady: @escaping (NWMessageChannel) -> Void) {
        self.isAccepted = true
        self.connection = acceptedConnection
        self.enableEncryption = enableEncryption
        self.onReady = onReady
    }

    // MARK: MessageChannel

    var state: TPSocketState { locked { _state } }
    var localAddress: String? { NWTLSConfigurator.ipString(from: connection?.currentPath?.localEndpoint) }
    var remoteAddress: String? {
        if let remote = connection?.currentPath?.remoteEndpoint {
            return NWTLSConfigurator.ipString(from: remote)
        }
        return NWTLSConfigurator.ipString(from: connection?.endpoint)
    }
    var peerCertificate: SecCertificate? { locked { _peerCertificate } }

    func setNoDelay(_ value: Bool) {
        locked { _noDelay = value }
    }

    func activateReceiveCallbacks() {
        // NWConnection delivers inbound data as soon as the delegate is wired.
    }

    @discardableResult
    func connect(toHost host: String, port: Int32) -> Bool {
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else {
            return false
        }

        let params = makeParameters()
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let connection = NWConnection(to: endpoint, using: params)
        self.connection = connection

        locked { _state = .connectingState }
        wireStateHandler(connection)
        startConnectTimeout()
        connection.start(queue: queue)
        infoLog("[NW] connecting to \(host):\(port) encryption=\(enableEncryption)", module: .network)
        return true
    }

    /// Start an accepted connection (called by the listener).
    func startAccepted() {
        guard let connection else { return }
        locked { _state = .connectingState }
        wireStateHandler(connection)
        connection.start(queue: queue)
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        guard let connection, locked({ _state }) == .connectedState else {
            return false
        }
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var success = true
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                resultLock.lock()
                success = false
                resultLock.unlock()
                errorLog("[NW] send failed: \(error)", module: .network)
            }
            semaphore.signal()
        })
        // A `.waiting`/stuck connection may never invoke the completion; don't block forever.
        if semaphore.wait(timeout: .now() + Self.sendTimeout) == .timedOut {
            errorLog("[NW] send timed out after \(Self.sendTimeout)s", module: .network)
            return false
        }
        resultLock.lock()
        defer { resultLock.unlock() }
        return success
    }

    func close() {
        cancelConnectTimeout()
        cancelWaitingTimeout()
        locked { _state = .disconnectedState }
        let conn = connection
        queue.async { conn?.cancel() }
    }

    // MARK: - Internals

    private func makeParameters() -> NWParameters {
        let tcp = NWTLSConfigurator.tcpOptions(noDelay: locked { _noDelay })
        let params: NWParameters
        if enableEncryption {
            let tls = NWTLSConfigurator.tlsOptions(verifyQueue: queue) { [weak self] cert in
                guard let self else { return }
                self.locked { self._peerCertificate = cert }
            }
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.serviceClass = .interactiveVoice
        return params
    }

    private func wireStateHandler(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                self.handleReady()
            case .failed(let error):
                self.handleTermination(error: error)
            case .cancelled:
                self.handleTermination(error: nil)
            case .waiting(let error):
                self.handleWaiting(error: error)
            default:
                break
            }
        }
    }

    private func handleReady() {
        cancelConnectTimeout()
        cancelWaitingTimeout()
        locked { _state = .connectedState }
        hasBecomeReady = true
        infoLog("[NW] connected local=\(localAddress ?? "nil") remote=\(remoteAddress ?? "nil")", module: .network)

        // Notify the owner first (it attaches the real delegate), then start
        // reading so inbound bytes are delivered to the right place.
        if isAccepted {
            onReady?(self)
            onReady = nil
        } else {
            delegate?.channelDidConnect(self)
        }
        startReceiveLoop()
    }

    private func handleWaiting(error: NWError) {
        warningLog("[NW] connection waiting: \(error)", module: .network)
        // Give the path a short window to recover; if it does not, fail fast like the legacy
        // stack so we don't leave a zombie connection stuck in `connectedState`. A subsequent
        // `.ready` cancels this; repeated `.waiting` updates do not extend the window.
        startWaitingTimeout()
    }

    private func startWaitingTimeout() {
        // Already counting down — don't restart, or a flood of `.waiting` updates would push the
        // deadline out indefinitely.
        guard waitingWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.waitingWorkItem = nil
            guard self.locked({ self._state }) != .disconnectedState else { return }
            warningLog("[NW] still waiting after \(Self.waitingGracePeriod)s; terminating connection", module: .network)
            let conn = self.connection
            self.handleTermination(error: nil)
            conn?.cancel()
        }
        waitingWorkItem = work
        queue.asyncAfter(deadline: .now() + Self.waitingGracePeriod, execute: work)
    }

    private func cancelWaitingTimeout() {
        waitingWorkItem?.cancel()
        waitingWorkItem = nil
    }

    private func handleTermination(error: Error?) {
        cancelConnectTimeout()
        cancelWaitingTimeout()
        guard !didReportTermination else { return }
        didReportTermination = true

        let wasReady = hasBecomeReady
        locked { _state = .disconnectedState }

        if let error {
            warningLog("[NW] connection terminated: \(error)", module: .network)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if wasReady {
                self.delegate?.channelDidDisconnect(self)
            } else if !self.isAccepted {
                self.delegate?.channelDidFailToConnect(self)
            }
        }
    }

    private func startReceiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.deliver(data)
            }
            if let error {
                self.handleTermination(error: error)
                return
            }
            if isComplete {
                self.handleTermination(error: nil)
                return
            }
            self.startReceiveLoop()
        }
    }

    private func deliver(_ data: Data) {
        if let delegate {
            delegate.channel(self, didReceiveData: data)
        } else {
            pendingInbound.append(data)
        }
    }

    private func flushPendingInbound() {
        guard let delegate, !pendingInbound.isEmpty else { return }
        let buffered = pendingInbound
        pendingInbound.removeAll()
        delegate.channel(self, didReceiveData: buffered)
    }

    private func startConnectTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.hasBecomeReady {
                warningLog("[NW] connect timeout", module: .network)
                self.handleTermination(error: nil)
                self.connection?.cancel()
            }
        }
        timeoutWorkItem = work
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout, execute: work)
    }

    private func cancelConnectTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }
}

// MARK: - NWMessageListener

final class NWMessageListener: MessageListener {

    private let queue = DispatchQueue(label: "com.teleport.nwlistener", qos: .userInitiated)
    private var listener: NWListener?

    var enableEncryption: Bool = true
    weak var delegate: MessageListenerDelegate?

    @discardableResult
    func start(onPort port: UnsafeMutablePointer<Int32>, tries: Int) -> Bool {
        var candidate = port.pointee
        let attempts = max(1, tries)

        for _ in 0..<attempts {
            if startListener(on: candidate) {
                port.pointee = candidate
                infoLog("[NW] listening on port \(candidate) encryption=\(enableEncryption)", module: .network)
                return true
            }
            candidate += 1
        }
        return false
    }

    func stop() {
        let listener = self.listener
        self.listener = nil
        queue.async { listener?.cancel() }
    }

    private func startListener(on port: Int32) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else { return false }

        let params = makeParameters()
        let selectedIp = TPNetworkConfigurationWatcher.shared.selectedLocalIpAddress
        let bindToSpecificIp = selectedIp != "0.0.0.0" && !selectedIp.isEmpty

        let listener: NWListener
        do {
            if bindToSpecificIp {
                // The port is carried by the required local endpoint; do not also
                // pass `on:` (that would double-specify the port).
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(selectedIp), port: nwPort)
                listener = try NWListener(using: params)
            } else {
                listener = try NWListener(using: params, on: nwPort)
            }
        } catch {
            warningLog("[NW] failed to create listener on \(port): \(error)", module: .network)
            return false
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        // Wait synchronously for the listener to bind (or fail) so port retry works.
        let semaphore = DispatchSemaphore(value: 0)
        var bound = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                bound = true
                semaphore.signal()
            case .failed:
                bound = false
                semaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        if semaphore.wait(timeout: .now() + 2.0) == .timedOut || !bound {
            listener.cancel()
            return false
        }

        self.listener = listener
        return true
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let channel = NWMessageChannel(acceptedConnection: connection,
                                       enableEncryption: enableEncryption) { [weak self] readyChannel in
            guard let self else { return }
            self.delegate?.listener(self, didAcceptChannel: readyChannel)
        }
        channel.startAccepted()
    }

    private func makeParameters() -> NWParameters {
        let tcp = NWTLSConfigurator.tcpOptions(noDelay: true)
        let params: NWParameters
        if enableEncryption {
            // Accepted channels capture their own peer certificate; the listener
            // params only need a local identity + TOFU verify block.
            let tls = NWTLSConfigurator.tlsOptions(verifyQueue: queue) { _ in }
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.allowLocalEndpointReuse = true
        return params
    }
}
