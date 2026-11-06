// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import Combine
import Security
@preconcurrency import ApplicationServices

extension Notification.Name {
	static let TPAccessibilityStatusDidChange = Notification.Name("TPAccessibilityStatusDidChangeNotification")
}

@objc enum AccessibilityIssueKind: Int {
	case none = 0
	case permissionNotGranted = 1
	case signatureRevokedOrExpired = 2
	case signatureChangedOnDisk = 3
}

@objcMembers
class AccessibilityManager: NSObject, ObservableObject {
	
	@objc static let shared = AccessibilityManager()
	
	private(set) var isTrustedState: Bool = false {
		willSet {
			if #available(macOS 13.0, *) {
				objectWillChange.send()
			}
		}
		didSet {
			if oldValue != isTrustedState {
				NotificationCenter.default.post(name: .TPAccessibilityStatusDidChange, object: self)
			}
		}
	}
	
	private(set) var issueKind: AccessibilityIssueKind = .none {
		willSet {
			if #available(macOS 13.0, *) {
				objectWillChange.send()
			}
		}
		didSet {
			if oldValue != issueKind && !isTrustedState {
				NotificationCenter.default.post(name: .TPAccessibilityStatusDidChange, object: self)
			}
		}
	}
	
	private var observer: NSObjectProtocol?
	private var pollTimer: Timer?
	private let signatureCheckQueue = DispatchQueue(label: "com.bennyhuo.unimacs.accessibility.signature", qos: .utility)
	private let launchCDHash: Data?
	private var cachedSignatureIssue: AccessibilityIssueKind = .none
	private var isCheckingSignature: Bool = false
	private var lastSignatureCheckTime: TimeInterval = 0
	private let signatureCheckInterval: TimeInterval = 15.0
	/// True when `CGEvent.tapCreate(.defaultTap)` failed despite `AXIsProcessTrusted()` returning true.
	private var hasObservedEventTapFailure: Bool = false
	
	private override init() {
		self.launchCDHash = Self.readCurrentProcessCDHash()
		super.init()
		let initialSigIssue = Self.evaluateBundleSignature(launchCDHash: self.launchCDHash, allowNetwork: false)
		self.cachedSignatureIssue = initialSigIssue
		self.lastSignatureCheckTime = Date().timeIntervalSince1970
		
		let axTrusted = AXIsProcessTrusted()
		if initialSigIssue != .none {
			self.issueKind = initialSigIssue
			self.isTrustedState = false
		} else if !axTrusted {
			self.issueKind = .permissionNotGranted
			self.isTrustedState = false
		} else {
			self.issueKind = .none
			self.isTrustedState = true
		}
		
		startObserving()
		scheduleSignatureCheck(allowNetwork: true)
	}
	
	deinit {
		stopObserving()
	}
	
	@objc static var isTrusted: Bool {
		return shared.isTrustedState
	}

	@objc static func checkAccessibility() -> Bool {
		let trusted = AXIsProcessTrustedWithOptions([
			kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
		] as CFDictionary)
		shared.refreshNow()
		return trusted && shared.isTrustedState
	}
	
	/// Refreshes trust status immediately on the main thread and schedules an asynchronous signature check.
	@objc func refreshNow() {
		if cachedSignatureIssue == .none {
			cachedSignatureIssue = Self.evaluateBundleSignature(launchCDHash: launchCDHash, allowNetwork: false)
		}
		let effectiveAXTrusted = evaluateEffectiveAXTrust()
		applyEvaluation(axTrusted: effectiveAXTrusted, signatureIssue: cachedSignatureIssue)
		scheduleSignatureCheck(allowNetwork: false)
	}
	
	/// Performs a full signature & OCSP revocation check when an EventTap creation fails despite AXIsProcessTrusted().
	@objc func refreshOnEventTapFailure() {
		hasObservedEventTapFailure = true
		let sigIssue = Self.evaluateBundleSignature(launchCDHash: launchCDHash, allowNetwork: true)
		cachedSignatureIssue = sigIssue
		lastSignatureCheckTime = Date().timeIntervalSince1970
		applyEvaluation(axTrusted: false, signatureIssue: sigIssue)
	}
	
	// MARK: - User-Facing Descriptions
	
	var localBezelTitle: String {
		switch issueKind {
		case .signatureRevokedOrExpired:
			return "Code Signature Invalid"
		case .signatureChangedOnDisk:
			return "App Updated — Restart Required"
		case .permissionNotGranted, .none:
			return "Accessibility Permission Required"
		}
	}
	
	var localBezelSubtitle: String {
		switch issueKind {
		case .signatureRevokedOrExpired:
			return "Signing certificate expired or revoked. Please rebuild and redeploy Unimacs."
		case .signatureChangedOnDisk:
			return "On-disk application signature changed. Please restart Unimacs."
		case .permissionNotGranted, .none:
			return "Re-authorize Unimacs in System Settings > Privacy & Security > Accessibility."
		}
	}
	
	func remoteStopReason(for hostName: String) -> String {
		switch issueKind {
		case .signatureRevokedOrExpired:
			return "Code signing certificate on \(hostName) expired or was revoked. Please rebuild and redeploy."
		case .signatureChangedOnDisk:
			return "Unimacs was updated on disk on \(hostName). Please restart it and try again."
		case .permissionNotGranted, .none:
			return "Accessibility permission on \(hostName) was revoked. Please re-authorize on that Mac."
		}
	}
	
	var activityLogTitle: String {
		switch issueKind {
		case .signatureRevokedOrExpired:
			return "Code signing certificate expired or revoked"
		case .signatureChangedOnDisk:
			return "Application binary updated on disk — restart required"
		case .permissionNotGranted, .none:
			return "Accessibility permission revoked"
		}
	}
	
	var activityLogDetail: String {
		switch issueKind {
		case .signatureRevokedOrExpired:
			return "macOS TCC rejected event injection because this build's Apple Development certificate has been revoked or expired."
		case .signatureChangedOnDisk:
			return "The on-disk Unimacs bundle has a different code signature than the running process, invalidating TCC permissions."
		case .permissionNotGranted, .none:
			return "Keyboard and mouse sharing cannot function without Accessibility access."
		}
	}
	
	var activityLogHowToFix: String {
		switch issueKind {
		case .signatureRevokedOrExpired:
			return "Rebuild and redeploy Unimacs with a valid certificate (e.g. ./Scripts/rebuild-and-deploy.sh), or remove and re-add Unimacs in System Settings > Privacy & Security > Accessibility."
		case .signatureChangedOnDisk:
			return "Quit and relaunch Unimacs, then verify it is enabled in System Settings > Privacy & Security > Accessibility."
		case .permissionNotGranted, .none:
			return "Click 'Authorize Accessibility' and enable Unimacs in System Settings > Privacy & Security > Accessibility."
		}
	}
	
	var statusBannerTitle: String {
		switch issueKind {
		case .signatureRevokedOrExpired:
			return "Code Signature Invalid (Certificate Revoked/Expired)"
		case .signatureChangedOnDisk:
			return "App Updated on Disk (Restart Required)"
		case .permissionNotGranted, .none:
			return "Accessibility Permission Required"
		}
	}
	
	var statusBannerSubtitle: String {
		switch issueKind {
		case .signatureRevokedOrExpired:
			return "macOS blocks input control because the signing certificate is no longer valid. Rebuild/redeploy Unimacs or re-authorize in Accessibility settings."
		case .signatureChangedOnDisk:
			return "The app bundle on disk was replaced since launch. Please restart Unimacs to restore Accessibility control."
		case .permissionNotGranted, .none:
			return "Unimacs requires Accessibility permission to control mouse and keyboard. Please authorize it in System Settings."
		}
	}
	
	// MARK: - Observation & Polling
	
	private func startObserving() {
		observer = DistributedNotificationCenter.default().addObserver(
			forName: NSNotification.Name("com.apple.accessibility.api"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
				self?.refreshNow()
			}
		}
		
		pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
			self?.pollTrustStatus()
		}
	}
	
	private func stopObserving() {
		if let observer = observer {
			DistributedNotificationCenter.default().removeObserver(observer)
			self.observer = nil
		}
		pollTimer?.invalidate()
		pollTimer = nil
	}
	
	private func evaluateEffectiveAXTrust() -> Bool {
		let axTrusted = AXIsProcessTrusted()
		guard axTrusted else {
			return false
		}
		if hasObservedEventTapFailure {
			if Self.canCreateActiveEventTap() {
				hasObservedEventTapFailure = false
				return true
			}
			return false
		}
		return true
	}
	
	private static func canCreateActiveEventTap() -> Bool {
		let port = CGEvent.tapCreate(
			tap: .cgSessionEventTap,
			place: .headInsertEventTap,
			options: .defaultTap,
			eventsOfInterest: 1 << CGEventType.mouseMoved.rawValue,
			callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
			userInfo: nil
		)
		guard let port else {
			return false
		}
		CFMachPortInvalidate(port)
		return true
	}
	
	private func pollTrustStatus() {
		let effectiveAXTrusted = evaluateEffectiveAXTrust()
		let now = Date().timeIntervalSince1970
		
		if now - lastSignatureCheckTime >= signatureCheckInterval {
			scheduleSignatureCheck(allowNetwork: true)
		} else {
			applyEvaluation(axTrusted: effectiveAXTrusted, signatureIssue: cachedSignatureIssue)
		}
	}
	
	private func scheduleSignatureCheck(allowNetwork: Bool) {
		guard !isCheckingSignature else { return }
		isCheckingSignature = true
		lastSignatureCheckTime = Date().timeIntervalSince1970
		let launchHash = self.launchCDHash
		signatureCheckQueue.async { [weak self] in
			let sigIssue = Self.evaluateBundleSignature(launchCDHash: launchHash, allowNetwork: allowNetwork)
			DispatchQueue.main.async {
				guard let self = self else { return }
				self.isCheckingSignature = false
				self.cachedSignatureIssue = sigIssue
				let effectiveAXTrusted = self.evaluateEffectiveAXTrust()
				self.applyEvaluation(axTrusted: effectiveAXTrusted, signatureIssue: sigIssue)
			}
		}
	}
	
	private func applyEvaluation(axTrusted: Bool, signatureIssue: AccessibilityIssueKind) {
		let newIssue: AccessibilityIssueKind
		let newTrusted: Bool
		
		if signatureIssue != .none {
			newIssue = signatureIssue
			newTrusted = false
		} else if !axTrusted {
			newIssue = .permissionNotGranted
			newTrusted = false
		} else {
			newIssue = .none
			newTrusted = true
		}
		
		if newIssue != issueKind {
			issueKind = newIssue
		}
		if newTrusted != isTrustedState {
			isTrustedState = newTrusted
		}
	}
	
	// MARK: - Code Signature Verification
	
	static func isCertificateRevokedOrExpiredStatus(_ status: OSStatus) -> Bool {
		// -2147409652 = CSSMERR_TP_CERT_REVOKED
		// -2147409654 = CSSMERR_TP_CERT_EXPIRED
		// -67820 = errSecCertificateRevoked
		// -67818 = errSecCertificateExpired
		return status == -2147409652
			|| status == -2147409654
			|| status == errSecCertificateRevoked
			|| status == errSecCertificateExpired
	}
	
	static func classifySignatureInfo(
		copyStatus: OSStatus,
		signingInfo: [String: Any]?,
		launchCDHash: Data?,
		validityStatus: OSStatus,
		trustEvaluatedValid: Bool?
	) -> AccessibilityIssueKind {
		if copyStatus != errSecSuccess {
			if isCertificateRevokedOrExpiredStatus(copyStatus) {
				return .signatureRevokedOrExpired
			}
			return .none
		}
		guard let dict = signingInfo else {
			return .none
		}
		
		if let launchCDHash,
		   let diskCDHash = dict[kSecCodeInfoUnique as String] as? Data,
		   launchCDHash != diskCDHash {
			return .signatureChangedOnDisk
		}
		
		let flags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
		let isAdHoc = (flags & SecCodeSignatureFlags.adhoc.rawValue) != 0
		if isAdHoc {
			return .none
		}
		
		if isCertificateRevokedOrExpiredStatus(validityStatus) {
			return .signatureRevokedOrExpired
		}
		
		if let trustEvaluatedValid {
			return trustEvaluatedValid ? .none : .signatureRevokedOrExpired
		}
		
		// When a certificate-signed binary's certificate has been revoked, macOS
		// SecCodeCopySigningInformation returns errSecSuccess (0) but omits
		// kSecCodeInfoCertificates while keeping kSecCodeInfoTrust / kSecCodeInfoTeamIdentifier.
		if dict[kSecCodeInfoTrust as String] != nil || dict[kSecCodeInfoTeamIdentifier as String] != nil {
			return .signatureRevokedOrExpired
		}
		
		return .none
	}
	
	private static func readCurrentProcessCDHash() -> Data? {
		var selfCode: SecCode?
		guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
			return nil
		}
		var staticCode: SecStaticCode?
		guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else {
			return nil
		}
		var info: CFDictionary?
		guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
			  let dict = info as? [String: Any] else {
			return nil
		}
		return dict[kSecCodeInfoUnique as String] as? Data
	}
	
	static func evaluateBundleSignature(
		bundleURL: URL = Bundle.main.bundleURL,
		launchCDHash: Data?,
		allowNetwork: Bool
	) -> AccessibilityIssueKind {
		var diskCode: SecStaticCode?
		guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &diskCode) == errSecSuccess,
			  let diskCode else {
			return .none
		}
		
		var info: CFDictionary?
		let copyStatus = SecCodeCopySigningInformation(diskCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
		let dict = info as? [String: Any]
		
		var validityStatus: OSStatus = errSecSuccess
		var trustEvaluatedValid: Bool? = nil
		
		if copyStatus == errSecSuccess, let dict {
			let flags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
			let isAdHoc = (flags & SecCodeSignatureFlags.adhoc.rawValue) != 0
			if !isAdHoc {
				validityStatus = SecStaticCodeCheckValidity(diskCode, [], nil)
				if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
				   !certs.isEmpty {
					var policies: [SecPolicy] = [SecPolicyCreateBasicX509()]
					if let revPolicy = SecPolicyCreateRevocation(kSecRevocationUseAnyAvailableMethod) {
						policies.append(revPolicy)
					}
					var secTrust: SecTrust?
					if SecTrustCreateWithCertificates(certs as CFArray, policies as CFArray, &secTrust) == errSecSuccess,
					   let secTrust {
						SecTrustSetNetworkFetchAllowed(secTrust, allowNetwork)
						var trustError: CFError?
						trustEvaluatedValid = SecTrustEvaluateWithError(secTrust, &trustError)
					}
				}
			}
		}
		
		return classifySignatureInfo(
			copyStatus: copyStatus,
			signingInfo: dict,
			launchCDHash: launchCDHash,
			validityStatus: validityStatus,
			trustEvaluatedValid: trustEvaluatedValid
		)
	}
}
