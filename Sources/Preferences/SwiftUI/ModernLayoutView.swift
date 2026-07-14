// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  Modern SwiftUI layout view for arranging connected displays.
//  Style aligned with macOS System Settings display arrangement.

import SwiftUI

// MARK: - Layout Constants

private enum LayoutConstants {
    static let minScale: CGFloat = 0.03
    static let maxScale: CGFloat = 0.12
    static let defaultScale: CGFloat = 0.06
    static let padding: CGFloat = 40
    static let screenCornerRadius: CGFloat = 10
}

// MARK: - Modern Layout View

@available(macOS 13.0, *)
struct ModernLayoutView: View {
    @StateObject private var viewModel = LayoutViewModel()
    @State private var selectedHostId: String?
    @State private var isDragging: Bool = false
    @State private var frozenLayoutInfo: LayoutInfo?
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Arrange Displays")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Drag connected devices to arrange their position. Devices on the edges will be accessible from that direction.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            
            if !viewModel.isAccessibilityTrusted {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .imageScale(.large)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility Permission Required")
                            .font(.headline)
                        Text("Teleport requires Accessibility permission to control mouse and keyboard. Please authorize it in System Settings.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button("Authorize...") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                )
                .padding(.horizontal, 24)
            }
            
            // Layout Canvas
            GeometryReader { geometry in
                let currentLayoutInfo = viewModel.calculateLayoutInfo(for: geometry.size)
                // Use frozen layout during drag, otherwise calculate fresh
                let layoutInfo = isDragging ? (frozenLayoutInfo ?? currentLayoutInfo) : currentLayoutInfo
                
                ZStack {
                    // Background
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    
                    // All screens (local + remote) positioned in global coordinates
                    ForEach(viewModel.allScreens) { screenInfo in
                        SystemStyleScreenView(
                            hostName: screenInfo.hostName,
                            isLocal: screenInfo.isLocal,
                            isMainScreen: screenInfo.isMainScreen,
                            scale: layoutInfo.scale,
                            isAccessibilityTrusted: viewModel.isAccessibilityTrusted
                        )
                        .frame(
                            width: screenInfo.globalFrame.width * layoutInfo.scale,
                            height: screenInfo.globalFrame.height * layoutInfo.scale
                        )
                        .shadow(
                            color: (!screenInfo.isLocal && selectedHostId == screenInfo.hostId) ? Color.accentColor.opacity(0.3) : Color.clear,
                            radius: 8
                        )
                        .position(
                            x: layoutInfo.offsetX + screenInfo.globalFrame.midX * layoutInfo.scale,
                            y: layoutInfo.offsetY - screenInfo.globalFrame.midY * layoutInfo.scale
                        )
                        .gesture(
                            screenInfo.isLocal ? nil : DragGesture()
                                .onChanged { value in
                                    // Freeze layout on first drag
                                    if !isDragging {
                                        isDragging = true
                                        frozenLayoutInfo = currentLayoutInfo
                                    }
                                    selectedHostId = screenInfo.hostId
                                    let activeLayoutInfo = frozenLayoutInfo ?? currentLayoutInfo
                                    viewModel.updateHostPosition(
                                        hostId: screenInfo.hostId,
                                        delta: CGSize(
                                            width: value.translation.width / activeLayoutInfo.scale,
                                            height: -value.translation.height / activeLayoutInfo.scale
                                        )
                                    )
                                }
                                .onEnded { _ in
                                    // Snap and commit position first to avoid a transient rescale flicker before snapping
                                    viewModel.snapHostToEdge(hostId: screenInfo.hostId)
                                    viewModel.commitDrag(hostId: screenInfo.hostId)

                                    // Unfreeze after snapping to trigger adaptive canvas scaling
                                    isDragging = false
                                    frozenLayoutInfo = nil
                                }
                        )
                        .onTapGesture {
                            if !screenInfo.isLocal {
                                selectedHostId = screenInfo.hostId
                            }
                        }
                    }
                    

                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.startObserving()
        }
        .onDisappear {
            viewModel.stopObserving()
        }
    }
}

// MARK: - System Style Screen View (macOS Settings style)

@available(macOS 13.0, *)
struct SystemStyleScreenView: View {
    let hostName: String
    let isLocal: Bool
    let isMainScreen: Bool
    let scale: CGFloat
    var isAccessibilityTrusted: Bool = true
    
