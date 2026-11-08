// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import os

// MARK: - Metadata identity (no promised-data materialization)

/// Change detection / echo suppression identity.
/// Built only from `changeCount` + declared types so polling never waits on a promise.
struct PasteboardContentHash: Hashable {
	let changeCount: Int
	let types: [String]

	#if !STANDALONE_UNIT_TEST
	static func capture(from pasteboard: NSPasteboard = .general) -> PasteboardContentHash {
		let marker = Bundle.main.bundleIdentifier ?? "unimacs"
		let types = (pasteboard.types ?? [])
			.map(\.rawValue)
			.filter { $0 != marker && !pasteboardTypeNeedsIgnoring($0) }
			.sorted()
		return PasteboardContentHash(changeCount: pasteboard.changeCount, types: types)
	}
	#endif
}

#if !STANDALONE_UNIT_TEST
protocol PasteboardMonitorDelegate: AnyObject {
	func pasteboardMonitorDidDetectExternalChange(_ monitor: PasteboardMonitor, hash: PasteboardContentHash)
}

struct PasteboardSnapshot {
	let hash: PasteboardContentHash
	let hasDeclaredContent: Bool
	let hasFileURLs: Bool
	let findHasContent: Bool
	let filePaths: [String]

	static let fileTypeNames: Set<String> = [
		NSPasteboard.PasteboardType.fileURL.rawValue,
		"NSFilenamesPboardType",
		"public.file-url"
	]

	/// Metadata-only snapshot. Does not resolve promised pasteboard data.
	static func captureMetadata() -> PasteboardSnapshot {
		let general = NSPasteboard.general
		let hash = PasteboardContentHash.capture(from: general)
		let hasFiles = hash.types.contains { fileTypeNames.contains($0) }

		let find = NSPasteboard(name: .find)
		let findHasContent = (find.types ?? []).contains {
			$0 == .string || $0.rawValue == "public.utf8-plain-text"
		}

		return PasteboardSnapshot(
			hash: hash,
			hasDeclaredContent: !hash.types.isEmpty,
			hasFileURLs: hasFiles,
			findHasContent: findHasContent,
			filePaths: []
		)
	}

	/// Same as `captureMetadata()`, plus file URL resolution when file types are declared.
	/// `readObjects` can block on promises; call only on `PasteboardAccess` queue.
	static func captureForSend() -> PasteboardSnapshot {
		let snapshot = captureMetadata()
		guard snapshot.hasFileURLs else { return snapshot }

		let urls = (NSPasteboard.general.readObjects(
			forClasses: [NSURL.self],
			options: [.urlReadingFileURLsOnly: true]
		) as? [URL]) ?? []
		let paths = urls.filter(\.isFileURL).map(\.path)
		return PasteboardSnapshot(
			hash: snapshot.hash,
			hasDeclaredContent: snapshot.hasDeclaredContent || !paths.isEmpty,
			hasFileURLs: snapshot.hasFileURLs,
			findHasContent: snapshot.findHasContent,
			filePaths: paths
		)
	}
}

// MARK: - Pasteboard Monitor

class PasteboardMonitor: NSObject {

	weak var delegate: PasteboardMonitorDelegate?

	static let shared = PasteboardMonitor()

	private var lastChangeCount: Int = 0
	private var lastContentHash: PasteboardContentHash?

	private var timer: Timer?
	private var workspaceObserver: NSObjectProtocol?
	private var applicationObserver: NSObjectProtocol?
	private var appActivateObserver: NSObjectProtocol?
	private var appDeactivateObserver: NSObjectProtocol?
	private var isAppActive = false

	private var isActivelyMonitoring = false
	private var adaptiveInterval: TimeInterval = 0.5
	private var aggressiveMonitoring = false
	private static let defaultInterval: TimeInterval = 0.5
	private static let aggressiveInterval: TimeInterval = 0.1

	var ignoreOwnAppCopies = true

