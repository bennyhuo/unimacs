// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

// MARK: - Constants

let FileTransferRepresentedFilesKey = "FileTransferRepresentedFiles"
let FileArchiverNameKey = "FileArchiverName"
let FileArchiverTypeKey = "FileArchiverType"

// MARK: - Tar Size Estimation

private func estimateUncompressedTarSize(forPaths paths: [String]) -> UInt64 {
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

private struct FileRepresentation {
	let name: String
	let fileType: String?

	init?(dictionary: [AnyHashable: Any]) {
		guard let name = dictionary[FileArchiverNameKey] as? String else {
			return nil
		}
		self.name = name
		self.fileType = dictionary[FileArchiverTypeKey] as? String
	}
}

// MARK: - File Archiver

protocol FileArchiverDelegate: AnyObject {
	func fileArchiver(_ archiver: FileArchiver, hasDataAvailable data: Data)
	func fileArchiverDidCompleteReading(_ archiver: FileArchiver)
}

@objcMembers
final class FileArchiver: NSObject {
	private weak var delegate: FileArchiverDelegate?
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

	init(forReadingFilesAtPaths paths: [String], delegate: FileArchiverDelegate) {
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

	var representedFiles: [NSDictionary] {
		var representedFiles: [NSDictionary] = []
		for path in paths {
			let name = (path as NSString).lastPathComponent
			let type = (try? NSWorkspace.shared.type(ofFile: path)) ?? "public.data"
			let dict: NSDictionary = [
				FileArchiverNameKey: name,
				FileArchiverTypeKey: type
			]
			representedFiles.append(dict)
		}
		return representedFiles
	}

	func startReading() {
		do {
			try readTask.run()
		} catch {
			NSLog("[FileArchiver] Failed to launch tar: %@", String(describing: error))
			delegate?.fileArchiverDidCompleteReading(self)
			return
		}
		readFileHandle.readInBackgroundAndNotify()
		readErrorFileHandle.readInBackgroundAndNotify()
	}

	func continueReading() {
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
				NSLog("[FileArchiver] tar exited with status %d", status)
			}
			delegate?.fileArchiverDidCompleteReading(self)
		}
	}

	@objc private func errorFileHandleDidReadData(_ notification: Notification) {
		guard let data = notification.userInfo?[NSFileHandleNotificationDataItem] as? Data, !data.isEmpty else {
			return
		}
		if let str = String(data: data, encoding: .utf8), !str.isEmpty {
			NSLog("[FileArchiver][tar stderr] %@", str)
		}
		readErrorFileHandle.readInBackgroundAndNotify()
	}
}

// MARK: - File Unarchiver

@objcMembers
final class FileUnarchiver: NSObject {
	private let writePipe = Pipe()
	private let writeErrorPipe = Pipe()
	private let writeTask = Process()

	private lazy var writeFileHandle: FileHandle = writePipe.fileHandleForWriting
	private lazy var writeErrorFileHandle: FileHandle = writeErrorPipe.fileHandleForReading

	private let path: String

	init(forWritingAtPath path: String) {
		self.path = path
		super.init()

		writeTask.executableURL = URL(fileURLWithPath: FileArchiver.tarPath)
		writeTask.arguments = ["x", "--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags", "-C", path]
		writeTask.environment = FileArchiver.environment()
		writeTask.standardInput = writePipe
		writeTask.standardError = writeErrorPipe

		NotificationCenter.default.addObserver(self, selector: #selector(writeErrorFileHandleDidReadData(_:)), name: FileHandle.readCompletionNotification, object: writeErrorFileHandle)
	}

	func startWriting() {
		do {
			try writeTask.run()
		} catch {
			NSLog("[FileUnarchiver] Failed to launch tar: %@", String(describing: error))
			return
		}
		writeErrorFileHandle.readInBackgroundAndNotify()
	}

	func close() {
		writeFileHandle.closeFile()
		writeTask.waitUntilExit()
		let status = writeTask.terminationStatus
		if status != 0 {
			NSLog("[FileUnarchiver] tar exited with status %d", status)
		}
	}

	func writeData(_ data: Data) {
		writeFileHandle.write(data)
	}

	func write(_ data: Data) {
		writeData(data)
	}

	@objc private func writeErrorFileHandleDidReadData(_ notification: Notification) {
		guard let data = notification.userInfo?[NSFileHandleNotificationDataItem] as? Data, !data.isEmpty else {
			return
		}
		if let str = String(data: data, encoding: .utf8), !str.isEmpty {
			NSLog("[FileUnarchiver][tar stderr] %@", str)
		}
		writeErrorFileHandle.readInBackgroundAndNotify()
	}
}

// MARK: - Outgoing Pasteboard File Transfer

private let archiveProgressRefreshRate: TimeInterval = 0.1

class OutgoingPasteboardFileTransfer: OutgoingTransfer, FileArchiverDelegate {
	private var _archiver: FileArchiver?
	private var _filePaths: [String] = []
	private var _lastProgressDate: Date = .distantPast
	private var _didLogArchiveHeader: Bool = false
	private var _archiveFinished: Bool = false

