// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import OSLog

// MARK: - Log Subsystem

private let logSubsystem = Bundle.main.bundleIdentifier ?? "com.teleport"

// MARK: - Log Module

/// Log modules for filtering logs by functional area
@objc enum LogModule: Int32, CaseIterable {
    case general = 0      // General/misc logs
    case network = 1      // Network connections, sockets
    case transfer = 2     // File/data transfers
    case clipboard = 3    // Pasteboard/clipboard operations
    case control = 4      // Control switching, host management
    case security = 5     // Authentication, encryption
    
    var displayName: String {
        switch self {
        case .general: return "General"
        case .network: return "Network"
        case .transfer: return "Transfer"
        case .clipboard: return "Clipboard"
        case .control: return "Control"
        case .security: return "Security"
        }
    }
    
    var description: String {
        switch self {
        case .general: return "General application logs"
        case .network: return "Network connections and sockets"
        case .transfer: return "File and data transfers"
        case .clipboard: return "Clipboard synchronization"
        case .control: return "Host control and switching"
        case .security: return "Authentication and encryption"
        }
    }
    
    var settingsKey: String {
        return "logModule_\(self.rawValue)_enabled"
    }
    
    var logger: Logger {
        switch self {
        case .general: return Log.general
        case .network: return Log.network
        case .transfer: return Log.transfer
        case .clipboard: return Log.clipboard
        case .control: return Log.control
        case .security: return Log.security
        }
    }
    
    /// Check if this module's logging is enabled
    var isEnabled: Bool {
        // Default to enabled if not set
        let prefs = TPPreferencesManager.shared()
        // Use value(forPref:) to check if key exists
        if prefs.value(forPref: settingsKey) == nil {
            return true // Default enabled
        }
        return prefs.bool(forPref: settingsKey)
    }
}

// MARK: - Log Categories

struct Log {
    static let network = Logger(subsystem: logSubsystem, category: "Network")
    static let transfer = Logger(subsystem: logSubsystem, category: "Transfer")
    static let general = Logger(subsystem: logSubsystem, category: "General")
    static let connection = Logger(subsystem: logSubsystem, category: "Connection")
    static let clipboard = Logger(subsystem: logSubsystem, category: "Clipboard")
    static let control = Logger(subsystem: logSubsystem, category: "Control")
    static let security = Logger(subsystem: logSubsystem, category: "Security")
}

// MARK: - Log Level

@objc enum LogLevel: Int32, Comparable, CaseIterable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    var prefix: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
    
    var displayName: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }
    
    var icon: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
}

// MARK: - Log Level Helper

private func currentMinLogLevel() -> LogLevel {
    let rawValue = TPPreferencesManager.shared().int(forPref: Settings.logLevelKey)
    return LogLevel(rawValue: rawValue) ?? .debug
}

private func shouldLog(level: LogLevel) -> Bool {
    return level >= currentMinLogLevel()
}

// MARK: - Log Formatting Helper

private func formatLogMessage(
    _ messages: [Any],
	threadLabel: String,
    file: String,
    function: String,
    line: Int,
    level: LogLevel,
    connectionId: String? = nil
) -> String {
    let message = messages.map { message in
        switch message {
        case Optional<Any>.none: "(nil)"
        case let Optional<Any>.some(value): "\(value)"
        default: "\(message)"
        }
    }.joined(separator: ", ")
    
    var components = [String]()
    
    #if DEBUG
    // Debug build: include file, line, and function info
    let fileName = (file as NSString).lastPathComponent
    let fileNameWLE = fileName.replacingOccurrences(of: ".swift", with: "")
    components.append("[\(fileName):\(line)]")
    components.append("[\(threadLabel)]")
    if let connId = connectionId {
        components.append("[Conn:\(connId)]")
    }
    components.append("[\(fileNameWLE) \(function)]")
    #else
    // Release build: hide sensitive code location info
    components.append("[\(threadLabel)]")
    if let connId = connectionId {
        components.append("[Conn:\(connId)]")
    }
    #endif
    
    components.append("\(level.prefix)")
    components.append(message)
    
    return components.joined(separator: " ")
}

