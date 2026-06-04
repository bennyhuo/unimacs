// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import CoreGraphics

/// Check if the event type is a mouse movement event
private func isMouseEventType(_ eventType: CGEventType) -> Bool {
    return eventType == .mouseMoved ||
           eventType == .leftMouseDragged ||
           eventType == .rightMouseDragged ||
           eventType == .otherMouseDragged
}

class TPDirectEventTapsController: TPEventTapsController {
    
    private static var _sharedInstance: TPDirectEventTapsController?
    
    @objc override class func `default`() -> TPEventsController {
        if _sharedInstance == nil {
            _sharedInstance = TPDirectEventTapsController()
        }
        return _sharedInstance!
    }
    
    @objc override func _eventData(fromEvent event: Any!) -> Data! {
        guard let event = event else {
            return nil
        }
        
        // event is passed as AnyObject, need to cast to CGEvent via Unmanaged
        let cgEvent = unsafeBitCast(event as AnyObject, to: CGEvent.self)
        
        // Convert CGEvent to Data using CGEventCreateData
        return cgEvent.data as Data?
    }
    
    @objc override func _postEvent(withEventData eventData: Data!) {
        guard let eventData = eventData, eventData.count > 0 else {
            return
        }
        
        guard let event = CGEvent(withDataAllocator: nil, data: eventData as CFData) else {
            return
        }
        
        let eventType = event.type
        
        // DebugLog("post event \(TPEventTapsController._eventName(from: eventType))")
        
        if isMouseEventType(eventType) {
            let deltaX = event.getIntegerValueField(.mouseEventDeltaX)
            let deltaY = event.getIntegerValueField(.mouseEventDeltaY)
            
            if deltaX != 0 || deltaY != 0 {
                let mouseDelta = TPMouseDelta(x: deltaX, y: deltaY)
                _updateMouseLocation(with: mouseDelta)
                
                // DebugLog("mouseDelta=\(mouseDelta.x) \(mouseDelta.y) mouseLocation=\(_currentMouseLocation.x) \(_currentMouseLocation.y)")
            }
        }
        
        event.location = currentMouseLocation
        
        _postEvent(event)
    }
}
