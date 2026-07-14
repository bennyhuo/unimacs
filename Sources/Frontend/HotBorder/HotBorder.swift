// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import AppKit


let BORDER_SIZE: CGFloat = 4.0

/// A hot border is now a pure geometry/state model. Detection is driven entirely
/// by `HotBorderMonitor` (cursor-position based), so this type no longer needs to
/// be an `NSWindow` and never receives AppKit mouse events.
///
/// The visible debug decoration (blue range bar + red fire flash) lives in an
/// optional, purely-cosmetic `HotBorderOverlay` that is only created while the
/// `visibleBorders` preference is on. With the toggle off, no window is created
/// at all and the border is invisible while still fully functional.
@MainActor
@objcMembers
final class TPHotBorder: NSObject {

	@objc(TPHotBorderState)
	enum State: Int {
		case inactiveState
		case activatingState
		case activeState
	}

	/// Which cursor feed is allowed to fire this border (see `HotBorderMonitor`).
	@objc(TPHotBorderKind)
	enum Kind: Int {
		/// Fired by the local real cursor to start controlling a remote.
		case trigger
		/// Fired by the injected virtual cursor to return control to the controller.
		case control
	}

	private var _state: State = .inactiveState
	private weak var _hotDelegate: TPHotBorderDelegate?
	private var _side: TPSide = []

	/// Optional cosmetic overlay; non-nil only when `visibleBorders` is enabled.
	private var overlay: HotBorderOverlay?

	/// The hot rect in Cocoa global (bottom-left origin) coordinates.
	private(set) var frame: NSRect = .zero

	var hostId: String
	let kind: Kind
	var firedByRealCursor: Bool = false

	static func createWith(hostId: String, contentRect: NSRect, in parentRect: NSRect, kind: Kind = .trigger) -> TPHotBorder {
		return TPHotBorder(hostId: hostId, contentRect: contentRect, in: parentRect, kind: kind)
	}

	static func hotRect(withRepresentingRect representedRect: NSRect, in parentRect: NSRect) -> NSRect {
		let enlargedRect = representedRect.insetBy(dx: -BORDER_SIZE, dy: -BORDER_SIZE)
		let hotRect = parentRect.intersection(enlargedRect)
		return hotRect
	}

	init(hostId: String, contentRect: NSRect, in parentRect: NSRect, kind: Kind = .trigger) {
		self.hostId = hostId
		self.kind = kind
		super.init()

		self.update(withRepresentingRect: contentRect, in: parentRect)

		// Detection is geometric (see HotBorderMonitor); no window/tracking-rect
		// events are involved.
		HotBorderMonitor.shared.register(self)
	}

	func close() {
		HotBorderMonitor.shared.unregister(self)
		overlay?.close()
		overlay = nil
	}

	func update(withRepresentingRect representedRect: NSRect, in parentRect: NSRect) {
		let hotRect = TPHotBorder.hotRect(withRepresentingRect: representedRect, in: parentRect)
		_side = TPGluedRect(parentRect, representedRect, excluding: []).side
		frame = hotRect

		syncOverlay()
	}

