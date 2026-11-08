// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

@MainActor
final class HotBorderMonitor {

    static let shared = HotBorderMonitor()

    private final class WeakBorder {
        weak var border: HotBorder?
        init(_ border: HotBorder) { self.border = border }
    }

    private var borders: [WeakBorder] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    // MARK: - Registration

    func register(_ border: HotBorder) {
        compact()
        guard !borders.contains(where: { $0.border === border }) else { return }
        borders.append(WeakBorder(border))
        startMonitoringIfNeeded()
    }

    func unregister(_ border: HotBorder) {
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
        if SystemStatusObserver.shared.isLocked {
            clearProximity(kind: .trigger)
            clearProximity(kind: .control)
            return
        }

        if ServerController.shared.isControlled {
            // Under controlled state, the local real cursor can only fire .control borders (switch control)
            let point = NSEvent.mouseLocation
            updateProximity(at: point, kind: .control)
            fireFirst(containing: point, kind: .control, isRealCursor: true)
            clearProximity(kind: .trigger)
        } else {
            let point = NSEvent.mouseLocation
            updateProximity(at: point, kind: .trigger)
            fireFirst(containing: point, kind: .trigger, isRealCursor: true)
            clearProximity(kind: .control)
        }
    }

    /// Drive the `.control` return border from the injected virtual cursor.
    /// - Parameter point: cursor position in Cocoa global coordinates (bottom-left origin).
    func evaluateInjectedCursor(atGlobalPoint point: NSPoint) {
        updateProximity(at: point, kind: .control)
        fireFirst(containing: point, kind: .control, isRealCursor: false)
    }

    private func fireFirst(containing point: NSPoint, kind: HotBorder.Kind, isRealCursor: Bool) {
        compact()
        for wrapper in borders {
            guard let border = wrapper.border, border.kind == kind else { continue }
            if border.fireIfEntered(atGlobalPoint: point, isRealCursor: isRealCursor) { return }
        }
    }

    /// Feed the cursor position to every border of `kind` so the overlay can
    /// fade in as the cursor approaches.
    private func updateProximity(at point: NSPoint, kind: HotBorder.Kind) {
        compact()
        for wrapper in borders {
            guard let border = wrapper.border, border.kind == kind else { continue }
            border.updateProximity(toGlobalPoint: point)
        }
    }

    private func clearProximity(kind: HotBorder.Kind) {
        let faraway = NSPoint(x: -1_000_000, y: -1_000_000)
        updateProximity(at: faraway, kind: kind)
    }
}
