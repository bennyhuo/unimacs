// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

/// Transfer dictionary keys - exposed to ObjC for cross-language compatibility
@objcMembers
class TransferKeys: NSObject {
	static let uid = "TransferUID"
	static let type = "TransferType"
	static let dataLength = "TransferDataLength" // exact on-wire byte count when known
	static let expectedDataLength = "TransferExpectedDataLength" // best-effort for progress UI when exact is unknown
	static let port = "TransferPort"
	static let shouldEncrypt = "TransferShouldEncrypt"
}

typealias TransferInfoDict = [AnyHashable: Any]

/// Outgoing `.transferRequest`/incoming request payload. Keeps the wire keys unchanged,
/// but provides a single typed place to read/write them.
struct TransferRequestInfo {
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

	init?(infoDict: TransferInfoDict) {
		guard let uid = infoDict[TransferKeys.uid] as? String,
			  let type = infoDict[TransferKeys.type] as? String else {
			return nil
		}
		self.uid = uid
		self.type = type
		self.dataLength = (infoDict[TransferKeys.dataLength] as? NSNumber)?.uint64Value ?? 0
		self.expectedDataLength = (infoDict[TransferKeys.expectedDataLength] as? NSNumber)?.uint64Value ?? 0
		self.shouldEncrypt = (infoDict[TransferKeys.shouldEncrypt] as? NSNumber)?.boolValue ?? false
	}

	var infoDict: TransferInfoDict {
		return [
			TransferKeys.uid: uid,
			TransferKeys.type: type,
			TransferKeys.dataLength: NSNumber(value: dataLength),
			TransferKeys.expectedDataLength: NSNumber(value: expectedDataLength),
			TransferKeys.shouldEncrypt: NSNumber(value: shouldEncrypt)
		]
	}
}

/// Incoming `.transferSuccess` payload.
struct TransferStartInfo {
	let uid: String
	let port: Int32

	init(uid: String, port: Int32) {
		self.uid = uid
		self.port = port
	}

	init?(infoDict: TransferInfoDict) {
		guard let uid = infoDict[TransferKeys.uid] as? String else {
			return nil
		}
		self.uid = uid
		self.port = (infoDict[TransferKeys.port] as? NSNumber)?.int32Value ?? 0
	}

	var infoDict: TransferInfoDict {
		return [
			TransferKeys.uid: uid,
			TransferKeys.port: NSNumber(value: port)
		]
	}
}

private let REFRESH_RATE: TimeInterval = 0.1
private let BLOCK_SIZE: UInt64 = 256 * 1024

enum TransferPriority: Int {
    case high
    case medium
    case low
}

@objcMembers
class Transfer: NSObject, MessageChannelDelegate, MessageListenerDelegate {
    var _listener: MessageListener?
    var _channel: MessageChannel?
    let _lock = NSLock()
    
    let uid: String

	// Set by `TransfersManager` so UI can attribute a transfer to a host.
	weak var remoteHost: RemoteHost?

    var _data: NSMutableData?
    var _totalDataLength: UInt64 = 0
	var _progressTotalDataLength: UInt64 = 0
	var _sentDataLength: UInt64 = 0
    var _receivedDataLength: UInt64 = 0
    
    weak var manager: TransfersManager?
    
	init(uid: String) {
		self.uid = uid
        super.init()
    }
    
    deinit {
        _channel?.delegate = nil
        _listener?.delegate = nil
    }
    
    var type: String {
        return "IncomingTransfer"
    }
    
    var priority: TransferPriority {
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
        let channel = _channel
        _channel = nil
        let listener = _listener
        _listener = nil
        _data = nil
        _lock.unlock()

        channel?.delegate = nil
        channel?.close()
        listener?.delegate = nil
        listener?.stop()
    }
    
    func _receivedData(_ data: Data) {
        // Subclasses override this
    }
    
    // MARK: - MessageChannelDelegate / MessageListenerDelegate
    
    func channelDidConnect(_ channel: MessageChannel) {}
    
    func channelDidFailToConnect(_ channel: MessageChannel) {}
    
    func channel(_ channel: MessageChannel, didReceiveData data: Data) {
        self._receivedData(data)
    }
    
    func channelDidDisconnect(_ channel: MessageChannel) {}
    
    func listener(_ listener: MessageListener, didAcceptChannel channel: MessageChannel) {}
    
