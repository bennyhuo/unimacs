// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

class IncomingBackgroundImageTransfer: IncomingTransfer {
    
    override func _receiverDataTransferCompleted() {
        TransferDebugLog("_receiverDataTransferCompleted \(self) on thread \(Thread.current)")
        
        guard let data = _data else {
			super._receiverDataTransferCompleted()
			return
		}

		let payload = BackgroundImageTransferPayload.decode(
			fromArchiveObject: LegacyKeyedArchiver.unarchive(data: data as Data)
		)

		if let payload = payload {
			let host = HostDevicesManager.shared.host(withIdentifier: payload.identifier)
			if let host = host, let backgroundImageData = payload.backgroundImageData {
				let backgroundImage = NSImage(data: backgroundImageData)
				host.setBackgroundImage(backgroundImage)
			}
		}
        
        super._receiverDataTransferCompleted()
    }
}
