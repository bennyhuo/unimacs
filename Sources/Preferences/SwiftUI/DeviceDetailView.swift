// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  Device detail view showing all available information about a device.

import SwiftUI
import SecurityInterface

// MARK: - Device Detail View

@available(macOS 13.0, *)
struct DeviceDetailView: View {
    let device: DeviceInfo
    @ObservedObject var viewModel: DevicesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var refreshedDevice: DeviceInfo?
    
    private var displayDevice: DeviceInfo {
        refreshedDevice ?? device
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 16) {
                // Device icon
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "desktopcomputer")
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
                        DetailRow(label: "Status", value: displayDevice.connectionStatusText)
                        if !displayDevice.address.isEmpty {
                            DetailRow(label: "IP Address", value: displayDevice.address)
                        }
                        if displayDevice.port > 0 {
                            DetailRow(label: "Port", value: "\(displayDevice.port)")
                        }
                    }
                    
                    // Device Info
                    DetailSection(title: "Device") {
                        DetailRow(label: "Name", value: displayDevice.name)
                        DetailRow(label: "Identifier", value: displayDevice.id)
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
                        
                        HStack {
                            Text("Certificate")
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            if displayDevice.hasCertificate {
                                Button {
                                    showCertificate()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundColor(.green)
                                        Text("View")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
                                Text("None")
                                    .foregroundColor(.secondary)
                            }
                        }
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
                
                if displayDevice.isConnected {
                    Button {
                        viewModel.disconnect(from: displayDevice)
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                } else if displayDevice.isOnline && displayDevice.isPaired {
                    Button {
                        viewModel.connect(to: displayDevice)
                    } label: {
                        Label("Connect", systemImage: "link")
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
        .onAppear {
            // Try to refresh device info from host manager
            // First try to get from the device's remoteHost reference
            if let host = device.remoteHost {
                refreshedDevice = DeviceInfo(from: host)
            } else if let host = TPHostsManager.shared.host(withIdentifier: device.id) {
                refreshedDevice = DeviceInfo(from: host)
            }
            // If refresh fails, we still have the original device data
        }
    }
    
    // MARK: - Helpers
    
    private func formatOSVersion(_ version: Int) -> String {
        let major = version / 100
        let minor = version % 100
        return "macOS \(major).\(minor)"
    }
    
    private func showCertificate() {
        guard let host = device.remoteHost ?? TPHostsManager.shared.host(withIdentifier: device.id),
              let certData = host.certificateData,
              let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            return
        }
        
        let panel = SFCertificatePanel.shared()
        panel?.runModal(forCertificates: [cert], showGroup: false)
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
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - MAC Address Row

@available(macOS 13.0, *)
struct MacAddressRow: View {
    let addresses: [String]
    
    var body: some View {
        HStack(alignment: .top) {
            Text("MAC Address")
                .foregroundColor(.secondary)
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(addresses, id: \.self) { address in
                    Text(address)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
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
            isOnline: true,
            isConnected: false,
            isControlling: false,
            isBeingControlled: false,
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
        isOnline: Bool,
        isConnected: Bool,
        isControlling: Bool,
        isBeingControlled: Bool,
        macAddresses: [String] = [],
        isWakeable: Bool = false,
        remoteHost: TPRemoteHost?
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.screenCount = screenCount
        self.hasCertificate = hasCertificate
        self.osVersion = osVersion
        self.isPaired = isPaired
        self.isOnline = isOnline
        self.isConnected = isConnected
        self.isControlling = isControlling
        self.isBeingControlled = isBeingControlled
        self.macAddresses = macAddresses
        self.isWakeable = isWakeable
        self.remoteHost = remoteHost
    }
}
