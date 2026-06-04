// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

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
}
