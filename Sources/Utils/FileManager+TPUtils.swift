// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

extension FileManager {
    
    @objc func isTotalSize(ofItemAtPath path: String, smallerThan maxSize: UInt64) -> Bool {
        debugLog("checking that size of \(path) is smaller than \(maxSize)")
        
        var isDirectory: ObjCBool = false
        guard fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        
        if isDirectory.boolValue {
            var folderSize: UInt64 = 0
            
            guard let enumerator = enumerator(atPath: path) else {
                return false
            }
            
            while let file = enumerator.nextObject() as? String {
                let attributes = enumerator.fileAttributes
                if let fileType = attributes?[.type] as? FileAttributeType,
                   fileType == .typeRegular,
                   let fileSize = attributes?[.size] as? UInt64 {
                    folderSize += fileSize
                    if folderSize > maxSize {
                        return false
                    }
                }
            }
            
            return true
        } else {
            do {
                let attributes = try attributesOfItem(atPath: path)
                if let fileSize = attributes[.size] as? UInt64 {
                    return fileSize <= maxSize
                }
            } catch {
                return false
            }
            return false
        }
    }
}
