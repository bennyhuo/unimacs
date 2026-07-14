// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import Combine
@preconcurrency import ApplicationServices

extension Notification.Name {
	static let TPAccessibilityStatusDidChange = Notification.Name("TPAccessibilityStatusDidChangeNotification")
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
	
	private var observer: NSObjectProtocol?
	private var pollTimer: Timer?
	
	private override init() {
		super.init()
		self.isTrustedState = AXIsProcessTrusted()
		startObserving()
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
		shared.updateTrustStatus()
		return trusted
	}
	
	private func startObserving() {
		observer = DistributedNotificationCenter.default().addObserver(
			forName: NSNotification.Name("com.apple.accessibility.api"),
			object: nil,
			queue: .main
		) { [weak self] _ in
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
				self?.updateTrustStatus()
			}
		}
		
		pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
			self?.updateTrustStatus()
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
	
	private func updateTrustStatus() {
		let trusted = AXIsProcessTrusted()
		if trusted != isTrustedState {
			isTrustedState = trusted
		}
	}
}
