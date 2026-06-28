// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import Carbon

// MARK: - Debug Logging

#if DEBUG
private let DEBUG_EVENTTAP = true
#else
private let DEBUG_EVENTTAP = false
#endif

private func EventTapDebugLog(_ message: String) {
    if DEBUG_EVENTTAP {
        NSLog("[EventTap] %@", message)
    }
}

// MARK: - Constants

private let MAX_STRING = 20
// ESC_KEYCODE is defined in TPEventsController.swift

// External C functions
@_silgen_name("CGSCurrentEventTimestamp")
func CGSCurrentEventTimestamp() -> CGEventTimestamp

// Event type names for debugging
private let eventTypeName: [String] = [
    "NullEvent", "LMouseDown", "LMouseUp", "RMouseDown", "RMouseUp",
    "MouseMoved", "LMouseDragged", "RMouseDragged", "MouseEntered",
    "MouseExited", "KeyDown", "KeyUp", "FlagsChanged", "Kitdefined",
    "SysDefined", "AppDefined", "Timer", "CursorUpdate",
    "Journaling", "Suspend", "Resume", "Notification",
    "ScrollWheel", "TabletPointer", "TabletProximity",
    "OtherMouseDown", "OtherMouseUp", "OtherMouseDragged", "Zoom"
]

// MARK: - TPEventTapsController

@objc public class TPEventTapsController: TPEventsController {
    
    // MARK: - Properties
    
    private var eventPort: CFMachPort?
    private var eventSource: CGEventSource?
    
    // MARK: - Singleton
    
    private static var _sharedInstance: TPEventTapsController?
    
    @objc public override class func `default`() -> TPEventsController {
        if _sharedInstance == nil {
            _sharedInstance = TPEventTapsController()
        }
        return _sharedInstance!
    }
    
    // MARK: - Helper Methods
    
    @objc public class func _eventName(from type: CGEventType) -> String {
        let index = Int(type.rawValue)
        if index < eventTypeName.count {
            return eventTypeName[index]
        } else {
            return String(format: "Event Type 0x%x", type.rawValue)
        }
    }
    
    // MARK: - Getting Events
    
    @objc public override func _startGettingEventsOnScreen() {
        #if DISABLE_CONTROL
        return
        #endif
        
        if IsSecureEventInputEnabled() {
            DispatchQueue.main.async {
                TPMainController.shared().goFrontmost()
            }
        }
        
        MainActor.assumeIsolated {
            TPCursorVisibilityController.shared.beginControlSession(reason: "startGettingEvents")
        }

        if eventPort == nil {
            let runLoop = CFRunLoopGetCurrent()
            
            // Create event tap with callback
            let callbackContext = Unmanaged.passUnretained(self).toOpaque()
            
            eventPort = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(UInt64.max) & ~(UInt64(NX_KITDEFINEDMASK) | UInt64(NX_APPDEFINEDMASK)),
                callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                    guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                    let controller = Unmanaged<TPEventTapsController>.fromOpaque(refcon).takeUnretainedValue()
                    return controller.handleEventCallback(proxy: proxy, type: type, event: event)
                },
                userInfo: callbackContext
            )
            
            guard let eventPort = eventPort else {
                NSLog("Can't create event port")
                return
            }
            
            guard let eventSrc = CFMachPortCreateRunLoopSource(nil, eventPort, 0) else {
                NSLog("Can't create event src")
                return
            }
            
