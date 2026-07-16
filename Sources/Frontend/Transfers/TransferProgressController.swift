// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

@objcMembers
final class TransferProgressController: NSObject, TransfersManagerDelegate {
	static let shared = TransferProgressController()

	@objc class func defaultController() -> TransferProgressController {
		return shared
	}
	
	/// Returns the minimum transfer size (in bytes) to show progress UI.
	/// Reads from user preferences, defaults to 100 KB.
	private var minimumSizeForFeedback: UInt64 {
		let thresholdKB = PreferencesManager.shared().int(forPref: Settings.transferProgressThresholdKey)
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

	private var windowController: TransferListWindowController?
	private var activeTransfers: [String: TransferState] = [:]
	private var closeTimer: Timer?

	fileprivate struct TransferState {
		let transfer: Transfer
		var progress: Float
		var isCompleted: Bool
		var completionMessage: String?
	}
	
	private func shouldShowFeedback(for transfer: Transfer) -> Bool {
		guard transfer.hasFeedback else { return false }
		let threshold = minimumSizeForFeedback
		if threshold == UInt64.max { return false }  // Never show
		if threshold == 0 { return true }  // Always show
		let totalSize = transfer._progressTotalDataLength
		// Show feedback if size is unknown (0) or larger than threshold
		return totalSize == 0 || totalSize >= threshold
	}

	func transfersManager(_ transfersManager: TransfersManager, beginNewTransfer transfer: Transfer) {
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

	func transfersManager(_ transfersManager: TransfersManager, transfer: Transfer, didProgress progress: Float) {
		guard var state = activeTransfers[transfer.uid] else { return }
		
		state.progress = progress
		activeTransfers[transfer.uid] = state
		
		updateWindowController()
	}

	func transfersManager(_ transfersManager: TransfersManager, completeTransfer transfer: Transfer) {
		guard var state = activeTransfers[transfer.uid] else { return }
		
		state.isCompleted = true
		state.progress = 1.0
		state.completionMessage = transfer.completionMessage
		activeTransfers[transfer.uid] = state
		
		updateWindowController()
		scheduleCloseIfAllCompleted()
	}

	func transfersManager(_ transfersManager: TransfersManager, cancelTransfer transfer: Transfer) {
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

	private func getOrCreateWindowController() -> TransferListWindowController {
		if let wc = windowController {
			return wc
		}
		let wc = TransferListWindowController()
		windowController = wc
		return wc
	}

	private func showWindowIfNeeded() {
		guard let wc = windowController, let window = wc.window else { return }
		if !window.isVisible {
			wc.positionInTopRight()
			wc.showWindow(nil)
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

private final class TransferListWindowController: NSWindowController {
	private let stackView = NSStackView()
	private var rowViews: [String: TransferRowView] = [:]

	init() {
		let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
		contentView.wantsLayer = true
		contentView.layer?.cornerRadius = 16
		contentView.layer?.masksToBounds = true

		let visualEffectView = NSVisualEffectView()
		visualEffectView.material = .hudWindow
		visualEffectView.blendingMode = .behindWindow
		visualEffectView.state = .active
		visualEffectView.translatesAutoresizingMaskIntoConstraints = false
		visualEffectView.wantsLayer = true
		visualEffectView.layer?.cornerRadius = 16
		visualEffectView.layer?.masksToBounds = true
		visualEffectView.layer?.borderWidth = 0.5
		visualEffectView.layer?.borderColor = NSColor.separatorColor.cgColor

		stackView.orientation = .vertical
		stackView.alignment = .leading
		stackView.spacing = 10
		stackView.translatesAutoresizingMaskIntoConstraints = false

		contentView.addSubview(visualEffectView)
		visualEffectView.addSubview(stackView)

		NSLayoutConstraint.activate([
			visualEffectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			visualEffectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			visualEffectView.topAnchor.constraint(equalTo: contentView.topAnchor),
			visualEffectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

			stackView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 14),
			stackView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -14),
			stackView.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 14),
			stackView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -14)
		])

		let window = NSWindow(
			contentRect: contentView.frame,
			styleMask: .borderless,
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.title = NSLocalizedString("Transfer", comment: "")
		window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
		window.contentView = contentView
		window.minSize = NSSize(width: 360, height: 60)
		window.maxSize = NSSize(width: 360, height: 400)
		window.isOpaque = false
		window.backgroundColor = .clear
		window.hasShadow = true
		window.level = .floating

		super.init(window: window)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func positionInTopRight() {
		guard let window = window else { return }
		let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
		guard let screen = screen else { return }
		let screenFrame = screen.visibleFrame
		let margin: CGFloat = 20
		let x = screenFrame.maxX - window.frame.width - margin
		let y = screenFrame.maxY - window.frame.height - margin
		window.setFrameOrigin(NSPoint(x: x, y: y))
	}

	func updateTransfers(_ transfers: [TransferProgressController.TransferState]) {
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
				row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
			}
			row.update(with: state)
		}

		// Adjust window height based on content
		adjustWindowHeight(transferCount: transfers.count)
	}

	private func adjustWindowHeight(transferCount: Int) {
		guard let window = window else { return }
		
		let rowHeight: CGFloat = 52
		let padding: CGFloat = 28
		let spacing: CGFloat = 10
		let contentHeight = CGFloat(transferCount) * rowHeight + CGFloat(max(0, transferCount - 1)) * spacing + padding
		let targetHeight = min(max(contentHeight, 60), 400)
		
		var frame = window.frame
		let screen = window.screen ?? NSScreen.main
		if let screen = screen {
			let screenFrame = screen.visibleFrame
			let margin: CGFloat = 20
			frame.size.height = targetHeight
			frame.origin.x = screenFrame.maxX - frame.width - margin
			frame.origin.y = screenFrame.maxY - targetHeight - margin
		} else {
			let heightDiff = targetHeight - frame.height
			frame.size.height = targetHeight
			frame.origin.y -= heightDiff
		}
		window.setFrame(frame, display: true, animate: false)
	}
}

// MARK: - Transfer Row View

private final class TransferRowView: NSView {
	private let iconImageView = NSImageView()
	private let titleLabel = NSTextField(labelWithString: "")
	private let detailLabel = NSTextField(labelWithString: "")
	private let progressIndicator = NSProgressIndicator(frame: .zero)
	private let cancelButton = NSButton()
	private var transferUID: String?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		setupUI()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		setupUI()
	}

	private func setupUI() {
		wantsLayer = true

		iconImageView.translatesAutoresizingMaskIntoConstraints = false
		iconImageView.contentTintColor = .controlAccentColor
		iconImageView.imageScaling = .scaleProportionallyUpOrDown

		titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
		titleLabel.lineBreakMode = .byTruncatingTail

		detailLabel.font = NSFont.systemFont(ofSize: 10)
		detailLabel.textColor = .secondaryLabelColor
		detailLabel.lineBreakMode = .byTruncatingTail

		progressIndicator.isIndeterminate = false
		progressIndicator.minValue = 0
		progressIndicator.maxValue = 1
		progressIndicator.doubleValue = 0
		progressIndicator.controlSize = .small
		progressIndicator.style = .bar
		progressIndicator.usesThreadedAnimation = true
		progressIndicator.translatesAutoresizingMaskIntoConstraints = false

		cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: NSLocalizedString("Cancel", comment: ""))
		cancelButton.isBordered = false
		cancelButton.setButtonType(.momentaryPushIn)
		cancelButton.contentTintColor = .secondaryLabelColor
		cancelButton.translatesAutoresizingMaskIntoConstraints = false
		cancelButton.target = self
		cancelButton.action = #selector(cancelButtonClicked)

		let textStack = NSStackView(views: [titleLabel, detailLabel, progressIndicator])
		textStack.orientation = .vertical
		textStack.alignment = .leading
		textStack.spacing = 3
		textStack.translatesAutoresizingMaskIntoConstraints = false

		addSubview(iconImageView)
		addSubview(textStack)
		addSubview(cancelButton)

		NSLayoutConstraint.activate([
			iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
			iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
			iconImageView.widthAnchor.constraint(equalToConstant: 24),
			iconImageView.heightAnchor.constraint(equalToConstant: 24),

			textStack.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 10),
			textStack.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -12),
			textStack.centerYAnchor.constraint(equalTo: centerYAnchor),

			cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor),
			cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
			cancelButton.widthAnchor.constraint(equalToConstant: 20),
			cancelButton.heightAnchor.constraint(equalToConstant: 20),

