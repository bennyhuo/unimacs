// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

extension String {
    
    private static let kilo: UInt64 = 1024
    private static let mega: UInt64 = kilo * kilo
    private static let giga: UInt64 = kilo * mega
    
    static func sizeString(for size: UInt64) -> String {
        guard size != 0 else {
            return NSLocalizedString("zero", comment: "")
        }
        
        let (unit, unitString): (UInt64, String)
        switch size {
        case giga...:
            unit = giga
            unitString = "G"
        case mega...:
            unit = mega
            unitString = "M"
        case kilo...:
            unit = kilo
            unitString = "K"
        default:
            return NSLocalizedString("< 1K", comment: "")
        }
        
        let value = (10.0 * Double(size)) / Double(unit) / 10.0
        return String(format: NSLocalizedString("%.1f\(unitString)", comment: ""), value)
    }
	
	var boolValue: Bool {
		let lowercased = self.lowercased()
		return lowercased == "yes" || lowercased == "true" || lowercased == "1"
	}
}
