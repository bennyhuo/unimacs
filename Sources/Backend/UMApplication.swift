// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

@objc(UMEventDelegate)
protocol UMEventDelegate: NSObjectProtocol {
	@objc(applicationWillSendEvent:)
	optional func applicationWillSendEvent(_ event: NSEvent) -> Bool
}

@objc(UMApplication)
final class UMApplication: NSApplication {
	private weak var eventsDelegate: UMEventDelegate?

	@objc(setEventDelegate:)
	func setEventDelegate(_ eventDelegate: UMEventDelegate?) {
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
