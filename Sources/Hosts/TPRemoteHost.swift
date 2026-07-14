// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Foundation
import Security

// MARK: - RemoteHost

final class TPRemoteHost: TPHost, NSCopying {

	static let AddressKey = "address"
	static let PortKey = "port"
	
	// New model: the remote host is positioned as a *full desktop* (union of remote screens).
	// Persist the origin of that desktop bounding rect in local global screen coordinates.
	static let DesktopOriginKey = "desktopOrigin"
	
	static let CertificateKey = "certificate"
	static let StateKey = "state"

    // MARK: - Properties (Stored)

    private var _identifier: String

    private var _address: String?

	var port: Int = 0 {
		didSet {
			if port != oldValue {
				self.notifyChange()
			}
		}
	}
	
    private var _backgroundImage: NSImage?
	
	// The origin of the remote *full desktop* bounding rect (union of remote screens)
	// placed into local global screen coordinates.
	private var _desktopOrigin: NSPoint = .zero

	private var _capabilities: TPHostCapability = []
    private var _state: TPHostState = []
    private var _previousHostState: TPHostState = []

    public private(set) var options: RemoteHostOptions

	var certificate: SecCertificate?
	
	public var lastError: String? = nil {
		didSet {
			if lastError != oldValue {
				self.notifyChange()
			}
		}
	}
	
	var wakeable: Bool {
	return hasValidMacAddress && hostState == .peeredOffline
	}
	
    // MARK: - Initializers

    init(identifier: String, address: String, port: Int) {
        _identifier = identifier
        _address = address
		self.port = port
        options = RemoteHostOptions()

		super.init(name: identifier, macAddresses: [], osVersion: 0)
    }
	
	convenience init(with record: TXTRecord, ipAddress: IpAddress) {
		self.init(identifier: record.id, address: ipAddress.address, port: ipAddress.port)
		self.update(with: record)
	}

    // MARK: - NSCoding (Archiving/Unarchiving)

    // The use of decode/encodeBytesForKey:returnedLength: for data is replaced with
    // modern Swift methods like decodeData(forKey:) and encode(data:forKey:).
    required init(coder: NSCoder) {
		_identifier = coder.decodeObject(of: NSString.self, forKey: Self.IdentifierKey)! as String
        _address = coder.decodeObject(forKey: Self.AddressKey) as? String
		if coder.containsValue(forKey: Self.PortKey) {
			port = coder.decodeInteger(forKey: Self.PortKey)
		} else {
			port = Int(TPPreferencesManager.shared().port(forPref: COMMAND_PORT))
		}

        // Desktop placement
        let decodedDesktopOrigin: NSPoint? = coder.containsValue(forKey: Self.DesktopOriginKey)
            ? coder.decodePoint(forKey: Self.DesktopOriginKey)
            : nil


        if coder.containsValue(forKey: Self.BackgroundImageDataKey),
            let backgroundImageData = coder.decodeData(forKey: Self.BackgroundImageDataKey)
        {
            _backgroundImage = NSImage(data: backgroundImageData)
        }

        // Certificate (SecCertificateRef/CSSM_DATA replacement)
        if coder.containsValue(forKey: Self.CertificateKey),
            let certData = coder.decodeData(forKey: Self.CertificateKey)
        {
            // SecCertificateCreateWithData is the modern replacement for SecCertificateCreateFromData
			certificate = SecCertificateCreateWithData(nil, certData as CFData)
            if certificate == nil {
                NSLog("Error reading certificate for host: Failed to create SecCertificate from data.")
            }
        }

        // Capabilities and OS Version
		let rawCapabilities = coder.decodeCInt(forKey: Self.CapabilitiesKey)
		_capabilities = TPHostCapability(rawValue: UInt(Int(rawCapabilities)))

        // State
        if coder.containsValue(forKey: Self.StateKey) {
            let rawState = coder.decodeInt64(forKey: Self.StateKey)
            _state = TPHostState(rawValue: UInt(rawState))
        } else {
            _state = []
        }

        // Custom Options
        if coder.containsValue(forKey: RemoteHostOptions.valuesKey) {
            options = RemoteHostOptions(coder: coder)
        } else {
            options = RemoteHostOptions()
        }
        super.init(coder: coder)

        // Finalize desktop origin after `screens` has been decoded by `TPHost`.
        if let origin = decodedDesktopOrigin {
            _desktopOrigin = origin
        }
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)

