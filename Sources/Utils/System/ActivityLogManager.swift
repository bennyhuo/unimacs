// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import AppKit
import Combine

// MARK: - Activity Log Level

enum ActivityLogLevel: Int, CaseIterable, Comparable, Sendable {
    case info = 0
    case success = 1
    case warning = 2
    case error = 3

    static func < (lhs: ActivityLogLevel, rhs: ActivityLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .info: return "Info"
        case .success: return "OK"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    var iconName: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var isIssue: Bool {
        self == .warning || self == .error
    }
}

// MARK: - Activity Log Category

enum ActivityLogCategory: String, CaseIterable, Identifiable, Sendable {
    case connection = "Connection"
    case discovery = "Discovery"
    case display = "Display"
    case control = "Control"

    /// Unified alias so local network interface / IP events and peer TCP connection events
    /// appear together under the single "Connection" category without splitting related logs.
    static let network: ActivityLogCategory = .connection

    var id: String { rawValue }

    var displayName: String { rawValue }

    var iconName: String {
        switch self {
        case .connection: return "network"
        case .discovery: return "antenna.radiowaves.left.and.right"
        case .display: return "display.2"
        case .control: return "cursorarrow.motionlines"
        }
    }
}

// MARK: - Activity Fix Action

enum ActivityFixAction: Equatable, Hashable, Identifiable, Sendable {
    case retryConnection(hostId: String, hostName: String)
    case resetAllConnections
    case repairDevice(hostId: String, hostName: String)
    case pingHost(hostId: String, hostName: String, address: String)
    case openNetworkSettings
    case openAccessibilitySettings

    var id: String {
        switch self {
        case .retryConnection(let hostId, _):
            return "retry:\(hostId)"
        case .resetAllConnections:
            return "resetAll"
        case .repairDevice(let hostId, _):
            return "repair:\(hostId)"
        case .pingHost(let hostId, _, let address):
            return "ping:\(hostId):\(address)"
        case .openNetworkSettings:
            return "openNetworkSettings"
        case .openAccessibilitySettings:
            return "openAccessibilitySettings"
        }
    }

    var title: String {
        switch self {
        case .retryConnection:
            return "Retry Now"
        case .resetAllConnections:
            return "Reset Network"
        case .repairDevice:
            return "Re-pair"
        case .pingHost:
            return "Ping Host"
        case .openNetworkSettings:
            return "Network Settings"
        case .openAccessibilitySettings:
            return "Authorize Accessibility"
        }
    }

    var iconName: String {
        switch self {
        case .retryConnection:
            return "arrow.clockwise"
        case .resetAllConnections:
            return "arrow.triangle.2.circlepath"
        case .repairDevice:
            return "link.badge.plus"
        case .pingHost:
            return "waveform.path.ecg"
        case .openNetworkSettings:
            return "network"
        case .openAccessibilitySettings:
            return "hand.raised.fill"
        }
    }

    var isPrimary: Bool {
        switch self {
        case .retryConnection, .repairDevice, .openAccessibilitySettings:
            return true
        case .resetAllConnections, .pingHost, .openNetworkSettings:
            return false
        }
    }
}

// MARK: - Activity Log Entry

struct ActivityLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var timestamp: Date
    let level: ActivityLogLevel
    let category: ActivityLogCategory
    let title: String
    var detail: String?
    var howToFix: String?
    let hostId: String?
    let hostName: String?
    var actions: [ActivityFixAction]
    var occurrenceCount: Int

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: ActivityLogLevel,
        category: ActivityLogCategory,
        title: String,
        detail: String? = nil,
        howToFix: String? = nil,
        hostId: String? = nil,
        hostName: String? = nil,
        actions: [ActivityFixAction] = [],
        occurrenceCount: Int = 1
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.title = title
        self.detail = detail
        self.howToFix = howToFix
        self.hostId = hostId
        self.hostName = hostName
        self.actions = actions
        self.occurrenceCount = max(1, occurrenceCount)
    }

    func matchesDeduplicationKey(
        level: ActivityLogLevel,
        category: ActivityLogCategory,
        title: String,
        detail: String?,
        howToFix: String?,
        hostId: String?
    ) -> Bool {
        self.level == level &&
        self.category == category &&
        self.title == title &&
        self.detail == detail &&
        self.howToFix == howToFix &&
        self.hostId == hostId
    }
}

// MARK: - Connection Failure Diagnosis

struct ConnectionFailureDiagnosis: Equatable, Sendable {
    let shortReason: String
    let whyFailed: String
    let howToFix: String
    let actions: [ActivityFixAction]

    var combinedDetail: String {
        "Why: \(whyFailed)\nHow to fix: \(howToFix)"
    }
}

