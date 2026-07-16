// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

/// Status of the Unimacs connection
@objc enum TPStatus: Int {
    case idle
    case controlling
    case controlled
}

private enum TPStatusBarIconState {
    case disconnected
    case connected
    /// Remote-control session in progress (controlling or being controlled).
    case active
    
    /// SF Symbol used for the menu-bar item. Symbols render as native template
    /// images, so they match macOS styling and adapt to light/dark menu bars.
    var symbolName: String {
        switch self {
        case .disconnected:
            return "point.3.connected.trianglepath.dotted"
        case .connected:
            return "point.3.filled.connected.trianglepath.dotted"
        case .active:
            return "cursorarrow.rays"
        }
    }
}

/// Controller for the menu bar status item
@objcMembers
class StatusItemController: NSObject, NSMenuDelegate {
    
    // MARK: - Singleton
    
    @objc static let `default` = StatusItemController()
    
    // MARK: - Properties
    
    private var statusItem: NSStatusItem?
    private var statusItemMenu: NSMenu?
    private var controlStatus: TPStatus = .idle
    
    @objc var showStatusItem: Bool {
        get { statusItem != nil }
        set { updateStatusItemVisibility(newValue) }
    }
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(connectionStateDidChange(_:)),
            name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
            object: nil
        )
        showStatusItem = true
    }
    
    // MARK: - Status Item Management
    
    private func updateStatusItemVisibility(_ show: Bool) {
        if show && statusItem == nil {
            createStatusItem()
        } else if !show && statusItem != nil {
            NSStatusBar.system.removeStatusItem(statusItem!)
            statusItem = nil
        }
    }
    
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        guard let statusItem = statusItem else { return }
        
        applyIconState(.disconnected, to: statusItem)
        
        let menu = NSMenu()
        menu.delegate = self
        self.statusItemMenu = menu
        
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        refreshStatusIcon()
    }
    
    // MARK: - Public Methods
    
    @objc func update(with status: TPStatus, host: RemoteHost?) {
        controlStatus = status
        refreshStatusIcon()
    }
    
    // MARK: - Icon State
    
    @objc private func connectionStateDidChange(_ notification: Notification) {
        refreshStatusIcon()
    }
    
    private func refreshStatusIcon() {
        guard statusItem != nil else { return }
        
        Task { @MainActor in
            guard let statusItem = self.statusItem else { return }
            let iconState = self.resolvedIconState()
            self.applyIconState(iconState, to: statusItem)
        }
    }
    
    @MainActor
    private func resolvedIconState() -> TPStatusBarIconState {
        switch controlStatus {
        case .controlling, .controlled:
            return .active
        case .idle:
            if DeviceConnectionManager.shared.isConnected {
                return .connected
            }
            return .disconnected
        }
    }
    
    private func applyIconState(_ iconState: TPStatusBarIconState, to statusItem: NSStatusItem) {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let image = NSImage(
            systemSymbolName: iconState.symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(config) else { return }
        image.isTemplate = true
        
        NSDisableScreenUpdates()
        statusItem.button?.title = ""
        statusItem.button?.image = image
        NSEnableScreenUpdates()
    }
    
    // MARK: - Actions
    
    #if DEBUG
    @objc private func disconnect() {
        Task { @MainActor in
            ClientController.shared.stopControl()
        }
    }
    #endif
    
    @objc private func quitApp() {
        NSApp.terminate(self)
    }
    
    @objc private func switchMenuItem(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let newValue = sender.state == .off
        PreferencesManager.shared().setValue(NSNumber(value: newValue), forKey: key)
    }
    
    @objc private func openUnimacsPanel() {
        ModernSettingsLauncher.showSettings()
    }
    
    @objc private func disconnectDevice(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? RemoteHost else { return }
        Task { @MainActor in
            DeviceConnectionManager.shared.disconnect(from: host)
        }
    }
    
    @objc private func stopControllingDevice() {
        Task { @MainActor in
            ClientController.shared.stopControl()
        }
    }
    
    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
        let isControlClick = event?.modifierFlags.contains(.control) == true
        
        if isRightClick || isControlClick {
            if let menu = self.statusItemMenu {
                statusItem?.menu = menu
                statusItem?.button?.performClick(nil)
            }
        } else {
            openUnimacsPanel()
        }
    }
    
    // MARK: - NSMenuDelegate
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        
        // 1. Configure item
        let openPrefPanelMenuItem = NSMenuItem(
            title: NSLocalizedString("Configure\u{2026}", comment: ""),
            action: #selector(openUnimacsPanel),
            keyEquivalent: ""
        )
        openPrefPanelMenuItem.target = self
        menu.addItem(openPrefPanelMenuItem)
        
        menu.addItem(.separator())
        
        // 2. Active Devices / Connections section
        let manager = DeviceConnectionManager.shared
        let hostsManager = HostDevicesManager.shared
        let peeredHosts = hostsManager.hosts(with: .peered) as? [RemoteHost] ?? []
        let connectedHosts = peeredHosts.filter { manager.linkPhase(for: $0) == .connected }
        
        if !connectedHosts.isEmpty {
            let activeHeader = NSMenuItem(title: NSLocalizedString("Connected Devices", comment: ""), action: nil, keyEquivalent: "")
            activeHeader.isEnabled = false
            menu.addItem(activeHeader)
            
            for host in connectedHosts {
                let name = host.computerName
                let hostItem = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                
                let subMenu = NSMenu()
                
                let disconnectSubItem = NSMenuItem(
                    title: NSLocalizedString("Disconnect Device", comment: ""),
                    action: #selector(disconnectDevice(_:)),
                    keyEquivalent: ""
                )
                disconnectSubItem.target = self
                disconnectSubItem.representedObject = host
                subMenu.addItem(disconnectSubItem)
                
                hostItem.submenu = subMenu
                menu.addItem(hostItem)
            }
            menu.addItem(.separator())
        }
        
        // 3. Client Control State (if controlling a device)
        let clientController = ClientController.shared
        if clientController.isControlling, let host = clientController.currentConnection?.connectedHost {
            let controllingItem = NSMenuItem(
                title: String(format: NSLocalizedString("Stop Controlling \u{201C}%@\u{201D}", comment: ""), host.computerName),
                action: #selector(stopControllingDevice),
                keyEquivalent: ""
            )
            controllingItem.target = self
            menu.addItem(controllingItem)
            menu.addItem(.separator())
        }
        
        // 4. Quit item
        let quitMenuItem = NSMenuItem(
            title: NSLocalizedString("Quit Unimacs", comment: ""),
            action: #selector(quitApp),
            keyEquivalent: ""
        )
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)
    }
    
    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }
}
