// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

class HostBrowser: NSObject, @preconcurrency NetServiceBrowserDelegate {
    private let domain: String
    private var browser: NetServiceBrowser?
    private var resolvers: [String: Resolver] = [:]

    init(domain: String) {
        self.domain = domain
        super.init()
    }

    func start() {
		stop()
		
		let browser = NetServiceBrowser()
		browser.delegate = self
		browser.schedule(in: .main, forMode: .common)

        browser.searchForServices(ofType: RV_SERVICE, inDomain: domain)
		
		self.browser = browser
    }

    func stop() {
		if let browser = self.browser {
			browser.delegate = nil
			browser.remove(from: .main, forMode: .common)
			browser.stop()
		}
		self.browser = nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
		if let resolver = resolvers[service.name] {
			resolver.start()
		} else {
			let resolver = Resolver(service: service)
			resolvers[service.name] = resolver
			resolver.start()
		}
    }

	@MainActor
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        if let resolver = resolvers.removeValue(forKey: service.name) {
            resolver.stop()
        }
    }
}
