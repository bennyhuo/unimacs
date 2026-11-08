// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import Network
import Security

// MARK: - TLS configuration

private enum NWTLSConfigurator {

    /// Build TCP options for a control or transfer channel.
    static func tcpOptions(noDelay: Bool) -> NWProtocolTCP.Options {
        let options = NWProtocolTCP.Options()
        options.noDelay = noDelay
        options.enableKeepalive = true
        options.keepaliveIdle = 10
        options.keepaliveInterval = 5
        options.keepaliveCount = 3
        return options
    }

    /// Build TLS options replicating the mutual-auth / TOFU behaviour.
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

    /// Extract a bare IPv4/IPv6/host string from an endpoint (stripping any `%ifname` scope suffix).
    static func ipString(from endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _)? = endpoint else { return nil }
        let raw: String
        switch host {
        case .ipv4(let address): raw = "\(address)"
        case .ipv6(let address): raw = "\(address)"
        case .name(let name, _): raw = name
        @unknown default: return nil
        }
        if let percentIndex = raw.firstIndex(of: "%") {
            return String(raw[..<percentIndex])
        }
        return raw
    }
}

// MARK: - NWMessageChannel

final class NWMessageChannel: MessageChannel {

    private static let connectionTimeout: TimeInterval = 5.0

    /// How long an *established* connection may stay parked in `.waiting` (path lost) before we
    /// give up and tear it down.
    private static let waitingGracePeriod: TimeInterval = 6.0

    /// Max time `send` blocks waiting for NWConnection to process the bytes. Guards against a
    /// `.waiting`/stuck connection never invoking the `.contentProcessed` completion.
    private static let sendTimeout: TimeInterval = 5.0

    private let queue = DispatchQueue(label: "com.unimacs.nwchannel", qos: .userInitiated)
    private var connection: NWConnection?

    /// Guards the scalar properties below. Must NOT be the connection `queue`.
    ///
    /// ⚠️ DO NOT "simplify" these getters back to `queue.sync { _state }`. The NWConnection
    /// state/receive handlers run *on* `queue` and synchronously call delegates (e.g.
    /// `channelDidConnect` → `NetworkConnection.sendAsync` → reads `state`); a `queue.sync`
    /// getter would then re-enter `queue` from within `queue` and deadlock on connect.
    /// Keep state behind this lightweight lock, held only for the trivial get/set (never
    /// across a delegate callback).
    private let stateLock = NSLock()
    private var _state: SocketState = .disconnectedState
    private var _noDelay = false
    private var _peerCertificate: SecCertificate?
    private var _lastFailureReason: String?

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

    /// Buffers inbound data that arrives before a delegate is attached. Only accessed on `queue`.
    private var pendingInbound = Data()

    /// For accepted channels: notified (instead of `delegate.channelDidConnect`)
    /// once the connection is ready, so the listener can hand it up.
    private var onReady: ((NWMessageChannel) -> Void)?
    /// Retains `self` while an accepted connection transitions from `.setup` to `.ready`.
    private var acceptedSelfRetain: NWMessageChannel?
    private let isAccepted: Bool

    var enableEncryption: Bool = false

    private weak var _delegate: MessageChannelDelegate?
    var delegate: MessageChannelDelegate? {
        get { locked { _delegate } }
        set {
            locked { _delegate = newValue }
            if newValue != nil {
                queue.async { [weak self] in
                    self?.flushPendingInbound()
                }
            }
        }
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

    var state: SocketState { locked { _state } }
    var localAddress: String? { NWTLSConfigurator.ipString(from: connection?.currentPath?.localEndpoint) }
    var remoteAddress: String? {
        if let remote = connection?.currentPath?.remoteEndpoint {
            return NWTLSConfigurator.ipString(from: remote)
        }
        return NWTLSConfigurator.ipString(from: connection?.endpoint)
    }
    var lastFailureReason: String? { locked { _lastFailureReason } }
    var peerCertificate: SecCertificate? { locked { _peerCertificate } }

    func setNoDelay(_ value: Bool) {
        locked { _noDelay = value }
    }

    func activateReceiveCallbacks() {
        // NWConnection delivers inbound data as soon as the delegate is wired.
    }

    @discardableResult
    func connect(toHost host: String, port: Int32) -> Bool {
        guard !host.isEmpty, port > 0, let nwPort = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else {
            locked { _lastFailureReason = "Invalid host or port (\(host):\(port))" }
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
        acceptedSelfRetain = self
        locked { _state = .connectingState }
        wireStateHandler(connection)
        startConnectTimeout()
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
        let wasReady: Bool = locked {
            _delegate = nil
            let ready = (_state == .connectedState)
            _state = .disconnectedState
            return ready
        }
        let conn = connection
        connection = nil
        queue.async { [weak self] in
            self?.didReportTermination = true
            self?.acceptedSelfRetain = nil
            self?.onReady = nil
            self?.pendingInbound.removeAll()
            guard let conn else { return }
            if wasReady {
                // Send a graceful TCP FIN after any queued payload bytes so the peer sees a clean EOF
                // rather than ECONNRESET when closing right after a transfer completes.
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    conn.cancel()
                })
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                    conn.cancel()
                }
            } else {
                conn.cancel()
            }
        }
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
        if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
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
        guard locked({ _state }) != .disconnectedState else {
            acceptedSelfRetain = nil
            return
        }
        locked { _state = .connectedState }
        hasBecomeReady = true
        infoLog("[NW] connected local=\(localAddress ?? "nil") remote=\(remoteAddress ?? "nil")", module: .network)

