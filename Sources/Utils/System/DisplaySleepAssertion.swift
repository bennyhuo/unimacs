// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import IOKit.pwr_mgt

@MainActor
@objcMembers
final class DisplaySleepAssertion: NSObject {
    private static var assertionID: IOPMAssertionID = 0
	
    static func activate(reason: String = "Prevent screen lock") {
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )

        if result != kIOReturnSuccess {
            debugLog("Failed to create assertion")
        }
    }

    static func deactivate() {
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }
}
