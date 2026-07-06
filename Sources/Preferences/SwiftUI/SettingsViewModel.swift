// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  Created for modern SwiftUI settings interface.

import SwiftUI
import Combine
import SecurityInterface
import Darwin

@MainActor
final class SettingsViewModel: ObservableObject {
    
    private let prefs: TPPreferencesManager
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Core Settings
    
    @Published var allowControl: Bool {
        didSet { prefs.setValue(allowControl, forKey: Settings.allowControlKey) }
    }
    
    @Published var trustRequestBehavior: TrustRequestBehavior {
        didSet { prefs.setValue(trustRequestBehavior.rawValue, forKey: Settings.trustRequestBehaviorKey) }
    }
    
    // MARK: - Switching Behavior
    
    @Published var requireKey: Bool {
        didSet { prefs.setValue(requireKey, forKey: Settings.requireKeyKey) }
    }
    
    @Published var switchKeyTag: ModifierKeyTag {
        didSet { prefs.setValue(switchKeyTag.rawValue, forKey: Settings.switchKeyTagKey) }
    }
    
    @Published var delayedSwitch: Bool {
        didSet { prefs.setValue(delayedSwitch, forKey: Settings.delayedSwitchKey) }
    }
    
    @Published var switchDelay: Double {
        didSet { prefs.setValue(switchDelay, forKey: Settings.switchDelayKey) }
    }

    /// When enabled, input events are streamed directly to the remote for full
    /// gesture support. When disabled, the compatibility event-taps mode is used.
    /// Takes effect on the next (re)connect.
    @Published var useDirectEventTaps: Bool {
        didSet { prefs.setValue(useDirectEventTaps, forKey: Settings.useDirectEventTapsKey) }
    }

    /// Cursor hiding strategy while controlling a remote Mac. When enabled
    /// (Scheme A, the default), teleport is brought to the foreground behind a
    /// transparent shield window and the public cursor-hiding API is used, which
    /// works reliably on macOS 26+. When disabled (Scheme B), the legacy private
    /// background hack is used instead. Takes effect on the next control session.
    /// When enabled, the cursor is warped to the center of the main screen
    /// after a control session ends. Off by default.
    @Published var warpCursorOnStopControl: Bool {
        didSet { prefs.setValue(warpCursorOnStopControl, forKey: Settings.wrapOnStopControlKey) }
    }

    @Published var useCursorShieldWindow: Bool {
        didSet { prefs.setValue(useCursorShieldWindow, forKey: Settings.useCursorShieldWindowKey) }
    }
    
    // MARK: - Network
    
    @Published var disconnectOnNetworkChange: Bool {
        didSet { prefs.setValue(disconnectOnNetworkChange, forKey: Settings.disconnectOnNetworkConfigChangeKey) }
    }

    /// Experimental: use the Swift Network.framework stack for the control
    /// connection instead of the legacy ObjC socket. Takes effect on the next
    /// (re)connect.
    @Published var useSwiftNetworkStack: Bool {
        didSet { prefs.setValue(useSwiftNetworkStack, forKey: Settings.useSwiftNetworkStackKey) }
    }
    
    // MARK: - Notifications
    
    @Published var hideControlBezel: Bool {
        didSet { prefs.setValue(hideControlBezel, forKey: Settings.hideControlBezelKey) }
    }
    
    @Published var showSwitchAnimation: Bool {
        didSet { prefs.setValue(showSwitchAnimation, forKey: Settings.showSwitchAnimationKey) }
    }
    
    @Published var playSwitchSound: Bool {
        didSet { prefs.setValue(playSwitchSound, forKey: Settings.playSwitchSoundKey) }
    }
    
    // MARK: - Debug
    
    @Published var enableLogging: Bool {
        didSet { prefs.setValue(enableLogging, forKey: Settings.enableDebugLogKey) }
    }
    
    @Published var logLevel: LogLevel {
        didSet { prefs.setValue(logLevel.rawValue, forKey: Settings.logLevelKey) }
    }

    /// Show the hot border debug visuals (edge glow + activation effect).
    /// Takes effect the next time hot borders are rebuilt (host/connection change).
    @Published var showHotBorderVisuals: Bool {
        didSet { prefs.setValue(showHotBorderVisuals, forKey: Settings.visibleBordersKey) }
    }

    /// Visual style for the hot border decoration.
    @Published var hotBorderStyle: HotBorderVisualStyle {
        didSet { prefs.setValue(hotBorderStyle.rawValue, forKey: Settings.hotBorderStyleKey) }
    }
    
    // MARK: - Log Module Settings
    
    @Published var logModuleStates: [LogModule: Bool] = [:]
    
