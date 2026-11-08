// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import AVFoundation
import CoreAudio

enum AudioMicTarget: String {
    case local = "local"
    case remote = "remote"
}

@objcMembers
final class AudioController: NSObject, AudioStreamManagerDelegate, ScreenCaptureKitAudioEngineDelegate {
    static let shared = AudioController()
    
    // Core components
    let streamManager = AudioStreamManager()
    private let scAudioEngine = ScreenCaptureKitAudioEngine()
    private var mutedDeviceID: AudioDeviceID?
    private var previousMuteState: Bool?
    private var previousVolumeState: Float?
    private var previousDefaultInputDeviceID: AudioDeviceID?
    
    // Playback Engines
    private let localPlaybackEngine = AVAudioEngine()
    private let remoteMicEngine = AVAudioEngine()
    private let localMicCaptureEngine = AVAudioEngine()
    
    // Playback Nodes (tracked for cleanup/detaching)
    private var localSysSourceNode: AVAudioSourceNode?
    private var remoteMicSourceNode: AVAudioSourceNode?
    
    // Ring Buffers (Float samples)
    private let sysRingBuffer = RingBuffer(capacity: 96000) // ~2 seconds buffer at 48kHz
    private let micRingBuffer = RingBuffer(capacity: 96000)
    
    // State
    private(set) var isHostSyncActive = false
    private(set) var isClientSyncActive = false
    var isSyncActive: Bool { isHostSyncActive || isClientSyncActive }
    private(set) var activeMicTarget: AudioMicTarget = .local
    private var peerAddress: String?
    private var peerHostId: String?
    private var isSysPlayable = false
    private var isMicPlayable = false
    private var sysUnderflowCount = 0
    private var micUnderflowCount = 0
    
    // Settings & Configuration
    
    var muteLocalSpeakers: Bool = true {
        didSet {
            PreferencesManager.shared().setValue(NSNumber(value: muteLocalSpeakers), forKey: "UMAudioMuteLocalSpeakers")
        }
    }
    
    var enableAdaptiveSpeed: Bool = true {
        didSet {
            PreferencesManager.shared().setValue(NSNumber(value: enableAdaptiveSpeed), forKey: "UMAudioEnableAdaptiveSpeed")
        }
    }
    
    var selectedVirtualDeviceName: String = "BlackHole 2ch" {
        didSet {
            PreferencesManager.shared().setValue(selectedVirtualDeviceName as NSString, forKey: "UMAudioVirtualDeviceName")
        }
    }
    
    @objc public static let audioHardwareStatusDidChangeNotification = Notification.Name("UMAudioHardwareStatusDidChangeNotification")
    
    public private(set) var hasLocalMicHardware: Bool = true
    public private(set) var hasLocalSpeakerHardware: Bool = true
    public private(set) var currentShareInput: Bool = false
    public private(set) var currentShareOutput: Bool = false
    
    override init() {
        super.init()
        streamManager.delegate = self
        scAudioEngine.delegate = self
        
        // Load settings
        if let muteLocalVal = PreferencesManager.shared().value(forKey: "UMAudioMuteLocalSpeakers") as? NSNumber {
            self.muteLocalSpeakers = muteLocalVal.boolValue
        } else {
            self.muteLocalSpeakers = true
        }
        if let adaptiveSpeedVal = PreferencesManager.shared().value(forKey: "UMAudioEnableAdaptiveSpeed") as? NSNumber {
            self.enableAdaptiveSpeed = adaptiveSpeedVal.boolValue
        } else {
            self.enableAdaptiveSpeed = true
        }
        if let deviceNameVal = PreferencesManager.shared().value(forKey: "UMAudioVirtualDeviceName") as? String {
            self.selectedVirtualDeviceName = deviceNameVal
        }
        
        // Auto-fix virtual device name if it is not BlackHole but BlackHole is available
        let availableInputDevices = getInputDevices()
        if !selectedVirtualDeviceName.lowercased().contains("blackhole") {
            if availableInputDevices.contains(where: { $0.lowercased().contains("blackhole") }) {
                selectedVirtualDeviceName = "BlackHole 2ch"
            }
        }
        
        // Synchronously initialize hardware status
        self.hasLocalMicHardware = !getPhysicalInputDevices().isEmpty
        self.hasLocalSpeakerHardware = !getOutputDevices().isEmpty
        
        setupNotificationObservers()
        Task { @MainActor in
            setupCoreAudioHardwareListeners()
        }
    }
    
