// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

let BackgroundImageTransferIdentifierKey = "BackgroundImageTransferIdentifier"
let BackgroundImageTransferDataKey = "BackgroundImageTransferData"

let ENABLE_BACKGROUND_IMAGE_TRANSFER = true

struct BackgroundImageTransferPayload {
	let identifier: String
	let backgroundImageData: Data?

	func archiveDictionary() -> [String: Any?] {
		return [
			BackgroundImageTransferIdentifierKey: identifier,
			BackgroundImageTransferDataKey: backgroundImageData
		]
	}

	static func decode(fromArchiveObject object: Any?) -> BackgroundImageTransferPayload? {
		guard let dict = object as? [String: Any],
			  let identifier = dict[BackgroundImageTransferIdentifierKey] as? String else {
			return nil
		}

		let data = dict[BackgroundImageTransferDataKey] as? Data
		return BackgroundImageTransferPayload(identifier: identifier, backgroundImageData: data)
	}
}
