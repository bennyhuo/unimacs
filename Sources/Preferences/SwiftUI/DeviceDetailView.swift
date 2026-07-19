// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI
import SecurityInterface

// MARK: - Device Detail View

@available(macOS 13.0, *)
struct DeviceDetailView: View {
    let device: DeviceInfo
    @ObservedObject var viewModel: DevicesViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        let displayDevice = viewModel.device(withId: device.id) ?? device
        
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 16) {
                // Device icon
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: displayDevice.systemIconName)
                        .font(.system(size: 64))
                        .foregroundColor(.accentColor)
                    
                    // Status indicator
                    Circle()
                        .fill(displayDevice.statusColor)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 3)
                        )
                        .offset(x: 4, y: 4)
                }
                
                // Device name
                Text(displayDevice.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                // Status
                Text(displayDevice.statusText)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)
            
            Divider()
            
            // Details
            ScrollView {
                VStack(spacing: 16) {
                    // Connection Info
                    DetailSection(title: "Connection") {
                        if let error = displayDevice.lastError, displayDevice.linkPhase == .disconnected || displayDevice.linkPhase == .unavailable {
                            DetailRow(label: "Status", value: "Error")
                            HStack(alignment: .top) {
                                Text("Last Error")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(error)
                                    .foregroundColor(.red)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: 220, alignment: .trailing)
                            }
                        } else {
                            DetailRow(label: "Status", value: displayDevice.connectionStatusText)
                        }
                        if !displayDevice.address.isEmpty {
                            DetailRow(label: "IP Address", value: displayDevice.address, showCopyButton: true)
                        }
                        if displayDevice.port > 0 {
                            DetailRow(label: "Port", value: "\(displayDevice.port)", showCopyButton: true)
                        }
                    }
                    
                    // Device Info
                    DetailSection(title: "Device") {
                        DetailRow(label: "Name", value: displayDevice.name)
                        DetailRow(label: "Identifier", value: displayDevice.id, showCopyButton: true)
                        if displayDevice.screenCount > 0 {
                            DetailRow(label: "Screens", value: "\(displayDevice.screenCount)")
                        }
                        if displayDevice.osVersion > 0 {
                            DetailRow(label: "OS Version", value: formatOSVersion(displayDevice.osVersion))
                        }
                        if !displayDevice.macAddresses.isEmpty {
                            MacAddressRow(addresses: displayDevice.macAddresses)
                        }
                    }
                    
                    // Security
                    DetailSection(title: "Security") {
                        DetailRow(label: "Paired", value: displayDevice.isPaired ? "Yes" : "No")
                    }
                }
                .padding(20)
            }
            
            Divider()
            
            // Actions
            HStack(spacing: 12) {
                if displayDevice.isPaired {
                    Button(role: .destructive) {
                        viewModel.unpair(device: displayDevice)
                        dismiss()
                    } label: {
                        Label("Unpair", systemImage: "minus.circle")
                    }
                    .buttonStyle(.bordered)
                }
                
                Spacer()
                
                if displayDevice.showsDisconnectAction {
                    Button {
                        viewModel.disconnect(from: displayDevice)
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                } else if displayDevice.showsRetryAction {
                    Button {
                        viewModel.connect(to: displayDevice)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                } else if displayDevice.showsConnectAction && displayDevice.isPaired {
                    Button {
                        if let error = displayDevice.lastError, error.contains("Control rejected") {
                            viewModel.pair(with: displayDevice)
                            dismiss()
                        } else {
                            viewModel.connect(to: displayDevice)
                        }
                    } label: {
                        if let error = displayDevice.lastError, error.contains("Control rejected") {
                            Label("Pair", systemImage: "link.badge.plus")
                        } else {
                            Label("Connect", systemImage: "link")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else if !displayDevice.isPaired {
                    Button {
                        viewModel.pair(with: displayDevice)
                        dismiss()
                    } label: {
                        Label("Pair", systemImage: "link.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 400, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Helpers
    
    private func formatOSVersion(_ version: Int) -> String {
        let major = version / 100
        let minor = version % 100
        return "macOS \(major).\(minor)"
    }
}

// MARK: - Detail Section

@available(macOS 13.0, *)
struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            
            VStack(spacing: 12) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }
}

// MARK: - Detail Row

@available(macOS 13.0, *)
struct DetailRow: View {
    let label: String
    let value: String
    var showCopyButton: Bool = false
    
    @State private var justCopied = false
    
    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .foregroundColor(.primary)
                .textSelection(.enabled)
            
            if showCopyButton {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    withAnimation {
                        justCopied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation {
                            justCopied = false
                        }
                    }
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(justCopied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy to Clipboard")
            }
        }
    }
}

// MARK: - MAC Address Row

@available(macOS 13.0, *)
struct MacAddressRow: View {
    let addresses: [String]
    @State private var justCopied = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("MAC Address")
                .foregroundColor(.secondary)
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(addresses, id: \.self) { address in
                    HStack(spacing: 4) {
                        Text(address)
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                        
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address, forType: .string)
                            withAnimation {
                                justCopied = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation {
                                    justCopied = false
                                }
                            }
                        } label: {
                            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(justCopied ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy MAC Address")
                    }
                }
            }
        }
    }
}

// MARK: - Preview

@available(macOS 13.0, *)
#Preview {
    DeviceDetailView(
        device: DeviceInfo(
            id: "test-id",
            name: "Test Mac",
            address: "192.168.1.100",
            port: 23456,
            screenCount: 2,
            hasCertificate: true,
            osVersion: 1400,
            isPaired: true,
            isConnected: false,
            isControlling: false,
            isBeingControlled: false,
            linkPhase: .unavailable,
            reconnectSecondsRemaining: nil,
            remoteHost: nil
        ),
        viewModel: DevicesViewModel()
    )
}

// Extension for preview
extension DeviceInfo {
    init(
        id: String,
        name: String,
        address: String,
        port: Int,
        screenCount: Int,
        hasCertificate: Bool,
        osVersion: Int,
        isPaired: Bool,
        isConnected: Bool,
        isControlling: Bool,
        isBeingControlled: Bool,
        macAddresses: [String] = [],
        linkPhase: DeviceLinkPhase = .unavailable,
        reconnectSecondsRemaining: Int? = nil,
        isPortable: Bool = false,
        lastError: String? = nil,
        shareOutput: Bool = false,
        shareInput: Bool = false,
        hasSpeakerHardware: Bool = true,
        hasMicHardware: Bool = true,
        remoteHost: RemoteHost?
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.screenCount = screenCount
        self.hasCertificate = hasCertificate
        self.osVersion = osVersion
        self.isPaired = isPaired
        self.isConnected = isConnected
        self.isControlling = isControlling
        self.isBeingControlled = isBeingControlled
        self.macAddresses = macAddresses
        self.linkPhase = linkPhase
        self.reconnectSecondsRemaining = reconnectSecondsRemaining
        self.isPortable = isPortable
        self.lastError = lastError
        self.shareOutput = shareOutput
        self.shareInput = shareInput
        self.hasSpeakerHardware = hasSpeakerHardware
        self.hasMicHardware = hasMicHardware
        self.remoteHost = remoteHost
    }
}
