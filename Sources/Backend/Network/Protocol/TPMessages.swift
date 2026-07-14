// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

let TPScreenPlacementKey = "TPScreenPlacement"
let TPMousePositionKey = "TPMousePosition"
let TPHotBorderRelativePointKey = "TPHotBorderRelativePoint"
let TPSwitchOptionsKey = "TPSwitchOptions"
let TPSwitchControlKey = "TPSwitchControl"

class ControlRequestBody {

    let screenPlacement: CGRect
    /// Fallback cursor position (legacy): relative to the client desktop bounding rect.
    let mousePosition: CGPoint
    /// Preferred cursor position: normalized within the hot border window (0..1, 0..1).
    let hotBorderRelativePoint: CGPoint?
    let options: [String: Any]?

    init(from message: TPMessage) {
        assert(message.msgType == .controlRequest)

        screenPlacement = (message.infoDict[TPScreenPlacementKey] as? NSData)!.rectValue

        mousePosition = (message.infoDict[TPMousePositionKey] as? NSData)?.pointValue ?? NSPoint(x: -1, y: -1)
        hotBorderRelativePoint = (message.infoDict[TPHotBorderRelativePointKey] as? NSData)?.pointValue
        options = message.infoDict[TPSwitchOptionsKey] as? [String: Any]
    }

}

extension TPMessage {
    var controlRequestBody: ControlRequestBody {
        ControlRequestBody(from: self)
    }

    static func controlRequestMessage(
        screenPlacement: CGRect,
        mousePosition: CGPoint,
        hotBorderRelativePoint: CGPoint?,
        options: [String: Any]
    ) -> TPMessage {
        var infoDict: [String: Any] = [
			TPScreenPlacementKey: NSData.data(with: screenPlacement),
			TPMousePositionKey: NSData.data(with: mousePosition),
            TPSwitchOptionsKey: options,
        ]
        if let point = hotBorderRelativePoint {
			infoDict[TPHotBorderRelativePointKey] = NSData.data(with: point)
        }

		return TPMessage.create(with: .controlRequest, andInfoDict: infoDict)
    }
}
