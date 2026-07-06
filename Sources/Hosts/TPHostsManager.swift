// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

let TPHostsVersionKey = "TPHostsVersion"
let TPHostsKey = "TPHosts"


private let HOSTS_VERSION = 6

@objcMembers
class TPHostsManager: NSObject {

	static let TPHostsConfigurationDidChangeNotification = "TPHostsConfigurationDidChangeNotification"
	
    private var _hosts: [String: TPRemoteHost] = [:]
    private var _clientHosts: [String: TPRemoteHost] = [:]
    private var _pendingAuthenticationHost: TPRemoteHost?

    nonisolated(unsafe) static let shared = TPHostsManager()

    override init() {
        super.init()

        TPHost.observe(observer: self, selector: #selector(notifyChanges))
        TPHost.observe(observer: self, selector: #selector(saveHosts))
    }

    // MARK: - Persistence

    func loadHosts() {
        let hostsVersion = TPPreferencesManager.shared().int(forPref: TPHostsVersionKey)
        if hostsVersion != HOSTS_VERSION {
			infoLog("Hosts version mismatch, expected=\(HOSTS_VERSION) got=\(hostsVersion)", module: .control)
            return
        }

        if let archivedData = TPPreferencesManager.shared().value(forPref: TPHostsKey) as? Data {
            _hosts.removeAll()

			let newHosts = NSKeyedUnarchiver.unarchiveObject(with: archivedData) as? [String: TPRemoteHost]
			if let newHostValues = newHosts?.values {
                for newHost in newHostValues {
                    switch newHost.hostState {
                    case [], .shared, .incompatible:
                        break
                    case .peeredOffline, .peeredOnline, .controlled:
                        newHost.hostState = .peeredOffline
						if newHost.port == 0 {
							newHost.port = Int(TPPreferencesManager.shared().port(forPref: COMMAND_PORT))
						}
                        _hosts[newHost.identifier] = newHost
                    default:
                        break
                    }
                }
            }
        }
    }

    @objc func saveHosts() {
		let hostsToSave = _hosts.filter { (_, host) in host.isSaveable }

        do {
            let archivedData = try NSKeyedArchiver.archivedData(
                withRootObject: hostsToSave, requiringSecureCoding: false)
            TPPreferencesManager.shared().setValue(archivedData, forKey: TPHostsKey)
            TPPreferencesManager.shared().setValue(HOSTS_VERSION, forKey: TPHostsVersionKey)
        } catch {
            // Handle error
        }
    }

    @MainActor
    func removeBonjourHost(_ host: TPRemoteHost) {
        let knownHost = self.host(withIdentifier: host.identifier)
        var shouldNotify = true

        if let knownHost = knownHost {
            if DeviceConnectionManager.shared.isConnected(to: knownHost) {
                debugLog("Bonjour service removed for \(knownHost.computerName) but persistent TCP is still up; keeping online state", module: .network)
                return
            }

            let state = knownHost.hostState

            switch state {
            case []:
                shouldNotify = false
            case .shared, .incompatible:
                knownHost.hostState = []
            case .peeredOffline:
                shouldNotify = false
            case .peeredOnline:
                knownHost.hostState = .peeredOffline
            case .controlled:
                knownHost.hostState = .peeredOffline
                TPClientController.shared.stopControl()
            default:
                break
            }
        } else {
            shouldNotify = false
        }

        if shouldNotify {
            self.notifyChanges()
        }
    }

    /// Reconcile a Bonjour-resolved host into the canonical host table.
    ///
    /// IMPORTANT: a remote is keyed by `identifier` (== `computerName`), so the saved/known host
    /// object — the one that carries the user's desktop placement (`desktopOrigin`) — is the only
    /// authoritative representation. We therefore parse the Bonjour record *into the known host in
    /// place* and never fabricate a throwaway `TPRemoteHost` to stand in for it. (Constructing one
    /// would also fire a spurious `.hostDidUpdate` with `desktopOrigin == .zero` via its property
    /// setters, which used to fling the hot border to the wrong screen edge.) Only when the host is
    /// genuinely unknown do we create a new object, which then becomes the authoritative one.
    ///
    /// - Returns: the authoritative `TPRemoteHost` for this record (existing or newly created).
    @discardableResult
    func addBonjourHost(record: TXTRecord, ipAddress: IpAddress?, compatible: Bool) -> TPRemoteHost {
        // Hosts are keyed by `identifier` (== `computerName`), which corresponds to the TXT `name`
        // field, not the `id` field.
        let identifier = record.name

        if let knownHost = self.host(withIdentifier: identifier) {
            var shouldNotify = true
            var shouldAutoConnect = false

            if let ipAddress = ipAddress {
                let state = knownHost.hostState

                // Refresh cached reachability from Bonjour; live TCP is not torn down on address change.
                knownHost.address = ipAddress.address
                knownHost.port = ipAddress.port
                // A Bonjour TXT record may omit/truncate the screens field (TXT size limits,
                // multi-monitor hosts). Never overwrite authoritative screen geometry obtained
                // in-band (via identification) with an empty Bonjour value, or the host's
                // desktop rect collapses to .zero and its hot border can never be created.
                let parsedScreens = TPScreen.screens(from: record.screens)
                if !parsedScreens.isEmpty {
                    knownHost.screens = parsedScreens
                }

                switch state {
                case []:
                    knownHost.hostState = .shared
                case .shared:
                    shouldNotify = false
                case .peeredOffline:
                    knownHost.hostState = .peeredOnline
                    shouldAutoConnect = true  // Auto-connect when paired device comes online
                case .peeredOnline:
                    break
                case .controlled:
                    break
                default:
                    break
                }
            } else {
                knownHost.hostState = .incompatible
            }

            if shouldNotify {
                self.notifyChanges()
            }

            // Auto-connect to paired device that just came online
            if shouldAutoConnect {
                Task { @MainActor in
                    DeviceConnectionManager.shared.connect(to: knownHost)
                }
            }

            return knownHost
        } else {
            let newHost: TPRemoteHost
            if let ipAddress = ipAddress {
                newHost = TPRemoteHost(with: record, ipAddress: ipAddress)
            } else {
                newHost = TPRemoteHost(identifier: identifier, address: "", port: 0)
                newHost.update(with: record)
            }
            newHost.hostState = compatible ? .shared : .incompatible
            _hosts[newHost.identifier] = newHost
            self.notifyChanges()
            return newHost
        }
    }

    func updatedHost(from hostData: Data) -> TPRemoteHost {
        let host = TPRemoteHost.from(data: hostData)
        let knownHost = self.host(withIdentifier: host.identifier)

        if let knownHost = knownHost {
            knownHost.computerName = host.computerName
            knownHost.capabilities = host.capabilities
			knownHost.macAddresses = host.macAddresses
            knownHost.osVersion = host.osVersion
			if let address = host.address, !address.isEmpty {
				knownHost.address = address
			}
			if host.port > 0 {
				knownHost.port = host.port
			}
			if !host.screens.isEmpty {
				knownHost.screens = host.screens
			}
			knownHost.notifyChange()

            return knownHost
        } else {
			debugLog("New host discovered: \(host.computerName)", module: .control)
            return host
        }
    }

    func addClientHost(_ clientHost: TPRemoteHost) {
        _clientHosts[clientHost.identifier] = clientHost
    }

    // MARK: - Getters

    func hosts(with state: TPHostState) -> [Any] {
        return Array(_hosts.values).hosts(withState: state)
    }

    func host(withIdentifier identifier: String) -> TPRemoteHost? {
        return _hosts[identifier]
    }

    func host(withAddress address: String) -> TPRemoteHost? {
        for host in _hosts.values {
            if host.address == address {
                return host
            }
        }

        for host in _clientHosts.values {
            if host.address == address {
                return host
            }
        }

        return nil
    }

    // MARK: - Misc

    @objc func notifyChangesNow() {
		NotificationCenter.default.post(name: Notification.Name(Self.TPHostsConfigurationDidChangeNotification), object: nil, userInfo: nil)
    }

    @objc func notifyChanges() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notifyChangesNow), object: nil)
        self.perform(#selector(notifyChangesNow), with: nil, afterDelay: 0.1)
    }
    
