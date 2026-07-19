// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

// MARK: - Devices View

@available(macOS 13.0, *)
struct DevicesView: View {
    @StateObject private var viewModel = DevicesViewModel()
    @State private var selectedDeviceId: String?
    @State private var detailDevice: DeviceInfo?
    @State private var showingLocalDetail = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Devices")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Manage paired devices and discover nearby Macs running Unimacs.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // This Device Section
                DevicesSection(title: "This Device", icon: viewModel.localSystemIconName) {
                    ThisDeviceRow(viewModel: viewModel, onShowDetail: {
                        showingLocalDetail = true
                    })
                }
                
                // Paired Devices Section
                DevicesSection(title: "My Devices", icon: "desktopcomputer") {
                    if viewModel.pairedDevices.isEmpty {
                        EmptyDevicesPlaceholder(
                            icon: "desktopcomputer",
                            title: "No Paired Devices",
                            message: "Pair with nearby devices to control them."
                        )
                    } else {
                        ForEach(viewModel.pairedDevices) { device in
                            PairedDeviceRow(
                                device: device,
                                viewModel: viewModel,
                                onConnect: { viewModel.connect(to: device) },
                                onDisconnect: { viewModel.disconnect(from: device) },
                                onUnpair: { viewModel.unpair(device: device) },
                                onShowDetail: {
                                    detailDevice = device
                                },
                                onPair: { viewModel.pair(with: device) },
                                onClearError: { viewModel.clearError(for: device) }
                            )
                            
                            if device.id != viewModel.pairedDevices.last?.id {
                                Divider()
                                    .padding(.leading, 44)
                            }
                        }
                    }
                }
                
                // Nearby Devices Section
                DevicesSection(
                    title: "Nearby Devices",
                    icon: "antenna.radiowaves.left.and.right"
                ) {
                    if viewModel.nearbyDevices.isEmpty {
                        EmptyDevicesPlaceholder(
                            icon: "magnifyingglass",
                            title: "No Nearby Devices",
                            message: "Looking for other Macs running Unimacs on the same network."
                        )
                    } else {
                        ForEach(viewModel.nearbyDevices) { device in
                            NearbyDeviceRow(
                                device: device,
                                onPair: { viewModel.pair(with: device) },
                                onShowDetail: {
                                    detailDevice = device
                                }
                            )
                            
                            if device.id != viewModel.nearbyDevices.last?.id {
                                Divider()
                                    .padding(.leading, 44)
                            }
                        }
                    }
                }
                
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $detailDevice) { device in
            DeviceDetailView(device: device, viewModel: viewModel)
        }
        .sheet(isPresented: $showingLocalDetail) {
            LocalDeviceDetailView(viewModel: viewModel)
        }
        .onAppear {
            viewModel.startObserving()
        }
        .onDisappear {
            viewModel.stopObserving()
        }
    }
}

// MARK: - Devices Section

