// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

public class NetworkUtils {

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
            let name = String(cString: interface.ifa_name)

            // Filter for 'en' and 'bridge' prefixes
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            switch Int32(interface.ifa_addr.pointee.sa_family) {
            case AF_LINK:
                // Check for Link Layer family (MAC address)
                interface.ifa_addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sockaddr_dl_ptr in
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
        
        var foundInterface: String? = nil
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr != nil else { continue }
            
            let family = Int32(interface.ifa_addr.pointee.sa_family)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            
            if family == AF_INET {
                // IPv4
                interface.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sockaddr_in_ptr in
                    var addr = sockaddr_in_ptr.pointee.sin_addr
                    inet_ntop(AF_INET, &addr, &host, socklen_t(host.count))
                }
            } else {
                continue
            }
            
            let hostString = String(cString: host)
            if hostString == ipAddress {
                foundInterface = String(cString: interface.ifa_name)
                break
            }
        }
        
        return foundInterface
    }
}