			progressIndicator.widthAnchor.constraint(equalTo: textStack.widthAnchor),
			progressIndicator.heightAnchor.constraint(equalToConstant: 6),

			heightAnchor.constraint(equalToConstant: 52)
		])
	}

	@objc private func cancelButtonClicked() {
		guard let uid = transferUID else { return }
		TransfersManager.shared.cancelTransfer(withUID: uid)
	}

	func update(with state: TransferProgressController.TransferState) {
		let transfer = state.transfer
		self.transferUID = transfer.uid
		let hostName = transfer.remoteHost?.computerName ?? NSLocalizedString("Remote Host", comment: "")
		
		if transfer.isIncoming {
			titleLabel.stringValue = String(format: NSLocalizedString("Receiving from \"%@\"", comment: ""), hostName)
			iconImageView.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
		} else {
			titleLabel.stringValue = String(format: NSLocalizedString("Sending to \"%@\"", comment: ""), hostName)
			iconImageView.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: nil)
		}

		if state.isCompleted {
			detailLabel.stringValue = state.completionMessage ?? NSLocalizedString("Completed", comment: "")
			progressIndicator.stopAnimation(nil)
			progressIndicator.isIndeterminate = false
			progressIndicator.doubleValue = 1
			cancelButton.isHidden = true
		} else {
			cancelButton.isHidden = false
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