	override var type: String {
		return "IncomingPasteboardFileTransfer"
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
		_archiver = FileArchiver(forReadingFilesAtPaths: filePaths, delegate: self)
	}

	override func infoDict() -> [AnyHashable: Any] {
		var infoDict = super.infoDict()
		if let archiver = _archiver {
			infoDict[FileTransferRepresentedFilesKey] = archiver.representedFiles
		}
		return infoDict
	}

	override func prepareToSendData() -> Bool {
		guard _archiver != nil, !_filePaths.isEmpty else { return false }

		_totalDataLength = 0
		_progressTotalDataLength = estimateUncompressedTarSize(forPaths: _filePaths)
		_sentDataLength = 0
		_lastProgressDate = .distantPast
		return true
	}

	override func _beginTransfer() {
		// Drive tar reading and channel writes on a dedicated background thread so a large
		// file transfer never blocks input/UI on the main thread.
		manager?.transfer(self, didProgress: 0.0)
		_lastProgressDate = Date()
		_archiveFinished = false
		Thread.detachNewThreadSelector(#selector(_archiveThread), toTarget: self, with: nil)
	}

	@objc private func _archiveThread() {
		autoreleasepool {
			_archiver?.startReading()
			// Pump this thread's run loop so the archiver's background-read notifications
			// are delivered here instead of on the main thread.
			while !_archiveFinished {
				CFRunLoopRunInMode(.defaultMode, 0.1, true)
			}
		}
	}

	func fileArchiver(_ archiver: FileArchiver, hasDataAvailable data: Data) {
		let sent = _channel?.send(data) ?? false
		if !sent {
			_archiveFinished = true
			self.performSelector(onMainThread: #selector(_senderDataTransferAborted), with: nil, waitUntilDone: false)
			return
		}

		_sentDataLength &+= UInt64(data.count)
		if abs(_lastProgressDate.timeIntervalSinceNow) >= archiveProgressRefreshRate {
			self.performSelector(onMainThread: #selector(_notifyProgress(_:)), with: NSNumber(value: _sentDataLength), waitUntilDone: false)
			_lastProgressDate = Date()
		}

		// Same (background) run loop the archiver was started on.
		archiver.continueReading()
	}

	func fileArchiverDidCompleteReading(_ archiver: FileArchiver) {
		_sentDataLength = _progressTotalDataLength
		self.performSelector(onMainThread: #selector(_notifyProgress(_:)), with: NSNumber(value: _sentDataLength), waitUntilDone: false)
		_archiveFinished = true
		self.performSelector(onMainThread: #selector(_senderDataTransferCompleted), with: nil, waitUntilDone: false)
	}
}

// MARK: - Incoming Pasteboard File Transfer

class IncomingPasteboardFileTransfer: IncomingTransfer {
	override var shouldBufferIncomingData: Bool {
		return false
	}

	private var _representedFiles: [FileRepresentation]?
	private var _unarchiver: FileUnarchiver?
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
		if let representedFiles = infoDict[FileTransferRepresentedFilesKey] as? [[AnyHashable: Any]] {
			_representedFiles = representedFiles.compactMap { FileRepresentation(dictionary: $0) }
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

		_unarchiver = FileUnarchiver(forWritingAtPath: destPath)
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
		_lock.lock()
		_receivedDataLength &+= UInt64(data.count)
		let currentReceived = _receivedDataLength
		let total = _totalDataLength
		_lock.unlock()
		_unarchiver?.write(data)
		_reportReceiveProgressIfNeeded(currentReceived: currentReceived, total: total)
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
			ClipboardTransferCoordinator.shared.didApplyIncomingPasteboard()
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