	func activate() {
		// If the cursor is still sitting inside the border, defer activation so we
		// don't immediately re-fire after a warp; retry once it has left.
		if frame.contains(NSEvent.mouseLocation) {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
				self?.activate()
			}
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

	var hotRect: NSRect {
		return frame
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
		// frame directly.
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

	@discardableResult
	private func _fireAttempt(at location: NSPoint, isRealCursor: Bool) -> Bool {
		guard _state == .activeState, let delegate = _hotDelegate else {
			return false
		}

		if !delegate.hotBorder(self, canFireWithEvent: nil) {
			return false
		}

		self.firedByRealCursor = isRealCursor
		self.fire(at: location)
		return true
	}

	/// Geometric entry test driven by `HotBorderMonitor`. Fires when the cursor
	/// (in Cocoa global coordinates) is inside the border and no buttons are
	/// pressed.
	/// - Returns: whether the border actually fired.
	@discardableResult
	func fireIfEntered(atGlobalPoint point: NSPoint, isRealCursor: Bool) -> Bool {
		guard _state == .activeState else { return false }
		guard NSEvent.pressedMouseButtons == 0 else { return false }
		guard frameContainsInclusive(point) else { return false }

		let localPoint = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)
		return self._fireAttempt(at: localPoint, isRealCursor: isRealCursor)
	}

	/// `NSRect.contains` treats the *max* edges (maxX / maxY) as exclusive, but a
	/// return hot border is a thin strip glued to the screen's outer edge whose
	/// `frame.maxY` (top) / `frame.maxX` (right) coincides with the desktop
	/// boundary. The injected virtual cursor, when flicked quickly past the edge,
	/// gets clamped exactly onto that boundary, so an exclusive test would miss a
	/// fast move to the extreme edge while a slow move that stops a pixel short
	/// fires fine. Treat the max edges as inclusive so the extreme edge is covered.
	private func frameContainsInclusive(_ point: NSPoint) -> Bool {
		return point.x >= frame.minX && point.x <= frame.maxX
			&& point.y >= frame.minY && point.y <= frame.maxY
	}

	func fire(at location: NSPoint) {
		guard let delegate = _hotDelegate else {
			return
		}

		self.deactivate()

		let doFireAnimation = delegate.hotBorder(self, firedAtLocation: location)

		if doFireAnimation {
			overlay?.fire()
		}
		// Control is handing off to the peer; fade the glow out gracefully
		// rather than letting it snap off when the cursor leaves this screen.
		overlay?.playDismiss()
	}

	/// Feed the cursor position so the overlay can reveal itself as the cursor
	/// approaches. No-op when the overlay is disabled.
	func updateProximity(toGlobalPoint point: NSPoint) {
		guard let overlay else { return }
		let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
		let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
		overlay.setProximity(distance: hypot(dx, dy))
	}

	// MARK: - Cosmetic overlay

	/// Create/update/destroy the cosmetic overlay to match the `visibleBorders`
	/// preference. Re-evaluated on every `update(...)` so toggling the setting
	/// takes effect the next time triggers are rebuilt (which happens on host /
	/// connection changes), without leaking windows.
	private func syncOverlay() {
		let wantsVisual = TPPreferencesManager.shared().bool(forPref: Settings.visibleBordersKey)
		if wantsVisual {
			if let overlay {
				overlay.update(frame: frame, side: _side)
			} else {
				overlay = HotBorderOverlay(frame: frame, side: _side)
			}
		} else if overlay != nil {
			overlay?.close()
			overlay = nil
		}
	}

	override var description: String {
		"Border(\(self.hostId): frame=\(self.frame)"
	}
}

@MainActor
@objc protocol TPHotBorderDelegate: NSObjectProtocol {
	@objc func hotBorder(_ hotBorder: TPHotBorder, canFireWithEvent event: NSEvent?) -> Bool
	@objc func hotBorder(_ hotBorder: TPHotBorder, firedAtLocation location: NSPoint) -> Bool
}

// MARK: - Hot border visual style

/// User-selectable look for the (debug) hot border decoration.
/// Backed by `Settings.hotBorderStyleKey`.
enum HotBorderVisualStyle: Int32, CaseIterable, Identifiable {
	case glow = 0
	case subtle = 1
	case glass = 2

	var id: Int32 { rawValue }

	var displayName: String {
		switch self {
		case .glow: return "Glow"
		case .subtle: return "Subtle"
		case .glass: return "Glass"
		}
	}

	var description: String {
		switch self {
		case .glow: return "Edge glow with a springy bloom on activation."
		case .subtle: return "Faint feathered light that only gently brightens."
		case .glass: return "Frosted glass bar with a specular edge and light sweep."
		}
	}

	static var current: HotBorderVisualStyle {
		HotBorderVisualStyle(rawValue: TPPreferencesManager.shared().int(forPref: Settings.hotBorderStyleKey)) ?? .glow
	}
}

// MARK: - Hot border overlay (debug visualization only)

/// A borderless, click-through window that draws the hot border so it can be
/// seen during development. It carries no detection logic — purely cosmetic.
///
/// The window is sized to bloom *inward* from the screen edge so the glow has
/// room to feather; detection geometry is unaffected (it lives entirely in
/// `TPHotBorder` / `HotBorderMonitor`).
@MainActor
final class HotBorderOverlay {

	private let window: NSWindow
	private let effectView: HotBorderEffectView

	init(frame: NSRect, side: TPSide) {
		let visualFrame = HotBorderOverlay.visualFrame(for: frame, side: side)
		effectView = HotBorderEffectView(frame: NSRect(origin: .zero, size: visualFrame.size))

		window = NSWindow(contentRect: visualFrame, styleMask: .borderless, backing: .buffered, defer: false)
		window.alphaValue = 1.0
		window.isOpaque = false
		window.hasShadow = false
		window.level = .maxLevel
		window.backgroundColor = .clear
		window.isReleasedWhenClosed = false
		window.ignoresMouseEvents = true
		window.collectionBehavior = [.canJoinAllSpaces, .stationary]
		window.contentView = effectView
		effectView.configure(side: side)
		window.orderFront(nil)
	}

