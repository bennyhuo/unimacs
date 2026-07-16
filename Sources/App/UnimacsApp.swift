// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import SwiftUI

@main
struct UnimacsApp: App {
	@NSApplicationDelegateAdaptor(MainController.self) private var appDelegate

	init() {
		signal(SIGPIPE, SIG_IGN)
	}

	var body: some Scene {
		// Placeholder scene so SwiftUI provides the standard app menu (Quit, Hide, etc.).
		// Settings UI is hosted by SettingsWindowController, not this scene.
		SwiftUI.Settings {
			EmptyView()
		}
		.commands {
			CommandGroup(replacing: .appSettings) {
				Button("Configure…") {
					ModernSettingsLauncher.showSettings()
				}
				.keyboardShortcut(",", modifiers: [.command])
			}
		}
	}
}