// MARK: - Debug Log (Controlled by Settings)
private func commonLog(
	_ messages: Any...,
	level: LogLevel = .debug,
	module: LogModule = .general,
	file: String = #file,
	function: String = #function,
	line: Int = #line,
	connectionId: String? = nil
) {
	let machThreadId = pthread_mach_thread_np(pthread_self())
	let threadLabel = Thread.isMainThread ? "MAIN " : String(format: "T-%-5u", machThreadId)
	
	DispatchQueue.global().async {
		guard module.isEnabled else {
			return
		}
		
		guard shouldLog(level: level) else {
			return
		}
		
		let formattedMessage = formatLogMessage(
			messages,
			threadLabel: threadLabel,
			file: file,
			function: function,
			line: line,
			level: level,
			connectionId: connectionId
		)
		
		// Always persist the full log stream to the rotating local file.
		// This keeps high-frequency connection logs off the console while
		// remaining available for troubleshooting.
		TPFileLogger.shared.append(level: level, category: module.displayName, message: formattedMessage)
		
		// Console (unified log) only receives key logs: warnings and errors.
		// When the user enables debug logging, mirror everything to the console
		// for live development as well.
		let mirrorToConsole = level >= .warning
			|| TPPreferencesManager.shared().bool(forPref: Settings.enableDebugLogKey)
		guard mirrorToConsole else { return }
		
		let logger = module.logger
		switch level {
		case .debug:
			logger.debug("\(formattedMessage, privacy: .public)")
		case .info:
			logger.info("\(formattedMessage, privacy: .public)")
		case .warning:
			logger.warning("\(formattedMessage, privacy: .public)")
		case .error:
			logger.error("\(formattedMessage, privacy: .public)")
		}
	}
}

func debugLog(
    _ messages: Any...,
    module: LogModule = .general,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    connectionId: String? = nil
) {
	commonLog(messages, level: .debug, module: module, file: file, function: function, line: line, connectionId: connectionId)
}

// MARK: - Error Log (Always Logged)

/// Error log that is always recorded regardless of debug settings.
/// Use this for critical errors that should always be captured.
func errorLog(
    _ messages: Any...,
    module: LogModule = .general,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    connectionId: String? = nil
) {
	commonLog(messages, level: .error, module: module, file: file, function: function, line: line, connectionId: connectionId)
}

/// Warning log that is always recorded regardless of debug settings.
func warningLog(
    _ messages: Any...,
    module: LogModule = .general,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    connectionId: String? = nil
) {
	commonLog(messages, level: .warning, module: module, file: file, function: function, line: line, connectionId: connectionId)
}

/// Info log that is always recorded regardless of debug settings.
func infoLog(
    _ messages: Any...,
    module: LogModule = .general,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    connectionId: String? = nil
) {
	commonLog(messages, level: .info, module: module, file: file, function: function, line: line, connectionId: connectionId)
}

func networkDebugLog(
	_ messages: Any...,
	file: String = #file,
	function: String = #function,
	line: Int = #line
) {
	debugLog(messages, module: .transfer, file: file, function: function, line: line)
}


// MARK: - Log Exporter

@objc class LogExporter: NSObject {
    
    @objc static let shared = LogExporter()
    
    private override init() {
        super.init()
    }
    
