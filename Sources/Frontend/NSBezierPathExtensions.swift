// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

extension NSBezierPath {
	/// ObjC selector: `+bezierPathWithRoundRectInRect:radius:`
	@objc class func bezierPathWithRoundRectInRect(_ rect: NSRect, radius: Float) -> NSBezierPath {
		let path = NSBezierPath()
		let topMid = NSPoint(x: NSMidX(rect), y: NSMaxY(rect))
		let topLeft = NSPoint(x: NSMinX(rect), y: NSMaxY(rect))
		let topRight = NSPoint(x: NSMaxX(rect), y: NSMaxY(rect))
		let bottomRight = NSPoint(x: NSMaxX(rect), y: NSMinY(rect))

		path.move(to: topMid)
		path.appendArc(from: topLeft, to: rect.origin, radius: CGFloat(radius))
		path.appendArc(from: rect.origin, to: bottomRight, radius: CGFloat(radius))
		path.appendArc(from: bottomRight, to: topRight, radius: CGFloat(radius))
		path.appendArc(from: topRight, to: topLeft, radius: CGFloat(radius))
		path.close()
		return path
	}

	/// ObjC selector: `+fillLeftRoundedRectInRect:radius:`
	@objc class func fillLeftRoundedRectInRect(_ rect: NSRect, radius: Float) {
		if rect.size.width < 4 {
			return
		}

		let path = NSBezierPath()
		let topMid = NSPoint(x: NSMidX(rect), y: NSMaxY(rect))
		let topLeft = NSPoint(x: NSMinX(rect), y: NSMaxY(rect))
		let topRight = NSPoint(x: NSMaxX(rect), y: NSMaxY(rect))
		let bottomRight = NSPoint(x: NSMaxX(rect), y: NSMinY(rect))

		path.move(to: topMid)
		path.appendArc(from: topLeft, to: rect.origin, radius: CGFloat(radius))
		path.appendArc(from: rect.origin, to: bottomRight, radius: CGFloat(radius))
		path.appendArc(from: bottomRight, to: topRight, radius: 0)
		path.appendArc(from: topRight, to: topLeft, radius: 0)
		path.close()
		path.fill()
	}

	/// ObjC selector: `+drawRect:withGradientFrom:to:`
	@objc class func drawRect(_ rect: NSRect, withGradientFrom colorStart: NSColor, to colorEnd: NSColor) {
		var fraction: CGFloat = 0
		let height = rect.size.height - 1
		let width = rect.size.width

		guard height > 0 else {
			colorEnd.set()
			NSBezierPath.fill(rect)
			return
		}

		let step: CGFloat = 1 / height
		var gradientRect = NSRect(x: rect.origin.x, y: rect.origin.y, width: width, height: 1.0)

		colorEnd.set()
		NSBezierPath.fill(gradientRect)

		let iterations = Int(height)
		for _ in 0..<iterations {
			gradientRect.origin.y += 1
			let gradientColor = colorStart.blended(withFraction: fraction, of: colorEnd) ?? colorStart
			gradientColor.set()
			NSBezierPath.fill(gradientRect)
			fraction += step
		}
	}
}
