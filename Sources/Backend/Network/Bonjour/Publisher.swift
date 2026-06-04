// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

let RV_SERVICE = "_teleport._tcp"

class Publisher: NSObject, NetServiceDelegate {
	@objc nonisolated(unsafe) static let shared: Publisher = Publisher()
	
	private var _publishService: NetService?
	private var port: Int32?
	
	override init() {
		super.init()
		TPLocalHost.shared.observe(observer: self, selector: #selector(updateTXTRecord))
	}
	
	@objc func start(with port: Int32) {
		if _publishService != nil && self.port == port {
			return
		}
		
		stop()
		
		debugLog("Publisher start on port: \(port)", module: .network)
		let service = NetService(domain: "", type: RV_SERVICE, name: TPLocalHost.shared.bonjourName, port: port)
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
	}
	
	func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
		errorLog("Service publish failed: \(sender.name), \(errorDict)", module: .network)
	}
	
	func netServiceDidStop(_ sender: NetService) {
		debugLog("Service stopped: \(sender.name)", module: .network)
	}
}

