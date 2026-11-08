// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

extension NSData {
    
    @objc func _readBytes(_ bytes: UnsafeMutableRawPointer, size: Int, pos: UnsafeMutablePointer<Int>) {
        getBytes(bytes, range: NSRange(location: pos.pointee, length: size))
        pos.pointee += size
    }
    
    // MARK: - Rectangle
    
    static func data(with rect: NSRect) -> NSData {
        let data = NSMutableData()
        data.append(self.data(with: rect.origin) as Data)
        data.append(self.data(with: rect.size) as Data)
        return data
    }
    
    var rectValue: NSRect {
        var pos = 0
        var originX = NSSwappedFloat(), originY = NSSwappedFloat()
        var sizeWidth = NSSwappedFloat(), sizeHeight = NSSwappedFloat()
        
        _readBytes(&originX, size: MemoryLayout<NSSwappedFloat>.size, pos: &pos)
        _readBytes(&originY, size: MemoryLayout<NSSwappedFloat>.size, pos: &pos)
        _readBytes(&sizeWidth, size: MemoryLayout<NSSwappedFloat>.size, pos: &pos)
        _readBytes(&sizeHeight, size: MemoryLayout<NSSwappedFloat>.size, pos: &pos)
        
        return NSRect(
            x: CGFloat(NSSwapBigFloatToHost(originX)),
            y: CGFloat(NSSwapBigFloatToHost(originY)),
            width: CGFloat(NSSwapBigFloatToHost(sizeWidth)),
            height: CGFloat(NSSwapBigFloatToHost(sizeHeight))
        )
    }
    
    // MARK: - Point
    
    static func data(with point: NSPoint) -> NSData {
        let data = NSMutableData()
        var x = NSSwapHostFloatToBig(Float(point.x))
        var y = NSSwapHostFloatToBig(Float(point.y))
        
        data.append(Data(bytes: &x, count: MemoryLayout<NSSwappedFloat>.size))
        data.append(Data(bytes: &y, count: MemoryLayout<NSSwappedFloat>.size))
        
        return data
    }

    @objc var pointValue: NSPoint {
        var pos = 0
        var x = NSSwappedFloat()
        var y = NSSwappedFloat()
        
        _readBytes(&x, size: MemoryLayout<NSSwappedFloat>.size, pos: &pos)
        _readBytes(&y, size: MemoryLayout<NSSwappedFloat>.size, pos: &pos)
        
        return NSPoint(
            x: CGFloat(NSSwapBigFloatToHost(x)),
            y: CGFloat(NSSwapBigFloatToHost(y))
        )
    }
    
    // MARK: - Size
    
    @objc static func data(with size: NSSize) -> NSData {
        let data = NSMutableData()
        var width = NSSwapHostFloatToBig(Float(size.width))
        var height = NSSwapHostFloatToBig(Float(size.height))
        
        data.append(Data(bytes: &width, count: MemoryLayout<NSSwappedFloat>.size))
        data.append(Data(bytes: &height, count: MemoryLayout<NSSwappedFloat>.size))
        
        return data
    }
    
    @objc var sizeValue: NSSize {
        var pos = 0
        var width = NSSwappedFloat()
        var height = NSSwappedFloat()
        
        _readBytes(&width, size: MemoryLayout<NSSwappedFloat>.size, pos: &pos)
        _readBytes(&height, size: MemoryLayout<NSSwappedFloat>.size, pos: &pos)
        
        return NSSize(
            width: CGFloat(NSSwapBigFloatToHost(width)),
            height: CGFloat(NSSwapBigFloatToHost(height))
        )
    }
    
    // MARK: - String
    
    static func data(with string: String) -> NSData {
        return (string.data(using: .utf8) ?? Data()) as NSData
    }
    
    var stringValue: String {
        return String(data: self as Data, encoding: .utf8) ?? ""
    }
    
    // MARK: - Int32
    
    static func data(with intValue: Int32) -> NSData {
        return data(with: String(intValue))
    }
    
    var intValue: Int32 {
        return Int32(stringValue) ?? 0
    }
    
    // MARK: - Bool
    
    static func data(with boolValue: Bool) -> NSData {
        return data(with: boolValue ? "true" : "false")
    }
    
    var boolValue: Bool {
        return stringValue.lowercased() == "true"
    }
}
