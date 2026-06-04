// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

class LegacyKeyedArchiver {
	static func unarchive(data: Data) -> Any? {
		do {
			// 1. Create the unarchiver instance
			let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
			
			// 2. Disable secure coding (this allows legacy behavior)
			unarchiver.requiresSecureCoding = false
			
			// 3. Decode the root object
			let decodedObject = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
			
			// 4. Finish decoding
			unarchiver.finishDecoding()
			
			return decodedObject
		} catch {
			debugLog("Unarchiving failed: \(error)")
			return nil
		}
	}
	
	static func archive(value: Any) -> Data? {
		try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: false)
	}
}
