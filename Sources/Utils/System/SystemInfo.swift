// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import IOKit.ps

class SystemInfo {
    /// Returns macOS version encoded as: major * 100 + minor
    /// e.g., macOS 15.2 -> 1502, macOS 14.0 -> 1400
    static var osVersion: Int {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion * 100 + version.minorVersion
    }
    
    /// Returns the major macOS version number (e.g., 15 for macOS 15.x)
    static var osMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }
    
    /// Returns true if the device is a laptop (i.e. has an internal battery)
    static var isLaptop: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               let type = description[kIOPSTypeKey] as? String,
               type == kIOPSInternalBatteryType {
                return true
            }
        }
        return false
    }
}
