// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI
import AppKit

@available(macOS 13.0, *)
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @State private var selectedTab: SettingsTab = .devices
    @State private var showingTrustedHosts = false
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        case devices = "Devices"
        case layout = "Layout"
        case settings = "Settings"
        case about = "About"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .devices: return "desktopcomputer"
            case .layout: return "rectangle.3.group"
            case .settings: return "gearshape"
            case .about: return "info.circle"
            }
        }
    }
    
    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .removeSidebarToggleIfNeeded()
        } detail: {
            Group {
                switch selectedTab {
                case .devices:
                    DevicesView()
                case .layout:
                    ModernLayoutView()
                case .settings:
                    SettingsTabView(viewModel: viewModel, showingTrustedHosts: $showingTrustedHosts)
                case .about:
                    AboutTabView()
                }
            }
            .id(selectedTab)
            .frame(minWidth: 550)
        }
        .frame(minWidth: 750, minHeight: 500)
        .sheet(isPresented: $showingTrustedHosts) {
            TrustedHostsView()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Toggle Sidebar")
            }
            
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.resetConnections()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reset all connections")
            }
        }
    }
}

// MARK: - Settings Tab View

@available(macOS 13.0, *)
struct SettingsTabView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Binding var showingTrustedHosts: Bool
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // General Section
                SettingsSection(title: "General") {
                    SettingsRow(
                        title: "Launch at login",
                        description: "Automatically start Unimacs when you log in to your Mac"
                    ) {
                        Toggle("", isOn: $viewModel.addToLoginItems)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }

                // Sharing Section
                SettingsSection(title: "Sharing") {
                    SettingsRow(title: "Network") {
                        Menu {
                            ForEach(viewModel.availableIPAddresses, id: \.self) { ip in
                                Button {
                                    viewModel.selectedIPAddress = ip
                                } label: {
                                    HStack {
                                        Text(ip)
                                        if ip == viewModel.selectedIPAddress {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "network")
                                    .foregroundColor(.secondary)
                                Text(viewModel.selectedIPAddress.isEmpty ? "Select..." : viewModel.selectedIPAddress)
                                    .foregroundColor(.primary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                
                // Security Section
                SettingsSection(title: "Security") {
                    SettingsRow(title: "Trusted Hosts") {
                        Button {
                            showingTrustedHosts = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "person.2.badge.gearshape")
                                Text("Manage")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                }
                
                // Trust Requests Section
                SettingsSection(title: "Control Requests") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(TrustRequestBehavior.allCases) { behavior in
                            TrustBehaviorRow(
                                behavior: behavior,
                                isSelected: viewModel.trustRequestBehavior == behavior
                            ) {
                                viewModel.trustRequestBehavior = behavior
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // Switching Section
                SettingsSection(title: "Switching") {
                    SettingsRow(
                        title: "Direct event taps (full gestures)",
                        description: "Stream input events directly to the remote Mac for full gesture support. Turn off to use the compatibility mode. Takes effect on next reconnect."
                    ) {
                        Toggle("", isOn: $viewModel.useDirectEventTaps)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsRow(
                        title: "Always observe events (Emergency stop)",
                        description: "Start event listening on application startup and keep it running in the background. This ensures the emergency force-quit sequence (ctrl+option+shift+esc) is always active. When off, events are only listened to during active control."
                    ) {
                        Toggle("", isOn: $viewModel.alwaysObserveEvents)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsRow(
                        title: "Hide cursor via foreground shield",
                        description: "Bring Unimacs to the front behind a transparent shield to hide the local cursor with public APIs (required on macOS 26). Turn off to use the legacy background method. Takes effect on next control session."
                    ) {
                        Toggle("", isOn: $viewModel.useCursorShieldWindow)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsRow(
                        title: "Warp cursor to center on stop",
                        description: "Move the cursor to the center of the main screen after a control session ends."
                    ) {
                        Toggle("", isOn: $viewModel.warpCursorOnStopControl)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsRow(
                        title: "Require modifier key",
                        description: "Only switch when holding a modifier key"
                    ) {
                        Toggle("", isOn: $viewModel.requireKey)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    
                    if viewModel.requireKey {
                        Divider()
                        
                        SettingsRow(title: "Modifier key") {
                            Picker("", selection: $viewModel.switchKeyTag) {
                                ForEach(ModifierKeyTag.allCases) { key in
                                    Text(key.symbol).tag(key)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                        }
                    }
                    
                    Divider()

                    SettingsRow(
                        title: "Keep connected devices awake",
                        description: "Periodically notify connected devices to stay awake while you are active on this machine."
                    ) {
                        Toggle("", isOn: $viewModel.enableKeepAwake)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    if viewModel.enableKeepAwake {
                        Divider()
                            .padding(.vertical, 8)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Keep-awake interval")
                                    .font(.body)
                                Spacer()
                                Text("\(Int(viewModel.keepAwakeInterval))s")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .fontWeight(.medium)
                            }
                            
                            HStack(spacing: 12) {
                                Text("10s")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Slider(value: $viewModel.keepAwakeInterval, in: 10...300, step: 5)
                                    .frame(maxWidth: .infinity)
                                
                                Text("300s")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text("Interval in seconds to send keep-awake commands to connected devices.")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    Divider()

                    SettingsRow(
                        title: "Synchronize lock and sleep events",
                        description: "Propagate manual lock and sleep events to connected devices. Suppresses automatic idle sleep/lock propagation."
                    ) {
                        Toggle("", isOn: $viewModel.syncLockSleep)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                
                // Network Section
                SettingsSection(title: "Network") {
                    SettingsRow(
                        title: "Reset on network changes",
                        description: "Disconnect when network configuration changes"
                    ) {
                        Toggle("", isOn: $viewModel.disconnectOnNetworkChange)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsRow(
                        title: "Use Swift network stack (experimental)",
                        description: "Use Network.framework for the control connection; off falls back to the legacy socket. Takes effect on next reconnect."
                    ) {
                        Toggle("", isOn: $viewModel.useSwiftNetworkStack)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                
                // Notifications Section
                SettingsSection(title: "Notifications") {
                    SettingsRow(
                        title: "Show control bezel",
                        description: "Display overlay when controlling another Mac"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { !viewModel.hideControlBezel },
                            set: { viewModel.hideControlBezel = !$0 }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                                        
                    Divider()
                    
                    SettingsRow(
                        title: "Show hot border visuals",
                        description: "Display the edge glow and activation effect at switching borders. For debugging; takes effect on the next connection."
                    ) {
                        Toggle("", isOn: $viewModel.showHotBorderVisuals)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    
                    if viewModel.showHotBorderVisuals {
                        Divider()
                        
                        SettingsRow(
                            title: "Hot border style",
                            description: viewModel.hotBorderStyle.description
                        ) {
                            Picker("", selection: $viewModel.hotBorderStyle) {
                                ForEach(HotBorderVisualStyle.allCases) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                    }
                }
                
                // Transfer Section
                SettingsSection(title: "Transfer") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsRow(
                            title: "Skip clipboard sync after local paste",
                            description: "Do not transfer copied content to another Mac after it has already been pasted on the current Mac."
                        ) {
                            Toggle("", isOn: $viewModel.skipClipboardAfterLocalPaste)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }

                        Divider()

                        SettingsRow(
                            title: "Expire clipboard sync after timeout",
                            description: "Only transfer copied content if you move to another Mac within the timeout window."
                        ) {
                            Toggle("", isOn: $viewModel.enableClipboardTimeout)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }

                        if viewModel.enableClipboardTimeout {
                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Clipboard sync timeout")
                                        .font(.body)
                                    Spacer()
                                    Text("\(Int(viewModel.clipboardTimeoutInterval))s")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                        .fontWeight(.medium)
                                }

                                HStack(spacing: 12) {
                                    Text("30s")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    Slider(
                                        value: $viewModel.clipboardTimeoutInterval,
                                        in: Settings.clipboardTimeoutIntervalMin...Settings.clipboardTimeoutIntervalMax,
                                        step: 10
                                    )
                                    .frame(maxWidth: .infinity)

                                    Text("600s")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Text("If you stay on the current Mac longer than this after copying, the clipboard won't be sent when switching.")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }

                        Divider()

                        HStack {
                            Text("Show progress for transfers larger than")
                                .font(.body)
                            Spacer()
                            Text(TransferThresholdOption.label(for: viewModel.transferProgressThreshold))
                                .font(.body)
                                .foregroundColor(.secondary)
                                .frame(minWidth: 60, alignment: .trailing)
                        }
                        
                        HStack(spacing: 12) {
                            Text("Always")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Slider(
                                value: Binding(
                                    get: { TransferThresholdOption.sliderValue(for: viewModel.transferProgressThreshold) },
                                    set: { viewModel.transferProgressThreshold = TransferThresholdOption.thresholdValue(for: $0) }
                                ),
                                in: 0...1
                            )
                            .frame(maxWidth: .infinity)
                            
                            Text("Never")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Text("Smaller transfers complete quickly and won't show a dialog")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        
                        Divider()
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cache")
                                    .font(.body)
                                Text(viewModel.cacheSize)
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button {
                                viewModel.openCacheDirectory()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder")
                                    Text("Show in Finder")
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            
                            Button {
                                viewModel.clearCache()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "trash")
                                    Text("Clear")
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // Audio & Mic Sync Section
                SettingsSection(title: "Audio & Mic Sync") {
                    SettingsRow(
                        title: "Audio Compression",
                        description: "Compress audio samples to save local network bandwidth. Raw PCM has the lowest latency."
                    ) {
                        Toggle("", isOn: $viewModel.audioUseCompression)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsRow(
                        title: "Mute Local Speakers",
                        description: "Automatically mute local speakers when sharing system audio output."
                    ) {
                        Toggle("", isOn: $viewModel.muteLocalSpeakers)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsRow(
                        title: "Adaptive Audio Speed",
                        description: "Automatically adjust playback speed to catch up and prevent packet loss during network lag."
                    ) {
                        Toggle("", isOn: $viewModel.enableAdaptiveSpeed)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsRow(
                        title: "Virtual Mic Status",
                        description: "Microphone routing uses BlackHole 2ch by Existential Audio (GPLv3) to loop back audio on the remote Mac."
                    ) {
                        HStack(spacing: 6) {
                            switch viewModel.blackHoleStatus {
                            case .available:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("BlackHole 2ch Available")
                                    .fontWeight(.medium)
                            case .installedButNeedReboot:
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Installed (Reboot Required)")
                                    .fontWeight(.medium)
                            case .missing:
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text("BlackHole 2ch Missing")
                                    .fontWeight(.medium)
                            }
                        }
                    }

                    if viewModel.blackHoleStatus != .available {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(viewModel.blackHoleStatus == .installedButNeedReboot ? "Reboot Required" : "Virtual Audio Device Not Detected")
                                    .fontWeight(.medium)
                            }
                            
                            if viewModel.blackHoleStatus == .installedButNeedReboot {
                                Text("BlackHole has been successfully installed, but macOS requires a system restart before CoreAudio can load it. Please reboot your Mac.")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Please install [BlackHole 2ch](https://existential.audio/blackhole/) (by Existential Audio, GPLv3) to enable microphone routing. Install the signed official package below or run: brew install blackhole-2ch")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack(spacing: 12) {
                                if viewModel.blackHoleStatus == .missing {
                                    Button(action: {
                                        viewModel.installBlackHole()
                                    }) {
                                        if viewModel.isInstallingBlackHole {
                                            HStack(spacing: 6) {
                                                ProgressView()
                                                    .controlSize(.small)
                                                Text("Installing...")
                                            }
                                        } else {
                                            Text("Install BlackHole")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(viewModel.isInstallingBlackHole)
                                }
                                
                                Button(action: {
                                    viewModel.checkBlackHoleStatus()
                                }) {
                                    Text("Re-check Status")
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.isInstallingBlackHole)
                            }
                            .padding(.top, 4)
                        }
                        .padding(.vertical, 8)
                    }
                }
                
                // Debug Section
                SettingsSection(title: "Advanced") {
                    SettingsRow(
                        title: "Enable debug logging",
                        description: "Mirror detailed logs to the system console (always saved to file)"
                    ) {
                        Toggle("", isOn: $viewModel.enableLogging)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    
                    if viewModel.enableLogging {
                        Divider()
                        
                        SettingsRow(
                            title: "Minimum log level",
                            description: "Only show logs at or above this level"
                        ) {
                            Menu {
                                ForEach(LogLevel.allCases, id: \.self) { level in
                                    Button {
                                        viewModel.logLevel = level
                                    } label: {
                                        HStack {
                                            Text(level.displayName)
                                            if level == viewModel.logLevel {
                                                Spacer()
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Text(viewModel.logLevel.displayName)
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                                    )
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        
                        Divider()
                        
                        // Log Module Filters
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Log Modules")
                                .font(.body)
                            Text("Enable or disable logging for specific modules")
                                .font(.callout)
                                .foregroundColor(.secondary)
                            
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible())
                            ], spacing: 8) {
                                ForEach(LogModule.allCases, id: \.rawValue) { module in
                                    LogModuleToggle(
                                        module: module,
                                        isEnabled: viewModel.binding(for: module)
                                    )
                                }
                            }
                            .padding(.top, 4)
                        }
                        .padding(.vertical, 4)
                    }
                    
                    Divider()
                    
                    LogExportRow()
                    
                    Divider()
                    
                    OpenLogFolderRow()
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.startPeriodicRefresh()
        }
        .onDisappear {
            viewModel.stopPeriodicRefresh()
        }
    }
}

// MARK: - Log Export Row

@available(macOS 13.0, *)
struct LogExportRow: View {
    @State private var isExporting = false
    
    var body: some View {
        SettingsRow(
            title: "Export logs",
            description: "Package saved log files into a zip for sharing with developers"
        ) {
            HStack(spacing: 8) {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                    Text("Exporting...")
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    Button {
                        isExporting = true
                        LogExporter.shared.saveLogs {
                            isExporting = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down")
                            Text("Save")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    
                    Button {
                        isExporting = true
                        LogExporter.shared.shareLogs {
                            isExporting = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
        }
    }
}

// MARK: - Open Log Folder Row

@available(macOS 13.0, *)
struct OpenLogFolderRow: View {
    var body: some View {
        SettingsRow(
            title: "Log files",
            description: "Detailed connection logs are saved here (kept for 7 days)"
        ) {
            Button {
                FileLogger.shared.revealLogDirectoryInFinder()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text("Open Folder")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }
}

// MARK: - Log Module Toggle

@available(macOS 13.0, *)
struct LogModuleToggle: View {
    let module: LogModule
    @Binding var isEnabled: Bool
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(module.displayName)
                    .font(.callout)
                    .fontWeight(.medium)
            }
            Spacer()
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

// MARK: - Settings Section

@available(macOS 13.0, *)
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            
            VStack(spacing: 0) {
                content()
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
        }
    }
}

// MARK: - Settings Row

@available(macOS 13.0, *)
struct SettingsRow<Control: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder let control: () -> Control
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                
                if let description = description {
                    Text(description)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            control()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Trust Behavior Row

@available(macOS 13.0, *)
struct TrustBehaviorRow: View {
    let behavior: TrustRequestBehavior
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(behavior.title)
                        .font(.body)
                        .foregroundColor(.primary)
                    
                    Text(behavior.description)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Trusted Hosts View

@available(macOS 13.0, *)
struct TrustedHostsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = TrustedHostsViewModel()
    @State private var selectedHosts = Set<String>()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trusted Hosts")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("These hosts are allowed to control this Mac without asking for permission.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(20)
            
            Divider()
            
            // Host list
            if viewModel.trustedHosts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text("No Trusted Hosts")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text("When you trust a host, it will appear here.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedHosts) {
                    ForEach(viewModel.trustedHosts) { host in
                        TrustedHostRow(host: host)
                            .tag(host.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            
            Divider()
            
            // Footer
            HStack {
                Button(role: .destructive) {
                    viewModel.removeHosts(withIds: selectedHosts)
                    selectedHosts.removeAll()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(selectedHosts.isEmpty)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 500, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Trusted Host Row

@available(macOS 13.0, *)
struct TrustedHostRow: View {
    let host: TrustedHostInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: host.systemIconName)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.body)
                    .fontWeight(.medium)

                Text(host.address)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - About View

@available(macOS 13.0, *)
struct AboutTabView: View {
    @State private var versionIndex = 0
    
    private var appIcon: NSImage? {
        NSApp.applicationIconImage
    }
    
    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "Unimacs"
    }
    
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1.0"
    }
    
    private var buildNumber: String {
        Bundle.main.infoDictionary?["TPRevision"] as? String ?? ""
    }
    
    private var copyright: String {
        Bundle.main.localizedInfoDictionary?["NSHumanReadableCopyright"] as? String
            ?? Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? "Copyright © 2003–2012 abyssoft (Julien Robert), 2020–2023 John Britton, 2025–2026 Benny Huo."
    }
    
    private var versionStrings: [String] {
        var versions = [
            "Version \(version)",
            "Build \(buildNumber)"
        ]
        if let translationInfo = Bundle.main.localizedInfoDictionary?["TPTranslationInfoString"] as? String {
            versions.append(translationInfo)
        }
        return versions
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("About")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Information about this application")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            // Content
            VStack(spacing: 20) {
                Spacer()
                
                // App icon
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 128, height: 128)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                }
                
                // App name
                Text(appName)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                
                // Version (clickable to cycle)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        versionIndex = (versionIndex + 1) % versionStrings.count
                    }
                } label: {
                    Text(versionStrings[versionIndex])
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .contentTransition(.numericText())
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Links
                HStack(spacing: 24) {
                    Link(destination: URL(string: "https://github.com/bennyhuo/unimacs")!) {
                        Label("GitHub", systemImage: "link")
                            .font(.callout)
                    }
                    
                    Link(destination: URL(string: "https://github.com/bennyhuo/unimacs/issues")!) {
                        Label("Report Issue", systemImage: "exclamationmark.bubble")
                            .font(.callout)
                    }
                    
                    Link(destination: URL(string: "https://github.com/bennyhuo/unimacs/blob/main/LICENSE")!) {
                        Label("GPL-2.0 License", systemImage: "doc.text")
                            .font(.callout)
                    }
                }
                
                // Credits & Copyright
                VStack(spacing: 6) {
                    Text("Forked from [johndbritton/teleport](https://github.com/johndbritton/teleport) and originally created as [Teleport](https://github.com/abyssoft/teleport) by Julien Robert (Abyssoft). Virtual microphone routing powered by [BlackHole](https://existential.audio/blackhole/) (Existential Audio, GPLv3).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    
                    Text(copyright)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - About View (Sheet)

@available(macOS 13.0, *)
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var versionIndex = 0
    
    private var appIcon: NSImage? {
        NSApp.applicationIconImage
    }
    
    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "Unimacs"
    }
    
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1.0"
    }
    
    private var buildNumber: String {
        Bundle.main.infoDictionary?["TPRevision"] as? String ?? ""
    }
    
    private var copyright: String {
        Bundle.main.localizedInfoDictionary?["NSHumanReadableCopyright"] as? String
            ?? Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? "Copyright © 2003–2012 abyssoft (Julien Robert), 2020–2023 John Britton, 2025–2026 Benny Huo."
    }
    
    private var versionStrings: [String] {
        var versions = [
            "Version \(version)",
            "Build \(buildNumber)"
        ]
        if let translationInfo = Bundle.main.localizedInfoDictionary?["TPTranslationInfoString"] as? String {
            versions.append(translationInfo)
        }
        return versions
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(12)
            }
            
            Spacer()
            
            // App icon
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            }
            
            // App name
            Text(appName)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .padding(.top, 12)
            
            // Version (clickable to cycle)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    versionIndex = (versionIndex + 1) % versionStrings.count
                }
            } label: {
                Text(versionStrings[versionIndex])
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            
            Spacer()
            
            // Links
            HStack(spacing: 16) {
                Link(destination: URL(string: "https://github.com/bennyhuo/unimacs")!) {
                    Label("GitHub", systemImage: "link")
                        .font(.callout)
                }
                
                Link(destination: URL(string: "https://github.com/bennyhuo/unimacs/issues")!) {
                    Label("Report Issue", systemImage: "exclamationmark.bubble")
                        .font(.callout)
                }
                
                Link(destination: URL(string: "https://github.com/bennyhuo/unimacs/blob/main/LICENSE")!) {
                    Label("GPL-2.0", systemImage: "doc.text")
                        .font(.callout)
                }
            }
            .padding(.bottom, 12)
            
            // Credits & Copyright
            VStack(spacing: 6) {
                Text("Forked from [johndbritton/teleport](https://github.com/johndbritton/teleport) and originally created as [Teleport](https://github.com/abyssoft/teleport) by Julien Robert (Abyssoft). Virtual microphone routing powered by [BlackHole](https://existential.audio/blackhole/) (Existential Audio, GPLv3).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Text(copyright)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 360, height: 430)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
    }
}

// MARK: - Transfer Threshold Options

enum TransferThresholdOption {
    // Slider stops: Always(0), 100KB, 200KB, 300KB, 500KB, 1MB, Never
    private static let stops: [(value: Int, position: Double)] = [
        (0, 0.0),           // Always
        (100, 0.15),        // 100 KB
        (200, 0.30),        // 200 KB
        (300, 0.45),        // 300 KB
        (500, 0.60),        // 500 KB
        (1024, 0.80),       // 1 MB
        (Int.max, 1.0)      // Never
    ]
    
    static func sliderValue(for threshold: Int) -> Double {
        // Find exact match or interpolate
        if let stop = stops.first(where: { $0.value == threshold }) {
            return stop.position
        }
        // Find surrounding stops and interpolate
        for i in 0..<(stops.count - 1) {
            let lower = stops[i]
            let upper = stops[i + 1]
            if threshold > lower.value && threshold < upper.value {
                let ratio = Double(threshold - lower.value) / Double(upper.value - lower.value)
                return lower.position + ratio * (upper.position - lower.position)
            }
        }
        return 0.5
    }
    
    static func thresholdValue(for sliderValue: Double) -> Int {
        // Snap to nearest stop
        var closestStop = stops[0]
        var minDistance = Double.infinity
        
        for stop in stops {
            let distance = abs(stop.position - sliderValue)
            if distance < minDistance {
                minDistance = distance
                closestStop = stop
            }
        }
        return closestStop.value
    }
    
    static func label(for threshold: Int) -> String {
        switch threshold {
        case 0: return "Always"
        case Int.max: return "Never"
        case 1024...: return "\(threshold / 1024) MB"
        default: return "\(threshold) KB"
        }
    }
}

// MARK: - Visual Effect View

@available(macOS 13.0, *)
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Preview

@available(macOS 13.0, *)
#Preview {
    SettingsView()
        .frame(width: 800, height: 600)
}

extension View {
    @ViewBuilder
    func removeSidebarToggleIfNeeded() -> some View {
        if #available(macOS 14.0, *) {
            self.toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

