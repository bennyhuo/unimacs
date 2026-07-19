// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import AppKit
import IOKit

enum ServerState: Int {
    case idle
    case shared
    case controlled
}

@objcMembers
class ServerController: ConnectionController, DeviceConnectionDelegate {
    
    private var state: ServerState = .idle {
        didSet {
            if oldValue != state {
                NotificationCenter.default.post(
                    name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
                    object: nil
                )
            }
        }
    }
    private var clientHotBorder: TPHotBorder?
    private var switchOptions: [AnyHashable: Any]?
	/// Client desktop placement in *server* global coordinates. Used to map cross-screen border locations.
	private var clientDesktopPlacementInServerCoords: NSRect?
    private var pendingSwitchToHost: RemoteHost?
    private var pendingSwitchLocation: NSPoint?
    private var pendingSwitchRelativePoint: NSPoint?
    
	static let shared = ServerController()
    
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
        let portValue = PreferencesManager.shared().port(forPref: COMMAND_PORT)
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
	func setupHotBorder(_ hotBorder: TPHotBorder, for host: RemoteHost) {
        // Hot border setup - no longer needs drag configuration
    }
    
	override func hotBorder(_ hotBorder: TPHotBorder, canFireWithEvent event: NSEvent?) -> Bool {
        let requireKey = (self.optionForRemoteHost(nil, key: REQUIRE_KEY) as? NSNumber)?.boolValue ?? false
		let keyTag = (self.optionForRemoteHost(nil, key: SWITCH_KEY_TAG) as? NSNumber)?.uintValue ?? 0
		return self.eventsController?.event(event, hasRequiredKeyIfNeeded: requireKey, withTag: NSEvent.EventType(rawValue: keyTag)!) ?? false
    }
    
	override func hotBorder(_ hotBorder: TPHotBorder, firedAtLocation location: NSPoint) -> Bool {
        self.requestStopControl(at: location, isSwitch: hotBorder.firedByRealCursor)
		return super.hotBorder(hotBorder, firedAtLocation: location)
    }
    
    // MARK: - Switch options
    
    func setSwitchOptions(_ options: [AnyHashable: Any]?) {
        self.switchOptions = options
    }
    
    @MainActor
    override func optionForRemoteHost(_ remoteHost: RemoteHost?, key: String) -> Any? {
        var option = self.switchOptions?[key]
        if option == nil {
            option = PreferencesManager.shared().value(forPref: key)
        }
        return option
    }
    
    // MARK: - Start control
    
	@MainActor
	func requestedStartControl(by host: RemoteHost, on connection: NetworkConnection, with data: ControlRequestBody) {
        let connectionIsCurrent = (connection === self.currentConnection)
        
		if !MainController.shared().canBeControlledByHost(withIdentifier: host.identifier) {
			// Fire and forget - failure response
			connection.sendAsync(Message.create(with: .controlFailure, andInfoDict: ["reason": NSLocalizedString("Host not controllable.", comment: "Reason for control failure")]))
            if connectionIsCurrent {
				self.currentConnection = nil
            }
            return
        }
        
        if !AuthenticationManager.default.isHostTrusted(host) {
			// Fire and forget - failure response
			connection.sendAsync(Message.create(with: .controlFailure, andInfoDict: ["reason": NSLocalizedString("Host not trusted.", comment: "Reason for control failure")]))
            if connectionIsCurrent {
				self.currentConnection = nil
            }
            return
        }
        
		// Fire and forget - success response
		connection.sendAsync(Message.create(with: .controlSuccess))
        
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
        
		StatusItemController.default.update(with: .controlled, host: host)
        
		ClientController.shared.updateTriggersAndShowVisualHint(false)
        
		
		let localDesktopFrame = LocalHost.shared.screens.reduce(NSRect.null) { $0.union($1.frame) }
        
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
			let mainMaxY = NSScreen.primaryScreenFrame.maxY
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
		
		if LocalHost.shared.hasCustomBackgroundImage {

			TransfersManager.shared.beginTransfer(OutgoingBackgroundImageTransfer.shared(), using: self.currentConnection!)
        }
        
        SystemPowerManager.wakeUpScreen()
        
        let entry = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/IOResources/IODisplayWrangler")
        if entry != MACH_PORT_NULL {
            IORegistryEntrySetCFProperty(entry, "IORequestIdle" as CFString, kCFBooleanFalse)
            IOObjectRelease(entry)
        }
    }
    
