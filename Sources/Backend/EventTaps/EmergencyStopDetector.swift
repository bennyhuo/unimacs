// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import Carbon

class EmergencyStopDetector {
    private var emergencyStopEventCount = 0
    private var lastEventTime: TimeInterval = 0
    private let onProgress: (Int) -> Void
    private let onTrigger: () -> Void
    
    private let timeWindow: TimeInterval = 2.0 // Time window of 2 seconds
    
    init(onProgress: @escaping (Int) -> Void, onTrigger: @escaping () -> Void) {
        self.onProgress = onProgress
        self.onTrigger = onTrigger
    }
    
    func reset() {
        emergencyStopEventCount = 0
        lastEventTime = 0
    }
    
    func processEvent(_ event: CGEvent) {
        // Ignore synthetic events injected by Unimacs on the controlled machine
        if event.getIntegerValueField(.eventSourceUserData) == EventsController.injectedEventUserDataTag {
            return
        }

        let currentTime = Date().timeIntervalSince1970
        
        // 1. Reset count if time window exceeded
        if emergencyStopEventCount > 0 && (currentTime - lastEventTime > timeWindow) {
            NSLog("[EmergencyStop] Time window exceeded, resetting count.")
            emergencyStopEventCount = 0
        }
        
        if isEmergencyStopEvent(event) {
            // 2. Ignore key-repeat events to prevent accidental terminations when holding down the key
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat {
                return
            }
            
            emergencyStopEventCount += 1
            lastEventTime = currentTime
            NSLog("[EmergencyStop] emergency events: %d", emergencyStopEventCount)
            
            if emergencyStopEventCount >= 3 {
                NSLog("[EmergencyStop] emergency stop key sequence detected, triggering callback.")
                onTrigger()
            }
            
            onProgress(emergencyStopEventCount)
            
            if emergencyStopEventCount >= 10 {
                NSLog("[EmergencyStop] emergency stop key sequence triggered 10 times, terminating application.")
                // 3. Graceful terminate
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
                // 4. Force exit after 1 second if main thread is deadlocked
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    exit(-1)
                }
            }
        } else {
            // 5. Only reset if it is another key's physical keyDown event.
            // Avoid resetting on flagsChanged event, as minor modifier fluctuations are common.
            if event.type == .keyDown {
                emergencyStopEventCount = 0
            }
        }
    }
    
    func isEmergencyStopEvent(_ event: CGEvent) -> Bool {
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
}

extension EmergencyStopDetector: EventTapListenerDelegate {
    func eventTapListener(
        _ listener: EventTapListener,
        handleEventCallback proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .keyDown || type == .flagsChanged {
            processEvent(event)
        }
        return Unmanaged.passRetained(event)
    }
}
