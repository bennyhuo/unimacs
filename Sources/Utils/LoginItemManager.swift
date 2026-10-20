// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import ServiceManagement
import os.log

/// Manages the app's login item registration via `SMAppService`.
///
/// macOS 13.0+ provides `SMAppService.mainApp` to register or unregister
/// the current application as a login item. This replaces the deprecated
/// `SMLoginItemSetEnabled` and Launch Services shared file list APIs.
enum LoginItemManager {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.unimacs",
        category: "LoginItemManager"
    )

    /// Update the login item registration to match the desired state.
    ///
    /// - Parameter enabled: `true` to register as a login item, `false` to unregister.
    static func updateRegistration(enabled: Bool) {
        let service = SMAppService.mainApp

        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                    logger.info("Registered as login item")
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                    logger.info("Unregistered from login items")
                }
            }
        } catch {
            logger.error("Failed to update login item registration (enabled=\(enabled)): \(error.localizedDescription)")
        }
    }

    /// Returns the current registration status.
    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
