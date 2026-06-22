// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

/// Status of the teleport connection
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
    
    var imageName: String {
        switch self {
        case .disconnected:
            return "status-disconnected"
        case .connected:
            return "status-connected"
        case .active:
            return "status-active"
        }
    }
}

/// Controller for the menu bar status item
@objcMembers
class TPStatusItemController: NSObject {
    
    // MARK: - Singleton
    
    @objc static let `default` = TPStatusItemController()
    
    // MARK: - Properties
    
    private var statusItem: NSStatusItem?
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
        
        // Share this Mac menu item
        let sharedMenuItem = NSMenuItem(
            title: NSLocalizedString("Share this Mac", comment: ""),
            action: #selector(switchMenuItem(_:)),
            keyEquivalent: ""
        )
        sharedMenuItem.target = self
        sharedMenuItem.representedObject = ALLOW_CONTROL
        sharedMenuItem.bind(
            .value,
            to: TPPreferencesManager.shared(),
            withKeyPath: ALLOW_CONTROL,
            options: nil
        )
        menu.addItem(sharedMenuItem)
        
        menu.addItem(.separator())
        
        // Configure menu item
        let openPrefPanelMenuItem = NSMenuItem(
            title: NSLocalizedString("Configure\u{2026}", comment: ""),
            action: #selector(openTeleportPanel),
            keyEquivalent: ""
        )
        openPrefPanelMenuItem.target = self
        menu.addItem(openPrefPanelMenuItem)
        
        menu.addItem(.separator())
        
        #if DEBUG
        // Disconnect menu item (debug only)
        let disconnectMenuItem = NSMenuItem(
            title: "Disconnect",
            action: #selector(disconnect),
            keyEquivalent: ""
        )
        disconnectMenuItem.target = self
        menu.addItem(disconnectMenuItem)
        #endif
        
        // Quit menu item
        let quitMenuItem = NSMenuItem(
            title: NSLocalizedString("Quit teleport", comment: ""),
            action: #selector(quitApp),
            keyEquivalent: ""
        )
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)
        
        statusItem.menu = menu
        refreshStatusIcon()
    }
    
    // MARK: - Public Methods
    
    @objc func update(with status: TPStatus, host: TPRemoteHost?) {
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
        guard let image = NSImage(named: iconState.imageName) else { return }
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
            TPClientController.shared.stopControl()
        }
    }
    #endif
    
    @objc private func quitApp() {
        NSApp.terminate(self)
    }
    
    @objc private func switchMenuItem(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let newValue = sender.state == .off
        TPPreferencesManager.shared().setValue(NSNumber(value: newValue), forKey: key)
    }
    
    @objc private func openTeleportPanel() {
        ModernSettingsLauncher.showSettings()
    }
}
