// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

class TPOutgoingPasteboardTransfer: TPOutgoingTransfer {
    private var _pasteboardName: String
    private var _maxSize: UInt64 = 0

	required init() {
        _pasteboardName = NSPasteboard.Name.general.rawValue
        super.init()
    }

    override var type: String {
        return "TPIncomingPasteboardTransfer"
    }

    func setPasteboardName(_ pasteboardName: String) {
        _pasteboardName = pasteboardName
    }

    func setMaxSize(_ maxSize: UInt64) {
        _maxSize = maxSize
    }

	override var shouldBeEncrypted: Bool {
        return true
    }

	var requireTrustedHost: Bool {
        return true
    }

	override var priority: TPTransferPriority {
		return .high
    }

	override var hasFeedback: Bool {
        return true
    }

	override var completionMessage: String {
		let sizeString = String.sizeString(for: UInt64(self.totalDataLength()))
        return String(format: NSLocalizedString("Pasteboard sent (%@)", comment: ""), sizeString)
    }

	override var errorMessage: String {
        return NSLocalizedString("Pasteboard not sent", comment: "")
    }

	override func infoDict() -> [AnyHashable : Any] {
        var infoDict = super.infoDict()
        
        infoDict[TPPasteboardTransferNameKey] = _pasteboardName
		infoDict[TPPasteboardTransferChangeCountKey] = NSNumber(value: NSPasteboard(name: NSPasteboard.Name(_pasteboardName)).changeCount)
        
        return infoDict
    }

	override func dataToTransfer() -> Data? {
        var dictionary = [String: Data]()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(_pasteboardName))
        let pasteboardTypes = pasteboard.types ?? []
        
        var pasteboardSize: UInt64 = 0
        for type in pasteboardTypes {
            let typeString = type.rawValue
            if TPTypeNeedsIgnoring(typeString) {
                continue
            }
            
            if var data = pasteboard.data(forType: type) {
                if TPTypeNeedsSwapping(typeString) {
                    if let string = String(data: data, encoding: .utf16LittleEndian) {
                        if let newData = string.data(using: .utf16BigEndian) {
                            data = newData
                        }
                    }
                }
                
                if !data.isEmpty {
                    dictionary[typeString] = data
                    pasteboardSize += UInt64(data.count)
                }
            }
        }
        
        if pasteboardSize == 0 {
            return nil
        } else if _maxSize > 0 && pasteboardSize > _maxSize {
            return nil
        }
        
        return try? NSKeyedArchiver.archivedData(withRootObject: dictionary, requiringSecureCoding: false)
    }

    var generationCount: CFIndex {
        return 0
    }
}
