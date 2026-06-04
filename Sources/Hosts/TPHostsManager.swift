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

    func addBonjourHost(_ bonjourHost: TPRemoteHost) {
        let knownHost = self.host(withIdentifier: bonjourHost.identifier)
        var shouldNotify = true
        var shouldAutoConnect = false

        if let knownHost = knownHost {
            if bonjourHost.address != nil {
                let state = knownHost.hostState

                knownHost.address = bonjourHost.address
                knownHost.port = bonjourHost.port
                knownHost.screens = bonjourHost.screens

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
        } else {
            _hosts[bonjourHost.identifier] = bonjourHost
        }

        if shouldNotify {
            self.notifyChanges()
        }
        
        // Auto-connect to paired device that just came online
        if shouldAutoConnect, let knownHost = knownHost {
            Task { @MainActor in
                DeviceConnectionManager.shared.connect(to: knownHost)
            }
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
}
