// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

let TPBackgroundImageTransferIdentifierKey = "TPBackgroundImageTransferIdentifier"
let TPBackgroundImageTransferDataKey = "TPBackgroundImageTransferData"

let ENABLE_BACKGROUND_IMAGE_TRANSFER = true

struct TPBackgroundImageTransferPayload {
	let identifier: String
	let backgroundImageData: Data?

	func archiveDictionary() -> [String: Any?] {
		return [
			TPBackgroundImageTransferIdentifierKey: identifier,
			TPBackgroundImageTransferDataKey: backgroundImageData
		]
	}

	static func decode(fromArchiveObject object: Any?) -> TPBackgroundImageTransferPayload? {
		guard let dict = object as? [String: Any],
			  let identifier = dict[TPBackgroundImageTransferIdentifierKey] as? String else {
			return nil
		}

		let data = dict[TPBackgroundImageTransferDataKey] as? Data
		return TPBackgroundImageTransferPayload(identifier: identifier, backgroundImageData: data)
	}
}
