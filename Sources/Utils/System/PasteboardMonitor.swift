// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import os
import CryptoKit

@objc protocol PasteboardMonitorDelegate: NSObjectProtocol {
	func pasteboardMonitorDidDetectExternalChange(_ monitor: PasteboardMonitor)
}

// MARK: - Content Hash for Deduplication

private struct PasteboardContentHash: Hashable {
    let textHash: String?
    let filePathsHash: String?
    let imageHash: String?
    let changeCount: Int
    
    init(from pasteboard: NSPasteboard) {
        self.changeCount = pasteboard.changeCount
        
        // Hash text content
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            self.textHash = SHA256.hash(data: Data(text.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        } else {
            self.textHash = nil
        }
        
        // Hash file paths
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.filter { $0.isFileURL }.map { $0.path }.sorted()
            let pathsString = paths.joined(separator: "|")
            self.filePathsHash = SHA256.hash(data: Data(pathsString.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        } else {
            self.filePathsHash = nil
        }
        
        // Hash image data (sample approach - could be optimized further)
        if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            // Only hash first 1KB for performance
            let sampleData = imageData.prefix(1024)
            self.imageHash = SHA256.hash(data: sampleData).compactMap { String(format: "%02x", $0) }.joined()
        } else {
            self.imageHash = nil
        }
    }
}

// MARK: - Optimized Pasteboard Monitor

@objcMembers
class PasteboardMonitor: NSObject {

	weak var delegate: PasteboardMonitorDelegate?

    static let shared = PasteboardMonitor()

    // MARK: - Properties
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var lastContentHash: PasteboardContentHash?
    
    // Monitoring strategy
    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var applicationObserver: NSObjectProtocol?
    
    // Performance optimization
    private let monitoringQueue = DispatchQueue(label: "com.teleport.pasteboard.monitor", qos: .utility)
    private var isActivelyMonitoring = false
    private var adaptiveInterval: TimeInterval = 0.5
    
    // Set this to true to ignore copies made by your own app
    var ignoreOwnAppCopies = true
    
    // Content deduplication
    private var contentHistory: Set<PasteboardContentHash> = []
    private let maxHistorySize = 10

	override init() {
        self.lastChangeCount = pasteboard.changeCount
        self.lastContentHash = PasteboardContentHash(from: pasteboard)
        super.init()
        setupSystemNotifications()
        debugLog("Pasteboard Monitor Initialized. ChangeCount: \(lastChangeCount)", module: .clipboard)
    }
    
    deinit {
        stop()
        removeSystemNotifications()
    }

    // MARK: - System Notifications Setup
    
    private func setupSystemNotifications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        
        // Monitor app activation to adjust monitoring frequency
        workspaceObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleApplicationActivation(notification)
        }
        
