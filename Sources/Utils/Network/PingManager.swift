// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

// MARK: - Constants
// Note: In Swift, you must define constants explicitly.
// Assuming PING_MAX_COUNT was a preprocessor macro defined elsewhere (e.g., "5")
let PING_MAX_COUNT = "30"

/// Represents a network interface with its IPv4 address and subnet mask
private struct InterfaceInfo {
	let name: String
	let ipAddress: String
	let subnetMask: String
	
	/// Check if the given IP address is in the same subnet as this interface
	func isInSameSubnet(targetIP: String) -> Bool {
		guard let ifIP = ipToUInt32(ipAddress),
			  let mask = ipToUInt32(subnetMask),
			  let target = ipToUInt32(targetIP) else {
			return false
		}
		return (ifIP & mask) == (target & mask)
	}
	
	private func ipToUInt32(_ ip: String) -> UInt32? {
		let parts = ip.split(separator: ".").compactMap { UInt32($0) }
		guard parts.count == 4 else { return nil }
		return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
	}
}

/**
 Manages asynchronous ping operations, ensuring only one ping is active per host.
 */
@objcMembers
class PingManager : NSObject {
	// 1. Static storage equivalent to 'static NSMutableDictionary'
	@MainActor private static var tasks: [String: Process] = [:]
	private static let lock = NSLock() // Used for thread-safe access to 'tasks'

	private static func updateTask(host: String, task: Process?) {
		DispatchQueue.main.async {
			if let prevTask = tasks[host] {
				// Terminate previous task for this host
				prevTask.terminate()
			}
			// Store the new task
			tasks[host] = task
		}
	}
	
	/// Get all network interfaces with IPv4 addresses
	private static func getAllInterfaces() -> [InterfaceInfo] {
		var interfaces: [InterfaceInfo] = []
		var ifaddr: UnsafeMutablePointer<ifaddrs>?
		
		guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
		defer { freeifaddrs(ifaddr) }
		
		for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
			let interface = ptr.pointee
			let name = String(cString: interface.ifa_name)
			
			// Filter for 'en' and 'bridge' prefixes (physical/bridge network interfaces)
			guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
			
			// Skip interfaces that are not UP or are LOOPBACK
			guard (interface.ifa_flags & UInt32(IFF_UP)) != 0,
				  (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
			
			// Check for IPv4 family
			guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
			
			// Get IP address
			var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
			interface.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sockaddr_in_ptr in
				var addr = sockaddr_in_ptr.pointee.sin_addr
				inet_ntop(AF_INET, &addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
			}
			let ipAddress = String(cString: ipBuffer)
			
			// Get subnet mask
			var maskBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
			if let netmask = interface.ifa_netmask {
				netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sockaddr_in_ptr in
					var addr = sockaddr_in_ptr.pointee.sin_addr
					inet_ntop(AF_INET, &addr, &maskBuffer, socklen_t(INET_ADDRSTRLEN))
				}
			}
			let subnetMask = String(cString: maskBuffer)
			
			interfaces.append(InterfaceInfo(name: name, ipAddress: ipAddress, subnetMask: subnetMask))
		}
		
