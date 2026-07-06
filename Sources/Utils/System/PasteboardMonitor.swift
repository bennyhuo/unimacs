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
    private var appActivateObserver: NSObjectProtocol?
    private var appDeactivateObserver: NSObjectProtocol?
    private var isAppActive = false
    
    // Performance optimization
    private let monitoringQueue = DispatchQueue(label: "com.teleport.pasteboard.monitor", qos: .utility)
    private var isActivelyMonitoring = false
    private var adaptiveInterval: TimeInterval = 0.5
    private var aggressiveMonitoring = false
    private static let defaultInterval: TimeInterval = 0.5
    private static let aggressiveInterval: TimeInterval = 0.1
    
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
        
        if Thread.isMainThread {
            self.isAppActive = NSApplication.shared.isActive
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let active = NSApplication.shared.isActive
                self.monitoringQueue.async {
                    self.isAppActive = active
                }
            }
        }
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
        
        // Monitor local app activation/deactivation to update cache without blocking on main thread sync
        let defaultCenter = NotificationCenter.default
        appActivateObserver = defaultCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateAppActiveState(isActive: true)
        }
        
        appDeactivateObserver = defaultCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateAppActiveState(isActive: false)
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
        
        if let observer = appActivateObserver {
            NotificationCenter.default.removeObserver(observer)
            appActivateObserver = nil
        }
        
        if let observer = appDeactivateObserver {
            NotificationCenter.default.removeObserver(observer)
            appDeactivateObserver = nil
        }
    }
    
    private func updateAppActiveState(isActive: Bool) {
        monitoringQueue.async { [weak self] in
            self?.isAppActive = isActive
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
        guard !aggressiveMonitoring else { return }
        adaptiveInterval = isActive ? 0.2 : 0.8  // Fast: 200ms, Slow: 800ms
        restartTimerIfNeeded()
    }

    private func restartTimerIfNeeded() {
        guard timer != nil else { return }
        stop()
        start()
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

    /// Poll synchronously so control-boundary clipboard sync sees the latest pasteboard state.
    func syncPoll() {
        monitoringQueue.sync { [weak self] in
            self?.pollPasteboard()
        }
    }

    /// Short-lived fast polling around control start/stop where copy-then-switch is common.
    func setAggressiveMonitoring(_ enabled: Bool) {
        let apply = { [weak self] in
            guard let self else { return }
            guard self.aggressiveMonitoring != enabled else { return }
            self.aggressiveMonitoring = enabled
            self.adaptiveInterval = enabled ? Self.aggressiveInterval : Self.defaultInterval
            self.restartTimerIfNeeded()
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
    
    /// Clear content history (useful when switching contexts)
    func clearHistory() {
        monitoringQueue.async { [weak self] in
            self?.contentHistory.removeAll()
        }
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

	/// Captured when a boundary sync starts so retries still work after mode resets.
	private struct BoundarySendContext {
		let connection: NetworkConnection
		let baseline: PasteboardContentHash?
		let generation: UInt
	}

	private var boundarySendGeneration: UInt = 0
	private var boundarySendCompletedGeneration: UInt?
	private var activeBoundaryContext: BoundarySendContext?
	private static let boundaryRetryDelays: [TimeInterval] = [0.08, 0.2, 0.45]

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
		PasteboardMonitor.shared.setAggressiveMonitoring(false)
        
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
		PasteboardMonitor.shared.syncPoll()
		sessionBaselineHash = PasteboardContentHash(from: NSPasteboard.general)
		PasteboardMonitor.shared.setAggressiveMonitoring(true)
	}

	func clientDidStartControl(using connection: NetworkConnection, remoteHost: TPRemoteHost) {
		mode = .controllingRemote
		scheduleBoundaryPasteboardSend(using: connection, reason: "start control")
	}

	func clientDidStopControl() {
		cancelBoundaryPasteboardSend()
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
		PasteboardMonitor.shared.syncPoll()
		sessionBaselineHash = PasteboardContentHash(from: NSPasteboard.general)
		PasteboardMonitor.shared.setAggressiveMonitoring(true)
	}

	/// Called when the server initiates stop (hot border). Matches legacy `beginTransfers` before `controlStop`.
	func serverRequestStopControl(using connection: NetworkConnection) {
		scheduleBoundaryPasteboardSend(using: connection, reason: "stop control")
	}

	func serverWillStopBeingControlled(using connection: NetworkConnection) {
		// Client-initiated stop does not go through serverRequestStopControl; still sync clipboard.
		if activeBoundaryContext == nil {
			scheduleBoundaryPasteboardSend(using: connection, reason: "stop control (client initiated)")
		}
		resetBaselineAndStartRecording()
	}

	// MARK: - Transfer building

	private func cancelBoundaryPasteboardSend() {
		boundarySendGeneration &+= 1
		activeBoundaryContext = nil
		boundarySendCompletedGeneration = nil
	}

	/// Always schedule boundary sync with short retries. Some apps update changeCount before
	/// payload data is readable; an immediate read at control start/stop can miss a fast copy.
	private func scheduleBoundaryPasteboardSend(using connection: NetworkConnection, reason: String) {
		boundarySendGeneration &+= 1
		let generation = boundarySendGeneration
		boundarySendCompletedGeneration = nil
		activeBoundaryContext = BoundarySendContext(
			connection: connection,
			baseline: sessionBaselineHash,
			generation: generation
		)

		debugLog("Scheduling boundary pasteboard send (\(reason))", module: .clipboard)
		PasteboardMonitor.shared.setAggressiveMonitoring(true)

		// Yield one run-loop turn so event-tap setup can finish before the first read.
		DispatchQueue.main.async { [weak self] in
			self?.performBoundaryPasteboardSendAttempt()
		}
		for delay in Self.boundaryRetryDelays {
			DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
				self?.performBoundaryPasteboardSendAttempt()
			}
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
			guard let self, generation == self.boundarySendGeneration else { return }
			self.activeBoundaryContext = nil
			if self.mode == .idleRecording {
				PasteboardMonitor.shared.setAggressiveMonitoring(false)
			}
		}
	}

	private func performBoundaryPasteboardSendAttempt() {
		guard let context = activeBoundaryContext,
			  context.generation == boundarySendGeneration,
			  boundarySendCompletedGeneration != context.generation else {
			return
		}

		PasteboardMonitor.shared.syncPoll()

		guard shouldSendPasteboard(since: context.baseline) else {
			return
		}
		guard pasteboardHasTransferableContent() else {
			debugLog("Deferring boundary pasteboard send: content not ready yet", module: .clipboard)
			return
		}

		debugLog("Sending pasteboard at control boundary", module: .clipboard)
		sendPasteboardIfNeeded(using: context.connection)
		boundarySendCompletedGeneration = context.generation
		pasteboardDirtySinceBaseline = false
		sessionBaselineHash = PasteboardContentHash(from: NSPasteboard.general)
	}

	private func shouldSendPasteboard(since baseline: PasteboardContentHash?) -> Bool {
		if pasteboardDirtySinceBaseline {
			return true
		}
		let current = PasteboardContentHash(from: NSPasteboard.general)
		if let baseline, current != baseline {
			return true
		}
		return false
	}

	private func pasteboardHasTransferableContent() -> Bool {
		let pasteboard = NSPasteboard.general
		let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
		if !fileURLs.filter({ $0.isFileURL }).isEmpty {
			return true
		}

		for type in pasteboard.types ?? [] {
			let typeString = type.rawValue
			if TPTypeNeedsIgnoring(typeString) {
				continue
			}
			if let data = pasteboard.data(forType: type), !data.isEmpty {
				return true
			}
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

