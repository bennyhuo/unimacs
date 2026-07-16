// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import CoreGraphics

@objc(BezelWindow)
final class BezelWindow: NSWindow {
	override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
		super.init(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
		commonInit()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("BezelWindow does not support init(coder:)")
	}

	private func commonInit() {
		backgroundColor = .clear
		alphaValue = 1.0
		isOpaque = false
		hasShadow = false
		level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
		ignoresMouseEvents = true
	}
}
