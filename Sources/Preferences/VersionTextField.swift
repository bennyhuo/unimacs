// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa

@objc(VersionTextField)
final class VersionTextField: NSTextField {
	private var versions: [String] = []
	private var currentVersionIndex: Int = -1

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		commonInit()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		commonInit()
	}

	private func commonInit() {
		currentVersionIndex = -1
		versions = []
	}

	@objc(setVersions:)
	func setVersions(_ inVersions: NSArray) {
		versions = inVersions.compactMap { $0 as? String }
		changeVersion()
	}

	override func mouseDown(with event: NSEvent) {
		changeVersion()
	}

	@objc func changeVersion() {
		guard !versions.isEmpty else { return }

		currentVersionIndex += 1
		if currentVersionIndex >= versions.count {
			currentVersionIndex = 0
		}

		stringValue = versions[currentVersionIndex]
	}
}
