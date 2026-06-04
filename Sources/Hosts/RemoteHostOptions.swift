// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

@objcMembers
class RemoteHostOptions: NSObject, NSMutableCopying, NSCoding {

    static let valuesKey = "customOptions"

    static let hasCustomOptionsKey = "hasCustomOptions"

    private var values: [String: Any]

    var hasCustomOptions: Bool {
        return !values.isEmpty
    }

    required init(coder: NSCoder) {
		values = coder.decodeObject(forKey: Self.valuesKey) as? [String: Any] ?? [:]
    }

    init(values: [String: Any]) {
        self.values = values
    }

    override init() {
        self.values = [:]
    }

	func mutableCopy(with zone: NSZone? = nil) -> Any {
        RemoteHostOptions(values: self.values)
    }

    func encode(with coder: NSCoder) {
        coder.encode(values, forKey: Self.valuesKey)
    }

    override func value(forKey key: String) -> Any? {
        values[key] ?? TPPreferencesManager.shared().value(forPref: key)
    }

    override func setValue(_ value: Any?, forKey key: String) {
        self.willChangeValue(forKey: Self.hasCustomOptionsKey)
        self.willChangeValue(forKey: key)

        let defaultValue = TPPreferencesManager.shared().value(forPref: key)
		let computedValue = (value as? NSObject)?.isEqual(defaultValue) == true ? nil : value
        values[key] = computedValue

        self.didChangeValue(forKey: key)
        self.didChangeValue(forKey: Self.hasCustomOptionsKey)
    }

    func reset() {
        for key in values.keys {
            self.willChangeValue(forKey: key)
            values.removeValue(forKey: key)
            self.didChangeValue(forKey: key)
        }
    }

    func makeDefault() {
        self.willChangeValue(forKey: Self.hasCustomOptionsKey)

        for (key, value) in values {
            TPPreferencesManager.shared().setValue(value, forKey: key)
        }
        values.removeAll()

        self.didChangeValue(forKey: Self.hasCustomOptionsKey)
    }
}
