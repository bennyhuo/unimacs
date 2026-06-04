// Copyright (c) 2003-2012 abyssoft (Julien Robert) and Teleport contributors
// Copyright (c) 2025-2026 Benny Huo
// Migrated to Swift and modified from Teleport.
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

@objcMembers
class SoundUtils : NSObject {
	nonisolated(unsafe) private static var _switchSoundPath: String?
	nonisolated(unsafe) private static var _switchSound: NSSound?

	static func switchSound() -> NSSound? {
		var soundPath = TPPreferencesManager.shared().value(forPref: SWITCH_SOUND_PATH) as? String
		if soundPath == nil || !FileManager.default.fileExists(atPath: soundPath!) {
			soundPath = Bundle(for: self).path(forSoundResource: "switch-sound")
		}
		
		if _switchSoundPath == nil || _switchSoundPath != soundPath {
			_switchSoundPath = soundPath
			if let path = soundPath {
				_switchSound = NSSound(contentsOfFile: path, byReference: false)
				_switchSound?.volume = 0.3
			}
		}
		
		return _switchSound
	}
	
	static func playSwitchSound() {
		switchSound()?.play()
	}
	
	static func preheatSwitchSoundIfNeeded() {
		if TPPreferencesManager.shared().bool(forPref: PLAY_SWITCH_SOUND) {
			_ = switchSound()
		}
	}
}
