// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

let RecordTXTVersionKey = "txtvers"
let RecordTXTVersionValue = "1"

let RecordIDKey = "id"
let RecordNameKey = "name"
let RecordProtocolVersionKey = "protocol"
let RecordScreenSizesKey = "screen-sizes"
let RecordCapabilitiesKey = "capabilities"
let RecordOSVersionKey = "os-vers"
let RecordSelectedServiceIpAddressKey = "service-ip"
let RecordHideIfNotPairedKey = "hide"
let RecordMacAddressesKey = "mac-addrs"

class TXTRecord {
	
	static let currentTXTVersion = 1
	static let currentProtocolVersion = PROTOCOL_VERSION

    let txtVersion: Int
    let protocolVersion: Int
    let id: String
    let name: String
    let screens: String
    let capabilities: UInt
    let osVersion: Int
    let serviceIp: String
    let hideIfNotPaired: Int
    let macAddresses: [IOEthernetAddress]

    init(
        version: Int,
        protocolVersion: Int,
        id: String,
        name: String,
        screens: String,
        capabilities: UInt,
        osVersion: Int,
        serviceIp: String,
        hideIfNotPaired: Int,
        macAddresses: [IOEthernetAddress] = []
    ) {
        self.txtVersion = version
        self.protocolVersion = protocolVersion
        self.id = id
        self.name = name
        self.screens = screens
        self.capabilities = capabilities
        self.osVersion = osVersion
        self.serviceIp = serviceIp
        self.hideIfNotPaired = hideIfNotPaired
        self.macAddresses = macAddresses
    }
	
	func isTXTRecordCompatible() -> Bool {
		if self.txtVersion == Self.currentTXTVersion {
			return true
		} else {
			infoLog("TXT version mismatch: \(txtVersion), expected: \(Self.currentTXTVersion)", module: .network)
			return false
		}
	}
	
	func isProtocolCompatible() -> Bool {
		if self.protocolVersion == Self.currentProtocolVersion {
			return true
		} else {
			infoLog("Protocol incompatible: \(protocolVersion) != \(PROTOCOL_VERSION)", module: .network)
			return false
		}
	}

    static func fromLocal() -> TXTRecord {
        let localHost = LocalHost.shared
        let selectedIp = NetworkConfigurationWatcher.shared.selectedLocalIpAddress
        let selectedIpAddress = NetworkUtils.isSpecificBindableIP(selectedIp) ? selectedIp : ""

        return TXTRecord(
			version: Self.currentTXTVersion,
            protocolVersion: PROTOCOL_VERSION,
            id: localHost.identifier,
            name: localHost.computerName,
            screens: Screen.string(from: localHost.screens),
            capabilities: localHost.capabilities.rawValue,
            osVersion: localHost.osVersion,
            serviceIp: selectedIpAddress,
            hideIfNotPaired: (PreferencesManager.shared().int(forPref: TRUST_REQUEST_BEHAVIOR) == TRUST_REQUEST_REJECT)
                ? 1 : 0,
            macAddresses: localHost.macAddresses
        )
    }

    static func from(data: Data?) -> TXTRecord? {
        data.map({ from(data: $0) })
    }

    static func from(data: Data) -> TXTRecord {
        let dict = NetService.dictionary(fromTXTRecord: data).compactMapValues({ String(data: $0, encoding: .utf8) })
        return TXTRecord(
            version: dict[RecordTXTVersionKey].flatMap { Int($0) } ?? 0,
            protocolVersion: dict[RecordProtocolVersionKey].flatMap { Int($0) } ?? 0,
            id: dict[RecordIDKey] ?? "",
            name: dict[RecordNameKey] ?? "",
            screens: dict[RecordScreenSizesKey] ?? "",
            capabilities: dict[RecordCapabilitiesKey].flatMap({ string in UInt(string) }) ?? 0,
            osVersion: dict[RecordOSVersionKey].flatMap({ string in Int(string) }) ?? 0,
            serviceIp: dict[RecordSelectedServiceIpAddressKey] ?? "",
            hideIfNotPaired: 0,
            macAddresses: Self.parseMacAddresses(dict[RecordMacAddressesKey])
        )
    }
    
    /// Parse MAC addresses from string format "aa:bb:cc:dd:ee:ff,11:22:33:44:55:66"
    private static func parseMacAddresses(_ string: String?) -> [IOEthernetAddress] {
        guard let string = string, !string.isEmpty else { return [] }
        return string.components(separatedBy: ",").compactMap { IOEthernetAddress(string: $0) }
    }

    func toData() -> Data {
        // Format MAC addresses as "aa:bb:cc:dd:ee:ff,11:22:33:44:55:66"
        let macAddressesString = macAddresses.map { $0.description }.joined(separator: ",")
        
        let dict = [
            RecordTXTVersionKey: String(self.txtVersion),
            RecordIDKey: self.id,
            RecordNameKey: self.name,
            RecordProtocolVersionKey: String(self.protocolVersion),
            RecordScreenSizesKey: self.screens,
            RecordCapabilitiesKey: String(self.capabilities),
            RecordOSVersionKey: String(self.osVersion),
            RecordSelectedServiceIpAddressKey: self.serviceIp,
            RecordHideIfNotPairedKey: String(self.hideIfNotPaired),
            RecordMacAddressesKey: macAddressesString,
        ].compactMapValues { $0.isEmpty ? nil : $0.data(using: .utf8) }

        return NetService.data(fromTXTRecord: dict)
    }
}