    /// Export logs from the last specified duration to a temporary file
    /// - Parameter duration: Time interval in seconds (default: 1 hour)
    /// - Returns: URL to the exported log file, or nil if export failed
    @objc func exportLogs(duration: TimeInterval = 3600) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let logFileName = "teleport_logs_\(timestamp).txt"
        let logFileURL = tempDir.appendingPathComponent(logFileName)
        
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-duration))
            
            let predicate = NSPredicate(format: "subsystem == %@", logSubsystem)
            let entries = try store.getEntries(at: position, matching: predicate)
            
            var logContent = "Teleport Log Export\n"
            logContent += "Exported: \(Date())\n"
            logContent += "Duration: Last \(Int(duration / 60)) minutes\n"
            logContent += "App Version: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")\n"
            logContent += "macOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
            logContent += String(repeating: "=", count: 80) + "\n\n"
            
            let dateFormatterLog = DateFormatter()
            dateFormatterLog.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            
            for entry in entries {
                if let logEntry = entry as? OSLogEntryLog {
                    let timestamp = dateFormatterLog.string(from: logEntry.date)
                    let level = logLevelString(from: logEntry.level)
                    logContent += "[\(timestamp)] [\(level)] [\(logEntry.category)] \(logEntry.composedMessage)\n"
                }
            }
            
            try logContent.write(to: logFileURL, atomically: true, encoding: .utf8)
            return logFileURL
            
        } catch {
            NSLog("[LogExporter] Failed to export logs: \(error)")
            return nil
        }
    }
    
    /// Package the local rotating log files (~/Library/Logs/Teleport/) into a
    /// single zip archive in the temporary directory.
    /// - Returns: URL to the zip archive, or nil if no logs exist / archiving failed.
    @objc func exportLogArchive() -> URL? {
        let logDir = TPFileLogger.shared.logDirectoryURL

        // Make sure the directory exists and actually contains log files.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: logDir,
            includingPropertiesForKeys: nil
        )) ?? []
        let logFiles = contents.filter { $0.pathExtension == "log" }
        guard !logFiles.isEmpty else {
            NSLog("[LogExporter] No log files to export at \(logDir.path)")
            return nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let archiveName = "teleport_logs_\(dateFormatter.string(from: Date())).zip"
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(archiveName)
        try? FileManager.default.removeItem(at: destinationURL)

        // NSFileCoordinator with .forUploading produces a zip of the directory.
        var coordinatorError: NSError?
        var didSucceed = false
        NSFileCoordinator().coordinate(
            readingItemAt: logDir,
            options: [.forUploading],
            error: &coordinatorError
        ) { zippedURL in
            do {
                try FileManager.default.copyItem(at: zippedURL, to: destinationURL)
                didSucceed = true
            } catch {
                NSLog("[LogExporter] Failed to copy zipped logs: \(error)")
            }
        }

        if let coordinatorError = coordinatorError {
            NSLog("[LogExporter] Failed to archive logs: \(coordinatorError)")
            return nil
        }

        return didSucceed ? destinationURL : nil
    }

    private func logLevelString(from level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        default: return "UNKNOWN"
        }
    }
    
    /// Share logs via system share sheet (async version with completion)
    @objc func shareLogs(from view: NSView? = nil, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let logURL = self?.exportLogArchive()
            
            DispatchQueue.main.async {
                defer { completion?() }
                
                guard let logURL = logURL else {
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = "Unable to export logs. Please try again."
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
                
                let picker = NSSharingServicePicker(items: [logURL])
                if let view = view ?? NSApp.keyWindow?.contentView {
                    picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
                }
            }
        }
    }
    
    /// Save logs to user-selected location (async version with completion)
    @objc func saveLogs(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let logURL = self?.exportLogArchive()
            
            DispatchQueue.main.async {
                guard let logURL = logURL else {
                    completion?()
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = "Unable to export logs. Please try again."
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
                
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.zip]
                savePanel.nameFieldStringValue = logURL.lastPathComponent
                savePanel.message = "Choose where to save the log archive"
                
                savePanel.begin { response in
                    defer { completion?() }
                    
                    if response == .OK, let destinationURL = savePanel.url {
                        do {
                            if FileManager.default.fileExists(atPath: destinationURL.path) {
                                try FileManager.default.removeItem(at: destinationURL)
                            }
                            try FileManager.default.copyItem(at: logURL, to: destinationURL)
                        } catch {
                            let alert = NSAlert()
                            alert.messageText = "Save Failed"
                            alert.informativeText = "Unable to save log file: \(error.localizedDescription)"
                            alert.alertStyle = .warning
                            alert.runModal()
                        }
                    }
                }
            }
        }
    }
}