enum ConnectionFailureDiagnoser {
    /// Diagnose a connection or reconnection failure and produce a user-friendly explanation
    /// along with actionable fix entry points.
    static func diagnose(
        rawReason: String?,
        hostId: String,
        hostName: String,
        targetAddress: String?,
        targetPort: Int,
        localInterfaces: [NetworkInterfaceInfo],
        selectedLocalIP: String = NetworkUtils.anyIPv4Address,
        isBonjourOnline: Bool = true
    ) -> ConnectionFailureDiagnosis {
        let cleanAddress = (targetAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointText = cleanAddress.isEmpty
            ? hostName
            : (targetPort > 0 ? "\(cleanAddress):\(targetPort)" : cleanAddress)
        let normalized = (rawReason ?? "").lowercased()

        // 1. Check if local Mac has no active IPv4 network at all
        if localInterfaces.isEmpty {
            return ConnectionFailureDiagnosis(
                shortReason: "Local network offline",
                whyFailed: "This Mac currently has no active IPv4 network connection (Wi-Fi or Ethernet is disconnected).",
                howToFix: "Connect this Mac to Wi-Fi or Ethernet, then click Retry Now.",
                actions: [
                    .retryConnection(hostId: hostId, hostName: hostName),
                    .openNetworkSettings
                ]
            )
        }

        // 2. Unpaired by peer
        if normalized.contains("unpaired") {
            return ConnectionFailureDiagnosis(
                shortReason: "Unpaired on remote Mac",
                whyFailed: "\"\(hostName)\" no longer recognizes this Mac as a paired peer (it was unpaired on the remote device).",
                howToFix: "Click Re-pair to send a new pairing request to \"\(hostName)\".",
                actions: [
                    .repairDevice(hostId: hostId, hostName: hostName)
                ]
            )
        }

        // 3. Code signature expired / revoked or app updated on disk
        if normalized.contains("code signature invalid") || normalized.contains("signing certificate") || normalized.contains("signature changed") || normalized.contains("certificate") || normalized.contains("revoked") || normalized.contains("updated on disk") || normalized.contains("app updated") {
            return ConnectionFailureDiagnosis(
                shortReason: "Code signature invalid",
                whyFailed: rawReason ?? "macOS blocked input control because the application signing certificate is expired or revoked.",
                howToFix: "Rebuild and redeploy Unimacs with a valid certificate (e.g. ./Scripts/rebuild-and-deploy.sh), or re-authorize Unimacs in System Settings > Privacy & Security > Accessibility.",
                actions: [
                    .openAccessibilitySettings
                ]
            )
        }

        // 4. Accessibility permission / EventTap creation failure
        if normalized.contains("accessibility") || normalized.contains("eventtap") || normalized.contains("input capture") || normalized.contains("event controller") {
            return ConnectionFailureDiagnosis(
                shortReason: "Accessibility / EventTap blocked",
                whyFailed: rawReason ?? "macOS blocked global input capture or injection due to missing Accessibility permission.",
                howToFix: "Open System Settings > Privacy & Security > Accessibility and ensure Unimacs is enabled on both Macs.",
                actions: [
                    .openAccessibilitySettings
                ]
            )
        }

        // 5. Control / Trust rejected
        if normalized.contains("rejected") || normalized.contains("not trusted") {
            return ConnectionFailureDiagnosis(
                shortReason: "Trust or control rejected",
                whyFailed: "\"\(hostName)\" rejected the connection or control request because this Mac is not in its Trusted Hosts list.",
                howToFix: "Click Re-pair, or open Unimacs > Settings > Trusted Hosts on \"\(hostName)\" to allow this Mac.",
                actions: [
                    .repairDevice(hostId: hostId, hostName: hostName),
                    .retryConnection(hostId: hostId, hostName: hostName)
                ]
            )
        }

        // 4. Incompatible protocol version
        if normalized.contains("incompatible protocol") || normalized.contains("protocol version") {
            return ConnectionFailureDiagnosis(
                shortReason: "Incompatible app version",
                whyFailed: rawReason ?? "The two Macs are running incompatible versions of Unimacs.",
                howToFix: "Update Unimacs to the same version on both Macs, then click Retry Now.",
                actions: [
                    .retryConnection(hostId: hostId, hostName: hostName)
                ]
            )
        }

        // 5. Missing target IP address
        if cleanAddress.isEmpty {
            return ConnectionFailureDiagnosis(
                shortReason: "No IP address for device",
                whyFailed: "No IPv4 address is known for \"\(hostName)\". Bonjour discovery has not resolved its address yet.",
                howToFix: "Ensure \"\(hostName)\" is awake and on the same network, then click Reset Network to re-scan.",
                actions: [
                    .resetAllConnections,
                    .retryConnection(hostId: hostId, hostName: hostName)
                ]
            )
        }

        // 6. Check if user manually bound a specific local IP that cannot reach target subnet
        if NetworkUtils.isSpecificBindableIP(selectedLocalIP) {
            let matchingBoundInterface = localInterfaces.first { $0.ipAddress == selectedLocalIP }
            if matchingBoundInterface == nil {
                return ConnectionFailureDiagnosis(
                    shortReason: "Bound IP (\(selectedLocalIP)) inactive",
                    whyFailed: "Unimacs is configured to use local IP \(selectedLocalIP), which is no longer active on this Mac.",
                    howToFix: "Open Network Settings and switch the network binding to 0.0.0.0 (All Interfaces) or an active IP.",
                    actions: [
                        .openNetworkSettings,
                        .resetAllConnections,
                        .retryConnection(hostId: hostId, hostName: hostName)
                    ]
                )
            } else if let boundIface = matchingBoundInterface,
                      !boundIface.isInSameSubnet(targetIP: cleanAddress),
                      localInterfaces.contains(where: { $0.isInSameSubnet(targetIP: cleanAddress) }) {
                return ConnectionFailureDiagnosis(
                    shortReason: "Bound IP (\(selectedLocalIP)) on wrong subnet",
                    whyFailed: "Your selected local IP (\(selectedLocalIP) on \(boundIface.name)) is on a different subnet than \"\(hostName)\" (\(cleanAddress)).",
                    howToFix: "Open Network Settings and change the bound IP to match the subnet of \(cleanAddress) or select 0.0.0.0.",
                    actions: [
                        .openNetworkSettings,
                        .retryConnection(hostId: hostId, hostName: hostName)
                    ]
                )
            }
        }

        // 7. Check subnet mismatch across all active interfaces
        let sameSubnetInterfaces = localInterfaces.filter { $0.isInSameSubnet(targetIP: cleanAddress) }
        let localIPSummary = localInterfaces.map { "\($0.ipAddress) (\($0.name))" }.joined(separator: ", ")
        let isDifferentSubnet = sameSubnetInterfaces.isEmpty

        var defaultActions: [ActivityFixAction] = [
            .retryConnection(hostId: hostId, hostName: hostName),
            .pingHost(hostId: hostId, hostName: hostName, address: cleanAddress),
            .resetAllConnections
        ]
        if isDifferentSubnet {
            defaultActions.append(.openNetworkSettings)
        }

        // 8. Connection refused (ECONNREFUSED / port closed)
        if normalized.contains("refused") || normalized.contains("econnrefused") || normalized.contains("error 61") || normalized.contains("errno=61") {
            return ConnectionFailureDiagnosis(
                shortReason: "Connection refused (\(endpointText))",
                whyFailed: "\"\(hostName)\" at \(endpointText) is reachable on the network, but refused the TCP connection. Unimacs may have quit on that Mac or its listening port changed.",
                howToFix: "Make sure Unimacs is running on \"\(hostName)\". If it restarted on a new port, click Reset Network to refresh its Bonjour port.",
                actions: defaultActions
            )
        }

        // 9. Host / network unreachable (EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN, EADDRNOTAVAIL)
        if normalized.contains("unreachable") || normalized.contains("no route") || normalized.contains("ehostunreach") || normalized.contains("enetunreach") || normalized.contains("ehostdown") || normalized.contains("eaddrnotavail") {
            let subnetNote = isDifferentSubnet
                ? " This Mac is on [\(localIPSummary)], which is a different subnet from \(cleanAddress) (cached IP may be stale after a network switch)."
                : ""
            return ConnectionFailureDiagnosis(
                shortReason: isDifferentSubnet ? "Unreachable (different subnet)" : "No route to \(cleanAddress)",
                whyFailed: "macOS cannot route traffic to \(endpointText).\(subnetNote)",
                howToFix: "Verify both Macs are connected to the same Wi-Fi/LAN without VPN or AP isolation, then click Reset Network to refresh IP addresses.",
                actions: defaultActions
            )
        }

        // 10. DNS / Host resolution failure
        if normalized.contains("resolve") {
            return ConnectionFailureDiagnosis(
                shortReason: "Address resolution failed",
                whyFailed: "Could not resolve address \"\(cleanAddress)\" for \"\(hostName)\".",
                howToFix: "Click Reset Network to restart Bonjour mDNS discovery and obtain a fresh IP address.",
                actions: defaultActions
            )
        }

        // 11. Closed during handshake / identification
        if normalized.contains("handshake") || normalized.contains("identification") || normalized.contains("closed by peer") {
            return ConnectionFailureDiagnosis(
                shortReason: "Closed during handshake",
                whyFailed: "TCP connected to \(endpointText), but \"\(hostName)\" closed the connection before completing device identification.",
                howToFix: "If a VPN or proxy tunnel is intercepting local traffic, disable it or exclude local LAN IPs, then click Retry Now.",
                actions: defaultActions
            )
        }

        // 12. Timeout (ETIMEDOUT / 5s connect timeout / waiting timeout)
        if normalized.contains("timeout") || normalized.contains("timed out") || normalized.contains("waiting") {
            if isDifferentSubnet {
                return ConnectionFailureDiagnosis(
                    shortReason: "Timed out (subnet mismatch: \(cleanAddress))",
                    whyFailed: "Connection to \(endpointText) timed out after 5s. This Mac is on [\(localIPSummary)], which is a different subnet from \(cleanAddress) (the remote IP may have changed).",
                    howToFix: "Ensure both Macs are on the same Wi-Fi/LAN, then click Reset Network to discover \"\(hostName)\"'s new IP address.",
                    actions: defaultActions
                )
            }
            let bonjourHint = isBonjourOnline
                ? "\"\(hostName)\" is visible via Bonjour, so a firewall, VPN tunnel, or macOS Local Network privacy setting may be blocking TCP port \(targetPort)."
                : "\"\(hostName)\" may be asleep, powered off, or disconnected from Wi-Fi."
            return ConnectionFailureDiagnosis(
                shortReason: "Connection timed out (\(endpointText))",
                whyFailed: "No response from \(endpointText) within 5s. \(bonjourHint)",
                howToFix: "Wake \"\(hostName)\", check firewall/VPN settings on both Macs, or click Ping Host / Reset Network.",
                actions: defaultActions
            )
        }

        // 13. Fallback generic failure
        if isDifferentSubnet {
            return ConnectionFailureDiagnosis(
                shortReason: "Subnet mismatch (\(cleanAddress))",
                whyFailed: "Could not connect to \(endpointText). This Mac is on [\(localIPSummary)], which does not match the subnet of \(cleanAddress).",
                howToFix: "Make sure both Macs are connected to the same Wi-Fi/LAN and click Reset Network to refresh device IPs.",
                actions: defaultActions
            )
        }

        let rawDetail = (rawReason?.isEmpty == false) ? " (\(rawReason!))" : ""
        return ConnectionFailureDiagnosis(
            shortReason: rawReason?.isEmpty == false ? rawReason! : "Connection failed (\(endpointText))",
            whyFailed: "Failed to establish TCP connection to \"\(hostName)\" at \(endpointText)\(rawDetail).",
            howToFix: "Ensure Unimacs is running on \"\(hostName)\" and both Macs are on the same local network, then click Retry Now or Reset Network.",
            actions: defaultActions
        )
    }

    /// Convert a POSIX errno into a concise human-readable description.
    static func describePosixError(_ errorCode: Int32, port: Int32 = 0) -> String {
        switch errorCode {
        case ECONNREFUSED:
            return port > 0 ? "Connection refused (port \(port) closed)" : "Connection refused"
        case ETIMEDOUT:
            return "Connection timed out"
        case EHOSTUNREACH:
            return "No route to host (host unreachable)"
        case ENETUNREACH:
            return "Network is unreachable"
        case EHOSTDOWN:
            return "Remote host is down"
        case ENETDOWN:
            return "Local network interface is down"
        case EADDRNOTAVAIL:
            return "Address not available"
        case ECONNRESET:
            return "Connection reset by peer"
        case EPIPE:
            return "Broken pipe (connection closed)"
        default:
            if errorCode > 0, let cStr = strerror(errorCode) {
                return "\(String(cString: cStr)) (errno=\(errorCode))"
            }
            return "Socket error (\(errorCode))"
        }
    }
}

// MARK: - Network & Display Diff Formatters

enum NetworkChangeFormatter {
    struct DiffResult: Equatable, Sendable {
        let level: ActivityLogLevel
        let title: String
        let detail: String
        let actions: [ActivityFixAction]
    }

