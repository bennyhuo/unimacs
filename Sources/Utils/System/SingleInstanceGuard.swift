// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation

@MainActor
enum SingleInstanceGuard {

    /// Open file descriptor that holds the exclusive lock for the lifetime of the
    /// process. Kept alive intentionally; the kernel releases the lock when the
    /// process exits (including on crash), so no manual cleanup is required.
    private static var lockFileDescriptor: Int32 = -1

    /// Tries to become the single running instance.
    ///
    /// Acquisition relies on an exclusive, non-blocking `flock` on a well-known
    /// lock file. `flock` is atomic, so two instances launched simultaneously
    /// cannot both win, and the lock is reclaimed automatically by the kernel if
    /// the owning process dies, so a crash never leaves a stale lock behind.
    ///
    /// - Returns: `true` if this process is now the sole instance, `false` if
    ///   another instance already holds the lock.
    static func acquire() -> Bool {
        let path = lockFilePath()

        let fd = open(path, O_CREAT | O_RDWR, 0o666)
        guard fd >= 0 else {
            // Failing to open the lock file should not prevent the app from
            // starting; fail open rather than block the user entirely.
            errorLog("Single-instance guard: unable to open lock file at \(path) (errno \(errno))", module: .control)
            return true
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // EWOULDBLOCK means another instance holds the lock.
            close(fd)
            return false
        }

        lockFileDescriptor = fd
        return true
    }

    /// Brings the already-running instance to the foreground so the user gets
    /// visible feedback when they re-launch the app.
    static func activateExistingInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let current = NSRunningApplication.current
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != current.processIdentifier
        }
        others.first?.activate(options: [.activateAllWindows])
    }

    private static func lockFilePath() -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.bennyhuo.unimacs"
        return "/tmp/\(bundleID).instance.lock"
    }
}
