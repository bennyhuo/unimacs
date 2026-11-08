// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI
import AppKit
import Combine

// MARK: - Activity Log Drawer View

@available(macOS 13.0, *)
struct ActivityLogDrawerView: View {
    static let collapsedHeaderHeight: CGFloat = 36
    static let collapsedHeight: CGFloat = collapsedHeaderHeight + 1

    var availableDetailHeight: CGFloat? = nil
    @ObservedObject var logManager: ActivityLogManager = .shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var drawerHeight: CGFloat = 260
    @State private var dragStartHeight: CGFloat? = nil
    @State private var justCopied: Bool = false
    @State private var activeDiagnoses: [ActiveHostDiagnostic] = []
    @State private var refreshTrigger = UUID()

    private let minDrawerHeight: CGFloat = 180
    private let maxDrawerHeight: CGFloat = 460

    private var dynamicMaxDrawerHeight: CGFloat {
        guard let availableDetailHeight, availableDetailHeight > 0 else {
            return maxDrawerHeight
        }
        let maxFitting = availableDetailHeight - Self.collapsedHeight - 120
        return min(maxDrawerHeight, max(minDrawerHeight, maxFitting))
    }

    private var effectiveDrawerHeight: CGFloat {
        min(max(drawerHeight, minDrawerHeight), dynamicMaxDrawerHeight)
    }

    struct ActiveHostDiagnostic: Identifiable {
        let id: String
        let hostName: String
        let linkPhase: DeviceLinkPhase
        let attemptCount: Int
        let maxAttempts: Int
        let secondsRemaining: Int?
        let diagnosis: ConnectionFailureDiagnosis
    }

