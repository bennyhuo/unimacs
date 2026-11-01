// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import CoreGraphics

// MARK: - Lightweight Assertion Helpers

private var totalTestsRun = 0
private var totalAssertions = 0
private var failedTests: [String] = []

private func assertEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: @autoclosure () -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    let a = actual()
    let e = expected()
    if a != e {
        let failure = "[\(file):\(line)] Assertion failed: expected (\(e)), got (\(a)). \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertTrue(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if !condition() {
        let failure = "[\(file):\(line)] Assertion failed: expected true. \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertFalse(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if condition() {
        let failure = "[\(file):\(line)] Assertion failed: expected false. \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertNil<T>(
    _ value: @autoclosure () -> T?,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if let v = value() {
        let failure = "[\(file):\(line)] Assertion failed: expected nil, got \(v). \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertNotNil<T>(
    _ value: @autoclosure () -> T?,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if value() == nil {
        let failure = "[\(file):\(line)] Assertion failed: expected non-nil. \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

@MainActor
private func runTest(_ name: String, _ block: @MainActor () -> Void) {
    totalTestsRun += 1
    let failuresBefore = failedTests.count
    block()
    if failedTests.count == failuresBefore {
        print("  ✅ \(name)")
    }
}

// MARK: - Test Suite

@main
struct ActivityLogTestRunner {
    @MainActor
    static func main() {
        print("=== Running Unimacs ActivityLog & Diagnostic Unit Tests ===")

        runTest("testActivityLogBasicLoggingAndNormalization") {
            let manager = ActivityLogManager(maxEntries: 50, deduplicationWindow: 30)
            assertEqual(manager.entries.count, 0)
            assertNil(manager.latestEntry)

            // Empty/whitespace title should be ignored (boundary condition)
            manager.log(level: .info, category: .network, title: "   \n\t  ")
            assertEqual(manager.entries.count, 0)

            // Normal log with whitespace-padded title, detail, and howToFix
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            manager.log(
                level: .error,
                category: .connection,
                title: "  Connection failed to Mac-Studio  ",
                detail: "  Timed out after 5s  ",
                howToFix: "  Click Retry Now  ",
                hostId: "Mac-Studio",
                hostName: "Mac-Studio",
                actions: [.retryConnection(hostId: "Mac-Studio", hostName: "Mac-Studio")],
                now: t0
            )

            assertEqual(manager.entries.count, 1)
            let entry = manager.latestEntry!
            assertEqual(entry.title, "Connection failed to Mac-Studio")
            assertEqual(entry.detail, "Timed out after 5s")
            assertEqual(entry.howToFix, "Click Retry Now")
            assertEqual(entry.occurrenceCount, 1)
            assertEqual(entry.hostId, "Mac-Studio")
            assertEqual(manager.unreadIssueCount, 1)

            // Empty detail and howToFix should normalize to nil
            manager.log(
                level: .info,
                category: .discovery,
                title: "Discovered MacBook-Pro",
                detail: "   ",
                howToFix: "",
                now: t0.addingTimeInterval(1)
            )
            assertEqual(manager.entries.count, 2)
            assertNil(manager.latestEntry?.detail)
            assertNil(manager.latestEntry?.howToFix)
            // Info should not increment unreadIssueCount
            assertEqual(manager.unreadIssueCount, 1)
        }

        runTest("testActivityLogDeduplicationWithinAndOutsideWindow") {
            let manager = ActivityLogManager(maxEntries: 50, deduplicationWindow: 15)
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)

            manager.log(
                level: .warning,
                category: .connection,
                title: "Auto-reconnect failed",
                detail: "Connection refused",
                howToFix: "Start Unimacs on remote",
                hostId: "host-1",
                hostName: "Host 1",
                now: t0
            )
            assertEqual(manager.entries.count, 1)
            assertEqual(manager.entries[0].occurrenceCount, 1)

            // Duplicate within 15s window should increment occurrenceCount and update timestamp
            let t1 = t0.addingTimeInterval(10)
            manager.log(
                level: .warning,
                category: .connection,
                title: "Auto-reconnect failed",
                detail: "Connection refused",
                howToFix: "Start Unimacs on remote",
                hostId: "host-1",
                hostName: "Host 1",
                actions: [.resetAllConnections],
                now: t1
            )
            assertEqual(manager.entries.count, 1)
            assertEqual(manager.entries[0].occurrenceCount, 2)
            assertEqual(manager.entries[0].timestamp, t1)
            assertEqual(manager.entries[0].actions, [.resetAllConnections])

            // Same message for a different hostId should NOT deduplicate
            manager.log(
                level: .warning,
                category: .connection,
                title: "Auto-reconnect failed",
                detail: "Connection refused",
                howToFix: "Start Unimacs on remote",
                hostId: "host-2",
                hostName: "Host 2",
                now: t1.addingTimeInterval(1)
            )
            assertEqual(manager.entries.count, 2)

            // Duplicate for host-1 outside 15s window (e.g. +20s after t1) should create a new entry
            let t2 = t1.addingTimeInterval(20)
            manager.log(
                level: .warning,
                category: .connection,
                title: "Auto-reconnect failed",
                detail: "Connection refused",
                howToFix: "Start Unimacs on remote",
                hostId: "host-1",
                hostName: "Host 1",
                now: t2
            )
            assertEqual(manager.entries.count, 3)
            assertEqual(manager.entries[0].occurrenceCount, 1)
        }

        runTest("testActivityLogRingBufferPruningAndMinCap") {
            // Passing maxEntries < 10 should clamp to 10
            let manager = ActivityLogManager(maxEntries: 3, deduplicationWindow: 0)
            assertEqual(manager.maxEntries, 10)

            let base = Date(timeIntervalSince1970: 1_700_000_000)
            for i in 1...15 {
                manager.log(
                    level: .info,
                    category: .network,
                    title: "Event #\(i)",
                    now: base.addingTimeInterval(Double(i))
                )
            }

            assertEqual(manager.entries.count, 10)
            assertEqual(manager.entries.first?.title, "Event #15")
            assertEqual(manager.entries.last?.title, "Event #6")
        }

        runTest("testActivityLogFilteringAndDrawerPresentation") {
            assertEqual(ActivityLogCategory.allCases, [.connection, .discovery, .display, .control])
            assertEqual(ActivityLogCategory.network, .connection)

            let manager = ActivityLogManager(maxEntries: 50, deduplicationWindow: 0)
            manager.log(
                level: .info,
                category: .discovery,
                title: "Discovered Mac-Mini",
                detail: "Endpoint 192.168.1.50:23456",
                hostId: "Mac-Mini",
                hostName: "Mac-Mini"
            )
            manager.log(
                level: .error,
                category: .connection,
                title: "Connection timed out to Mac-Studio",
                detail: "No response within 5s",
                howToFix: "Check firewall",
                hostId: "Mac-Studio",
                hostName: "Mac-Studio"
            )
            manager.log(
                level: .info,
                category: .display,
                title: "Local display count changed: 1 → 2 screens",
                detail: "2560×1440"
            )

            assertEqual(manager.filteredEntries.count, 3)
            assertEqual(manager.issueCount, 1)
            assertEqual(manager.knownHostsInLog.count, 2)

            // Filter by category
            manager.selectedCategory = .display
            assertEqual(manager.filteredEntries.count, 1)
            assertEqual(manager.filteredEntries[0].title, "Local display count changed: 1 → 2 screens")

            // Filter by host via revealLogs
            manager.revealLogs(forHostId: "Mac-Studio", issuesOnly: true)
            assertTrue(manager.isDrawerExpanded)
            assertEqual(manager.unreadIssueCount, 0)
            assertNil(manager.selectedCategory)
            assertEqual(manager.selectedHostId, "Mac-Studio")
            assertTrue(manager.showIssuesOnly)
            assertEqual(manager.filteredEntries.count, 1)
            assertEqual(manager.filteredEntries[0].hostId, "Mac-Studio")

            // Reset filters and test search query
            manager.resetFilters()
            assertEqual(manager.filteredEntries.count, 3)
            manager.searchText = "192.168.1.50"
            assertEqual(manager.filteredEntries.count, 1)
            assertEqual(manager.filteredEntries[0].hostId, "Mac-Mini")

            // Export formatted text check
            manager.resetFilters()
            let exported = manager.exportFormattedText()
            assertTrue(exported.contains("[ERROR] [Connection] [Mac-Studio] Connection timed out to Mac-Studio"))
            assertTrue(exported.contains("How to fix: Check firewall"))

            // Clear check
            manager.clear()
            assertEqual(manager.entries.count, 0)
            assertEqual(manager.unreadIssueCount, 0)
        }

        runTest("testActivityLogPerformActions") {
            let manager = ActivityLogManager(maxEntries: 50, deduplicationWindow: 0)
            var navigatedToSettings = false
            manager.onNavigateToSettingsTab = {
                navigatedToSettings = true
            }

            manager.performAction(.openNetworkSettings)
            assertTrue(navigatedToSettings)

            manager.performAction(.resetAllConnections)
            assertEqual(manager.latestEntry?.category, .network)
            assertTrue(manager.latestEntry?.title.contains("Resetting all network connections") == true)

            manager.performAction(.retryConnection(hostId: "Mac-Studio", hostName: "Mac-Studio"))
            assertTrue(manager.latestEntry?.title.contains("Manual retry initiated for Mac-Studio") == true)

            var interceptedAction: ActivityFixAction?
            manager.customActionHandler = { action in
                interceptedAction = action
                return true
            }
            let repairAction = ActivityFixAction.repairDevice(hostId: "Mac-Pro", hostName: "Mac-Pro")
            manager.performAction(repairAction)
            assertEqual(interceptedAction, repairAction)
        }

        runTest("testConnectionFailureDiagnoserAllBranches") {
            let wifiIface = NetworkInterfaceInfo(name: "en0", ipAddress: "192.168.1.10", subnetMask: "255.255.255.0")
            let lanIface = NetworkInterfaceInfo(name: "en1", ipAddress: "10.0.0.15", subnetMask: "255.255.255.0")

            // 1. Offline (no local interfaces)
            let offlineDiag = ConnectionFailureDiagnoser.diagnose(
                rawReason: "Connection timed out",
                hostId: "peer-1",
                hostName: "PeerMac",
                targetAddress: "192.168.1.20",
                targetPort: 23456,
                localInterfaces: []
            )
            assertEqual(offlineDiag.shortReason, "Local network offline")
            assertTrue(offlineDiag.actions.contains(.openNetworkSettings))

            // 2. Unpaired by peer
            let unpairDiag = ConnectionFailureDiagnoser.diagnose(
                rawReason: "Remote Mac unpaired this device",
                hostId: "peer-1",
                hostName: "PeerMac",
                targetAddress: "192.168.1.20",
                targetPort: 23456,
                localInterfaces: [wifiIface]
            )
            assertEqual(unpairDiag.shortReason, "Unpaired on remote Mac")
            assertEqual(unpairDiag.actions, [.repairDevice(hostId: "peer-1", hostName: "PeerMac")])

            // 3. Trust / Control rejected
            let rejectedDiag = ConnectionFailureDiagnoser.diagnose(
                rawReason: "Control rejected: Host not trusted",
                hostId: "peer-1",
                hostName: "PeerMac",
                targetAddress: "192.168.1.20",
                targetPort: 23456,
                localInterfaces: [wifiIface]
            )
            assertEqual(rejectedDiag.shortReason, "Trust or control rejected")
            assertTrue(rejectedDiag.actions.contains(.repairDevice(hostId: "peer-1", hostName: "PeerMac")))

            // 4. Incompatible protocol version
            let protoDiag = ConnectionFailureDiagnoser.diagnose(
                rawReason: "Incompatible protocol version (remote=9, local=8)",
                hostId: "peer-1",
                hostName: "PeerMac",
                targetAddress: "192.168.1.20",
                targetPort: 23456,
                localInterfaces: [wifiIface]
            )
            assertEqual(protoDiag.shortReason, "Incompatible app version")

            // 5. Missing target IP address (boundary condition: nil or whitespace)
            let noIPDiag = ConnectionFailureDiagnoser.diagnose(
                rawReason: nil,
                hostId: "peer-1",
                hostName: "PeerMac",
                targetAddress: "   ",
                targetPort: 23456,
                localInterfaces: [wifiIface]
            )
            assertEqual(noIPDiag.shortReason, "No IP address for device")
            assertTrue(noIPDiag.actions.contains(.resetAllConnections))

            // 6a. Selected bound local IP is inactive
            let inactiveBoundDiag = ConnectionFailureDiagnoser.diagnose(
                rawReason: "Socket error",
                hostId: "peer-1",
                hostName: "PeerMac",
                targetAddress: "192.168.1.20",
                targetPort: 23456,
                localInterfaces: [wifiIface],
                selectedLocalIP: "172.16.0.99"
            )
            assertEqual(inactiveBoundDiag.shortReason, "Bound IP (172.16.0.99) inactive")

            // 6b. Selected bound local IP is on wrong subnet while another interface matches target subnet
            let wrongBoundSubnetDiag = ConnectionFailureDiagnoser.diagnose(
                rawReason: "No route to host",
                hostId: "peer-1",
                hostName: "PeerMac",
                targetAddress: "192.168.1.20",
                targetPort: 23456,
                localInterfaces: [wifiIface, lanIface],
                selectedLocalIP: "10.0.0.15"
            )
            assertEqual(wrongBoundSubnetDiag.shortReason, "Bound IP (10.0.0.15) on wrong subnet")

            // 7. Connection refused
            let refusedDiag = ConnectionFailureDiagnoser.diagnose(
                rawReason: "Connection refused (port 23456 closed)",
                hostId: "peer-1",
                hostName: "PeerMac",
                targetAddress: "192.168.1.20",
                targetPort: 23456,
                localInterfaces: [wifiIface]
            )
            assertEqual(refusedDiag.shortReason, "Connection refused (192.168.1.20:23456)")

            // 8. Unreachable on different subnet
            let unreachableSubnetDiag = ConnectionFailureDiagnoser.diagnose(
                rawReason: "No route to host (ehostunreach)",
                hostId: "peer-1",
                hostName: "PeerMac",
                targetAddress: "172.20.10.5",
                targetPort: 23456,
                localInterfaces: [wifiIface]
            )
            assertEqual(unreachableSubnetDiag.shortReason, "Unreachable (different subnet)")
            assertTrue(unreachableSubnetDiag.actions.contains(.openNetworkSettings))

            // 9. Closed during handshake
            let handshakeDiag = ConnectionFailureDiagnoser.diagnose(
                rawReason: "Connection closed by peer during identification handshake",
                hostId: "peer-1",
                hostName: "PeerMac",
                targetAddress: "192.168.1.20",
                targetPort: 23456,
                localInterfaces: [wifiIface]
            )
            assertEqual(handshakeDiag.shortReason, "Closed during handshake")

            // 10. Timeout on same subnet vs different subnet
            let timeoutSameSubnet = ConnectionFailureDiagnoser.diagnose(
                rawReason: "Connection timed out after 5s",
                hostId: "peer-1",
                hostName: "PeerMac",
                targetAddress: "192.168.1.20",
                targetPort: 23456,
                localInterfaces: [wifiIface],
                isBonjourOnline: true
            )
            assertEqual(timeoutSameSubnet.shortReason, "Connection timed out (192.168.1.20:23456)")
            assertTrue(timeoutSameSubnet.whyFailed.contains("Bonjour"))

            let timeoutDiffSubnet = ConnectionFailureDiagnoser.diagnose(
                rawReason: "Connection timed out after 5s",
                hostId: "peer-1",
                hostName: "PeerMac",
                targetAddress: "10.99.0.5",
                targetPort: 23456,
                localInterfaces: [wifiIface]
            )
            assertEqual(timeoutDiffSubnet.shortReason, "Timed out (subnet mismatch: 10.99.0.5)")

            // 11. POSIX errno descriptions
            assertEqual(ConnectionFailureDiagnoser.describePosixError(ECONNREFUSED, port: 23456), "Connection refused (port 23456 closed)")
            assertEqual(ConnectionFailureDiagnoser.describePosixError(ETIMEDOUT), "Connection timed out")
            assertEqual(ConnectionFailureDiagnoser.describePosixError(EHOSTUNREACH), "No route to host (host unreachable)")
            assertEqual(ConnectionFailureDiagnoser.describePosixError(ECONNRESET), "Connection reset by peer")
            assertEqual(ConnectionFailureDiagnoser.describePosixError(-1), "Socket error (-1)")
        }

        runTest("testNetworkChangeFormatterDiffs") {
            let en0Old = NetworkInterfaceInfo(name: "en0", ipAddress: "192.168.1.10", subnetMask: "255.255.255.0")
            let en0New = NetworkInterfaceInfo(name: "en0", ipAddress: "192.168.1.25", subnetMask: "255.255.255.0")
            let en1 = NetworkInterfaceInfo(name: "en1", ipAddress: "10.0.0.8", subnetMask: "255.255.255.0")

            // No change -> nil
            assertNil(NetworkChangeFormatter.describeChange(previous: [en0Old], current: [en0Old]))

            // Offline transition
            let offlineDiff = NetworkChangeFormatter.describeChange(previous: [en0Old], current: [])
            assertNotNil(offlineDiff)
            assertEqual(offlineDiff?.level, .error)
            assertTrue(offlineDiff?.title.contains("Network disconnected") == true)

            // Online transition from empty
            let onlineDiff = NetworkChangeFormatter.describeChange(previous: [], current: [en0New])
            assertNotNil(onlineDiff)
            assertEqual(onlineDiff?.level, .success)
            assertTrue(onlineDiff?.title.contains("192.168.1.25 (en0)") == true)

            // IP updated on en0 + en1 joined
            let multiDiff = NetworkChangeFormatter.describeChange(previous: [en0Old], current: [en0New, en1])
            assertNotNil(multiDiff)
            assertEqual(multiDiff?.level, .info)
            assertTrue(multiDiff?.title.contains("en0 IP updated 192.168.1.10 → 192.168.1.25") == true)
            assertTrue(multiDiff?.title.contains("en1 joined (10.0.0.8)") == true)
        }

        runTest("testDisplayChangeFormatterDiffs") {
            let r1 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let r2 = CGRect(x: 1920, y: 0, width: 2560, height: 1440)

            // Identical ScreenSummary returns nil
            let s1 = DisplayChangeFormatter.ScreenSummary(rect: r1)
            assertNil(DisplayChangeFormatter.describeLocalScreenChange(previous: [s1], current: [s1]))

            // Local screen count change
            let countChange = DisplayChangeFormatter.describeLocalScreenChange(previous: [r1], current: [r1, r2])
            assertEqual(countChange.title, "Local display count changed: 1 → 2 screens")
            assertTrue(countChange.detail.contains("1920×1080, 2560×1440"))

            // Local resolution change with same count
            let resChange = DisplayChangeFormatter.describeLocalScreenChange(previous: [r1], current: [r2])
            assertTrue(resChange.title.contains("Local display resolution or arrangement updated"))

            // Remote screen count change
            let remoteChange = DisplayChangeFormatter.describeRemoteScreenChange(
                hostName: "Mac-Studio",
                previous: [r1, r2],
                current: [r2]
            )
            assertEqual(remoteChange.title, "Mac-Studio display count changed: 2 → 1 screen")
        }

        runTest("testActivityLogDrawerGeometrySynchronizedMetrics") {
            // 1. Collapsed state (progress = 0)
            let collapsed = ActivityLogDrawerGeometry.computeMetrics(
                revealProgress: 0,
                collapsedHeaderHeight: 36,
                expandedBodyHeight: 260,
                isDarkMode: false
            )
            assertEqual(collapsed.clampedProgress, 0)
            assertEqual(collapsed.collapsedTotalHeight, 37)
            assertEqual(collapsed.fullExpandedHeight, 297)
            assertEqual(collapsed.currentVisibleHeight, 37)
            assertEqual(collapsed.chevronRotationDegrees, 0)
            assertEqual(collapsed.shadowHeight, 3)

            // 2. Mid-animation state (progress = 0.5)
            let halfway = ActivityLogDrawerGeometry.computeMetrics(
                revealProgress: 0.5,
                collapsedHeaderHeight: 36,
                expandedBodyHeight: 260,
                isDarkMode: true
            )
            assertEqual(halfway.clampedProgress, 0.5)
            assertEqual(halfway.currentVisibleHeight, 167)
            assertEqual(halfway.chevronRotationDegrees, 90)
            assertEqual(halfway.shadowHeight, 4.5)

            // 3. Expanded state (progress = 1)
            let expanded = ActivityLogDrawerGeometry.computeMetrics(
                revealProgress: 1.0,
                collapsedHeaderHeight: 36,
                expandedBodyHeight: 260,
                isDarkMode: true
            )
            assertEqual(expanded.clampedProgress, 1.0)
            assertEqual(expanded.currentVisibleHeight, 297)
            assertEqual(expanded.chevronRotationDegrees, 180)
            assertEqual(expanded.shadowHeight, 6)

            // 4. Boundary conditions: spring overshoot (> 1, < 0, NaN, negative heights)
            let overshoot = ActivityLogDrawerGeometry.computeMetrics(
                revealProgress: 1.15,
                collapsedHeaderHeight: 36,
                expandedBodyHeight: 260,
                isDarkMode: false
            )
            assertEqual(overshoot.clampedProgress, 1.0)
            assertEqual(overshoot.currentVisibleHeight, 297)

            let undershoot = ActivityLogDrawerGeometry.computeMetrics(
                revealProgress: -0.2,
                collapsedHeaderHeight: -10,
                expandedBodyHeight: -50,
                isDarkMode: false
            )
            assertEqual(undershoot.clampedProgress, 0)
            assertEqual(undershoot.collapsedTotalHeight, 1)
            assertEqual(undershoot.fullExpandedHeight, 1)
            assertEqual(undershoot.currentVisibleHeight, 1)

            let nanMetrics = ActivityLogDrawerGeometry.computeMetrics(
                revealProgress: .nan,
                collapsedHeaderHeight: 36,
                expandedBodyHeight: 260,
                isDarkMode: false
            )
            assertEqual(nanMetrics.clampedProgress, 0)
            assertEqual(nanMetrics.currentVisibleHeight, 37)
        }

        runTest("testLayoutDisplayAvailabilityPolicy") {
            // 1. Connected & controlled states
            let connected = LayoutDisplayAvailabilityPolicy.resolveRemoteStatus(
                isConnectedLink: true,
                isConnecting: false,
                isReconnecting: false,
                isBonjourOnline: true,
                isControlled: false
            )
            assertTrue(connected.isConnected)
            assertNil(connected.statusLabel)

            let controlledOnly = LayoutDisplayAvailabilityPolicy.resolveRemoteStatus(
                isConnectedLink: false,
                isConnecting: false,
                isReconnecting: false,
                isBonjourOnline: false,
                isControlled: true
            )
            assertTrue(controlledOnly.isConnected)
            assertNil(controlledOnly.statusLabel)

            // 2. Disconnected / transitional states (greyed out in Layout view)
            let connecting = LayoutDisplayAvailabilityPolicy.resolveRemoteStatus(
                isConnectedLink: false,
                isConnecting: true,
                isReconnecting: false,
                isBonjourOnline: true,
                isControlled: false
            )
            assertFalse(connecting.isConnected)
            assertEqual(connecting.statusLabel, "Connecting…")

            let reconnecting = LayoutDisplayAvailabilityPolicy.resolveRemoteStatus(
                isConnectedLink: false,
                isConnecting: false,
                isReconnecting: true,
                isBonjourOnline: true,
                isControlled: false
            )
            assertFalse(reconnecting.isConnected)
            assertEqual(reconnecting.statusLabel, "Reconnecting…")

            let bonjourDisconnected = LayoutDisplayAvailabilityPolicy.resolveRemoteStatus(
                isConnectedLink: false,
                isConnecting: false,
                isReconnecting: false,
                isBonjourOnline: true,
                isControlled: false
            )
            assertFalse(bonjourDisconnected.isConnected)
            assertEqual(bonjourDisconnected.statusLabel, "Disconnected")

            let offline = LayoutDisplayAvailabilityPolicy.resolveRemoteStatus(
                isConnectedLink: false,
                isConnecting: false,
                isReconnecting: false,
                isBonjourOnline: false,
                isControlled: false
            )
            assertFalse(offline.isConnected)
            assertEqual(offline.statusLabel, "Offline")

            // 3. Overlap filtering for disconnected displays vs active connected displays
            let rightEdgeRect = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
            let leftEdgeRect = CGRect(x: -1920, y: 0, width: 1920, height: 1080)

            // Disconnected display on a non-overlapping edge should be displayed (greyed out) when showConnectedOnly is false
            assertTrue(
                LayoutDisplayAvailabilityPolicy.shouldDisplayRemoteLayout(
                    candidateRect: leftEdgeRect,
                    isConnected: false,
                    showConnectedOnly: false,
                    activeConnectedRects: [rightEdgeRect]
                )
            )
            // When showConnectedOnly is true, disconnected display is hidden even if non-overlapping
            assertFalse(
                LayoutDisplayAvailabilityPolicy.shouldDisplayRemoteLayout(
                    candidateRect: leftEdgeRect,
                    isConnected: false,
                    showConnectedOnly: true,
                    activeConnectedRects: [rightEdgeRect]
                )
            )
            // When showConnectedOnly is true, connected display is still shown
            assertTrue(
                LayoutDisplayAvailabilityPolicy.shouldDisplayRemoteLayout(
                    candidateRect: rightEdgeRect,
                    isConnected: true,
                    showConnectedOnly: true,
                    activeConnectedRects: [rightEdgeRect]
                )
            )
            // Disconnected display overlapping an active connected display on the same edge should be hidden
            assertFalse(
                LayoutDisplayAvailabilityPolicy.shouldDisplayRemoteLayout(
                    candidateRect: rightEdgeRect,
                    isConnected: false,
                    activeConnectedRects: [rightEdgeRect]
                )
            )
            // Connected display is always shown even if rects overlap
            assertTrue(
                LayoutDisplayAvailabilityPolicy.shouldDisplayRemoteLayout(
                    candidateRect: rightEdgeRect,
                    isConnected: true,
                    activeConnectedRects: [rightEdgeRect]
                )
            )
            // Boundary: empty/zero/null rect is rejected
            assertFalse(
                LayoutDisplayAvailabilityPolicy.shouldDisplayRemoteLayout(
                    candidateRect: .zero,
                    isConnected: true,
                    activeConnectedRects: []
                )
            )
            assertFalse(
                LayoutDisplayAvailabilityPolicy.shouldDisplayRemoteLayout(
                    candidateRect: .null,
                    isConnected: false,
                    activeConnectedRects: []
                )
            )
        }

        print("=== Test Summary: \(totalTestsRun) tests (\(totalAssertions) assertions), \(failedTests.count) failures ===")
        if !failedTests.isEmpty {
            exit(1)
        }
    }
}
