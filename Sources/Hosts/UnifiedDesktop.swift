// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

@objcMembers
class UnifiedScreen: NSObject, Codable {
    var ownerHostId: String
    var screenIndex: Int
    var frame: NSRect
    var isMain: Bool
    
    init(ownerHostId: String, screenIndex: Int, frame: NSRect, isMain: Bool) {
        self.ownerHostId = ownerHostId
        self.screenIndex = screenIndex
        self.frame = frame
        self.isMain = isMain
        super.init()
    }
    
    override var description: String {
        return "UnifiedScreen(owner=\(ownerHostId), idx=\(screenIndex), frame=\(NSStringFromRect(frame)), isMain=\(isMain))"
    }
}

@objcMembers
class UnifiedDesktop: NSObject, Codable {
    var version: UInt64
    var screens: [UnifiedScreen]
    
    init(version: UInt64, screens: [UnifiedScreen]) {
        self.version = version
        self.screens = screens
        super.init()
    }
    
    override var description: String {
        return "UnifiedDesktop(version=\(version), screens=\(screens))"
    }
    
    /// Serialize the desktop layout to Data
    func toData() -> Data? {
        do {
            return try JSONEncoder().encode(self)
        } catch {
            NSLog("UnifiedDesktop: Failed to encode desktop: \(error)")
            return nil
        }
    }
    
    /// Deserialize the desktop layout from Data
    static func from(data: Data) -> UnifiedDesktop? {
        do {
            return try JSONDecoder().decode(UnifiedDesktop.self, from: data)
        } catch {
            NSLog("UnifiedDesktop: Failed to decode desktop: \(error)")
            return nil
        }
    }
}
