// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

@objcMembers
final class TPHotBorderView: NSView {
	
	static let debugHotBorder = true
	
	static let highlightColor: NSColor = .systemRed
	static let visibleColor: NSColor = .systemBlue
	static let transparentColor: NSColor = .clear
	
	static let animationTime: TimeInterval = 2.0
	static let animationInterval: TimeInterval = 0.02
	
	static var normalColor: NSColor = {
		if TPHotBorderView.debugHotBorder || TPPreferencesManager.shared().bool(forPref: Settings.visibleBordersKey) {
			return TPHotBorderView.visibleColor
		} else {
			return TPHotBorderView.transparentColor
		}
	}()
	
	// MARK: - Properties
	
	// Timer using the modern Swift type
	private var animationTimer: Timer? = nil
	
	var color: NSColor
	
	// Tracks the start time for animation progress calculation
	private var animationStartTime: Date?
	
	override init(frame frameRect: NSRect) {
		self.color = Self.normalColor
		super.init(frame: frameRect)
		self.wantsLayer = true
	}
	
	required init?(coder: NSCoder) {
		self.color = Self.normalColor
		super.init(coder: coder)
		self.wantsLayer = true
	}
		
	func fire() {
		stopAnimation()
		
		let now = Date()
		self.animationStartTime = now
		
		// Use the modern Timer API with a block, which is cleaner and safer
		// NSView subclasses are implicitly @MainActor, so we can use MainActor.assumeIsolated
		self.animationTimer = Timer.scheduledTimer(withTimeInterval: Self.animationInterval, repeats: true) { [weak self] _ in
			guard let self else { return }
			MainActor.assumeIsolated {
				self.animationStep()
			}
		}
		
		// Ensure the timer is monitored by the common run loop modes (important for UI updates)
		RunLoop.current.add(self.animationTimer!, forMode: .common)
	}
	
	func stopAnimation() {
		animationTimer?.invalidate()
		animationTimer = nil
		animationStartTime = nil
		
		self.color = Self.normalColor
		
		// The original code had `[self window]`, possibly to force a window-level update.
		// let _ = window
	}
	
	private func animationStep() {
	
		guard let start = animationStartTime else {
			stopAnimation()
			return
		}
		
		let elapsed = -start.timeIntervalSinceNow
		let progress = elapsed / Self.animationTime
		
		if progress >= 1.0 {
			stopAnimation()
		} else {
			// Use the modern Swift method for color blending
			if let blendedColor = Self.highlightColor.blended(withFraction: progress, of: Self.normalColor) {
				self.color = blendedColor
			} else {
				stopAnimation()
			}
		}
	}

	override func draw(_ dirtyRect: NSRect) {
		super.draw(dirtyRect)
		
		color.setFill()
		dirtyRect.fill()
	}
}
