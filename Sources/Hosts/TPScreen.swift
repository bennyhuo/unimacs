// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import Foundation

@objcMembers
class TPScreen: NSObject {

	nonisolated(unsafe) private static var globalId: CGDirectDisplayID = 10000
	
    var id: CGDirectDisplayID
    var frame: NSRect = .zero

    init(id: CGDirectDisplayID, frame: NSRect) {
        self.id = id
        self.frame = frame
    }

    convenience init?(from string: String) {
        let parts = string.split(separator: "|")
		if parts.count == 1 {
			// Compatible with old format.
			self.init(id: Self.globalId, frame: NSRectFromString(String(parts[0])))
			Self.globalId += 1
		} else if parts.count == 2 {
			self.init(id: CGDirectDisplayID(parts[0])!, frame: NSRectFromString(String(parts[1])))
		} else {
			return nil
		}
    }

    convenience init(screen: NSScreen) {
        self.init(id: screen.id, frame: screen.frame)
    }

    override func isEqual(_ object: Any?) -> Bool {
        if let screen = object as? TPScreen {
			return self.frame == screen.frame
		} else if let screen = object as? NSScreen {
			return self.frame == screen.frame
		} else {
			return false
		}
    }

    override var description: String {
        return "Screen \(NSStringFromRect(self.frame))"
    }

    var stringRepresentation: String {
        "\(id)|\(NSStringFromRect(frame))"
    }

	/// Only for LocalHost.
    func toNSScreen() -> NSScreen? {
        NSScreen.screens.first { screen in screen.id == self.id }
    }

    static func screens(from string: String) -> [TPScreen] {
		string.components(separatedBy: ";").compactMap { string in TPScreen(from: string) }
    }
	
	static func string(from screens: [TPScreen]) -> String {
		screens.stringRepresentation
	}
}

extension Array where Element == TPScreen {
    var stringRepresentation: String {
        map { $0.stringRepresentation }.joined(separator: ";")
    }
}

extension Array where Element == NSScreen {
    func toTPScreens() -> [TPScreen] {
        self.map { screen in
            TPScreen(screen: screen)
        }
    }
}

extension NSScreen {
    var id: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            .flatMap { $0 as? NSNumber }
            .map { CGDirectDisplayID($0.uint32Value) }!
    }

    static var primaryScreenFrame: CGRect {
        screens.first(where: { $0.frame.origin == .zero })?.frame
            ?? screens.first?.frame
            ?? .zero
    }
}

