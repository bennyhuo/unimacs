// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

private struct TransferRequest {
	let transfer: IncomingTransfer
	let infoDict: [AnyHashable: Any]
	let connection: NetworkConnection
}

func TransferDebugLog(
	_ messages: Any...,
	file: String = #file,
	function: String = #function,
	line: Int = #line
) {
	debugLog(messages, module: .transfer, file: file, function: function, line: line)
}

@objc
protocol TransfersManagerDelegate: NSObjectProtocol {
    func transfersManager(_ transfersManager: TransfersManager, beginNewTransfer transfer: Transfer)
    func transfersManager(_ transfersManager: TransfersManager, transfer: Transfer, didProgress progress: Float)
    func transfersManager(_ transfersManager: TransfersManager, completeTransfer transfer: Transfer)
    func transfersManager(_ transfersManager: TransfersManager, cancelTransfer transfer: Transfer)
}

@objcMembers
class TransfersManager: NSObject {
    
    private var _outgoingTransfers: [String: OutgoingTransfer] = [:]
    private var _incomingTransfers: [String: IncomingTransfer] = [:]
    private var _outgoingConnections: [String: NetworkConnection] = [:]
    private var _transferRequests: [TransferRequest] = []
    
    private var _requestInProcess: Bool = false
    private var _lastTransferWasCancelled: Bool = false
    
    private weak var _delegate: AnyObject?
	
	static let shared = TransfersManager()
   
    override init() {
        super.init()
        _outgoingTransfers = [:]
        _incomingTransfers = [:]
        _outgoingConnections = [:]
        _transferRequests = []
        _lastTransferWasCancelled = false
        _requestInProcess = false
    }
    
    func setDelegate(_ delegate: AnyObject?) {
        _delegate = delegate
    }
    
    func beginTransfer(_ transfer: OutgoingTransfer, using connection: NetworkConnection) {
        _lastTransferWasCancelled = false

		transfer.manager = self
		transfer.remoteHost = connection.connectedHost
		// Register synchronously so an early `transferSuccess` can still find the transfer.
		_outgoingTransfers[transfer.uid] = transfer
		_outgoingConnections[transfer.uid] = connection

		// Serializing the payload (e.g. a large pasteboard image via NSKeyedArchiver) can be
		// expensive. Never run it on the main thread or it freezes input/UI while a control
		// session is starting or stopping. This restores the pre-persistent-connection behavior
		// where transfer setup happened off the main run loop.
		DispatchQueue.global(qos: .userInitiated).async {
			let transferIsOK = transfer.prepareToSendData()
			DispatchQueue.main.async {
				// Bail if the transfer was cancelled/aborted while we were serializing.
				guard self._outgoingTransfers[transfer.uid] != nil else { return }

				if !transferIsOK {
					self.transferDidCancel(transfer)
					return
				}

				let message = Message.create(with: .transferRequest, andInfoDict: transfer.infoDict())

				// Use async send, but handle failure via callback
				Task {
					let success = await connection.sendMessageAsync(message)
					if !success {
						await MainActor.run {
							self.transferDidCancel(transfer)
						}
					}
				}
			}
		}
    }
    
    func startTransfer(withUID transferUID: String, using connection: NetworkConnection, onPort port: Int32) {
        let transfer = _outgoingTransfers[transferUID]
        
        if let transfer = transfer {
            if let delegate = _delegate as? TransfersManagerDelegate {
                delegate.transfersManager(self, beginNewTransfer: transfer)
            }
            
			if let host = connection.connectedHost, let address = host.address {
				let channel = MessageTransportFactory.makeChannel()
				channel.setNoDelay(false)
				transfer.setChannel(channel)
				if !channel.connect(toHost: address, port: port) {
					transfer._senderDataTransferFailed()
				}
			}
        }
    }
    
    func abortTransfer(withUID transferUID: String) {
        _outgoingConnections.removeValue(forKey: transferUID)
        _outgoingTransfers.removeValue(forKey: transferUID)
        _incomingTransfers.removeValue(forKey: transferUID)
    }
    
    func cancelTransfer(withUID transferUID: String) {
        if let transfer = _outgoingTransfers[transferUID] {
            transfer._transferDone()
            transferDidCancel(transfer)
        } else if let transfer = _incomingTransfers[transferUID] {
            transfer._transferDone()
            transferDidCancel(transfer)
        }
    }
    
