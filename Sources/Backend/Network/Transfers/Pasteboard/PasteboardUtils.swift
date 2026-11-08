// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

let PasteboardTransferNameKey = "PasteboardTransferName"
let PasteboardTransferChangeCountKey = "PasteboardTransferChangeCount"

/// Serializes all `NSPasteboard` I/O onto one queue.
///
/// `NSPasteboard` is not thread-safe; the process-wide `general` pasteboard must not
/// be touched concurrently. This queue is the single owner. The main thread must never
/// `sync` onto it — promised-data reads can block for ~60s per type.
enum PasteboardAccess {
	private static let specificKey = DispatchSpecificKey<UInt8>()
	private static let specificValue: UInt8 = 1

	static let queue: DispatchQueue = {
		let queue = DispatchQueue(label: "com.unimacs.pasteboard", qos: .userInitiated)
		queue.setSpecific(key: specificKey, value: specificValue)
		return queue
	}()

	static var isOnQueue: Bool {
		DispatchQueue.getSpecific(key: specificKey) == specificValue
	}

	/// Run `work` on the pasteboard queue. Never call from the main thread.
	static func sync<T>(_ work: () -> T) -> T {
		precondition(!Thread.isMainThread, "PasteboardAccess.sync must not run on the main thread")
		if isOnQueue {
			return work()
		}
		return queue.sync(execute: work)
	}

	static func async(_ work: @escaping () -> Void) {
		if isOnQueue {
			work()
			return
		}
		queue.async(execute: work)
	}
}

func pasteboardTypeNeedsSwapping(_ type: String) -> Bool {
    if CFByteOrderGetCurrent() == Int(CFByteOrderBigEndian.rawValue) {
        return false
    } else {
        return type == "public.utf16-plain-text" || type == "CorePasteboardFlavorType 0x75747874"
    }
}

func pasteboardTypeNeedsIgnoring(_ type: String) -> Bool {
    return type == "com.apple.txn.text-multimedia-data" || type == "CorePasteboardFlavorType 0x7478746E"
}
