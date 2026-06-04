// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  Window controller for the modern SwiftUI settings interface.

import SwiftUI
import AppKit

@available(macOS 13.0, *)
@objcMembers
class SettingsWindowController: NSWindowController {
    
    // MARK: - Singleton
    
    private static var _shared: SettingsWindowController?
    
    static var shared: SettingsWindowController {
        if _shared == nil {
            _shared = SettingsWindowController()
        }
        return _shared!
    }
    
    // MARK: - Initialization
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        self.init(window: window)
        
        setupWindow()
    }
    
    private func setupWindow() {
        guard let window = window else { return }
        
        window.title = "teleport"
        window.minSize = NSSize(width: 750, height: 500)
        window.center()
        window.setFrameAutosaveName("TeleportSettingsWindow")
        
        // Set toolbar style for modern appearance
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        
        // Create and set the SwiftUI content
        let settingsView = SettingsView()
        let hostingView = NSHostingView(rootView: settingsView)
        window.contentView = hostingView
        
        // Set window delegate
        window.delegate = self
    }
    
    // MARK: - Public Methods
    
    func showSettings() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - NSWindowDelegate

@available(macOS 13.0, *)
extension SettingsWindowController: NSWindowDelegate {
    
    func windowWillClose(_ notification: Notification) {
        // Optionally handle window close
    }
}

// MARK: - Objective-C Bridge

/// Objective-C compatible wrapper for showing the modern settings window
@objcMembers
class ModernSettingsLauncher: NSObject {
    
    /// Check if modern settings are available (macOS 13+)
    @objc static var isAvailable: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }
    
    /// Show the modern settings window
    @objc static func showSettings() {
        SettingsWindowController.shared.showSettings()
    }
}
