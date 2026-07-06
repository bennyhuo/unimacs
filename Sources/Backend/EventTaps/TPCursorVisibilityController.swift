// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  Encapsulates hide/show of the local cursor while controlling a remote machine.
//  Scheme A (useCursorShieldWindow, default): foreground shield windows take cursor
//  ownership, then CGDisplayHideCursor. Because shield ownership only settles a few
//  frames after the windows are ordered front, the hide is re-attempted from the
//  event tap *only while the cursor is actually still visible*. Every counted hide is
//  balanced by a matching show at session end, so the ref-count never drifts.
//  Scheme B (legacy): SetsCursorInBackground + CGCursorIsVisible polling in event tap.

import Cocoa

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ targetCid: Int32, _ key: CFString, _ value: CFBoolean)

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> Int32

@_silgen_name("CGCursorIsVisible")
private func cgCursorIsVisible() -> Bool

/// Borderless windows refuse key/main status by default, which makes AppKit
/// ignore them when deciding which Space to switch to on activation. Allowing
/// the shield to become key/main lets us anchor `NSApp.activate` to the Space
/// the user is currently on (the shield is `.canJoinAllSpaces`), instead of
/// being yanked to the Space that hosts Teleport's regular window.
private final class TPShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class TPCursorVisibilityController {

    static let shared = TPCursorVisibilityController()

    private var shieldWindows: [TPShieldWindow] = []
    private var shieldScreenFrames: [CGRect] = []

    /// Teleport's intent: true = cursor should be shown to the user.
    private var desiredCursorVisible = true
    /// Number of CGDisplayHideCursor calls not yet balanced by CGDisplayShowCursor.
    private var unbalancedHideCount = 0

    private init() {}

    private var usesShieldWindow: Bool {
        TPPreferencesManager.shared().bool(forPref: USE_CURSOR_SHIELD_WINDOW)
    }

    // MARK: - Control session

    func beginControlSession(reason: String) {
        guard desiredCursorVisible else { return }
        desiredCursorVisible = false

        if usesShieldWindow {
            // Scheme A relies on shield-window cursor ownership + public
            // CGDisplayHideCursor; the private SetsCursorInBackground hack is
            // neither needed nor effective here.
            //
            // Order matters: put the shield windows (canJoinAllSpaces +
            // fullScreenAuxiliary) on the *current* Space first and make the one
            // under the cursor key/main, then activate. App activation switches
            // to the Space of the app's key/main window; by anchoring that to a
            // shield on the current Space we avoid being yanked to the Space that
            // hosts Teleport's regular window (e.g. when control starts from
            // another app's fullscreen window).
            showShields(makeKey: true)
            TPMainController.shared().goFrontmost()
        } else {
            applyBackgroundHack()
        }
        debugLog("cursor: hide for control session (reason=\(reason), shield=\(usesShieldWindow))", module: .control)
        hideCursorIfLeaked()
    }

    func endControlSession(reason: String) {
        guard !desiredCursorVisible else { return }
        desiredCursorVisible = true

        if usesShieldWindow {
            hideShields()
        }
        balanceShowCursor()
        debugLog("cursor: restored after control session (reason=\(reason))", module: .control)
    }

    /// Called for every event tap callback while the tap is live.
    func handleEventTapTick(isControlling: Bool, eventType: CGEventType) {
        if usesShieldWindow {
            guard isControlling, !desiredCursorVisible else { return }
            // Keep shields owning the cursor region, and re-hide only if it leaked.
            showShields()
            if Self.isPointerEvent(eventType) {
                hideCursorIfLeaked()
            }
            return
        }

        // Scheme B (legacy)
        if isControlling {
            hideCursorIfLeaked()
        } else if !desiredCursorVisible {
            endControlSession(reason: "legacy:idleRecover")
        }
    }

    // MARK: - Visibility primitives

    /// Hides the cursor once (counted) but only if it is currently visible. This keeps
    /// the unbalanced hide count bounded by the few frames it takes shield ownership to
    /// settle, instead of growing on every event.
    private func hideCursorIfLeaked() {
        guard !desiredCursorVisible else { return }
        guard cgCursorIsVisible() else { return }

        // CGDisplayHideCursor only affects the cursor while the caller is the
        // foreground application (per Apple's docs). Scheme A normally satisfies
        // this via the shield window + goFrontmost. A few apps refuse to yield
        // the foreground — most notably Xcode, which holds Secure Event Input —
        // so NSApp.activate never sticks and the public hide is a silent no-op,
        // leaving the cursor visible. Fall back to the SetsCursorInBackground
        // connection property (the mechanism Scheme B relies on) whenever we are
        // not the active app, so the hide lands regardless of foreground state.
        if !usesShieldWindow || !NSApp.isActive {
            applyBackgroundHack()
        }

        invokeHideCursorAPI()
        unbalancedHideCount += 1
    }

    /// Shows the cursor exactly as many times as it was hidden, then makes sure it is
    /// actually visible again as a safety net.
    private func balanceShowCursor() {
        while unbalancedHideCount > 0 {
            invokeShowCursorAPI()
            unbalancedHideCount -= 1
        }
        var attempts = 0
        while !cgCursorIsVisible(), attempts < 16 {
            invokeShowCursorAPI()
            attempts += 1
        }
    }

    private func invokeHideCursorAPI() {
        let error = CGDisplayHideCursor(CGMainDisplayID())
        if error != .success {
            debugLog("CGDisplayHideCursor failed: \(error)", module: .control)
        }
    }

    private func invokeShowCursorAPI() {
        let error = CGDisplayShowCursor(CGMainDisplayID())
        if error != .success {
            debugLog("CGDisplayShowCursor failed: \(error)", module: .control)
        }
    }

    private static func isPointerEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .scrollWheel:
            return true
        default:
            return false
        }
    }

    // MARK: - Scheme A: shield windows

    /// - Parameter makeKey: when true (control-session start), the shield under
    ///   the cursor is made key/main so a subsequent `NSApp.activate` stays on
    ///   the current Space. The per-event tick path passes false and only
    ///   re-asserts z-order, since stealing key on every pointer event would
    ///   thrash focus.
    private func showShields(makeKey: Bool = false) {
        rebuildShieldWindowsIfNeeded()

        if makeKey, let keyWindow = shieldWindowUnderCursor() ?? shieldWindows.first {
            keyWindow.makeKeyAndOrderFront(nil)
        }

        for window in shieldWindows where !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    private func shieldWindowUnderCursor() -> TPShieldWindow? {
        let cursor = NSEvent.mouseLocation
        return shieldWindows.first { $0.frame.contains(cursor) }
    }

    private func hideShields() {
        for window in shieldWindows {
            window.orderOut(nil)
        }
    }

    private func rebuildShieldWindowsIfNeeded() {
        let frames = NSScreen.screens.map { $0.frame }
        if frames == shieldScreenFrames && shieldWindows.count == frames.count {
            return
        }

        for window in shieldWindows {
            window.orderOut(nil)
        }
        shieldWindows.removeAll(keepingCapacity: true)

        for frame in frames {
            let window = makeShieldWindow()
            window.setFrame(frame, display: false)
            shieldWindows.append(window)
        }
        shieldScreenFrames = frames
    }

    private func makeShieldWindow() -> TPShieldWindow {
        let window = TPShieldWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = NSColor(white: 0.0, alpha: 0.01)
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return window
    }

    // MARK: - Scheme B: legacy private background hack

    private func applyBackgroundHack() {
        let propertyString = "SetsCursorInBackground" as CFString
        CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(), propertyString, kCFBooleanTrue)
    }
}