	func update(frame: NSRect, side: TPSide) {
		let visualFrame = HotBorderOverlay.visualFrame(for: frame, side: side)
		window.setFrame(visualFrame, display: true)
		effectView.configure(side: side)
	}

	func fire() {
		effectView.fire()
	}

	func setProximity(distance: CGFloat) {
		effectView.setProximity(distance: distance)
	}

	func playDismiss() {
		effectView.playDismiss()
	}

	func close() {
		window.orderOut(nil)
		window.close()
	}

	/// Expand the (thin) detection rect inward from the screen edge so the glow
	/// has depth to fade across, anchored to the outermost edge.
	static func visualFrame(for frame: NSRect, side: TPSide) -> NSRect {
		let depth = HotBorderEffectView.preferredDepth()
		if side.contains(.right) && !side.contains(.left) {
			let d = max(depth, frame.width)
			return NSRect(x: frame.maxX - d, y: frame.minY, width: d, height: frame.height)
		} else if side.contains(.left) && !side.contains(.right) {
			let d = max(depth, frame.width)
			return NSRect(x: frame.minX, y: frame.minY, width: d, height: frame.height)
		} else if side.contains(.top) && !side.contains(.bottom) {
			let d = max(depth, frame.height)
			return NSRect(x: frame.minX, y: frame.maxY - d, width: frame.width, height: d)
		} else if side.contains(.bottom) && !side.contains(.top) {
			let d = max(depth, frame.height)
			return NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: d)
		}
		return frame
	}
}

// MARK: - Hot border effect view

/// Layer-backed renderer for the hot border. Draws one of the
/// `HotBorderVisualStyle` looks (accent-tinted) and animates a Core-Animation
/// driven "fire" effect when the border activates. Purely cosmetic.
@MainActor
final class HotBorderEffectView: NSView {

	private var side: TPSide = []
	private var style: HotBorderVisualStyle = .glow

	private let gradientLayer = CAGradientLayer()
	private let edgeLineLayer = CALayer()

	private var hasConfigured = false
	/// While dismissing (control handed off to the peer), ignore proximity/reset
	/// so the fade-out plays through instead of snapping.
	private var isDismissing = false

	/// How far the overlay window blooms inward from the screen edge, per style.
	static func preferredDepth() -> CGFloat {
		switch HotBorderVisualStyle.current {
		case .glow: return 10
		case .subtle: return 7
		case .glass: return 14
		}
	}

	/// Reveal mapping: at rest (cursor far) the border is nearly invisible to
	/// avoid distraction; it fades in as the cursor approaches within `revealRadius`.
	private let revealRadius: CGFloat = 150

	private var restAlpha: CGFloat {
		switch style {
		case .glow: return 0.07
		case .subtle: return 0.0
		case .glass: return 0.05
		}
	}

	private var revealAlpha: CGFloat {
		switch style {
		case .glow: return 0.75
		case .subtle: return 0.55
		case .glass: return 0.7
		}
	}

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.masksToBounds = false
		gradientLayer.masksToBounds = false
		layer?.addSublayer(gradientLayer)
		layer?.addSublayer(edgeLineLayer)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func configure(side: TPSide) {
		self.side = side
		self.style = HotBorderVisualStyle.current
		applyStyle()
		layoutLayers()
		// Only seed the resting opacity once; afterwards the proximity feed owns
		// it, so a layout/side refresh during handoff doesn't snap the glow off.
		if !hasConfigured {
			setOpacity(restAlpha)
			hasConfigured = true
		}
	}

	/// Drive the resting visibility from the cursor's distance to the border.
	/// Far away → `restAlpha` (inconspicuous); at the edge → `revealAlpha`.
	func setProximity(distance: CGFloat) {
		guard !isDismissing else { return }
		let t = max(0, min(1, 1 - distance / revealRadius))
		let eased = t * t  // bias toward "only reveal when genuinely close"
		setOpacity(restAlpha + (revealAlpha - restAlpha) * eased)
	}

