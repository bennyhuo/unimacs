// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

@objc(LinkTextField)
final class LinkTextField: NSTextField {
	private static let highlightedColor = NSColor(calibratedRed: 0.8, green: 0.08, blue: 0.1, alpha: 1.0)
	private static let normalColor = NSColor.controlTextColor

	private var trackingArea: NSTrackingArea?
	private var isHovering: Bool = false

	private var linkURLString: String? {
		// Historically this control stored the URL in the cell placeholder string.
		return (cell as? NSTextFieldCell)?.placeholderString
	}

	override func awakeFromNib() {
		super.awakeFromNib()

		// Make it behave like a clickable label (not an editable/selectable field).
		isEditable = false
		isSelectable = false
		isBordered = false
		drawsBackground = false

		updateTrackingAreas()
		window?.invalidateCursorRects(for: self)
	}

	override func updateTrackingAreas() {
		super.updateTrackingAreas()

		if let ta = trackingArea {
			removeTrackingArea(ta)
		}

		let options: NSTrackingArea.Options = [
			.mouseEnteredAndExited,
			.activeInActiveApp,
			.inVisibleRect
		]
		let ta = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
		addTrackingArea(ta)
		trackingArea = ta
	}

	override func resetCursorRects() {
		super.resetCursorRects()
		addCursorRect(bounds, cursor: .pointingHand)
	}

	deinit {
		if isHovering {
			NSCursor.pop()
		}
	}

	override func mouseEntered(with event: NSEvent) {
		isHovering = true
		textColor = Self.highlightedColor
		NSCursor.pointingHand.push()
		needsDisplay = true
	}

	override func mouseExited(with event: NSEvent) {
		isHovering = false
		textColor = Self.normalColor
		NSCursor.pop()
		needsDisplay = true
	}

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
		true
	}

	override func mouseDown(with event: NSEvent) {
		guard let s = linkURLString, let url = URL(string: s) else { return }
		NSWorkspace.shared.open(url)
	}
}
