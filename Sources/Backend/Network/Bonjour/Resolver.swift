// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

let resolveTimeout = 10.0

class Resolver: NSObject, @preconcurrency NetServiceDelegate {

    let service: NetService

    private var host: TPRemoteHost? = nil

    init(service: NetService) {
        self.service = service
        super.init()
    }

    func start() {
        self.service.delegate = self
        self.service.resolve(withTimeout: resolveTimeout)
    }

    @MainActor
    func stop() {
        self.service.delegate = nil
        self.service.stop()
        if let host = host {
            TPHostsManager.shared.removeBonjourHost(host)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        warningLog("Resolve failed: \(sender.name), \(errorDict)", module: .network)
    }

    func netServiceDidStop(_ sender: NetService) {
        // Service stopped - no log needed
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        guard let record = TXTRecord.from(data: service.txtRecordData()) else {
            warningLog("Invalid host: no TXT record!", module: .network)
            service.stop()
            return
        }

        if !record.isTXTRecordCompatible() {
            service.stop()
            return
        }

        if record.isProtocolCompatible() {
            guard let ipAddress = service.resolveIpAddress(withSelected: record.serviceIp) else {
                return
            }

            debugLog("Resolved: \(record.id) -> \(ipAddress.address):\(ipAddress.port)", module: .network)

            let remoteHost = TPRemoteHost(with: record, ipAddress: ipAddress)
            remoteHost.hostState = .shared

            if remoteHost != TPLocalHost.shared {
                TPHostsManager.shared.addBonjourHost(remoteHost)
                PingManager.pingRemoteAsync(host: ipAddress.address)
            } else {
                #if DEBUG_BUILD
                    TPHostsManager.shared.addBonjourHost(remoteHost)
                #endif
            }

            self.host = remoteHost
            service.startMonitoring()
        } else {
            guard let ipPort = service.resolveIpAddress(withSelected: record.serviceIp) else { return }
            let remoteHost = TPRemoteHost(with: record, ipAddress: ipPort)
            remoteHost.hostState = .incompatible

            if remoteHost != TPLocalHost.shared {
                TPHostsManager.shared.addBonjourHost(remoteHost)
            }
        }
    }

    @MainActor func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        let record = TXTRecord.from(data: data)
        if let host = host {
			guard let ipAddress = sender.resolveIpAddress(withSelected: record.serviceIp) else {
				return
			}
			
            if record.id == host.identifier {
                host.update(with: record)
				host.address = ipAddress.address
				host.port = ipAddress.port
            } else {
                let newHost = TPRemoteHost(with: record, ipAddress: ipAddress)

                TPHostsManager.shared.removeBonjourHost(host)
                TPHostsManager.shared.addBonjourHost(newHost)
                self.host = newHost
            }
        }
    }
}

extension NetService {

    func txtRecord() -> [String: String]? {
        txtRecordData().flatMap { Self.txtRecord(from: $0) }
    }

    static func txtRecord(from data: Data) -> [String: String] {
        NetService.dictionary(fromTXTRecord: data).compactMapValues({ String(data: $0, encoding: .utf8) })
    }

    func resolveIpAddress(withSelected selectedIpAddress: String) -> IpAddress? {
        guard let addresses = addresses, !addresses.isEmpty else {
            return nil
        }

        let ipAddresses = addresses.compactMap({ IpAddress(with: $0) })

        return ipAddresses.first { $0.address == selectedIpAddress }
            ?? ipAddresses.sorted { a, b in
                a.priority < b.priority || a.address < b.address
            }.first
    }

}
