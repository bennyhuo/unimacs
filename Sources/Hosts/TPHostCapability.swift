// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

let MAX_CAPABILITIES = 3

struct TPHostCapability: OptionSet {
    let rawValue: UInt
    
    static let none             = TPHostCapability([])
    static let encryption       = TPHostCapability(rawValue: 1 << 0)
    static let eventTaps        = TPHostCapability(rawValue: 1 << 1)
    static let directEventTaps  = TPHostCapability(rawValue: 1 << 2)
}