		return interfaces
	}
	
	/// Filter interfaces that could potentially reach the target IP (same subnet or all if none match)
	private static func getCandidateInterfaces(for targetIP: String) -> [String] {
		let allInterfaces = getAllInterfaces()
		
		// First, try to find interfaces in the same subnet
		let sameSubnetInterfaces = allInterfaces.filter { $0.isInSameSubnet(targetIP: targetIP) }
		
		if !sameSubnetInterfaces.isEmpty {
			return sameSubnetInterfaces.map { $0.name }
		}
		
		// If no interface is in the same subnet, return all interfaces
		// (the target might be reachable via routing)
		return allInterfaces.map { $0.name }
	}
	
	/**
	 Performs an asynchronous network ping to the specified host.
	 
	 It launches the /sbin/ping command, monitors its output line-by-line,
	 and automatically terminates the ping process upon success or timeout.
	 This method will try different network interfaces sequentially until one succeeds.
	 
	 - Parameter host: The hostname or IP address to ping.
	 */
	static func pingRemoteAsync(host: String) {
		let candidateInterfaces = getCandidateInterfaces(for: host)
		
		if candidateInterfaces.isEmpty {
			debugLog("ping to \(host) - no available interfaces found.")
			return
		}
		
		debugLog("ping to \(host) - candidate interfaces: \(candidateInterfaces)")
		
		// Start pinging with the first interface
		pingWithInterfaces(host: host, interfaces: candidateInterfaces, currentIndex: 0)
	}
	
	/// Recursively try ping on each interface until success or all interfaces exhausted
	private static func pingWithInterfaces(host: String, interfaces: [String], currentIndex: Int) {
		guard currentIndex < interfaces.count else {
			debugLog("ping to \(host) - all interfaces exhausted, no success.")
			DispatchQueue.main.async {
				TPMainController.shared().resetAllConnectionsIfNotInControl()
			}
			return
		}
		
		let interfaceName = interfaces[currentIndex]
		let launchPath = "/sbin/ping"
		
		// Prepare the new Process (Swift equivalent of NSTask)
		let task = Process()
		task.executableURL = URL(fileURLWithPath: launchPath)
		// Use -b to bind to specific interface
		task.arguments = ["-c", PING_MAX_COUNT, "-b", interfaceName, host]

		let pipe = Pipe()
		task.standardOutput = pipe
		task.standardError = pipe // Capture both output and error streams
		
		let outputHandle = pipe.fileHandleForReading
		
		updateTask(host: host, task: task)

		// Track if we've already handled success/failure for this task
		var hasHandledResult = false
		let resultLock = NSLock()

		// Asynchronous Output Handling (readabilityHandler equivalent)
		// Note: The readabilityHandler runs on a background queue.
		outputHandle.readabilityHandler = { handle in
			let data = handle.availableData
			
			// Check for end of file (EOF) or process completion
			if data.isEmpty {
				// Remove handler and potentially clean up state if needed
				handle.readabilityHandler = nil
				return
			}
			
			// Convert data to string and process line-by-line
			if let output = String(data: data, encoding: .utf8) {
				let lines = output.components(separatedBy: .newlines)
				
				for line in lines {
					guard !line.isEmpty else { continue }

					if line.contains("bytes from") {
						resultLock.lock()
						let alreadyHandled = hasHandledResult
						hasHandledResult = true
						resultLock.unlock()
						
						if !alreadyHandled {
							debugLog("ping successfully to \(host) via \(interfaceName).")
							// Success: Terminate the running task
							task.terminate()
							handle.readabilityHandler = nil
						}
						return
					}
					
					if line.contains("Request timeout for icmp_seq \(PING_MAX_COUNT)") {
						resultLock.lock()
						let alreadyHandled = hasHandledResult
						hasHandledResult = true
						resultLock.unlock()
						
						if !alreadyHandled {
							debugLog("ping to \(host) via \(interfaceName) - Timeout. Trying next interface...")
							
							// Timeout detected: Terminate the running task and try next interface
							task.terminate()
							handle.readabilityHandler = nil
							
							// Try next interface
							pingWithInterfaces(host: host, interfaces: interfaces, currentIndex: currentIndex + 1)
						}
						return
					}
				}
			}
		}
		
		// Launch the process
		do {
			try task.run()
			debugLog("ping to \(host) via \(interfaceName) - start.")
		} catch {
			debugLog("Error launching ping task via \(interfaceName): \(error.localizedDescription)")
			// Cleanup task storage on launch failure, try next interface
			updateTask(host: host, task: nil)
			pingWithInterfaces(host: host, interfaces: interfaces, currentIndex: currentIndex + 1)
			return
		}
		
		// Define a termination handler (optional, but good practice)
		// This is primarily for post-cleanup or logging final status.
		task.terminationHandler = { finishedTask in
			// Final cleanup of the task storage
			updateTask(host: host, task: nil)
		}
	}
}
