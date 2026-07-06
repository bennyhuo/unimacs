// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

/// Transfer dictionary keys - exposed to ObjC for cross-language compatibility
@objcMembers
class TPTransferKeys: NSObject {
	static let uid = "TPTransferUID"
	static let type = "TPTransferType"
	static let dataLength = "TPTransferDataLength" // exact on-wire byte count when known
	static let expectedDataLength = "TPTransferExpectedDataLength" // best-effort for progress UI when exact is unknown
	static let port = "TPTransferPort"
	static let shouldEncrypt = "TPTransferShouldEncrypt"
}

typealias TPTransferInfoDict = [AnyHashable: Any]

/// Outgoing `.transferRequest`/incoming request payload. Keeps the wire keys unchanged,
/// but provides a single typed place to read/write them.
struct TPTransferRequestInfo {
	let uid: String
	let type: String

	/// Exact on-wire payload byte count when known. If `0`, the receiver treats it as unknown
	/// and will read until the socket closes.
	let dataLength: UInt64

	/// Best-effort payload size hint for progress UI when `dataLength` is unknown.
	let expectedDataLength: UInt64

	let shouldEncrypt: Bool

	init(uid: String, type: String, dataLength: UInt64, expectedDataLength: UInt64 = 0, shouldEncrypt: Bool) {
		self.uid = uid
		self.type = type
		self.dataLength = dataLength
		self.expectedDataLength = expectedDataLength
		self.shouldEncrypt = shouldEncrypt
	}

	init?(infoDict: TPTransferInfoDict) {
		guard let uid = infoDict[TPTransferKeys.uid] as? String,
			  let type = infoDict[TPTransferKeys.type] as? String else {
			return nil
		}
		self.uid = uid
		self.type = type
		self.dataLength = (infoDict[TPTransferKeys.dataLength] as? NSNumber)?.uint64Value ?? 0
		self.expectedDataLength = (infoDict[TPTransferKeys.expectedDataLength] as? NSNumber)?.uint64Value ?? 0
		self.shouldEncrypt = (infoDict[TPTransferKeys.shouldEncrypt] as? NSNumber)?.boolValue ?? false
	}

	var infoDict: TPTransferInfoDict {
		return [
			TPTransferKeys.uid: uid,
			TPTransferKeys.type: type,
			TPTransferKeys.dataLength: NSNumber(value: dataLength),
			TPTransferKeys.expectedDataLength: NSNumber(value: expectedDataLength),
			TPTransferKeys.shouldEncrypt: NSNumber(value: shouldEncrypt)
		]
	}
}

/// Incoming `.transferSuccess` payload.
struct TPTransferStartInfo {
	let uid: String
	let port: Int32

	init(uid: String, port: Int32) {
		self.uid = uid
		self.port = port
	}

	init?(infoDict: TPTransferInfoDict) {
		guard let uid = infoDict[TPTransferKeys.uid] as? String else {
			return nil
		}
		self.uid = uid
		self.port = (infoDict[TPTransferKeys.port] as? NSNumber)?.int32Value ?? 0
	}

	var infoDict: TPTransferInfoDict {
		return [
			TPTransferKeys.uid: uid,
			TPTransferKeys.port: NSNumber(value: port)
		]
	}
}

private let REFRESH_RATE: TimeInterval = 0.1
private let BLOCK_SIZE: UInt64 = 256 * 1024

enum TPTransferPriority: Int {
    case high
    case medium
    case low
}

@objcMembers
class TPTransfer: NSObject, TPTCPSocketDelegate {
    var _listenSocket: TPTCPSocket?
    var _socket: TPTCPSocket?
    let _lock = NSLock()
    
    let uid: String

	// Set by `TPTransfersManager` so UI can attribute a transfer to a host.
	weak var remoteHost: TPRemoteHost?

    var _data: NSMutableData?
    var _totalDataLength: UInt64 = 0
	var _progressTotalDataLength: UInt64 = 0
	var _sentDataLength: UInt64 = 0
    var _receivedDataLength: UInt64 = 0
    
    weak var manager: TPTransfersManager?
    
	init(uid: String) {
		self.uid = uid
        super.init()
    }
    
    deinit {
        _socket?.delegate = nil
    }
    
    var type: String {
        return "TPIncomingTransfer"
    }
    
    var priority: TPTransferPriority {
        return .low
    }
    
    var isIncoming: Bool {
        return false
    }
    
    var hasFeedback: Bool {
        return false
    }
    
    var completionMessage: String? {
        return nil
    }
    
    var errorMessage: String? {
        return nil
    }
    
    func _beginTransfer() {}
    