    var body: some View {
        ZStack {
            // Screen background - solid color like system settings
            RoundedRectangle(cornerRadius: LayoutConstants.screenCornerRadius)
                .fill(isLocal ? (isAccessibilityTrusted ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15)) : Color.purple.opacity(0.15))
            
            // Screen border
            RoundedRectangle(cornerRadius: LayoutConstants.screenCornerRadius)
                .strokeBorder(
                    isLocal ? (isAccessibilityTrusted ? Color.blue : Color.orange) : Color.purple,
                    lineWidth: isMainScreen ? 3 : 2
                )
            
            // Menu bar for main screen
            if isMainScreen {
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.5))
                        .frame(height: 5)
                        .padding(.horizontal, 6)
                        .padding(.top, 5)
                    Spacer()
                }
            }
            
            // Host name in center for main screen only
            if isMainScreen {
                VStack(spacing: 4) {
                    Text(hostName)
                        .font(.system(size: max(9, 11 * scale * 12)))
                        .fontWeight(.medium)
                        .foregroundColor(isLocal ? (isAccessibilityTrusted ? .blue : .orange) : .purple)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    
                    if isLocal && !isAccessibilityTrusted {
                        HStack(spacing: 2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: max(8, 10 * scale * 12)))
                            Text("Unauthorized")
                                .font(.system(size: max(8, 9 * scale * 12)))
                        }
                        .foregroundColor(.orange)
                    }
                }
            }
        }
    }
}

// MARK: - Screen Info (for rendering)

struct ScreenInfo: Identifiable {
    let id: String  // unique id: hostId + screenIndex
    let hostId: String
    let hostName: String
    let isLocal: Bool
    let isMainScreen: Bool
    var globalFrame: CGRect  // Frame in global coordinate space
}

// MARK: - Layout Info

struct LayoutInfo {
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
}

// MARK: - Layout ViewModel

@available(macOS 13.0, *)
@MainActor
final class LayoutViewModel: ObservableObject {
    @Published var localHostLayout: HostLayout?
    @Published var connectedHostLayouts: [HostLayout] = []
    @Published var allScreens: [ScreenInfo] = []
    @Published var isAccessibilityTrusted: Bool = AccessibilityManager.isTrusted
    
    private var hostObserver: NSObjectProtocol?
    private var connectionObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var dragStartPositions: [String: CGPoint] = [:]
    
    init() {
        loadLayouts()
    }
    
    // MARK: - Observation
    
    func startObserving() {
        warningLog("[LayoutSyncUI] startObserving called", module: .control)
        hostObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TPHostDidUpdateNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            warningLog("[LayoutSyncUI] Received TPHostDidUpdateNotification", module: .control)
            self?.loadLayouts()
        }
        
        connectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TPConnectionStateDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            warningLog("[LayoutSyncUI] Received TPConnectionStateDidChangeNotification", module: .control)
            self?.loadLayouts()
        }
        
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: .TPAccessibilityStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            warningLog("[LayoutSyncUI] Received TPAccessibilityStatusDidChange", module: .control)
            self?.isAccessibilityTrusted = AccessibilityManager.isTrusted
        }
        
        loadLayouts()
    }
    
    func stopObserving() {
        if let observer = hostObserver {
            NotificationCenter.default.removeObserver(observer)
            hostObserver = nil
        }
        if let observer = connectionObserver {
            NotificationCenter.default.removeObserver(observer)
            connectionObserver = nil
        }
        if let observer = accessibilityObserver {
            NotificationCenter.default.removeObserver(observer)
            accessibilityObserver = nil
        }
    }
    
    // MARK: - Load Layouts
    
    func loadLayouts() {
        warningLog("[LayoutSyncUI] loadLayouts called", module: .control)
        isAccessibilityTrusted = AccessibilityManager.isTrusted
        // Load local host
        let localHost = TPLocalHost.shared
        localHostLayout = HostLayout(from: localHost)
        
        // Load connected remote hosts
        let connectedHosts = getConnectedHosts()
        
        // Preserve drag positions during drag
        let existingPositions = Dictionary(uniqueKeysWithValues: connectedHostLayouts.map { ($0.id, $0.position) })
        
        connectedHostLayouts = connectedHosts.map { host in
            var layout = HostLayout(from: host)
            warningLog("[LayoutSyncUI] Loaded host \(host.computerName) position: \(layout.position)", module: .control)
            
            // Preserve position if currently dragging this host
            if let existingPos = existingPositions[layout.id], dragStartPositions[layout.id] != nil {
                layout.position = existingPos
            }
            // Note: adjustedHostDesktopRect already handles initial positioning/snapping
            
            return layout
        }
        
        // Build all screens list for rendering
        rebuildAllScreens()
    }
    
    private func rebuildAllScreens() {
        var screens: [ScreenInfo] = []
        
        // Add local host screens
        if let local = localHostLayout {
            for (index, screen) in local.screens.enumerated() {
                screens.append(ScreenInfo(
                    id: "\(local.id)_\(index)",
                    hostId: local.id,
                    hostName: "This Mac",
                    isLocal: true,
                    isMainScreen: screen.isMain,
                    globalFrame: screen.frame  // Local screens are already in global coords
                ))
            }
        }
        
        // Add remote host screens
        for hostLayout in connectedHostLayouts {
            for (index, screen) in hostLayout.screens.enumerated() {
                // Remote screen global frame = screen frame offset by host position
                let globalFrame = CGRect(
                    x: hostLayout.position.x + (screen.frame.origin.x - hostLayout.bounds.origin.x),
                    y: hostLayout.position.y + (screen.frame.origin.y - hostLayout.bounds.origin.y),
                    width: screen.frame.width,
                    height: screen.frame.height
                )
                
                screens.append(ScreenInfo(
                    id: "\(hostLayout.id)_\(index)",
                    hostId: hostLayout.id,
                    hostName: hostLayout.name,
                    isLocal: false,
                    isMainScreen: screen.isMain,
                    globalFrame: globalFrame
                ))
            }
        }
        
        allScreens = screens
    }
    
    private func getConnectedHosts() -> [TPRemoteHost] {
        // Get all hosts that are in controlled state (being actively controlled)
        let controlledHosts = TPHostsManager.shared.hosts(with: .controlled) as? [TPRemoteHost] ?? []
        
        // Also get all paired online hosts - they should be shown in layout
        // because they are available for control
        let peeredOnlineHosts = TPHostsManager.shared.hosts(with: .peeredOnline) as? [TPRemoteHost] ?? []
        
        var result: [TPRemoteHost] = []
        var seenIds: Set<String> = []
        
        // Add controlled hosts first (higher priority)
        for host in controlledHosts {
            if !seenIds.contains(host.identifier) {
                result.append(host)
                seenIds.insert(host.identifier)
            }
        }
        
        // Add paired online hosts (they should appear in layout for arrangement)
        for host in peeredOnlineHosts {
            if !seenIds.contains(host.identifier) {
                result.append(host)
                seenIds.insert(host.identifier)
            }
        }
        
        return result
    }
    

    // MARK: - Layout Calculation
    
    func calculateLayoutInfo(for containerSize: CGSize) -> LayoutInfo {
        // Calculate bounding box of all screens
        var globalBounds = CGRect.null
        
        for screen in allScreens {
            globalBounds = globalBounds.union(screen.globalFrame)
        }
        
        if globalBounds.isNull {
            globalBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        
        // Calculate scale to fit
        let availableWidth = containerSize.width - LayoutConstants.padding * 2
        let availableHeight = containerSize.height - LayoutConstants.padding * 2
        
        let scaleX = availableWidth / globalBounds.width
        let scaleY = availableHeight / globalBounds.height
        
        let scale = min(
            max(min(scaleX, scaleY), LayoutConstants.minScale),
            LayoutConstants.maxScale
        )
        
        // Calculate offset to center
        let scaledWidth = globalBounds.width * scale
        let scaledHeight = globalBounds.height * scale
        
        let offsetX = (containerSize.width - scaledWidth) / 2 - globalBounds.minX * scale
        let offsetY = (containerSize.height + scaledHeight) / 2 + globalBounds.minY * scale
        
        return LayoutInfo(scale: scale, offsetX: offsetX, offsetY: offsetY)
    }
    
    // MARK: - Host Positioning
    
    func updateHostPosition(hostId: String, delta: CGSize) {
        guard let index = connectedHostLayouts.firstIndex(where: { $0.id == hostId }) else { return }
        
        // Store start position if not already stored
        if dragStartPositions[hostId] == nil {
            dragStartPositions[hostId] = connectedHostLayouts[index].position
        }
        
        guard let startPos = dragStartPositions[hostId] else { return }
        
        // Update position from start + delta
        connectedHostLayouts[index].position = CGPoint(
            x: startPos.x + delta.width,
            y: startPos.y + delta.height
        )
        
        // Rebuild screens for rendering
        rebuildAllScreens()
    }
    
    func commitDrag(hostId: String) {
        dragStartPositions.removeValue(forKey: hostId)
    }
    
    func snapHostToEdge(hostId: String) {
        guard let index = connectedHostLayouts.firstIndex(where: { $0.id == hostId }),
              let local = localHostLayout else { return }

        var hostLayout = connectedHostLayouts[index]

        // Calculate local host bounds (union of local screens, already in global coords)
        var localBounds = CGRect.null
        for screen in local.screens {
            localBounds = localBounds.union(screen.frame)
        }
        guard !localBounds.isNull else { return }

        // Remote host bounds in global coords (hostLayout.position is the global origin of hostLayout.bounds)
        let movingRect = CGRect(origin: hostLayout.position, size: hostLayout.bounds.size)
        guard movingRect != .zero else { return }

        // Glue to the nearest edge (no threshold). This matches TPRemoteHost.adjustedHostDesktopRect.
        let result = TPGluedRect(localBounds, movingRect, excluding: [])
        hostLayout.position = result.rect.origin

        connectedHostLayouts[index] = hostLayout
        rebuildAllScreens()
        saveHostPosition(hostLayout)
    }
    
    private func saveHostPosition(_ layout: HostLayout) {
        guard let host = TPHostsManager.shared.host(withIdentifier: layout.id) else { return }
        // Save the position as desktopOrigin
        host.desktopOrigin = NSPoint(x: layout.position.x, y: layout.position.y)
        TPHostsManager.shared.saveHosts()
        
        // Broadcast the new layout with an incremented version number
        let newVersion = TPHostsManager.shared.incrementLayoutVersion()
        if let desktop = TPHostsManager.shared.currentUnifiedDesktop(version: newVersion) {
            TPHostsManager.shared.broadcastUnifiedDesktop(desktop)
        }
    }
}

