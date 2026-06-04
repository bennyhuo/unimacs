// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

@objcMembers
final class TPTransferProgressController: NSObject, TPTransfersManagerDelegate {
	static let shared = TPTransferProgressController()

	@objc class func defaultController() -> TPTransferProgressController {
		return shared
	}
	
	/// Returns the minimum transfer size (in bytes) to show progress UI.
	/// Reads from user preferences, defaults to 100 KB.
	private var minimumSizeForFeedback: UInt64 {
		let thresholdKB = TPPreferencesManager.shared().int(forPref: Settings.transferProgressThresholdKey)
		if thresholdKB == Int32.max || thresholdKB < 0 {
			return UInt64.max  // Never show
		}
		if thresholdKB == 0 {
			return 0  // Always show
		}
		// Use saved value, or default if not set
		let kb = thresholdKB > 0 ? thresholdKB : Int32(Settings.transferProgressThresholdDefault)
		return UInt64(kb) * 1024
	}

	private var windowController: TPTransferListWindowController?
	private var activeTransfers: [String: TransferState] = [:]
	private var closeTimer: Timer?

	fileprivate struct TransferState {
		let transfer: TPTransfer
		var progress: Float
		var isCompleted: Bool
		var completionMessage: String?
	}
	
	private func shouldShowFeedback(for transfer: TPTransfer) -> Bool {
		guard transfer.hasFeedback else { return false }
		let threshold = minimumSizeForFeedback
		if threshold == UInt64.max { return false }  // Never show
		if threshold == 0 { return true }  // Always show
		let totalSize = transfer._progressTotalDataLength
		// Show feedback if size is unknown (0) or larger than threshold
		return totalSize == 0 || totalSize >= threshold
	}

	func transfersManager(_ transfersManager: TPTransfersManager, beginNewTransfer transfer: TPTransfer) {
		guard shouldShowFeedback(for: transfer) else { return }
		
		cancelCloseTimer()
		
		activeTransfers[transfer.uid] = TransferState(
			transfer: transfer,
			progress: 0,
			isCompleted: false,
			completionMessage: nil
		)
		
		updateWindowController()
		showWindowIfNeeded()
	}

	func transfersManager(_ transfersManager: TPTransfersManager, transfer: TPTransfer, didProgress progress: Float) {
		guard var state = activeTransfers[transfer.uid] else { return }
		
		state.progress = progress
		activeTransfers[transfer.uid] = state
		
		updateWindowController()
	}

	func transfersManager(_ transfersManager: TPTransfersManager, completeTransfer transfer: TPTransfer) {
		guard var state = activeTransfers[transfer.uid] else { return }
		
		state.isCompleted = true
		state.progress = 1.0
		state.completionMessage = transfer.completionMessage
		activeTransfers[transfer.uid] = state
		
		updateWindowController()
		scheduleCloseIfAllCompleted()
	}

	func transfersManager(_ transfersManager: TPTransfersManager, cancelTransfer transfer: TPTransfer) {
		guard var state = activeTransfers[transfer.uid] else { return }
		
		state.isCompleted = true
		state.completionMessage = transfer.errorMessage
		activeTransfers[transfer.uid] = state
		
		updateWindowController()
		scheduleCloseIfAllCompleted()
	}

	private func updateWindowController() {
		let wc = getOrCreateWindowController()
		wc.updateTransfers(Array(activeTransfers.values))
	}

	private func getOrCreateWindowController() -> TPTransferListWindowController {
		if let wc = windowController {
			return wc
		}
		let wc = TPTransferListWindowController()
		windowController = wc
		return wc
	}

	private func showWindowIfNeeded() {
		guard let wc = windowController, let window = wc.window else { return }
		if !window.isVisible {
			wc.showWindow(nil)
			window.center()
			window.orderFrontRegardless()
		}
	}

	private func scheduleCloseIfAllCompleted() {
		let allCompleted = activeTransfers.values.allSatisfy { $0.isCompleted }
		guard allCompleted else { return }
		
		cancelCloseTimer()
		closeTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
			self?.closeWindow()
		}
	}

	private func cancelCloseTimer() {
		closeTimer?.invalidate()
		closeTimer = nil
	}

	private func closeWindow() {
		windowController?.close()
		windowController = nil
		activeTransfers.removeAll()
	}
}

// MARK: - Transfer List Window Controller

private final class TPTransferListWindowController: NSWindowController {
	private let scrollView = NSScrollView()
	private let stackView = NSStackView()
	private var rowViews: [String: TransferRowView] = [:]

