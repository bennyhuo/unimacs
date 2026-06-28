// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  Single, window-independent hot-border detection.
//  Hot borders used to fire from AppKit window tracking-rect `mouseEntered:`
//  events, except on a locked screen where the window never receives them — so a
//  separate geometric path (`handleLockedReturnHotBorder`) existed just for that
//  case. This monitor unifies both into one mechanism: it tracks the cursor
//  position and geometrically tests it against the active hot borders, so the
//  window no longer needs to receive mouse events at all.
//  Two cursor feeds share the same evaluate/fire path:
//    * Real cursor (controlling side) — a global `mouseMoved` monitor drives the
//      `.trigger` borders that start control.
//    * Injected virtual cursor (controlled side) — `TPEventsController` forwards
//      the synthesized cursor position to drive the `.control` return border,
//      whether or not the screen is locked.
//  Main-thread confined: created/queried from the main run loop only (NSEvent
//  monitors, NSWindow geometry and the controllers it consults are all
//  main-thread state).

import AppKit

@MainActor
final class HotBorderMonitor {

    static let shared = HotBorderMonitor()

    private final class WeakBorder {
        weak var border: TPHotBorder?
        init(_ border: TPHotBorder) { self.border = border }
    }

    private var borders: [WeakBorder] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    // MARK: - Registration

    func register(_ border: TPHotBorder) {
        compact()
        guard !borders.contains(where: { $0.border === border }) else { return }
        borders.append(WeakBorder(border))
        startMonitoringIfNeeded()
    }

    func unregister(_ border: TPHotBorder) {
        borders.removeAll { $0.border === border || $0.border == nil }
        stopMonitoringIfIdle()
    }

    private func compact() {
        borders.removeAll { $0.border == nil }
    }

    // MARK: - Real-cursor monitoring (controlling side)

    private func startMonitoringIfNeeded() {
        guard globalMonitor == nil, !borders.isEmpty else { return }

        // `mouseMoved` only — buttons-down movement is `*Dragged` and must not
        // start/stop control, matching the previous `pressedMouseButtons == 0`
        // guard. Global catches movement over other apps; local catches movement
        // over our own (e.g. full-screen) windows.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.evaluateRealCursor()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.evaluateRealCursor()
            return event
        }
    }

    private func stopMonitoringIfIdle() {
        compact()
        guard borders.isEmpty else { return }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    // MARK: - Evaluation

    /// Drive `.trigger` borders from the local real cursor.
    func evaluateRealCursor() {
        // While this machine is being controlled, its real cursor is driven by
        // the remote's injected events; it must not start a reverse control
        // session. The controlled side's return border is handled by the
        // injected-cursor feed instead.
        if TPServerController.shared.isControlled || SystemStatusObserver.shared.isLocked {
            // Keep the proximity reveal from getting stuck "on".
            clearProximity(kind: .trigger)
            return
        }
        let point = NSEvent.mouseLocation
        updateProximity(at: point, kind: .trigger)
        fireFirst(containing: point, kind: .trigger)
    }

    /// Drive the `.control` return border from the injected virtual cursor.
    /// - Parameter point: cursor position in Cocoa global coordinates (bottom-left origin).
    func evaluateInjectedCursor(atGlobalPoint point: NSPoint) {
        updateProximity(at: point, kind: .control)
        fireFirst(containing: point, kind: .control)
    }

    private func fireFirst(containing point: NSPoint, kind: TPHotBorder.Kind) {
        compact()
        for wrapper in borders {
            guard let border = wrapper.border, border.kind == kind else { continue }
            if border.fireIfEntered(atGlobalPoint: point) { return }
        }
    }

    /// Feed the cursor position to every border of `kind` so the overlay can
    /// fade in as the cursor approaches.
    private func updateProximity(at point: NSPoint, kind: TPHotBorder.Kind) {
        compact()
        for wrapper in borders {
            guard let border = wrapper.border, border.kind == kind else { continue }
            border.updateProximity(toGlobalPoint: point)
        }
    }

    private func clearProximity(kind: TPHotBorder.Kind) {
        let faraway = NSPoint(x: -1_000_000, y: -1_000_000)
        updateProximity(at: faraway, kind: kind)
    }
}
