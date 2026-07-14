// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import Carbon
import CoreGraphics

// MARK: - Constants

let ESC_KEYCODE: Int = 53
let DISABLE_CONTROL = false
private let MAX_STRING = 20

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

// MARK: - Helper Functions

private func isMouseEventType(_ eventType: CGEventType) -> Bool {
    return eventType == .mouseMoved ||
           eventType == .leftMouseDragged ||
           eventType == .rightMouseDragged ||
           eventType == .otherMouseDragged
}

// MARK: - TPEventsListener Protocol

public protocol TPEventsListener: NSObjectProtocol {
    func gotEvent(withEventData eventData: Data)
    func gotEmergencyStopEvent()
    func gotEmergencyStopProgress(count: Int)
}

// MARK: - TPSerializationMode

@objc public enum TPSerializationMode: Int {
    case legacy
    case direct
}

// MARK: - TPEventsController

@objc public class TPEventsController: NSObject {
    
    // MARK: - Properties
    
    public private(set) var eventsListener: TPEventsListener?
    
    public var currentScreenIndex: Int = 0
    public var currentMouseLocation: CGPoint = .zero
    
    private var lastPostedEventDate: TimeInterval = 0.0
    
    private var eventSource: CGEventSource?
    
    private lazy var emergencyStopDetector = TPEmergencyStopDetector(
        onProgress: { [weak self] count in
            DispatchQueue.main.async {
                self?.eventsListener?.gotEmergencyStopProgress(count: count)
            }
        },
        onTrigger: { [weak self] in
            DispatchQueue.main.async {
                self?.eventsListener?.gotEmergencyStopEvent()
            }
        }
    )
    
    /// Snapshot of the controlling state, written on the main thread and read
    /// on the event tap thread.  A plain Bool store/load is atomic on ARM64
    /// and x86-64, so no lock is needed.
    nonisolated(unsafe) private var _isControllingSnapshot: Bool = false
    
    @objc public var serializationMode: TPSerializationMode = .legacy
    
    // MARK: - Singleton
    
    private static var _sharedInstance: TPEventsController?
    
    @objc public class func `default`() -> TPEventsController {
        if _sharedInstance == nil {
            _sharedInstance = TPEventsController()
        }
        return _sharedInstance!
    }
    
    private override init() {
        super.init()
        TPEventTapListener.shared.addDelegate(self.emergencyStopDetector)
    }
    
    @objc public static var shared: TPEventsController {
        return `default`()
    }
    
    class func instance(for remoteHost: TPRemoteHost?) -> TPEventsController? {
        guard let remoteHost = remoteHost else { return nil }
        let preferDirect = TPPreferencesManager.shared().bool(forPref: Settings.useDirectEventTapsKey)
        let controller = TPEventsController.shared
        if preferDirect, TPLocalHost.shared.pairWith(host: remoteHost, hasCapability: .directEventTaps) {
            debugLog("Using direct event taps serialization")
            controller.serializationMode = .direct
            return controller
        } else if TPLocalHost.shared.pairWith(host: remoteHost, hasCapability: .eventTaps) {
            debugLog("Using legacy event taps serialization")
            controller.serializationMode = .legacy
            return controller
        } else {
            return nil
        }
    }
    
    @objc public class func _eventName(from type: CGEventType) -> String {
        let index = Int(type.rawValue)
        if index < eventTypeName.count {
            return eventTypeName[index]
        } else {
            return String(format: "Event Type 0x%x", type.rawValue)
        }
    }
    
    // MARK: - Getting Events
    
    @discardableResult
    public func startGettingEvents(for listener: TPEventsListener) -> Bool {
        lastPostedEventDate = 0.0
        eventsListener = listener
        
        return _startGettingEventsOnScreen()
    }
    
    public func stopGettingEvents() {
        _stopGettingEvents()
    }
    
    @objc public func cleanupGettingEvents() {
        _isControllingSnapshot = false
        
        let listener = TPEventTapListener.shared
        listener.removeDelegate(self)
        
        let alwaysObserve = TPPreferencesManager.shared().bool(forPref: Settings.alwaysObserveEventsKey)
        if !alwaysObserve {
            listener.stop()
        }
        
        MainActor.assumeIsolated {
            TPCursorVisibilityController.shared.endControlSession(reason: "cleanupGettingEvents")
        }
    }