// MARK: - Host Layout Model

struct HostLayout: Identifiable {
    let id: String
    let name: String
    let address: String?
    let screens: [ScreenLayout]
    let bounds: CGRect  // Bounding rect of all screens in host's local coordinate space
    var position: CGPoint  // Position of bounds.origin in global coordinates
    
    init(from host: TPHost) {
        self.id = host.identifier
        self.name = host.computerName
        self.address = host.address
        
        // Convert screens
        var screenLayouts: [ScreenLayout] = []
        for (index, screen) in host.screens.enumerated() {
            screenLayouts.append(ScreenLayout(frame: screen.frame, isMain: index == 0))
        }
        self.screens = screenLayouts
        
        // Calculate bounds (union of all screen frames)
        var unionRect = CGRect.null
        for screen in screens {
            unionRect = unionRect.union(screen.frame)
        }
        self.bounds = unionRect.isNull ? CGRect(x: 0, y: 0, width: 1920, height: 1080) : unionRect
        
        // Get position from remote host
        if let remoteHost = host as? TPRemoteHost {
            // Use adjustedHostDesktopRect which handles gluing/snapping to local desktop
            let adjustedRect = remoteHost.adjustedHostDesktopRect
            if adjustedRect != .zero {
                // The adjustedRect is the position in global coordinates
                self.position = CGPoint(x: adjustedRect.origin.x, y: adjustedRect.origin.y)
            } else {
                // Fallback to desktopOrigin
                let origin = remoteHost.desktopOrigin
                self.position = CGPoint(x: origin.x, y: origin.y)
            }
        } else {
            // Local host position is always at its bounds origin (screens are in global coords)
            self.position = .zero
        }
    }
}

// MARK: - Screen Layout Model

struct ScreenLayout {
    let frame: CGRect
    let isMain: Bool
}

// MARK: - Preview

@available(macOS 13.0, *)
#Preview {
    ModernLayoutView()
        .frame(width: 600, height: 400)
}
