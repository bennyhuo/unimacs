// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

@objc(TPBezelView)
final class TPBezelView: NSVisualEffectView {
	private enum Layout {
		static let height: CGFloat = 110.0             // Refined height (2/3 of 164)
		static let roundedRectRadius: CGFloat = 22.0    // Xcode-style rounded corners
		static let xPadding: CGFloat = 32.0            // Left/right padding
		static let minWidth: CGFloat = 240.0           // Minimum width
	}

	private static let paragraphStyle: NSMutableParagraphStyle = {
		let style = NSMutableParagraphStyle()
		style.alignment = .center
		return style
	}()

	private static let titleAttributes: [NSAttributedString.Key: Any] = [
		.font: NSFont.systemFont(ofSize: 24, weight: .bold),
		.paragraphStyle: paragraphStyle
	]

	private static let textAttributes: [NSAttributedString.Key: Any] = [
		.font: NSFont.systemFont(ofSize: 16, weight: .medium),
		.paragraphStyle: paragraphStyle
	]

	private let titleLabel: NSTextField = {
		let label = NSTextField(labelWithString: "")
		label.isEditable = false
		label.isSelectable = false
		label.isBordered = false
		label.drawsBackground = false
		label.alignment = .center
		label.textColor = .labelColor // Adaptive system color
		label.font = NSFont.systemFont(ofSize: 24, weight: .bold)
		return label
	}()

	private let subtitleLabel: NSTextField = {
		let label = NSTextField(labelWithString: "")
		label.isEditable = false
		label.isSelectable = false
		label.isBordered = false
		label.drawsBackground = false
		label.alignment = .center
		label.textColor = .secondaryLabelColor // Adaptive secondary color
		label.font = NSFont.systemFont(ofSize: 16, weight: .medium)
		return label
	}()

	private var viewMode: TPBezelViewMode = .hidden

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		commonInit()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		commonInit()
	}

	private func commonInit() {
		// Use popover material as it provides a very refined premium dark-brownish/light-creamy look matching Xcode HUD
		material = .popover
		blendingMode = .behindWindow
		state = .active
		wantsLayer = true
		layer?.cornerRadius = Layout.roundedRectRadius
		layer?.masksToBounds = true
		
		// Assemble standard controls (No gradientBar)
		addSubview(titleLabel)
		addSubview(subtitleLabel)
	}

	func setMode(_ mode: TPBezelViewMode) {
		self.viewMode = mode
		updateLayout()
	}

	private func updateLayout() {
		guard let window = window else {
			needsDisplay = true
			return
		}

		switch viewMode {
		case .hidden:
			titleLabel.stringValue = ""
			subtitleLabel.stringValue = ""
			needsLayout = true
			return
		case .controlling(let host, let hint):
			titleLabel.stringValue = host.computerName
			subtitleLabel.stringValue = hint ?? ""
		case .emergency(let title, let subtitle, _, _):
			titleLabel.stringValue = title
			subtitleLabel.stringValue = subtitle
		case .notification(let title, let subtitle, _):
			titleLabel.stringValue = title
			subtitleLabel.stringValue = subtitle
		}
		
		// Let AppKit automatically calculate the size fitting the string content
		titleLabel.sizeToFit()
		subtitleLabel.sizeToFit()
		
		let maxTextWidth = max(titleLabel.frame.width, subtitleLabel.frame.width)
		let width = round(max(Layout.minWidth, maxTextWidth + 2 * Layout.xPadding))
		let mainScreenFrame = TPLocalHost.shared.mainScreen.frame

		var frame = mainScreenFrame
		frame.origin.x = NSMinX(frame) + round((NSWidth(frame) - width) / 2.0)
		frame.origin.y = NSMinY(frame) + round((NSHeight(frame) - Layout.height) / 2.0)
		frame.size = NSSize(width: width, height: Layout.height)

		needsLayout = true
		window.setFrame(frame, display: true, animate: false)
	}

	override func layout() {
		super.layout()
		let bounds = bounds
		
		// Positioning labels based on whether subtitle exists
		let hasSubtitle = !subtitleLabel.stringValue.isEmpty
		
		if hasSubtitle {
			titleLabel.frame = NSRect(
				x: Layout.xPadding,
				y: bounds.height - 52.0,
				width: bounds.width - 2 * Layout.xPadding,
				height: 32.0
			)
			subtitleLabel.frame = NSRect(
				x: Layout.xPadding,
				y: bounds.height - 86.0,
				width: bounds.width - 2 * Layout.xPadding,
				height: 22.0
			)
			subtitleLabel.isHidden = false
		} else {
			let titleHeight: CGFloat = 32.0
			titleLabel.frame = NSRect(
				x: Layout.xPadding,
				y: round((bounds.height - titleHeight) / 2.0),
				width: bounds.width - 2 * Layout.xPadding,
				height: titleHeight
			)
			subtitleLabel.isHidden = true
		}
	}

	@objc(setRemoteHost:)
	func setRemoteHost(_ remoteHost: TPRemoteHost?) {
		if let remoteHost = remoteHost {
			setMode(.controlling(host: remoteHost, emergencyHint: nil))
		} else {
			setMode(.hidden)
		}
	}

	@objc(setText:)
	func setText(_ text: String?) {
		if let text = text {
			setMode(.notification(title: "", subtitle: text, icon: .logo))
		} else {
			setMode(.hidden)
		}
	}
}

enum TPBezelViewMode {
	case hidden
	case controlling(host: TPRemoteHost, emergencyHint: String?)
	case emergency(title: String, subtitle: String, count: Int, maxCount: Int)
	case notification(title: String, subtitle: String, icon: TPNotificationIconType)
}
