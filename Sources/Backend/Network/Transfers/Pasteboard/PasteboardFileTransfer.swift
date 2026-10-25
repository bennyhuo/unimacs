// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

// MARK: - Constants

let TPFileTransferRepresentedFilesKey = "TPFileTransferRepresentedFiles"
let TPFileArchiverNameKey = "TPFileArchiverName"
let TPFileArchiverTypeKey = "TPFileArchiverType"

// MARK: - Tar Size Estimation

private func TPEstimateUncompressedTarSize(forPaths paths: [String]) -> UInt64 {
	let tarBlock: UInt64 = 512
	var total: UInt64 = 2 * tarBlock

	let fm = FileManager.default

	func roundUpToTarBlock(_ size: UInt64) -> UInt64 {
		let rem = size % tarBlock
		return rem == 0 ? size : (size + (tarBlock - rem))
	}

	func addEntry(at url: URL) {
		total += tarBlock
		let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
		if values?.isRegularFile == true {
			let size = UInt64(values?.fileSize ?? 0)
			total += roundUpToTarBlock(size)
		}
	}

	for path in paths {
		let url = URL(fileURLWithPath: path)
		var isDirectory: ObjCBool = false
		if fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
			addEntry(at: url)
			if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [], errorHandler: { _, _ in true }) {
				for case let childURL as URL in enumerator {
					addEntry(at: childURL)
				}
			}
		} else {
			addEntry(at: url)
		}
	}

	return total
}

// MARK: - File Representation

private struct TPFileRepresentation {
	let name: String
	let fileType: String?

	init?(dictionary: [AnyHashable: Any]) {
		guard let name = dictionary[TPFileArchiverNameKey] as? String else {
			return nil
		}
		self.name = name
		self.fileType = dictionary[TPFileArchiverTypeKey] as? String
	}
}

// MARK: - File Archiver

@objc protocol TPFileArchiverDelegate: NSObjectProtocol {
	func fileArchiver(_ archiver: TPFileArchiver, hasDataAvailable data: Data)
	func fileArchiverDidCompleteReading(_ archiver: TPFileArchiver)
}

@objcMembers
final class TPFileArchiver: NSObject {
	private weak var delegate: TPFileArchiverDelegate?
	private let paths: [String]

	private let readPipe = Pipe()
	private let readErrorPipe = Pipe()
	private let readTask = Process()

	private lazy var readFileHandle: FileHandle = readPipe.fileHandleForReading
	private lazy var readErrorFileHandle: FileHandle = readErrorPipe.fileHandleForReading

	fileprivate static let tarPath = "/usr/bin/tar"

	fileprivate static func environment() -> [String: String] {
		return [
			"LANG": "en_US.UTF-8",
			"LC_CTYPE": "en_US.UTF-8",
			"COPYFILE_DISABLE": "1"
		]
	}

