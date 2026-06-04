// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import AppKit

let DISCONNECT_WHEN_STOP_CONTROL = false

@MainActor
@objcMembers
class TPConnectionController: NSObject, TPHotBorderDelegate, NetworkConnectionDelegate {
	
    @IBOutlet weak var delegate: AnyObject?
    
    private var _currentConnection: NetworkConnection?
    private var _eventsController: TPEventsController?
    
    var currentConnection: NetworkConnection? {
        get {
            return _currentConnection
        }
        set {
            let oldConnId = _currentConnection?.connectionId ?? "nil"
            let oldHost = _currentConnection?.connectedHost?.computerName ?? "nil"
            let newConnId = newValue?.connectionId ?? "nil"
            let newHost = newValue?.connectedHost?.computerName ?? "nil"
            let isSameRef = _currentConnection === newValue
            
            debugLog("currentConnection setter: old=[\(oldConnId), \(oldHost)], new=[\(newConnId), \(newHost)], isSameRef=\(isSameRef)", module: .control)
            
            if _currentConnection !== newValue {
                warningLog("currentConnection setter: reference changed, will disconnect old connection", module: .control)
				TPTransfersManager.shared.abortAllTransferRequests()
                _currentConnection?.disconnect()
                
                _currentConnection = newValue
                // Note: delegate is managed by DeviceConnectionManager
                // Messages are routed via DeviceConnectionDelegate.handleMessage
            }
        }
    }
    
    var eventsController: TPEventsController? {
        return _eventsController
    }
    
	func currentHotBorder() -> TPHotBorder? {
        return nil
    }

    override init() {
        super.init()
        _currentConnection = nil
		SoundUtils.preheatSwitchSoundIfNeeded()
		TPLocalHost.shared.observe(observer: self, selector: #selector(_localHostDidChange(_:)))
    }
    
    func updateEventsController() {
        if let connection = _currentConnection {
			let eventsController = TPEventsController.instance(for: connection.connectedHost);
            if _eventsController != eventsController {
                _eventsController = eventsController
            }
        } else {
            _eventsController = nil
        }
    }

    func setupHotBorder(_ hotBorder: TPHotBorder, forHost host: TPRemoteHost) {
        // Hot border setup - no longer needs drag configuration
    }

    func takeDownHotBorder(_ hotBorder: TPHotBorder) {
        // No-op: hot border cleanup handled elsewhere
    }

    func hotBorder(_ hotBorder: TPHotBorder, firedAtLocation location: NSPoint) -> Bool {
        return false
    }
	
	func hotBorder(_ hotBorder: TPHotBorder, canFireWithEvent event: NSEvent?) -> Bool {
		return false
	}

    func stopControl() {
        stopControl(withDisconnect: true)
    }

    func stopControl(withDisconnect disconnect: Bool) {
        if disconnect {
            currentConnection = nil
        }
    }

    func optionForRemoteHost(_ remoteHost: TPRemoteHost?, key: String) -> Any? {
        return remoteHost?.options.value(forKey: key)
    }

    @objc private func _localHostDidChange(_ notification: Notification) {
        let currentCaps = _currentConnection?.localHostCapabilities
        let newCaps = TPLocalHost.shared.capabilities
        let hasConnection = _currentConnection != nil
        let capsChanged = currentCaps != newCaps
        
        debugLog("localHostDidChange: hasConnection=\(hasConnection), capsChanged=\(capsChanged), currentCaps=\(String(describing: currentCaps)), newCaps=\(newCaps)", module: .control)
        
        if hasConnection && capsChanged {
            warningLog("localHostDidChange: capabilities changed, stopping control", module: .control)
            stopControl()
        }
    }

	func connection(_ connection: NetworkConnection, receivedMessage message: TPMessage) {
		let type = message.msgType
        
        switch type {
		case .transferRequest:
			TPTransfersManager.shared.receiveTransferRequest(withInfoDict: message.infoDict, on: connection, isClient: self is TPClientController)
		case .transferSuccess:
			if let startInfo = TPTransferStartInfo(infoDict: message.infoDict) {
				TPTransfersManager.shared.startTransfer(withUID: startInfo.uid, using: connection, onPort: startInfo.port)
			}
		case .transferFailure:
			TPTransfersManager.shared.abortTransfer(withUID: message.string)
        default:
            break
        }
    }

	func connectionDisconnected(_ connection: NetworkConnection) {
		warningLog("connectionDisconnected: connId=\(connection.connectionId), host=\(connection.connectedHost?.computerName ?? "nil")", module: .control)
		stopControl()
    }
}
