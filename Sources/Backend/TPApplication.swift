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

@objc(TPApplication)
final class TPApplication: NSApplication {
	private weak var eventsDelegate: TPEventDelegate?

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
