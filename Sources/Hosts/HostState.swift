// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

struct HostState: OptionSet {
    let rawValue: UInt
    
    static let undef            = HostState([])
    static let shared           = HostState(rawValue: 1 << 0)
    static let peeredOffline    = HostState(rawValue: 1 << 1)
    static let peeredOnline     = HostState(rawValue: 1 << 2)
    static let controlled       = HostState(rawValue: 1 << 3)
    static let incompatible     = HostState(rawValue: 1 << 4)
    static let peering          = HostState(rawValue: 1 << 5)
    
    static let peered: HostState      = [.peeredOffline, .peeredOnline, .controlled, .peering]
    static let online: HostState      = [.shared, .peeredOnline, .controlled, .incompatible, .peering]
    static let draggable: HostState   = [.shared, .peeredOnline]
    static let all: HostState         = HostState(rawValue: 0xFFFF)
}
