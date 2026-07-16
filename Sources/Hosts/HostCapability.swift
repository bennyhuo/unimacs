// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

let MAX_CAPABILITIES = 4

struct HostCapability: OptionSet {
    let rawValue: UInt
    
    static let none             = HostCapability([])
    static let encryption       = HostCapability(rawValue: 1 << 0)
    static let eventTaps        = HostCapability(rawValue: 1 << 1)
    static let directEventTaps  = HostCapability(rawValue: 1 << 2)
    static let portable         = HostCapability(rawValue: 1 << 3)
}
