// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

@objc(TPBezelView)
final class TPBezelView: NSView {
	private enum Layout {
		static let yTitleMargin: CGFloat = 64.0
		static let xTitleMargin: CGFloat = 16.0
		static let yTextMargin: CGFloat = 32.0
		static let yIconAdjustment: CGFloat = 24.0
		static let minRoundedRectSize: CGFloat = 214.0
		static let roundedRectRadius: CGFloat = 24.0
		static let arrowSize: CGFloat = 14.0
		static let arrowMargin: CGFloat = (arrowSize / 2.0 + 8.0)
		static let windowTransparency: CGFloat = 0.15
	}

	private static let teleportImage: NSImage? = NSImage(named: "whitelogo")
	private static let lockImage: NSImage? = NSImage(named: "Lock_White")

	private static let paragraphStyle: NSMutableParagraphStyle = {
		let style = NSMutableParagraphStyle()
		style.alignment = .center
		return style
	}()

	private static let titleAttributes: [NSAttributedString.Key: Any] = [
		.font: NSFont(name: "Arial Black", size: 18) as Any,
		.foregroundColor: NSColor.white,
		.paragraphStyle: paragraphStyle
	]

	private static let textAttributes: [NSAttributedString.Key: Any] = [
		.font: NSFont(name: "Arial Black", size: 13) as Any,
		.foregroundColor: NSColor.white,
		.paragraphStyle: paragraphStyle
	]

	private var remoteHost: TPRemoteHost?
	private var text: String?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
	}

	private func titleString() -> String {
		remoteHost?.computerName ?? ""
	}

	private func updateLayout() {
		let titleSize = (titleString() as NSString).size(withAttributes: Self.titleAttributes)
		let width = round(max(Layout.minRoundedRectSize, titleSize.width + 2 * Layout.xTitleMargin))

		guard let window = window else {
			needsDisplay = true
			return
		}

		let mainScreenFrame = TPLocalHost.shared.mainScreen.frame

		var frame = mainScreenFrame
		frame.origin.x = NSMinX(frame) + round((NSWidth(frame) - width) / 2.0)
		frame.origin.y = NSMinY(frame) + round((NSHeight(frame) - Layout.minRoundedRectSize) / 2.0)
		frame.size = NSSize(width: width, height: Layout.minRoundedRectSize)

		needsDisplay = true
		window.setFrame(frame, display: true, animate: false)
	}

	@objc(setRemoteHost:)
	func setRemoteHost(_ remoteHost: TPRemoteHost?) {
		self.remoteHost = remoteHost
		updateLayout()
	}

	@objc(setText:)
	func setText(_ text: String?) {
		self.text = text
		updateLayout()
	}

	override func draw(_ dirtyRect: NSRect) {
		NSColor.clear.setFill()
		NSBezierPath(rect: dirtyRect).fill()

		let bounds = bounds

		// Draw rounded rect background
		NSColor(calibratedWhite: 0.0, alpha: Layout.windowTransparency).setFill()
		NSBezierPath.bezierPathWithRoundRectInRect(bounds, radius: Float(Layout.roundedRectRadius)).fill()

		// Draw icon
		if let image = Self.teleportImage {
			var imagePoint = bounds.origin
			let imageSize = image.size
			imagePoint.x += round((NSWidth(bounds) - imageSize.width) / 2.0)
			imagePoint.y += round((NSHeight(bounds) - imageSize.height + (Layout.yTitleMargin - Layout.yIconAdjustment)) / 2.0)
			image.draw(at: imagePoint, from: .zero, operation: .sourceOver, fraction: 1.0)
		}

		// Create arrow
		let arrow = NSBezierPath()
		arrow.move(to: .zero)
		arrow.line(to: NSPoint(x: 0, y: Layout.arrowSize))
		arrow.line(to: NSPoint(x: Layout.arrowSize, y: Layout.arrowSize / 2.0))
		arrow.close()

		// Setup shadow
		let shadow = NSShadow()
		shadow.shadowBlurRadius = 4.0
		shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.8)
		shadow.shadowOffset = NSSize(width: 1.5, height: -1.5)
		shadow.set()

		// Position and draw arrow
		if let remoteHost {
			// The bezel is centered on the main screen, so compute the arrow direction
			// relative to the main screen center.
			let localRect = TPLocalHost.shared.mainScreen.frame
			let hostRect = remoteHost.adjustedHostDesktopRect
			let h = NSMidX(hostRect) - NSMidX(localRect)
			let v = NSMidY(hostRect) - NSMidY(localRect)
			var angle = atan2(v, h)

			var transform = AffineTransform()
			transform.translate(x: NSMidX(bounds), y: NSMidY(bounds))
			transform.rotate(byRadians: angle)
			transform.translate(x: -Layout.arrowSize / 2.0, y: -Layout.arrowSize / 2.0)

			let halfWidth = NSWidth(bounds) / 2.0
			let halfHeight = NSHeight(bounds) / 2.0
			let limitAngle = atan2(halfHeight, halfWidth)

			if angle >= .pi / 2.0 {
				angle = .pi - angle
			} else if angle < 0.0 && angle >= -.pi / 2.0 {
				angle = -angle
			} else if angle < 0.0 {
				angle = angle + .pi
			}

			let distance: CGFloat
			if angle < limitAngle {
				distance = halfWidth / cos(angle)
			} else {
				distance = halfHeight / sin(angle)
			}

			transform.translate(x: round(distance - Layout.arrowMargin), y: 0.0)
			arrow.transform(using: transform)
		}

		NSColor.white.setFill()
		arrow.fill()

		// Draw title
		var titleRect = bounds
		titleRect.origin.y -= (NSHeight(bounds) - Layout.yTitleMargin)
		(titleString() as NSString).draw(in: titleRect, withAttributes: Self.titleAttributes)

		// Eventually draw text
		if let text {
			var textRect = bounds
			textRect.origin.y -= (NSHeight(bounds) - Layout.yTextMargin)
			(text as NSString).draw(in: textRect, withAttributes: Self.textAttributes)
		}
	}
}
