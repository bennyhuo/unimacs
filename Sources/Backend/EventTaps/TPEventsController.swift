// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

// MARK: - Constants

let ESC_KEYCODE: Int = 53
let DISABLE_CONTROL = false

// MARK: - TPEventsListener Protocol

public protocol TPEventsListener: NSObjectProtocol {
    func gotEvent(withEventData eventData: Data)
    func gotEmergencyStopEvent()
    func shouldStop(with event: NSEvent) -> Bool
}

// MARK: - TPEventsController

open class TPEventsController: NSObject {
    
    // MARK: - Properties
    
    public private(set) var eventsListener: TPEventsListener?
    
    public var currentScreenIndex: Int = 0
    public var currentMouseLocation: CGPoint = .zero
    
    private var lastPostedEventDate: TimeInterval = 0.0
    
    // MARK: - Class Methods
    
    public class func `default`() -> TPEventsController {
        return TPEventTapsController.default()
    }
    
    class func instance(for remoteHost: TPRemoteHost?) -> TPEventsController? {
        guard let remoteHost = remoteHost else { return nil }
        if TPLocalHost.shared.pairWith(host: remoteHost, hasCapability: .directEventTaps) {
            // osVersion is encoded as: major * 100 + minor (e.g., 1502 = macOS 15.2)
            let localMajorVersion = TPLocalHost.shared.osVersion / 100
            let remoteMajorVersion = remoteHost.osVersion / 100
            // only allow direct event taps between same major OS versions
            if localMajorVersion == remoteMajorVersion {
                debugLog("Using TPDirectEventTapsController")
                return TPDirectEventTapsController.default()
            } else {
                debugLog("Using TPEventTapsController")
                return TPEventTapsController.default()
            }
        } else if TPLocalHost.shared.pairWith(host: remoteHost, hasCapability: .eventTaps) {
            debugLog("Using TPEventTapsController")
            return TPEventTapsController.default()
        } else {
            return nil
        }
    }
    
    // MARK: - Getting Events
    
    public func startGettingEvents(for listener: TPEventsListener) {
        lastPostedEventDate = 0.0
        eventsListener = listener
        
        _startGettingEventsOnScreen()
    }
    
    public func stopGettingEvents() {
        _stopGettingEvents()
    }
    
    open func cleanupGettingEvents() {
        // Can be overridden by subclasses
    }
    
    // MARK: - Internal Getting Events Methods
    
    open func _startGettingEventsOnScreen() {
        // Overloaded by subclasses
    }
    
    open func _sendEvent(toListener event: Any) {
        let listener = eventsListener
        
        if lastPostedEventDate == 0.0 && _shouldSkipFirstEvent(event) {
            debugLog("skipping first event")
        } else if let listener = listener {
            if let nsEvent = _nsEvent(fromEvent: event), !listener.shouldStop(with: nsEvent) {
                if let eventData = _eventData(fromEvent: event) {
                    listener.gotEvent(withEventData: eventData)
                }
            }
        }
        
        lastPostedEventDate = Date.timeIntervalSinceReferenceDate
    }
    
    open func _stopGettingEvents() {
        // Overloaded by subclasses
    }
    
    // MARK: - Posting Events
    
    open func startPostingEvents() {
        lastPostedEventDate = 0.0
    }
    
    open func stopPostingEvents() {
        // Can be overridden by subclasses
    }
    
    public func postEvent(withEventData eventData: Data?) {
        guard let eventData = eventData else { return }
        let now = Date.timeIntervalSinceReferenceDate
        
        if now - lastPostedEventDate > 60.0 { // if last event occurred more than a minute ago
            SystemPowerManager.wakeUpScreen()
        }
        
        lastPostedEventDate = now
        
        _postEvent(withEventData: eventData)
    }
    
    open func _postEvent(withEventData eventData: Data) {
        // Overloaded by subclasses
    }
    
    // MARK: - Mouse Warping
    
    public func warpMouseToCenter() {
        let screens = TPLocalHost.shared.screens
        var mainScreenRect = NSScreen.main?.frame ?? .zero
        if mainScreenRect == .zero && screens.count > 0 {
            mainScreenRect = screens[0].frame
        }
        
        let centerPoint = NSPoint(x: mainScreenRect.midX, y: mainScreenRect.midY)
        warpMouse(toPosition: centerPoint)
    }
    
