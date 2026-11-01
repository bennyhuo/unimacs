// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import IOKit.network

@objcMembers
class IOEthernetAddress: NSObject, NSCoding {
    static let size: Int = Int(kIOEthernetAddressSize)
	private static let BytesKey = "BytesKey"

    let bytes: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer.allocate(capacity: IOEthernetAddress.size)

    var isValid: Bool {
        for i in 0..<Self.size {
            if bytes[i] != 0 {
                return true
            }
        }
        return false
    }
	
	var byteArray: [UInt8] {
		Array(UnsafeBufferPointer(start: bytes, count: Self.size))
	}

    override init() {
        self.bytes.initialize(repeating: 0, count: Self.size)
    }

    convenience init(_ bytes: UnsafePointer<UInt8>?) {
        if let bytes = bytes {
            self.init(bytes)
        } else {
            self.init()
        }
    }

    @objc(initWithBytes:)
    init(_ bytes: UnsafePointer<UInt8>) {
        self.bytes.initialize(from: bytes, count: Self.size)
    }

    /// Parses a colon-separated hexadecimal MAC address string (e.g. `"aa:bb:cc:dd:ee:ff"`).
    convenience init?(string: String) {
        let parts = string.components(separatedBy: ":")
        guard parts.count == Self.size else { return nil }
        let parsedBytes = parts.compactMap { UInt8($0, radix: 16) }
        guard parsedBytes.count == Self.size else { return nil }
        self.init()
        parsedBytes.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                self.bytes.assign(from: base, count: Self.size)
            }
        }
    }

    deinit {
        bytes.deallocate()
    }

    func encode(with coder: NSCoder) {
		coder.encodeBytes(bytes, length: Self.size, forKey: Self.BytesKey)
    }

	required convenience init?(coder: NSCoder) {
		if let bytes = coder.decodeBytes(forKey: Self.BytesKey, returnedLength: nil) {
			self.init(bytes)
		} else {
			return nil
		}
    }

    func invalidate() {
        self.bytes.initialize(repeating: 0, count: Self.size)
    }

    override var description: String {
        (0..<Self.size).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":")
    }
}
