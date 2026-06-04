// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

extension NSCoder {

    func decodeData(forKey key: String) -> Data? {
        var length: Int = 0
		if let bytes = decodeBytes(forKey: key, returnedLength: &length) {
			return Data(bytes: bytes, count: length)
		} else {
			return nil
		}
    }

}