    @objc func _notifyProgress(_ transferedNumber: NSNumber) {
        let transferedDataLength = transferedNumber.uint64Value
		let totalForProgress = _progressTotalDataLength
		if totalForProgress > 0 {
			let progress = Double(transferedDataLength) / Double(totalForProgress)
			manager?.transfer(self, didProgress: Float(progress))
		} else {
			// Unknown total: keep it indeterminate.
			manager?.transfer(self, didProgress: -1.0)
		}
    }
    
    func _transferDone() {
        _lock.lock()
        _socket?.delegate = nil
        _socket?.close()
        _socket = nil
        _data = nil
        _lock.unlock()
    }
    
    func _receivedData(_ data: Data) {
        // Subclasses override this
    }
    
    // MARK: - TCP Socket delegate
    
    func tcpSocketConnectionSucceeded(_ tcpSocket: TPTCPSocket) {
		
	}
    
    func tcpSocketConnectionFailed(_ tcpSocket: TPTCPSocket) {

	}
    
    func tcpSocket(_ tcpSocket: TPTCPSocket, gotData data: Data) {
        self._receivedData(data)
    }
    
    func tcpSocketDidSendData(_ tcpSocket: TPTCPSocket) {
        // Data sent callback
    }
    
    func tcpSocketConnectionClosed(_ tcpSocket: TPTCPSocket) {
        // Connection closed - handled by subclasses
    }
    
    override var description: String {
        return "\(Swift.type(of: self))<\(Unmanaged.passUnretained(self).toOpaque())> uid:\(uid)"
    }
    
    // Abstract placeholders for subclasses
    func _senderDataTransferCompleted() {}
    func _senderDataTransferAborted() {}
    func _receiverDataTransferCompleted() {}
    func _receiverDataTransferAborted() {}
}

class TPOutgoingTransfer: TPTransfer {
    
    static func shared() -> Self {
		self.init()
    }
	
	required init() {
		super.init(uid:  ProcessInfo.processInfo.globallyUniqueString)
	}
	
    var shouldBeEncrypted: Bool {
        return false
    }
    
    func prepareToSendData() -> Bool {
        guard let dataToTransfer = self.dataToTransfer() else { return false }
        
        _data = NSMutableData(data: dataToTransfer)
        _totalDataLength = UInt64(_data?.length ?? 0)
		_progressTotalDataLength = _totalDataLength
		_sentDataLength = 0
        
        return true
    }
    