    // MARK: - Internal Getting Events Methods
    
    @discardableResult
    @objc public func _startGettingEventsOnScreen() -> Bool {
        #if DISABLE_CONTROL
        return false
        #endif
        
        _isControllingSnapshot = true
        emergencyStopDetector.reset()
        
        if IsSecureEventInputEnabled() {
            DispatchQueue.main.async {
                TPMainController.shared().goFrontmost()
            }
        }
        
        MainActor.assumeIsolated {
            TPCursorVisibilityController.shared.beginControlSession(reason: "startGettingEvents")
        }

        let listener = TPEventTapListener.shared
        listener.addDelegate(self)
        return listener.start()
    }
    
    @objc public func _sendEvent(toListener event: Any) {
        guard TPEventTapListener.shared.isEnabled() else { return }
        
        let listener = eventsListener
        
        if lastPostedEventDate == 0.0 && _shouldSkipFirstEvent(event) {
            debugLog("skipping first event")
        } else if let listener = listener {
            if let eventData = _eventData(fromEvent: event) {
                listener.gotEvent(withEventData: eventData)
            }
        }
        
        lastPostedEventDate = Date.timeIntervalSinceReferenceDate
    }
    
    @objc public func _stopGettingEvents() {
        _isControllingSnapshot = false
        let listener = TPEventTapListener.shared
        listener.stop()
        
        DispatchQueue.main.async {
            TPMainController.shared().leaveFrontmost()
        }
    }
    
    // MARK: - Posting Events
    
    @objc public func startPostingEvents() {
        lastPostedEventDate = 0.0
        eventSource = CGEventSource(stateID: .combinedSessionState)
    }
    
    @objc public func stopPostingEvents() {
        eventSource = nil
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
    
    @objc public func _postEvent(withEventData eventData: Data) {
        guard let event = CGEventSerializer.deserialize(eventData, mode: serializationMode, eventSource: eventSource, currentMouseLocation: currentMouseLocation) else {
            return
        }
        
        let eventType = event.type
        if isMouseEventType(eventType) {
            let deltaX = event.getIntegerValueField(.mouseEventDeltaX)
            let deltaY = event.getIntegerValueField(.mouseEventDeltaY)
            
            if deltaX != 0 || deltaY != 0 {
                let mouseDelta = TPMouseDelta(x: deltaX, y: deltaY)
                _updateMouseLocation(with: mouseDelta)
            }
        }
        
        event.location = currentMouseLocation
        _postEvent(event)
    }
    
    @objc public func _postEvent(_ event: CGEvent) {
        event.timestamp = CGSCurrentEventTimestamp()
        
        if let source = eventSource {
            event.setSource(source)
        }
        
        event.post(tap: .cgSessionEventTap)
    }
    
    // MARK: - Mouse Warping
    
    public func warpMouseToCenter() {
        let screens = TPLocalHost.shared.screens
        let mainScreenRect = NSScreen.primaryScreenFrame
        
        let centerPoint = NSPoint(x: mainScreenRect.midX, y: mainScreenRect.midY)
        warpMouse(toPosition: centerPoint)
    }
    
    @objc public func warpMouse(toPosition position: NSPoint) {
        currentMouseLocation = CGPoint(x: position.x, y: position.y)
        
        // Keep screen index in sync with warps; otherwise subsequent delta updates may clamp
        // the cursor back to the previous/default screen (often the primary screen).
        let screens = TPLocalHost.shared.screens
        let mainScreenRect = NSScreen.primaryScreenFrame
        
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
        
        debugLog("warp to \(NSStringFromPoint(position))", module: .control)
        
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
    
    @objc public func mouseDown(atPosition position: NSPoint) {
        warpMouse(toPosition: position)
        
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: currentMouseLocation, mouseButton: .left) {
            event.type = .leftMouseDown
            _postEvent(event)
        }
    }
    
    @objc public func mouseUp(atPosition position: NSPoint) {
        warpMouse(toPosition: position)
        
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: currentMouseLocation, mouseButton: .left) {
            event.type = .leftMouseUp
            event.post(tap: .cgSessionEventTap)
        }
    }
    
