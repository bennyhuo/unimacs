// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

let ScreenPlacementKey = "ScreenPlacement"
let MousePositionKey = "MousePosition"
let HotBorderRelativePointKey = "HotBorderRelativePoint"
let SwitchOptionsKey = "SwitchOptions"
let SwitchControlKey = "SwitchControl"
let StopControlReasonKey = "StopControlReason"
let ControlFailureReasonKey = "reason"
let ControlFailureIsPermissionIssueKey = "ControlFailureIsPermissionIssue"

class ControlRequestBody {

    let screenPlacement: CGRect
    /// Fallback cursor position (legacy): relative to the client desktop bounding rect.
    let mousePosition: CGPoint
    /// Preferred cursor position: normalized within the hot border window (0..1, 0..1).
    let hotBorderRelativePoint: CGPoint?
    let options: [String: Any]?

    init(from message: Message) {
        assert(message.msgType == .controlRequest)

        screenPlacement = (message.infoDict[ScreenPlacementKey] as? NSData)!.rectValue

        mousePosition = (message.infoDict[MousePositionKey] as? NSData)?.pointValue ?? NSPoint(x: -1, y: -1)
        hotBorderRelativePoint = (message.infoDict[HotBorderRelativePointKey] as? NSData)?.pointValue
        options = message.infoDict[SwitchOptionsKey] as? [String: Any]
    }

}

extension Message {
    var controlRequestBody: ControlRequestBody {
        ControlRequestBody(from: self)
    }

    static func controlRequestMessage(
        screenPlacement: CGRect,
        mousePosition: CGPoint,
        hotBorderRelativePoint: CGPoint?,
        options: [String: Any]
    ) -> Message {
        var infoDict: [String: Any] = [
			ScreenPlacementKey: NSData.data(with: screenPlacement),
			MousePositionKey: NSData.data(with: mousePosition),
            SwitchOptionsKey: options,
        ]
        if let point = hotBorderRelativePoint {
			infoDict[HotBorderRelativePointKey] = NSData.data(with: point)
        }

		return Message.create(with: .controlRequest, andInfoDict: infoDict)
    }
}
