// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

@objc protocol TPClientConnectionsDelegate: AnyObject {
    func connectionToServerSucceeded(_ networkConnection: NetworkConnection, infoDict: [String: Any]?)
    func connectionToServerFailed(_ host: TPRemoteHost, infoDict: [String: Any]?)
}

@objc protocol TPServerConnectionsDelegate: AnyObject {
    func connectionFromClientAccepted(_ networkConnection: NetworkConnection)
}
