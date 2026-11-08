// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import CoreGraphics

@MainActor
@objcMembers
final class SystemStatusObserver: NSObject {

	static let shared = SystemStatusObserver()

    private static let KEY_SCREEN_LOCKED = "com.apple.screenIsLocked"
    private static let KEY_SCREEN_UNLOCKED = "com.apple.screenIsUnlocked"

    private(set) var isLocked: Bool = false

    func register() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onScreenLocked), name: NSNotification.Name(Self.KEY_SCREEN_LOCKED), object: nil)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onScreenUnlocked), name: NSNotification.Name(Self.KEY_SCREEN_UNLOCKED),
            object: nil)

        isLocked = Self.isScreenLocked()
    }

    func unregister() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

	@objc private func didWake() {
        MainController.shared().resetAllConnectionsIfNotInControl()
    }

	@objc private func onScreenLocked() {
        self.isLocked = true
    }

	@objc private func onScreenUnlocked() {
        self.isLocked = false
        MainController.shared().resetAllConnectionsIfNotInControl()
    }

    private static func isScreenLocked() -> Bool {
        guard let sessionInfo = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }

        let locked = sessionInfo["CGSSessionScreenIsLocked"] as? Bool
        return locked == true
    }
}
