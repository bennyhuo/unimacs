// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

private let trustedHostsVersion = 2
private let trustedHostsVersionKey = "UMTrustedHostsVersion"
private let trustedHostsKey = "UMTrustedHosts"

class AuthenticationManager: NSObject, ClientConnectionsDelegate, NetworkConnectionDelegate {
    
    static let `default` = AuthenticationManager()
    
    private var _trustedHosts: [RemoteHost] = []
    private var currentConnection: NetworkConnection?
    
    var trustedHosts: [RemoteHost] {
        return _trustedHosts
    }
    
    private override init() {
        super.init()
    }
    
    // MARK: - Loading/Saving
    
    func loadHosts() {
        let prefsManager = PreferencesManager.shared()
        
        // Do not load hosts from an earlier version
        guard prefsManager.int(forPref: trustedHostsVersionKey) == trustedHostsVersion else {
            return
        }
        
        guard let archivedData = prefsManager.value(forPref: trustedHostsKey) as? Data else {
            return
        }

		if let hosts = LegacyKeyedArchiver.unarchive(data: archivedData) as? [RemoteHost] {
			_trustedHosts.append(contentsOf: hosts)
		}
    }
    
    func saveHosts() {
        let prefsManager = PreferencesManager.shared()
		let archivedData = LegacyKeyedArchiver.archive(value: _trustedHosts)
		prefsManager.setValue(archivedData, forKey: trustedHostsKey)
		prefsManager.setValue(trustedHostsVersion, forKey: trustedHostsVersionKey)
    }
    
    // MARK: - Authentication requests - client side
    
    @objc func requestAuthentication(on host: RemoteHost) -> Bool {
        return ConnectionsManager.shared.connect(toHost: host, withDelegate: self, infoDict: nil)
    }
    
    @objc func connectionToServerSucceeded(_ connection: NetworkConnection, infoDict: [String: Any]?) {
        currentConnection = connection
        currentConnection?.delegate = self
        // Fire and forget - auth request
        currentConnection?.sendAsync(Message.create(with: .authenticationRequest))
    }
    
    @objc func connectionToServerFailed(_ host: RemoteHost, infoDict: [String: Any]?) {
        host.hostState = .shared
        let rawReason = infoDict?["failureReason"] as? String
        
        DispatchQueue.main.async {
            let diagnosis = ConnectionFailureDiagnoser.diagnose(
                rawReason: rawReason,
                hostId: host.identifier,
                hostName: host.computerName,
                targetAddress: host.address,
                targetPort: host.port,
                localInterfaces: NetworkUtils.activeIPv4Interfaces(onlySupported: true),
                selectedLocalIP: NetworkConfigurationWatcher.shared.selectedLocalIpAddress,
                isBonjourOnline: host.isInState(.online)
            )
            host.lastError = diagnosis.shortReason
            ActivityLogManager.shared.log(
                level: .error,
                category: .connection,
                title: "Pairing connection to \(host.computerName) failed — \(diagnosis.shortReason)",
                detail: diagnosis.whyFailed,
                howToFix: diagnosis.howToFix,
                hostId: host.identifier,
                hostName: host.computerName,
                actions: diagnosis.actions
            )
        }
    }
    
    @objc func connectionDisconnected(_ connection: NetworkConnection) {
        // Handle disconnection - clear current connection if it matches
        if currentConnection === connection {
            currentConnection = nil
        }
    }    
    @objc func connection(_ connection: NetworkConnection, receivedMessage message: Message) {
        let type = message.msgType
        guard let host = connection.connectedHost else { return }
        
        #if DEBUG_GENERAL
        debugLog("authentication manager receive msg \(type.rawValue)", module: .general)
        #endif
        
        switch type {
        case .authenticationInProgress:
            break
            
        case .authenticationSuccess:
            let authConnection = connection
            currentConnection = nil
            Task { @MainActor in
                self.host(host, setTrusted: true)
                DeviceConnectionManager.shared.adoptConnection(authConnection)
                host.hostState = .peeredOnline
                ActivityLogManager.shared.log(
                    level: .success,
                    category: .control,
                    title: "Paired with \(host.computerName)",
                    detail: "\(host.computerName) accepted the pairing request and is now a trusted Mac.",
                    hostId: host.identifier,
                    hostName: host.computerName
                )
            }
            
        case .authenticationFailure:
            let explanation = message.infoDict["reason"] as? String ?? NSLocalizedString("The computer you tried to control rejected your request. You should try on a computer you own.", comment: "")
            
            host.hostState = .shared
            
            Task { @MainActor in
                host.lastError = explanation
                ActivityLogManager.shared.log(
                    level: .error,
                    category: .control,
                    title: "Pairing request rejected by \(host.computerName)",
                    detail: explanation,
                    howToFix: "Ensure 'Allow this Mac to be controlled' is enabled on \(host.computerName), then click Pair again and accept the prompt on \(host.computerName).",
                    hostId: host.identifier,
                    hostName: host.computerName
                )
            }
            
            currentConnection?.disconnect()
            currentConnection = nil
            
        case .transferRequest:
            TransfersManager.shared.receiveTransferRequest(withInfoDict: message.infoDict, on: connection, isClient: false)
            
        case .transferSuccess:
            if let uid = message.infoDict[TransferKeys.uid] as? String,
               let port = message.infoDict[TransferKeys.port] as? Int {
                TransfersManager.shared.startTransfer(withUID: uid, using: connection, onPort: Int32(port))
            }
            
        case .transferFailure:
			TransfersManager.shared.abortTransfer(withUID: message.string)

        case .unpairNotification, .disconnectNotification:
            Task { @MainActor in
                DeviceConnectionManager.shared.handlePeerLifecycleMessage(message, on: connection)
            }
            
        default:
            warningLog("[Handshake] Forwarding non-authentication message type=\(type.rawValue) to DeviceConnectionManager", module: .network)
            Task { @MainActor in
                DeviceConnectionManager.shared.connection(connection, receivedMessage: message)
            }
        }
    }
    