    /// Compare previous and current active IPv4 interfaces and produce a user-friendly log summary.
    /// Returns nil if nothing meaningful changed.
    static func describeChange(
        previous: [NetworkInterfaceInfo],
        current: [NetworkInterfaceInfo]
    ) -> DiffResult? {
        let prevMap = Dictionary(grouping: previous, by: { $0.name }).compactMapValues { $0.first?.ipAddress }
        let currMap = Dictionary(grouping: current, by: { $0.name }).compactMapValues { $0.first?.ipAddress }

        if prevMap == currMap {
            return nil
        }

        if currMap.isEmpty {
            let prevSummary = prevMap.keys.sorted().compactMap { key in
                prevMap[key].map { "\(key): \($0)" }
            }.joined(separator: ", ")
            return DiffResult(
                level: .error,
                title: "Network disconnected (no active IPv4 address)",
                detail: prevSummary.isEmpty
                    ? "All supported network interfaces (Wi-Fi / Ethernet) are offline."
                    : "Lost IPv4 connectivity on [\(prevSummary)]. Waiting for network recovery.",
                actions: [.openNetworkSettings]
            )
        }

        if prevMap.isEmpty {
            let currSummary = currMap.keys.sorted().compactMap { key in
                currMap[key].map { "\($0) (\(key))" }
            }.joined(separator: ", ")
            return DiffResult(
                level: .success,
                title: "Network connected: \(currSummary)",
                detail: "Local IPv4 network is active. Refreshing Bonjour discovery and paired device connections.",
                actions: []
            )
        }

        var changes: [String] = []
        let allInterfaces = Set(prevMap.keys).union(currMap.keys).sorted()
        for iface in allInterfaces {
            switch (prevMap[iface], currMap[iface]) {
            case let (oldIP?, newIP?) where oldIP != newIP:
                changes.append("\(iface) IP updated \(oldIP) → \(newIP)")
            case (nil, let newIP?):
                changes.append("\(iface) joined (\(newIP))")
            case (let oldIP?, nil):
                changes.append("\(iface) disconnected (was \(oldIP))")
            default:
                break
            }
        }

        guard !changes.isEmpty else { return nil }

        let activeSummary = currMap.keys.sorted().compactMap { key in
            currMap[key].map { "\($0) (\(key))" }
        }.joined(separator: ", ")

        let title = changes.count == 1
            ? "Network updated: \(changes[0])"
            : "Network configuration changed (\(changes.joined(separator: "; ")))"

        return DiffResult(
            level: .info,
            title: title,
            detail: "Active local IPv4 addresses: \(activeSummary)",
            actions: [.resetAllConnections]
        )
    }
}

enum DisplayChangeFormatter {
    struct ScreenSummary: Equatable, Sendable {
        let width: Int
        let height: Int

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        init(rect: CGRect) {
            self.width = Int(rect.width.rounded())
            self.height = Int(rect.height.rounded())
        }

