// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import Darwin

@objcMembers
class WakeOnLan : NSObject {
	static func wakeUpHost(with macAddresses: [IOEthernetAddress]) {
		DispatchQueue.global().async {
			// 1. Run 'arp -a' and find the interface name
			getInterfaceFromARP(for: macAddresses)
				.forEach { (interfaceName, macAddress) in
					debugLog("WOL Debug: Remote host address \(macAddress) found on interface: \(interfaceName)")

					// 2. Get the Subnet/Broadcast info for that interface
					guard let info = getInterfaceBroadcastInfo(for: interfaceName) else {
						debugLog("WOL Error: Could not calculate broadcast for \(interfaceName)")
						return
					}

					// 3. Send the Magic Packet
					_ = sendMagicPacket(mac: macAddress, broadcastAddr: info.broadcast, interfaceName: interfaceName)
				}
		}
	}

	private static func getInterfaceFromARP(for macAddresses: [IOEthernetAddress]) -> [(String, IOEthernetAddress)] {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
		process.arguments = ["-a"]
		
		let pipe = Pipe()
		process.standardOutput = pipe
		
		do {
			try process.run()
			let data = pipe.fileHandleForReading.readDataToEndOfFile()
			if let output = String(data: data, encoding: .utf8) {
				// Typical line: ? (10.2.133.1) at 0:0:c:9f:f0:8f on en0 ifscope ...
				let lines = output.components(separatedBy: .newlines)
				
				return macAddresses.compactMap { macAddress -> (String, IOEthernetAddress)? in
					let address = macAddress.description
					for line in lines where line.contains(address) {
						let parts = line.components(separatedBy: " ")
						if let onIndex = parts.firstIndex(of: "on"), onIndex + 1 < parts.count {
							return (parts[onIndex + 1], macAddress)
						}
					}
					return nil
				}
			}
		} catch {
			debugLog("WOL Error: Failed to execute ARP command: \(error)")
		}
		return []
	}

	private static func getInterfaceBroadcastInfo(for name: String) -> (ip: in_addr_t, broadcast: in_addr_t)? {
		var ifaddr: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
		defer { freeifaddrs(ifaddr) }

		for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
			let ifName = String(cString: ptr.pointee.ifa_name)
			guard ifName == name,
				  let addrPtr = ptr.pointee.ifa_addr,
				  addrPtr.pointee.sa_family == UInt8(AF_INET) else { continue }
			
			let sinArr = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
			let sinMask = ptr.pointee.ifa_netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
			
			let ip = sinArr.sin_addr.s_addr
			let mask = sinMask.sin_addr.s_addr
			let broadcast = ip | ~mask
			
			return (ip, broadcast)
		}
		return nil
	}

	private static func sendMagicPacket(mac: IOEthernetAddress, broadcastAddr: in_addr_t, interfaceName: String) -> Bool {
		var msg = [UInt8](repeating: 0xff, count: 6)
		for _ in 0..<16 {
			msg.append(contentsOf: mac.byteArray)
		}

		let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
		guard sock >= 0 else { return false }
		defer { close(sock) }

		var optval: Int32 = 1
		setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &optval, socklen_t(MemoryLayout.size(ofValue: optval)))

		var ifindex = if_nametoindex(interfaceName)
		setsockopt(sock, IPPROTO_IP, IP_BOUND_IF, &ifindex, socklen_t(MemoryLayout.size(ofValue: ifindex)))

		var bcast = sockaddr_in()
		bcast.sin_len = UInt8(MemoryLayout.size(ofValue: bcast))
		bcast.sin_family = sa_family_t(AF_INET)
		bcast.sin_addr.s_addr = broadcastAddr
		bcast.sin_port = UInt16(9).bigEndian

		var targetAddr = bcast
		let result = withUnsafePointer(to: &targetAddr) { ptr in
			ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
				sendto(sock, msg, msg.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		
		if result >= 0 {
			debugLog("WOL Success: Sent packet to \(in_addr(s_addr: broadcastAddr).presentation) via \(interfaceName)")
		}
		return result >= 0
	}
}

// Fixed: This extension provides the missing 'presentation' property
extension in_addr {
	var presentation: String {
		var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
		var mutableSelf = self
		inet_ntop(AF_INET, &mutableSelf, &buffer, socklen_t(INET_ADDRSTRLEN))
		return String(cString: buffer)
	}
}
