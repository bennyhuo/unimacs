// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
@preconcurrency import ApplicationServices

@objcMembers
class AccessibilityManager: NSObject {
	
	static var isTrusted: Bool {
		AXIsProcessTrusted()
	}

	static func checkAccessibility() -> Bool {
		AXIsProcessTrustedWithOptions([
			kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
		] as CFDictionary)
	}
	
}