    func binding(for module: LogModule) -> Binding<Bool> {
        Binding(
            get: { [weak self] in
                self?.logModuleStates[module] ?? true
            },
            set: { [weak self] newValue in
                self?.logModuleStates[module] = newValue
                self?.prefs.setValue(newValue, forKey: module.settingsKey)
            }
        )
    }
    
    // MARK: - Transfer Settings
    
    @Published var transferProgressThreshold: Int {
        didSet { prefs.setValue(transferProgressThreshold, forKey: Settings.transferProgressThresholdKey) }
    }
    
    // MARK: - Cache Management
    
    @Published var cacheSize: String = "Calculating..."
    
    private var directoryMonitor: DispatchSourceFileSystemObject?
    private var monitorQueue = DispatchQueue(label: "com.teleport.cacheMonitor", qos: .background)
    private var refreshTimer: Timer?
    
    nonisolated private var cacheDirectory: URL {
        let tempDir = NSTemporaryDirectory()
        return URL(fileURLWithPath: tempDir).appendingPathComponent("teleport-pasteboard-files")
    }
    
    func calculateCacheSize() {
        // Try to start monitoring if not already monitoring
        if directoryMonitor == nil && FileManager.default.fileExists(atPath: cacheDirectory.path) {
            startMonitoring()
        }
        
        Task.detached(priority: .background) {
            let size = self.getDirectorySize(url: self.cacheDirectory)
            let formattedSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            await MainActor.run {
                self.cacheSize = formattedSize
            }
        }
    }
    
    func clearCache() {
        // Don't stop monitoring, just clear contents
        Task.detached(priority: .userInitiated) {
            do {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: self.cacheDirectory.path) {
                    let fileURLs = try fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: nil)
                    for fileURL in fileURLs {
                        try fileManager.removeItem(at: fileURL)
                    }
                }
            } catch {
                print("Failed to clear cache: \(error)")
            }
            await self.calculateCacheSize()
        }
    }
    
    func openCacheDirectory() {
        // Create directory if it doesn't exist, so Finder can open it
        if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            // Start monitoring since we just created it
            startMonitoring()
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cacheDirectory.path)
    }
    
    private func startMonitoring() {
        stopMonitoring()
        
        let path = cacheDirectory.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        
        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: monitorQueue
        )
        
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            // If directory is deleted or renamed, stop monitoring
            let event = source.data
            if event.contains(.delete) || event.contains(.rename) {
                Task { @MainActor in
                    self.stopMonitoring()
                    self.calculateCacheSize()
                }
                return
            }
            
            // Debounce the refresh slightly to avoid excessive updates during rapid writes
            Task { @MainActor in
                self.calculateCacheSize()
            }
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
        directoryMonitor = source
    }
    
    private func stopMonitoring() {
        directoryMonitor?.cancel()
        directoryMonitor = nil
    }
    
    func startPeriodicRefresh() {
        calculateCacheSize()
        // Check periodically to start monitoring if directory is created later
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.directoryMonitor == nil {
                self.calculateCacheSize()
            }
        }
    }
    
    func stopPeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopMonitoring()
    }
    
    nonisolated private func getDirectorySize(url: URL) -> UInt64 {
        let fileManager = FileManager.default
        var size: UInt64 = 0
        
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else {
            return 0
        }
        
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  let isDirectory = resourceValues.isDirectory,
                  !isDirectory,
                  let fileSize = resourceValues.fileSize else {
                continue
            }
            size += UInt64(fileSize)
        }
        
        return size
    }
    
    // MARK: - IP Address
    
    @Published var selectedIPAddress: String = "" {
        didSet {
            TPNetworkConfigurationWatcher.shared.selectLocalIpAddress(selectedIPAddress)
        }
    }
    @Published var availableIPAddresses: [String] = []
    
    // MARK: - Initialization
    
    init() {
        prefs = TPPreferencesManager.shared()
        
        // Load initial values from preferences
        allowControl = prefs.bool(forPref: Settings.allowControlKey)
        trustRequestBehavior = TrustRequestBehavior(rawValue: prefs.int(forPref: Settings.trustRequestBehaviorKey)) ?? .ask
        
        requireKey = prefs.bool(forPref: Settings.requireKeyKey)
        switchKeyTag = ModifierKeyTag(rawValue: prefs.int(forPref: Settings.switchKeyTagKey)) ?? .option
        delayedSwitch = prefs.bool(forPref: Settings.delayedSwitchKey)
        switchDelay = Double(prefs.float(forPref: Settings.switchDelayKey))
        useDirectEventTaps = prefs.bool(forPref: Settings.useDirectEventTapsKey)
        useCursorShieldWindow = prefs.bool(forPref: Settings.useCursorShieldWindowKey)
        warpCursorOnStopControl = prefs.bool(forPref: Settings.wrapOnStopControlKey)
        
        disconnectOnNetworkChange = prefs.bool(forPref: Settings.disconnectOnNetworkConfigChangeKey)
        useSwiftNetworkStack = prefs.bool(forPref: Settings.useSwiftNetworkStackKey)
        
        hideControlBezel = prefs.bool(forPref: Settings.hideControlBezelKey)
        showSwitchAnimation = prefs.bool(forPref: Settings.showSwitchAnimationKey)
        playSwitchSound = prefs.bool(forPref: Settings.playSwitchSoundKey)
        
        enableLogging = prefs.bool(forPref: Settings.enableDebugLogKey)
        logLevel = LogLevel(rawValue: prefs.int(forPref: Settings.logLevelKey)) ?? .debug
        showHotBorderVisuals = prefs.bool(forPref: Settings.visibleBordersKey)
        hotBorderStyle = HotBorderVisualStyle(rawValue: prefs.int(forPref: Settings.hotBorderStyleKey)) ?? .glow
        
        // Load transfer threshold, use default if not set
        let savedThreshold = prefs.int(forPref: Settings.transferProgressThresholdKey)
        transferProgressThreshold = savedThreshold > 0 ? Int(savedThreshold) : Settings.transferProgressThresholdDefault
        
        // Load log module states (must be after all stored properties are initialized)
        for module in LogModule.allCases {
            logModuleStates[module] = module.isEnabled
        }
        
        loadIPAddresses()
        calculateCacheSize()
    }
    
    // MARK: - Actions
    
    func resetConnections() {
        TPMainController.shared().resetAllConnections()
    }
    
    private func loadIPAddresses() {
		let watcher = TPNetworkConfigurationWatcher.shared
		availableIPAddresses = watcher.localIpAddresses
		selectedIPAddress = watcher.selectedLocalIpAddress
    }
}