            CFRunLoopAddSource(runLoop, eventSrc, .defaultMode)
        } else {
            _startGettingEvents()
        }
    }
    
    private func handleEventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown || type == .flagsChanged {
            processEmergencyStopEvent(event)
        }
        
        // Check isControlling - use nonisolated(unsafe) approach
        let isControlling = MainActor.assumeIsolated {
            TPClientController.shared.isControlling
        }

        if isControlling {
            if type.rawValue >= CGEventType.tapDisabledByTimeout.rawValue {
                _startGettingEvents()
                EventTapDebugLog("eventCallback, _startGettingsEvents again on type=\(type.rawValue)")
            } else {
                _sendEvent(toListener: event)
            }

            MainActor.assumeIsolated {
                TPCursorVisibilityController.shared.handleEventTapTick(isControlling: true, eventType: type)
            }

            return nil
        } else {
            if type.rawValue >= CGEventType.tapDisabledByTimeout.rawValue {
                return nil
            }

            MainActor.assumeIsolated {
                TPCursorVisibilityController.shared.handleEventTapTick(isControlling: false, eventType: type)
            }

            return Unmanaged.passRetained(event)
        }
    }
    
    @objc public override func _sendEvent(toListener event: Any) {
        if let port = eventPort, CGEvent.tapIsEnabled(tap: port) {
            super._sendEvent(toListener: event)
        }
    }
    
    private func _startGettingEvents() {
        if let port = eventPort, !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }
    
    @objc public override func _stopGettingEvents() {
        if let port = eventPort, CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        
        DispatchQueue.main.async {
            TPMainController.shared().leaveFrontmost()
        }
    }
    
    @objc public override func cleanupGettingEvents() {
        super.cleanupGettingEvents()
        MainActor.assumeIsolated {
            TPCursorVisibilityController.shared.endControlSession(reason: "cleanupGettingEvents")
        }
    }
    
    private func processEmergencyStopEvent(_ event: CGEvent) {
        struct Static {
            static var emergencyStopEventCount = 0
        }
        
        if _isEmergencyStopEvent(event) {
            Static.emergencyStopEventCount += 1
            NSLog("emergency events: %d", Static.emergencyStopEventCount)
            
            if Static.emergencyStopEventCount >= 3 {
                NSLog("emergency stop key sequence detected, disconnecting.")
                eventsListener?.gotEmergencyStopEvent()
            }
            
            if Static.emergencyStopEventCount >= 10 {
                exit(-1)
            }
        } else {
            Static.emergencyStopEventCount = 0
        }
    }
    
    // MARK: - Posting Events
    
    @objc public override func startPostingEvents() {
        eventSource = CGEventSource(stateID: .combinedSessionState)
    }
    
    @objc public override func stopPostingEvents() {
        eventSource = nil
    }
    
    @objc public func _postEvent(_ event: CGEvent) {
        event.timestamp = CGSCurrentEventTimestamp()
        
        if let source = eventSource {
            event.setSource(source)
        }
        
        event.post(tap: .cgSessionEventTap)
    }
    
    // MARK: - Conversions
    
    @objc public override func _eventData(fromEvent e: Any) -> Data? {
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
    
    private func appendInteger(_ data: inout Data, event: CGEvent, field: CGEventField) {
        let value = event.getIntegerValueField(field)
        var swappedValue = value.bigEndian
        data.append(Data(bytes: &swappedValue, count: MemoryLayout<Int64>.size))
    }
    
    private func appendDouble(_ data: inout Data, event: CGEvent, field: CGEventField) {
        let value = event.getDoubleValueField(field)
        var swappedValue = NSSwapHostDoubleToBig(value)
        data.append(Data(bytes: &swappedValue, count: MemoryLayout<NSSwappedDouble>.size))
    }
    
    @objc public override func _postEvent(withEventData eventData: Data) {
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
            
            var mouseDelta = TPMouseDelta()
            mouseDelta.x = event!.getIntegerValueField(.mouseEventDeltaX)
            mouseDelta.y = event!.getIntegerValueField(.mouseEventDeltaY)
            
            _updateMouseLocation(with: mouseDelta)
            
            event?.location = currentMouseLocation
            
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
            
            _postEvent(event)
        }
    }
    
    private func readInteger(_ data: NSData, event: CGEvent, field: CGEventField, pos: inout Int) {
        var swappedValue: Int64 = 0
        data._readBytes(&swappedValue, size: MemoryLayout<Int64>.size, pos: &pos)
        let value = Int64(bigEndian: swappedValue)
        event.setIntegerValueField(field, value: value)
    }
    
    private func readDouble(_ data: NSData, event: CGEvent, field: CGEventField, pos: inout Int) {
        var swappedValue = NSSwappedDouble()
        data._readBytes(&swappedValue, size: MemoryLayout<NSSwappedDouble>.size, pos: &pos)
        let value = NSSwapBigDoubleToHost(swappedValue)
        event.setDoubleValueField(field, value: value)
    }
    
    // MARK: - Misc
    
    @objc public override func _shouldSkipFirstEvent(_ e: Any) -> Bool {
        // CGEvent is a CFType, use type ID comparison
        guard CFGetTypeID(e as CFTypeRef) == CGEvent.typeID else { return false }
        let event = e as! CGEvent
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }
    
    @objc public override func _nsEvent(fromEvent event: Any) -> NSEvent? {
        guard CFGetTypeID(event as CFTypeRef) == CGEvent.typeID else { return nil }
        let cgEvent = event as! CGEvent
        return NSEvent(cgEvent: cgEvent)
    }
    
    @objc public override func _isEmergencyStopEvent(_ e: Any) -> Bool {
        guard CFGetTypeID(e as CFTypeRef) == CGEvent.typeID else { return false }
        let event = e as! CGEvent
        
        if event.type != .keyDown {
            return false
        }
        
        let flags = event.flags
        if !flags.contains(.maskShift) {
            return false
        }
        if !flags.contains(.maskControl) {
            return false
        }
        if !flags.contains(.maskAlternate) {
            return false
        }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode != Int64(ESC_KEYCODE) {
            return false
        }
        
        return true
    }
    
    @objc public override func warpMouse(toPosition position: NSPoint) {
        super.warpMouse(toPosition: position)
        
        EventTapDebugLog("warp to \(NSStringFromPoint(position))")
        
        let sourceState: CGEventSourceStateID
        if let source = eventSource {
            sourceState = source.sourceStateID
        } else {
            sourceState = .combinedSessionState
        }
        
        var event: CGEvent?
        let cgPosition = CGPoint(x: position.x, y: position.y)
        
        if CGEventSource.buttonState(sourceState, button: .left) {
            event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: cgPosition, mouseButton: .left)
            event?.type = .leftMouseDragged
        } else if CGEventSource.buttonState(sourceState, button: .right) {
            event = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDragged, mouseCursorPosition: cgPosition, mouseButton: .right)
            event?.type = .rightMouseDragged
        } else if CGEventSource.buttonState(sourceState, button: .center) {
            event = CGEvent(mouseEventSource: eventSource, mouseType: .otherMouseDragged, mouseCursorPosition: cgPosition, mouseButton: .center)
            event?.type = .otherMouseDragged
        } else {
            event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: cgPosition, mouseButton: .left)
            event?.type = .mouseMoved
        }
        
        if let event = event {
            _postEvent(event)
        }
    }
    
    @objc public override func mouseDown(atPosition position: NSPoint) {
        super.mouseDown(atPosition: position)
        
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: currentMouseLocation, mouseButton: .left) {
            event.type = .leftMouseDown
            _postEvent(event)
        }
    }
    
    @objc public override func mouseUp(atPosition position: NSPoint) {
        super.mouseUp(atPosition: position)
        
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: currentMouseLocation, mouseButton: .left) {
            event.type = .leftMouseUp
            event.post(tap: .cgSessionEventTap)
        }
    }
    
    @objc public override func event(_ event: NSEvent?, hasRequiredKeyIfNeeded needed: Bool, withTag tag: NSEvent.EventType) -> Bool {
        guard let event = event, let source = eventSource else {
            return super.event(event, hasRequiredKeyIfNeeded: needed, withTag: tag)
        }
        
        if !needed {
            return true
        }
        
        let sourceState = source.sourceStateID
        let flags = CGEventSource.flagsState(sourceState)
        let keyMask = NSEvent.EventTypeMask(type: tag)
        return (flags.rawValue & keyMask.rawValue) != 0
    }
}