    // MARK: - Event Processing Helpers
    
    @objc public func _shouldSkipFirstEvent(_ e: Any) -> Bool {
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
    
    
    @objc public func _eventData(fromEvent e: Any) -> Data? {
        return CGEventSerializer.serialize(e, mode: serializationMode)
    }
    
    public func _updateMouseLocation(with mouseDelta: TPMouseDelta) {
        let screens = TPLocalHost.shared.screens
        let mainScreenRect = NSScreen.primaryScreenFrame
        
        currentMouseLocation = NSEvent.mouseLocation
        currentMouseLocation.x += CGFloat(mouseDelta.x)
        // currentMouseLocation is relative to the left-top corner of the main screen.
        currentMouseLocation.y = mainScreenRect.maxY - currentMouseLocation.y
        currentMouseLocation.y += CGFloat(mouseDelta.y)
        
        var insideScreen = false
        for (i, screen) in screens.enumerated() {
            let screenFrame = screen.frame
            var relativePoint = currentMouseLocation
            relativePoint.x -= screenFrame.minX
            relativePoint.y -= (mainScreenRect.maxY - screenFrame.maxY)
            
            if relativePoint.x >= 0 && relativePoint.y >= 0 && relativePoint.x < screenFrame.width && relativePoint.y < screenFrame.height {
                currentScreenIndex = i
                insideScreen = true
                break
            }
        }
        
        if !insideScreen {
            // Mouse cursor is outside every screen: clamp it back onto the screen
            // it most recently belonged to.
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
        }
        
        // Drive the controlled-side return border geometrically from the injected
        // virtual cursor (locked or not). The hot-border window never receives
        // real mouseEntered events for an injected cursor, so detection is unified
        // through HotBorderMonitor instead of relying on window events.
        //
        // This must run whether the injected cursor is inside a screen or not: the
        // return hot border is a thin strip *inside* the screen along an edge, so
        // the cursor is still on-screen when it reaches it. Evaluating only in the
        // off-screen/clamped branch meant edge strips (notably the top edge, whose
        // clamped point lands on the rect's exclusive max-Y) never fired, so
        // control could not be returned.
        // `currentMouseLocation` here is top-left origin; convert back to Cocoa
        // global (bottom-left origin) for the geometric test.
        let mouseLocationInvertY = CGPoint(x: currentMouseLocation.x, y: mainScreenRect.maxY - currentMouseLocation.y)
        MainActor.assumeIsolated {
            HotBorderMonitor.shared.evaluateInjectedCursor(atGlobalPoint: mouseLocationInvertY)
        }
    }
    
    @objc public func event(_ event: NSEvent?, hasRequiredKeyIfNeeded needed: Bool, withTag tag: NSEvent.EventType) -> Bool {
        if !needed {
            return true
        }
        
        if let event = event, let source = eventSource {
            let sourceState = source.sourceStateID
            let flags = CGEventSource.flagsState(sourceState)
            let keyMask = NSEvent.EventTypeMask(type: tag)
            return (flags.rawValue & keyMask.rawValue) != 0
        }
        
        // Geometric (HotBorderMonitor) firing has no NSEvent; fall back to the
        // current global modifier state below. With an event, prefer its flags.
        if let event = event {
            let keyMask = NSEvent.EventTypeMask(type: tag)
            debugLog("keyMask: \(keyMask.rawValue) modifiersFlags: \(event.modifierFlags.rawValue)")
            if (UInt64(event.modifierFlags.rawValue) & keyMask.rawValue) != 0 {
                return true
            }
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

// MARK: - TPEventTapListenerDelegate

extension TPEventsController: TPEventTapListenerDelegate {
    func eventTapListener(
        _ listener: TPEventTapListener,
        handleEventCallback proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type.rawValue >= CGEventType.tapDisabledByTimeout.rawValue {
            _ = listener.start()
            NSLog("[EventTap] eventCallback, reenable on type=\(type.rawValue)")
            return nil
        }
        
        guard _isControllingSnapshot else {
            return Unmanaged.passRetained(event)
        }
        
        _sendEvent(toListener: event)

        DispatchQueue.main.async {
            TPCursorVisibilityController.shared.handleEventTapTick(isControlling: true, eventType: type)
        }

        return nil
    }
}