// MARK: - Enums

enum TrustRequestBehavior: Int32, CaseIterable, Identifiable {
    case ask = 0
    case reject = 1
    case accept = 2
    
    var id: Int32 { rawValue }
    
    var title: String {
        switch self {
        case .ask: return "Ask me if host can be trusted"
        case .reject: return "Reject if host not already trusted"
        case .accept: return "Automatically accept"
        }
    }
    
    var description: String {
        switch self {
        case .ask: return "You'll be prompted when a new host tries to connect"
        case .reject: return "Only previously trusted hosts can connect"
        case .accept: return "Any host on your network can connect automatically"
        }
    }
}

enum ModifierKeyTag: Int32, CaseIterable, Identifiable {
    case command = 20
    case option = 19
    case control = 18
    case shift = 17
    case capsLock = 16
    
    var id: Int32 { rawValue }
    
    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .capsLock: return "⇪"
        }
    }
    
    var title: String {
        switch self {
        case .command: return "Command"
        case .option: return "Option"
        case .control: return "Control"
        case .shift: return "Shift"
        case .capsLock: return "Caps Lock"
        }
    }
    
    var displayTitle: String {
        "\(symbol) \(title)"
    }
}

// MARK: - Trusted Host Info

struct TrustedHostInfo: Identifiable {
    let id: String
    let name: String
    let address: String
    let hasCertificate: Bool
    let remoteHost: TPRemoteHost
    
    init(from remoteHost: TPRemoteHost) {
        self.id = remoteHost.identifier
        self.name = remoteHost.computerName
        self.address = remoteHost.address ?? ""
        self.hasCertificate = remoteHost.isCertified
        self.remoteHost = remoteHost
    }
    
    var systemIconName: String {
        remoteHost.hasCapability(.portable) ? "laptopcomputer" : "desktopcomputer"
    }
}

// MARK: - Trusted Hosts ViewModel

@MainActor
final class TrustedHostsViewModel: ObservableObject {
    @Published var trustedHosts: [TrustedHostInfo] = []
    
    init() {
        loadTrustedHosts()
    }
    
    func loadTrustedHosts() {
        let hosts = TPAuthenticationManager.default.trustedHosts as? [TPRemoteHost] ?? []
        trustedHosts = hosts.map { TrustedHostInfo(from: $0) }
    }
    
    func removeHosts(withIds ids: Set<String>) {
        for id in ids {
            if let hostInfo = trustedHosts.first(where: { $0.id == id }) {
                TPAuthenticationManager.default.host(hostInfo.remoteHost, setTrusted: false)
            }
        }
        loadTrustedHosts()
    }
}