    open func warpMouse(toPosition position: NSPoint) {
        currentMouseLocation = CGPoint(x: position.x, y: position.y)
        
        // Keep screen index in sync with warps; otherwise subsequent delta updates may clamp
        // the cursor back to the previous/default screen (often the primary screen).
        let screens = TPLocalHost.shared.screens
        var mainScreenRect = NSScreen.main?.frame ?? .zero
        if mainScreenRect == .zero && screens.count > 0 {
            mainScreenRect = screens[0].frame
        }
        
        for (i, screen) in screens.enumerated() {
            let screenFrame = screen.frame
            var relativePoint = currentMouseLocation
            relativePoint.x -= screenFrame.minX
            relativePoint.y -= (mainScreenRect.maxY - screenFrame.maxY)
            if relativePoint.x >= 0 && relativePoint.y >= 0 && relativePoint.x < screenFrame.width && relativePoint.y < screenFrame.height {
                currentScreenIndex = i
                break
            }
        }
    }
    
    open func mouseDown(atPosition position: NSPoint) {
        warpMouse(toPosition: position)
    }
    
    open func mouseUp(atPosition position: NSPoint) {
        warpMouse(toPosition: position)
    }
    
    // MARK: - Event Processing Helpers
    
    open func _shouldSkipFirstEvent(_ event: Any) -> Bool {
        return false
    }
    
    open func _isEmergencyStopEvent(_ event: Any) -> Bool {
        return false
    }
    
    open func _nsEvent(fromEvent event: Any) -> NSEvent? {
        return event as? NSEvent
    }
    
    open func _eventData(fromEvent event: Any) -> Data? {
        return nil
    }
    
    public func _updateMouseLocation(with mouseDelta: TPMouseDelta) {
        let screens = TPLocalHost.shared.screens
        var mainScreenRect = NSScreen.main?.frame ?? .zero
        if mainScreenRect == .zero && screens.count > 0 {
            mainScreenRect = screens[0].frame
        }
        
        currentMouseLocation = NSEvent.mouseLocation
        currentMouseLocation.x += CGFloat(mouseDelta.x)
        // currentMouseLocation is relative to the left-top corner of the main screen.
        currentMouseLocation.y = mainScreenRect.maxY - currentMouseLocation.y
        currentMouseLocation.y += CGFloat(mouseDelta.y)
        
        for (i, screen) in screens.enumerated() {
            let screenFrame = screen.frame
            var relativePoint = currentMouseLocation
            relativePoint.x -= screenFrame.minX
            relativePoint.y -= (mainScreenRect.maxY - screenFrame.maxY)
            
            if relativePoint.x >= 0 && relativePoint.y >= 0 && relativePoint.x < screenFrame.width && relativePoint.y < screenFrame.height {
                currentScreenIndex = i
                return
            }
        }
        
        // Mouse cursor is outside
        let screen = screens[currentScreenIndex]
        let screenFrame = screen.frame
        var relativePoint = currentMouseLocation
        relativePoint.x -= screenFrame.minX
        relativePoint.y -= (mainScreenRect.maxY - screenFrame.maxY)
        
        relativePoint.x = max(0, min(relativePoint.x, screenFrame.width - 1.0))
        relativePoint.y = max(0, min(relativePoint.y, screenFrame.height - 1.0))
        
        currentMouseLocation = relativePoint
        currentMouseLocation.x += screenFrame.minX
        currentMouseLocation.y += (mainScreenRect.maxY - screenFrame.maxY)
        
        // When locked, HotBorder will never receive mouseEnter events.
        // Detect geometric entry and ask the client to stop control (same as a normal hot-border exit).
        if MainActor.assumeIsolated({ SystemStatusObserver.shared.isLocked }) {
            let mouseLocationInvertY = CGPoint(x: currentMouseLocation.x, y: mainScreenRect.maxY - currentMouseLocation.y)
            MainActor.assumeIsolated {
                TPServerController.shared.handleLockedReturnHotBorder(at: mouseLocationInvertY)
            }
        }
    }
    
    open func event(_ event: NSEvent?, hasRequiredKeyIfNeeded needed: Bool, withTag tag: NSEvent.EventType) -> Bool {
        guard let event = event else { return false }
        
        if !needed {
            return true
        }
        
        let keyMask = NSEvent.EventTypeMask(type: tag)
        debugLog("keyMask: \(keyMask.rawValue) modifiersFlags: \(event.modifierFlags.rawValue)")
        if (UInt64(event.modifierFlags.rawValue) & keyMask.rawValue) != 0 {
            return true
        }
        
        let flags = NSEvent.modifierFlags
        debugLog("flags: \(flags.rawValue)")
        switch tag.rawValue {
        case UInt(COMMAND_KEY_TAG):
            if flags.contains(.command) {
                return true
            }
        case UInt(ALT_KEY_TAG):
            if flags.contains(.option) {
                return true
            }
        case UInt(CTRL_KEY_TAG):
            if flags.contains(.control) {
                return true
            }
        case UInt(SHIFT_KEY_TAG):
            if flags.contains(.shift) {
                return true
            }
        case UInt(CAPSLOCK_KEY_TAG):
            if flags.contains(.capsLock) {
                return true
            }
        default:
            break
        }
        
        return false
    }
}
