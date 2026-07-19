// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import IOKit.pwr_mgt
import IOKit

enum ClientState: Int {
    case idleState
    case connectingState
    case controllingState
}

private let HOTBORDER_SAFE_MARGIN = 3

@objcMembers
class ClientController: ConnectionController, EventsListener, DeviceConnectionDelegate {

	static let shared = ClientController()
	
    private var _state: ClientState = .idleState {
        didSet {
            if oldValue != _state {
                NotificationCenter.default.post(
                    name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
                    object: nil
                )
            }
        }
    }
    private var _hotBorders = [String: TPHotBorder]()
    private var _sleepNotifier: io_object_t = 0
    private var _sleepService: io_connect_t = 0
    private var _sleepNotifyPortRef: IONotificationPortRef?
    
    /// Pending control request info for when connection is being established
    private var _pendingControlRequestInfo: [AnyHashable: Any]?
    
    @MainActor
    override init() {
        super.init()
        
        _hotBorders = [:]
        _sleepService = 0
        _state = .idleState
        
		HostDevice.observe(observer: self, selector: #selector(updateTriggers(_:)), object: nil)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(connectionStateDidChange(_:)),
			name: NSNotification.Name("TPConnectionStateDidChangeNotification"),
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(accessibilityStatusDidChange(_:)),
			name: .TPAccessibilityStatusDidChange,
			object: nil
		)
		TPClipboardTransferCoordinator.shared.start()
        
        // Register as delegate with DeviceConnectionManager
        DeviceConnectionManager.shared.addDelegate(self)
	}

    
    @MainActor
    override func currentHotBorder() -> TPHotBorder? {
        guard let currentConnection = self.currentConnection else { return nil }
        guard let host = currentConnection.connectedHost else { return nil }
        
        return _hotBorders[host.identifier]
    }
    
	@MainActor
	private func _updateTriggers(for notifyingHost: RemoteHost, showVisualHint: Bool) {
		// A remote is represented by several transient RemoteHost objects that all share the
		// same key (identifier == computerName): the canonical saved host in HostDevicesManager,
		// which carries the user's desktop placement (`desktopOrigin`), plus throwaway objects
		// created by Bonjour resolution and inbound identification. Those throwaways default
		// `desktopOrigin` to .zero (the remote never encodes *our* local layout of it) yet they
		// still post `.hostDidUpdate`. If we trust the notifying object blindly, a stray
		// origin=.zero host flings the hot border to a wrong screen edge. Always drive the hot
		// border from the canonical known host so placement stays stable.
		let host = HostDevicesManager.shared.host(withIdentifier: notifyingHost.identifier) ?? notifyingHost
		let canControl = MainController.shared().canControlHost(withIdentifier: host.identifier)
		let isOnlineOrControlled = host.isInState(.controlled)
			|| DeviceConnectionManager.shared.isReachableForControl(host)
		let shouldEnableTriggers = canControl && isOnlineOrControlled && AccessibilityManager.isTrusted
		let shouldActivateHotBorder = !host.isInState(.controlled)
		let identifier = host.identifier
		
		debugLog("Trigger: host=\(host.computerName) canControl=\(canControl) online=\(isOnlineOrControlled) wakeable=\(host.wakeable)", module: .control)
		
		var hotBorder = _hotBorders[identifier]
		
		// Hot border
		// NOTE: local host may have multiple screens; the hot border must be clipped by the
		// whole local desktop (union of screens), not a single screen frame.
		let localDesktopFrame = LocalHost.shared.screens.reduce(NSRect.null) { $0.union($1.frame) }
		
		let hasValidRemotePlacement = (host.hostDesktopRect != .zero)

		if let existingHotBorder = hotBorder, hasValidRemotePlacement {
			if shouldEnableTriggers {
				// IMPORTANT: once we allow 1↔N / N↔M mappings, the hot border must be sized from the
				// full remote desktop rect, not just a single remote screen rect.
				existingHotBorder.update(withRepresentingRect: host.adjustedHostDesktopRect, in: localDesktopFrame)
				
				if shouldActivateHotBorder && existingHotBorder.state == .inactiveState {
					existingHotBorder.delayedActivate()
				} else if !shouldActivateHotBorder && existingHotBorder.state != .inactiveState {
					existingHotBorder.deactivate()
				}
			} else {
				existingHotBorder.deactivate()
				self.takeDownHotBorder(existingHotBorder)
				existingHotBorder.close()
				_hotBorders.removeValue(forKey: identifier)
			}
		} else if shouldEnableTriggers {
			if hasValidRemotePlacement {
				hotBorder = TPHotBorder(hostId: host.identifier, contentRect: host.adjustedHostDesktopRect, in: localDesktopFrame)
				hotBorder?.setHotDelegate(self)
				if let hb = hotBorder {
					self.setupHotBorder(hb, forHost: host)
					_hotBorders[identifier] = hb
					
					debugLog("HotBorder created: \(hb)", module: .control)
					
					if shouldActivateHotBorder {
						hb.delayedActivate()
					}
				}
			} else {
				warningLog("Remote placement not ready for host: \(host.computerName)", module: .control)
			}
		}
		
		if showVisualHint && shouldEnableTriggers && shouldActivateHotBorder && DeviceConnectionManager.shared.isReachableForControl(host) && host.previousHostState != .controlled {
			EdgeAppearanceAnimator.shared.showAppearanceAnimation(for: host)
		}
	}
	
