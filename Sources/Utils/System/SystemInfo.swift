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

    /// Formats an encoded macOS version integer (`major * 100 + minor`) as `"macOS X.Y"`.
    static func formatOSVersion(_ version: Int) -> String {
        let major = version / 100
        let minor = version % 100
        return "macOS \(major).\(minor)"
    }

    // MARK: - Application Metadata

    static var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "Unimacs"
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1.0"
    }

    static var appBuildNumber: String {
        Bundle.main.infoDictionary?["TPRevision"] as? String ?? ""
    }

    static var appCopyright: String {
        Bundle.main.localizedInfoDictionary?["NSHumanReadableCopyright"] as? String
            ?? Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? "Copyright © 2003–2012 abyssoft (Julien Robert), 2020–2023 John Britton, 2025–2026 Benny Huo."
    }

    static var appVersionStrings: [String] {
        var versions = [
            "Version \(appVersion)",
            "Build \(appBuildNumber)"
        ]
        if let translationInfo = Bundle.main.localizedInfoDictionary?["TPTranslationInfoString"] as? String {
            versions.append(translationInfo)
        }
        return versions
    }

    static let githubRepositoryURL = URL(string: "https://github.com/bennyhuo/unimacs")!
    static let githubIssuesURL = URL(string: "https://github.com/bennyhuo/unimacs/issues")!
    static let licenseURL = URL(string: "https://github.com/bennyhuo/unimacs/blob/main/LICENSE")!
    static let upstreamTeleportURL = URL(string: "https://github.com/johndbritton/teleport")!
    static let originalTeleportURL = URL(string: "https://github.com/abyssoft/teleport")!
    static let blackHoleURL = URL(string: "https://existential.audio/blackhole/")!
    
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
