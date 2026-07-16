// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import AppKit

@objc final class FileLogger: NSObject {

    @objc static let shared = FileLogger()

    /// Number of days of log files to keep. Older files are pruned on launch
    /// and whenever the active file rolls over to a new day.
    private static let retentionDays = 7

    private let queue = DispatchQueue(label: "com.unimacs.filelogger", qos: .utility)
    private var handle: FileHandle?
    private var currentDayKey = ""

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    // MARK: - Lifecycle

    private override init() {
        super.init()
        queue.async { [weak self] in
            self?.ensureDirectoryExists()
            self?.pruneOldLogs()
        }
    }

    // MARK: - Paths

    /// Directory where log files are stored: ~/Library/Logs/Unimacs/
    @objc var logDirectoryURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Unimacs", isDirectory: true)
    }

    private func fileURL(forDayKey dayKey: String) -> URL {
        return logDirectoryURL.appendingPathComponent("unimacs-\(dayKey).log", isDirectory: false)
    }

    // MARK: - Public API

    /// Append a formatted log entry to the current day's file.
    /// The actual file I/O happens asynchronously on a serial queue.
    func append(level: LogLevel, category: String, message: String, date: Date = Date()) {
        let timestamp = timestampFormatter.string(from: date)
        let line = "\(timestamp) [\(level.fileTag)] [\(category)] \(message)\n"
        queue.async { [weak self] in
            self?.write(line: line, date: date)
        }
    }

    /// Reveal the log directory in Finder (creating it first if needed).
    @objc func revealLogDirectoryInFinder() {
        queue.async { [weak self] in
            self?.ensureDirectoryExists()
            guard let url = self?.logDirectoryURL else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - File handling (serial queue only)

    private func ensureDirectoryExists() {
        let dir = logDirectoryURL
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func write(line: String, date: Date) {
        rotateIfNeeded(for: date)
        guard let handle = handle, let data = line.data(using: .utf8) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Reset the handle so the next write tries to reopen the file.
            try? handle.close()
            self.handle = nil
        }
    }

    private func rotateIfNeeded(for date: Date) {
        let dayKey = dayFormatter.string(from: date)
        if dayKey == currentDayKey, handle != nil {
            return
        }

        // Close the previous day's handle.
        if let handle = handle {
            try? handle.close()
            self.handle = nil
        }

        ensureDirectoryExists()

        let url = fileURL(forDayKey: dayKey)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        handle = try? FileHandle(forWritingTo: url)
        currentDayKey = dayKey

        // A new day started (or the logger just launched): prune stale files.
        pruneOldLogs()
    }

    private func pruneOldLogs() {
        let dir = logDirectoryURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }

        let calendar = Calendar.current
        let cutoff = calendar.startOfDay(for: Date()).addingTimeInterval(-Double(Self.retentionDays) * 86_400)

        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("unimacs-"), name.hasSuffix(".log") else { continue }

            let dayString = name
                .replacingOccurrences(of: "unimacs-", with: "")
                .replacingOccurrences(of: ".log", with: "")
            guard let fileDate = dayFormatter.date(from: dayString) else { continue }

            if fileDate < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

// MARK: - LogLevel file tag

private extension LogLevel {
    var fileTag: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}

// MARK: - ObjC bridge (callable from C/ObjC log macros in common.h)

/// C-callable entry point used by the Objective-C logging macros.
/// `level` and `module` match the raw values of `LogLevel` / `LogModule`.
@_cdecl("TPFileLog")
func TPFileLog(_ level: Int32, _ module: Int32, _ cMessage: UnsafePointer<CChar>) {
    let logLevel = LogLevel(rawValue: level) ?? .debug

    // Honor the configured minimum log level for the file as well.
    let minLevel = LogLevel(rawValue: PreferencesManager.shared().int(forPref: Settings.logLevelKey)) ?? .debug
    guard logLevel >= minLevel else { return }

    let category = (LogModule(rawValue: module) ?? .general).displayName
    let message = String(cString: cMessage)
    FileLogger.shared.append(level: logLevel, category: category, message: message)
}