	@objc(initForReadingFilesAtPaths:delegate:)
	init(forReadingFilesAtPaths paths: [String], delegate: TPFileArchiverDelegate) {
		self.paths = paths
		self.delegate = delegate
		super.init()

		readTask.executableURL = URL(fileURLWithPath: Self.tarPath)
		readTask.standardOutput = readPipe
		readTask.standardError = readErrorPipe
		readTask.environment = Self.environment()

		var arguments: [String] = ["c", "-", "--no-xattrs", "--no-acls", "--no-fflags"]

		for path in paths {
			let parent = (path as NSString).deletingLastPathComponent
			let name = (path as NSString).lastPathComponent
			if !parent.isEmpty, !name.isEmpty {
				arguments.append("-C")
				arguments.append(parent)
				arguments.append(name)
			}
		}
		readTask.arguments = arguments

		NotificationCenter.default.addObserver(self, selector: #selector(fileHandleDidReadData(_:)), name: FileHandle.readCompletionNotification, object: readFileHandle)
		NotificationCenter.default.addObserver(self, selector: #selector(errorFileHandleDidReadData(_:)), name: FileHandle.readCompletionNotification, object: readErrorFileHandle)
	}

	@objc var representedFiles: [NSDictionary] {
		var representedFiles: [NSDictionary] = []
		for path in paths {
			let name = (path as NSString).lastPathComponent
			let type = (try? NSWorkspace.shared.type(ofFile: path)) ?? "public.data"
			let dict: NSDictionary = [
				TPFileArchiverNameKey: name,
				TPFileArchiverTypeKey: type
			]
			representedFiles.append(dict)
		}
		return representedFiles
	}

	@objc func startReading() {
		do {
			try readTask.run()
		} catch {
			NSLog("[TPFileArchiver] Failed to launch tar: %@", String(describing: error))
			delegate?.fileArchiverDidCompleteReading(self)
			return
		}
		readFileHandle.readInBackgroundAndNotify()
		readErrorFileHandle.readInBackgroundAndNotify()
	}

	@objc func continueReading() {
		readFileHandle.readInBackgroundAndNotify()
	}

	@objc private func fileHandleDidReadData(_ notification: Notification) {
		guard let data = notification.userInfo?[NSFileHandleNotificationDataItem] as? Data else {
			delegate?.fileArchiverDidCompleteReading(self)
			return
		}

		if !data.isEmpty {
			delegate?.fileArchiver(self, hasDataAvailable: data)
		} else {
			readTask.waitUntilExit()
			let status = readTask.terminationStatus
			if status != 0 {
				NSLog("[TPFileArchiver] tar exited with status %d", status)
			}
			delegate?.fileArchiverDidCompleteReading(self)
		}
	}

	@objc private func errorFileHandleDidReadData(_ notification: Notification) {
		guard let data = notification.userInfo?[NSFileHandleNotificationDataItem] as? Data, !data.isEmpty else {
			return
		}
		if let str = String(data: data, encoding: .utf8), !str.isEmpty {
			NSLog("[TPFileArchiver][tar stderr] %@", str)
		}
		readErrorFileHandle.readInBackgroundAndNotify()
	}
}

// MARK: - File Unarchiver

@objcMembers
final class TPFileUnarchiver: NSObject {
	private let writePipe = Pipe()
	private let writeErrorPipe = Pipe()
	private let writeTask = Process()

	private lazy var writeFileHandle: FileHandle = writePipe.fileHandleForWriting
	private lazy var writeErrorFileHandle: FileHandle = writeErrorPipe.fileHandleForReading

	private let path: String

	@objc(initForWritingAtPath:)
	init(forWritingAtPath path: String) {
		self.path = path
		super.init()

		writeTask.executableURL = URL(fileURLWithPath: TPFileArchiver.tarPath)
		writeTask.arguments = ["x", "--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags", "-C", path]
		writeTask.environment = TPFileArchiver.environment()
		writeTask.standardInput = writePipe
		writeTask.standardError = writeErrorPipe

		NotificationCenter.default.addObserver(self, selector: #selector(writeErrorFileHandleDidReadData(_:)), name: FileHandle.readCompletionNotification, object: writeErrorFileHandle)
	}

	@objc func startWriting() {
		do {
			try writeTask.run()
		} catch {
			NSLog("[TPFileUnarchiver] Failed to launch tar: %@", String(describing: error))
			return
		}
		writeErrorFileHandle.readInBackgroundAndNotify()
	}

	@objc func close() {
		writeFileHandle.closeFile()
		writeTask.waitUntilExit()
		let status = writeTask.terminationStatus
		if status != 0 {
			NSLog("[TPFileUnarchiver] tar exited with status %d", status)
		}
	}

	@objc func writeData(_ data: Data) {
		writeFileHandle.write(data)
	}

	@objc(write:)
	func write(_ data: Data) {
		writeData(data)
	}

	@objc private func writeErrorFileHandleDidReadData(_ notification: Notification) {
		guard let data = notification.userInfo?[NSFileHandleNotificationDataItem] as? Data, !data.isEmpty else {
			return
		}
		if let str = String(data: data, encoding: .utf8), !str.isEmpty {
			NSLog("[TPFileUnarchiver][tar stderr] %@", str)
		}
		writeErrorFileHandle.readInBackgroundAndNotify()
	}
}

// MARK: - Outgoing Pasteboard File Transfer

private let TPArchiveProgressRefreshRate: TimeInterval = 0.1

class TPOutgoingPasteboardFileTransfer: TPOutgoingTransfer, TPFileArchiverDelegate {
	private var _archiver: TPFileArchiver?
	private var _filePaths: [String] = []
	private var _lastProgressDate: Date = .distantPast
	private var _didLogArchiveHeader: Bool = false
	private var _archiveFinished: Bool = false

	override var type: String {
		return "TPIncomingPasteboardFileTransfer"
	}

	override var shouldBeEncrypted: Bool {
		return true
	}

	var requireTrustedHost: Bool {
		return true
	}

	override var priority: TransferPriority {
		return .high
	}

	override var hasFeedback: Bool {
		return true
	}

	override var completionMessage: String {
		let size = _progressTotalDataLength > 0 ? _progressTotalDataLength : _sentDataLength
let sizeString = String.sizeString(for: size)
		return String(format: NSLocalizedString("File sent (%@)", comment: ""), sizeString)
	}

	override var errorMessage: String {
		return NSLocalizedString("File not sent", comment: "")
	}

	func setFilePaths(_ filePaths: [String]) {
		_filePaths = filePaths
		_archiver = TPFileArchiver(forReadingFilesAtPaths: filePaths, delegate: self)
	}

	override func infoDict() -> [AnyHashable: Any] {
		var infoDict = super.infoDict()
		if let archiver = _archiver {
			infoDict[TPFileTransferRepresentedFilesKey] = archiver.representedFiles
		}
		return infoDict
	}

	override func prepareToSendData() -> Bool {
		guard _archiver != nil, !_filePaths.isEmpty else { return false }

		_totalDataLength = 0
		_progressTotalDataLength = TPEstimateUncompressedTarSize(forPaths: _filePaths)
		_sentDataLength = 0
		_lastProgressDate = .distantPast
		return true
	}

	override func _beginTransfer() {
		// `_beginTransfer` runs on the socket's run loop, which is the main run loop because the
		// transfer socket connects on the MainActor. Drive tar reading and socket writes on a
		// dedicated background thread (mirroring TPOutgoingTransfer._sendDataThread) so a large
		// file transfer never blocks input/UI on the main thread.
		manager?.transfer(self, didProgress: 0.0)
		_lastProgressDate = Date()
		_archiveFinished = false
		_socket?._setRunLoop(nil)
		Thread.detachNewThreadSelector(#selector(_archiveThread), toTarget: self, with: nil)
	}

	@objc private func _archiveThread() {
		autoreleasepool {
			_socket?._setRunLoop(RunLoop.current.getCFRunLoop())
			_archiver?.startReading()
			// Pump this thread's run loop so the archiver's background-read notifications
			// (and the socket callbacks) are delivered here instead of on the main thread.
			while !_archiveFinished {
				CFRunLoopRunInMode(.defaultMode, 0.1, true)
			}
			_socket?._setRunLoop(nil)
		}
	}

	func fileArchiver(_ archiver: TPFileArchiver, hasDataAvailable data: Data) {
		let sent = _socket?.send(data) ?? false
		if !sent {
			_archiveFinished = true
			self.performSelector(onMainThread: #selector(_senderDataTransferAborted), with: nil, waitUntilDone: false)
			return
		}

		_sentDataLength &+= UInt64(data.count)
		if abs(_lastProgressDate.timeIntervalSinceNow) >= TPArchiveProgressRefreshRate {
			self.performSelector(onMainThread: #selector(_notifyProgress(_:)), with: NSNumber(value: _sentDataLength), waitUntilDone: false)
			_lastProgressDate = Date()
		}

		// Same (background) run loop the archiver was started on.
		archiver.continueReading()
	}

	override func tcpSocketDidSendData(_ tcpSocket: UMTCPSocket) {
		// No-op: driven by `fileArchiver` callback.
	}

	func fileArchiverDidCompleteReading(_ archiver: TPFileArchiver) {
		_sentDataLength = _progressTotalDataLength
		self.performSelector(onMainThread: #selector(_notifyProgress(_:)), with: NSNumber(value: _sentDataLength), waitUntilDone: false)
		_archiveFinished = true
		self.performSelector(onMainThread: #selector(_senderDataTransferCompleted), with: nil, waitUntilDone: false)
	}
}

// MARK: - Incoming Pasteboard File Transfer

class TPIncomingPasteboardFileTransfer: TPIncomingTransfer {
	override var shouldBufferIncomingData: Bool {
		return false
	}

	private var _representedFiles: [TPFileRepresentation]?
	private var _unarchiver: TPFileUnarchiver?
	private var _didLogArchiveHeader: Bool = false
	private var _didApplyPasteboard = false

	var shouldBeEncrypted: Bool {
		return true
	}

	override var requireTrustedHost: Bool {
		return true
	}

	override var priority: TransferPriority {
		return .high
	}

	override var hasFeedback: Bool {
		return true
	}

	override var completionMessage: String {
		let size = _progressTotalDataLength > 0 ? _progressTotalDataLength : _receivedDataLength
let sizeString = String.sizeString(for: size)
		return String(format: NSLocalizedString("File received (%@)", comment: ""), sizeString)
	}

	override var errorMessage: String {
		return NSLocalizedString("File not received", comment: "")
	}

	private func _temporaryDestinationPath() -> String {
		let tempDir = NSTemporaryDirectory() as NSString
		return (tempDir.appendingPathComponent("unimacs-pasteboard-files") as NSString).appendingPathComponent(self.uid)
	}

	override func prepareToReceiveData(withInfoDict infoDict: [AnyHashable : Any], from host: RemoteHost, onPort port: inout Int32, delegate: Any) -> Bool {
		if let representedFiles = infoDict[TPFileTransferRepresentedFilesKey] as? [[AnyHashable: Any]] {
			_representedFiles = representedFiles.compactMap { TPFileRepresentation(dictionary: $0) }
		} else {
			_representedFiles = nil
		}

		let destPath = self._temporaryDestinationPath()
		do {
			try FileManager.default.createDirectory(atPath: destPath, withIntermediateDirectories: true, attributes: nil)
		} catch {
			warningLog("Failed to create temp dir: \(destPath)", module: .transfer)
			return false
		}

		_unarchiver = TPFileUnarchiver(forWritingAtPath: destPath)
		_unarchiver?.startWriting()

		let ok = super.prepareToReceiveData(withInfoDict: infoDict, from: host, onPort: &port, delegate: delegate)
		if !ok {
			_unarchiver?.close()
			_unarchiver = nil
			try? FileManager.default.removeItem(atPath: destPath)
		}
		return ok
	}

	private func _logArchiveHeaderIfNeeded(_ data: Data) {
		// Archive header logging removed - not needed in production
	}

	override func _receivedData(_ data: Data) {
		_logArchiveHeaderIfNeeded(data)
		_receivedDataLength &+= UInt64(data.count)
		_unarchiver?.write(data)
	}

	override func _prepareReceivedDataBeforeCompletion() {
		_unarchiver?.close()
		_unarchiver = nil

		let destPath = self._temporaryDestinationPath()
		var urls = [URL]()
		if let files = _representedFiles, !files.isEmpty {
			for file in files {
				let path = (destPath as NSString).appendingPathComponent(file.name)
				if FileManager.default.fileExists(atPath: path) {
					urls.append(URL(fileURLWithPath: path))
				}
			}
		}

		guard !urls.isEmpty else { return }

		PasteboardAccess.sync {
			let pasteboard = NSPasteboard.general
			pasteboard.clearContents()

			let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
			let markerType = NSPasteboard.PasteboardType(Bundle.main.bundleIdentifier ?? "unimacs")

			pasteboard.declareTypes([filenamesType, markerType], owner: nil)
			pasteboard.setPropertyList(urls.map { $0.path }, forType: filenamesType)
			pasteboard.setData(Data([1]), forType: markerType)
		}

		cleanupOldFiles(keeping: destPath)
		_didApplyPasteboard = true
	}

	override func _receiverDataTransferCompleted() {
		if _didApplyPasteboard {
			TPClipboardTransferCoordinator.shared.didApplyIncomingPasteboard()
		}
		super._receiverDataTransferCompleted()
	}

	private func cleanupOldFiles(keeping currentPath: String) {
		let tempDir = NSTemporaryDirectory() as NSString
		let baseDir = tempDir.appendingPathComponent("unimacs-pasteboard-files")
		
		// Ensure baseDir exists and is a directory
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: baseDir, isDirectory: &isDirectory), isDirectory.boolValue else {
			return
		}
		
		do {
			let contents = try FileManager.default.contentsOfDirectory(atPath: baseDir)
			for item in contents {
				let itemPath = (baseDir as NSString).appendingPathComponent(item)
				// Skip the current transfer's directory
				if itemPath == currentPath { continue }
				
				// Try to remove other directories
				try? FileManager.default.removeItem(atPath: itemPath)
			}
		} catch {
			warningLog("Failed to cleanup old pasteboard files: \(error)", module: .transfer)
		}
	}
}
