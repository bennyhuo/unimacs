// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

struct TPHostState: OptionSet {
    let rawValue: UInt
    
    static let undef            = TPHostState([])
    static let shared           = TPHostState(rawValue: 1 << 0)
    static let peeredOffline    = TPHostState(rawValue: 1 << 1)
    static let peeredOnline     = TPHostState(rawValue: 1 << 2)
    static let controlled       = TPHostState(rawValue: 1 << 3)
    static let incompatible     = TPHostState(rawValue: 1 << 4)
    static let peering          = TPHostState(rawValue: 1 << 5)
    
    static let peered: TPHostState      = [.peeredOffline, .peeredOnline, .controlled, .peering]
    static let online: TPHostState      = [.shared, .peeredOnline, .controlled, .incompatible, .peering]
    static let draggable: TPHostState   = [.shared, .peeredOnline]
    static let all: TPHostState         = TPHostState(rawValue: 0xFFFF)
}
