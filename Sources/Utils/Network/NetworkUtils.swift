// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Represents an active network interface with its IPv4 address and subnet mask
public struct NetworkInterfaceInfo {
    public let name: String
    public let ipAddress: String
    public let subnetMask: String

    /// Check if the given IP address is in the same subnet as this interface
    public func isInSameSubnet(targetIP: String) -> Bool {
        guard let ifIP = Self.ipToUInt32(ipAddress),
              let mask = Self.ipToUInt32(subnetMask),
              let target = Self.ipToUInt32(targetIP) else {
            return false
        }
        return (ifIP & mask) == (target & mask)
    }

    private static func ipToUInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}

public class NetworkUtils {

    public static let anyIPv4Address = "0.0.0.0"
    public static let loopbackIPv4Address = "127.0.0.1"

    /// Whether the interface name is a physical/bridge interface supported by Unimacs (`en*` or `bridge*`).
    public static func isSupportedInterfaceName(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("bridge")
    }

    /// Whether the IP string represents a specific local address rather than a wildcard or loopback address.
    public static func isSpecificBindableIP(_ ip: String) -> Bool {
        !ip.isEmpty && ip != anyIPv4Address && ip != loopbackIPv4Address
    }

    private static func ipv4String(from sockaddrPtr: UnsafePointer<sockaddr>) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        sockaddrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sockaddrInPtr in
            var addr = sockaddrInPtr.pointee.sin_addr
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        }
        return String(cString: buffer)
    }

    /// Returns all active (UP, non-loopback) IPv4 network interfaces.
    /// - Parameter onlySupported: When true, filters to `en*` and `bridge*` interfaces.
    public static func activeIPv4Interfaces(onlySupported: Bool = true) -> [NetworkInterfaceInfo] {
        var interfaces: [NetworkInterfaceInfo] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let addr = interface.ifa_addr else { continue }

            let name = String(cString: interface.ifa_name)
            if onlySupported && !isSupportedInterfaceName(name) {
                continue
            }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let ipAddress = ipv4String(from: addr)
            let subnetMask = interface.ifa_netmask.map { ipv4String(from: $0) } ?? ""

            interfaces.append(NetworkInterfaceInfo(name: name, ipAddress: ipAddress, subnetMask: subnetMask))
        }

        return interfaces
    }

    static func getMacAddresses() -> [IOEthernetAddress] {
        var inet4infs: Set<String> = []
        var addresses = [String: IOEthernetAddress]()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        // Retrieve the current interfaces - returns 0 on success
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        // Iterate through linked list of interfaces
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let addr = interface.ifa_addr else { continue }
            let name = String(cString: interface.ifa_name)

            // Filter for 'en' and 'bridge' prefixes
            guard isSupportedInterfaceName(name) else { continue }

            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                // Check for Link Layer family (MAC address)
                addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sockaddr_dl_ptr in
                    let sdl = sockaddr_dl_ptr.pointee
                    let nameLen = Int(sdl.sdl_nlen)
                    let macLen = Int(sdl.sdl_alen)

                    let address = withUnsafePointer(to: sdl.sdl_data) { tuplePtr in
                        // 2. Rebound the tuple pointer to a UInt8 pointer
                        tuplePtr.withMemoryRebound(to: UInt8.self, capacity: nameLen + macLen) { bytePtr in
                            // 3. Skip the interface name to reach the MAC address bytes
                            let macBase = bytePtr + nameLen
                            return IOEthernetAddress(macBase)
                        }
                    }
                    addresses[name] = address
                }
            case AF_INET:
                inet4infs.insert(name)
            default:
                break
            }
        }

        return Array(addresses.filter { inet4infs.contains($0.key) }.values)
    }

    /// Returns the network interface name for a given IP address
    /// - Parameter ipAddress: The IP address to look up
    /// - Returns: The interface name (e.g., "en0") or nil if not found
    @objc static func interfaceName(forIPAddress ipAddress: String?) -> String? {
        guard let ipAddress = ipAddress else { return nil }

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            perror("getifaddrs")
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let addr = interface.ifa_addr,
                  Int32(addr.pointee.sa_family) == AF_INET else { continue }

            if ipv4String(from: addr) == ipAddress {
                return String(cString: interface.ifa_name)
            }
        }

        return nil
    }

    /// Checks if a network interface is currently UP and has an active IPv4 address
    /// - Parameter interfaceName: The interface name to check (e.g., "en0")
    /// - Returns: True if interface exists, has IFF_UP flag set, and has an IPv4 address assigned
    @objc public static func isInterfaceUp(_ interfaceName: String?) -> Bool {
        guard let interfaceName = interfaceName else { return false }
        return activeIPv4Interfaces(onlySupported: false).contains { $0.name == interfaceName }
    }
}