	@MainActor
	@objc func updateTriggers(_ notification: Notification) {
		if let host = notification.object as? RemoteHost {
			self._updateTriggers(for: host, showVisualHint: true)
		}
	}

	@MainActor
	@objc private func accessibilityStatusDidChange(_ notification: Notification) {
		self.updateTriggersAndShowVisualHint(false)
	}

	@MainActor
	@objc private func connectionStateDidChange(_ notification: Notification) {
		if let host = notification.object as? RemoteHost {
			if _state == .connectingState,
			   _pendingControlRequestInfo != nil,
			   let connection = DeviceConnectionManager.shared.connection(for: host) {
				fulfillPendingControlRequest(on: connection, for: host)
			}
			self._updateTriggers(for: host, showVisualHint: false)
		} else {
			cancelPendingControlRequest()
			self.updateTriggersAndShowVisualHint(false)
		}
	}
	
	@MainActor
	func updateTriggersAndShowVisualHint(_ showVisualHint: Bool) {
		let hosts = HostDevicesManager.shared.hosts(with: .all)
		for case let host as RemoteHost in hosts {
			self._updateTriggers(for: host, showVisualHint: showVisualHint)
		}
	}
	
	@MainActor
	override func hotBorder(_ hotBorder: TPHotBorder, canFireWithEvent event: NSEvent?) -> Bool {
		if !MainController.shared().canControlHost(withIdentifier: hotBorder.hostId) {
			return false
		}
		
		if let applicationsIgnoringUnimacs = PreferencesManager.shared().value(forPref: APPLICATIONS_DISABLING_UNIMACS) as? [String] {
			if let currentApplicationIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
				for ignoringApp in applicationsIgnoringUnimacs {
					if ignoringApp == currentApplicationIdentifier {
						return false
					}
				}
			}
		}
		
