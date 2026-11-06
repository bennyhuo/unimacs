// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

protocol EventTapListenerDelegate: AnyObject {
    func eventTapListener(
        _ listener: EventTapListener,
        handleEventCallback proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>?
}

class WeakEventTapListenerDelegate: @unchecked Sendable {
    weak var value: EventTapListenerDelegate?
    init(_ value: EventTapListenerDelegate) {
        self.value = value
    }
}

enum EventTapMode: Int {
    /// Passive observation of keyboard events only (used for background emergency stop detection).
    /// Uses `.listenOnly` so local mouse clicks are never routed through or blocked by this process.
    case passiveKeyboardOnly
    /// Active interception of all keyboard and mouse events (used while actively controlling a remote Mac).
    case activeControl
}

class EventTapListener: @unchecked Sendable {
    nonisolated(unsafe) private var eventPort: CFMachPort?
    nonisolated(unsafe) private var eventSource: CFRunLoopSource?
    nonisolated(unsafe) private var eventTapThread: Thread?
    nonisolated(unsafe) private var eventTapRunLoop: CFRunLoop?
    nonisolated(unsafe) private var currentMode: EventTapMode?
    
    static let shared = EventTapListener()
    
    private let delegatesLock = NSLock()
    private var weakDelegates: [WeakEventTapListenerDelegate] = []
    
    func addDelegate(_ delegate: EventTapListenerDelegate) {
        delegatesLock.lock()
        defer { delegatesLock.unlock() }
        weakDelegates.removeAll { $0.value == nil }
        if !weakDelegates.contains(where: { $0.value === delegate }) {
            weakDelegates.append(WeakEventTapListenerDelegate(delegate))
        }
    }
    
    func removeDelegate(_ delegate: EventTapListenerDelegate) {
        delegatesLock.lock()
        defer { delegatesLock.unlock() }
        weakDelegates.removeAll { $0.value === delegate || $0.value == nil }
    }
    
    private init() {}
    
    /// Starts or reconfigures the event tap on a dedicated background thread.
    func start(mode: EventTapMode = .passiveKeyboardOnly) -> Bool {
        if let port = eventPort, currentMode == mode {
            if !CGEvent.tapIsEnabled(tap: port) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return true
        }
        
        if eventTapRunLoop == nil {
            let semaphore = DispatchSemaphore(value: 0)
            
            let thread = Thread { [weak self] in
                guard let self = self else {
                    semaphore.signal()
                    return
                }
                
                let runLoop = CFRunLoopGetCurrent()!
                self.eventTapRunLoop = runLoop
                
                // Add a dummy source to keep the run loop alive
                var context = CFRunLoopSourceContext()
                if let dummySource = CFRunLoopSourceCreate(nil, 0, &context) {
                    CFRunLoopAddSource(runLoop, dummySource, .defaultMode)
                }
                
                semaphore.signal()
                CFRunLoopRun()
                NSLog("[EventTap] Event tap thread exiting")
            }
            
            thread.name = "com.bennyhuo.unimacs.EventTapThread"
            thread.qualityOfService = .userInteractive
            self.eventTapThread = thread
            thread.start()
            
            semaphore.wait()
        }
        
        guard let runLoop = eventTapRunLoop else { return false }
        
        // Tear down existing tap if switching modes
        if let existingPort = eventPort {
            if let existingSrc = eventSource {
                CFRunLoopRemoveSource(runLoop, existingSrc, .defaultMode)
                eventSource = nil
            }
            CFMachPortInvalidate(existingPort)
            eventPort = nil
            currentMode = nil
        }
        
        let options: CGEventTapOptions
        let eventsOfInterest: CGEventMask
        switch mode {
        case .passiveKeyboardOnly:
            options = .listenOnly
            eventsOfInterest = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        case .activeControl:
            options = .defaultTap
            eventsOfInterest = CGEventMask(UInt64.max) & ~(UInt64(NX_KITDEFINEDMASK) | UInt64(NX_APPDEFINEDMASK))
        }
        
        let callbackContext = Unmanaged.passUnretained(self).toOpaque()
        let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: eventsOfInterest,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<EventTapListener>.fromOpaque(refcon).takeUnretainedValue()
                return listener.handleEventCallback(proxy: proxy, type: type, event: event)
            },
            userInfo: callbackContext
        )
        
        guard let port = port else {
            NSLog("[EventTap] Can't create event port (mode=\(mode))")
            return false
        }
        
        guard let eventSrc = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            NSLog("[EventTap] Can't create event src")
            CFMachPortInvalidate(port)
            return false
        }
        
        CFRunLoopAddSource(runLoop, eventSrc, .defaultMode)
        CFRunLoopWakeUp(runLoop)
        self.eventPort = port
        self.eventSource = eventSrc
        self.currentMode = mode
        return true
    }
    
    /// Stops the event tap on the background thread's RunLoop.
    func stop() {
        performOnEventThread { [weak self] in
            guard let self = self else { return }
            NSLog("[EventTap] EventTapListener.stop called. eventTapRunLoop exists: \(self.eventTapRunLoop != nil), eventPort exists: \(self.eventPort != nil)")
            
            if let runLoop = self.eventTapRunLoop, let src = self.eventSource {
                CFRunLoopRemoveSource(runLoop, src, .defaultMode)
                self.eventSource = nil
            }
            if let port = self.eventPort {
                CFMachPortInvalidate(port)
                self.eventPort = nil
            }
            self.currentMode = nil
        }
    }
    
    /// Checks if the event tap is active and enabled.
    func isEnabled() -> Bool {
        guard let port = eventPort else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }
    
    /// Safely performs a block on the event tap thread's RunLoop.
    func performOnEventThread(_ block: @escaping () -> Void) {
        guard let runLoop = eventTapRunLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
    
    private func handleEventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type.rawValue >= CGEventType.tapDisabledByTimeout.rawValue {
            if let port = eventPort {
                CGEvent.tapEnable(tap: port, enable: true)
            } else {
                _ = start(mode: currentMode ?? .passiveKeyboardOnly)
            }
            NSLog("[EventTap] eventCallback, reenable on type=\(type.rawValue)")
            return nil
        }

        delegatesLock.lock()
        let activeDelegates = weakDelegates.compactMap { $0.value }
        delegatesLock.unlock()
        
        var currentEvent: CGEvent = event
        var shouldSwallow = false
        
        for delegate in activeDelegates {
            if let result = delegate.eventTapListener(self, handleEventCallback: proxy, type: type, event: currentEvent) {
                currentEvent = result.takeUnretainedValue()
            } else {
                shouldSwallow = true
            }
        }
        
        return shouldSwallow ? nil : Unmanaged.passUnretained(currentEvent)
    }
}