        // Monitor app deactivation
        applicationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.adjustMonitoringFrequency(isActive: false)
        }
    }
    
    private func removeSystemNotifications() {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        
        if let observer = applicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            applicationObserver = nil
        }
    }
    
    private func handleApplicationActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        
        // Increase monitoring frequency for apps that commonly use clipboard
        let clipboardIntensiveApps = [
            "com.apple.finder",
            "com.microsoft.Word",
            "com.microsoft.Excel",
            "com.apple.TextEdit",
            "com.apple.dt.Xcode",
            "com.sublimetext.4",
            "com.github.atom"
        ]
        
        let isClipboardIntensive = clipboardIntensiveApps.contains(app.bundleIdentifier ?? "")
        adjustMonitoringFrequency(isActive: isClipboardIntensive)
    }
    
    private func adjustMonitoringFrequency(isActive: Bool) {
        adaptiveInterval = isActive ? 0.2 : 0.8  // Fast: 200ms, Slow: 800ms
        
        if timer != nil {
            stop()
            start()  // Restart with new interval
        }
    }

    // MARK: - Public Interface
    func start() {
        guard timer == nil else { return }
        
        isActivelyMonitoring = true
        
        timer = Timer.scheduledTimer(withTimeInterval: adaptiveInterval, repeats: true) { [weak self] _ in
            self?.monitoringQueue.async {
                self?.pollPasteboard()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isActivelyMonitoring = false
    }
    
    // MARK: - Smart Detection with Deduplication

    private func pollPasteboard() {
        // Quick check: if change count hasn't changed, skip expensive operations
        guard pasteboard.changeCount != lastChangeCount else { return }
        
        // Create content hash for deduplication
        let currentContentHash = PasteboardContentHash(from: pasteboard)
        
        // Check if we've seen this exact content recently
        if contentHistory.contains(currentContentHash) {
            lastChangeCount = pasteboard.changeCount
            return
        }
        
        // Check if this is our own app's content
        if ignoreOwnAppCopies && isOwnAppContent() {
            lastChangeCount = pasteboard.changeCount
            return
        }
        
        // Update tracking variables
        lastChangeCount = pasteboard.changeCount
        lastContentHash = currentContentHash
        
        // Add to history and maintain size limit
        contentHistory.insert(currentContentHash)
        if contentHistory.count > maxHistorySize {
            // Remove oldest entries (this is approximate since Set doesn't maintain order)
            let excess = contentHistory.count - maxHistorySize
            for _ in 0..<excess {
                contentHistory.remove(contentHistory.first!)
            }
        }
        
        // Notify delegate on main queue
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.pasteboardMonitorDidDetectExternalChange(self)
        }
    }
    
    private func isOwnAppContent() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        
        // Check for our custom marker type
        let customType = NSPasteboard.PasteboardType(bundleID)
        if pasteboard.types?.contains(customType) == true {
            return true
        }
        
        // Additional heuristic: check if we're the frontmost app and content changed very recently
        // NSApplication.shared.isActive must be called on main thread
        var isAppActive = false
        if Thread.isMainThread {
            isAppActive = NSApplication.shared.isActive
        } else {
            DispatchQueue.main.sync {
                isAppActive = NSApplication.shared.isActive
            }
        }
        
        if isAppActive {
            let timeSinceLastChange = Date().timeIntervalSince1970 - Double(lastChangeCount) * 0.001
            if timeSinceLastChange < 0.1 { // Less than 100ms ago
                return true
            }
        }
        
        return false
    }
   
    // MARK: - Public Utilities
    
    /// Force an immediate check (useful for testing or manual triggers)
    func forceCheck() {
        monitoringQueue.async { [weak self] in
            self?.pollPasteboard()
        }
    }
    
    /// Clear content history (useful when switching contexts)
    func clearHistory() {
        contentHistory.removeAll()
    }
    
    /// Get current monitoring statistics
    var monitoringStats: [String: Any] {
        return [
            "isActive": isActivelyMonitoring,
            "interval": adaptiveInterval,
            "historySize": contentHistory.count,
            "lastChangeCount": lastChangeCount
        ]
    }
}

// MARK: - Clipboard transfer optimization

@objcMembers
final class TPClipboardTransferCoordinator: NSObject, PasteboardMonitorDelegate {
	static let shared = TPClipboardTransferCoordinator()

	private enum Mode {
		case idleRecording
		case connectingToControl
		case controllingRemote
		case controlledByRemote
	}

	private var mode: Mode = .idleRecording
	private var pasteboardDirtySinceBaseline: Bool = false
	/// Pasteboard snapshot at control-session boundaries; used when polling misses a copy.
	private var sessionBaselineHash: PasteboardContentHash?
    
    // Performance optimization
    private var lastTransferHash: PasteboardContentHash?

	func start() {
		let monitor = PasteboardMonitor.shared
        monitor.delegate = self
        
        // Start with optimized monitoring
        monitor.start()
        
		resetBaselineAndStartRecording()
	}

	func resetBaselineAndStartRecording() {
		pasteboardDirtySinceBaseline = false
		sessionBaselineHash = nil
		mode = .idleRecording
        
        // Clear history when resetting to avoid false positives
        PasteboardMonitor.shared.clearHistory()
        
        // Reset transfer tracking
        lastTransferHash = PasteboardContentHash(from: NSPasteboard.general)
	}

	// MARK: - PasteboardMonitorDelegate

	func pasteboardMonitorDidDetectExternalChange(_ monitor: PasteboardMonitor) {
        // Create hash to avoid duplicate transfers
        let currentHash = PasteboardContentHash(from: NSPasteboard.general)
        
        // Skip if this is the same content we just transferred
        if let lastHash = lastTransferHash, lastHash == currentHash {
            return
        }
        
		switch mode {
		case .idleRecording, .connectingToControl, .controlledByRemote:
			pasteboardDirtySinceBaseline = true
		case .controllingRemote:
			// While controlling a remote host, local pasteboard changes are usually unrelated.
			break
		}
	}

	// MARK: - Client side (this Mac controls remote)

	func clientWillRequestStartControl() {
		mode = .connectingToControl
		sessionBaselineHash = PasteboardContentHash(from: NSPasteboard.general)
	}

	func clientDidStartControl(using connection: NetworkConnection, remoteHost: TPRemoteHost) {
		mode = .controllingRemote
		schedulePasteboardSendIfNeeded(using: connection)
	}

	func clientDidStopControl() {
		resetBaselineAndStartRecording()
	}