        var label: String {
            "\(width)×\(height)"
        }
    }

    static func summarize(_ screens: [ScreenSummary]) -> String {
        guard !screens.isEmpty else { return "0 screens" }
        let countStr = "\(screens.count) screen\(screens.count == 1 ? "" : "s")"
        let dims = screens.map { $0.label }.joined(separator: ", ")
        return "\(countStr) (\(dims))"
    }

    static func describeLocalScreenChange(
        previous: [ScreenSummary],
        current: [ScreenSummary]
    ) -> (title: String, detail: String)? {
        guard previous != current else { return nil }

        let prevText = summarize(previous)
        let currText = summarize(current)

        let title: String
        if previous.count != current.count {
            title = "Local display count changed: \(previous.count) → \(current.count) screen\(current.count == 1 ? "" : "s")"
        } else {
            title = "Local display resolution or arrangement updated (\(currText))"
        }

        let detail = "Changed from \(prevText) to \(currText). Updated screen edge hot borders and Bonjour display broadcast."
        return (title, detail)
    }

    static func describeLocalScreenChange(
        previous: [CGRect],
        current: [CGRect]
    ) -> (title: String, detail: String) {
        let prevSummaries = previous.map { ScreenSummary(rect: $0) }
        let currSummaries = current.map { ScreenSummary(rect: $0) }
        if let result = describeLocalScreenChange(previous: prevSummaries, current: currSummaries) {
            return result
        }
        let currText = summarize(currSummaries)
        return (
            "Local display arrangement updated (\(currText))",
            "Updated local screen coordinates, hot borders, and Bonjour display broadcast."
        )
    }

