// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import AppKit

class LocalHost: HostDevice {

    nonisolated(unsafe) static let shared: LocalHost = LocalHost()

    private var backgroundImages: [NSImage] = []

    override var address: String? {
        "127.0.0.1"
    }

    var mainScreen: Screen {
        screenAt(index: 0)!
    }

    init() {
        let hostName = Host.current().localizedName!
        super.init(
            name: hostName,
            macAddresses: NetworkUtils.getMacAddresses(),
            osVersion: SystemInfo.osVersion
        )
        screens = NSScreen.screens.toScreens()
        observeSystemEvents()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        observeSystemEvents()
    }

    private func observeSystemEvents() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(_generateBackgroundImages), name: NSNotification.Name("com.apple.desktop"),
            object: "BackgroundChanged")

        NotificationCenter.default.addObserver(
            self, selector: #selector(_accessibilityAPIChanged),
            name: .TPAccessibilityStatusDidChange, object: nil)
		
		NotificationCenter.default.addObserver(
					self,
					selector: #selector(screenParametersChanged),
					name: NSApplication.didChangeScreenParametersNotification,
					object: nil
				)
    }

    func backgroundImage(for screen: Screen) -> NSImage {
        if backgroundImages.isEmpty {
            _generateBackgroundImages()
        }

        let index = screens.firstIndex(of: screen)
        if let index = index {
            return backgroundImages[index]
        }

        return defaultBackgroundImage()
    }

    @objc private func _generateBackgroundImages() {
        backgroundImages = screens.map { screen in
            BackgroundImageResolver.desktopImage(for: screen)
        }
    }

    @objc private func _accessibilityAPIChanged() {
        notifyChange()
    }
	
	@objc func screenParametersChanged(notification: Notification) {
		let newScreens = NSScreen.screens.toScreens()
		if screens != newScreens {
			debugLog("Screens changed: \(screens.count) -> \(newScreens.count)", module: .control)
			screens = newScreens
			notifyChange()
		}
	}
	
	/// Returns the index of the local screen that contains the given point (in AppKit global screen coords).
	func screenIndex(containing point: NSPoint) -> UInt? {
		for (idx, screen) in screens.enumerated() {
			// Add a tiny tolerance so points on the border still match.
			let frame = screen.frame.insetBy(dx: -1, dy: -1)
			if frame.contains(point) {
				return UInt(idx)
			}
		}
		return nil
	}

    override var backgroundImage: NSImage? {
        backgroundImage(for: mainScreen)
    }

    override var capabilities: HostCapability {
        var capabilities: HostCapability = []

        for i in 0..<MAX_CAPABILITIES {
            let capability = HostCapability(rawValue: 1 << i)
            if hasCapability(capability) {
                capabilities.formUnion(capability)
            }
        }

        return capabilities
    }

		override func hasCapability(_ capability: HostCapability) -> Bool {
			return switch capability {
			case .encryption:
				false
			case .eventTaps:
				AccessibilityManager.isTrusted
			case .directEventTaps:
				AccessibilityManager.isTrusted && !PreferencesManager.shared().bool(forPref: Settings.tigerBehaviorKey)
			case .portable:
				SystemInfo.isLaptop
			default:
				false
			}
		}

	var bonjourName: String {
		"\(NSUserName())@\(computerName)"
    }

    func toData() -> Data {
		let data = NSMutableData()
        let archiver = NSKeyedArchiver(forWritingWith: data)
        self.encode(with: archiver)
        archiver.finishEncoding()
        return data as Data
    }

    override func value(forUndefinedKey key: String) -> Any? {
        return super.value(forUndefinedKey: key)
    }
}
