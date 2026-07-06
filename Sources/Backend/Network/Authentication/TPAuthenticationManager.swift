// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

private let trustedHostsVersion = 2
private let trustedHostsVersionKey = "TPTrustedHostsVersion"
private let trustedHostsKey = "TPTrustedHosts"

@objc class TPAuthenticationManager: NSObject, TPClientConnectionsDelegate, NetworkConnectionDelegate {
    
    @objc static let `default` = TPAuthenticationManager()
    
    // Legacy ObjC compatibility
    @objc class func defaultManager() -> TPAuthenticationManager {
        return Self.default
    }
    
    private var _trustedHosts: [TPRemoteHost] = []
    private var currentConnection: NetworkConnection?
    
    // Public ObjC-compatible property
    @objc var trustedHosts: [TPRemoteHost] {
        return _trustedHosts
    }
    
    private override init() {
        super.init()
    }
    
    // MARK: - Loading/Saving
    
    @objc func loadHosts() {
        let prefsManager = TPPreferencesManager.shared()
        
        // Do not load hosts from an earlier version
        guard prefsManager.int(forPref: trustedHostsVersionKey) == trustedHostsVersion else {
            return
        }
        
        guard let archivedData = prefsManager.value(forPref: trustedHostsKey) as? Data else {
            return
        }

		if let hosts = LegacyKeyedArchiver.unarchive(data: archivedData) as? [TPRemoteHost] {
			_trustedHosts.append(contentsOf: hosts)
		}
    }
    
    @objc func saveHosts() {
        let prefsManager = TPPreferencesManager.shared()
		let archivedData = LegacyKeyedArchiver.archive(value: _trustedHosts)
		prefsManager.setValue(archivedData, forKey: trustedHostsKey)
		prefsManager.setValue(trustedHostsVersion, forKey: trustedHostsVersionKey)
    }
    
    // MARK: - Authentication requests - client side
    
    @objc func requestAuthentication(on host: TPRemoteHost) -> Bool {
        return TPConnectionsManager.shared.connect(toHost: host, withDelegate: self, infoDict: nil)
    }
    
    @objc func connectionToServerSucceeded(_ connection: NetworkConnection, infoDict: [String: Any]?) {
        currentConnection = connection
        currentConnection?.delegate = self
        // Fire and forget - auth request
        currentConnection?.sendAsync(TPMessage.create(with: .authenticationRequest))
    }
    
    @objc func connectionToServerFailed(_ host: TPRemoteHost, infoDict: [String: Any]?) {
        host.hostState = .shared
        
        DispatchQueue.main.async {
			let msgTitle = String(format: NSLocalizedString("Connection to \u{201C}%@\u{201D} failed.", comment: "Title for connection failure"), host.computerName)
			let alert = NSAlert()
			alert.messageText = msgTitle
			alert.informativeText = NSLocalizedString("The server may be down, or a network problem may have occurred.", comment: "")
			alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
			
            TPMainController.shared().present(alert)
        }
    }
    
    @objc func connectionDisconnected(_ connection: NetworkConnection) {
        // Handle disconnection - clear current connection if it matches
        if currentConnection === connection {
            currentConnection = nil
        }
    }    
    @objc func connection(_ connection: NetworkConnection, receivedMessage message: TPMessage) {
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
            }
            
        case .authenticationFailure:
            let msgTitle = String(format: NSLocalizedString("The host \u{201C}%@\u{201D} rejected your trust request.", comment: "Title for trust failure"), host.computerName ?? "")
			let explanation = message.infoDict["reason"] as? String ?? NSLocalizedString("The computer you tried to control rejected your request. You should try on a computer you own.", comment: "")
            
            host.hostState = .shared
            
			Task { @MainActor in
				let alert = NSAlert()
				alert.messageText = msgTitle
				alert.informativeText = explanation
				alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
				_ = TPMainController.shared().present(alert)
			}
            
            currentConnection?.disconnect()
            currentConnection = nil
            
        case .transferRequest:
            TPTransfersManager.shared.receiveTransferRequest(withInfoDict: message.infoDict, on: connection, isClient: false)
            
        case .transferSuccess:
            if let uid = message.infoDict[TPTransferKeys.uid] as? String,
               let port = message.infoDict[TPTransferKeys.port] as? Int {
                TPTransfersManager.shared.startTransfer(withUID: uid, using: connection, onPort: Int32(port))
            }
            
