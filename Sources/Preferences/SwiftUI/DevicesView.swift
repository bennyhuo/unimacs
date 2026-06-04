// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  Device management interface similar to macOS Bluetooth settings.

import SwiftUI

// MARK: - Devices View

@available(macOS 13.0, *)
struct DevicesView: View {
    @StateObject private var viewModel = DevicesViewModel()
    @State private var selectedDeviceId: String?
    @State private var detailDevice: DeviceInfo?
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Devices")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Manage paired devices and discover nearby Macs running teleport.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
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
                                onConnect: { viewModel.connect(to: device) },
                                onDisconnect: { viewModel.disconnect(from: device) },
                                onUnpair: { viewModel.unpair(device: device) },
                                onShowDetail: {
                                    detailDevice = device
                                },
                                onWakeUp: { viewModel.wakeUp(device: device) }
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
                            title: "Scanning...",
                            message: "Looking for nearby Macs with teleport."
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
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onUnpair: () -> Void
    let onShowDetail: () -> Void
    let onWakeUp: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Device icon with status indicator
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 24))
                    .foregroundColor(device.isOnline ? .accentColor : .secondary)
                    .frame(width: 32, height: 32)
                
                // Status indicator
                Circle()
                    .fill(device.statusColor)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2)
                    )
                    .offset(x: 2, y: 2)
            }
            
            // Device info
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body)
                    .fontWeight(.medium)
                
                Text(device.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 12) {
                if device.isConnected {
                    Button {
                        onDisconnect()
                    } label: {
                        Text("Disconnect")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                } else if device.isOnline {
                    Button {
                        onConnect()
                    } label: {
                        Text("Connect")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                } else if device.isWakeable {
                    Button {
                        onWakeUp()
                    } label: {
                        Text("Wake")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.orange)
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
            if device.isConnected {
                Button("Disconnect") { onDisconnect() }
            } else if device.isOnline {
                Button("Connect") { onConnect() }
            } else if device.isWakeable {
                Button("Wake") { onWakeUp() }
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
            Image(systemName: "desktopcomputer")
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
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            
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

// MARK: - Preview

@available(macOS 13.0, *)
#Preview {
    DevicesView()
        .frame(width: 600, height: 500)
}
