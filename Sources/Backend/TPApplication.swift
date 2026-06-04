// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

@objc(TPEventDelegate)
protocol TPEventDelegate: NSObjectProtocol {
	@objc(applicationWillSendEvent:)
	optional func applicationWillSendEvent(_ event: NSEvent) -> Bool
}

@main
@objc(TPApplication)
final class TPApplication: NSApplication {
	private weak var eventsDelegate: TPEventDelegate?

	// Entry point - migrated from main.m
	static func main() {
		// Ignore SIGPIPE on socket
		signal(SIGPIPE, SIG_IGN)
		
		// Start the application
		let app = TPApplication.shared
		_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
	}

	@objc(setEventDelegate:)
	func setEventDelegate(_ eventDelegate: TPEventDelegate?) {
		eventsDelegate = eventDelegate
	}

	override func sendEvent(_ event: NSEvent) {
		var sendToSuper = true

		if let delegate = eventsDelegate {
			if let shouldSend = delegate.applicationWillSendEvent?(event) {
				sendToSuper = shouldSend
			}
		}

		if sendToSuper {
			super.sendEvent(event)
		}
	}
}
