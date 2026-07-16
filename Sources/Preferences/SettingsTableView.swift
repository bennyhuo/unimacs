// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

@objc(SettingsTableView)
final class SettingsTableView: NSTableView {
	override func keyDown(with event: NSEvent) {
		let sel = Selector(("tableView:handleKeyDown:"))
		if let del = delegate as AnyObject?, del.responds(to: sel) {
			if let unmanaged = del.perform(sel, with: self, with: event) {
				let value = unmanaged.takeUnretainedValue()
				if let num = value as? NSNumber, num.boolValue {
					return
				}
			}
		}
		super.keyDown(with: event)
	}
}
