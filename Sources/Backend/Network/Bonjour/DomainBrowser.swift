// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

class DomainBrowser: NSObject, NetServiceBrowserDelegate {
	@objc nonisolated(unsafe) static let shared = DomainBrowser()
	
    private var _browseService: NetServiceBrowser?
    private var _browsers: [String: HostBrowser] = [:]

	@objc func restart() {
		stop()
		start()
	}
	
    private let localDomain = "local."

    @objc func start() {
        startBrowsing(in: localDomain)

        if _browseService == nil {
            _browseService = NetServiceBrowser()
        }

        _browseService?.schedule(in: .main, forMode: .common)
        _browseService?.delegate = self
        _browseService?.searchForBrowsableDomains()
    }

    private func startBrowsing(in domain: String) {
        guard _browsers[domain] == nil else { return }

        let browser = HostBrowser(domain: domain)
        browser.start()
        _browsers[domain] = browser
        debugLog("Browse started in domain: \(domain)", module: .network)
    }

    @objc func stop() {
		_browseService?.delegate = nil
		_browseService?.remove(from: .main, forMode: .common)
        _browseService?.stop()
        for browser in _browsers.values {
            browser.stop()
        }
        _browsers.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFindDomain domain: String, moreComing: Bool) {
        startBrowsing(in: domain)
        debugLog("Found domain: \(domain)", module: .network)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemoveDomain domain: String, moreComing: Bool) {
        if let browser = _browsers[domain] {
            browser.stop()
            _browsers.removeValue(forKey: domain)
        }
    }
}