    // MARK: - Unified Desktop Layout Sync

    private let TPLayoutVersionKey = "layoutVersion"

    func layoutVersion() -> UInt64 {
        let val = TPPreferencesManager.shared().value(forPref: TPLayoutVersionKey)
        if let num = val as? NSNumber {
            return num.uint64Value
        }
        return 0
    }

    func incrementLayoutVersion() -> UInt64 {
        let nextVer = layoutVersion() + 1
        TPPreferencesManager.shared().setValue(NSNumber(value: nextVer), forKey: TPLayoutVersionKey)
        return nextVer
    }

    @MainActor
    func currentUnifiedDesktop(version: UInt64) -> TPUnifiedDesktop? {
        var unifiedScreens: [TPUnifiedScreen] = []
        
        // 1. Add local host screens
        let localHost = TPLocalHost.shared
        for (index, screen) in localHost.screens.enumerated() {
            unifiedScreens.append(TPUnifiedScreen(
                ownerHostId: localHost.identifier,
                screenIndex: index,
                frame: screen.frame,
                isMain: index == 0
            ))
        }
        
        // 2. Add remote host screens
        let peeredHosts = self.hosts(with: .peered) as? [TPRemoteHost] ?? []
        for host in peeredHosts {
            for (index, screen) in host.screens.enumerated() {
                let globalFrame = CGRect(
                    x: host.desktopOrigin.x + screen.frame.origin.x,
                    y: host.desktopOrigin.y + screen.frame.origin.y,
                    width: screen.frame.width,
                    height: screen.frame.height
                )
                unifiedScreens.append(TPUnifiedScreen(
                    ownerHostId: host.identifier,
                    screenIndex: index,
                    frame: globalFrame,
                    isMain: index == 0
                ))
            }
        }
        
        return TPUnifiedDesktop(version: version, screens: unifiedScreens)
    }