    var body: some View {
        AnimatableDrawerContainer(
            revealProgress: logManager.isDrawerExpanded ? 1.0 : 0.0,
            collapsedHeaderHeight: Self.collapsedHeaderHeight,
            expandedBodyHeight: effectiveDrawerHeight,
            topBorderColor: drawerTopBorderColor,
            headerBackgroundColor: drawerHeaderBackgroundColor,
            bodyBackgroundColor: drawerBodyBackgroundColor,
            colorScheme: colorScheme,
            header: { progress in
                collapsedHeaderBar(revealProgress: progress)
                    .overlay(alignment: .top) {
                        resizeHandle
                            .opacity(Double(progress))
                            .allowsHitTesting(logManager.isDrawerExpanded)
                    }
            },
            drawerBody: {
                expandedDrawerContent
                    .allowsHitTesting(logManager.isDrawerExpanded)
                    .accessibilityHidden(!logManager.isDrawerExpanded)
            }
        )
        .animation(.spring(response: 0.26, dampingFraction: 0.92), value: logManager.isDrawerExpanded)
        .onAppear {
            refreshActiveDiagnoses()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UMConnectionStateDidChangeNotification"))) { _ in
            refreshActiveDiagnoses()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("HostDeviceDidUpdateNotification"))) { _ in
            refreshActiveDiagnoses()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name(HostDevicesManager.HostDevicesConfigurationDidChangeNotification))) { _ in
            refreshActiveDiagnoses()
        }
        .onReceive(NotificationCenter.default.publisher(for: .UMAccessibilityStatusDidChange)) { _ in
            refreshActiveDiagnoses()
        }
        .onReceive(logManager.$entries) { _ in
            refreshActiveDiagnoses()
        }
    }

    // MARK: - Expanded Drawer Content

    private var expandedDrawerContent: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(drawerInnerSeparatorColor)
                .frame(height: 1)

            filterToolbar
                .background(drawerToolbarBackgroundColor, ignoresSafeAreaEdges: [])

            Rectangle()
                .fill(drawerInnerSeparatorColor)
                .frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    // Active troubleshooting cards for devices currently failing to connect/reconnect
                    ForEach(filteredActiveDiagnoses) { item in
                        ActiveDiagnosticBannerView(
                            item: item,
                            onPerformAction: { action in
                                logManager.performAction(action)
                                refreshActiveDiagnoses()
                            },
                            onDismissError: {
                                if let host = HostDevicesManager.shared.host(withIdentifier: item.id) {
                                    host.lastError = nil
                                }
                                DeviceConnectionManager.shared.clearLastDiagnosis(for: item.id)
                                refreshActiveDiagnoses()
                            }
                        )
                    }

                    // Timeline entries
                    let entries = logManager.filteredEntries
                    if entries.isEmpty {
                        emptyLogPlaceholder
                    } else {
                        ForEach(entries) { entry in
                            ActivityLogEntryRow(
                                entry: entry,
                                onPerformAction: { action in
                                    logManager.performAction(action)
                                },
                                onFilterHost: { hostId in
                                    logManager.selectedHostId = (logManager.selectedHostId == hostId) ? nil : hostId
                                }
                            )
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(drawerBodyBackgroundColor, ignoresSafeAreaEdges: [])
        }
    }

    // MARK: - Drawer Surface Palette

    private var drawerTopBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.16)
            : Color.black.opacity(0.16)
    }

    private var drawerInnerSeparatorColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.09)
    }

    private var drawerHeaderBackgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.17, blue: 0.19)
            : Color(red: 0.90, green: 0.91, blue: 0.93)
    }

    private var drawerToolbarBackgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.135, green: 0.145, blue: 0.165)
            : Color(red: 0.925, green: 0.932, blue: 0.948)
    }

    private var drawerBodyBackgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.112, blue: 0.128)
            : Color(red: 0.942, green: 0.948, blue: 0.962)
    }

    // MARK: - Filtered Active Diagnoses

    private var filteredActiveDiagnoses: [ActiveHostDiagnostic] {
        _ = refreshTrigger
        return activeDiagnoses.filter { item in
            if let selectedHost = logManager.selectedHostId,
               item.id != selectedHost,
               item.id != LocalHost.shared.identifier {
                return false
            }
            if let category = logManager.selectedCategory,
               category != .connection && category != .control {
                return false
            }
            return true
        }
    }

    private func refreshActiveDiagnoses() {
        let hosts = (HostDevicesManager.shared.hosts(with: .peered) as? [RemoteHost] ?? [])
            .filter { !$0.computerName.isEmpty }
        let manager = DeviceConnectionManager.shared
        var items: [ActiveHostDiagnostic] = []

        if !AccessibilityManager.isTrusted {
            let localDiag = ConnectionFailureDiagnosis(
                shortReason: AccessibilityManager.shared.statusBannerTitle,
                whyFailed: AccessibilityManager.shared.activityLogDetail,
                howToFix: AccessibilityManager.shared.activityLogHowToFix,
                actions: [.openAccessibilitySettings]
            )
            items.append(
                ActiveHostDiagnostic(
                    id: LocalHost.shared.identifier,
                    hostName: "\(LocalHost.shared.computerName) (This Mac)",
                    linkPhase: .connected,
                    attemptCount: 0,
                    maxAttempts: 0,
                    secondsRemaining: nil,
                    diagnosis: localDiag
                )
            )
        }

        for host in hosts {
            let phase = manager.linkPhase(for: host)
            let hasActiveError = (host.lastError?.isEmpty == false)
            guard phase != .connected || hasActiveError else { continue }
            // Only highlight troubleshooting cards for devices discovered via Bonjour (.peeredOnline),
            // actively in the reconnect loop, or connected with an active control error.
            guard host.isInState(.peeredOnline) || phase == .reconnecting || (phase == .connected && hasActiveError) else { continue }
            if phase != .connected, let diagnosis = manager.lastDiagnosis(for: host.identifier) {
                items.append(
                    ActiveHostDiagnostic(
                        id: host.identifier,
                        hostName: host.computerName,
                        linkPhase: phase,
                        attemptCount: manager.reconnectAttemptCount(for: host.identifier),
                        maxAttempts: manager.maxReconnectAttemptsCount,
                        secondsRemaining: manager.reconnectSecondsRemaining(for: host),
                        diagnosis: diagnosis
                    )
                )
            } else if let lastErr = host.lastError, !lastErr.isEmpty {
                let diag = ConnectionFailureDiagnoser.diagnose(
                    rawReason: lastErr,
                    hostId: host.identifier,
                    hostName: host.computerName,
                    targetAddress: host.address,
                    targetPort: host.port,
                    localInterfaces: NetworkUtils.activeIPv4Interfaces(onlySupported: true),
                    selectedLocalIP: NetworkConfigurationWatcher.shared.selectedLocalIpAddress,
                    isBonjourOnline: host.isInState(.peeredOnline)
                )
                items.append(
                    ActiveHostDiagnostic(
                        id: host.identifier,
                        hostName: host.computerName,
                        linkPhase: phase,
                        attemptCount: manager.reconnectAttemptCount(for: host.identifier),
                        maxAttempts: manager.maxReconnectAttemptsCount,
                        secondsRemaining: manager.reconnectSecondsRemaining(for: host),
                        diagnosis: diag
                    )
                )
            }
        }

        activeDiagnoses = items
        refreshTrigger = UUID()
    }

    // MARK: - Resize Handle

    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 8)
                .contentShape(Rectangle())
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 3)
        }
        .onHover { inside in
            if inside {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartHeight == nil {
                        dragStartHeight = effectiveDrawerHeight
                    }
                    let base = dragStartHeight ?? effectiveDrawerHeight
                    let proposed = base - value.translation.height
                    let clamped = min(max(proposed, minDrawerHeight), dynamicMaxDrawerHeight)
                    if abs(clamped - drawerHeight) >= 0.5 {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            drawerHeight = clamped
                        }
                    }
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
    }

    // MARK: - Collapsed / Top Header Bar

    private func collapsedHeaderBar(revealProgress: CGFloat) -> some View {
        HStack(spacing: 10) {
            // Status indicator dot / icon
            statusIndicator

            // Latest activity summary
            if let latest = logManager.latestEntry {
                HStack(spacing: 6) {
                    Text(Self.timeFormatter.string(from: latest.timestamp))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)

                    Text(latest.title)
                        .font(.callout)
                        .fontWeight(latest.level.isIssue ? .medium : .regular)
                        .foregroundColor(latest.level == .error ? .red : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if latest.occurrenceCount > 1 {
                        Text("×\(latest.occurrenceCount)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text("Activity Log — Monitoring connections, network, displays, and Bonjour")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Quick fix action button when an active issue exists (layout-invariant across expand/collapse)
            if let primaryIssue = activeDiagnoses.first,
               let firstAction = primaryIssue.diagnosis.actions.first {
                Button {
                    logManager.performAction(firstAction)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: firstAction.iconName)
                            .font(.caption2)
                        Text(firstAction.title)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }

            // Active issue / historical issue badge (layout-invariant across expand/collapse)
            if !activeDiagnoses.isEmpty {
                Button {
                    logManager.isDrawerExpanded = true
                    logManager.unreadIssueCount = 0
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.caption2)
                        Text("\(activeDiagnoses.count) Issue\(activeDiagnoses.count == 1 ? "" : "s") — How to Fix")
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red.opacity(0.15)))
                    .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .fixedSize()
            } else if logManager.issueCount > 0 {
                Button {
                    logManager.presentDrawer(issuesOnly: true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text("\(logManager.issueCount)")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
                    .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }

            // Expand / Collapse button (fixed text & width so it moves cleanly with the header bar)
            Button {
                logManager.toggleDrawer()
            } label: {
                HStack(spacing: 4) {
                    Text("Activity Log")
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(Double(revealProgress) * 180))
                }
                .foregroundColor(.primary.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: Self.collapsedHeaderHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            logManager.toggleDrawer()
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if !activeDiagnoses.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.system(size: 13))
        } else if let latest = logManager.latestEntry {
            Image(systemName: latest.level.iconName)
                .foregroundColor(color(for: latest.level))
                .font(.system(size: 13))
        } else {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        }
    }

    // MARK: - Filter Toolbar

    private var filterToolbar: some View {
        HStack(spacing: 8) {
            // Category pills (pure SwiftUI HStack so no AppKit NSScrollView lags during drawer slide)
            HStack(spacing: 4) {
                CategoryFilterPill(
                    title: "All",
                    icon: "list.bullet.rectangle",
                    isSelected: logManager.selectedCategory == nil
                ) {
                    logManager.selectedCategory = nil
                }

                ForEach(ActivityLogCategory.allCases) { category in
                    CategoryFilterPill(
                        title: category.rawValue,
                        icon: category.iconName,
                        isSelected: logManager.selectedCategory == category
                    ) {
                        logManager.selectedCategory = (logManager.selectedCategory == category) ? nil : category
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            // Selected host filter chip
            if let selectedHostId = logManager.selectedHostId {
                let hostName = logManager.knownHostsInLog.first(where: { $0.id == selectedHostId })?.name ?? selectedHostId
                Button {
                    logManager.selectedHostId = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer")
                            .font(.caption2)
                        Text(hostName)
                            .font(.caption)
                            .fontWeight(.medium)
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Clear device filter")
            } else if logManager.knownHostsInLog.count > 1 {
                Menu {
                    Button("All Devices") {
                        logManager.selectedHostId = nil
                    }
                    Divider()
                    ForEach(logManager.knownHostsInLog, id: \.id) { host in
                        Button(host.name) {
                            logManager.selectedHostId = host.id
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer")
                        Text("Device")
                    }
                    .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Spacer()

            // Issues only toggle
            Button {
                logManager.showIssuesOnly.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: logManager.showIssuesOnly ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                    Text("Issues Only")
                }
                .font(.caption)
                .fontWeight(logManager.showIssuesOnly ? .semibold : .regular)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(logManager.showIssuesOnly ? Color.orange.opacity(0.2) : Color.clear)
                )
                .foregroundColor(logManager.showIssuesOnly ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help("Show only warnings and errors")

            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Filter…", text: $logManager.searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(width: 110)
                if !logManager.searchText.isEmpty {
                    Button {
                        logManager.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )

            // Copy button
            Button {
                logManager.copyExportedTextToPasteboard()
                withAnimation {
                    justCopied = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation {
                        justCopied = false
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    Text(justCopied ? "Copied" : "Copy")
                }
                .font(.caption)
                .foregroundColor(justCopied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy diagnostic log to clipboard")

            // Clear button
            Button {
                logManager.clear()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "trash")
                    Text("Clear")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear activity log")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Empty Placeholder

    private var emptyLogPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
            Text(logManager.showIssuesOnly ? "No active warnings or errors" : "No matching activity events")
                .font(.callout)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Text("Connection attempts, IP changes, screen layout updates, and Bonjour broadcasts will appear here in real time.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func color(for level: ActivityLogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - Frame-Synchronized Animatable Drawer Container

@available(macOS 13.0, *)
private struct AnimatableDrawerContainer<Header: View, DrawerBody: View>: View, Animatable {
    var revealProgress: CGFloat
    let collapsedHeaderHeight: CGFloat
    let expandedBodyHeight: CGFloat
    let topBorderColor: Color
    let headerBackgroundColor: Color
    let bodyBackgroundColor: Color
    let colorScheme: ColorScheme
    @ViewBuilder let header: (CGFloat) -> Header
    @ViewBuilder let drawerBody: () -> DrawerBody

    var animatableData: CGFloat {
        get { revealProgress }
        set { revealProgress = newValue }
    }

    var body: some View {
        let metrics = ActivityLogDrawerGeometry.computeMetrics(
            revealProgress: revealProgress,
            collapsedHeaderHeight: collapsedHeaderHeight,
            expandedBodyHeight: expandedBodyHeight,
            isDarkMode: colorScheme == .dark
        )

        VStack(spacing: 0) {
            Rectangle()
                .fill(topBorderColor)
                .frame(height: 1)

            header(metrics.clampedProgress)
                .background(headerBackgroundColor, ignoresSafeAreaEdges: [])

            drawerBody()
                .frame(height: expandedBodyHeight, alignment: .top)
        }
        .frame(height: metrics.fullExpandedHeight, alignment: .top)
        .background(bodyBackgroundColor, ignoresSafeAreaEdges: [])
        .frame(height: metrics.currentVisibleHeight, alignment: .top)
        .clipped()
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(metrics.shadowOpacity)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: metrics.shadowHeight)
            .offset(y: -metrics.shadowHeight)
            .allowsHitTesting(false)
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

// MARK: - Category Filter Pill

@available(macOS 13.0, *)
private struct CategoryFilterPill: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .foregroundColor(isSelected ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Active Diagnostic Banner View

@available(macOS 13.0, *)
private struct ActiveDiagnosticBannerView: View {
    let item: ActivityLogDrawerView.ActiveHostDiagnostic
    let onPerformAction: (ActivityFixAction) -> Void
    let onDismissError: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 14))

                Text("Troubleshooting \(item.hostName)")
                    .font(.callout)
                    .fontWeight(.semibold)

                Text(statusBadgeText)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.14)))
                    .foregroundColor(.red)

                Spacer()

                Button {
                    onDismissError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss diagnostic card")
            }

            // Why it failed
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Text("Why it failed:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .frame(width: 82, alignment: .leading)
                    Text(item.diagnosis.whyFailed)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }

                HStack(alignment: .top, spacing: 6) {
                    Text("How to fix:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                        .frame(width: 82, alignment: .leading)
                    Text(item.diagnosis.howToFix)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }
            }

            // Actionable buttons
            if !item.diagnosis.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(item.diagnosis.actions.enumerated()), id: \.element.id) { index, action in
                        Button {
                            onPerformAction(action)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: action.iconName)
                                    .font(.caption2)
                                Text(action.title)
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(index == 0 ? Color.accentColor : Color.secondary.opacity(0.14))
                            )
                            .foregroundColor(index == 0 ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
        )
    }

    private var statusBadgeText: String {
        switch item.linkPhase {
        case .reconnecting:
            if let sec = item.secondsRemaining, sec > 0 {
                return "\(item.diagnosis.shortReason) · Retry \(max(item.attemptCount, 1))/\(item.maxAttempts) in \(sec)s"
            }
            return "\(item.diagnosis.shortReason) · Attempt \(max(item.attemptCount, 1))/\(item.maxAttempts)"
        case .connecting:
            return "Connecting…"
        case .disconnected, .unavailable:
            if item.attemptCount >= item.maxAttempts {
                return "\(item.diagnosis.shortReason) · Paused after \(item.maxAttempts) retries"
            }
            return item.diagnosis.shortReason
        case .connected:
            return item.diagnosis.shortReason
        }
    }
}

// MARK: - Activity Log Entry Row

@available(macOS 13.0, *)
private struct ActivityLogEntryRow: View {
    let entry: ActivityLogEntry
    let onPerformAction: (ActivityFixAction) -> Void
    let onFilterHost: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isExpanded: Bool = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Timestamp
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)

                // Level icon
                Image(systemName: entry.level.iconName)
                    .foregroundColor(levelColor)
                    .font(.system(size: 12))

                // Category badge
                Text(entry.category.rawValue)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.14))
                    )
                    .foregroundColor(.secondary)

                // Host badge (clickable to filter)
                if let hostName = entry.hostName, let hostId = entry.hostId {
                    Button {
                        onFilterHost(hostId)
                    } label: {
                        Text(hostName)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.opacity(0.14))
                            )
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Filter by \(hostName)")
                }

                // Title
                Text(entry.title)
                    .font(.callout)
                    .fontWeight(entry.level.isIssue ? .medium : .regular)
                    .foregroundColor(entry.level == .error ? .red : .primary)
                    .textSelection(.enabled)

                if entry.occurrenceCount > 1 {
                    Text("×\(entry.occurrenceCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if hasDetails {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: showDetailsSection ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if showDetailsSection {
                VStack(alignment: .leading, spacing: 5) {
                    if let detail = entry.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    if let howToFix = entry.howToFix, !howToFix.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .padding(.top, 2)
                            Text("How to fix: \(howToFix)")
                                .font(.caption)
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.orange.opacity(0.1))
                        )
                    }

                    if !entry.actions.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(entry.actions) { action in
                                Button {
                                    onPerformAction(action)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: action.iconName)
                                            .font(.caption2)
                                        Text(action.title)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Color.secondary.opacity(0.14))
                                    )
                                    .foregroundColor(.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.leading, 62)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(rowBorderColor, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if hasDetails {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
        }
    }

    private var hasDetails: Bool {
        (entry.detail != nil && !entry.detail!.isEmpty) ||
        (entry.howToFix != nil && !entry.howToFix!.isEmpty) ||
        !entry.actions.isEmpty
    }

    private var showDetailsSection: Bool {
        // Always expand issues (warnings/errors) by default so the user sees Why + How to fix immediately
        isExpanded || entry.level.isIssue
    }

    private var levelColor: Color {
        switch entry.level {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var rowBackgroundColor: Color {
        switch entry.level {
        case .error:
            return Color.red.opacity(colorScheme == .dark ? 0.10 : 0.07)
        case .warning:
            return Color.orange.opacity(colorScheme == .dark ? 0.08 : 0.06)
        default:
            return colorScheme == .dark
                ? Color.white.opacity(0.05)
                : Color.white.opacity(0.88)
        }
    }

    private var rowBorderColor: Color {
        switch entry.level {
        case .error:
            return Color.red.opacity(0.25)
        case .warning:
            return Color.orange.opacity(0.22)
        default:
            return colorScheme == .dark
                ? Color.white.opacity(0.07)
                : Color.black.opacity(0.06)
        }
    }
}