	init() {
		let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))

		stackView.orientation = .vertical
		stackView.spacing = 12
		stackView.translatesAutoresizingMaskIntoConstraints = false
		stackView.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

		scrollView.documentView = stackView
		scrollView.hasVerticalScroller = true
		scrollView.hasHorizontalScroller = false
		scrollView.autohidesScrollers = true
		scrollView.drawsBackground = false
		scrollView.translatesAutoresizingMaskIntoConstraints = false

		contentView.addSubview(scrollView)
		NSLayoutConstraint.activate([
			scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
			scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
			stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
		])

		let window = NSWindow(
			contentRect: contentView.frame,
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.title = NSLocalizedString("Transfer", comment: "")
		window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
		window.contentView = contentView
		window.minSize = NSSize(width: 420, height: 80)
		window.maxSize = NSSize(width: 420, height: 400)

		super.init(window: window)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func updateTransfers(_ transfers: [TPTransferProgressController.TransferState]) {
		// Remove rows for transfers that no longer exist
		let currentUIDs = Set(transfers.map { $0.transfer.uid })
		for uid in rowViews.keys where !currentUIDs.contains(uid) {
			if let row = rowViews.removeValue(forKey: uid) {
				stackView.removeArrangedSubview(row)
				row.removeFromSuperview()
			}
		}

		// Add or update rows
		for state in transfers {
			let uid = state.transfer.uid
			let row: TransferRowView
			if let existingRow = rowViews[uid] {
				row = existingRow
			} else {
				row = TransferRowView()
				rowViews[uid] = row
				stackView.addArrangedSubview(row)
			}
			row.update(with: state)
		}

		// Adjust window height based on content
		adjustWindowHeight(transferCount: transfers.count)
	}

	private func adjustWindowHeight(transferCount: Int) {
		guard let window = window else { return }
		
		let rowHeight: CGFloat = 70
		let padding: CGFloat = 32
		let spacing: CGFloat = 12
		let contentHeight = CGFloat(transferCount) * rowHeight + CGFloat(max(0, transferCount - 1)) * spacing + padding
		let targetHeight = min(max(contentHeight, 80), 400)
		
		var frame = window.frame
		let heightDiff = targetHeight - frame.height
		frame.size.height = targetHeight
		frame.origin.y -= heightDiff
		window.setFrame(frame, display: true, animate: false)
	}
}

// MARK: - Transfer Row View

private final class TransferRowView: NSView {
	private let titleLabel = NSTextField(labelWithString: "")
	private let detailLabel = NSTextField(labelWithString: "")
	private let progressIndicator = NSProgressIndicator(frame: .zero)

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		setupUI()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		setupUI()
	}

	private func setupUI() {
		titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
		titleLabel.lineBreakMode = .byTruncatingTail

		detailLabel.font = NSFont.systemFont(ofSize: 11)
		detailLabel.textColor = .secondaryLabelColor
		detailLabel.lineBreakMode = .byTruncatingTail

		progressIndicator.isIndeterminate = false
		progressIndicator.minValue = 0
		progressIndicator.maxValue = 1
		progressIndicator.doubleValue = 0
		progressIndicator.controlSize = .small
		progressIndicator.style = .bar
		progressIndicator.usesThreadedAnimation = true

		let stack = NSStackView(views: [titleLabel, detailLabel, progressIndicator])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 4
		stack.translatesAutoresizingMaskIntoConstraints = false

		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
			progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
			progressIndicator.heightAnchor.constraint(equalToConstant: 8)
		])
	}

	func update(with state: TPTransferProgressController.TransferState) {
		let transfer = state.transfer
		let hostName = transfer.remoteHost?.computerName ?? NSLocalizedString("Remote Host", comment: "")
		
		if transfer.isIncoming {
			titleLabel.stringValue = String(format: NSLocalizedString("Receiving from \"%@\"", comment: ""), hostName)
		} else {
			titleLabel.stringValue = String(format: NSLocalizedString("Sending to \"%@\"", comment: ""), hostName)
		}

		if state.isCompleted {
			detailLabel.stringValue = state.completionMessage ?? NSLocalizedString("Completed", comment: "")
			progressIndicator.stopAnimation(nil)
			progressIndicator.isIndeterminate = false
			progressIndicator.doubleValue = 1
		} else {
			let transferred: UInt64 = transfer.isIncoming ? transfer._receivedDataLength : transfer._sentDataLength
			let total: UInt64 = transfer._progressTotalDataLength

			if total > 0, state.progress >= 0 {
let transferredStr = String.sizeString(for: transferred)
				let totalStr = String.sizeString(for: total)
				detailLabel.stringValue = "\(transferredStr) / \(totalStr)"

				progressIndicator.stopAnimation(nil)
				progressIndicator.isIndeterminate = false
				progressIndicator.doubleValue = Double(max(0, min(1, state.progress)))
			} else {
let transferredStr = String.sizeString(for: transferred)
				detailLabel.stringValue = String(format: NSLocalizedString("Transferred %@", comment: ""), transferredStr)

				progressIndicator.isIndeterminate = true
				progressIndicator.startAnimation(nil)
			}
		}
	}
}
