// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  Window controller for the SwiftUI settings interface.

import SwiftUI
import AppKit

@available(macOS 13.0, *)
@objcMembers
class SettingsWindowController: NSWindowController {

	// MARK: - Singleton

	private static var _shared: SettingsWindowController?

	static var shared: SettingsWindowController {
		if _shared == nil {
			_shared = SettingsWindowController()
		}
		return _shared!
	}

	// MARK: - Initialization

	convenience init() {
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)

		self.init(window: window)

		setupWindow()
	}

	private func setupWindow() {
		guard let window = window else { return }

		window.title = "teleport"
		window.minSize = NSSize(width: 750, height: 500)
		window.center()
		window.setFrameAutosaveName("TeleportSettingsWindow")

		window.toolbarStyle = .unified
		window.titlebarAppearsTransparent = false

		let hostingView = NSHostingView(rootView: SettingsView())
		window.contentView = hostingView

		window.delegate = self
	}

	// MARK: - Public Methods

	func showSettings() {
		window?.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}
}

// MARK: - NSWindowDelegate

@available(macOS 13.0, *)
extension SettingsWindowController: NSWindowDelegate {
	func windowWillClose(_ notification: Notification) {
		// Window can be reopened via showSettings()
	}
}

// MARK: - Objective-C Bridge

/// Objective-C compatible wrapper for showing the settings window.
@objcMembers
class ModernSettingsLauncher: NSObject {

	@objc static var isAvailable: Bool {
		if #available(macOS 13.0, *) {
			return true
		}
		return false
	}

	@objc static func showSettings() {
		if #available(macOS 13.0, *) {
			SettingsWindowController.shared.showSettings()
		}
	}
}