    // MARK: - Stop control
    
	@MainActor func requestStopControl(at location: NSPoint, isSwitch: Bool) {
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
            
            if isSwitch {
                messageInfoDict[TPSwitchControlKey] = true
                self.pendingSwitchToHost = self.currentConnection?.connectedHost
                
                let localDesktopRect = LocalHost.shared.screens.reduce(NSRect.null) { $0.union($1.frame) }
                let localDesktopRelative = NSPoint(
                    x: serverCocoaPoint.x - localDesktopRect.minX,
                    y: serverCocoaPoint.y - localDesktopRect.minY
                )
                self.pendingSwitchLocation = localDesktopRelative
                self.pendingSwitchRelativePoint = rel
            }
		} else {
			messageInfoDict[TPMousePositionKey] = NSData.data(with: location)
            if isSwitch {
                messageInfoDict[TPSwitchControlKey] = true
                self.pendingSwitchToHost = self.currentConnection?.connectedHost
                self.pendingSwitchLocation = location
                self.pendingSwitchRelativePoint = nil
            }
		}
		
		if state == .controlled, let connection = currentConnection {
			TPClipboardTransferCoordinator.shared.serverRequestStopControl(using: connection)
		}
		
		let message = Message.create(with: .controlStop, andInfoDict: messageInfoDict)
		// Fire and forget - control stop should not block
		self.currentConnection?.sendAsync(message)
		
	}
    
    override func stopControl(withDisconnect disconnect: Bool) {
		if state == .controlled, let connection = self.currentConnection {
			TPClipboardTransferCoordinator.shared.serverWillStopBeingControlled(using: connection)
		}

        super.stopControl(withDisconnect: disconnect)
        
        if state == .controlled {
            state = PreferencesManager.shared().bool(forPref: ALLOW_CONTROL) ? .shared : .idle
            
            if PreferencesManager.shared().bool(forPref: WRAP_ON_STOP_CONTROL) {
                self.eventsController?.warpMouseToCenter()
            }
            
            self.eventsController?.stopPostingEvents()
            
            if let border = clientHotBorder {
                self.takeDownHotBorder(border)
                border.close()
                clientHotBorder = nil
				clientDesktopPlacementInServerCoords = nil
            }
            
			StatusItemController.default.update(with: .idle, host: nil)
            ClientController.shared.updateTriggersAndShowVisualHint(false)
			debugLog("Control stopped, server state restored to \(state == .shared ? "shared" : "idle")", module: .control)
            
            if let targetHost = self.pendingSwitchToHost {
                self.pendingSwitchToHost = nil
                let loc = self.pendingSwitchLocation ?? .zero
                let rel = self.pendingSwitchRelativePoint
                self.pendingSwitchLocation = nil
                self.pendingSwitchRelativePoint = nil
                
                TPClipboardTransferCoordinator.shared.isSwitchingControl = true
                
                debugLog("Executing pending switch to host: \(targetHost.computerName) at \(loc)", module: .control)
                _ = ClientController.shared.requestStartControl(on: targetHost, at: loc, hotBorderRelativePoint: rel)
            }
        }
    }
    
    // MARK: - DeviceConnectionDelegate
    
    @MainActor
    func connectionDidEstablish(to host: RemoteHost, connection: NetworkConnection) {
        // Server receives incoming connections, no specific action needed on establishment
        // The connection is ready to receive control requests
        NSLog("ServerController: Connection established from \(host.computerName)")
    }
    
    @MainActor
    func connectionDidDisconnect(from host: RemoteHost) {
        guard currentConnection?.connectedHost?.identifier == host.identifier else { return }
        if state == .controlled {
            stopControl(withDisconnect: false)
        }
        currentConnection = nil
    }
    
    @MainActor
    func connectionDidFail(to host: RemoteHost) {
        // Server doesn't initiate connections, so this is rarely called
    }
    
    @MainActor
    func handleMessage(_ message: Message, from host: RemoteHost, connection: NetworkConnection) -> Bool {
        let type = message.msgType
        
        switch type {
        case .controlDeviceSleep:
            SystemPowerManager.sleepTheSystem()
            return true
        case .controlScreenSleep:
            SystemPowerManager.sleepScreen()
            return true
        case .controlWake:
            guard !SystemStatusObserver.shared.isLocked else {
                debugLog("Ignoring controlWake because this machine is locked", module: .control)
                return true
            }
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
            AuthenticationManager.default.authenticationRequested(from: host, on: connection)
            return true
        case .event:
            // Only accept events from the controlling connection
            if self.currentConnection === connection || 
               self.currentConnection?.connectedHost?.identifier == host.identifier {
                self.eventsController?.postEvent(withEventData: message.data)
                return true
            }
            return false
        case .audioSyncStartRequest:
            let info = message.infoDict
            if let peerPortVal = info["port"] as? Int {
                let peerPort = UInt16(peerPortVal)
                let clientShareOutput = (info["shareOutput"] as? Bool) ?? false
                let clientShareInput = (info["shareInput"] as? Bool) ?? false
                do {
                    try AudioController.shared.streamManager.startSysListener { localPort in
                        DispatchQueue.main.async {
                            let rawIp = connection.connectedHost?.address ?? "127.0.0.1"
                            var ipAddress = rawIp
                            if rawIp.lowercased().hasPrefix("fe80"), let interface = connection.networkInterfaceName {
                                ipAddress = "\(rawIp)%\(interface)"
                            }
                            
                            // Start sync as HOST role
                            AudioController.shared.startAudioSync(
                                peerHostId: host.identifier,
                                peerIp: ipAddress,
                                localUdpPort: localPort,
                                peerUdpPort: peerPort,
                                isHostRole: true,
                                shareOutput: clientShareOutput,
                                shareInput: clientShareInput
                            )
                            
                            // Reply with success
                            let response = Message.create(with: .audioSyncStartSuccess, andInfoDict: [
                                "port": Int(localPort),
                                "shareOutput": clientShareOutput,
                                "shareInput": clientShareInput
                            ])
                            connection.sendMessage(response)
                            NSLog("ServerController: Started audio sync, sent audioSyncStartSuccess. Local: \(localPort), Remote: \(peerPort)")
                        }
                    }
                } catch {
                    NSLog("ServerController: Failed to start audio listener: \(error)")
                }
            }
            return true
        case .audioMicRouteUpdate:
            let info = message.infoDict
            if let targetStr = info["target"] as? String, let target = AudioMicTarget(rawValue: targetStr) {
                AudioController.shared.setMicrophoneTarget(target, notifyPeer: false)
            }
            return true
        case .audioOutputRouteUpdate:
            let info = message.infoDict
            if let enabled = info["enabled"] as? Bool {
                AudioController.shared.setHostSystemCaptureEnabled(enabled)
            }
            return true
        case .audioSyncStopNotification:
            AudioController.shared.stopAudioSync()
            return true
        case .audioHardwareStatusUpdate:
            let info = message.infoDict
            let hasMic = info["hasMic"] as? Bool ?? true
            let hasSpeaker = info["hasSpeaker"] as? Bool ?? true
            if let host = connection.connectedHost as? RemoteHost {
                DispatchQueue.main.async {
                    host.hasMicHardware = hasMic
                    host.hasSpeakerHardware = hasSpeaker
                }
            }
            return true
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