	private var contentHistory: Set<PasteboardContentHash> = []
	private let maxHistorySize = 10

	override init() {
		super.init()
		if Thread.isMainThread {
			isAppActive = NSApplication.shared.isActive
			setupSystemNotifications()
		} else {
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				self.isAppActive = NSApplication.shared.isActive
				self.setupSystemNotifications()
			}
		}
		PasteboardAccess.async { [weak self] in
			guard let self else { return }
			let hash = PasteboardContentHash.capture()
			self.lastChangeCount = hash.changeCount
			self.lastContentHash = hash
		}
		debugLog("Pasteboard Monitor Initialized", module: .clipboard)
	}

	deinit {
		stop()
		removeSystemNotifications()
	}

	// MARK: - System Notifications Setup

	private func setupSystemNotifications() {
		let notificationCenter = NSWorkspace.shared.notificationCenter

		workspaceObserver = notificationCenter.addObserver(
			forName: NSWorkspace.didActivateApplicationNotification,
			object: nil,
			queue: .main
		) { [weak self] notification in
			self?.handleApplicationActivation(notification)
		}

		applicationObserver = notificationCenter.addObserver(
			forName: NSWorkspace.didDeactivateApplicationNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?.adjustMonitoringFrequency(isActive: false)
		}

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
		runOnMainThread { [weak self] in
			self?.isAppActive = isActive
		}
	}

	private func handleApplicationActivation(_ notification: Notification) {
		guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
			return
		}

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
		adaptiveInterval = isActive ? 0.2 : 0.8
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

		runOnMainThread { [weak self] in
			guard let self = self, self.timer == nil else { return }
			self.timer = Timer.scheduledTimer(withTimeInterval: self.adaptiveInterval, repeats: true) { [weak self] _ in
				self?.schedulePoll()
			}
		}
	}

	func stop() {
		timer?.invalidate()
		timer = nil
		isActivelyMonitoring = false
	}

	private func schedulePoll() {
		PasteboardAccess.async { [weak self] in
			self?.pollPasteboard()
		}
	}

	/// Poll on the pasteboard queue and deliver a metadata snapshot to `completion` on main.
	func snapshot(completion: @escaping (PasteboardSnapshot) -> Void) {
		PasteboardAccess.async { [weak self] in
			let snapshot = PasteboardSnapshot.captureMetadata()
			if let self {
				self.lastChangeCount = snapshot.hash.changeCount
				self.lastContentHash = snapshot.hash
			}
			DispatchQueue.main.async {
				completion(snapshot)
			}
		}
	}

	/// Snapshot used at control boundaries. May resolve file-URL promises on the pasteboard queue.
	func snapshotForSend(completion: @escaping (PasteboardSnapshot) -> Void) {
		PasteboardAccess.async { [weak self] in
			let snapshot = PasteboardSnapshot.captureForSend()
			if let self {
				self.lastChangeCount = snapshot.hash.changeCount
				self.lastContentHash = snapshot.hash
			}
			DispatchQueue.main.async {
				completion(snapshot)
			}
		}
	}

	// MARK: - Detection

	private func pollPasteboard() {
		assert(PasteboardAccess.isOnQueue)

		let changeCount = NSPasteboard.general.changeCount
		guard changeCount != lastChangeCount else { return }

		if ignoreOwnAppCopies && isOwnAppContent() {
			lastChangeCount = changeCount
			lastContentHash = PasteboardContentHash.capture()
			return
		}

		let snapshot = PasteboardSnapshot.captureMetadata()
		if let lastContentHash, lastContentHash == snapshot.hash {
			lastChangeCount = changeCount
			return
		}

		if contentHistory.contains(snapshot.hash) {
			lastChangeCount = changeCount
			lastContentHash = snapshot.hash
			return
		}

		lastChangeCount = changeCount
		lastContentHash = snapshot.hash
		contentHistory.insert(snapshot.hash)
		if contentHistory.count > maxHistorySize {
			let excess = contentHistory.count - maxHistorySize
			for _ in 0..<excess {
				contentHistory.remove(contentHistory.first!)
			}
		}

		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self.delegate?.pasteboardMonitorDidDetectExternalChange(self, hash: snapshot.hash)
		}
	}

	private func isOwnAppContent() -> Bool {
		guard let bundleID = Bundle.main.bundleIdentifier else { return false }

		let customType = NSPasteboard.PasteboardType(bundleID)
		if NSPasteboard.general.types?.contains(customType) == true {
			return true
		}

		if isAppActive {
			let timeSinceLastChange = Date().timeIntervalSince1970 - Double(lastChangeCount) * 0.001
			if timeSinceLastChange < 0.1 {
				return true
			}
		}

		return false
	}

	// MARK: - Public Utilities

	func forceCheck() {
		schedulePoll()
	}

	func setAggressiveMonitoring(_ enabled: Bool) {
		runOnMainThread { [weak self] in
			guard let self else { return }
			guard self.aggressiveMonitoring != enabled else { return }
			self.aggressiveMonitoring = enabled
			self.adaptiveInterval = enabled ? Self.aggressiveInterval : Self.defaultInterval
			self.restartTimerIfNeeded()
		}
	}

	func clearHistory() {
		PasteboardAccess.async { [weak self] in
			self?.contentHistory.removeAll()
		}
	}

	var monitoringStats: [String: Any] {
		return [
			"isActive": isActivelyMonitoring,
			"interval": adaptiveInterval,
			"historySize": contentHistory.count,
			"lastChangeCount": lastChangeCount
		]
	}
}
#endif

