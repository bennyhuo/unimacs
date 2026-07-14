// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import Carbon
import CoreGraphics

private let MAX_STRING = 20

enum CGEventSerializer {
    
    static func serialize(_ e: Any, mode: TPSerializationMode) -> Data? {
        switch mode {
        case .direct:
            // CGEvent is a CFType, use type ID comparison
            guard CFGetTypeID(e as CFTypeRef) == CGEvent.typeID else { return nil }
            let cgEvent = e as! CGEvent
            return cgEvent.data as Data?
            
        case .legacy:
            // CGEvent is a CFType, use type ID comparison
            guard CFGetTypeID(e as CFTypeRef) == CGEvent.typeID else { return nil }
            let event = e as! CGEvent
            
            var eventData = Data()
            
            let eventType = event.type
            var swappedEventType = eventType.rawValue.bigEndian
            eventData.append(Data(bytes: &swappedEventType, count: MemoryLayout<UInt32>.size))
            
            switch eventType {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                appendInteger(&eventData, event: event, field: .mouseEventNumber)
                appendInteger(&eventData, event: event, field: .mouseEventDeltaX)
                appendInteger(&eventData, event: event, field: .mouseEventDeltaY)
                appendInteger(&eventData, event: event, field: .mouseEventButtonNumber)
                
            case .scrollWheel:
                appendInteger(&eventData, event: event, field: .scrollWheelEventDeltaAxis1)
                appendInteger(&eventData, event: event, field: .scrollWheelEventDeltaAxis2)
                appendInteger(&eventData, event: event, field: .scrollWheelEventDeltaAxis3)
                appendInteger(&eventData, event: event, field: .scrollWheelEventScrollPhase)
                appendInteger(&eventData, event: event, field: .scrollWheelEventIsContinuous)
                appendDouble(&eventData, event: event, field: .scrollWheelEventFixedPtDeltaAxis1)
                appendDouble(&eventData, event: event, field: .scrollWheelEventFixedPtDeltaAxis2)
                appendDouble(&eventData, event: event, field: .scrollWheelEventFixedPtDeltaAxis3)
                appendDouble(&eventData, event: event, field: .scrollWheelEventPointDeltaAxis1)
                appendDouble(&eventData, event: event, field: .scrollWheelEventPointDeltaAxis2)
                appendDouble(&eventData, event: event, field: .scrollWheelEventPointDeltaAxis3)
                
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
                appendInteger(&eventData, event: event, field: .mouseEventNumber)
                appendInteger(&eventData, event: event, field: .mouseEventButtonNumber)
                appendInteger(&eventData, event: event, field: .mouseEventClickState)
                appendInteger(&eventData, event: event, field: .mouseEventInstantMouser)
                appendInteger(&eventData, event: event, field: .mouseEventSubtype)
                appendDouble(&eventData, event: event, field: .mouseEventPressure)
                
            case .keyUp, .keyDown:
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                var swappedKeyCode = keyCode.bigEndian
                eventData.append(Data(bytes: &swappedKeyCode, count: MemoryLayout<UInt16>.size))
                
                appendInteger(&eventData, event: event, field: .keyboardEventKeyboardType)
                
                var string = [UniChar](repeating: 0, count: MAX_STRING)
                var length: Int = 0
                event.keyboardGetUnicodeString(maxStringLength: MAX_STRING, actualStringLength: &length, unicodeString: &string)
                
                var swappedLength = UInt32(length).bigEndian
                eventData.append(Data(bytes: &swappedLength, count: MemoryLayout<UInt32>.size))
                
                for i in 0..<length {
                    var swappedC = string[i].bigEndian
                    eventData.append(Data(bytes: &swappedC, count: MemoryLayout<UniChar>.size))
                }
                
            default:
                break
            }
            
            let flags = event.flags.rawValue
            var swappedFlags = flags.bigEndian
            eventData.append(Data(bytes: &swappedFlags, count: MemoryLayout<UInt64>.size))
            
            return eventData
        }
    }
    