    static func describeRemoteScreenChange(
        hostName: String,
        previous: [CGRect],
        current: [CGRect]
    ) -> (title: String, detail: String) {
        let prevSummaries = previous.map { ScreenSummary(rect: $0) }
        let currSummaries = current.map { ScreenSummary(rect: $0) }
        let prevText = summarize(prevSummaries)
        let currText = summarize(currSummaries)

        let title: String
        if previous.count != current.count {
            title = "\(hostName) display count changed: \(previous.count) → \(current.count) screen\(current.count == 1 ? "" : "s")"
        } else {
            title = "\(hostName) display resolution or layout updated (\(currText))"
        }
        let detail = "\(hostName) screens changed from \(prevText) to \(currText)."
        return (title, detail)
    }
}

enum ActivityLogDrawerGeometry {
    struct Metrics: Equatable, Sendable {
        let clampedProgress: CGFloat
        let collapsedTotalHeight: CGFloat
        let fullExpandedHeight: CGFloat
        let currentVisibleHeight: CGFloat
        let chevronRotationDegrees: Double
        let shadowHeight: CGFloat
        let shadowOpacity: Double
    }

    static func computeMetrics(
        revealProgress: CGFloat,
        collapsedHeaderHeight: CGFloat,
        expandedBodyHeight: CGFloat,
        isDarkMode: Bool
    ) -> Metrics {
        let clamped = min(max(revealProgress.isFinite ? revealProgress : 0, 0), 1)
        let safeHeader = max(0, collapsedHeaderHeight.isFinite ? collapsedHeaderHeight : 0)
        let safeBody = max(0, expandedBodyHeight.isFinite ? expandedBodyHeight : 0)
        let collapsedTotal = safeHeader + 1
        let fullExpanded = collapsedTotal + safeBody
        let currentVisible = collapsedTotal + safeBody * clamped
        let chevronDeg = Double(clamped) * 180.0
        let shadowH = 3 + 3 * clamped
        let shadowOp = isDarkMode
            ? (0.10 + 0.18 * Double(clamped))
            : (0.025 + 0.045 * Double(clamped))
        return Metrics(
            clampedProgress: clamped,
            collapsedTotalHeight: collapsedTotal,
            fullExpandedHeight: fullExpanded,
            currentVisibleHeight: currentVisible,
            chevronRotationDegrees: chevronDeg,
            shadowHeight: shadowH,
            shadowOpacity: shadowOp
        )
    }
}

enum LayoutDisplayAvailabilityPolicy {
    static func resolveRemoteStatus(
        isConnectedLink: Bool,
        isConnecting: Bool,
        isReconnecting: Bool,
        isBonjourOnline: Bool,
        isControlled: Bool
    ) -> (isConnected: Bool, statusLabel: String?) {
        if isConnectedLink || isControlled {
            return (true, nil)
        }
        if isConnecting {
            return (false, "Connecting…")
        }
        if isReconnecting {
            return (false, "Reconnecting…")
        }
        if isBonjourOnline {
            return (false, "Disconnected")
        }
        return (false, "Offline")
    }