// MARK: - Keyboard Shortcut Detection for Clipboard

enum ClipboardShortcutAction: Equatable {
	case copyOrCut
	case paste
}

enum ClipboardShortcutDetector {
	static let ansiKeyC: UInt16 = 0x08
	static let ansiKeyV: UInt16 = 0x09
	static let ansiKeyX: UInt16 = 0x07

	static func classify(
		keyCode: UInt16,
		commandDown: Bool,
		controlDown: Bool,
		isRepeat: Bool = false,
		charactersIgnoringModifiers: String? = nil
	) -> ClipboardShortcutAction? {
		guard !isRepeat, commandDown, !controlDown else {
			return nil
		}

		let normalizedChar = charactersIgnoringModifiers?.lowercased()
		if keyCode == ansiKeyV || normalizedChar == "v" {
			return .paste
		}
		if keyCode == ansiKeyC || keyCode == ansiKeyX || normalizedChar == "c" || normalizedChar == "x" {
			return .copyOrCut
		}
		return nil
	}

	static func classify(event: NSEvent) -> ClipboardShortcutAction? {
		guard event.type == .keyDown else { return nil }
		let flags = event.modifierFlags
		return classify(
			keyCode: event.keyCode,
			commandDown: flags.contains(.command),
			controlDown: flags.contains(.control),
			isRepeat: event.isARepeat,
			charactersIgnoringModifiers: event.charactersIgnoringModifiers
		)
	}

	static func classify(cgEvent: CGEvent) -> ClipboardShortcutAction? {
		guard cgEvent.type == .keyDown else { return nil }
		let isRepeat = cgEvent.getIntegerValueField(.keyboardEventAutorepeat) != 0
		let keyCode = UInt16(truncatingIfNeeded: cgEvent.getIntegerValueField(.keyboardEventKeycode))
		let flags = cgEvent.flags
		return classify(
			keyCode: keyCode,
			commandDown: flags.contains(.maskCommand),
			controlDown: flags.contains(.maskControl),
			isRepeat: isRepeat,
			charactersIgnoringModifiers: nil
		)
	}
}

// MARK: - Clipboard Transfer Policy State Machine

enum ClipboardControlMode: Equatable {
	case idleRecording
	case connectingToControl
	case controllingRemote
	case controlledByRemote
}

