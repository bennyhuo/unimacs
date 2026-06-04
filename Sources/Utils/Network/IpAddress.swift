// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

class IpAddress {
    let address: String
    let port: Int

    init(address: String, port: Int) {
        self.address = address
        self.port = port
    }

    convenience init?(with data: Data) {
        if let (address, port) = data.withUnsafeBytes({ (ptr: UnsafeRawBufferPointer) in
            let sockaddrPtr = ptr.bindMemory(to: sockaddr.self).baseAddress!
            if sockaddrPtr.pointee.sa_family == AF_INET {
                let sockaddrInPtr = ptr.bindMemory(to: sockaddr_in.self).baseAddress!
                return withUnsafePointer(to: sockaddrInPtr.pointee.sin_addr) { ptr in
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, ptr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let port = Int(UInt16(bigEndian: sockaddrInPtr.pointee.sin_port))
                        if let address = String(cString: buffer, encoding: .utf8) {
                            return Optional((address, port))
                        }
                    }
                    return nil
                }
            }
            return nil
        }) {
            self.init(address: address, port: port)
        } else {
            return nil
        }
    }

    var priority: Int {
        let prefixes = ["169.254", "192.168", "172.", "10."]
        return prefixes.firstIndex(where: address.hasPrefix) ?? 4
    }

    var description: String {
        return "\(address):\(port)"
    }
}
