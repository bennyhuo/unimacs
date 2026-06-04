// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  Modern replacement for TPHostAnimationController's appearance animation.

import AppKit

/// Displays a pulsing edge indicator when a remote host comes online.
@MainActor
final class EdgeAppearanceAnimator {
    
    static let shared = EdgeAppearanceAnimator()
    
    private var activeWindows: Set<NSWindow> = []
    
    private init() {}
    
    // MARK: - Configuration
    
    private let borderSize: CGFloat = 8.0
    private let blurRadius: CGFloat = 2.0
    private let inDuration: TimeInterval = 0.5
    private let pulseDuration: TimeInterval = 0.75
    private let outDuration: TimeInterval = 0.5
    private let pulseMinOpacity: CGFloat = 0.25
    
    // MARK: - Public API
    
    func showAppearanceAnimation(for host: TPRemoteHost) {
        let representedRect = host.adjustedHostDesktopRect
        
        // Calculate parent rect from all local screens
        var parentRect = NSRect.zero
        var hasAnyScreen = false
        for screen in TPLocalHost.shared.screens {
            if !hasAnyScreen {
                parentRect = screen.frame
                hasAnyScreen = true
            } else {
                parentRect = parentRect.union(screen.frame)
            }
        }
        
        guard hasAnyScreen else { return }
        
        // Determine which side the host is on
        let side = TPGluedRect(parentRect, representedRect, excluding: []).side
        
        let horizontal = side.contains(.top) || side.contains(.bottom)
        
        // Calculate window frame
        var windowFrame = parentRect.intersection(representedRect.insetBy(dx: -borderSize, dy: -borderSize))
        windowFrame = windowFrame.insetBy(
            dx: horizontal ? -blurRadius : 0,
            dy: horizontal ? 0 : -blurRadius
        )
        
        // Create borderless window
        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)) - 1)
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        
        // Create content view with layer
        let contentView = NSView(frame: NSRect(origin: .zero, size: windowFrame.size))
        contentView.wantsLayer = true
        window.contentView = contentView
        
        guard let rootLayer = contentView.layer else { return }
        
        // Create indicator layer
        let indicatorLayer = CALayer()
        indicatorLayer.backgroundColor = NSColor.systemRed.cgColor
        
        var layerFrame = rootLayer.bounds.insetBy(
            dx: horizontal ? blurRadius : 0,
            dy: horizontal ? 0 : blurRadius
        )
        
        // Offset based on side
        if side.contains(.top) {
            layerFrame.origin.y += blurRadius
        } else if side.contains(.bottom) {
            layerFrame.origin.y -= blurRadius
        } else if side.contains(.left) {
            layerFrame.origin.x -= blurRadius
        } else if side.contains(.right) {
            layerFrame.origin.x += blurRadius
        }
        
        indicatorLayer.frame = layerFrame
        
        // Apply blur filter
        if let blurFilter = CIFilter(name: "CIGaussianBlur") {
            blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
            indicatorLayer.filters = [blurFilter]
        }
        
        rootLayer.addSublayer(indicatorLayer)
        
        activeWindows.insert(window)
        window.orderFront(nil)
        
        // Calculate transform for slide animation
        let slideOffset: CGFloat = borderSize
        let appearTransform: CATransform3D
        if side.contains(.top) {
            appearTransform = CATransform3DMakeTranslation(0, slideOffset, 0)
        } else if side.contains(.bottom) {
            appearTransform = CATransform3DMakeTranslation(0, -slideOffset, 0)
        } else if side.contains(.left) {
            appearTransform = CATransform3DMakeTranslation(-slideOffset, 0, 0)
        } else if side.contains(.right) {
            appearTransform = CATransform3DMakeTranslation(slideOffset, 0, 0)
        } else {
            appearTransform = CATransform3DIdentity
        }
        
        // Slide in animation
        let appearAnimation = CABasicAnimation(keyPath: "transform")
        appearAnimation.fromValue = NSValue(caTransform3D: appearTransform)
        appearAnimation.duration = inDuration
        appearAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        indicatorLayer.add(appearAnimation, forKey: "appear")
        
        // Pulse animation (delayed)
        let pulseAnimation = CAKeyframeAnimation(keyPath: "opacity")
        pulseAnimation.beginTime = CACurrentMediaTime() + inDuration
        pulseAnimation.values = [1.0, pulseMinOpacity, 1.0, pulseMinOpacity, 1.0]
        pulseAnimation.duration = pulseDuration
        pulseAnimation.fillMode = .forwards
        pulseAnimation.isRemovedOnCompletion = false
        pulseAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        indicatorLayer.add(pulseAnimation, forKey: "pulse")
        
        // Slide out animation (delayed)
        let disappearAnimation = CABasicAnimation(keyPath: "transform")
        disappearAnimation.beginTime = CACurrentMediaTime() + inDuration + pulseDuration
        disappearAnimation.toValue = NSValue(caTransform3D: appearTransform)
        disappearAnimation.duration = outDuration
        disappearAnimation.fillMode = .forwards
        disappearAnimation.isRemovedOnCompletion = false
        disappearAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        indicatorLayer.add(disappearAnimation, forKey: "disappear")
        
        // Close window after animation completes
        let totalDuration = inDuration + pulseDuration + outDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration) { [weak self] in
            self?.activeWindows.remove(window)
            window.close()
        }
    }
}