    override func _beginTransfer() {
        if _totalDataLength > 0 {
            _socket?._setRunLoop(nil)
            Thread.detachNewThreadSelector(#selector(_sendDataThread), toTarget: self, with: nil)
        }
    }
    
    @objc func _sendDataThread() {
        autoreleasepool {
            _socket?._setRunLoop(RunLoop.current.getCFRunLoop())
            
            if _totalDataLength > 0 {
                var lastDate = Date()
                var sendRange = NSRange(location: 0, length: Int(min(BLOCK_SIZE, _totalDataLength)))
                
                while _data != nil && sendRange.length > 0 {
					_sentDataLength = UInt64(sendRange.location)
                    if abs(lastDate.timeIntervalSinceNow) >= REFRESH_RATE {
                        self.performSelector(onMainThread: #selector(_notifyProgress(_:)), with: NSNumber(value: _sentDataLength), waitUntilDone: false)
                        lastDate = Date()
                    }
                    
                    _lock.lock()
                    let sendData = _data?.subdata(with: sendRange)
                    let sent = sendData != nil ? _socket?.send(sendData!) ?? false : false
                    _lock.unlock()
                    
                    if !sent {
                        break
                    } else {
                        sendRange.location += sendRange.length
                        sendRange.length = Int(min(BLOCK_SIZE, _totalDataLength - UInt64(sendRange.location)))
                    }
                }
                
                // Detach the socket from this thread's run loop *before* hopping to main.
                // Completion runs on main and calls close(); if the socket still owned this
                // (now blocked, waiting on the synchronous hop) thread's run loop, close()
                // would wait 2s for it to respond and stall the main run loop — freezing
                // input capture and the transfer progress UI. The receive thread does the same.
                _socket?._setRunLoop(nil)

                if UInt64(sendRange.location) == _totalDataLength {
                    self.performSelector(onMainThread: #selector(_senderDataTransferCompleted), with: nil, waitUntilDone: true)
                } else {
                    self.performSelector(onMainThread: #selector(_senderDataTransferAborted), with: nil, waitUntilDone: true)
                }
            } else {
                // Logic for data is null or empty
                while _data != nil {
                    _lock.lock()
                    let sent = _socket?.send(_data as Data?) ?? false
                    _data = nil
                    _lock.unlock()
                    
                    CFRunLoopRunInMode(.defaultMode, 0.0, false)
                    if !sent { break }
                }
                _socket?._setRunLoop(nil)
                self.performSelector(onMainThread: #selector(_senderDataTransferCompleted), with: nil, waitUntilDone: true)
            }
        }
    }
    
	@objc override func _senderDataTransferCompleted() {
		if hasFeedback {
			manager?.transfer(self, didProgress: 1.0)
		}
        self._transferDone()
        manager?.transferDidComplete(self)
    }
    
    func _senderDataTransferFailed() {
        self._transferDone()
        manager?.transferDidCancel(self)
    }
    
	@objc override func _senderDataTransferAborted() {
        self._transferDone()
        manager?.transferDidCancel(self)
    }
    
    func setSocket(_ socket: TPTCPSocket) {
        _socket = socket
        _socket?.delegate = self
    }
    
    func dataToTransfer() -> Data? {
        return Data()
    }
    
    func totalDataLength() -> UInt64 {
        return _totalDataLength
    }
    
    func infoDict() -> [AnyHashable: Any] {
		return TPTransferRequestInfo(
			uid: uid,
			type: type,
			dataLength: totalDataLength(),
			expectedDataLength: _progressTotalDataLength,
			shouldEncrypt: false
		).infoDict
    }
    
    override func tcpSocketConnectionSucceeded(_ tcpSocket: TPTCPSocket) {
        debugLog("Transfer connected: \(_socket?.remoteAddress ?? "unknown")", module: .transfer)
        manager?.transferDidStart(self)
        self._beginTransfer()
    }
    
    override func tcpSocketConnectionFailed(_ tcpSocket: TPTCPSocket) {
        warningLog("Transfer connection failed", module: .transfer)
        self._senderDataTransferFailed()
    }
}

class TPIncomingTransfer: TPTransfer {
    var _shouldEncrypt: Bool = false
	
	static let incomingTransferTypes: [String: TPIncomingTransfer.Type] = [
		"TPIncomingPasteboardTransfer": TPIncomingPasteboardTransfer.self,
		"TPIncomingPasteboardFileTransfer": TPIncomingPasteboardFileTransfer.self,
		"TPIncomingBackgroundImageTransfer": TPIncomingBackgroundImageTransfer.self
	]
    
    static func instance(withType type: String, uid: String) -> TPIncomingTransfer? {
		guard let transferClass = incomingTransferTypes[type] else {
            return nil
        }
		return transferClass.init(uid: uid)
    }
	
	override required init(uid: String) {
		super.init(uid: uid)
	}
	
    var requireTrustedHost: Bool {
        return false
    }

	/// Whether the base class should buffer the entire incoming payload into `_data`.
	/// Streaming receivers (file transfers) should override to return `false`.
	var shouldBufferIncomingData: Bool {
		return true
	}
    
    func _listen(onPort port: UnsafeMutablePointer<Int32>, for host: TPRemoteHost, encrypt shouldEncrypt: Bool) -> Bool {
        if _listenSocket == nil {
            _listenSocket = TPTCPSocket(delegate: self)
            
            let result = _listenSocket?.listen(onPort: port, tries: 50) ?? false
            if !result {
                warningLog("Transfer listen failed on port \(port.pointee)", module: .transfer)
            }
            return result
        }
        return true
    }
    
    func _stopListening() {
        _listenSocket?.delegate = nil
        _listenSocket?.close()
        _listenSocket = nil
    }
    
    override var isIncoming: Bool {
        return true
    }
    
	func prepareToReceiveData(withInfoDict infoDict: [AnyHashable: Any], from host: TPRemoteHost, onPort port: inout Int32, delegate: Any) -> Bool {
        let requestInfo = TPTransferRequestInfo(infoDict: infoDict)
		_totalDataLength = requestInfo?.dataLength ?? 0
        _shouldEncrypt = requestInfo?.shouldEncrypt ?? false
		_progressTotalDataLength = _totalDataLength > 0 ? _totalDataLength : (requestInfo?.expectedDataLength ?? 0)
        
		_receivedDataLength = 0

		if shouldBufferIncomingData, _totalDataLength > 0 {
			_data = NSMutableData(capacity: Int(_totalDataLength))
			_data?.length = Int(_totalDataLength)
		} else {
			_data = nil
		}
        
		return _listen(onPort: &port, for: host, encrypt: _shouldEncrypt)

    }
    
    override func _beginTransfer() {
        _socket?._setRunLoop(nil)
        Thread.detachNewThreadSelector(#selector(_receiveDataThread), toTarget: self, with: nil)
    }
    
    override func _notifyProgress(_ transferedNumber: NSNumber) {
        super._notifyProgress(transferedNumber)
        let transferedDataLength = transferedNumber.uint64Value
		let totalForProgress = _progressTotalDataLength
		let progress = totalForProgress > 0 ? Double(transferedDataLength) / Double(totalForProgress) : -1.0
        self._transferDidProgress(Float(progress))
    }
    
    func _transferDidProgress(_ progress: Float) {}
    
    override func _receivedData(_ data: Data) {
        let dataLength = data.count
        _lock.lock()
        _data?.replaceBytes(in: NSRange(location: Int(_receivedDataLength), length: dataLength), withBytes: (data as NSData).bytes)
        _lock.unlock()
        _receivedDataLength += UInt64(dataLength)
    }
    
    @objc func _receiveDataThread() {
        autoreleasepool {
            var ret: CFRunLoopRunResult = .timedOut
            _socket?._setRunLoop(RunLoop.current.getCFRunLoop())
            
            if _totalDataLength > 0 {
                _receivedDataLength = 0
				var lastDate = Date()
                while ret != .finished && _socket != nil && _receivedDataLength < _totalDataLength {
                    autoreleasepool {
                        ret = CFRunLoopRunInMode(.defaultMode, 0.0, false)
                        if abs(lastDate.timeIntervalSinceNow) >= REFRESH_RATE {
                            self.performSelector(onMainThread: #selector(_notifyProgress(_:)), with: NSNumber(value: _receivedDataLength), waitUntilDone: false)
                            lastDate = Date()
                        }
                    }
                }
                
                _socket?._setRunLoop(nil)
                if _receivedDataLength == _totalDataLength {
                    // Heavy post-receive work (deserialize + pasteboard write) runs here on the
                    // background receive thread, so it never blocks the main thread / control I/O.
                    self._prepareReceivedDataBeforeCompletion()
                    self.performSelector(onMainThread: #selector(_receiverDataTransferCompleted), with: nil, waitUntilDone: true)
                } else {
                    self.performSelector(onMainThread: #selector(_receiverDataTransferAborted), with: nil, waitUntilDone: true)
                }
            } else {
				var lastDate = Date()
                while ret != .finished && _socket != nil && _totalDataLength != UInt64.max { // Using max as proxy for -1
                    autoreleasepool {
                        ret = CFRunLoopRunInMode(.defaultMode, 0.0, false)
						if abs(lastDate.timeIntervalSinceNow) >= REFRESH_RATE {
							self.performSelector(onMainThread: #selector(_notifyProgress(_:)), with: NSNumber(value: _receivedDataLength), waitUntilDone: false)
							lastDate = Date()
						}
                    }
                }
                _socket?._setRunLoop(nil)
				self.performSelector(onMainThread: #selector(_notifyProgress(_:)), with: NSNumber(value: _receivedDataLength), waitUntilDone: false)
                self._prepareReceivedDataBeforeCompletion()
                self.performSelector(onMainThread: #selector(_receiverDataTransferCompleted), with: nil, waitUntilDone: true)
            }
        }
    }

    /// Subclass hook for heavy post-receive processing (deserialize, write pasteboard, etc.).
    /// Runs on the background receive thread *before* the main-thread completion callback,
    /// so it never stalls the main run loop or the persistent control connection's I/O.
    @objc func _prepareReceivedDataBeforeCompletion() {}
    
	@objc override func _receiverDataTransferCompleted() {
		if hasFeedback {
			manager?.transfer(self, didProgress: 1.0)
		}
        self._transferDone()
        manager?.transferDidComplete(self)
    }
    
    func _receiverDataTransferFailed() {
        self._transferDone()
        manager?.transferDidCancel(self)
    }
    
	@objc override func _receiverDataTransferAborted() {
        self._transferDone()
        manager?.transferDidCancel(self)
    }
    
    func tcpSocket(_ listenSocket: TPTCPSocket, connectionAccepted childSocket: TPTCPSocket) {
        _socket?.close()
        _socket = childSocket
        _socket?.setNoDelay(false)
        _socket?.delegate = self
        
        self._stopListening()
        manager?.transferDidStart(self)
        self._beginTransfer()
    }
    
	override func tcpSocketConnectionFailed(_ tcpSocket: TPTCPSocket) {
        warningLog("Transfer receive connection failed", module: .transfer)
        self._receiverDataTransferFailed()
    }
    
    override func tcpSocketConnectionClosed(_ tcpSocket: TPTCPSocket) {
        if _totalDataLength == 0 {
            _totalDataLength = UInt64.max // Proxy for -1
        }
    }
}
