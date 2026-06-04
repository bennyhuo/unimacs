// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import IOKit
import CoreFoundation
import IOKit.pwr_mgt

@_silgen_name("SACLockScreenImmediate") func SACLockScreenImmediate() -> Int32

@objcMembers
class SystemPowerManager: NSObject {
	
	static func lockScreen() {
		// FixMe: Remove the private API!!!
		let _ = SACLockScreenImmediate()
	}
	
	static func wakeUpScreen() {
		var assertionID: IOPMAssertionID = 0
		var success: IOReturn
		
		// 1. Create a general assertion to prevent display sleep (kIOPMAssertionTypeNoDisplaySleep)
		// This is often good practice before attempting to force the screen on.
		success = IOPMAssertionCreateWithName(
			kIOPMAssertionTypeNoDisplaySleep as CFString,
			IOPMAssertionLevel(kIOPMAssertionLevelOn),
			"SwiftApp_NoDisplaySleep_Wake" as CFString,
			&assertionID
		)
		if success == kIOReturnSuccess {
			// Immediately release the assertion—it served its purpose as a brief system nudge.
			IOPMAssertionRelease(assertionID)
			assertionID = 0 // Reset for safety
		} else {
			debugLog("IOPMAssertionCreateWithDescription failed: \(success)")
		}
		
		// 2. Tweak the IODisplayWrangler (Legacy/Pre-Big Sur method)
		// This attempts to set IORequestIdle to False to force the display out of an idle state.
		let entry = IORegistryEntryFromPath(
			kIOMasterPortDefault,
			"IOService:/IOResources/IODisplayWrangler"
		)
		
		if entry != MACH_PORT_NULL {
			// Note: CFSTR is bridged to CFString in Swift. kCFBooleanFalse is available via CoreFoundation.
			IORegistryEntrySetCFProperty(entry, "IORequestIdle" as CFString, kCFBooleanFalse)
			IOObjectRelease(entry)
		} else {
			debugLog("Error: Could not find IODisplayWrangler entry.")
		}
		
		// 3. Declare User Activity (Recommended for M1/Big Sur+)
		// This is the explicit way to tell Power Management that the user is active,
		// which reliably wakes the display and system instantly.
		let activityReason = "SwiftApp_WakeScreen_UserActivity" as CFString
		success = IOPMAssertionDeclareUserActivity(activityReason, kIOPMUserActiveLocal, &assertionID)
		
		if success == kIOReturnSuccess {
			// Release the activity assertion after a brief period, or immediately if just for a nudge.
			// Keeping it alive too long prevents sleep. Release immediately as in the ObjC code:
			IOPMAssertionRelease(assertionID)
		} else {
			debugLog("IOPMAssertionDeclareUserActivity failed: \(success)")
		}
	}
	
	// MARK: - Sleep Screen (Based on Objective-C sleepScreen)
	
	static func sleepScreen() {
		// This function forces the display to enter its idle state, causing it to sleep.
		let entry = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/IOResources/IODisplayWrangler")
		
		if entry != MACH_PORT_NULL {
			// Note: kCFBooleanTrue is used to request the idle state (sleep).
			IORegistryEntrySetCFProperty(entry, "IORequestIdle" as CFString, kCFBooleanTrue)
			IOObjectRelease(entry)
		} else {
			debugLog("Error: Could not find IODisplayWrangler entry for sleep.")
		}
	}
	
	// MARK: - Sleep System (Based on Objective-C sleepTheSystem)
	
	static func sleepTheSystem() {
		// The IOPMFindPowerManagement function is also available through IOPowerManagement
		let fb = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
		
		if fb != MACH_PORT_NULL {
			let status = IOPMSleepSystem(fb)
			
			if status != kIOReturnSuccess {
				debugLog("Error initiating system sleep: \(status)")
			}
			
			IOServiceClose(fb)
		} else {
			debugLog("Error: Could not find Power Management service.")
		}
	}
}