    static func shouldDisplayRemoteLayout(
        candidateRect: CGRect,
        isConnected: Bool,
        showConnectedOnly: Bool = false,
        activeConnectedRects: [CGRect],
        overlapTolerance: CGFloat = 8
    ) -> Bool {
        guard !candidateRect.isNull, candidateRect.width > 0, candidateRect.height > 0 else {
            return false
        }
        if isConnected {
            return true
        }
        if showConnectedOnly {
            return false
        }
        let overlapsConnected = activeConnectedRects.contains { activeRect in
            let inter = activeRect.intersection(candidateRect)
            return !inter.isNull && inter.width > overlapTolerance && inter.height > overlapTolerance
        }
        return !overlapsConnected
    }
}

// MARK: - Activity Log Manager

@MainActor
final class ActivityLogManager: ObservableObject {

    static let shared = ActivityLogManager()

    @Published private(set) var entries: [ActivityLogEntry] = []
    @Published var isDrawerExpanded: Bool = false {
        didSet {
            if isDrawerExpanded {
                unreadIssueCount = 0
            }
        }
    }
    @Published var selectedCategory: ActivityLogCategory? = nil
    @Published var selectedHostId: String? = nil
    @Published var showIssuesOnly: Bool = false
    @Published var searchText: String = ""
    @Published var unreadIssueCount: Int = 0
    @Published var isPingingHostIds: Set<String> = []

    /// Callback wired by SettingsView to switch to the Settings tab when requested.
    var onNavigateToSettingsTab: (() -> Void)?
    /// Optional action interceptor used for unit testing fix action execution.
    var customActionHandler: ((ActivityFixAction) -> Bool)?

    let maxEntries: Int
    let deduplicationWindow: TimeInterval

    init(maxEntries: Int = 300, deduplicationWindow: TimeInterval = 30.0) {
        self.maxEntries = max(10, maxEntries)
        self.deduplicationWindow = max(0, deduplicationWindow)
    }

    // MARK: - Logging API

