// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Header length: sizeof(MsgType) + sizeof(DataLength) = 4 + 8 = 12 bytes
let MessageHeaderLength: UInt = UInt(MemoryLayout<Int>.size + MemoryLayout<UInt64>.size)

class Message: NSObject {
    
    // MARK: - Private Properties
    
	private var _msgType: MsgType
    private var _dataLength: UInt64 = 0
    private var _additionalData: Data?
    
    // MARK: - Initialization
    
	init(type: MsgType) {
		_msgType = type
        _additionalData = nil
		
		super.init()
    }
    
    convenience init?(rawData: Data) {
        var pos = 0
        
        do {
            // Read message type (4 bytes, big endian)
            guard rawData.count >= pos + MemoryLayout<Int64>.size else { return nil }
            let msgTypeInt = rawData.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: pos, as: Int64.self)
            }
			guard let msgType = MsgType(rawValue: Int(msgTypeInt.bigEndian)) else { return nil }
			self.init(type: msgType)
			
            pos += MemoryLayout<Int>.size
            
            // Read data length (8 bytes, big endian)
            guard rawData.count >= pos + MemoryLayout<UInt64>.size else { return nil }
			_dataLength = rawData.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: pos, as: UInt64.self)
			}.bigEndian
			
            pos += MemoryLayout<UInt64>.size
            
            if _dataLength > 0 {
                guard UInt64(rawData.count - pos) >= _dataLength else {
                    // Not enough data!
                    return nil
                }
                _additionalData = rawData.subdata(in: pos..<(pos + Int(_dataLength)))
            } else {
                _additionalData = nil
            }
        }
    }
    
    // MARK: - Private Initializers
    
    private convenience init(type: MsgType, data: Data) {
        self.init(type: type)
        _additionalData = data
    }
    
    private convenience init(type: MsgType, string: String) {
        self.init(type: type)
        _additionalData = string.data(using: .utf8)
    }
    
    private convenience init(type: MsgType, infoDict: [AnyHashable: Any]) {
        self.init(type: type)
		_additionalData = NSArchiver.archivedData(withRootObject: infoDict)
    }
    
    // MARK: - Factory Methods
    
    static func create(with type: MsgType) -> Message {
        return Message(type: type)
    }
    
    static func create(with type: MsgType, andData data: Data) -> Message {
        return Message(type: type, data: data)
    }
    
    static func create(with type: MsgType, andString string: String) -> Message {
        return Message(type: type, string: string)
    }
    
    static func create(with type: MsgType, andInfoDict infoDict: [AnyHashable: Any]) -> Message {
        return Message(type: type, infoDict: infoDict)
    }
    
    // MARK: - Accessors
    
    var rawData: Data {
        var rawData = Data()
        
		var msgTypeInt = _msgType.rawValue.bigEndian
		rawData.append(Data(bytes: &msgTypeInt, count: MemoryLayout<Int64>.size))
        
        // Write data length and optional data
        if let additionalData = _additionalData {
            var dataLength = UInt64(additionalData.count).bigEndian
            rawData.append(Data(bytes: &dataLength, count: MemoryLayout<UInt64>.size))
            rawData.append(additionalData)
        } else {
            var dataLength = UInt64(0).bigEndian
            rawData.append(Data(bytes: &dataLength, count: MemoryLayout<UInt64>.size))
        }
        
        return rawData
    }
    
    var msgType: MsgType {
        return _msgType
    }
    
    var msgLength: UInt64 {
        return dataLength + UInt64(MessageHeaderLength)
    }
    
    var dataLength: UInt64 {
        return _dataLength
    }
    
    var data: Data? {
        return _additionalData
    }
    
    var string: String {
        guard let data = _additionalData else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    var infoDict: [AnyHashable: Any] {
        guard let data = _additionalData else { return [:] }
        if msgType == .layoutUpdate || msgType == .event {
            return [:]
        }
        if let obj = NSUnarchiver.unarchiveObject(with: data) as? [AnyHashable: Any] {
            return obj
        }
        return [:]
    }
    
    // MARK: - Description
    
    override var description: String {
        return "\(super.description) type=\(_msgType) data length=\(_additionalData?.count ?? 0)"
    }
    
    /// Returns a debug-friendly description including message type name and readable infoDict keys
    var debugInfo: String {
        var parts = ["type=\(msgType.displayName)"]
        
        if dataLength > 0 {
            // Try to extract readable info from infoDict
            if let data = _additionalData,
               let dict = try? NSUnarchiver.unarchiveObject(with: data) as? [AnyHashable: Any] {
                let readableKeys = dict.keys.compactMap { key -> String? in
                    guard let strKey = key as? String else { return nil }
                    // Filter out binary data keys and format values
                    if let value = dict[key] {
                        if value is NSData {
                            return "\(strKey)=(data)"
                        } else if let strValue = value as? String {
                            return "\(strKey)=\"\(strValue.prefix(50))\""
                        } else if let numValue = value as? NSNumber {
                            return "\(strKey)=\(numValue)"
                        } else if let dictValue = value as? [String: Any] {
                            return "\(strKey)={\(dictValue.keys.joined(separator: ","))}"
                        } else {
                            return "\(strKey)=\(type(of: value))"
                        }
                    }
                    return nil
                }
                if !readableKeys.isEmpty {
                    parts.append("info=[\(readableKeys.joined(separator: ", "))]")
                }
            } else {
                parts.append("dataLen=\(dataLength)")
            }
        }
        
        return parts.joined(separator: " ")
    }
}

// MARK: - MsgType Display Name Extension

extension MsgType {
    /// Returns a human-readable name for the message type
    var displayName: String {
        switch self {
        case .identification: return "Identification"
        case .authenticationRequest: return "AuthRequest"
        case .authenticationInProgress: return "AuthInProgress"
        case .authenticationAbort: return "AuthAbort"
        case .authenticationSuccess: return "AuthSuccess"
        case .authenticationFailure: return "AuthFailure"
        case .controlRequest: return "CtrlRequest"
        case .controlSuccess: return "CtrlSuccess"
        case .controlFailure: return "CtrlFailure"
        case .controlStop: return "CtrlStop"
        case .controlWake: return "CtrlWake"
        case .controlScreenSleep: return "CtrlScreenSleep"
        case .controlDeviceSleep: return "CtrlDeviceSleep"
        case .controlLock: return "CtrlLock"
        case .event: return "Event"
        case .transferRequest: return "TransferReq"
        case .transferSuccess: return "TransferSuccess"
        case .transferFailure: return "TransferFailure"
        case .layoutUpdate: return "LayoutUpdate"
        case .unpairNotification: return "UnpairNotification"
        case .disconnectNotification: return "DisconnectNotification"
        case .audioSyncStartRequest: return "AudioSyncStartRequest"
        case .audioSyncStartSuccess: return "AudioSyncStartSuccess"
        case .audioSyncStopNotification: return "AudioSyncStopNotification"
        case .audioMicRouteUpdate: return "AudioMicRouteUpdate"
        case .audioOutputRouteUpdate: return "AudioOutputRouteUpdate"
        case .audioHardwareStatusUpdate: return "AudioHardwareStatusUpdate"
        }
    }
}