enum ClipboardSendDecision: Equatable {
	case noChange
	case send
	case skippedAfterLocalPaste
	case skippedExpired(elapsed: TimeInterval, timeout: TimeInterval)
}

struct ClipboardTransferPolicyState {
	private(set) var mode: ClipboardControlMode = .idleRecording
	private(set) var pasteboardDirtySinceBaseline: Bool = false
	/// Pasteboard snapshot at control-session boundaries; used when polling misses a copy.
	private(set) var sessionBaselineHash: PasteboardContentHash?
	private(set) var lastTransferHash: PasteboardContentHash?
	private(set) var lastChangedHash: PasteboardContentHash?
	private(set) var lastChangeTimestamp: Date?
	private(set) var consumedByLocalPasteHash: PasteboardContentHash?

	mutating func enterIdleMode() {
		mode = .idleRecording
	}

	mutating func resetBaseline(with hash: PasteboardContentHash?) {
		mode = .idleRecording
		pasteboardDirtySinceBaseline = false
		sessionBaselineHash = hash
		lastTransferHash = hash
		if let hash, lastChangedHash == hash {
			lastChangedHash = nil
			lastChangeTimestamp = nil
		}
	}

	mutating func applyIncomingPasteboard(hash: PasteboardContentHash) {
		sessionBaselineHash = hash
		lastTransferHash = hash
		pasteboardDirtySinceBaseline = false
		lastChangedHash = nil
		lastChangeTimestamp = nil
		consumedByLocalPasteHash = nil
	}

	mutating func beginConnectingToControl(currentHash: PasteboardContentHash?, now: Date) {
		mode = .connectingToControl
		guard let currentHash else { return }
		if sessionBaselineHash == nil {
			sessionBaselineHash = lastTransferHash ?? currentHash
		}
		if currentHash != lastTransferHash && currentHash != sessionBaselineHash {
			recordExternalChange(hash: currentHash, now: now)
		}
	}

	mutating func didStartControllingRemote() {
		mode = .controllingRemote
	}

	mutating func didStartBeingControlled(baselineHash: PasteboardContentHash?) {
		mode = .controlledByRemote
		pasteboardDirtySinceBaseline = false
		sessionBaselineHash = baselineHash
		lastChangedHash = nil
		lastChangeTimestamp = nil
		consumedByLocalPasteHash = nil
	}

	mutating func recordExternalChange(hash: PasteboardContentHash, now: Date) {
		if let lastHash = lastTransferHash, lastHash == hash {
			return
		}
		if lastChangedHash == hash {
			return
		}

		switch mode {
		case .idleRecording, .connectingToControl, .controlledByRemote:
			pasteboardDirtySinceBaseline = true
			lastChangedHash = hash
			lastChangeTimestamp = now
			if consumedByLocalPasteHash != hash {
				consumedByLocalPasteHash = nil
			}
		case .controllingRemote:
			break
		}
	}

	mutating func recordLocalPaste(currentHash: PasteboardContentHash, now: Date) {
		guard mode == .idleRecording || mode == .controlledByRemote else {
			return
		}
		guard !currentHash.types.isEmpty else {
			return
		}
		if currentHash != lastTransferHash && currentHash != sessionBaselineHash && lastChangedHash != currentHash {
			recordExternalChange(hash: currentHash, now: now)
		}
		consumedByLocalPasteHash = currentHash
	}

	mutating func evaluateBoundarySend(
		hash: PasteboardContentHash,
		baseline: PasteboardContentHash?,
		skipAfterLocalPaste: Bool,
		enableTimeout: Bool,
		timeoutInterval: TimeInterval,
		now: Date
	) -> ClipboardSendDecision {
		if let lastHash = lastTransferHash, lastHash == hash {
			return .noChange
		}

		let effectiveBaseline = baseline ?? sessionBaselineHash
		let hasChanged = pasteboardDirtySinceBaseline || (effectiveBaseline != nil && hash != effectiveBaseline)
		guard hasChanged else {
			return .noChange
		}

		if lastChangedHash != hash {
			lastChangedHash = hash
			lastChangeTimestamp = now
		}

		if skipAfterLocalPaste, consumedByLocalPasteHash == hash {
			return .skippedAfterLocalPaste
		}

		if enableTimeout, timeoutInterval > 0, let changeTime = lastChangeTimestamp {
			let elapsed = now.timeIntervalSince(changeTime)
			if elapsed > timeoutInterval {
				return .skippedExpired(elapsed: elapsed, timeout: timeoutInterval)
			}
		}

		return .send
	}