	/// Called after an incoming (remote) pasteboard has been written to a local pasteboard.
	/// Writing a remote clipboard is not a local user change, so we re-baseline against the
	/// just-written content. Without this, the next stop/start boundary sees the synced content
	/// as "dirty" and echoes it straight back to the sender (clipboard round-trip bug).
	func didApplyIncomingPasteboard() {
		let hash = PasteboardContentHash(from: NSPasteboard.general)
		sessionBaselineHash = hash
		lastTransferHash = hash
		pasteboardDirtySinceBaseline = false
		PasteboardMonitor.shared.clearHistory()
	}

	// MARK: - Server side (this Mac is controlled by remote)

	func serverDidStartBeingControlled() {
		mode = .controlledByRemote
		pasteboardDirtySinceBaseline = false
		sessionBaselineHash = PasteboardContentHash(from: NSPasteboard.general)
	}

	/// Called when the server initiates stop (hot border). Matches legacy `beginTransfers` before `controlStop`.
	func serverRequestStopControl(using connection: NetworkConnection) {
		sendPasteboardOnStopIfNeeded(using: connection)
	}

	func serverWillStopBeingControlled(using connection: NetworkConnection) {
		sendPasteboardOnStopIfNeeded(using: connection)
		resetBaselineAndStartRecording()
	}

	// MARK: - Transfer building

	private func schedulePasteboardSendIfNeeded(using connection: NetworkConnection) {
		guard shouldSendPasteboardSinceSessionBaseline() else { return }
		debugLog("Scheduling start pasteboard send", module: .clipboard)
		// Yield so event-tap setup in the same run-loop turn can finish first.
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			guard self.mode == .controllingRemote else { return }
			guard self.shouldSendPasteboardSinceSessionBaseline() else { return }
			self.sendPasteboardIfNeeded(using: connection)
			self.pasteboardDirtySinceBaseline = false
			self.sessionBaselineHash = PasteboardContentHash(from: NSPasteboard.general)
		}
	}

	private func sendPasteboardOnStopIfNeeded(using connection: NetworkConnection) {
		guard mode == .controlledByRemote else { return }
		// Stop-time sync must not rely on dirty polling alone: compare against the session
		// baseline captured in serverDidStartBeingControlled (legacy beginTransfers read live pasteboard).
		guard shouldSendPasteboardSinceSessionBaseline() else {
			debugLog("Skip stop pasteboard send: unchanged since session baseline", module: .clipboard)
			return
		}
		debugLog("Sending pasteboard on stop control", module: .clipboard)
		sendPasteboardIfNeeded(using: connection)
		pasteboardDirtySinceBaseline = false
		sessionBaselineHash = PasteboardContentHash(from: NSPasteboard.general)
	}

	private func shouldSendPasteboardSinceSessionBaseline() -> Bool {
		if pasteboardDirtySinceBaseline {
			return true
		}
		let current = PasteboardContentHash(from: NSPasteboard.general)
		if let baseline = sessionBaselineHash, current != baseline {
			return true
		}
		return false
	}

	private func sendPasteboardIfNeeded(using connection: NetworkConnection) {
		let pasteboard = NSPasteboard.general
        
        // Update transfer hash to prevent loops
        lastTransferHash = PasteboardContentHash(from: pasteboard)
        
		let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
		let filePaths = fileURLs.filter { $0.isFileURL }.map { $0.path }

		if !filePaths.isEmpty {
            debugLog("Sending file pasteboard: \(filePaths.count) files", module: .clipboard)
			let filePasteTransfer = TPOutgoingPasteboardFileTransfer.shared() as! TPOutgoingPasteboardFileTransfer
			filePasteTransfer.setFilePaths(filePaths)
			TPTransfersManager.shared.beginTransfer(filePasteTransfer, using: connection)
		} else {
            debugLog("Sending general pasteboard", module: .clipboard)
			let generalPasteboardTransfer = TPOutgoingPasteboardTransfer.shared()
			TPTransfersManager.shared.beginTransfer(generalPasteboardTransfer, using: connection)
		}

		// Only sync find pasteboard if it has content
		let findPasteboard = NSPasteboard(name: .find)
		if let findString = findPasteboard.string(forType: .string), !findString.isEmpty {
			let findPasteboardTransfer = TPOutgoingPasteboardTransfer.shared()
			findPasteboardTransfer.setPasteboardName(NSPasteboard.Name.find.rawValue)
			TPTransfersManager.shared.beginTransfer(findPasteboardTransfer, using: connection)
		}
	}
    
    // MARK: - Public Utilities
    
    /// Get current coordinator statistics
    var coordinatorStats: [String: Any] {
        return [
            "mode": String(describing: mode),
            "isDirty": pasteboardDirtySinceBaseline,
            "hasTransferHash": lastTransferHash != nil,
            "monitorStats": PasteboardMonitor.shared.monitoringStats
        ]
    }
}

