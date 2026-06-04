// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

@objc enum TPAuthenticationResult: Int {
    case accepted
    case rejected
    case acceptedAndRejectOthers
    case aborted
}

@objc class TPAuthenticationRequest: NSObject, NetworkConnectionDelegate {
    
    private let _connection: NetworkConnection
    private let _demandingHost: TPRemoteHost
    
    @objc var connection: NetworkConnection {
        return _connection
    }
    
    @objc var demandingHost: TPRemoteHost {
        return _demandingHost
    }
    
    @objc init(networkConnection connection: NetworkConnection, demandingHost: TPRemoteHost) {
        self._connection = connection
        self._demandingHost = demandingHost
        super.init()
        
        _connection.delegate = self
    }
    
    @MainActor @objc func ask() -> TPAuthenticationResult {
        let msgString: String
        let textString: String
        
        if TPLocalHost.shared.pairWith(host: _demandingHost, hasCapability: .encryption) {
            msgString = String(format: NSLocalizedString("Trust request from certified host \u{201C}%@\u{201D}.", comment: "teleport trust request title - certified version"), _demandingHost.computerName)
            textString = NSLocalizedString("This will allow the demanding host to take control of your mouse and keyword. All keystrokes and transfers will be encrypted with this host.\nIf you didn't request the control, you should Reject it.", comment: "")
        } else {
            msgString = String(format: NSLocalizedString("Trust request from uncertified host \u{201C}%@\u{201D}.", comment: "teleport trust request title - uncertified version"), _demandingHost.computerName)
            textString = NSLocalizedString("This will allow the demanding host to take control of your mouse and keyword. Warning: the keystrokes and transfers will be sent clear on your network. You should enable encryption on both Macs to encrypt these.\nIf you didn't request the control, you should Reject it.", comment: "")
        }
        
        let authenticationAlert = NSAlert()
        authenticationAlert.messageText = msgString
        authenticationAlert.informativeText = textString
        authenticationAlert.addButton(withTitle: NSLocalizedString("Accept", comment: ""))
        authenticationAlert.addButton(withTitle: NSLocalizedString("Reject", comment: ""))
        authenticationAlert.addButton(withTitle: NSLocalizedString("Accept and Reject Others", comment: ""))
        
        let result = (NSApp.delegate as! TPMainController).present(authenticationAlert)
        
        switch result {
        case NSApplication.ModalResponse.alertFirstButtonReturn:
            return .accepted
        case NSApplication.ModalResponse.alertSecondButtonReturn:
            return .rejected
        case NSApplication.ModalResponse.alertThirdButtonReturn:
            return .acceptedAndRejectOthers
        case NSApplication.ModalResponse.abort:
            return .aborted
        default:
            return .rejected
        }
    }
    
    // MARK: - NetworkConnectionDelegate
    
    @objc func connection(_ connection: NetworkConnection, receivedMessage message: TPMessage) {
        let type = message.msgType
        
        switch type {
        case .authenticationAbort:
            NSApp.abortModal()
        default:
            break
        }
    }
    
    @objc func connectionDisconnected(_ connection: NetworkConnection) {
        NSApp.abortModal()
    }
}
