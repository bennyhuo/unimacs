// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

class TPIncomingPasteboardTransfer: TPIncomingTransfer {
    private var _pasteboardName: String?

	override var priority: TPTransferPriority {
		return .high
    }

	override var hasFeedback: Bool {
        return true
    }

	override var completionMessage: String {
        let sizeString = String.sizeString(for: UInt64(_totalDataLength))
        return String(format: NSLocalizedString("Pasteboard received (%@)", comment: ""), sizeString)
    }

	override var errorMessage: String {
        return NSLocalizedString("Pasteboard failed to receive", comment: "")
    }

    override func prepareToReceiveData(withInfoDict infoDict: [AnyHashable : Any], from host: TPRemoteHost, onPort port: inout Int32, delegate: Any) -> Bool {
        _pasteboardName = infoDict[TPPasteboardTransferNameKey] as? String
		return super.prepareToReceiveData(withInfoDict: infoDict, from: host, onPort: &port, delegate: delegate)
    }

    override func _receiverDataTransferCompleted() {
        guard let data = _data,
			  let dictionary = LegacyKeyedArchiver.unarchive(data: data as Data) as? [String: Data] ,
              let pboardName = _pasteboardName else {
            super._receiverDataTransferCompleted()
            return
        }
        
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(pboardName))
        let typesStrings = Array(dictionary.keys)
        let types = typesStrings.map { NSPasteboard.PasteboardType($0) }

		let markerType = NSPasteboard.PasteboardType(Bundle.main.bundleIdentifier ?? "teleport")
		var declaredTypes = types
		declaredTypes.append(markerType)

        pasteboard.declareTypes(declaredTypes, owner: nil)
        
        for typeString in typesStrings {
            var data = dictionary[typeString]
            
            if let currentData = data, TPTypeNeedsSwapping(typeString) {
                if let string = String(data: currentData, encoding: .utf16BigEndian) {
					if let newData = string.data(using: String.Encoding.utf16LittleEndian) {
                        data = newData
                    }
                }
            }
            
            if let finalData = data, !finalData.isEmpty {
                pasteboard.setData(finalData, forType: NSPasteboard.PasteboardType(typeString))
            }
        }

		// Marker so `PasteboardMonitor` can ignore changes applied by teleport itself.
		pasteboard.setData(Data([1]), forType: markerType)
        
        super._receiverDataTransferCompleted()
    }
}
