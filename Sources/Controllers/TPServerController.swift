// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import AppKit
import IOKit

enum TPServerState: Int {
    case idle
    case shared
    case controlled
}

@objcMembers
class TPServerController: TPConnectionController, DeviceConnectionDelegate {
    
    private var state: TPServerState = .idle
    private var clientHotBorder: TPHotBorder?
    private var switchOptions: [AnyHashable: Any]?
	/// Client desktop placement in *server* global coordinates. Used to map cross-screen border locations.
	private var clientDesktopPlacementInServerCoords: NSRect?
    
	static let shared = TPServerController()
    
    override init() {
        super.init()
        
        self.state = .shared
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(connectionDisconnected(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        
        // Register as delegate with DeviceConnectionManager
        // Use MainActor.assumeIsolated since init is called on main thread
        MainActor.assumeIsolated {
            DeviceConnectionManager.shared.addDelegate(self)
        }
    }
    
    // MARK: - Sharing
    
    @MainActor
    func startSharing() {
        let portValue = TPPreferencesManager.shared().port(forPref: COMMAND_PORT)
        var port = Int32(portValue)
        
        // Use DeviceConnectionManager to start listening
        if DeviceConnectionManager.shared.startListening(onPort: &port) {
            Publisher.shared.start(with: port)
        }
    }
    
	@MainActor
    func stopSharing() {
        stopControl()
        Publisher.shared.stop()
        // Use DeviceConnectionManager to stop listening
        DeviceConnectionManager.shared.stopListening()
    }
    
    // MARK: - Hot border

	@MainActor
	override func currentHotBorder() -> TPHotBorder? {
        return clientHotBorder
    }
    
	@MainActor
	func setupHotBorder(_ hotBorder: TPHotBorder, for host: TPRemoteHost) {
        // Hot border setup - no longer needs drag configuration
    }
    
	override func hotBorder(_ hotBorder: TPHotBorder, canFireWithEvent event: NSEvent?) -> Bool {
        let requireKey = (self.optionForRemoteHost(nil, key: REQUIRE_KEY) as? NSNumber)?.boolValue ?? false
		let keyTag = (self.optionForRemoteHost(nil, key: SWITCH_KEY_TAG) as? NSNumber)?.uintValue ?? 0
		return self.eventsController?.event(event, hasRequiredKeyIfNeeded: requireKey, withTag: NSEvent.EventType(rawValue: keyTag)!) ?? false
    }
    
	override func hotBorder(_ hotBorder: TPHotBorder, firedAtLocation location: NSPoint) -> Bool {
        self.requestStopControl(at: location)
		return super.hotBorder(hotBorder, firedAtLocation: location)
    }
    
    // MARK: - Switch options
    
    func setSwitchOptions(_ options: [AnyHashable: Any]?) {
        self.switchOptions = options
    }
    
    @MainActor
    override func optionForRemoteHost(_ remoteHost: TPRemoteHost?, key: String) -> Any? {
        var option = self.switchOptions?[key]
        if option == nil {
            option = TPPreferencesManager.shared().value(forPref: key)
        }
        return option
    }
    
    // MARK: - Start control
    
	@MainActor
	func requestedStartControl(by host: TPRemoteHost, on connection: NetworkConnection, with data: ControlRequestBody) {
        let connectionIsCurrent = (connection === self.currentConnection)
        
		if !TPMainController.shared().canBeControlledByHost(withIdentifier: host.identifier) {
			// Fire and forget - failure response
			connection.sendAsync(TPMessage.create(with: .controlFailure, andInfoDict: ["reason": NSLocalizedString("Host not controllable.", comment: "Reason for control failure")]))
            if connectionIsCurrent {
				self.currentConnection = nil
            }
            return
        }
        
        if !TPAuthenticationManager.default.isHostTrusted(host) {
			// Fire and forget - failure response
			connection.sendAsync(TPMessage.create(with: .controlFailure, andInfoDict: ["reason": NSLocalizedString("Host not trusted.", comment: "Reason for control failure")]))
            if connectionIsCurrent {
				self.currentConnection = nil
            }
            return
        }
        
		// Fire and forget - success response
		connection.sendAsync(TPMessage.create(with: .controlSuccess))
        
        if !connectionIsCurrent {
			self.currentConnection = connection
        }
        
        self.updateEventsController()
        self.startControl(with: data)
    }
    
	@MainActor
	func startControl(with data: ControlRequestBody) {
        self.state = .controlled
        
		let host = self.currentConnection!.connectedHost!
        
		TPStatusItemController.default.update(with: .controlled, host: host)
        
		TPClientController.shared.updateTriggersAndShowVisualHint(false)
        
		
		let localDesktopFrame = TPLocalHost.shared.screens.reduce(NSRect.null) { $0.union($1.frame) }
        
		// `screenPlacement` is expressed in a coordinate system whose origin is the *server desktop* bounding rect.
		// Convert it to server global screen coordinates by adding the server desktop origin.
		var adjustedPlacement = data.screenPlacement
        adjustedPlacement.origin.x += localDesktopFrame.minX
        adjustedPlacement.origin.y += localDesktopFrame.minY
        
        if let existingBorder = clientHotBorder {
            existingBorder.close()
        }
        
		// Clip against the whole local desktop, not a single screen frame.
        clientHotBorder = TPHotBorder(hostId: host.identifier, contentRect: adjustedPlacement, in: localDesktopFrame, kind: .control)
		clientDesktopPlacementInServerCoords = adjustedPlacement
        if let border = clientHotBorder {
            self.setupHotBorder(border, for: host)
            border.setHotDelegate(self)
            border.delayedActivate()
        }
		
		debugLog("Control started with border: \(clientHotBorder?.frame ?? .zero)", module: .control)
        
        self.eventsController?.startPostingEvents()
        
        var shouldWarp = false
		var mousePosition = data.mousePosition
		if let border = clientHotBorder, let rel = data.hotBorderRelativePoint {
			// Preferred: normalized within the hot border window.
			shouldWarp = true
			let contentSize = border.frame.size
			let localPoint = NSPoint(x: rel.x * contentSize.width, y: rel.y * contentSize.height)
			mousePosition = border.screenPoint(fromLocalPoint: localPoint, flipped: true)
		} else if mousePosition.x >= 0.0 && mousePosition.y >= 0.0 {
            // Fallback (legacy): `mousePosition` is relative to the *client* desktop bounding rect.
            // Map it into server global coordinates using the placement rect.
            shouldWarp = true
            let serverCocoaPoint = NSPoint(
                x: adjustedPlacement.minX + mousePosition.x,
                y: adjustedPlacement.minY + mousePosition.y
            )
			let mainMaxY = NSScreen.main?.frame.maxY ?? localDesktopFrame.maxY
            mousePosition = NSPoint(
                x: serverCocoaPoint.x,
                y: mainMaxY - serverCocoaPoint.y
            )
        }
        
		if let border = clientHotBorder, border.state != .inactiveState {
            border.deactivate()
            if shouldWarp {
                self.eventsController?.warpMouse(toPosition: mousePosition)
            }
            border.delayedActivate()
        } else if shouldWarp {
            self.eventsController?.warpMouse(toPosition: mousePosition)
        }
        
		self.setSwitchOptions(data.options)
		TPClipboardTransferCoordinator.shared.serverDidStartBeingControlled()
		
		if TPLocalHost.shared.hasCustomBackgroundImage {

			TPTransfersManager.shared.beginTransfer(TPOutgoingBackgroundImageTransfer.shared(), using: self.currentConnection!)
        }
        
        SystemPowerManager.wakeUpScreen()
        
        let entry = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/IOResources/IODisplayWrangler")
        if entry != MACH_PORT_NULL {
            IORegistryEntrySetCFProperty(entry, "IORequestIdle" as CFString, kCFBooleanFalse)
            IOObjectRelease(entry)
        }
    }
    
    // MARK: - Stop control
    
	@MainActor func requestStopControl(at location: NSPoint) {
		// Only send serializable cursor / hot-border position info in the controlStop message.
		var messageInfoDict: [AnyHashable: Any] = [:]
		
		// `location` is window-local to `clientHotBorder`. Convert it to a point relative to the
		// *client desktop bounding rect* so the client can map it back to the correct local screen.
		if let border = clientHotBorder, let placement = clientDesktopPlacementInServerCoords {
			let serverCocoaPoint = border.screenPoint(fromLocalPoint: location, flipped: false)
			let clientDesktopRelative = NSPoint(
				x: serverCocoaPoint.x - placement.minX,
				y: serverCocoaPoint.y - placement.minY
			)
			messageInfoDict[TPMousePositionKey] = NSData.data(with: clientDesktopRelative)
			
			// Preferred: normalized within the hot border window.
			let contentSize = border.frame.size
			let rawRelative = NSPoint(
				x: contentSize.width > 0 ? (location.x / contentSize.width) : 0,
				y: contentSize.height > 0 ? (location.y / contentSize.height) : 0
			)
			let rel = NSPoint(
				x: min(max(rawRelative.x, 0), 1),
				y: min(max(rawRelative.y, 0), 1)
			)
			messageInfoDict[TPHotBorderRelativePointKey] = NSData.data(with: rel)
		} else {
			messageInfoDict[TPMousePositionKey] = NSData.data(with: location)
		}
		
		if state == .controlled, let connection = currentConnection {
			TPClipboardTransferCoordinator.shared.serverRequestStopControl(using: connection)
		}
		
		let message = TPMessage.create(with: .controlStop, andInfoDict: messageInfoDict)
		// Fire and forget - control stop should not block
		self.currentConnection?.sendAsync(message)
		
	}
    
    override func stopControl(withDisconnect disconnect: Bool) {
		if state == .controlled, let connection = self.currentConnection {
			TPClipboardTransferCoordinator.shared.serverWillStopBeingControlled(using: connection)
		}

        super.stopControl(withDisconnect: disconnect)
        
        if state == .controlled {
            state = TPPreferencesManager.shared().bool(forPref: ALLOW_CONTROL) ? .shared : .idle
            
            if TPPreferencesManager.shared().bool(forPref: WRAP_ON_STOP_CONTROL) {
                self.eventsController?.warpMouseToCenter()
            }
            
            self.eventsController?.stopPostingEvents()
            
            if let border = clientHotBorder {
                self.takeDownHotBorder(border)
                border.close()
                clientHotBorder = nil
				clientDesktopPlacementInServerCoords = nil
            }
            
			TPStatusItemController.default.update(with: .idle, host: nil)
            TPClientController.shared.updateTriggersAndShowVisualHint(false)
			debugLog("Control stopped, server state restored to \(state == .shared ? "shared" : "idle")", module: .control)
        }
    }
    
    // MARK: - DeviceConnectionDelegate
    
    @MainActor
    func connectionDidEstablish(to host: TPRemoteHost, connection: NetworkConnection) {
        // Server receives incoming connections, no specific action needed on establishment
        // The connection is ready to receive control requests
        NSLog("TPServerController: Connection established from \(host.computerName)")
    }
    
    @MainActor
    func connectionDidDisconnect(from host: TPRemoteHost) {
        guard currentConnection?.connectedHost?.identifier == host.identifier else { return }
        if state == .controlled {
            stopControl(withDisconnect: false)
        }
        currentConnection = nil
    }
    
    @MainActor
    func connectionDidFail(to host: TPRemoteHost) {
        // Server doesn't initiate connections, so this is rarely called
    }
    
    @MainActor
    func handleMessage(_ message: TPMessage, from host: TPRemoteHost, connection: NetworkConnection) -> Bool {
        let type = message.msgType
        
        switch type {
        case .controlDeviceSleep:
            SystemPowerManager.sleepTheSystem()
            return true
        case .controlScreenSleep:
            SystemPowerManager.sleepScreen()
            return true
        case .controlWake:
            SystemPowerManager.wakeUpScreen()
            return true
        case .controlLock:
            SystemPowerManager.lockScreen()
            return true
        case .controlRequest:
            self.requestedStartControl(by: host, on: connection, with: message.controlRequestBody)
            return true
        case .controlStop:
            self.stopControl(withDisconnect: DISCONNECT_WHEN_STOP_CONTROL)
            return true
        case .authenticationRequest:
            TPAuthenticationManager.default.authenticationRequested(from: host, on: connection)
            return true
        case .event:
            // Only accept events from the controlling connection
            if self.currentConnection === connection || 
               self.currentConnection?.connectedHost?.identifier == host.identifier {
                self.eventsController?.postEvent(withEventData: message.data)
                return true
            }
            return false
        default:
            switch message.msgType {
            case .transferRequest, .transferSuccess, .transferFailure:
                super.connection(connection, receivedMessage: message)
                return true
            default:
                return false
            }
        }
    }
    
    // MARK: - Setters and getters
    
	@MainActor
    var allowControl: Bool {
        get {
            return true
        }
        set {
            // Under Unified Cursor Space design, server sharing is always enabled.
        }
    }
    
    var isControlled: Bool {
        get {
            return state == .controlled
        }
    }
}
