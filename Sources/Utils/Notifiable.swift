// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

@objcMembers
class Notifiable : NSObject {
	
	private var lastTask: DispatchWorkItem? = nil
	
	class var notificationName: Notification.Name {
		fatalError("Not Implemented")
	}
	
	func notifyChange() {
		if !Thread.isMainThread {
			DispatchQueue.main.async {
				self.notifyChange()
			}
			return
		}
		
		let newTask = DispatchWorkItem { [weak self] in
			self?.sendNotification()
		}
		
		lastTask?.cancel()
		lastTask = newTask
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: newTask)
	}
	
	static func observe(observer: Any, selector: Selector, object: Notifiable? = nil) {
		NotificationCenter.default.addObserver(observer, selector: selector, name: notificationName, object: object)
	}
	
	func observe(observer: Any, selector: Selector) {
		Self.observe(observer: observer, selector: selector, object: self)
	}
	
	private func sendNotification() {
		NotificationCenter.default.post(name: Self.notificationName, object: self)
	}
}