        coder.encode(_address, forKey: Self.AddressKey)
		coder.encode(port, forKey: Self.PortKey)
        coder.encode(_desktopOrigin, forKey: Self.DesktopOriginKey)

        if let certData = certificateData as CFData? {
            coder.encode(certData as Data, forKey: Self.CertificateKey)
        }

        // State (using encodeInt64 for OptionSet rawValue)
        coder.encode(Int64(_state.rawValue), forKey: Self.StateKey)

        // Custom Options
        options.encode(with: coder)
    }

    // MARK: - NSCopying

    func copy(with zone: NSZone? = nil) -> Any {
        // Explicitly unwrap `identifier` for the initializer call as it's optional,
        // and we assume the initializer requires a non-optional string based on the Obj-C.
        let copy = TPRemoteHost(identifier: identifier, address: _address ?? "", port: port)
        copy._desktopOrigin = _desktopOrigin
        copy.options = options.mutableCopy() as! RemoteHostOptions
        return copy
    }

    override var address: String? {
        get { return _address }
        set { _address = newValue }
    }

    // MARK: - Certificate

    var certificateData: Data? {
        guard let cert = certificate else { return nil }

        // SecCertificateCopyData is the modern, safer way to get the data (returns CFData)
		if let data = SecCertificateCopyData(cert) as Data? {
            return data
        } else {
            NSLog("Error getting certificate data for host: \(self)")
            return nil
        }
    }

    var isCertified: Bool {
        return certificate != nil
    }

    // MARK: - Screen / Placement

	private var _fullHostRectInRemoteCoords: NSRect {
		screens.reduce(NSRect.null) { $0.union($1.frame) }
	}
	
	/// Remote desktop bounding rect in remote coordinate space (union of remote screens).
    var fullHostRect: NSRect {
		let rect = _fullHostRectInRemoteCoords
		return rect.isNull ? .zero : rect
    }
	
	private var _remoteToLocalOffset: NSPoint? {
		let rect = _fullHostRectInRemoteCoords
		guard !rect.isNull else { return nil }
		return NSPoint(
			x: _desktopOrigin.x - rect.origin.x,
			y: _desktopOrigin.y - rect.origin.y
		)
	}
	
	/// The bounding rect of the full remote desktop (union of all remote screens)
	/// placed into local global screen coordinates.
	var hostDesktopRect: NSRect {
		guard let offset = _remoteToLocalOffset else { return .zero }
		let rect = _fullHostRectInRemoteCoords
		guard !rect.isNull else { return .zero }
		return rect.offsetBy(dx: offset.x, dy: offset.y)
	}

	/// Legacy alias: historically this represented only the "shared screen".
	/// With full-desktop placement, this is equivalent to `hostDesktopRect`.
	var hostRect: NSRect {
		hostDesktopRect
	}

    func setHostPosition(_ position: NSPoint) {
        _desktopOrigin = position
        self.notifyChange()
    }
    
    /// The origin of the remote desktop in local coordinates
    var desktopOrigin: NSPoint {
        get { _desktopOrigin }
        set {
            _desktopOrigin = newValue
            self.notifyChange()
        }
    }
	
	private var _localDesktopFrame: NSRect {
		TPLocalHost.shared.screens.reduce(NSRect.null) { $0.union($1.frame) }
	}
	
	/// Glue the full remote desktop rect against the whole local desktop bounding rect.
	var adjustedHostDesktopRect: NSRect {
		let movingRect = self.hostDesktopRect
		let localRect = _localDesktopFrame
		guard movingRect != .zero, !localRect.isNull else { return .zero }
		
		return TPGluedRect(localRect, movingRect, excluding: []).rect
	}
	
	/// Glue the full remote desktop rect against one local screen.
	/// This matters when we want entry-screen-specific placement (e.g. cursor return mapping).
	func adjustedHostDesktopRect(gluedToLocalScreenIndex localScreenIndex: UInt) -> NSRect {
		let movingRect = self.hostDesktopRect
		guard movingRect != .zero,
			  let localRect = TPLocalHost.shared.screenAt(index: localScreenIndex)?.frame
		else { return .zero }
		
		return TPGluedRect(localRect, movingRect, excluding: []).rect
	}
	
	/// Legacy alias: historically this glued only the "shared screen" rect.
	var adjustedHostRect: NSRect {
		adjustedHostDesktopRect
	}
	
	func adjustedHostRect(gluedToLocalScreenIndex localScreenIndex: UInt) -> NSRect {
		adjustedHostDesktopRect(gluedToLocalScreenIndex: localScreenIndex)
	}

    // MARK: - Background Image

    func setBackgroundImage(_ backgroundImage: NSImage?) {
        if _backgroundImage !== backgroundImage {
            _backgroundImage = backgroundImage
            self.notifyChange()
        }
    }

    override var backgroundImage: NSImage? {
        if let image = _backgroundImage {
            return image
        } else {
            // Calling super method if custom image is nil
            return super.defaultBackgroundImage()
        }
    }

    override var hasCustomBackgroundImage: Bool {
        return _backgroundImage != nil
    }

    // MARK: - Capabilities

    override var capabilities: TPHostCapability {
        get { return _capabilities }
        set {
            if _capabilities != newValue {
                _capabilities = newValue
                self.notifyChange()
            }
        }
    }

    func setCapability(_ capability: TPHostCapability, isEnabled enabled: Bool) {
        if enabled {
            _capabilities.formUnion(capability)
        } else {
            _capabilities.subtract(capability)
        }
        self.notifyChange()
    }

    // MARK: - State

    var hostState: TPHostState {
        get { return _state }
        set {
            // DebugLog("changing state of host \(Unmanaged.passUnretained(self).toOpaque()) (\(_identifier ?? "")) from \(_state.rawValue) to \(newValue.rawValue)")
            if _state != newValue {
                _previousHostState = _state
                _state = newValue
                self.notifyChange()
            }
        }
    }

    var previousHostState: TPHostState {
        return _previousHostState
    }
	
	var isSaveable: Bool {
		isInState(.peered)
	}

    func isInState(_ state: TPHostState) -> Bool {
		return !_state.intersection(state).isEmpty
    }
	
	func update(with record: TXTRecord) {
		self.capabilities = TPHostCapability(rawValue: record.capabilities)
		self.osVersion = record.osVersion
		self.screens = TPScreen.screens(from: record.screens)
		self.computerName = record.name
		if !record.macAddresses.isEmpty {
			self.macAddresses = record.macAddresses
		}
		notifyChange()
	}

    static func from(data: Data) -> TPRemoteHost {
		let unarchiver = try! NSKeyedUnarchiver(forReadingFrom: data)
		// make it possible to decode [IOEthernetAddress]. 
		unarchiver.requiresSecureCoding = false
		let host = TPRemoteHost(coder: unarchiver)
		unarchiver.finishDecoding()
		return host
    }

    // MARK: - Misc

    override var description: String {
        let addressStr = _address ?? "N/A"
        let rectStr = NSStringFromRect(hostRect)
        return "\(super.description) state=\(_state.rawValue) rect=\(rectStr)"
    }
}

extension NSArray {

    /**
	 Filters the array to include only hosts whose `hostState` contains the specified state.

	 - Parameter state: The `TPHostState` to check for.
	 - Returns: An array of `TPRemoteHost` objects.
	 */
    func hosts(withState state: TPHostState) -> [TPRemoteHost] {
        return self.compactMap { $0 as? TPRemoteHost }
                  .filter { !$0.hostState.intersection(state).isEmpty }
    }
}

extension Array where Element: TPRemoteHost {

	/**
	 Filters the array to include only hosts whose `hostState` contains the specified state.

	 - Parameter state: The `TPHostState` to check for.
	 - Returns: An array of `TPRemoteHost` objects.
	 */
	func hosts(withState state: TPHostState) -> [TPRemoteHost] {
		return self.filter { !$0.hostState.intersection(state).isEmpty }
	}
}