	/// Play a graceful fade-out when control crosses to the peer, instead of the
	/// glow snapping off the moment the cursor leaves / the host turns controlled.
	func playDismiss() {
		isDismissing = true
		let current = layer?.presentation()?.opacity ?? layer?.opacity ?? Float(revealAlpha)
		// Land the model value at 0 first so the end state holds *without* a
		// forwards-filled animation pinning the layer (which would otherwise stop
		// the glow from ever revealing again).
		setOpacity(0)
		let fade = CABasicAnimation(keyPath: "opacity")
		fade.fromValue = current
		fade.toValue = 0.0
		fade.duration = 0.45
		fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
		layer?.add(fade, forKey: "dismiss")
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
			self?.isDismissing = false
		}
	}

	private func setOpacity(_ value: CGFloat) {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		layer?.removeAnimation(forKey: "dismiss")
		layer?.opacity = Float(value)
		CATransaction.commit()
	}

	override func layout() {
		super.layout()
		layoutLayers()
	}

	// MARK: Appearance

	/// Neutral, window-standard tint that adapts to light/dark (no accent blue).
	private var tint: NSColor { NSColor.labelColor }

	/// Resolve a dynamic color against the overlay's appearance, so light/dark
	/// render correctly even though we assign CGColors outside a draw cycle.
	private func cg(_ color: NSColor) -> CGColor {
		var resolved = color.cgColor
		effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
		return resolved
	}

	private func applyStyle() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		defer { CATransaction.commit() }

		gradientLayer.startPoint = gradientStart
		gradientLayer.endPoint = gradientEnd
		gradientLayer.filters = nil
		edgeLineLayer.isHidden = false

		switch style {
		case .glow:
			// Neutral edge glow: brightest hairline at the edge, feathering inward.
			gradientLayer.colors = [
				cg(tint.withAlphaComponent(0.55)),
				cg(tint.withAlphaComponent(0.30)),
				cg(tint.withAlphaComponent(0.0))
			]
			gradientLayer.locations = [0.0, 0.30, 1.0]
			edgeLineLayer.backgroundColor = cg(tint.withAlphaComponent(0.7))
		case .subtle:
			gradientLayer.colors = [
				cg(tint.withAlphaComponent(0.45)),
				cg(tint.withAlphaComponent(0.0))
			]
			gradientLayer.locations = [0.0, 1.0]
			edgeLineLayer.backgroundColor = cg(tint.withAlphaComponent(0.45))
		case .glass:
			gradientLayer.colors = [
				cg(tint.withAlphaComponent(0.5)),
				cg(tint.withAlphaComponent(0.28)),
				cg(tint.withAlphaComponent(0.0))
			]
			gradientLayer.locations = [0.0, 0.4, 1.0]
			edgeLineLayer.backgroundColor = cg(tint.withAlphaComponent(0.6))
			gradientLayer.filters = blurFilter(2.0)
		}
	}

	private func layoutLayers() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		gradientLayer.frame = bounds
		edgeLineLayer.frame = edgeLineFrame
		CATransaction.commit()
	}

	// MARK: Fire

	func fire() {
		let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
		switch style {
		case .glow: fireBloom(color: tint.withAlphaComponent(0.85), blur: 0, duration: 0.5, springy: !reduceMotion, edgePulse: cg(tint.withAlphaComponent(0.95)))
		case .subtle: fireSubtle()
		case .glass:
			fireBloom(color: tint.withAlphaComponent(0.8), blur: 3.0, duration: 0.55, springy: !reduceMotion, edgePulse: cg(tint.withAlphaComponent(0.85)))
			if !reduceMotion { addShimmer() }
		}
	}

	private func fireSubtle() {
		let bloom = makeBloomLayer(color: tint.withAlphaComponent(0.5))
		layer?.addSublayer(bloom)
		bloom.opacity = 0
		let fade = CABasicAnimation(keyPath: "opacity")
		fade.fromValue = 0.6
		fade.toValue = 0.0
		fade.duration = 0.7
		fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
		fade.fillMode = .forwards
		fade.isRemovedOnCompletion = false
		bloom.add(fade, forKey: "fade")
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { bloom.removeFromSuperlayer() }
	}

	private func fireBloom(color: NSColor, blur: CGFloat, duration: TimeInterval, springy: Bool, edgePulse: CGColor) {
		let bloom = makeBloomLayer(color: color)
		if blur > 0 { bloom.filters = blurFilter(blur) }
		layer?.addSublayer(bloom)
		bloom.opacity = 0

		let fade = CABasicAnimation(keyPath: "opacity")
		fade.fromValue = 0.9
		fade.toValue = 0.0
		fade.duration = duration
		fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
		fade.fillMode = .forwards
		fade.isRemovedOnCompletion = false
		bloom.add(fade, forKey: "fade")

		if springy {
			let spring = CASpringAnimation(keyPath: bloomScaleKey)
			spring.fromValue = 0.25
			spring.toValue = 1.0
			spring.damping = 13
			spring.stiffness = 180
			spring.mass = 0.9
			spring.initialVelocity = 6
			spring.duration = spring.settlingDuration
			spring.fillMode = .forwards
			spring.isRemovedOnCompletion = false
			bloom.add(spring, forKey: "bloom")
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { bloom.removeFromSuperlayer() }
		pulseEdgeLine(to: edgePulse, duration: duration)
	}

	private func addShimmer() {
		let shimmer = CAGradientLayer()
		shimmer.frame = bounds
		let horizontal = side.contains(.top) || side.contains(.bottom)
		if horizontal {
			shimmer.startPoint = CGPoint(x: 0, y: 0.5)
			shimmer.endPoint = CGPoint(x: 1, y: 0.5)
		} else {
			shimmer.startPoint = CGPoint(x: 0.5, y: 0)
			shimmer.endPoint = CGPoint(x: 0.5, y: 1)
		}
		let clear = cg(tint.withAlphaComponent(0.0))
		let bright = cg(tint.withAlphaComponent(0.85))
		shimmer.colors = [clear, bright, clear]
		shimmer.locations = [0.0, 0.5, 1.0]
		layer?.addSublayer(shimmer)

		let anim = CABasicAnimation(keyPath: "locations")
		anim.fromValue = [-0.3, -0.15, 0.0]
		anim.toValue = [1.0, 1.15, 1.3]
		anim.duration = 0.7
		anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
		shimmer.add(anim, forKey: "shimmer")
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { shimmer.removeFromSuperlayer() }
	}

	private func pulseEdgeLine(to color: CGColor, duration: TimeInterval) {
		guard !edgeLineLayer.isHidden else { return }
		let base = edgeLineLayer.backgroundColor
		let anim = CABasicAnimation(keyPath: "backgroundColor")
		anim.fromValue = color
		anim.toValue = base
		anim.duration = duration
		anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
		edgeLineLayer.add(anim, forKey: "edgePulse")
	}

	// MARK: Geometry helpers

	private func makeBloomLayer(color: NSColor) -> CAGradientLayer {
		let l = CAGradientLayer()
		l.bounds = CGRect(origin: .zero, size: bounds.size)
		l.anchorPoint = bloomAnchor
		l.position = bloomPosition
		l.startPoint = gradientStart
		l.endPoint = gradientEnd
		l.colors = [cg(color), cg(color.withAlphaComponent(0))]
		l.locations = [0.0, 1.0]
		l.masksToBounds = false
		return l
	}

	private func blurFilter(_ radius: CGFloat) -> [CIFilter] {
		guard let blur = CIFilter(name: "CIGaussianBlur") else { return [] }
		blur.setValue(radius, forKey: kCIInputRadiusKey)
		return [blur]
	}

	private var gradientStart: CGPoint {
		if side.contains(.right) { return CGPoint(x: 1, y: 0.5) }
		if side.contains(.left) { return CGPoint(x: 0, y: 0.5) }
		if side.contains(.top) { return CGPoint(x: 0.5, y: 1) }
		if side.contains(.bottom) { return CGPoint(x: 0.5, y: 0) }
		return CGPoint(x: 0, y: 0.5)
	}

	private var gradientEnd: CGPoint {
		if side.contains(.right) { return CGPoint(x: 0, y: 0.5) }
		if side.contains(.left) { return CGPoint(x: 1, y: 0.5) }
		if side.contains(.top) { return CGPoint(x: 0.5, y: 0) }
		if side.contains(.bottom) { return CGPoint(x: 0.5, y: 1) }
		return CGPoint(x: 1, y: 0.5)
	}

	private var edgeLineFrame: NSRect {
		let w: CGFloat = (style == .glass) ? 1.0 : 1.5
		if side.contains(.right) { return NSRect(x: bounds.maxX - w, y: 0, width: w, height: bounds.height) }
		if side.contains(.left) { return NSRect(x: 0, y: 0, width: w, height: bounds.height) }
		if side.contains(.top) { return NSRect(x: 0, y: bounds.maxY - w, width: bounds.width, height: w) }
		if side.contains(.bottom) { return NSRect(x: 0, y: 0, width: bounds.width, height: w) }
		return .zero
	}

	private var bloomAnchor: CGPoint {
		if side.contains(.right) { return CGPoint(x: 1, y: 0.5) }
		if side.contains(.left) { return CGPoint(x: 0, y: 0.5) }
		if side.contains(.top) { return CGPoint(x: 0.5, y: 1) }
		if side.contains(.bottom) { return CGPoint(x: 0.5, y: 0) }
		return CGPoint(x: 0.5, y: 0.5)
	}

	private var bloomPosition: CGPoint {
		CGPoint(x: bounds.width * bloomAnchor.x, y: bounds.height * bloomAnchor.y)
	}

	private var bloomScaleKey: String {
		let horizontal = side.contains(.top) || side.contains(.bottom)
		return horizontal ? "transform.scale.y" : "transform.scale.x"
	}
}
