// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

struct BorderSide: OptionSet {
    let rawValue: UInt
    
    static let right  = BorderSide(rawValue: 1 << 0)
    static let bottom = BorderSide(rawValue: 1 << 1)
    static let left   = BorderSide(rawValue: 1 << 2)
    static let top    = BorderSide(rawValue: 1 << 3)
}

func squaredDistance(_ rect1: NSRect, _ rect2: NSRect) -> Float {
    let point1 = rect1.origin
    let point2 = rect2.origin
    let dx = Float(point1.x - point2.x)
    let dy = Float(point1.y - point2.y)
    return dx * dx + dy * dy
}

/// Glue a mobile rect to a fixed rect on the nearest side.
/// - Parameters:
///   - fixedRect: The fixed reference rect
///   - mobileRect: The rect to be glued
///   - excludedSides: Sides to exclude from consideration
/// - Returns: Tuple containing (glued rect, side, squared distance - negative if intersects)
@discardableResult
func gluedRect(_ fixedRect: NSRect, _ mobileRect: NSRect, excluding excludedSides: BorderSide = []) -> (rect: NSRect, side: BorderSide, distance: Float) {
    let gluedRect = [
        NSRect(x: fixedRect.maxX, y: min(fixedRect.maxY, max(fixedRect.minY - mobileRect.height, mobileRect.origin.y)), width: mobileRect.width, height: mobileRect.height),    // Right
        NSRect(x: fixedRect.minX - mobileRect.width, y: min(fixedRect.maxY, max(fixedRect.minY - mobileRect.height, mobileRect.origin.y)), width: mobileRect.width, height: mobileRect.height), // Left
        NSRect(x: min(fixedRect.maxX, max(fixedRect.minX - mobileRect.width, mobileRect.origin.x)), y: fixedRect.maxY, width: mobileRect.width, height: mobileRect.height),     // Top
        NSRect(x: min(fixedRect.maxX, max(fixedRect.minX - mobileRect.width, mobileRect.origin.x)), y: fixedRect.minY - mobileRect.height, width: mobileRect.width, height: mobileRect.height)  // Bottom
    ]
    let sides: [BorderSide] = [.right, .left, .top, .bottom]
    
    var minGluedRect = NSRect.zero
    var minDist: Float = .infinity
    var minSide: BorderSide = .left
    
    for (index, side) in sides.enumerated() where side.intersection(excludedSides).isEmpty {
        let dist = squaredDistance(mobileRect, gluedRect[index])
        if dist < minDist {
            minDist = dist
            minSide = side
            minGluedRect = gluedRect[index]
        }
    }
    
    // Add secondary side if aligned edge-to-edge
    if minSide == .right || minSide == .left {
        if mobileRect.minY >= fixedRect.maxY {
            minSide.insert(.top)
        } else if mobileRect.maxY <= fixedRect.minY {
            minSide.insert(.bottom)
        }
    } else if minSide == .top || minSide == .bottom {
        if mobileRect.minX >= fixedRect.maxX {
            minSide.insert(.right)
        } else if mobileRect.maxX <= fixedRect.minX {
            minSide.insert(.left)
        }
    }
    
    let distance = fixedRect.intersects(mobileRect) ? -minDist : minDist
    return (minGluedRect, minSide, distance)
}

func rectShiftedOnSide(_ rect: NSRect, _ side: BorderSide, _ amount: Float) -> NSRect {
    var shiftedRect = rect
    if side == .right {
        shiftedRect.origin.x += CGFloat(amount)
    } else if side == .left {
        shiftedRect.origin.x -= CGFloat(amount)
    } else if side == .top {
        shiftedRect.origin.y += CGFloat(amount)
    } else if side == .bottom {
        shiftedRect.origin.y -= CGFloat(amount)
    }
    return shiftedRect
}