@available(macOS 13.0, *)
struct DevicesSection<Content: View, Trailing: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content
    
    init(
        title: String,
        icon: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.trailing = trailing
        self.content = content
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                trailing()
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
            
            // Section content
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

// MARK: - Paired Device Row

@available(macOS 13.0, *)
struct PairedDeviceRow: View {
    let device: DeviceInfo
    let viewModel: DevicesViewModel
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onUnpair: () -> Void
    let onShowDetail: () -> Void
    let onPair: () -> Void
    let onClearError: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Device icon with status indicator
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: device.systemIconName)
                    .font(.system(size: 24))
                    .foregroundColor(device.linkPhase == .connected ? .accentColor : .secondary)
                    .frame(width: 32, height: 32)
                
                // Status indicator
                if device.linkPhase == .connecting || device.linkPhase == .reconnecting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.4)
                        .frame(width: 12, height: 12)
                        .background(
                            Circle()
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .frame(width: 12, height: 12)
                        )
                        .offset(x: 2, y: 2)
                } else {
                    Circle()
                        .fill(device.statusColor)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2)
                        )
                        .offset(x: 2, y: 2)
                }
            }
            
            // Device info
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body)
                    .fontWeight(.medium)
                
                if let error = device.lastError, device.linkPhase == .disconnected || device.linkPhase == .unavailable {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                    }
                    .foregroundColor(.red)
                } else {
                    Text(device.statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 12) {
                if device.showsDisconnectAction {
                    Button {
                        onDisconnect()
                    } label: {
                        Text("Disconnect")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                } else if device.showsRetryAction {
                    HStack(spacing: 8) {
                        Button {
                            onConnect()
                        } label: {
                            Text("Retry")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        
                        Button {
                            onDisconnect()
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else if device.showsConnectAction {
                    Button {
                        if let error = device.lastError, error.contains("Control rejected") {
                            onPair()
                        } else {
                            onConnect()
                        }
                    } label: {
                        Text((device.lastError?.contains("Control rejected") == true) ? "Pair" : "Connect")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                
                if device.isConnected {
                    // Share Output Button
                    Button {
                        let newValue = !device.shareOutput
                        if let host = device.remoteHost {
                            host.shareOutput = newValue
                            viewModel.updateAudioSharingState(for: host)
                        }
                    } label: {
                        Image(systemName: device.shareOutput ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.system(size: 16))
                            .foregroundColor(!device.hasSpeakerHardware ? .secondary.opacity(0.5) : (device.shareOutput ? .accentColor : .secondary))
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill((device.shareOutput && device.hasSpeakerHardware) ? Color.accentColor.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!device.hasSpeakerHardware)
                    .opacity(device.hasSpeakerHardware ? 1.0 : 0.4)
                    .help(!device.hasSpeakerHardware ? "No audio output hardware available on target host" : (device.shareOutput ? "Stop Sharing Output" : "Share Output"))
                    
                    // Share Input Button
                    Button {
                        let newValue = !device.shareInput
                        if let host = device.remoteHost {
                            host.shareInput = newValue
                            viewModel.updateAudioSharingState(for: host)
                        }
                    } label: {
                        Image(systemName: device.shareInput ? "mic.fill" : "mic")
                            .font(.system(size: 16))
                            .foregroundColor(!device.hasMicHardware ? .secondary.opacity(0.5) : (device.shareInput ? .accentColor : .secondary))
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill((device.shareInput && device.hasMicHardware) ? Color.accentColor.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!device.hasMicHardware)
                    .opacity(device.hasMicHardware ? 1.0 : 0.4)
                    .help(!device.hasMicHardware ? "No microphone hardware available on target host" : (device.shareInput ? "Stop Sharing Input" : "Share Input"))
                }
                
                // Info button
                Button {
                    onShowDetail()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .contextMenu {
            if device.showsDisconnectAction {
                Button("Disconnect") { onDisconnect() }
            } else if device.showsRetryAction {
                Button("Retry") { onConnect() }
            } else if device.showsConnectAction {
                if let error = device.lastError, error.contains("Control rejected") {
                    Button("Pair") { onPair() }
                } else {
                    Button("Connect") { onConnect() }
                }
            }
            if device.lastError != nil {
                Button("Clear Error") {
                    onClearError()
                }
            }
            Divider()
            Button("Show Details") { onShowDetail() }
            Divider()
            Button("Unpair", role: .destructive) { onUnpair() }
        }
    }
}

// MARK: - Nearby Device Row

@available(macOS 13.0, *)
struct NearbyDeviceRow: View {
    let device: DeviceInfo
    let onPair: () -> Void
    let onShowDetail: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Device icon
            Image(systemName: device.systemIconName)
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
                .frame(width: 32, height: 32)
            
            // Device info
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body)
                    .fontWeight(.medium)
                
                Text(device.address)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 12) {
                Button {
                    onPair()
                } label: {
                    Text("Pair")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                
                // Info button
                Button {
                    onShowDetail()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Empty Placeholder

@available(macOS 13.0, *)
struct EmptyDevicesPlaceholder: View {
    let icon: String
    let title: String
    let message: String
    
    @State private var pulse = false
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.secondary)
                .opacity(pulse ? 0.4 : 1.0)
                .scaleEffect(pulse ? 0.95 : 1.0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - This Device Row

@available(macOS 13.0, *)
struct ThisDeviceRow: View {
    @ObservedObject var viewModel: DevicesViewModel
    let onShowDetail: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            // Local Device main details: Name, OS version, Screen Count
            HStack(spacing: 16) {
                // Device large icon
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: viewModel.localSystemIconName)
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.1))
                        )
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.localName)
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    HStack(spacing: 6) {
                        Text(viewModel.localOSVersion)
                        Text("•")
                        Text("\(viewModel.localScreenCount) Screen" + (viewModel.localScreenCount > 1 ? "s" : ""))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Network section: IP and Port
                VStack(alignment: .trailing, spacing: 2) {
                    Text(viewModel.localIPAddress)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Text("Port: \(viewModel.localPort)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Info button
                Button {
                    onShowDetail()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            // Status row if there is status info
            if !statusText.isEmpty {
                Divider()
                
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Connection actions
                    if !viewModel.isAccessibilityTrusted {
                        Button("Authorize...") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    } else if viewModel.isClientControlling {
                        Button("Disconnect") {
                            viewModel.stopClientControl()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    } else if viewModel.isClientConnecting {
                        Button("Cancel") {
                            viewModel.stopClientControl()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    } else if viewModel.isServerControlled {
                        Button("Disconnect") {
                            viewModel.stopServerControl()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
    }
    
    // Status text and colors
    private var statusText: String {
        if !viewModel.isAccessibilityTrusted {
            return "Accessibility Permission Required"
        }
        if viewModel.isClientControlling {
            if let hostName = viewModel.clientControlledHostName {
                return "Controlling \"\(hostName)\""
            }
            return "Controlling"
        } else if viewModel.isClientConnecting {
            if let hostName = viewModel.clientConnectingHostName {
                return "Connecting to \"\(hostName)\"..."
            }
            return "Connecting..."
        } else if viewModel.isServerControlled {
            if let hostName = viewModel.serverControlledHostName {
                return "Controlled by \"\(hostName)\""
            }
            return "Controlled"
        } else {
            return "Ready"
        }
    }
    
    private var statusColor: Color {
        if !viewModel.isAccessibilityTrusted {
            return .orange
        }
        if viewModel.isClientControlling {
            return .green
        } else if viewModel.isClientConnecting {
            return .orange
        } else if viewModel.isServerControlled {
            return .orange
        } else if viewModel.isServerSharing {
            return .green
        }
        return .gray
    }
}

// MARK: - Local Device Detail View

@available(macOS 13.0, *)
struct LocalDeviceDetailView: View {
    @ObservedObject var viewModel: DevicesViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 16) {
                Image(systemName: viewModel.localSystemIconName)
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)
                
                Text(viewModel.localName)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("This Device")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)
            
            Divider()
            
            // Details
            ScrollView {
                VStack(spacing: 16) {
                    DetailSection(title: "System") {
                        DetailRow(label: "Name", value: viewModel.localName)
                        DetailRow(label: "OS Version", value: viewModel.localOSVersion)
                        DetailRow(label: "Screens", value: "\(viewModel.localScreenCount)")
                    }
                    
                    DetailSection(title: "Network") {
                        DetailRow(label: "Listening Port", value: "\(viewModel.localPort)")
                        
                        // List all local IP addresses
                        HStack(alignment: .top) {
                            Text("IP Addresses")
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 4) {
                                ForEach(viewModel.localIPAddresses, id: \.self) { ip in
                                    Text(ip)
                                        .foregroundColor(.primary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    
                    // Show MAC address if available
                    let macAddresses = LocalHost.shared.macAddresses.map { $0.description }
                    if !macAddresses.isEmpty {
                        DetailSection(title: "Hardware") {
                            MacAddressRow(addresses: macAddresses)
                        }
                    }
                }
                .padding(20)
            }
            
            Divider()
            
            // Action
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 400, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Preview

@available(macOS 13.0, *)
#Preview {
    DevicesView()
        .frame(width: 600, height: 500)
}
