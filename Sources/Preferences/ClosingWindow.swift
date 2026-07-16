// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

@objc(ClosingWindow)
final class ClosingWindow: NSWindow {
	// ESC triggers `cancelOperation(_:)` in the responder chain.
	override func cancelOperation(_ sender: Any?) {
		closeAboutSheetIfPossible()
	}

	override func keyDown(with event: NSEvent) {
		// Key code 53 == Escape.
		if event.keyCode == 53 {
			closeAboutSheetIfPossible()
			return
		}
		super.keyDown(with: event)
	}

	override func mouseDown(with event: NSEvent) {
		closeAboutSheetIfPossible()
	}

	private func closeAboutSheetIfPossible() {
		(delegate as AnyObject?)?.perform(Selector(("closeAboutSheet")))
	}
}
