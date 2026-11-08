// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

enum NotificationIconType: Int {
	case logo
	case warning
	case success
	case key
}

enum BezelMode {
	case hidden
	case controlling(host: RemoteHost, emergencyHint: String?)
	case emergency(title: String, subtitle: String, count: Int, maxCount: Int)
	case notification(title: String, subtitle: String, icon: NotificationIconType, duration: TimeInterval)
}

final class BezelController: NSObject {
	private static var _default: BezelController?

	private var bezelWindow: BezelWindow?
	private var bezelView: BezelView?
	private var textTimer: Timer?
	private var activeControlledHost: RemoteHost?

	class func `default`() -> BezelController {
		if let existing = _default {
			return existing
		}
		let created = BezelController()
		_default = created
		return created
	}

	func setMode(_ mode: BezelMode) {
		// Ensure window and view are created on main thread.
		if bezelWindow == nil {
			let mainScreenFrame = LocalHost.shared.mainScreen.frame
			let window = BezelWindow(contentRect: mainScreenFrame, styleMask: .borderless, backing: .buffered, defer: false)
			let view = BezelView(frame: .zero)
			window.contentView = view
			bezelWindow = window
			bezelView = view
		}

		textTimer?.invalidate()
		textTimer = nil

		guard let bezelView = bezelView, let bezelWindow = bezelWindow else { return }

		switch mode {
		case .hidden:
			activeControlledHost = nil
			bezelView.setMode(.hidden)
			bezelWindow.orderOut(self)
		case .controlling(let host, let hint):
			activeControlledHost = host
			bezelView.setMode(.controlling(host: host, emergencyHint: hint))
			bezelWindow.orderFront(nil)
			bezelWindow.orderFrontRegardless()
		case .emergency(let title, let subtitle, let count, let maxCount):
			bezelView.setMode(.emergency(title: title, subtitle: subtitle, count: count, maxCount: maxCount))
			bezelWindow.orderFront(nil)
			bezelWindow.orderFrontRegardless()
			
			// Auto dismiss or roll back after 2 seconds
			textTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
				self?.restorePreviousActiveState()
			}
		case .notification(let title, let subtitle, let icon, let duration):
			bezelView.setMode(.notification(title: title, subtitle: subtitle, icon: icon))
			bezelWindow.orderFront(nil)
			bezelWindow.orderFrontRegardless()
			
			if duration > 0 {
				textTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
					self?.restorePreviousActiveState()
				}
			}
		}
	}

	private func restorePreviousActiveState() {
		if let host = activeControlledHost {
			setMode(.controlling(host: host, emergencyHint: "⌃⌥⇧⎋ to release"))
		} else {
			setMode(.hidden)
		}
	}

	func showBezel(withControlledHost host: RemoteHost) {
		setMode(.controlling(host: host, emergencyHint: "⌃⌥⇧⎋ to release"))
	}

	func hideBezel() {
		setMode(.hidden)
	}

	func showText(_ text: String, withDuration duration: TimeInterval) {
		setMode(.notification(title: "", subtitle: text, icon: .logo, duration: duration))
	}
}
