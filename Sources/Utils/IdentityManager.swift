// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import Security
import CryptoKit

class IdentityManager: NSObject {
	
	nonisolated(unsafe) private static var _potentialIdentities: [SecIdentity]?

	static func keychainRef() -> SecKeychain? {
		var keychain: SecKeychain?
		let status = SecKeychainCopyDefault(&keychain)

		if status == errSecSuccess {
			return keychain
		} else {
			print("Unable to get default keychain: \(status)")
			return nil
		}
	}
	
	static func keySupportsUsage(identity: SecIdentity, desiredUsages: [String]) -> Bool {
		var certificate: SecCertificate?
		guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
			  let cert = certificate else { return false }

		// Extract KeyUsage (OID: 2.5.29.15)
		let keyUsageOID = "2.5.29.15" as CFString
		guard let dict = SecCertificateCopyValues(cert, [keyUsageOID] as CFArray, nil) as? [String: Any],
			  let usageDict = dict[keyUsageOID as String] as? [String: Any],
			  let usageList = usageDict[kSecPropertyKeyValue as String] as? [[String: Any]] else {
			// If no KeyUsage extension exists → assume "allowed"
			return true
		}

		let actualUsages = usageList.compactMap { $0[kSecPropertyKeyValue as String] as? String }
		return actualUsages.contains(where: { desiredUsages.contains($0) })
	}
	
	static func identifier(for identity: SecIdentity) -> String? {
		// Extract unique identity information, such as:
		// certificate's common name, SHA-1, serial number, etc.
		var certificate: SecCertificate?
		if SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
		   let certificate = certificate {
			return SecCertificateCopySubjectSummary(certificate) as String?
		}
		return nil
	}
	
	static func potentialIdentities() -> [SecIdentity] {
		if let cached = _potentialIdentities {
			return cached
		}

		// 1. Get the keychain to search
		guard let keychain = keychainRef() else {
			return []
		}

		// 2. Build query to fetch all identities from the keychain
		let query: [String: Any] = [
			kSecClass as String: kSecClassIdentity,
			kSecReturnRef as String: true,
			kSecMatchLimit as String: kSecMatchLimitAll,
			kSecMatchSearchList as String: [keychain]
		]

		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)

		guard status == errSecSuccess,
			  let identities = result as? [SecIdentity] else {
			if status != errSecItemNotFound {
				print("Error fetching identities: \(status)")
			}
			return []
		}

		// 3. Map CSSM_KEYUSE_* → modern usage strings
		let desiredUsages = [
			"Digital Signature",
			"Key Encipherment",
			"Data Encipherment"
		]

		// 4. Filter by KeyUsage
		let filtered = identities.filter {
			keySupportsUsage(identity: $0, desiredUsages: desiredUsages)
		}

		_potentialIdentities = filtered
		return filtered
	}

	@objc
	static func loadOrderedIdentities() -> [Any] {
		let ids = potentialIdentities()
		let ordered = if let prefId = TPPreferencesManager.shared().value(forPref: Settings.certificateIdentifierKey) as? String {
			ids.sorted { a, b in
				identifier(for: a) == prefId || identifier(for: b) != prefId
			}
		} else {
			ids
		}
		return ordered
	}
	
	@objc
	static func potentialIdentitiesLegacy() -> [Any] {
		potentialIdentities()
	}
	
	@objc
	static func setIdentity(_ identity: SecIdentity?) {
		if let identity = identity {
			let identifier = identifier(for: identity)
			TPPreferencesManager.shared().setValue(identifier, forKey: Settings.certificateIdentifierKey)
		}
		reloadIdentity()
	}
	
	@objc
	static func reloadIdentity() {
		_potentialIdentities = nil
	}
	
	@objc
	static func identity() -> SecIdentity? {
		potentialIdentities().first
	}
	
	@objc
	static func hasIdentity() -> Bool {
		identity() != nil
	}
	
	@objc
	static func identityInfo(_ identity: SecIdentity) -> String {
		var cert: SecCertificate?
		SecIdentityCopyCertificate(identity, &cert)
		guard let cert else { return "No certs found." }

		let summary = SecCertificateCopySubjectSummary(cert) as String? ?? ""

		
		var nameRef: CFString?
		let status = SecCertificateCopyCommonName(cert, &nameRef)
		let name = status == errSecSuccess && nameRef != nil ? nameRef! as String : "Unknown Name"
		
		let data = SecCertificateCopyData(cert) as Data
		let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
		
		return "CN=\(name), Summary=\(summary), SHA256=\(sha256)"
	}
}
