// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import Darwin

enum WakeOnLanSender {

    static let wolPort: UInt16 = 9
    static let magicPacketLength = 102

    static func buildMagicPacket(macBytes: [UInt8]) -> Data? {
        guard macBytes.count == 6, macBytes.contains(where: { $0 != 0 }) else {
            return nil
        }
        var bytes = [UInt8](repeating: 0xFF, count: 6)
        bytes.reserveCapacity(magicPacketLength)
        for _ in 0..<16 {
            bytes.append(contentsOf: macBytes)
        }
        return Data(bytes)
    }

    static func parseMacAddress(_ macString: String) -> [UInt8]? {
        let parts = macString.split(separator: ":")
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        return bytes
    }

    static func sendWakePackets(to macAddresses: [IOEthernetAddress]) {
        let packets = macAddresses.compactMap { buildMagicPacket(macBytes: $0.byteArray) }
        guard !packets.isEmpty else { return }

        let interfaces = NetworkUtils.activeIPv4Interfaces(onlySupported: true)

        DispatchQueue.global(qos: .userInitiated).async {
            for packet in packets {
                var sentOnAnyInterface = false

                for iface in interfaces {
                    if let broadcast = iface.broadcastAddress {
                        if sendUDP(packet: packet, to: broadcast, interfaceName: iface.name) {
                            sentOnAnyInterface = true
                        }
                    }
                    _ = sendUDP(packet: packet, to: "255.255.255.255", interfaceName: iface.name)
                }

                if !sentOnAnyInterface {
                    _ = sendUDP(packet: packet, to: "255.255.255.255", interfaceName: nil)
                }
            }
        }
    }

    @discardableResult
    static func sendUDP(packet: Data, to ipv4Address: String, interfaceName: String?) -> Bool {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var broadcastEnable: Int32 = 1
        _ = setsockopt(
            sock,
            SOL_SOCKET,
            SO_BROADCAST,
            &broadcastEnable,
            socklen_t(MemoryLayout.size(ofValue: broadcastEnable))
        )

        if let interfaceName = interfaceName {
            var ifIndex = if_nametoindex(interfaceName)
            if ifIndex != 0 {
                _ = setsockopt(
                    sock,
                    IPPROTO_IP,
                    IP_BOUND_IF,
                    &ifIndex,
                    socklen_t(MemoryLayout.size(ofValue: ifIndex))
                )
            }
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = wolPort.bigEndian
        guard inet_pton(AF_INET, ipv4Address, &addr.sin_addr) == 1 else {
            return false
        }

        let sent = packet.withUnsafeBytes { rawBuffer -> ssize_t in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sendto(sock, baseAddress, packet.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == packet.count
    }
}
