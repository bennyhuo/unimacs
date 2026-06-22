// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

extension Process {
	/// Terminates the process if it is running; no-op otherwise.
	func terminateIfRunning() {
		guard isRunning else { return }
		terminate()
	}
}