    func log(
        level: ActivityLogLevel,
        category: ActivityLogCategory,
        title: String,
        detail: String? = nil,
        howToFix: String? = nil,
        hostId: String? = nil,
        hostName: String? = nil,
        actions: [ActivityFixAction] = [],
        now: Date = Date()
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDetail = (trimmedDetail?.isEmpty == false) ? trimmedDetail : nil
        let trimmedFix = howToFix?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFix = (trimmedFix?.isEmpty == false) ? trimmedFix : nil

        // Deduplicate against the most recent entry (or recent entry for the same host) within window
        if let index = entries.firstIndex(where: {
            now.timeIntervalSince($0.timestamp) <= deduplicationWindow &&
            $0.matchesDeduplicationKey(
                level: level,
                category: category,
                title: trimmedTitle,
                detail: normalizedDetail,
                howToFix: normalizedFix,
                hostId: hostId
            )
        }) {
            var updated = entries.remove(at: index)
            updated.timestamp = now
            updated.occurrenceCount += 1
            if !actions.isEmpty {
                updated.actions = actions
            }
            entries.insert(updated, at: 0)
        } else {
            let entry = ActivityLogEntry(
                timestamp: now,
                level: level,
                category: category,
                title: trimmedTitle,
                detail: normalizedDetail,
                howToFix: normalizedFix,
                hostId: hostId,
                hostName: hostName,
                actions: actions
            )
            entries.insert(entry, at: 0)
            if entries.count > maxEntries {
                entries.removeLast(entries.count - maxEntries)
            }
        }

        if level.isIssue && !isDrawerExpanded {
            unreadIssueCount += 1
        }
    }

    // MARK: - Filtering & Queries

    var filteredEntries: [ActivityLogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            if let category = selectedCategory, entry.category != category {
                return false
            }
            if let hostId = selectedHostId, entry.hostId != hostId {
                return false
            }
            if showIssuesOnly && !entry.level.isIssue {
                return false
            }
            if !query.isEmpty {
                let matchesTitle = entry.title.lowercased().contains(query)
                let matchesDetail = entry.detail?.lowercased().contains(query) ?? false
                let matchesHost = entry.hostName?.lowercased().contains(query) ?? false
                let matchesCategory = entry.category.displayName.lowercased().contains(query)
                if !matchesTitle && !matchesDetail && !matchesHost && !matchesCategory {
                    return false
                }
            }
            return true
        }
    }

    /// Distinct hosts represented in the log history for quick filtering.
    var availableHostFilters: [(id: String, name: String)] {
        var seen = Set<String>()
        var result: [(id: String, name: String)] = []
        for entry in entries {
            if let id = entry.hostId, let name = entry.hostName, !id.isEmpty, !name.isEmpty {
                if seen.insert(id).inserted {
                    result.append((id: id, name: name))
                }
            }
        }
        return result
    }

    var knownHostsInLog: [(id: String, name: String)] {
        availableHostFilters
    }

    var latestEntry: ActivityLogEntry? {
        entries.first
    }

    var issueCount: Int {
        entries.filter { $0.level.isIssue }.count
    }

    // MARK: - Presentation & Management

    func toggleDrawer() {
        isDrawerExpanded.toggle()
        if isDrawerExpanded {
            unreadIssueCount = 0
        }
    }

    func revealLogs(forHostId hostId: String? = nil, issuesOnly: Bool = false) {
        presentDrawer(forHostId: hostId, issuesOnly: issuesOnly)
    }

    func presentDrawer(forHostId hostId: String? = nil, issuesOnly: Bool = false) {
        if let hostId = hostId {
            selectedHostId = hostId
        }
        if issuesOnly {
            showIssuesOnly = true
        }
        selectedCategory = nil
        isDrawerExpanded = true
        unreadIssueCount = 0
    }

    func resetFilters() {
        selectedCategory = nil
        selectedHostId = nil
        showIssuesOnly = false
        searchText = ""
    }

    func clear() {
        entries.removeAll()
        unreadIssueCount = 0
    }

