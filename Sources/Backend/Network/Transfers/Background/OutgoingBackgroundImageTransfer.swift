// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

class OutgoingBackgroundImageTransfer: TPOutgoingTransfer {
    
    override var type: String {
        return "IncomingBackgroundImageTransfer"
    }
    
	override func dataToTransfer() -> Data? {
        if ENABLE_BACKGROUND_IMAGE_TRANSFER {
			let payload = BackgroundImageTransferPayload(
				identifier: LocalHost.shared.identifier,
				backgroundImageData: LocalHost.shared.backgroundImageData
			)

			return LegacyKeyedArchiver.archive(value: payload.archiveDictionary())
        } else {
            return nil
        }
    }
}