    private func setupNotificationObservers() {
        // Stop audio when peer disconnects
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConnectionStateChange(_:)),
            name: NSNotification.Name("UMConnectionStateDidChangeNotification"),
            object: nil
        )
        
        // Listen to audio engine configuration changes (e.g. device output switch)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: localPlaybackEngine
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: remoteMicEngine
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: localMicCaptureEngine
        )
    }
    
    @MainActor
    private func setupCoreAudioHardwareListeners() {
        updateLocalHardwareStatus(notify: false)
        
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let selectorsToListen: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice
        ]
        
        for selector in selectorsToListen {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: AudioObjectPropertyElement(0)
            )
            
            AudioObjectAddPropertyListenerBlock(systemObjectID, &propertyAddress, DispatchQueue.main) { [weak self] _, _ in
                Task { @MainActor in
                    self?.updateLocalHardwareStatus(notify: true)
                }
            }
        }
    }
    
    @MainActor
    public func updateLocalHardwareStatus(notify: Bool = true) {
        let physInputs = getPhysicalInputDevices()
        let outputs = getOutputDevices()
        let micAvailable = !physInputs.isEmpty
        let speakerAvailable = !outputs.isEmpty
        
        let micChanged = (micAvailable != hasLocalMicHardware)
        let speakerChanged = (speakerAvailable != hasLocalSpeakerHardware)
        
        debugLog("AudioController: [HWStatusUpdate] micAvailable=\(micAvailable) (devices: \(physInputs)), speakerAvailable=\(speakerAvailable), micChanged=\(micChanged), prevHasMic=\(hasLocalMicHardware), isHostSyncActive=\(isHostSyncActive), currentShareInput=\(currentShareInput)", module: .network)
        
        self.hasLocalMicHardware = micAvailable
        self.hasLocalSpeakerHardware = speakerAvailable
        
        if isHostSyncActive {
            if micAvailable && currentShareInput {
                debugLog("AudioController: Physical mic available during active sync. Dynamically starting/restarting local mic capture.", module: .network)
                self.activeMicTarget = .remote
                stopLocalMicCapture()
                startLocalMicCapture()
            } else if !micAvailable {
                debugLog("AudioController: Physical mic removed during active sync. Dynamically stopping local mic capture.", module: .network)
                self.activeMicTarget = .local
                stopLocalMicCapture()
            }
        }
        
        if notify && (micChanged || speakerChanged) {
            debugLog("AudioController: CoreAudio hardware status changed. Mic: \(micAvailable), Speaker: \(speakerAvailable)", module: .network)
            NotificationCenter.default.post(
                name: AudioController.audioHardwareStatusDidChangeNotification,
                object: self,
                userInfo: [
                    "hasMic": micAvailable,
                    "hasSpeaker": speakerAvailable
                ]
            )
            sendHardwareStatusToActivePeer()
        }
    }
    
    @MainActor
    public func sendHardwareStatusToActivePeer() {
        guard let conn = activeConnection else { return }
        let msg = Message.create(with: .audioHardwareStatusUpdate, andInfoDict: [
            "hasMic": hasLocalMicHardware,
            "hasSpeaker": hasLocalSpeakerHardware
        ])
        _ = conn.sendMessage(msg)
        debugLog("AudioController: Sent audioHardwareStatusUpdate to active peer. Mic: \(hasLocalMicHardware), Speaker: \(hasLocalSpeakerHardware)", module: .network)
    }
    
    @MainActor
    @objc private func handleConnectionStateChange(_ notification: Notification) {
        if !DeviceConnectionManager.shared.isConnected {
            stopAudioSync()
        } else {
            sendHardwareStatusToActivePeer()
        }
    }
    
    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        guard let engine = notification.object as? AVAudioEngine else { return }
        
        debugLog("AudioController: AVAudioEngineConfigurationChange received", module: .network)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if engine === self.localPlaybackEngine {
                if self.isHostSyncActive && self.localSysSourceNode != nil {
                    debugLog("AudioController: Restarting localPlaybackEngine due to config change", module: .network)
                    self.startLocalSystemPlayback()
                }
            } else if engine === self.remoteMicEngine {
                if self.isClientSyncActive && self.remoteMicSourceNode != nil {
                    debugLog("AudioController: Restarting remoteMicEngine due to config change", module: .network)
                    self.startRemoteMicPlayback()
                }
            } else if engine === self.localMicCaptureEngine {
                if self.isHostSyncActive && self.activeMicTarget == .remote {
                    debugLog("AudioController: Restarting localMicCaptureEngine due to config change", module: .network)
                    self.startLocalMicCapture()
                }
            }
        }
    }
    
    // MARK: - CoreAudio Device Helpers
    
    func getInputDevices() -> [String] {
        return getDevices(isInput: true)
    }
    
    func getPhysicalInputDevices() -> [String] {
        return getInputDevices().filter { name in
            let lower = name.lowercased()
            return !lower.contains("blackhole") &&
                   !lower.contains("soundflower") &&
                   !lower.contains("zoom") &&
                   !lower.contains("loopback") &&
                   !lower.contains("virtual") &&
                   !lower.contains("vad")
        }
    }
    
    func getOutputDevices() -> [String] {
        return getDevices(isInput: false)
    }
    
    private func getDevices(isInput: Bool) -> [String] {
        return queryAudioDevices(isInput: isInput).map { $0.name }
    }
    
    /// Find AudioDeviceID by name matching
    private func findDeviceID(named name: String, isInput: Bool) -> AudioDeviceID? {
        let lowerTarget = name.lowercased()
        if let match = queryAudioDevices(isInput: isInput).first(where: { $0.name.lowercased().contains(lowerTarget) }) {
            return match.id
        }
        return queryAudioDevices(isInput: nil).first(where: { $0.name.lowercased().contains(lowerTarget) })?.id
    }

    /// Queries CoreAudio hardware devices, optionally filtered by stream direction (`isInput`).
    private func queryAudioDevices(isInput: Bool?) -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: AudioObjectPropertyElement(0)
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else { return [] }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }
        
        var result = [(id: AudioDeviceID, name: String)]()
        for deviceID in deviceIDs {
            if let isInput = isInput {
                let scope: AudioObjectPropertyScope = isInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
                var streamAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreams,
                    mScope: scope,
                    mElement: AudioObjectPropertyElement(0)
                )
                var streamSize: UInt32 = 0
                status = AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize)
                guard status == noErr && streamSize > 0 else { continue }
                let streamCount = Int(streamSize) / MemoryLayout<AudioStreamID>.size
                guard streamCount > 0 else { continue }
                
                if let name = audioDeviceName(for: deviceID) {
                    debugLog("AudioController: [DeviceQuery] \(isInput ? "Input" : "Output") Device [ID:\(deviceID)] '\(name)': streams=\(streamCount)", module: .network)
                    result.append((id: deviceID, name: name))
                }
            } else if let name = audioDeviceName(for: deviceID) {
                result.append((id: deviceID, name: name))
            }
        }
        return result
    }

    private func audioDeviceName(for deviceID: AudioDeviceID) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: AudioObjectPropertyElement(0)
        )
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var deviceNameCF: CFString?
        let status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &deviceNameCF)
        guard status == noErr, let name = deviceNameCF as String? else { return nil }
        return name
    }
    
    // MARK: - Core Audio Sync Actions
    
    /// Initialize audio sync channels after handshaking UDP ports with peer
    @MainActor
    func startAudioSync(peerHostId: String, peerIp: String, localUdpPort: UInt16, peerUdpPort: UInt16, isHostRole: Bool, shareOutput: Bool, shareInput: Bool) {
        self.peerHostId = peerHostId
        self.isSysPlayable = false
        self.isMicPlayable = false
        self.sysUnderflowCount = 0
        self.micUnderflowCount = 0
        self.currentShareInput = shareInput
        self.currentShareOutput = shareOutput
        if isHostRole { // Server role (MINI, Remote)
            guard !isHostSyncActive else {
                debugLog("[\(Unmanaged.passUnretained(self).toOpaque())] AudioController: Host audio sync already active. Skipping.", module: .network)
                return
            }
            debugLog("[\(Unmanaged.passUnretained(self).toOpaque())] AudioController: Starting Host Audio Sync. Peer IP: \(peerIp), Local Port: \(localUdpPort), Peer Port: \(peerUdpPort)", module: .network)
            self.peerAddress = peerIp
            self.isHostSyncActive = true
            
            // Set up stream manager configuration
            if let compressPref = PreferencesManager.shared().value(forKey: "UMAudioUseCompression") as? NSNumber {
                streamManager.useCompression = compressPref.boolValue
            }
            
            // Server (MINI) sends mic input to Client (MBP)
            streamManager.startMicSender(toHost: peerIp, port: peerUdpPort)
            sysRingBuffer.clear()
            
            // Server (MINI) plays received MBP system output in local playback engine
            if shareOutput {
                startLocalSystemPlayback()
            }
            
            // Server (MINI) captures local mic input and streams it
            if shareInput && hasLocalMicHardware && !getPhysicalInputDevices().isEmpty {
                self.activeMicTarget = .remote
                startLocalMicCapture()
            } else {
                self.activeMicTarget = .local
                if shareInput {
                    warningLog("AudioController: Requested mic input sharing, but host has no microphone hardware available. Skipping capture.", module: .network)
                }
            }
        } else { // Client role (MBP, Local)
            guard !isClientSyncActive else {
                debugLog("[\(Unmanaged.passUnretained(self).toOpaque())] AudioController: Client audio sync already active. Skipping.", module: .network)
                return
            }
            debugLog("[\(Unmanaged.passUnretained(self).toOpaque())] AudioController: Starting Client Audio Sync. Peer IP: \(peerIp), Local Port: \(localUdpPort), Peer Port: \(peerUdpPort)", module: .network)
            self.peerAddress = peerIp
            self.isClientSyncActive = true
            
            // Set up stream manager configuration
            if let compressPref = PreferencesManager.shared().value(forKey: "UMAudioUseCompression") as? NSNumber {
                streamManager.useCompression = compressPref.boolValue
            }
            
            // Client (MBP) sends system output to Server (MINI)
            streamManager.startSysSender(toHost: peerIp, port: peerUdpPort)
            micRingBuffer.clear()
            
            // Client (MBP) captures local system output and streams it
            if shareOutput {
                if muteLocalSpeakers {
                    muteDefaultOutputDeviceIfNeeded()
                }
                scAudioEngine.start()
            }
            
            // Client (MBP) plays received MINI mic input in local virtual output
            if shareInput {
                self.activeMicTarget = .remote
                switchToVirtualInputDeviceIfNeeded()
                startRemoteMicPlayback()
            } else {
                self.activeMicTarget = .local
            }
        }
    }
    
    @MainActor
    func stopAudioSync() {
        guard isSyncActive else { return }
        debugLog("AudioController: Stopping Audio Sync", module: .network)
        
        scAudioEngine.stop()
        restoreDefaultOutputDeviceMuteIfNeeded()
        restoreDefaultInputDeviceIfNeeded()
        
        streamManager.stopSysListener()
        streamManager.stopMicListener()
        streamManager.stopSender()
        
        stopLocalPlayback()
        stopRemoteMicPlayback()
        stopLocalMicCapture()
        
        isHostSyncActive = false
        isClientSyncActive = false
        isSysPlayable = false
        isMicPlayable = false
        sysUnderflowCount = 0
        micUnderflowCount = 0
        peerAddress = nil
        peerHostId = nil
        currentShareInput = false
        currentShareOutput = false
    }
    
    // MARK: - Local Mac A: Playback & Capture
    
    private func startLocalSystemPlayback() {
        stopLocalPlayback() // Clean up any existing system playback node to prevent engine collision
        if !enableAdaptiveSpeed {
            sysRingBuffer.clear() // Clear backlog to maintain low latency
        }
        let mainMixer = localPlaybackEngine.mainMixerNode
        guard let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2) else {
            errorLog("AudioController: Failed to create playback format", module: .network)
            return
        }
        
        var callbackCount = 0
        var lastSampleTime: Double = -1.0
        var resampledRight = [Float](repeating: 0.0, count: 8192)
        
        // Pre-allocate temporary buffers outside the render callback
        // to avoid heap allocation on the real-time audio thread.
        // Sized for max frameCount=4096 with 1.01x adaptive rate adjustment.
        let maxSysInputCount = 8500
        var preallocSysInput = [Float](repeating: 0.0, count: maxSysInputCount)
        var preallocSysL = [Float](repeating: 0.0, count: maxSysInputCount / 2)
        var preallocSysR = [Float](repeating: 0.0, count: maxSysInputCount / 2)
        
        // Create an AVAudioSourceNode to read from ring buffer
        let sourceNode = AVAudioSourceNode { [weak self] (isSilence, timestamp, frameCount, audioBufferList) -> OSStatus in
            guard let self = self else { return noErr }
            isSilence.pointee = false
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard !ablPointer.isEmpty else { return noErr }
            
            callbackCount &+= 1
            let logThrottled = (callbackCount == 1 || callbackCount % 1000 == 0)
            
            let currentSampleTime = timestamp.pointee.mSampleTime
            let fCount = Int(frameCount)
            
            if ablPointer.count == 1 {
                let isSecondChannel = (currentSampleTime == lastSampleTime)
                if isSecondChannel {
                    if let rData = ablPointer[0].mData {
                        let rightPtr = rData.assumingMemoryBound(to: Float.self)
                        rightPtr.assign(from: resampledRight, count: fCount)
                    }
                    return noErr
                }
                lastSampleTime = currentSampleTime
            }
            
            if !self.isSysPlayable {
                if logThrottled {
                    debugLog("[\(Unmanaged.passUnretained(self).toOpaque())] AudioController: SysPlayback waiting for pre-buffer. Available: \(self.sysRingBuffer.availableRead)", module: .network)
                }
                if self.sysRingBuffer.availableRead >= 9600 { // 100ms stereo pre-buffer (9600 samples)
                    self.isSysPlayable = true
                    debugLog("[\(Unmanaged.passUnretained(self).toOpaque())] AudioController: SysPlayback pre-buffering completed. Starting playback.", module: .network)
                } else {
                    for ch in 0..<ablPointer.count {
                        if let chData = ablPointer[ch].mData {
                            let chPtr = chData.assumingMemoryBound(to: Float.self)
                            for i in 0..<Int(frameCount) {
                                chPtr[i] = 0.0
                            }
                        }
                    }
                    return noErr
                }
            }
            
            let leftBuffer = ablPointer[0]
            if let mData = leftBuffer.mData {
                let leftPtr = mData.assumingMemoryBound(to: Float.self)
                let fCount = Int(frameCount)
                
                // Stereo stream is interleaved L/R: we need twice as many samples as frameCount
                let targetInputCount = fCount * 2
                let available = self.sysRingBuffer.availableRead
                var inputCount = targetInputCount
                
                if self.isSysPlayable && self.enableAdaptiveSpeed {
                    if available < 2880 * 2 { // Less than 60ms stereo: stretch (slow down playback to let buffer fill)
                        inputCount = Int(Double(targetInputCount) * 0.95)
                        if inputCount % 2 != 0 { inputCount -= 1 }
                    } else if available > 5760 * 2 { // More than 120ms stereo: compress (speed up playback to drain buffer)
                        inputCount = Int(Double(targetInputCount) * 1.05)
                        if inputCount % 2 != 0 { inputCount += 1 }
                    }
                }
                
                // Reuse pre-allocated buffers (no heap allocation on real-time thread)
                let readCount = self.sysRingBuffer.read(into: &preallocSysInput, count: inputCount)
                
                if readCount < inputCount {
                    for i in readCount..<inputCount {
                        preallocSysInput[i] = 0.0
                    }
                }
                
                // Separate L and R channels from interleaved stream
                let halfInputCount = inputCount / 2
                for i in 0..<halfInputCount {
                    preallocSysL[i] = preallocSysInput[2 * i]
                    preallocSysR[i] = preallocSysInput[2 * i + 1]
                }
                
                // Resample L into Left channel
                self.resample(from: preallocSysL, inputCount: halfInputCount, to: leftPtr, outputCount: fCount)
                
                // Resample R into Right channel
                if ablPointer.count > 1, let rData = ablPointer[1].mData {
                    let rightPtr = rData.assumingMemoryBound(to: Float.self)
                    self.resample(from: preallocSysR, inputCount: halfInputCount, to: rightPtr, outputCount: fCount)
                } else {
                    // Store in temporary buffer for the second channel's call
                    self.resample(from: preallocSysR, inputCount: halfInputCount, to: &resampledRight, outputCount: fCount)
                }
                
                if logThrottled {
                    var minL: Float = 0.0
                    var maxL: Float = 0.0
                    for i in 0..<fCount {
                        let val = leftPtr[i]
                        if val < minL { minL = val }
                        if val > maxL { maxL = val }
                    }
                    debugLog("[\(Unmanaged.passUnretained(self).toOpaque())] AudioController: SysPlayback render. Read: \(readCount)/\(inputCount) -> Resampled: \(fCount), Available: \(self.sysRingBuffer.availableRead), Underflows: \(self.sysUnderflowCount), Output Min: \(minL), Max: \(maxL)", module: .network)
                }
                
                if readCount < inputCount {
                    self.sysUnderflowCount += 1
                    if self.sysUnderflowCount >= 5 { // 5 consecutive partial/empty reads triggers re-buffering
                        self.isSysPlayable = false
                        debugLog("[\(Unmanaged.passUnretained(self).toOpaque())] AudioController: SysPlayback underflow trigger. Pausing for pre-buffer.", module: .network)
                    }
                } else {
                    self.sysUnderflowCount = 0
                }
            }
            return noErr
        }
        
        self.localSysSourceNode = sourceNode
        localPlaybackEngine.attach(sourceNode)
        localPlaybackEngine.connect(sourceNode, to: mainMixer, format: playbackFormat)
        
        do {
            try localPlaybackEngine.start()
            debugLog("AudioController: Local playback engine started successfully", module: .network)
        } catch {
            errorLog("AudioController: Failed to start local playback engine: \(error)", module: .network)
        }
    }
    
    private func stopLocalPlayback() {
        localPlaybackEngine.stop()
        if let node = localSysSourceNode {
            localPlaybackEngine.detach(node)
            localSysSourceNode = nil
        }
        localPlaybackEngine.reset()
    }
    
    private func startLocalMicCapture() {
        guard hasLocalMicHardware && !getPhysicalInputDevices().isEmpty else {
            warningLog("AudioController: Skipping mic capture start - no physical microphone hardware detected.", module: .network)
            return
        }
        
        // Verify recording permission first
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let self = self, granted else {
                errorLog("AudioController: Microphone access denied by user", module: .network)
                return
            }
            
            DispatchQueue.main.async {
                guard self.hasLocalMicHardware && !self.getPhysicalInputDevices().isEmpty else {
                    warningLog("AudioController: Skipping mic capture tap install - physical microphone hardware absent.", module: .network)
                    return
                }
                
                // Thoroughly reset engine & tap before setup
                self.localMicCaptureEngine.inputNode.removeTap(onBus: 0)
                if self.localMicCaptureEngine.isRunning {
                    self.localMicCaptureEngine.stop()
                }
                self.localMicCaptureEngine.reset()
                
                let inputNode = self.localMicCaptureEngine.inputNode
                let inputFormat = inputNode.inputFormat(forBus: 0)
                let outputFormat = inputNode.outputFormat(forBus: 0)
                
                let formatToUse: AVAudioFormat?
                if inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 {
                    formatToUse = inputFormat
                } else if outputFormat.sampleRate > 0 && outputFormat.channelCount > 0 {
                    formatToUse = outputFormat
                } else {
                    formatToUse = nil
                }
                
                guard let tapFormat = formatToUse else {
                    errorLog("AudioController: No valid microphone format available (input: \(inputFormat), output: \(outputFormat)). Host may lack physical microphone hardware.", module: .network)
                    return
                }
                
                var micPacketCount = 0
                
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, time in
                    guard let self = self else { return }
                    // Only stream if mic target is remote
                    guard self.activeMicTarget == .remote else { return }
                    
                    if let channels = buffer.floatChannelData {
                        let sampleCount = Int(buffer.frameLength)
                        let samples = Array(UnsafeBufferPointer(start: channels[0], count: sampleCount))
                        
                        micPacketCount &+= 1
                        if micPacketCount == 1 || micPacketCount % 200 == 0 {
                            var minVal: Float = 0.0
                            var maxVal: Float = 0.0
                            for s in samples {
                                if s < minVal { minVal = s }
                                if s > maxVal { maxVal = s }
                            }
                            debugLog("AudioController: Captured local mic samples (size: \(samples.count)). Signal min: \(minVal), max: \(maxVal)", module: .network)
                        }
                        
                        self.streamManager.sendAudio(samples: samples, isSystemAudio: false)
                    }
                }
                
                // If engine isn't running, start it
                if !self.localMicCaptureEngine.isRunning {
                    do {
                        try self.localMicCaptureEngine.start()
                    } catch {
                        errorLog("AudioController: Failed to start engine for mic capture: \(error)", module: .network)
                    }
                }
                debugLog("AudioController: Local mic capture tap installed successfully on separate engine (running: \(self.localMicCaptureEngine.isRunning))", module: .network)
            }
        }
    }
    
    private func stopLocalMicCapture() {
        localMicCaptureEngine.inputNode.removeTap(onBus: 0)
        if localMicCaptureEngine.isRunning {
            localMicCaptureEngine.stop()
        }
        localMicCaptureEngine.reset()
    }
    
    // MARK: - Remote Mac B: Playback into Loopback Virtual Device
    
    private func startRemoteMicPlayback() {
        stopRemoteMicPlayback() // Clean up any existing remote mic playback node to prevent engine collision
        if !enableAdaptiveSpeed {
            micRingBuffer.clear() // Clear backlog to maintain low latency
        }
        let outputNode = remoteMicEngine.outputNode
        guard let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2) else {
            errorLog("AudioController: Failed to create playback format", module: .network)
            return
        }
        let mainMixer = remoteMicEngine.mainMixerNode
        
        // Find Virtual Device ID (e.g. BlackHole)
        if let deviceID = findDeviceID(named: selectedVirtualDeviceName, isInput: false) {
            let audioUnit = outputNode.audioUnit
            var devID = deviceID
            let status = AudioUnitSetProperty(
                audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                errorLog("AudioController: Failed to assign BlackHole output device: \(status)", module: .network)
            } else {
                debugLog("AudioController: Assigned virtual output device \(selectedVirtualDeviceName) (ID \(deviceID)) successfully", module: .network)
            }
        } else {
            debugLog("AudioController: Virtual device '\(selectedVirtualDeviceName)' not found. Outputting to default device.", module: .network)
        }
        
        var callbackCount = 0
        var lastSampleTime: Double = -1.0
        var resampledRight = [Float](repeating: 0.0, count: 8192)
        
        // Pre-allocate temporary buffer outside the render callback
        // to avoid heap allocation on the real-time audio thread.
        let maxMicInputCount = 4200
        var preallocMicInput = [Float](repeating: 0.0, count: maxMicInputCount)
        
        let sourceNode = AVAudioSourceNode { [weak self] (isSilence, timestamp, frameCount, audioBufferList) -> OSStatus in
            guard let self = self else { return noErr }
            isSilence.pointee = false
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard !ablPointer.isEmpty else { return noErr }
            
            callbackCount &+= 1
            let logThrottled = (callbackCount == 1 || callbackCount % 1000 == 0)
            
            let currentSampleTime = timestamp.pointee.mSampleTime
            let fCount = Int(frameCount)
            
            if ablPointer.count == 1 {
                let isSecondChannel = (currentSampleTime == lastSampleTime)
                if isSecondChannel {
                    if let rData = ablPointer[0].mData {
                        let rightPtr = rData.assumingMemoryBound(to: Float.self)
                        rightPtr.assign(from: resampledRight, count: fCount)
                    }
                    return noErr
                }
                lastSampleTime = currentSampleTime
            }
            
            if !self.isMicPlayable {
                if logThrottled {
                    debugLog("AudioController: MicPlayback waiting for pre-buffer. Available: \(self.micRingBuffer.availableRead)", module: .network)
                }
                if self.micMicAvailableReadCheck(logThrottled) {
                    self.isMicPlayable = true
                    debugLog("AudioController: MicPlayback pre-buffering completed. Starting playback.", module: .network)
                } else {
                    for ch in 0..<ablPointer.count {
                        if let chData = ablPointer[ch].mData {
                            let chPtr = chData.assumingMemoryBound(to: Float.self)
                            for i in 0..<Int(frameCount) {
                                chPtr[i] = 0.0
                              }
                        }
                    }
                    return noErr
                }
            }
            
            let leftBuffer = ablPointer[0]
            if let mData = leftBuffer.mData {
                let leftPtr = mData.assumingMemoryBound(to: Float.self)
                let fCount = Int(frameCount)
                
                // Mic is Mono
                let targetInputCount = fCount
                let available = self.micRingBuffer.availableRead
                var inputCount = targetInputCount
                
                if self.isMicPlayable && self.enableAdaptiveSpeed {
                    if available < 2880 { // Less than 60ms mono: stretch
                        inputCount = Int(Double(targetInputCount) * 0.95)
                    } else if available > 5760 { // More than 120ms mono: compress
                        inputCount = Int(Double(targetInputCount) * 1.05)
                    }
                }
                
                // Reuse pre-allocated buffer (no heap allocation on real-time thread)
                let readCount = self.micRingBuffer.read(into: &preallocMicInput, count: inputCount)
                
                if readCount < inputCount {
                    for i in readCount..<inputCount {
                        preallocMicInput[i] = 0.0
                    }
                }
                
                // Resample Mono into Left channel
                self.resample(from: preallocMicInput, inputCount: inputCount, to: leftPtr, outputCount: fCount)
                
                if logThrottled {
                    debugLog("AudioController: MicPlayback render. Read: \(readCount)/\(inputCount) -> Resampled: \(fCount), Available: \(self.micRingBuffer.availableRead), Underflows: \(self.micUnderflowCount)", module: .network)
                }
                
                if readCount < inputCount {
                    self.micUnderflowCount += 1
                    if self.micUnderflowCount >= 5 { // 5 consecutive partial/empty reads triggers re-buffering
                        self.isMicPlayable = false
                        debugLog("AudioController: MicPlayback underflow trigger. Pausing for pre-buffer.", module: .network)
                    }
                } else {
                    self.micUnderflowCount = 0
                }
                
                if ablPointer.count > 1 {
                    for ch in 1..<ablPointer.count {
                        if let chData = ablPointer[ch].mData {
                            let chPtr = chData.assumingMemoryBound(to: Float.self)
                            chPtr.assign(from: leftPtr, count: fCount)
                        }
                    }
                } else {
                    // Copy Left channel output to temporary buffer for the Right channel call
                    resampledRight.withUnsafeMutableBufferPointer { dest in
                        if let destAddress = dest.baseAddress {
                            destAddress.assign(from: leftPtr, count: fCount)
                        }
                    }
                }
            }
            return noErr
        }
        
        self.remoteMicSourceNode = sourceNode
        remoteMicEngine.attach(sourceNode)
        remoteMicEngine.connect(sourceNode, to: mainMixer, format: playbackFormat)
        remoteMicEngine.connect(mainMixer, to: outputNode, format: playbackFormat)
        
        do {
            try remoteMicEngine.start()
            debugLog("AudioController: Remote virtual mic playback engine started", module: .network)
        } catch {
            errorLog("AudioController: Failed to start remote virtual mic engine: \(error)", module: .network)
        }
    }
    
    private func stopRemoteMicPlayback() {
        remoteMicEngine.stop()
        if let node = remoteMicSourceNode {
            remoteMicEngine.detach(node)
            remoteMicSourceNode = nil
        }
        remoteMicEngine.reset()
    }
    
    // MARK: - Mic Routing Switches
    
    @MainActor
    private var activeConnection: NetworkConnection? {
        guard let hostId = peerHostId else { return nil }
        return DeviceConnectionManager.shared.connection(forHostId: hostId)
    }
    
    @MainActor
    func setMicrophoneTarget(_ target: AudioMicTarget, notifyPeer: Bool = true) {
        guard activeMicTarget != target else { return }
        self.activeMicTarget = target
        debugLog("AudioController: Microphone target changed to: \(target.rawValue)", module: .network)
        
        NotificationCenter.default.post(name: NSNotification.Name("UMAudioMicRouteDidChangeNotification"), object: nil)
        
        if isClientSyncActive { // Client role (MBP, Local)
            if target == .remote {
                // Client receives and plays Mic audio from Server
                switchToVirtualInputDeviceIfNeeded()
                startRemoteMicPlayback()
            } else {
                stopRemoteMicPlayback()
                restoreDefaultInputDeviceIfNeeded()
            }
        } else if isHostSyncActive { // Server role (Host, MINI)
            if target == .remote {
                // Server captures local Mic audio and streams it
                startLocalMicCapture()
            } else {
                stopLocalMicCapture()
            }
        }
        
        if notifyPeer, let conn = activeConnection {
            let msg = Message.create(with: .audioMicRouteUpdate, andInfoDict: ["target": target.rawValue])
            _ = conn.sendMessage(msg)
        }
    }
    
    @MainActor
    func setShareOutputEnabled(_ enabled: Bool) {
        guard isSyncActive else { return }
        if isClientSyncActive { // Client role (MBP, Local)
            if enabled {
                if muteLocalSpeakers {
                    muteDefaultOutputDeviceIfNeeded()
                }
                // Client captures its system audio and sends to Server
                scAudioEngine.start()
            } else {
                scAudioEngine.stop()
                restoreDefaultOutputDeviceMuteIfNeeded()
            }
            if let conn = activeConnection {
                let msg = Message.create(with: .audioOutputRouteUpdate, andInfoDict: ["enabled": enabled])
                _ = conn.sendMessage(msg)
            }
        }
    }
    
    @MainActor
    func setHostSystemCaptureEnabled(_ enabled: Bool) {
        guard isHostSyncActive else { return } // Server role (Host, MINI)
        if enabled {
            // Server plays received system audio samples
            startLocalSystemPlayback()
        } else {
            stopLocalPlayback()
        }
    }
    
    /// Get current system default output device ID
    func getDefaultOutputDeviceID() -> AudioDeviceID? {
        getDefaultAudioDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }
    
    /// Set system default output device ID
    @discardableResult
    func setDefaultOutputDeviceID(_ deviceID: AudioDeviceID) -> Bool {
        setDefaultAudioDeviceID(deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func getDefaultAudioDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: AudioObjectPropertyElement(0)
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func setDefaultAudioDeviceID(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: AudioObjectPropertyElement(0)
        )
        var deviceIDVar = deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            dataSize,
            &deviceIDVar
        )
        return status == noErr
    }
    
    /// Get current volume of device
    func getDeviceVolume(deviceID: AudioDeviceID) -> Float {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: AudioObjectPropertyElement(0)
        )
        var volume: Float = 1.0
        var dataSize = UInt32(MemoryLayout<Float>.size)
        
        var status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &volume)
        if status != noErr {
            propertyAddress.mScope = kAudioObjectPropertyScopeGlobal
            status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &volume)
        }
        return status == noErr ? volume : 1.0
    }
    
    /// Set volume of device
    @discardableResult
    func setDeviceVolume(deviceID: AudioDeviceID, volume: Float) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: AudioObjectPropertyElement(0)
        )
        var volumeVar = volume
        let dataSize = UInt32(MemoryLayout<Float>.size)
        
        var status = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, dataSize, &volumeVar)
        if status != noErr {
            propertyAddress.mScope = kAudioObjectPropertyScopeGlobal
            status = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, dataSize, &volumeVar)
        }
        return status == noErr
    }
    
    /// Get mute state of device
    func getDeviceMute(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: AudioObjectPropertyElement(0)
        )
        var isMuted: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        
        var status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &isMuted)
        if status != noErr {
            propertyAddress.mScope = kAudioObjectPropertyScopeGlobal
            status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &isMuted)
        }
        return status == noErr && isMuted != 0
    }
    
    /// Set mute state of device
    @discardableResult
    func setDeviceMute(deviceID: AudioDeviceID, mute: Bool) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: AudioObjectPropertyElement(0)
        )
        var isMuted: UInt32 = mute ? 1 : 0
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        
        var status = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, dataSize, &isMuted)
        if status != noErr {
            propertyAddress.mScope = kAudioObjectPropertyScopeGlobal
            status = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, dataSize, &isMuted)
        }
        return status == noErr
    }
    
    /// Mute the default output device and save previous volume/mute state
    @MainActor
    func muteDefaultOutputDeviceIfNeeded() {
        guard let deviceID = getDefaultOutputDeviceID() else { return }
        
        self.mutedDeviceID = deviceID
        self.previousMuteState = getDeviceMute(deviceID: deviceID)
        self.previousVolumeState = getDeviceVolume(deviceID: deviceID)
        
        let muteSuccess = setDeviceMute(deviceID: deviceID, mute: true)
        let volSuccess = setDeviceVolume(deviceID: deviceID, volume: 0.0)
        
        if muteSuccess || volSuccess {
            NSLog("AudioController: Successfully muted default output device ID \(deviceID) for output sharing.")
        } else {
            NSLog("AudioController: Failed to mute default output device ID \(deviceID).")
        }
    }
    
    /// Restore default output device's volume and mute state
    @MainActor
    func restoreDefaultOutputDeviceMuteIfNeeded() {
        guard let deviceID = mutedDeviceID else { return }
        self.mutedDeviceID = nil
        
        if let prevMute = previousMuteState {
            setDeviceMute(deviceID: deviceID, mute: prevMute)
        }
        if let prevVol = previousVolumeState {
            setDeviceVolume(deviceID: deviceID, volume: prevVol)
        }
        
        NSLog("AudioController: Restored volume/mute state on device ID \(deviceID).")
    }
    
    /// Get current system default input device ID
    func getDefaultInputDeviceID() -> AudioDeviceID? {
        getDefaultAudioDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }
    
    /// Set system default input device ID
    @discardableResult
    func setDefaultInputDeviceID(_ deviceID: AudioDeviceID) -> Bool {
        setDefaultAudioDeviceID(deviceID, selector: kAudioHardwarePropertyDefaultInputDevice)
    }
    
    /// Check and automatically route default system input to BlackHole virtual device
    @MainActor
    func switchToVirtualInputDeviceIfNeeded() {
        guard let virtualDeviceID = findDeviceID(named: selectedVirtualDeviceName, isInput: true) else {
            NSLog("AudioController: Virtual device '\(selectedVirtualDeviceName)' not found for input auto-switch.")
            return
        }
        
        let currentDefaultID = getDefaultInputDeviceID()
        guard currentDefaultID != virtualDeviceID else {
            NSLog("AudioController: Default input is already virtual device.")
            return
        }
        
        self.previousDefaultInputDeviceID = currentDefaultID
        
        if setDefaultInputDeviceID(virtualDeviceID) {
            NSLog("AudioController: Automatically switched default input to virtual device '\(selectedVirtualDeviceName)'.")
            BezelController.default().setMode(.notification(
                title: NSLocalizedString("Input Routed", comment: ""),
                subtitle: NSLocalizedString("Default input switched to BlackHole.", comment: ""),
                icon: .success,
                duration: 3.0
            ))
        } else {
            NSLog("AudioController: Failed to switch default input to virtual device.")
        }
    }
    
    /// Restore default system input to previous input device
    @MainActor
    func restoreDefaultInputDeviceIfNeeded() {
        guard let previousID = previousDefaultInputDeviceID else { return }
        self.previousDefaultInputDeviceID = nil
        
        if setDefaultInputDeviceID(previousID) {
            NSLog("AudioController: Restored default input back to previous device ID \(previousID).")
        } else {
            NSLog("AudioController: Failed to restore default input back to previous device.")
        }
    }
    
    // MARK: - Delegates
    
    // AudioStreamManagerDelegate: Network received audio packets
    func audioStreamManager(_ manager: AudioStreamManager, didReceiveMicSamples samples: [Float]) {
        micRingBuffer.write(samples)
    }
    
    private var sysPacketCount = 0
    func audioStreamManager(_ manager: AudioStreamManager, didReceiveSysSamples samples: [Float]) {
        sysRingBuffer.write(samples)
        
        sysPacketCount &+= 1
        if sysPacketCount % 1000 == 0 {
            var minVal: Float = 0.0
            var maxVal: Float = 0.0
            for s in samples {
                if s < minVal { minVal = s }
                if s > maxVal { maxVal = s }
            }
            debugLog("[\(Unmanaged.passUnretained(self).toOpaque())] AudioController: Received sys samples (size: \(samples.count)). Signal min: \(minVal), max: \(maxVal)", module: .network)
        }
    }
    
    // ScreenCaptureKitAudioEngineDelegate: Captured system audio from remote host B
    func screenCaptureAudioEngine(_ engine: ScreenCaptureKitAudioEngine, didCaptureAudioSamples samples: [Float]) {
        var minVal: Float = 0.0
        var maxVal: Float = 0.0
        for s in samples {
            if s < minVal { minVal = s }
            if s > maxVal { maxVal = s }
        }
        debugLog("AudioController: Captured local sys samples (size: \(samples.count)). Signal min: \(minVal), max: \(maxVal)", module: .network)
        
        // Send system audio over network to A
        streamManager.sendAudio(samples: samples, isSystemAudio: true)
    }
    
    // ScreenCaptureKitAudioEngineDelegate: Stream stopped by system or error
    func screenCaptureAudioEngineDidStop(_ engine: ScreenCaptureKitAudioEngine, withError error: Error?) {
        NSLog("AudioController: ScreenCaptureKit audio engine stopped externally: \(String(describing: error))")
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.restoreDefaultOutputDeviceMuteIfNeeded()
            
            guard let hostId = self.peerHostId, let host = HostDevicesManager.shared.host(withIdentifier: hostId) else {
                return
            }
            
            if host.shareOutput {
                host.shareOutput = false
                HostDevicesManager.shared.saveHosts()
                HostDevicesManager.shared.notifyChanges()
                
                if let conn = DeviceConnectionManager.shared.connection(for: host) {
                    let msg = Message.create(with: .audioOutputRouteUpdate, andInfoDict: ["enabled": false])
                    _ = conn.sendMessage(msg)
                    
                    if !host.shareInput {
                        let stopMsg = Message.create(with: .audioSyncStopNotification, andInfoDict: [:])
                        _ = conn.sendMessage(stopMsg)
                        self.stopAudioSync()
                    }
                } else {
                    if !host.shareInput {
                        self.stopAudioSync()
                    }
                }
                
                BezelController.default().setMode(.notification(
                    title: NSLocalizedString("Audio Sharing Stopped", comment: ""),
                    subtitle: NSLocalizedString("Audio sharing has been stopped by the system.", comment: ""),
                    icon: .logo,
                    duration: 3.0
                ))
            }
        }
    }
    
    private func micMicAvailableReadCheck(_ logThrottled: Bool) -> Bool {
        return self.micRingBuffer.availableRead >= 4800 // 100ms mono pre-buffer
    }
    
    private func resample(from input: [Float], inputCount: Int, to output: UnsafeMutablePointer<Float>, outputCount: Int) {
        guard inputCount > 0 && outputCount > 0 else { return }
        if inputCount == outputCount {
            for i in 0..<outputCount {
                output[i] = input[i]
            }
            return
        }
        
        let scale = Float(inputCount - 1) / Float(outputCount - 1)
        for i in 0..<outputCount {
            let inputIndex = Float(i) * scale
            let indexFloor = Int(floor(inputIndex))
            let indexCeil = min(indexFloor + 1, inputCount - 1)
            let t = inputIndex - Float(indexFloor)
            
            output[i] = input[indexFloor] * (1.0 - t) + input[indexCeil] * t
        }
    }
}