    func receiveTransferRequest(withInfoDict infoDict: [AnyHashable: Any], on connection: NetworkConnection, isClient: Bool) {
		guard let requestInfo = TransferRequestInfo(infoDict: infoDict) else {
			warningLog("Invalid transfer request", module: .transfer)
			return
		}
        
		let transfer = IncomingTransfer.instance(withType: requestInfo.type, uid: requestInfo.uid)
        
        if let transfer = transfer, let connectedHost = connection.connectedHost {
            if !isClient && transfer.requireTrustedHost && !AuthenticationManager.default.isHostTrusted(connectedHost) {
                // Fire and forget - failure response
                connection.sendAsync(Message.create(with: .transferFailure, andString: transfer.uid))
            } else {
				let transferRequest = TransferRequest(
					transfer: transfer,
					infoDict: infoDict,
					connection: connection
				)
				_transferRequests.append(transferRequest)
                _processNextTransferRequestIfPossible()
            }
        }
    }
    
    func abortAllTransferRequests() {
        for transferRequest in _transferRequests {
			self.abortTransfer(withUID: transferRequest.transfer.uid)
        }
        
        _transferRequests.removeAll()
        _requestInProcess = false
    }
    
    private func _processNextTransferRequestIfPossible() {
        if _transferRequests.isEmpty || _requestInProcess {
            return
        }
        
        _requestInProcess = true
        
        let transferRequest = _transferRequests[0]
        let transfer = transferRequest.transfer
        let infoDict = transferRequest.infoDict
        let connection = transferRequest.connection
        let host = connection.connectedHost!
		transfer.remoteHost = host
        var port = PreferencesManager.shared().port(forPref: TRANSFER_PORT)
        
		if transfer.prepareToReceiveData(withInfoDict: infoDict, from: host, onPort: &port, delegate: connection.delegate as Any) {
            if let delegate = _delegate as? TransfersManagerDelegate {
                delegate.transfersManager(self, beginNewTransfer: transfer)
            }
            
            transfer.manager = self
			_incomingTransfers[transfer.uid] = transfer
            
            // Use async send and handle result
            Task {
                let sent = await connection.sendMessageAsync(Message.create(with: .transferSuccess, andInfoDict: TransferStartInfo(uid: transfer.uid, port: port).infoDict))
                
                if !sent {
                    await MainActor.run {
                        self._requestInProcess = false
                        self._processNextTransferRequestIfPossible()
                    }
                }
            }
        } else {
            // Fire and forget - failure response
            connection.sendAsync(Message.create(with: .transferFailure, andString: transfer.uid))
            _requestInProcess = false
            _processNextTransferRequestIfPossible()
        }
    }
    
    private func _removeTransfer(_ transfer: Transfer) {
		_outgoingTransfers.removeValue(forKey: transfer.uid)
		_incomingTransfers.removeValue(forKey: transfer.uid)
		_outgoingConnections.removeValue(forKey: transfer.uid)
    }
    
    func transferDidStart(_ transfer: Transfer) {
        if transfer.isIncoming {
            if _requestInProcess && !_transferRequests.isEmpty {
                _transferRequests.remove(at: 0)
                _requestInProcess = false
                _processNextTransferRequestIfPossible()
            }
        } else {
			_outgoingConnections.removeValue(forKey: transfer.uid)
        }
    }
    
    func transfer(_ transfer: Transfer, didProgress progress: Float) {
        if let delegate = _delegate as? TransfersManagerDelegate, transfer.hasFeedback {
            delegate.transfersManager(self, transfer: transfer, didProgress: progress)
        }
    }
    
    func transferDidComplete(_ transfer: Transfer) {
        if let delegate = _delegate as? TransfersManagerDelegate, transfer.hasFeedback {
            delegate.transfersManager(self, completeTransfer: transfer)
        }
        
        _removeTransfer(transfer)
    }
    
    func transferDidCancel(_ transfer: Transfer) {
        if let delegate = _delegate as? TransfersManagerDelegate, transfer.hasFeedback {
            delegate.transfersManager(self, cancelTransfer: transfer)
        }
        
        _removeTransfer(transfer)
        _lastTransferWasCancelled = true
    }
}