        // Notify the owner first (it attaches the real delegate), then start
        // reading so inbound bytes are delivered to the right place.
        if isAccepted {
            let callback = onReady
            onReady = nil
            callback?(self)
            acceptedSelfRetain = nil
        } else {
            delegate?.channelDidConnect(self)
        }
        startReceiveLoop()
    }

    private func handleWaiting(error: NWError) {
        warningLog("[NW] connection waiting: \(error)", module: .network)
        locked {
            if _lastFailureReason == nil {
                _lastFailureReason = "\(error)"
            }
        }
        startWaitingTimeout()
    }

    private func startWaitingTimeout() {
        guard waitingWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.waitingWorkItem = nil
            guard self.locked({ self._state }) != .disconnectedState else { return }
            warningLog("[NW] still waiting after \(Self.waitingGracePeriod)s; terminating connection", module: .network)
            self.locked {
                if self._lastFailureReason == nil {
                    self._lastFailureReason = "Connection timed out while waiting for network path (\(Int(Self.waitingGracePeriod))s)"
                }
            }
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
        acceptedSelfRetain = nil
        onReady = nil

        let wasReady = hasBecomeReady
        let currentDelegate: MessageChannelDelegate? = locked {
            _state = .disconnectedState
            if let error {
                _lastFailureReason = "\(error)"
            }
            return _delegate
        }

        if let error {
            warningLog("[NW] connection terminated: \(error)", module: .network)
        }

        if wasReady {
            currentDelegate?.channelDidDisconnect(self)
        } else if !isAccepted {
            currentDelegate?.channelDidFailToConnect(self)
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
        if let delegate = self.delegate {
            if !pendingInbound.isEmpty {
                var combined = pendingInbound
                pendingInbound.removeAll()
                combined.append(data)
                delegate.channel(self, didReceiveData: combined)
            } else {
                delegate.channel(self, didReceiveData: data)
            }
        } else {
            pendingInbound.append(data)
        }
    }

    private func flushPendingInbound() {
        guard let delegate = self.delegate, !pendingInbound.isEmpty else { return }
        let buffered = pendingInbound
        pendingInbound.removeAll()
        delegate.channel(self, didReceiveData: buffered)
    }

    private func startConnectTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.hasBecomeReady {
                warningLog("[NW] connect timeout", module: .network)
                self.locked {
                    if self._lastFailureReason == nil {
                        self._lastFailureReason = "Connection timed out (\(Int(Self.connectionTimeout))s)"
                    }
                }
                let conn = self.connection
                self.handleTermination(error: nil)
                conn?.cancel()
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

    private let queue = DispatchQueue(label: "com.unimacs.nwlistener", qos: .userInitiated)
    private var listener: NWListener?
    private var cancelSemaphore: DispatchSemaphore?

    var enableEncryption: Bool = false
    weak var delegate: MessageListenerDelegate?

    @discardableResult
    func start(onPort port: UnsafeMutablePointer<Int32>, tries: Int) -> Bool {
        var candidate = port.pointee
        if candidate == 0 {
            if let assigned = startListener(on: 0) {
                port.pointee = assigned
                infoLog("[NW] listening on ephemeral port \(assigned) encryption=\(enableEncryption)", module: .network)
                return true
            }
            return false
        }

        let attempts = max(1, tries)
        for _ in 0..<attempts {
            if let assigned = startListener(on: candidate) {
                port.pointee = assigned
                infoLog("[NW] listening on port \(assigned) encryption=\(enableEncryption)", module: .network)
                return true
            }
            candidate += 1
        }
        return false
    }

    func stop() {
        guard let listener = self.listener else { return }
        self.listener = nil
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            self.cancelSemaphore = sem
            listener.cancel()
        }
        _ = sem.wait(timeout: .now() + 0.5)
    }

    private func startListener(on port: Int32) -> Int32? {
        let nwPort: NWEndpoint.Port
        if port == 0 {
            nwPort = .any
        } else {
            guard port > 0, let validPort = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else {
                return nil
            }
            nwPort = validPort
        }

        let params = makeParameters()
        let selectedIp = NetworkConfigurationWatcher.shared.selectedLocalIpAddress
        let bindToSpecificIp = NetworkUtils.isSpecificBindableIP(selectedIp)

        let listener: NWListener
        do {
            if bindToSpecificIp {
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(selectedIp), port: nwPort)
                listener = try NWListener(using: params)
            } else if port == 0 {
                listener = try NWListener(using: params)
            } else {
                listener = try NWListener(using: params, on: nwPort)
            }
        } catch {
            warningLog("[NW] failed to create listener on \(port): \(error)", module: .network)
            return nil
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        // Wait synchronously for the listener to bind (or fail) so port retry works.
        let semaphore = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var didSignal = false
        var bound = false

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                stateLock.lock()
                if !didSignal {
                    didSignal = true
                    bound = true
                    stateLock.unlock()
                    semaphore.signal()
                } else {
                    stateLock.unlock()
                }
            case .failed:
                stateLock.lock()
                if !didSignal {
                    didSignal = true
                    bound = false
                    stateLock.unlock()
                    semaphore.signal()
                } else {
                    stateLock.unlock()
                }
            case .cancelled:
                stateLock.lock()
                if !didSignal {
                    didSignal = true
                    bound = false
                    stateLock.unlock()
                    semaphore.signal()
                } else {
                    stateLock.unlock()
                }
                self?.cancelSemaphore?.signal()
                self?.cancelSemaphore = nil
            default:
                break
            }
        }
        listener.start(queue: queue)

        if semaphore.wait(timeout: .now() + 2.0) == .timedOut || !bound {
            listener.cancel()
            return nil
        }

        let assignedPort = Int32(listener.port?.rawValue ?? UInt16(truncatingIfNeeded: port))
        self.listener = listener
        return assignedPort
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
            let tls = NWTLSConfigurator.tlsOptions(verifyQueue: queue) { _ in }
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        return params
    }
}
