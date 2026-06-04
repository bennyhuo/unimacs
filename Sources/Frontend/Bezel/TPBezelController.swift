// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

@objc(TPBezelController)
final class TPBezelController: NSObject {
	private static var _default: TPBezelController?

	private var bezelWindow: TPBezelWindow?
	private var bezelView: TPBezelView?
	private var textTimer: Timer?

	@objc(defaultController)
	class func `default`() -> TPBezelController {
		if let existing = _default {
			return existing
		}
		let created = TPBezelController()
		_default = created
		return created
	}

	@objc(showBezelWithControlledHost:)
	func showBezel(withControlledHost host: TPRemoteHost) {
		// Always show bezel centered on the *main screen*.
		let mainScreenFrame = TPLocalHost.shared.mainScreen.frame

		if bezelWindow == nil {
			let window = TPBezelWindow(contentRect: mainScreenFrame, styleMask: .borderless, backing: .buffered, defer: false)
			let view = TPBezelView(frame: .zero)
			window.contentView = view
			bezelWindow = window
			bezelView = view
		}

		bezelView?.setRemoteHost(host)
		bezelWindow?.orderFront(nil)
		bezelWindow?.orderFrontRegardless()
		bezelWindow?.collectionBehavior = [.canJoinAllSpaces, .stationary]
	}

	@objc func hideBezel() {
		bezelWindow?.orderOut(self)
		textTimer?.invalidate()
		textTimer = nil
		bezelView?.setText(nil)
	}

	@objc(showText:withDuration:)
	func showText(_ text: String, withDuration duration: TimeInterval) {
		bezelView?.setText(text)
		textTimer?.invalidate()
		textTimer = Timer.scheduledTimer(timeInterval: duration, target: self, selector: #selector(removeText(_:)), userInfo: nil, repeats: false)
	}

	@objc private func removeText(_ timer: Timer) {
		bezelView?.setText(nil)
		textTimer = nil
	}
}