	mutating func markBoundaryHandled(hash: PasteboardContentHash) {
		lastTransferHash = hash
		sessionBaselineHash = hash
		pasteboardDirtySinceBaseline = false
	}
}

#if !STANDALONE_UNIT_TEST
// MARK: - Clipboard transfer optimization

@objcMembers
final class ClipboardTransferCoordinator: NSObject, PasteboardMonitorDelegate {
	static let shared = ClipboardTransferCoordinator()

	private var policyState = ClipboardTransferPolicyState()
	var isSwitchingControl: Bool = false

	var nowProvider: () -> Date = { Date() }
	var isSkipAfterLocalPasteEnabled: () -> Bool = {
		let prefs = PreferencesManager.shared()
		if prefs.value(forPref: Settings.skipClipboardAfterLocalPasteKey) == nil {
			return true
		}
		return prefs.bool(forPref: Settings.skipClipboardAfterLocalPasteKey)
	}
	var isClipboardTimeoutEnabled: () -> Bool = {
		let prefs = PreferencesManager.shared()
		if prefs.value(forPref: Settings.enableClipboardTimeoutKey) == nil {
			return true
		}
		return prefs.bool(forPref: Settings.enableClipboardTimeoutKey)
	}
	var clipboardTimeoutInterval: () -> TimeInterval = {
		let interval = TimeInterval(PreferencesManager.shared().float(forPref: Settings.clipboardTimeoutIntervalKey))
		guard interval > 0 else { return Settings.clipboardTimeoutIntervalDefault }
		return min(max(interval, Settings.clipboardTimeoutIntervalMin), Settings.clipboardTimeoutIntervalMax)
	}

	private struct BoundarySendContext {
		let connection: NetworkConnection
		let baseline: PasteboardContentHash?
		let generation: UInt
	}

	private var boundarySendGeneration: UInt = 0
	private var boundarySendCompletedGeneration: UInt?
	private var activeBoundaryContext: BoundarySendContext?
	private static let boundaryRetryDelays: [TimeInterval] = [0.08, 0.2, 0.45]

	private var globalKeyDownMonitor: Any?
	private var localKeyDownMonitor: Any?

	deinit {
		stopKeyMonitors()
	}

	func start() {
		let monitor = PasteboardMonitor.shared
		monitor.delegate = self
		monitor.start()
		startKeyMonitorsIfNeeded()
		resetBaselineAndStartRecording()
	}