    @objc func abortAuthenticationRequest() {
        // Fire and forget - abort message
        currentConnection?.sendAsync(Message.create(with: .authenticationAbort))
    }
    
    // MARK: - Authentication requests - server side
    
    @objc func authenticationRequested(from host: RemoteHost, on connection: NetworkConnection) {
        if isHostTrusted(host) {
            if LocalHost.shared.hasCustomBackgroundImage {
                TransfersManager.shared.beginTransfer(OutgoingBackgroundImageTransfer.shared(), using: connection)
            }
            connection.sendAsync(Message.create(with: .authenticationSuccess))
        } else {
            let trustRequestBehavior = Int32(PreferencesManager.shared().int(forPref: TRUST_REQUEST_BEHAVIOR))
            
            switch trustRequestBehavior {
            case Int32(TRUST_REQUEST_REJECT):
                let infoDict = ["reason": NSLocalizedString("Host not accepting any more trusted hosts.", comment: "Reason for trust failure")]
                // Fire and forget - failure response
                connection.sendAsync(Message.create(with: .authenticationFailure, andInfoDict: infoDict))
                debugLog("Rejecting authentication: no more authentication", module: .general)
                
            case Int32(TRUST_REQUEST_ACCEPT):
                self.host(host, setTrusted: true)
                if LocalHost.shared.hasCustomBackgroundImage {
                    TransfersManager.shared.beginTransfer(OutgoingBackgroundImageTransfer.shared(), using: connection)
                }
                // Fire and forget - success response
                connection.sendAsync(Message.create(with: .authenticationSuccess))
                
            default: // TRUST_REQUEST_ASK
                // Fire and forget - in progress response
                connection.sendAsync(Message.create(with: .authenticationInProgress))
                
				Task { @MainActor in
					let authenticationRequest = AuthenticationRequest(networkConnection: connection, demandingHost: host)
					let result = authenticationRequest.ask()
					reply(to: authenticationRequest, with: result)
				}
                
                connection.delegate = self
            }
        }
    }
    
    @MainActor
    @objc func reply(to authRequest: AuthenticationRequest, with result: AuthenticationResult) {
        let connection = authRequest.connection
        defer {
            DeviceConnectionManager.shared.restorePersistentDelegate(for: connection)
        }

        switch result {
        case .acceptedAndRejectOthers:
            PreferencesManager.shared().setValue(TRUST_REQUEST_REJECT, forKey: TRUST_REQUEST_BEHAVIOR)
            fallthrough
            
        case .accepted:
            let host = authRequest.demandingHost
            debugLog("authentication request from host \(String(describing: host)) accepted", module: .general)
            
            self.host(host, setTrusted: true)
            ActivityLogManager.shared.log(
                level: .success,
                category: .control,
                title: "Accepted pairing request from \(host.computerName)",
                detail: "\(host.computerName) is now a trusted Mac and can share mouse and keyboard control.",
                hostId: host.identifier,
                hostName: host.computerName
            )
            
            let connection = authRequest.connection
            if LocalHost.shared.hasCustomBackgroundImage {
                TransfersManager.shared.beginTransfer(OutgoingBackgroundImageTransfer.shared(), using: connection)
            }
            // Fire and forget - success response
            connection.sendAsync(Message.create(with: .authenticationSuccess))
            
        case .rejected:
            let host = authRequest.demandingHost
            let infoDict = ["reason": NSLocalizedString("User rejected your trust request.", comment: "Reason for trust failure")]
            // Fire and forget - failure response
            authRequest.connection.sendAsync(Message.create(with: .authenticationFailure, andInfoDict: infoDict))
            debugLog("Rejecting authentication: user decision", module: .general)
            ActivityLogManager.shared.log(
                level: .warning,
                category: .control,
                title: "Rejected pairing request from \(host.computerName)",
                detail: "You declined the incoming pairing prompt from \(host.computerName).",
                hostId: host.identifier,
                hostName: host.computerName
            )
            
        case .aborted:
            debugLog("Authentication aborted", module: .general)
            
        @unknown default:
            break
        }
    }
    
    // MARK: - Trusted hosts
    
    func getTrustedHosts() -> [RemoteHost] {
        return _trustedHosts
    }
    
    func host(_ remoteHost: RemoteHost, setTrusted trusted: Bool) {
        _trustedHosts.removeAll { $0 == remoteHost }
        
        if trusted {
            _trustedHosts.append(remoteHost)
            
            // In symmetric layout sync, a trusted remote host is also a peered host
            // that should be registered persistently in HostDevicesManager._hosts.
            Task { @MainActor in
                let online = DeviceConnectionManager.shared.isConnected(to: remoteHost)
                remoteHost.hostState = online ? .peeredOnline : .peeredOffline
                HostDevicesManager.shared.addTrustedHostToHosts(remoteHost)
            }
        } else {
            Task { @MainActor in
                HostDevicesManager.shared.removeTrustedHostFromHosts(remoteHost)
            }
        }
        
        saveHosts()
    }
    
    @objc func isHostTrusted(_ remoteHost: RemoteHost) -> Bool {
        _trustedHosts.contains { $0 == remoteHost }
    }
}
