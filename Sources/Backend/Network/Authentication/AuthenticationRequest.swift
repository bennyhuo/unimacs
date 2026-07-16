// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

@objc enum AuthenticationResult: Int {
    case accepted
    case rejected
    case acceptedAndRejectOthers
    case aborted
}

@objc class AuthenticationRequest: NSObject, NetworkConnectionDelegate {
    
    private let _connection: NetworkConnection
    private let _demandingHost: RemoteHost
    
    @objc var connection: NetworkConnection {
        return _connection
    }
    
    @objc var demandingHost: RemoteHost {
        return _demandingHost
    }
    
    @objc init(networkConnection connection: NetworkConnection, demandingHost: RemoteHost) {
        self._connection = connection
        self._demandingHost = demandingHost
        super.init()
        
        _connection.delegate = self
    }
    
    @MainActor @objc func ask() -> AuthenticationResult {
        let msgString = String(format: NSLocalizedString("Trust request from host \u{201C}%@\u{201D}.", comment: "Unimacs trust request title"), _demandingHost.computerName)
        let textString = NSLocalizedString("This will allow the demanding host to take control of your mouse and keyboard.\nIf you didn't request the control, you should Reject it.", comment: "")
        
        let authenticationAlert = NSAlert()
        authenticationAlert.messageText = msgString
        authenticationAlert.informativeText = textString
        authenticationAlert.addButton(withTitle: NSLocalizedString("Accept", comment: ""))
        authenticationAlert.addButton(withTitle: NSLocalizedString("Reject", comment: ""))
        authenticationAlert.addButton(withTitle: NSLocalizedString("Accept and Reject Others", comment: ""))
        
        let result = MainController.shared().present(authenticationAlert)
        
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
    
    @objc func connection(_ connection: NetworkConnection, receivedMessage message: Message) {
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