	private func startKeyMonitorsIfNeeded() {
		runOnMainThread { [weak self] in
			guard let self else { return }
			if self.globalKeyDownMonitor == nil {
				self.globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
					guard let action = ClipboardShortcutDetector.classify(event: event) else { return }
					self?.handleDetectedShortcut(action)
				}
			}
			if self.localKeyDownMonitor == nil {
				self.localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
					if let action = ClipboardShortcutDetector.classify(event: event) {
						self?.handleDetectedShortcut(action)
					}
					return event
				}
			}
		}
	}

	private func stopKeyMonitors() {
		if let monitor = globalKeyDownMonitor {
			NSEvent.removeMonitor(monitor)
			globalKeyDownMonitor = nil
		}
		if let monitor = localKeyDownMonitor {
			NSEvent.removeMonitor(monitor)
			localKeyDownMonitor = nil
		}
	}

	func handleDetectedShortcut(_ action: ClipboardShortcutAction) {
		switch action {
		case .paste:
			recordLocalPasteEvent()
		case .copyOrCut:
			// Poll shortly after Cmd+C / Cmd+X so the copy timestamp is recorded accurately.
			for delay in [0.04, 0.12] {
				DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
					PasteboardMonitor.shared.forceCheck()
				}
			}
		}
	}

	func recordLocalPasteEvent() {
		guard policyState.mode == .idleRecording || policyState.mode == .controlledByRemote else {
			return
		}
		let pasteTime = nowProvider()
		PasteboardMonitor.shared.snapshot { [weak self] snapshot in
			guard let self else { return }
			self.policyState.recordLocalPaste(currentHash: snapshot.hash, now: pasteTime)
			debugLog("Recorded local paste for pasteboard changeCount=\(snapshot.hash.changeCount)", module: .clipboard)
		}
	}

	func resetBaselineAndStartRecording() {
		policyState.enterIdleMode()
		PasteboardMonitor.shared.setAggressiveMonitoring(false)
		isSwitchingControl = false
		guard activeBoundaryContext == nil else {
			return
		}
		PasteboardMonitor.shared.clearHistory()
		PasteboardMonitor.shared.snapshot { [weak self] snapshot in
			guard let self, self.activeBoundaryContext == nil else { return }
			self.policyState.resetBaseline(with: snapshot.hash)
		}
	}

	// MARK: - PasteboardMonitorDelegate

	func pasteboardMonitorDidDetectExternalChange(_ monitor: PasteboardMonitor, hash: PasteboardContentHash) {
		policyState.recordExternalChange(hash: hash, now: nowProvider())
	}

	// MARK: - Client side (this Mac controls remote)

	func clientWillRequestStartControl() {
		let now = nowProvider()
		policyState.beginConnectingToControl(currentHash: nil, now: now)
		PasteboardMonitor.shared.setAggressiveMonitoring(true)
		PasteboardMonitor.shared.snapshot { [weak self] snapshot in
			guard let self else { return }
			self.policyState.beginConnectingToControl(currentHash: snapshot.hash, now: self.nowProvider())
		}
	}

	func clientDidStartControl(using connection: NetworkConnection, remoteHost: RemoteHost) {
		policyState.didStartControllingRemote()
		if isSwitchingControl {
			isSwitchingControl = false
			debugLog("Skipping start control clipboard send due to SwitchControl", module: .clipboard)
		} else {
			scheduleBoundaryPasteboardSend(using: connection, reason: "start control")
		}
	}

	func clientDidStopControl() {
		cancelBoundaryPasteboardSend()
		resetBaselineAndStartRecording()
	}

	/// Called after an incoming (remote) pasteboard has been written to a local pasteboard.
	func didApplyIncomingPasteboard() {
		PasteboardMonitor.shared.clearHistory()
		PasteboardMonitor.shared.snapshot { [weak self] snapshot in
			guard let self else { return }
			self.policyState.applyIncomingPasteboard(hash: snapshot.hash)
		}
	}

	// MARK: - Server side (this Mac is controlled by remote)

	func serverDidStartBeingControlled() {
		policyState.didStartBeingControlled(baselineHash: nil)
		PasteboardMonitor.shared.setAggressiveMonitoring(true)
		PasteboardMonitor.shared.snapshot { [weak self] snapshot in
			self?.policyState.didStartBeingControlled(baselineHash: snapshot.hash)
		}
	}

	func serverRequestStopControl(using connection: NetworkConnection) {
		scheduleBoundaryPasteboardSend(using: connection, reason: "stop control")
	}

	func serverWillStopBeingControlled(using connection: NetworkConnection) {
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
	/// types are declared; an immediate metadata read at control start/stop can miss a fast copy.
	private func scheduleBoundaryPasteboardSend(using connection: NetworkConnection, reason: String) {
		boundarySendGeneration &+= 1
		let generation = boundarySendGeneration
		boundarySendCompletedGeneration = nil
		activeBoundaryContext = BoundarySendContext(
			connection: connection,
			baseline: policyState.sessionBaselineHash,
			generation: generation
		)

		debugLog("Scheduling boundary pasteboard send (\(reason))", module: .clipboard)
		PasteboardMonitor.shared.setAggressiveMonitoring(true)

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
			if self.policyState.mode == .idleRecording {
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

		let generation = context.generation
		let baseline = context.baseline
		let connection = context.connection

		PasteboardMonitor.shared.snapshotForSend { [weak self] snapshot in
			guard let self,
				  let current = self.activeBoundaryContext,
				  current.generation == generation,
				  self.boundarySendCompletedGeneration != generation else {
				return
			}

			let decision = self.policyState.evaluateBoundarySend(
				hash: snapshot.hash,
				baseline: baseline,
				skipAfterLocalPaste: self.isSkipAfterLocalPasteEnabled(),
				enableTimeout: self.isClipboardTimeoutEnabled(),
				timeoutInterval: self.clipboardTimeoutInterval(),
				now: self.nowProvider()
			)

			switch decision {
			case .noChange:
				return
			case .skippedAfterLocalPaste:
				debugLog("Skipping pasteboard send at control boundary: content was already pasted locally", module: .clipboard)
				self.boundarySendCompletedGeneration = generation
				self.policyState.markBoundaryHandled(hash: snapshot.hash)
				return
			case .skippedExpired(let elapsed, let timeout):
				debugLog(String(format: "Skipping pasteboard send at control boundary: content expired (%.1fs > %.1fs)", elapsed, timeout), module: .clipboard)
				self.boundarySendCompletedGeneration = generation
				self.policyState.markBoundaryHandled(hash: snapshot.hash)
				return
			case .send:
				break
			}

			guard snapshot.hasDeclaredContent || !snapshot.filePaths.isEmpty else {
				debugLog("Deferring boundary pasteboard send: content not ready yet", module: .clipboard)
				return
			}

			debugLog("Sending pasteboard at control boundary", module: .clipboard)
			self.sendPasteboardIfNeeded(
				using: connection,
				filePaths: snapshot.filePaths,
				sendFind: snapshot.findHasContent,
				hash: snapshot.hash
			)
			self.boundarySendCompletedGeneration = generation
			self.policyState.markBoundaryHandled(hash: snapshot.hash)
		}
	}

	private func sendPasteboardIfNeeded(
		using connection: NetworkConnection,
		filePaths: [String],
		sendFind: Bool,
		hash: PasteboardContentHash
	) {
		if !filePaths.isEmpty {
			debugLog("Sending file pasteboard: \(filePaths.count) files", module: .clipboard)
			let filePasteTransfer = OutgoingPasteboardFileTransfer.shared() as! OutgoingPasteboardFileTransfer
			filePasteTransfer.setFilePaths(filePaths)
			TransfersManager.shared.beginTransfer(filePasteTransfer, using: connection)
		} else {
			debugLog("Sending general pasteboard", module: .clipboard)
			let generalPasteboardTransfer = OutgoingPasteboardTransfer.shared()
			TransfersManager.shared.beginTransfer(generalPasteboardTransfer, using: connection)
		}

		if sendFind {
			let findPasteboardTransfer = OutgoingPasteboardTransfer.shared()
			findPasteboardTransfer.setPasteboardName(NSPasteboard.Name.find.rawValue)
			TransfersManager.shared.beginTransfer(findPasteboardTransfer, using: connection)
		}
	}

	var coordinatorStats: [String: Any] {
		return [
			"mode": String(describing: policyState.mode),
			"isDirty": policyState.pasteboardDirtySinceBaseline,
			"hasTransferHash": policyState.lastTransferHash != nil,
			"hasLocalPasteHash": policyState.consumedByLocalPasteHash != nil,
			"monitorStats": PasteboardMonitor.shared.monitoringStats
		]
	}
}
#endif