    @MainActor
    func broadcastUnifiedDesktop(_ desktop: TPUnifiedDesktop) {
        guard let data = desktop.toData() else { return }
        let msg = TPMessage.create(with: .layoutUpdate, andData: data)
        warningLog("[LayoutSync] Broadcasting layout update, version=\(desktop.version)", module: .control)
        DeviceConnectionManager.shared.sendMessageToAllConnectedDevices(msg)
    }

    @MainActor
    func applyUnifiedDesktop(_ desktop: TPUnifiedDesktop) -> Bool {
        let currentVer = layoutVersion()
        guard desktop.version > currentVer else {
            warningLog("[LayoutSync] Ignoring layout update: incoming version (\(desktop.version)) <= local version (\(currentVer))", module: .control)
            return false
        }
        
        warningLog("[LayoutSync] Applying layout update: incoming version (\(desktop.version)) > local version (\(currentVer))", module: .control)
        TPPreferencesManager.shared().setValue(NSNumber(value: desktop.version), forKey: TPLayoutVersionKey)
        
        let localId = TPLocalHost.shared.identifier
        
        // Symmetrical layout sync: Find the absolute origin of the local host's primary screen
        // in the incoming layout to translate absolute coordinates into relative local coordinates.
        var localMainOrigin = CGPoint.zero
        if let localMainScreen = desktop.screens.first(where: { $0.ownerHostId == localId && $0.screenIndex == 0 }) {
            localMainOrigin = localMainScreen.frame.origin
        }
        
        for screen in desktop.screens {
            guard screen.ownerHostId != localId else { continue }
            guard let host = self.host(withIdentifier: screen.ownerHostId) else { continue }
            
            if screen.screenIndex < host.screens.count {
                let localFrame = host.screens[screen.screenIndex].frame
                let relativeOrigin = NSPoint(
                    x: screen.frame.origin.x - localMainOrigin.x,
                    y: screen.frame.origin.y - localMainOrigin.y
                )
                let computedOrigin = NSPoint(
                    x: relativeOrigin.x - localFrame.origin.x,
                    y: relativeOrigin.y - localFrame.origin.y
                )
                
                if host.desktopOrigin != computedOrigin {
                    host.desktopOrigin = computedOrigin
                    warningLog("[LayoutSync] Updated remote host \(host.computerName) position to \(computedOrigin) from layout update", module: .control)
                }
            }
        }
        
        saveHosts()
        notifyChanges()
        return true
    }

    @MainActor
    func addTrustedHostToHosts(_ host: TPRemoteHost) {
        if _hosts[host.identifier] == nil {
            _hosts[host.identifier] = host
            saveHosts()
            notifyChanges()
        }
    }
    
    @MainActor
    func removeTrustedHostFromHosts(_ host: TPRemoteHost) {
        if host.isInState(.online) {
            host.hostState = .shared
            saveHosts()
            notifyChanges()
        } else {
            if _hosts.removeValue(forKey: host.identifier) != nil {
                saveHosts()
                notifyChanges()
            }
        }
    }
}