    static func deserialize(
        _ eventData: Data,
        mode: TPSerializationMode,
        eventSource: CGEventSource?,
        currentMouseLocation: CGPoint
    ) -> CGEvent? {
        guard eventData.count > 0 else { return nil }
        
        switch mode {
        case .direct:
            return CGEvent(withDataAllocator: nil, data: eventData as CFData)
            
        case .legacy:
            let nsEventData = eventData as NSData
            var pos: Int = 0
            var down = false
            
            var event: CGEvent?
            
            var swappedEventType: UInt32 = 0
            nsEventData._readBytes(&swappedEventType, size: MemoryLayout<UInt32>.size, pos: &pos)
            let eventType = CGEventType(rawValue: UInt32(bigEndian: swappedEventType))!
            
            switch eventType {
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
                event = CGEvent(mouseEventSource: eventSource, mouseType: eventType, mouseCursorPosition: currentMouseLocation, mouseButton: .left)
                event?.type = eventType
                
                readInteger(nsEventData, event: event!, field: .mouseEventNumber, pos: &pos)
                readInteger(nsEventData, event: event!, field: .mouseEventButtonNumber, pos: &pos)
                readInteger(nsEventData, event: event!, field: .mouseEventClickState, pos: &pos)
                readInteger(nsEventData, event: event!, field: .mouseEventInstantMouser, pos: &pos)
                readInteger(nsEventData, event: event!, field: .mouseEventSubtype, pos: &pos)
                readDouble(nsEventData, event: event!, field: .mouseEventPressure, pos: &pos)
                
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                event = CGEvent(mouseEventSource: eventSource, mouseType: eventType, mouseCursorPosition: currentMouseLocation, mouseButton: .left)
                event?.type = eventType
                
                readInteger(nsEventData, event: event!, field: .mouseEventNumber, pos: &pos)
                readInteger(nsEventData, event: event!, field: .mouseEventDeltaX, pos: &pos)
                readInteger(nsEventData, event: event!, field: .mouseEventDeltaY, pos: &pos)
                readInteger(nsEventData, event: event!, field: .mouseEventButtonNumber, pos: &pos)
                
            case .scrollWheel:
                event = CGEvent(source: eventSource)
                event?.type = eventType
                
                readInteger(nsEventData, event: event!, field: .scrollWheelEventDeltaAxis1, pos: &pos)
                readInteger(nsEventData, event: event!, field: .scrollWheelEventDeltaAxis2, pos: &pos)
                readInteger(nsEventData, event: event!, field: .scrollWheelEventDeltaAxis3, pos: &pos)
                readInteger(nsEventData, event: event!, field: .scrollWheelEventScrollPhase, pos: &pos)
                readInteger(nsEventData, event: event!, field: .scrollWheelEventIsContinuous, pos: &pos)
                readDouble(nsEventData, event: event!, field: .scrollWheelEventFixedPtDeltaAxis1, pos: &pos)
                readDouble(nsEventData, event: event!, field: .scrollWheelEventFixedPtDeltaAxis2, pos: &pos)
                readDouble(nsEventData, event: event!, field: .scrollWheelEventFixedPtDeltaAxis3, pos: &pos)
                readDouble(nsEventData, event: event!, field: .scrollWheelEventPointDeltaAxis1, pos: &pos)
                readDouble(nsEventData, event: event!, field: .scrollWheelEventPointDeltaAxis2, pos: &pos)
                readDouble(nsEventData, event: event!, field: .scrollWheelEventPointDeltaAxis3, pos: &pos)
                
            case .keyDown:
                down = true
                fallthrough
            case .keyUp:
                var swappedKeyCode: UInt16 = 0
                nsEventData._readBytes(&swappedKeyCode, size: MemoryLayout<UInt16>.size, pos: &pos)
                let keyCode = UInt16(bigEndian: swappedKeyCode)
                
                event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: down)
                event?.type = eventType
                
                readInteger(nsEventData, event: event!, field: .keyboardEventKeyboardType, pos: &pos)
                
                var swappedLength: UInt32 = 0
                nsEventData._readBytes(&swappedLength, size: MemoryLayout<UInt32>.size, pos: &pos)
                let length = Int(UInt32(bigEndian: swappedLength))
                
                var string = [UniChar](repeating: 0, count: MAX_STRING)
                for i in 0..<length {
                    var swappedC: UniChar = 0
                    nsEventData._readBytes(&swappedC, size: MemoryLayout<UniChar>.size, pos: &pos)
                    string[i] = UniChar(bigEndian: swappedC)
                }
                
            case .flagsChanged:
                event = CGEvent(source: eventSource)
                event?.type = eventType
                
            default:
                break
            }
            
            if let event = event {
                var swappedFlags: UInt64 = 0
                nsEventData._readBytes(&swappedFlags, size: MemoryLayout<UInt64>.size, pos: &pos)
                let flags = UInt64(bigEndian: swappedFlags)
                
                event.flags = CGEventFlags(rawValue: flags)
            }
            
            return event
        }
    }
    
    // MARK: - Legacy Helpers
    
    private static func appendInteger(_ data: inout Data, event: CGEvent, field: CGEventField) {
        let value = event.getIntegerValueField(field)
        var swappedValue = value.bigEndian
        data.append(Data(bytes: &swappedValue, count: MemoryLayout<Int64>.size))
    }
    
    private static func appendDouble(_ data: inout Data, event: CGEvent, field: CGEventField) {
        let value = event.getDoubleValueField(field)
        var swappedValue = NSSwapHostDoubleToBig(value)
        data.append(Data(bytes: &swappedValue, count: MemoryLayout<NSSwappedDouble>.size))
    }
    
    private static func readInteger(_ data: NSData, event: CGEvent, field: CGEventField, pos: inout Int) {
        var swappedValue: Int64 = 0
        data._readBytes(&swappedValue, size: MemoryLayout<Int64>.size, pos: &pos)
        let value = Int64(bigEndian: swappedValue)
        event.setIntegerValueField(field, value: value)
    }
    
    private static func readDouble(_ data: NSData, event: CGEvent, field: CGEventField, pos: inout Int) {
        var swappedValue = NSSwappedDouble()
        data._readBytes(&swappedValue, size: MemoryLayout<NSSwappedDouble>.size, pos: &pos)
        let value = NSSwapBigDoubleToHost(swappedValue)
        event.setDoubleValueField(field, value: value)
    }
}
