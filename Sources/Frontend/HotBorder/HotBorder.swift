// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import AppKit


let BORDER_SIZE: CGFloat = 4.0

@objcMembers
class TPHotBorder: NSWindow, NSWindowDelegate {
	
	@objc(TPHotBorderState)
	enum State: Int {
		case inactiveState
		case activatingState
		case activeState
	}
	
	private var _state: State = .inactiveState
	
	private weak var _hotDelegate: TPHotBorderDelegate?
	private var _trackingRectTag: NSView.TrackingRectTag = -1
	private var _side: TPSide = []
	private var _ignoringEvents: Bool = false

	var hostId: String
	
	static func createWith(hostId: String, contentRect: NSRect, in parentRect: NSRect) -> TPHotBorder {
		return TPHotBorder(hostId: hostId, contentRect: contentRect, in: parentRect)
	}

	static func hotRect(withRepresentingRect representedRect: NSRect, in parentRect: NSRect) -> NSRect {
		let enlargedRect = representedRect.insetBy(dx: -BORDER_SIZE, dy: -BORDER_SIZE)
		let hotRect = parentRect.intersection(enlargedRect)
		return hotRect
	}

	init(hostId: String, contentRect: NSRect, in parentRect: NSRect) {
		self.hostId = hostId
		
		super.init(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
		
		self.alphaValue = 1.0
		self.isOpaque = false
		self.hasShadow = false
		self.level = .maxLevel
		
		self.isReleasedWhenClosed = false
		self.delegate = self
		
		let hotView = TPHotBorderView(frame: .zero)
		self.contentView = hotView
		
		_state = .inactiveState
		_hotDelegate = nil
		_trackingRectTag = -1
		
		self.update(withRepresentingRect: contentRect, in: parentRect)
		
		self.orderFront(self)
		
		self.collectionBehavior = [.canJoinAllSpaces, .stationary]
	}

	func update(withRepresentingRect representedRect: NSRect, in parentRect: NSRect) {
		let hotRect = TPHotBorder.hotRect(withRepresentingRect: representedRect, in: parentRect)
		_side = TPGluedRect(parentRect, representedRect, excluding: []).side

		self.setFrame(hotRect, display: true)
		
		guard let hotView = self.contentView else { return }
		
		if _trackingRectTag != -1 {
			hotView.removeTrackingRect(_trackingRectTag)
		}
		
		_trackingRectTag = hotView.addTrackingRect(hotView.bounds, owner: self, userData: nil, assumeInside: false)
	}

	func activate() {
		if self.mouseLocationOutsideOfEventStream.insetInRect(self.contentView!.bounds) {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: activate)
		} else {
			_state = .activeState
		}
	}

	func deactivate() {
		_state = .inactiveState
	}

	var state: State {
		return _state
	}

	func setHotDelegate(_ delegate: TPHotBorderDelegate?) {
		_hotDelegate = delegate
	}

	func setOpaqueToMouseEvents(_ opaque: Bool) {
		guard let hotView = self.contentView as? TPHotBorderView else { return }
		
		if opaque {
			_ignoringEvents = true
			self.ignoresMouseEvents = false
			hotView.color = NSColor(calibratedWhite: 0.5, alpha: 0.2)
			hotView.display()
		} else {
			_ignoringEvents = false
			self.ignoresMouseEvents = true
			hotView.color = TPHotBorderView.normalColor
			hotView.display()
		}
	}

	var hotRect: NSRect {
		return self.frame
	}

	var side: TPSide {
		return _side
	}

	func delayedActivate() {
		let inhibitionPeriod = TPPreferencesManager.shared().float(forPref: Settings.inhibitionPeriodKey)
		if inhibitionPeriod > 0.0 {
			_state = .activatingState
			Timer.scheduledTimer(timeInterval: TimeInterval(inhibitionPeriod), target: self, selector: #selector(activate), userInfo: nil, repeats: false)
		} else {
			self.activate()
		}
	}

	func screenPoint(fromLocalPoint localPoint: NSPoint, flipped: Bool) -> NSPoint {
		// NOTE: Using `convertPoint(toScreen:)` becomes surprisingly fragile when the border window
		// spans multiple screens. We only need a stable global coordinate, so derive it from the
		// window frame directly.
		var point = NSPoint(x: frame.minX + localPoint.x, y: frame.minY + localPoint.y)
		if flipped {
			// CGEvent global coordinates use the top-left origin of the *primary* (menu bar) screen.
			let mainFrame = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame
				?? NSScreen.main?.frame
				?? NSScreen.screens.first?.frame
			let mainMaxY = mainFrame?.maxY ?? 0
			point.y = mainMaxY - point.y
		}
		return point
	}

	override func mouseDown(with event: NSEvent) {
		super.mouseDown(with: event)
	}

	override func mouseUp(with event: NSEvent) {
		super.mouseUp(with: event)
	}

	private func _fireAttempt(with event: NSEvent?, at location: NSPoint) {
		if _state != .activeState {
			return
		}
		guard let delegate = _hotDelegate else {
			return
		}
		if _ignoringEvents {
			return
		}
		
		let canFire = _hotDelegate?.hotBorder(self, canFireWithEvent: event) ?? true
		if !canFire {
			return
		}
		
		self.fire(at: location)
	}

	override func mouseEntered(with event: NSEvent) {
		let buttonState = NSEvent.pressedMouseButtons
		if buttonState == 0 {
			self._fireAttempt(with: event, at: event.locationInWindow)
		}
	}

	func fire(at location: NSPoint) {
		guard let delegate = _hotDelegate else {
			return
		}
		
		self.deactivate()
		
		let doFireAnimation = delegate.hotBorder(self, firedAtLocation: location)

		if doFireAnimation {
			(self.contentView as? TPHotBorderView)?.fire()
		}
	}
		
	override var description: String {
		"Border(\(self.hostId): frame=\(self.frame)"
	}
}

@objc protocol TPHotBorderDelegate: NSObjectProtocol {
	@objc func hotBorder(_ hotBorder: TPHotBorder, canFireWithEvent event: NSEvent?) -> Bool
	@objc func hotBorder(_ hotBorder: TPHotBorder, firedAtLocation location: NSPoint) -> Bool
}

extension NSPoint {
	func insetInRect(_ rect: NSRect) -> Bool {
		return NSPointInRect(self, rect)
	}
}
