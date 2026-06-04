// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

class TPOutgoingBackgroundImageTransfer: TPOutgoingTransfer {
    
    override var type: String {
        return "TPIncomingBackgroundImageTransfer"
    }
    
	override func dataToTransfer() -> Data? {
        if ENABLE_BACKGROUND_IMAGE_TRANSFER {
			let payload = TPBackgroundImageTransferPayload(
				identifier: TPLocalHost.shared.identifier,
				backgroundImageData: TPLocalHost.shared.backgroundImageData
			)

			return LegacyKeyedArchiver.archive(value: payload.archiveDictionary())
        } else {
            return nil
        }
    }
}