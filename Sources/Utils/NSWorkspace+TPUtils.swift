// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import IOKit
import IOKit.network

extension NSWorkspace {
    private static let maxInterfaceNumber = 5
    
    var computerIdentifier: String {
        var identifier: String? = nil
        var interfaceNumber = 0
        
        while identifier == nil && interfaceNumber < Self.maxInterfaceNumber {
            let interfaceName = "en\(interfaceNumber)"
            
            guard let matchingDict = IOBSDNameMatching(kIOMainPortDefault, 0, interfaceName) else {
                interfaceNumber += 1
                continue
            }
            
            var iterator: io_iterator_t = 0
            let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
            
            guard result == KERN_SUCCESS else {
                interfaceNumber += 1
                continue
            }
            
            defer { IOObjectRelease(iterator) }
            
            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }
                
                var controllerService: io_object_t = 0
                let parentResult = IORegistryEntryGetParentEntry(service, kIOServicePlane, &controllerService)
                
                guard parentResult == KERN_SUCCESS else { continue }
                defer { IOObjectRelease(controllerService) }
                
                if let macData = IORegistryEntryCreateCFProperty(controllerService, kIOMACAddress as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                    let macAddress = [UInt8](macData)
                    if macAddress.count >= 6 {
                        identifier = String(format: "%02x-%02x-%02x-%02x-%02x-%02x",
                                          macAddress[0], macAddress[1], macAddress[2],
                                          macAddress[3], macAddress[4], macAddress[5])
                    }
                }
            }
            
            interfaceNumber += 1
        }
        
		let ipAddress = NetworkConfigurationWatcher.shared.selectedLocalIpAddress
        if let id = identifier {
            return "\(id)_\(ipAddress)"
        }
        
        return ipAddress
    }
}