    func copyExportedTextToPasteboard() {
        let text = exportFormattedText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportFormattedText(from targetEntries: [ActivityLogEntry]? = nil) -> String {
        let list = targetEntries ?? filteredEntries
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        return list.map { entry in
            var header = "[\(formatter.string(from: entry.timestamp))] [\(entry.level.displayName.uppercased())] [\(entry.category.displayName)]"
            if let hostName = entry.hostName {
                header += " [\(hostName)]"
            }
            header += " \(entry.title)"
            if entry.occurrenceCount > 1 {
                header += " (×\(entry.occurrenceCount))"
            }
            var lines = [header]
            if let detail = entry.detail {
                lines.append("  \(detail.replacingOccurrences(of: "\n", with: "\n  "))")
            }
            if let howToFix = entry.howToFix {
                lines.append("  How to fix: \(howToFix.replacingOccurrences(of: "\n", with: "\n  "))")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: - Executing Fix Actions

    func performAction(_ action: ActivityFixAction) {
        if let customActionHandler = customActionHandler, customActionHandler(action) {
            return
        }
        switch action {
        case .retryConnection(let hostId, let hostName):
            #if !STANDALONE_UNIT_TEST
            if let host = HostDevicesManager.shared.host(withIdentifier: hostId) {
                host.lastError = nil
                log(
                    level: .info,
                    category: .connection,
                    title: "Manual retry initiated for \(host.computerName)",
                    detail: "Resetting retry counter and dialing \(host.address ?? host.computerName):\(host.port) immediately.",
                    hostId: host.identifier,
                    hostName: host.computerName
                )
                _ = DeviceConnectionManager.shared.connect(to: host, resetRetryBudget: true, ignoreIdRule: true)
            } else {
                log(
                    level: .warning,
                    category: .connection,
                    title: "Device \(hostName) not found in host table",
                    detail: "Refreshing network discovery to locate \(hostName).",
                    hostId: hostId,
                    hostName: hostName
                )
                MainController.shared().resetAllConnections()
            }
            #else
            log(
                level: .info,
                category: .connection,
                title: "Manual retry initiated for \(hostName)",
                hostId: hostId,
                hostName: hostName
            )
            #endif

        case .resetAllConnections:
            log(
                level: .info,
                category: .network,
                title: "Resetting all network connections and Bonjour discovery",
                detail: "Restarted local listener, Bonjour service broadcast, mDNS browser, and re-initiated connections to paired Macs."
            )
            #if !STANDALONE_UNIT_TEST
            MainController.shared().resetAllConnections()
            #endif

        case .repairDevice(let hostId, let hostName):
            #if !STANDALONE_UNIT_TEST
            if let host = HostDevicesManager.shared.host(withIdentifier: hostId) {
                host.lastError = nil
                log(
                    level: .info,
                    category: .connection,
                    title: "Sending pairing request to \(host.computerName)…",
                    detail: "Connecting to \(host.address ?? host.computerName):\(host.port) to request trust authorization.",
                    hostId: host.identifier,
                    hostName: host.computerName
                )
                _ = AuthenticationManager.default.requestAuthentication(on: host)
            } else {
                log(
                    level: .warning,
                    category: .connection,
                    title: "Cannot re-pair with \(hostName): device not found",
                    detail: "Make sure \(hostName) is online and visible in Nearby Devices.",
                    hostId: hostId,
                    hostName: hostName,
                    actions: [.resetAllConnections]
                )
            }
            #else
            log(
                level: .info,
                category: .connection,
                title: "Sending pairing request to \(hostName)…",
                hostId: hostId,
                hostName: hostName
            )
            #endif

        case .pingHost(let hostId, let hostName, let address):
            runDiagnosticPing(hostId: hostId, hostName: hostName, address: address)

        case .openNetworkSettings:
            onNavigateToSettingsTab?()

        case .openAccessibilitySettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func runDiagnosticPing(hostId: String, hostName: String, address: String) {
        guard !address.isEmpty, !isPingingHostIds.contains(hostId) else { return }
        isPingingHostIds.insert(hostId)

        log(
            level: .info,
            category: .network,
            title: "Pinging \(hostName) (\(address))…",
            detail: "Testing ICMP reachability from local network interfaces.",
            hostId: hostId,
            hostName: hostName
        )

        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/ping")
            process.arguments = ["-c", "2", "-t", "3", address]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            var outputText = ""
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                outputText = String(data: data, encoding: .utf8) ?? ""
            } catch {
                outputText = error.localizedDescription
            }

            let succeeded = process.terminationStatus == 0 && outputText.contains("bytes from")
            let rttLine = outputText
                .components(separatedBy: .newlines)
                .first { $0.contains("round-trip") || $0.contains("bytes from") }
                ?? outputText.trimmingCharacters(in: .whitespacesAndNewlines)

            await MainActor.run {
                self.isPingingHostIds.remove(hostId)
                if succeeded {
                    self.log(
                        level: .success,
                        category: .network,
                        title: "Ping to \(hostName) (\(address)) succeeded",
                        detail: "IP \(address) is reachable (\(rttLine)). If Unimacs still cannot connect, verify Unimacs is running on \(hostName) and firewall rules allow TCP connections.",
                        hostId: hostId,
                        hostName: hostName,
                        actions: [.retryConnection(hostId: hostId, hostName: hostName)]
                    )
                } else {
                    self.log(
                        level: .error,
                        category: .network,
                        title: "Ping to \(hostName) (\(address)) failed (host unreachable)",
                        detail: "ICMP ping received no reply from \(address). The remote Mac may be asleep, on a different Wi-Fi/VLAN, blocked by VPN/AP isolation, or its IP address has changed.",
                        hostId: hostId,
                        hostName: hostName,
                        actions: [
                            .resetAllConnections,
                            .openNetworkSettings,
                            .retryConnection(hostId: hostId, hostName: hostName)
                        ]
                    )
                }
            }
        }
    }
}