        case .transferFailure:
			TPTransfersManager.shared.abortTransfer(withUID: message.string)

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
        currentConnection?.sendAsync(TPMessage.create(with: .authenticationAbort))
    }
    
    // MARK: - Authentication requests - server side
    
    @objc func authenticationRequested(from host: TPRemoteHost, on connection: NetworkConnection) {
        if isHostTrusted(host) {
            if TPLocalHost.shared.hasCustomBackgroundImage {
                TPTransfersManager.shared.beginTransfer(TPOutgoingBackgroundImageTransfer.shared(), using: connection)
            }
            connection.sendAsync(TPMessage.create(with: .authenticationSuccess))
        } else {
            let trustRequestBehavior = Int32(TPPreferencesManager.shared().int(forPref: TRUST_REQUEST_BEHAVIOR))
            
            switch trustRequestBehavior {
            case Int32(TRUST_REQUEST_REJECT):
                let infoDict = ["reason": NSLocalizedString("Host not accepting any more trusted hosts.", comment: "Reason for trust failure")]
                // Fire and forget - failure response
                connection.sendAsync(TPMessage.create(with: .authenticationFailure, andInfoDict: infoDict))
                debugLog("Rejecting authentication: no more authentication", module: .general)
                
            case Int32(TRUST_REQUEST_ACCEPT):
                self.host(host, setTrusted: true)
                if TPLocalHost.shared.hasCustomBackgroundImage {
                    TPTransfersManager.shared.beginTransfer(TPOutgoingBackgroundImageTransfer.shared(), using: connection)
                }
                // Fire and forget - success response
                connection.sendAsync(TPMessage.create(with: .authenticationSuccess))
                
            default: // TRUST_REQUEST_ASK
                // Fire and forget - in progress response
                connection.sendAsync(TPMessage.create(with: .authenticationInProgress))
                
				Task { @MainActor in
					let authenticationRequest = TPAuthenticationRequest(networkConnection: connection, demandingHost: host)
					let result = authenticationRequest.ask()
					reply(to: authenticationRequest, with: result)
				}
                
                connection.delegate = self
            }
        }
    }
    
    @MainActor
    @objc func reply(to authRequest: TPAuthenticationRequest, with result: TPAuthenticationResult) {
        let connection = authRequest.connection
        defer {
            DeviceConnectionManager.shared.restorePersistentDelegate(for: connection)
        }

        switch result {
        case .acceptedAndRejectOthers:
            TPPreferencesManager.shared().setValue(TRUST_REQUEST_REJECT, forKey: TRUST_REQUEST_BEHAVIOR)
            fallthrough
            
        case .accepted:
            let host = authRequest.demandingHost
            debugLog("authentication request from host \(String(describing: host)) accepted", module: .general)
            
            self.host(host, setTrusted: true)
            
            let connection = authRequest.connection
            if TPLocalHost.shared.hasCustomBackgroundImage {
                TPTransfersManager.shared.beginTransfer(TPOutgoingBackgroundImageTransfer.shared(), using: connection)
            }
            // Fire and forget - success response
            connection.sendAsync(TPMessage.create(with: .authenticationSuccess))
            
        case .rejected:
            let infoDict = ["reason": NSLocalizedString("User rejected your trust request.", comment: "Reason for trust failure")]
            // Fire and forget - failure response
            authRequest.connection.sendAsync(TPMessage.create(with: .authenticationFailure, andInfoDict: infoDict))
            debugLog("Rejecting authentication: user decision", module: .general)
            
        case .aborted:
            debugLog("Authentication aborted", module: .general)
            
        @unknown default:
            break
        }
    }
    
    // MARK: - Trusted hosts
    
    @objc func getTrustedHosts() -> [TPRemoteHost] {
        return _trustedHosts
    }
    
    @objc(host:setTrusted:)
    func host(_ remoteHost: TPRemoteHost, setTrusted trusted: Bool) {
        _trustedHosts.removeAll { $0 == remoteHost }
        
        if trusted {
            _trustedHosts.append(remoteHost)
            
            // In symmetric layout sync, a trusted remote host is also a peered host
            // that should be registered persistently in TPHostsManager._hosts.
            Task { @MainActor in
                let online = DeviceConnectionManager.shared.isConnected(to: remoteHost)
                remoteHost.hostState = online ? .peeredOnline : .peeredOffline
                TPHostsManager.shared.addTrustedHostToHosts(remoteHost)
            }
        } else {
            Task { @MainActor in
                TPHostsManager.shared.removeTrustedHostFromHosts(remoteHost)
            }
        }
        
        saveHosts()
    }
    
    @objc func isHostTrusted(_ remoteHost: TPRemoteHost) -> Bool {
        _trustedHosts.contains { $0 == remoteHost }
    }
}
