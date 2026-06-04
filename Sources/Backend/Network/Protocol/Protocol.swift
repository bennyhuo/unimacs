// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import Carbon

let PROTOCOL_VERSION: Int = 20

enum TPMsgType: Int {
    case identification
    
    // Authentication
    case authenticationRequest
    case authenticationInProgress
    case authenticationAbort
    case authenticationSuccess
    case authenticationFailure
    
    // Control
    case controlRequest
    case controlSuccess
    case controlFailure
    case controlStop
    case controlWake
    case controlScreenSleep
    case controlDeviceSleep
    case controlLock
    
    // Events
    case event
    
    // Transfers
    case transferRequest
    case transferSuccess
    case transferFailure
}

public struct TPMouseDelta {
    public var x: Int64
    public var y: Int64
    
    public init(x: Int64 = 0, y: Int64 = 0) {
        self.x = x
        self.y = y
    }
}

typealias TPMouseButton = UInt8
typealias TPScrollWheelDistance = Int64
typealias TPPixelPos = Float
typealias TPDataLength = UInt64
typealias TPProtocolVersion = UInt16

struct TPKey {
    var keyCode: CGKeyCode
    var charCode: CGCharCode
}