    func listenerShouldEnableEncryption(_ listener: MessageListener, forRemoteAddress address: String?) -> Bool {
        false
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

class OutgoingTransfer: Transfer {
    
    static func shared() -> Self {
		self.init()
    }
	
	required init() {
		super.init(uid: ProcessInfo.processInfo.globallyUniqueString)
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?._sendDataWork()
        }
    }
    
    private func _sendDataWork() {
        if _totalDataLength > 0 {
            var lastDate = Date()
            var offset: Int = 0
            let total = Int(_totalDataLength)
            let blockSize = Int(BLOCK_SIZE)
            
            while offset < total {
                _sentDataLength = UInt64(offset)
                if abs(lastDate.timeIntervalSinceNow) >= REFRESH_RATE {
                    let sentSnapshot = _sentDataLength
                    DispatchQueue.main.async { [weak self] in
                        self?._notifyProgress(NSNumber(value: sentSnapshot))
                    }
                    lastDate = Date()
                }
                
                let chunkLength = min(blockSize, total - offset)
                let sendRange = NSRange(location: offset, length: chunkLength)
                
                _lock.lock()
                let currentData = _data
                let currentChannel = _channel
                let sendData = currentData?.subdata(with: sendRange)
                _lock.unlock()
                
                guard let sendData, let currentChannel else {
                    break
                }
                
                if !currentChannel.send(sendData) {
                    break
                }
                offset += chunkLength
            }
            
            if UInt64(offset) == _totalDataLength {
                DispatchQueue.main.async {
                    self._senderDataTransferCompleted()
                }
            } else {
                DispatchQueue.main.async {
                    self._senderDataTransferAborted()
                }
            }
        } else {
            _lock.lock()
            let dataToSend = _data as Data?
            let currentChannel = _channel
            _data = nil
            _lock.unlock()
            
            if let dataToSend, !dataToSend.isEmpty {
                _ = currentChannel?.send(dataToSend)
            }
            DispatchQueue.main.async {
                self._senderDataTransferCompleted()
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
    
    func setChannel(_ channel: MessageChannel) {
        _channel = channel
        _channel?.delegate = self
    }
    
    func dataToTransfer() -> Data? {
        return Data()
    }
    
    func totalDataLength() -> UInt64 {
        return _totalDataLength
    }
    
    func infoDict() -> [AnyHashable: Any] {
		return TransferRequestInfo(
			uid: uid,
			type: type,
			dataLength: totalDataLength(),
			expectedDataLength: _progressTotalDataLength,
			shouldEncrypt: false
		).infoDict
    }
    
    override func channelDidConnect(_ channel: MessageChannel) {
        debugLog("Transfer connected: \(_channel?.remoteAddress ?? "unknown")", module: .transfer)
        DispatchQueue.main.async {
            self.manager?.transferDidStart(self)
            self._beginTransfer()
        }
    }
    
    override func channelDidFailToConnect(_ channel: MessageChannel) {
        warningLog("Transfer connection failed", module: .transfer)
        DispatchQueue.main.async {
            self._senderDataTransferFailed()
        }
    }
}

class IncomingTransfer: Transfer {
    var _shouldEncrypt: Bool = false
    private var _lastProgressNotifyDate: Date = .distantPast
    private var _didFinishReceive: Bool = false
	
	static let incomingTransferTypes: [String: IncomingTransfer.Type] = [
		"IncomingPasteboardTransfer": IncomingPasteboardTransfer.self,
		"IncomingPasteboardFileTransfer": IncomingPasteboardFileTransfer.self,
		"IncomingBackgroundImageTransfer": IncomingBackgroundImageTransfer.self
	]
    
    static func instance(withType type: String, uid: String) -> IncomingTransfer? {
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
    
    func _listen(onPort port: UnsafeMutablePointer<Int32>, for host: RemoteHost, encrypt shouldEncrypt: Bool) -> Bool {
        if _listener == nil {
            let listener = MessageTransportFactory.makeListener(enableEncryption: false)
            listener.delegate = self
            _listener = listener
            
            let result = listener.start(onPort: port, tries: 50)
            if !result {
                warningLog("Transfer listen failed on port \(port.pointee)", module: .transfer)
                _listener = nil
            }
            return result
        }
        return true
    }
    
    func _stopListening() {
        _listener?.delegate = nil
        _listener?.stop()
        _listener = nil
    }
    
    override var isIncoming: Bool {
        return true
    }
    
	func prepareToReceiveData(withInfoDict infoDict: [AnyHashable: Any], from host: RemoteHost, onPort port: inout Int32, delegate: Any) -> Bool {
        let requestInfo = TransferRequestInfo(infoDict: infoDict)
		_totalDataLength = requestInfo?.dataLength ?? 0
        _shouldEncrypt = requestInfo?.shouldEncrypt ?? false
		_progressTotalDataLength = _totalDataLength > 0 ? _totalDataLength : (requestInfo?.expectedDataLength ?? 0)
        
		_receivedDataLength = 0
        _didFinishReceive = false
        _lastProgressNotifyDate = .distantPast

		if shouldBufferIncomingData, _totalDataLength > 0 {
			_data = NSMutableData(capacity: Int(_totalDataLength))
			_data?.length = Int(_totalDataLength)
		} else {
			_data = nil
		}
        
		return _listen(onPort: &port, for: host, encrypt: _shouldEncrypt)
    }
    
    override func _beginTransfer() {
        // Inbound bytes are delivered via `NWMessageChannel`'s background receive loop.
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
        guard dataLength > 0 else { return }
        _lock.lock()
        if let buffer = _data {
            let offset = Int(_receivedDataLength)
            let available = max(0, buffer.length - offset)
            let copyLen = min(dataLength, available)
            if copyLen > 0 {
                data.withUnsafeBytes { rawBuf in
                    if let base = rawBuf.baseAddress {
                        buffer.replaceBytes(in: NSRange(location: offset, length: copyLen), withBytes: base)
                    }
                }
            }
        }
        _receivedDataLength &+= UInt64(dataLength)
        let currentReceived = _receivedDataLength
        let total = _totalDataLength
        _lock.unlock()

        _reportReceiveProgressIfNeeded(currentReceived: currentReceived, total: total)
    }

    func _reportReceiveProgressIfNeeded(currentReceived: UInt64, total: UInt64) {
        let now = Date()
        var shouldNotifyProgress = false
        var shouldCompleteFixedLength = false

        _lock.lock()
        if abs(_lastProgressNotifyDate.timeIntervalSince(now)) >= REFRESH_RATE {
            _lastProgressNotifyDate = now
            shouldNotifyProgress = true
        }
        if total > 0 && currentReceived >= total && !_didFinishReceive {
            _didFinishReceive = true
            shouldCompleteFixedLength = true
        }
        _lock.unlock()

        if shouldNotifyProgress {
            DispatchQueue.main.async { [weak self] in
                self?._notifyProgress(NSNumber(value: currentReceived))
            }
        }

        if shouldCompleteFixedLength {
            _finalizeIncomingTransfer(succeeded: true)
        }
    }

    private func _finalizeIncomingTransfer(succeeded: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if succeeded {
                self._prepareReceivedDataBeforeCompletion()
                DispatchQueue.main.async {
                    self._receiverDataTransferCompleted()
                }
            } else {
                DispatchQueue.main.async {
                    self._receiverDataTransferAborted()
                }
            }
        }
    }

    /// Subclass hook for heavy post-receive processing (deserialize, write pasteboard, etc.).
    /// Runs on a background queue *before* the main-thread completion callback,
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
    
    override func listener(_ listener: MessageListener, didAcceptChannel channel: MessageChannel) {
        _lock.lock()
        let oldChannel = _channel
        _channel = channel
        _didFinishReceive = false
        _lastProgressNotifyDate = Date()
        _lock.unlock()

        oldChannel?.close()
        channel.setNoDelay(false)
        channel.delegate = self
        channel.activateReceiveCallbacks()
        
        self._stopListening()
        DispatchQueue.main.async {
            self.manager?.transferDidStart(self)
        }
        self._beginTransfer()
    }
    
	override func channelDidFailToConnect(_ channel: MessageChannel) {
        warningLog("Transfer receive connection failed", module: .transfer)
        _lock.lock()
        guard !_didFinishReceive else {
            _lock.unlock()
            return
        }
        _didFinishReceive = true
        _lock.unlock()
        DispatchQueue.main.async {
            self._receiverDataTransferFailed()
        }
    }
    
    override func channelDidDisconnect(_ channel: MessageChannel) {
        _lock.lock()
        guard !_didFinishReceive else {
            _lock.unlock()
            return
        }
        _didFinishReceive = true
        let total = _totalDataLength
        let received = _receivedDataLength
        _lock.unlock()

        if total == 0 {
            DispatchQueue.main.async { [weak self] in
                self?._notifyProgress(NSNumber(value: received))
            }
            _finalizeIncomingTransfer(succeeded: true)
        } else if received >= total {
            _finalizeIncomingTransfer(succeeded: true)
        } else {
            _finalizeIncomingTransfer(succeeded: false)
        }
    }
}