		let remoteHost = HostDevicesManager.shared.host(withIdentifier: hotBorder.hostId)
		let options = remoteHost?.options
		let requireKey = (options?.value(forKey: REQUIRE_KEY) as? NSNumber)?.boolValue ?? false
		let keyTag = (options?.value(forKey: SWITCH_KEY_TAG) as? NSNumber)?.intValue ?? 0
		return EventsController.default().event(event, hasRequiredKeyIfNeeded: requireKey, withTag: NSEvent.EventType(rawValue: UInt(keyTag))!)
	}
	
	@MainActor
	override func hotBorder(_ hotBorder: TPHotBorder, firedAtLocation location: NSPoint) -> Bool {
		guard let remoteHost = HostDevicesManager.shared.host(withIdentifier: hotBorder.hostId) else { return false }
		
		if DeviceConnectionManager.shared.isReachableForControl(remoteHost) {
			// `location` is window-local. Convert it to a point relative to the *local desktop bounding rect*.
			let localDesktopRect = LocalHost.shared.screens.reduce(NSRect.null) { $0.union($1.frame) }
			let localCocoaPoint = hotBorder.screenPoint(fromLocalPoint: location, flipped: false)
			let desktopRelativeLocation = NSPoint(
				x: localCocoaPoint.x - localDesktopRect.minX,
				y: localCocoaPoint.y - localDesktopRect.minY
			)
			
			// Preferred: normalized position within the hot border window.
			let contentSize = hotBorder.frame.size
			let rawRelative = NSPoint(
				x: contentSize.width > 0 ? (location.x / contentSize.width) : 0,
				y: contentSize.height > 0 ? (location.y / contentSize.height) : 0
			)
			let hotBorderRelativePoint = NSPoint(
				x: min(max(rawRelative.x, 0), 1),
				y: min(max(rawRelative.y, 0), 1)
			)
			
			if !self.requestStartControl(on: remoteHost, at: desktopRelativeLocation, hotBorderRelativePoint: hotBorderRelativePoint) {
				hotBorder.activate()
			}
			return super.hotBorder(hotBorder, firedAtLocation: location)
		}
		
		return false
	}
	
	@MainActor
	func requestStartControl(on remoteHost: RemoteHost?, at location: NSPoint, hotBorderRelativePoint: NSPoint?) -> Bool {
		guard let remoteHost else {
			warningLog("requestStartControl blocked: nil host", module: .control)
			return false
		}
		guard DeviceConnectionManager.shared.isReachableForControl(remoteHost) else {
			warningLog("requestStartControl blocked: \(remoteHost.computerName) not reachable for control (state=\(remoteHost.hostState.rawValue), screens=\(remoteHost.screens.count))", module: .control)
			return false
		}
		guard _state == .idleState else {
			if _state == .connectingState,
			   let pendingInfo = _pendingControlRequestInfo,
			   let existingConnection = DeviceConnectionManager.shared.connection(for: remoteHost) {
				warningLog("requestStartControl: recovering stuck connectingState for \(remoteHost.computerName)", module: .control)
				_pendingControlRequestInfo = nil
				_state = .idleState
				self.currentConnection = existingConnection
				TPClipboardTransferCoordinator.shared.clientWillRequestStartControl()
				self.sendStartControlRequest(for: existingConnection, withInfoDict: pendingInfo)
				return true
			}
			warningLog("requestStartControl blocked: client state=\(_state.rawValue)", module: .control)
			return false
		}
		
		var infoDict: [AnyHashable: Any] = [
			TPMousePositionKey: NSData.data(with: location)
		]
		if let p = hotBorderRelativePoint {
			infoDict[TPHotBorderRelativePointKey] = NSData.data(with: p)
		}
		
		// Try to use existing connection from DeviceConnectionManager
		if let existingConnection = DeviceConnectionManager.shared.connection(for: remoteHost) {
			self.currentConnection = existingConnection
			TPClipboardTransferCoordinator.shared.clientWillRequestStartControl()
			self.sendStartControlRequest(for: existingConnection, withInfoDict: infoDict)
			return true
		}
		
		// Check if we have a current connection that's still valid
		if let currentConnection = self.currentConnection {
			if currentConnection.isValid(for: remoteHost) {
				TPClipboardTransferCoordinator.shared.clientWillRequestStartControl()
				self.sendStartControlRequest(for: currentConnection, withInfoDict: infoDict)
				return true
			} else {
				self.currentConnection = nil
			}
		}
		
		// Need to establish new connection via DeviceConnectionManager
		_pendingControlRequestInfo = infoDict
		_state = .connectingState
		
		TPClipboardTransferCoordinator.shared.clientWillRequestStartControl()
		DeviceConnectionManager.shared.connect(to: remoteHost)
		
		// Persistent TCP may already exist (connect() is a no-op); send control immediately.
		if let existingConnection = DeviceConnectionManager.shared.connection(for: remoteHost) {
			_pendingControlRequestInfo = nil
			_state = .idleState
			self.currentConnection = existingConnection
			self.sendStartControlRequest(for: existingConnection, withInfoDict: infoDict)
		}
		return true
	}
	
	@MainActor
	private func cancelPendingControlRequest() {
		_pendingControlRequestInfo = nil
		if _state == .connectingState {
			_state = .idleState
		}
	}
	
	@MainActor
	private func fulfillPendingControlRequest(on connection: NetworkConnection, for host: RemoteHost) {
		guard let infoDict = _pendingControlRequestInfo else { return }
		_pendingControlRequestInfo = nil
		_state = .idleState
		self.currentConnection = connection
		self.sendStartControlRequest(for: connection, withInfoDict: infoDict)
	}
	
	func sendStartControlRequest(for connection: NetworkConnection, withInfoDict infoDict: [AnyHashable: Any]) {
		guard let controlledHost = connection.connectedHost else {
			warningLog("sendStartControlRequest blocked: connection has no connectedHost", module: .control)
			return
		}
		
		let mousePosition = (infoDict[TPMousePositionKey] as? NSData)?.pointValue ?? .zero
		
		self.currentConnection = connection
		
		// The client desktop can span multiple screens (e.g. vertical stacked displays).
		// Use the full desktop bounding rect so the return hot border can also span screens.
		let clientDesktopRect = LocalHost.shared.screens.reduce(NSRect.null) { $0.union($1.frame) }
		
		// When the border spans multiple local screens, we must glue the remote host rect to the
		// *actual* screen the cursor used to enter, otherwise the placement will be shifted and the
		// cursor may come back on a wrong screen.
		let entryCocoaPoint = NSPoint(
			x: clientDesktopRect.minX + mousePosition.x,
			y: clientDesktopRect.minY + mousePosition.y
		)
		let entryLocalScreenIndex = LocalHost.shared.screenIndex(containing: entryCocoaPoint) ?? 0
		let serverDesktopRect = controlledHost.adjustedHostDesktopRect(gluedToLocalScreenIndex: entryLocalScreenIndex)
		
		var screenPlacement = clientDesktopRect
		screenPlacement.origin.x -= serverDesktopRect.minX
		screenPlacement.origin.y -= serverDesktopRect.minY
		
		let clientOptions = self._clientOptions(for: controlledHost)
		let hotBorderRelativePoint = (infoDict[TPHotBorderRelativePointKey] as? NSData)?.pointValue
		let message = Message.controlRequestMessage(
			screenPlacement: screenPlacement,
			mousePosition: mousePosition,
			hotBorderRelativePoint: hotBorderRelativePoint,
			options: clientOptions)
		// Fire and forget - control request doesn't need to block
		self.currentConnection?.sendAsync(message)
	}
	
	@MainActor
	func startControl() {
		guard let currentConnection = self.currentConnection, let controlledHost = currentConnection.connectedHost else { return }
		
		StatusItemController.default.update(with: .controlling, host: controlledHost)
		controlledHost.hostState = .controlled
		self.updateTriggersAndShowVisualHint(false)
		
		if !PreferencesManager.shared().bool(forPref: HIDE_CONTROL_BEZEL) {
			BezelController.default().setMode(.controlling(host: controlledHost, emergencyHint: "⌃⌥⇧⎋ to release"))
		}
		
		if PreferencesManager.shared().bool(forPref: PLAY_SWITCH_SOUND) {
			SoundUtils.playSwitchSound()
		}

		self.updateEventsController()
		if let ec = self.eventsController {
			if !ec.startGettingEvents(for: self) {
				warningLog("startGettingEvents failed, stopping control", module: .control)
				self.stopControl()
				return
			}
		} else {
			warningLog("No events controller available, stopping control", module: .control)
			self.stopControl()
			return
		}
		TPClipboardTransferCoordinator.shared.clientDidStartControl(using: currentConnection, remoteHost: controlledHost)
		
		DisplaySleepAssertion.activate(reason: "startControl")
		
		_state = .controllingState
	}
	
	private func _clientOptions(for remoteHost: RemoteHost) -> [String: Any] {
		let optionKeys = [
			REQUIRE_KEY,
			SWITCH_KEY_TAG
		]
		
		var clientOptions = [String: Any]()
		let hostOptions = remoteHost.options
		
		for optionKey in optionKeys {
			var value = hostOptions.value(forKey: optionKey)
			
			if optionKey == REQUIRE_KEY {
				if !PreferencesManager.shared().bool(forPref: SYNC_MODIFIERS) {
					value = false
				}
			}
			
			if let val = value {
				clientOptions[optionKey] = val
			}
		}
		
		return clientOptions
	}
	
	@MainActor
	func requestedStopControl(withInfoDict infoDict: [AnyHashable: Any]) {
		guard let currentConnection = self.currentConnection, let controlledHost = currentConnection.connectedHost else { return }
		
        if let isSwitch = infoDict[TPSwitchControlKey] as? Bool, isSwitch {
            debugLog("Stopping control due to SwitchControl request from remote host: \(controlledHost.computerName)", module: .control)
        }
        
		// Fire and forget - control stop doesn't need to block
		currentConnection.sendAsync(Message.create(with: .controlStop))
		
		let eventsController = self.eventsController
		self.stopControl(withDisconnect: DISCONNECT_WHEN_STOP_CONTROL)
		
		if let relativeValue = infoDict[TPHotBorderRelativePointKey] as? NSData,
			let hotBorder = _hotBorders[controlledHost.identifier] {
			// Preferred: normalized within the hot border window.
			let rel = relativeValue.pointValue
			let contentSize = hotBorder.frame.size
			let localPoint = NSPoint(x: rel.x * contentSize.width, y: rel.y * contentSize.height)
			let warpedPoint = hotBorder.screenPoint(fromLocalPoint: localPoint, flipped: true)
			
			if hotBorder.state != .inactiveState {
				hotBorder.deactivate()
				eventsController?.warpMouse(toPosition: warpedPoint)
				hotBorder.delayedActivate()
			} else {
				eventsController?.warpMouse(toPosition: warpedPoint)
			}
		} else if let mouseValue = infoDict[TPMousePositionKey] as? NSData {
			// Fallback (legacy): `TPMousePositionKey` is relative to the *local desktop bounding rect*.
			let localDesktopRect = LocalHost.shared.screens.reduce(NSRect.null) { $0.union($1.frame) }
			let desktopRelative = mouseValue.pointValue
			let localCocoaPoint = NSPoint(
				x: localDesktopRect.minX + desktopRelative.x,
				y: localDesktopRect.minY + desktopRelative.y
			)
			let mainMaxY = NSScreen.primaryScreenFrame.maxY
			let warpedPoint = NSPoint(
				x: localCocoaPoint.x,
				y: mainMaxY - localCocoaPoint.y
			)
			
			if let hotBorder = _hotBorders[controlledHost.identifier], hotBorder.state != .inactiveState {
				hotBorder.deactivate()
				eventsController?.warpMouse(toPosition: warpedPoint)
				hotBorder.delayedActivate()
			} else {
				eventsController?.warpMouse(toPosition: warpedPoint)
			}
		}
	}
	
	override func stopControl() {
		super.stopControl()
		self.eventsController?.cleanupGettingEvents()
	}
	
	@MainActor
	override func stopControl(withDisconnect disconnect: Bool) {
		let wasControlling = _state == .controllingState
		if wasControlling {
			TPClipboardTransferCoordinator.shared.clientDidStopControl()
			MainController.shared().leaveFrontmost()
			BezelController.default().setMode(.hidden)
			StatusItemController.default.update(with: .idle, host: nil)
			self.currentConnection?.connectedHost?.hostState = .peeredOnline
			DisplaySleepAssertion.deactivate()
			
			if PreferencesManager.shared().bool(forPref: PLAY_SWITCH_SOUND) {
				SoundUtils.playSwitchSound()
			}
		}
		
		cancelPendingControlRequest()
		_state = .idleState
		self.updateTriggersAndShowVisualHint(false)
		if wasControlling {
			self.eventsController?.cleanupGettingEvents()
		}
		super.stopControl(withDisconnect: disconnect)
	}
	
	var isControlling: Bool {
		return _state == .controllingState
	}
	
	/// True while waiting for TCP and/or a controlSuccess after the user triggered a hot border.
	var isWaitingForControlAttempt: Bool {
		return _state == .connectingState || _pendingControlRequestInfo != nil
	}
	
	func gotEvent(withEventData eventData: Data) {
		// Events are produced inside the CGEventTap callback on the main run loop. Send them
		// through the ordered, non-blocking path so a slow/saturated control socket (e.g. while a
		// large clipboard transfer is in flight) can never stall input capture or the main run
		// loop. Ordering is still guaranteed by the single serial send queue.
		self.currentConnection?.sendAsync(Message.create(with: .event, andData: eventData))
	}
	
	@MainActor
	func gotEmergencyStopEvent() {
		if let currentConnection = self.currentConnection {
			currentConnection.sendAsync(Message.create(with: .controlStop))
		}
		self.stopControl()
	}
	
	@MainActor
	func gotEmergencyStopProgress(count: Int) {
		if count < 3 {
			BezelController.default().setMode(.emergency(
				title: "Emergency Stop",
				subtitle: "Releasing... (\(count)/3)",
				count: count,
				maxCount: 3
			))
		} else if count < 10 {
			BezelController.default().setMode(.emergency(
				title: "Force Quit App",
				subtitle: "Terminating... (\(count - 3)/7)",
				count: count - 3,
				maxCount: 7
			))
		}
	}
	
	
    // MARK: - DeviceConnectionDelegate
    
    @MainActor
    func connectionDidEstablish(to host: RemoteHost, connection: NetworkConnection) {
        // Only honor a pending control request from an explicit user-initiated attempt.
        if _state == .connectingState, _pendingControlRequestInfo != nil {
            fulfillPendingControlRequest(on: connection, for: host)
        }
		
		self._updateTriggers(for: host, showVisualHint: true)
        
        // Start Audio Sync Negotiation
        if (host.shareOutput || host.shareInput) && host.hasCapability(.audioSync) {
            do {
                try AudioController.shared.streamManager.startMicListener { localUdpPort in
                    DispatchQueue.main.async {
                        let infoDict: [AnyHashable: Any] = [
                            "port": Int(localUdpPort),
                            "shareOutput": host.shareOutput,
                            "shareInput": host.shareInput
                        ]
                        let message = Message.create(with: .audioSyncStartRequest, andInfoDict: infoDict)
                        connection.sendMessage(message)
                        NSLog("ClientController: Sent audioSyncStartRequest on port \(localUdpPort) with shareOutput=\(host.shareOutput), shareInput=\(host.shareInput)")
                    }
                }
            } catch {
                NSLog("ClientController: Failed to start audio listener: \(error)")
            }
        }
    }
    
    @MainActor
    func connectionDidDisconnect(from host: RemoteHost) {
        // If this was our current connection, handle disconnection
        if let currentHost = self.currentConnection?.connectedHost,
           currentHost.identifier == host.identifier {
            if _state == .controllingState {
                self.stopControl(withDisconnect: false)
            }
            self.currentConnection = nil
        }
        
        cancelPendingControlRequest()
        AudioController.shared.stopAudioSync()
    }
    
    @MainActor
    func connectionDidFail(to host: RemoteHost) {
        guard _state == .connectingState else { return }
        // Connection attempts can fail repeatedly (e.g. an offline host "reached" over a tunnel
        // that fakes a TCP handshake, then drops). A modal alert here is far too disruptive, so
        // just clear the in-flight control attempt and refresh triggers silently.
        warningLog("Connection to \(host.computerName) failed; clearing pending control attempt", module: .control)
        cancelPendingControlRequest()
        self.updateTriggersAndShowVisualHint(false)
    }
    
    /// Clear an in-flight control attempt without tearing down persistent TCP connections.
    @MainActor
    func cancelControlAttempt() {
        cancelPendingControlRequest()
    }
    
    @MainActor
    private func shouldHandleControlMessage(from host: RemoteHost, on connection: NetworkConnection) -> Bool {
        if self.currentConnection === connection {
            return true
        }
        if self.currentConnection?.connectedHost?.identifier == host.identifier {
            return true
        }
        if DeviceConnectionManager.shared.managesConnection(connection),
           connection.connectedHost?.identifier == host.identifier {
            return true
        }
        return false
    }

    @MainActor
    func handleMessage(_ message: Message, from host: RemoteHost, connection: NetworkConnection) -> Bool {
        switch message.msgType {
        case .controlSuccess:
            guard shouldHandleControlMessage(from: host, on: connection) else { return false }
            self.currentConnection = connection
            self.startControl()
            return true
        case .controlFailure:
            guard shouldHandleControlMessage(from: host, on: connection) else { return false }
            _state = .idleState
            if let controlledHost = connection.connectedHost {
                controlledHost.hostState = .shared
                controlledHost.lastError = NSLocalizedString("Control rejected: The host may have removed this Mac from its trusted list.", comment: "")
            }
            return true
        case .controlStop:
            // Only the controlling side may consume controlStop. On a machine that is *being
            // controlled* (server role), the idle client delegate must not swallow this message,
            // otherwise ServerController never receives it and stays stuck in .controlled
            // (leaving the menu-bar icon stuck on "active").
            guard _state == .controllingState, self.currentConnection === connection else {
                return false
            }
            self.requestedStopControl(withInfoDict: message.infoDict)
            return true
        case .audioSyncStartSuccess:
            let info = message.infoDict
            if let peerPortVal = info["port"] as? Int {
                let peerPort = UInt16(peerPortVal)
                let localPort = AudioController.shared.streamManager.sysLocalPort
                let rawIp = connection.connectedHost?.address ?? "127.0.0.1"
                var ipAddress = rawIp
                if rawIp.lowercased().hasPrefix("fe80"), let interface = connection.networkInterfaceName {
                    ipAddress = "\(rawIp)%\(interface)"
                }
                
                AudioController.shared.startAudioSync(
                    peerHostId: host.identifier,
                    peerIp: ipAddress,
                    localUdpPort: localPort,
                    peerUdpPort: peerPort,
                    isHostRole: false,
                    shareOutput: host.shareOutput,
                    shareInput: host.shareInput
                )
                NSLog("ClientController: Audio sync fully established. Local: \(localPort), Remote: \(peerPort) on \(ipAddress)")
            }
            return true
        case .audioMicRouteUpdate:
            let info = message.infoDict
            if let targetStr = info["target"] as? String, let target = AudioMicTarget(rawValue: targetStr) {
                AudioController.shared.setMicrophoneTarget(target, notifyPeer: false)
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
                    let oldMic = host.hasMicHardware
                    debugLog("ClientController: Received audioHardwareStatusUpdate from \(host.computerName): hasMic=\(hasMic) (was \(oldMic)), hasSpeaker=\(hasSpeaker), shareInput=\(host.shareInput)", module: .network)
                    host.hasMicHardware = hasMic
                    host.hasSpeakerHardware = hasSpeaker
                    if (!oldMic && hasMic && host.shareInput) || (oldMic && !hasMic) {
                        self.updateAudioSharingState(for: host)
                    }
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
    
    @MainActor
    func updateAudioSharingState(for host: RemoteHost) {
        guard let connection = DeviceConnectionManager.shared.connection(for: host) else {
            return
        }
        
        let shareOutput = host.shareOutput
        let shareInput = host.shareInput
        
        if !shareOutput && !shareInput {
            if AudioController.shared.isSyncActive {
                let msg = Message.create(with: .audioSyncStopNotification, andInfoDict: [:])
                _ = connection.sendMessage(msg)
                AudioController.shared.stopAudioSync()
                NSLog("ClientController: Stopped audio sync because both sharing options were disabled.")
            }
        } else {
            if !AudioController.shared.isSyncActive {
                do {
                    try AudioController.shared.streamManager.startMicListener { localUdpPort in
                        DispatchQueue.main.async {
                            let infoDict: [AnyHashable: Any] = [
                                "port": Int(localUdpPort),
                                "shareOutput": shareOutput,
                                "shareInput": shareInput
                            ]
                            let message = Message.create(with: .audioSyncStartRequest, andInfoDict: infoDict)
                            connection.sendMessage(message)
                            NSLog("ClientController: Sent audioSyncStartRequest dynamically on port \(localUdpPort)")
                        }
                    }
                } catch {
                    NSLog("ClientController: Failed to start audio listener dynamically: \(error)")
                }
            } else {
                AudioController.shared.setShareOutputEnabled(shareOutput)
                let micTarget: AudioMicTarget = shareInput ? .remote : .local
                AudioController.shared.setMicrophoneTarget(micTarget, notifyPeer: true)
            }
        }
    }
}
