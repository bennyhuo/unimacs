// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

let RV_SERVICE = "_unimacs._tcp"

class Publisher: NSObject, NetServiceDelegate {
	@objc nonisolated(unsafe) static let shared: Publisher = Publisher()
	
	private var _publishService: NetService?
	private var port: Int32?
	
	override init() {
		super.init()
		LocalHost.shared.observe(observer: self, selector: #selector(updateTXTRecord))
	}
	
	@objc func start(with port: Int32) {
		if _publishService != nil && self.port == port {
			return
		}
		
		stop()
		
		debugLog("Publisher start on port: \(port)", module: .network)
		let service = NetService(domain: "", type: RV_SERVICE, name: LocalHost.shared.bonjourName, port: port)
		service.delegate = self
		service.publish()

		self._publishService = service
		self.port = port
		
		updateTXTRecord()
	}
	
	@objc func stop() {
		if let service = _publishService {
			service.delegate = nil
			service.stop()
		}
		self._publishService = nil
		self.port = nil
	}
	
	@objc func updateTXTRecord() {
		guard let service = _publishService else {
			return
		}

		if !service.setTXTRecord(TXTRecord.fromLocal().toData()) {
			warningLog("Can't set TXT record data", module: .network)
		}
	}

	func netServiceDidPublish(_ sender: NetService) {
		debugLog("Service published: \(sender.name):\(sender.port)", module: .network)
		let serviceName = sender.name
		let servicePort = sender.port
		Task { @MainActor in
			let ipSummary = NetworkUtils.activeIPv4Interfaces(onlySupported: true)
				.map { "\($0.name): \($0.ipAddress)" }
				.joined(separator: ", ")
			ActivityLogManager.shared.log(
				level: .info,
				category: .discovery,
				title: "Broadcasting this Mac via Bonjour (\(serviceName))",
				detail: "Advertising _unimacs._tcp on port \(servicePort)\(ipSummary.isEmpty ? "" : " (\(ipSummary))")."
			)
		}
	}
	
	func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
		errorLog("Service publish failed: \(sender.name), \(errorDict)", module: .network)
		let serviceName = sender.name
		let errorCode = errorDict[NetService.errorCode]?.intValue ?? 0
		Task { @MainActor in
			ActivityLogManager.shared.log(
				level: .error,
				category: .discovery,
				title: "Bonjour broadcast failed for \(serviceName)",
				detail: "mDNS failed to publish service (error code \(errorCode)). Other Macs may not automatically discover this Mac.",
				howToFix: "Click 'Reset All Connections' to restart the Bonjour publisher, or check your network and firewall settings.",
				actions: [.resetAllConnections, .openNetworkSettings]
			)
		}
	}
	
	func netServiceDidStop(_ sender: NetService) {
		debugLog("Service stopped: \(sender.name)", module: .network)
	}
}

