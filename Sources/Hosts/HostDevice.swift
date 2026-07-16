// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

@objcMembers
class HostDevice: Notifiable, NSCoding {

    static let DidUpdateNotification = "HostDeviceDidUpdateNotification"
    static let IdentifierKey = "identifier"
    static let ComputerNameKey = "computerName"
    static let BackgroundImageDataKey = "backgroundImage"
    static let MacAddressesKey = "macAddresses"
    static let CapabilitiesKey = "capabilities"
    static let OSVersionKey = "osVersion"
	
	static let ScreensKey = "screens"

	var computerName: String
	var identifier: String { computerName }

	var osVersion: Int
	
	private var _macAddresses: [IOEthernetAddress]
	var macAddresses: [IOEthernetAddress] {
		get {
			_macAddresses
		}
		set {
			_macAddresses = newValue.filter { $0.isValid }
		}
	}
    var hasValidMacAddress: Bool {
		!self.macAddresses.isEmpty
    }

	var address: String? { nil }

	var backgroundImage: NSImage? { nil }

    var backgroundImageData: Data? {
        guard let backgroundImage = self.backgroundImage else {
            return nil
        }
        return backgroundImage.tiffRepresentation(using: NSBitmapImageRep.TIFFCompression.lzw, factor: 1.0)
    }

	var hasCustomBackgroundImage: Bool { false }
	var screens: [Screen] = []
	var capabilities: HostCapability { [] }

    override class var notificationName: Notification.Name {
        .hostDidUpdate
    }

	init(name: String, macAddresses: [IOEthernetAddress], osVersion: Int) {
		self.computerName = name
		self._macAddresses = macAddresses
		self.osVersion = osVersion
		super.init()
	}

    required init(coder: NSCoder) {
		computerName = coder.decodeObject(of: NSString.self, forKey: Self.ComputerNameKey)! as String
		
		if let decodedAddresses = coder.decodeObject(forKey: Self.MacAddressesKey) as? [IOEthernetAddress] {
			self._macAddresses = decodedAddresses.filter({ $0.isValid })
		} else {
			self._macAddresses = []
		}
		
		osVersion = coder.decodeInteger(forKey: Self.OSVersionKey)
		
		if coder.containsValue(forKey: Self.ScreensKey) {
			if let screensString = coder.decodeObject(forKey: Self.ScreensKey) as? String {
				screens = Screen.screens(from: screensString)
			}
		}
    }

    func encode(with coder: NSCoder) {
		coder.encode(self.identifier, forKey: Self.IdentifierKey)
        coder.encode(self.computerName, forKey: Self.ComputerNameKey)
		coder.encode(self.macAddresses, forKey: Self.MacAddressesKey)
		coder.encodeCInt(Int32(self.capabilities.rawValue), forKey: Self.CapabilitiesKey)
        coder.encode(self.osVersion, forKey: Self.OSVersionKey)
		
        if self.hasCustomBackgroundImage {
            if let backgroundImageData = self.backgroundImageData {
                coder.encode(backgroundImageData, forKey: Self.BackgroundImageDataKey)
            }
        }
				
		coder.encode(screens.stringRepresentation, forKey: Self.ScreensKey)
    }

    static var supportsSecureCoding: Bool { return true }

    func screenAt(index: UInt) -> Screen? {
		if index >= screens.count { return nil }
        return screens[Int(index)]
    }

	func hasCapability(_ capability: HostCapability) -> Bool {
        return capabilities.contains(capability)
    }

    func defaultBackgroundImage() -> NSImage {
        BackgroundImageResolver.defaultBackgroundImage(of: osVersion)
    }

	func pairWith(host: HostDevice,hasCapability capability: HostCapability) -> Bool {
		return host.hasCapability(capability) && self.hasCapability(capability)
	}
	
	override func isEqual(_ object: Any?) -> Bool {
		return if let other = object as? HostDevice {
			other.identifier == self.identifier
		} else {
			false
		}
	}
	
    override var description: String {
		"identifier=\(String(describing: identifier)) computerName=\(String(describing: computerName)) address=\(String(describing: address))|\(macAddresses.map({ $0.description }).joined(separator: ", "))"
    }

}

extension Notification.Name {
    static let hostDidUpdate = Notification.Name(HostDevice.DidUpdateNotification)
}
