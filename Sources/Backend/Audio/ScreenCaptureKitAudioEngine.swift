// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics

protocol ScreenCaptureKitAudioEngineDelegate: AnyObject {
    func screenCaptureAudioEngine(_ engine: ScreenCaptureKitAudioEngine, didCaptureAudioSamples samples: [Float])
    func screenCaptureAudioEngineDidStop(_ engine: ScreenCaptureKitAudioEngine, withError error: Error?)
}

final class ScreenCaptureKitAudioEngine: NSObject, SCStreamDelegate, SCStreamOutput {
    
    private let queue = DispatchQueue(label: "com.unimacs.screencapturekit", qos: .userInteractive)
    private var stream: SCStream?
    
    weak var delegate: ScreenCaptureKitAudioEngineDelegate?
    private(set) var isRunning = false
    private var capturedBufferCount = 0
    private var loggedFormat = false
    
    override init() {
        super.init()
    }
    
    /// Start capturing system audio
    func start() {
        guard !isRunning else { return }
        
        if #available(macOS 14.0, *) {
            if !CGPreflightScreenCaptureAccess() {
                NSLog("ScreenCaptureKitAudioEngine: Screen Capture permission is denied or missing.")
                DispatchQueue.main.async {
                    CGRequestScreenCaptureAccess()
                    BezelController.default().setMode(.notification(
                        title: NSLocalizedString("Audio Sharing Failed", comment: ""),
                        subtitle: NSLocalizedString("Please enable Screen & System Audio Recording permission in System Settings.", comment: ""),
                        icon: .warning,
                        duration: 5.0
                    ))
                }
                return
            }
        }
        
        // Sync-lock state to prevent double execution during async content fetch
        isRunning = true
        
        SCShareableContent.getWithCompletionHandler { [weak self] content, error in
            guard let self = self else { return }
            if let error = error {
                NSLog("ScreenCaptureKitAudioEngine: Failed to get shareable content: \(error)")
                DispatchQueue.main.async {
                    self.isRunning = false
                    if #available(macOS 14.0, *) {
                        CGRequestScreenCaptureAccess()
                    }
                    BezelController.default().setMode(.notification(
                        title: NSLocalizedString("Audio Sharing Failed", comment: ""),
                        subtitle: NSLocalizedString("Please reset Screen Recording permission for Unimacs in System Settings.", comment: ""),
                        icon: .warning,
                        duration: 5.0
                    ))
                }
                return
            }
            
            guard let content = content, let display = content.displays.first else {
                NSLog("ScreenCaptureKitAudioEngine: No display found to capture")
                DispatchQueue.main.async {
                    self.isRunning = false
                    if #available(macOS 14.0, *) {
                        CGRequestScreenCaptureAccess()
                    }
                    BezelController.default().setMode(.notification(
                        title: NSLocalizedString("Audio Sharing Failed", comment: ""),
                        subtitle: NSLocalizedString("No display found. Please check Screen Recording permission in System Settings.", comment: ""),
                        icon: .warning,
                        duration: 5.0
                    ))
                }
                return
            }
            
            // Create content filter. We capture the main display and exclude nothing (or exclude our own app)
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true // Essential to prevent feed loops
            
            // Minimize video capture overhead (no video frame processing is attached)
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
            
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                
                stream.startCapture { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        NSLog("ScreenCaptureKitAudioEngine: Start stream failed: \(error)")
                        self.isRunning = false
                        self.stream = nil
                        return
                    }
                    NSLog("ScreenCaptureKitAudioEngine: System audio stream started successfully")
                }
                self.stream = stream
            } catch {
                NSLog("ScreenCaptureKitAudioEngine: Failed to setup SCStream: \(error)")
                self.isRunning = false
                self.stream = nil
            }
        }
    }
    
    /// Stop capturing system audio
    func stop() {
        guard isRunning else { return }
        
        isRunning = false
        
        let streamToStop = stream
        stream = nil
        
        streamToStop?.stopCapture { error in
            if let error = error {
                NSLog("ScreenCaptureKitAudioEngine: Stop stream failed: \(error)")
            }
            NSLog("ScreenCaptureKitAudioEngine: System audio stream stopped")
        }
    }
    
    // MARK: - SCStreamOutput Delegate
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isRunning else { return }
        guard type == .audio else { return }
        
        capturedBufferCount += 1
        if capturedBufferCount == 1 || capturedBufferCount % 500 == 0 {
            debugLog("ScreenCaptureKitAudioEngine: Captured \(capturedBufferCount) audio buffers", module: .network)
        }
        
        // Extract ASBD (AudioStreamBasicDescription)
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return
        }
        
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            NSLog("ScreenCaptureKitAudioEngine: Non-PCM audio captured, formatID: \(asbd.mFormatID)")
            return
        }
        
        // Retrieve AudioBufferList
        var bufferListSizeNeeded = 0
        let statusCheck = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        
        guard statusCheck == noErr else { return }
        
        let bufferListBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListBuffer.deallocate() }
        
        let bufferListPtr = bufferListBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPtr,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr else { return }
        
        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPtr)
        guard !buffers.isEmpty else { return }
        
        // Log format on the first buffer
        if !loggedFormat {
            loggedFormat = true
            let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            debugLog("ScreenCaptureKitAudioEngine: Captured ASBD: sampleRate=\(asbd.mSampleRate), channels=\(asbd.mChannelsPerFrame), bits=\(asbd.mBitsPerChannel), formatFlags=\(asbd.mFormatFlags), isNonInterleaved=\(isNonInterleaved), buffersCount=\(buffers.count), byteSize=\(Int(buffers[0].mDataByteSize))", module: .network)
        }
        
        // Extract float samples
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = asbd.mBitsPerChannel
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = Int(asbd.mChannelsPerFrame)
        
        var samples = [Float]()
        
        let firstBuffer = buffers[0]
        guard let mData = firstBuffer.mData else { return }
        let byteSize = Int(firstBuffer.mDataByteSize)
        
        if channels == 1 {
            // Mono stream: read directly from buffer 0
            if isFloat {
                if bitsPerChannel == 32 {
                    let sampleCount = byteSize / MemoryLayout<Float>.size
                    samples = [Float](repeating: 0.0, count: sampleCount)
                    let floatPtr = mData.assumingMemoryBound(to: Float.self)
                    for i in 0..<sampleCount {
                        samples[i] = floatPtr[i]
                    }
                } else if bitsPerChannel == 64 {
                    let sampleCount = byteSize / MemoryLayout<Double>.size
                    samples = [Float](repeating: 0.0, count: sampleCount)
                    let doublePtr = mData.assumingMemoryBound(to: Double.self)
                    for i in 0..<sampleCount {
                        samples[i] = Float(doublePtr[i])
                    }
                }
            } else {
                if bitsPerChannel == 16 {
                    let sampleCount = byteSize / MemoryLayout<Int16>.size
                    samples = [Float](repeating: 0.0, count: sampleCount)
                    let intPtr = mData.assumingMemoryBound(to: Int16.self)
                    for i in 0..<sampleCount {
                        samples[i] = Float(intPtr[i]) / 32767.0
                    }
                }
            }
        } else if isNonInterleaved {
            // Non-interleaved Stereo/Multi-channel: interleave Left (buffer 0) and Right (buffer 1)
            if isFloat {
                if bitsPerChannel == 32 {
                    let sampleCount = byteSize / MemoryLayout<Float>.size
                    samples = [Float](repeating: 0.0, count: sampleCount * 2)
                    guard buffers.count >= 2,
                          let leftData = buffers[0].mData,
                          let rightData = buffers[1].mData else { return }
                    
                    let leftPtr = leftData.assumingMemoryBound(to: Float.self)
                    let rightPtr = rightData.assumingMemoryBound(to: Float.self)
                    
                    for i in 0..<sampleCount {
                        samples[2 * i] = leftPtr[i]
                        samples[2 * i + 1] = rightPtr[i]
                    }
                } else if bitsPerChannel == 64 {
                    let sampleCount = byteSize / MemoryLayout<Double>.size
                    samples = [Float](repeating: 0.0, count: sampleCount * 2)
                    guard buffers.count >= 2,
                          let leftData = buffers[0].mData,
                          let rightData = buffers[1].mData else { return }
                    
                    let leftPtr = leftData.assumingMemoryBound(to: Double.self)
                    let rightPtr = rightData.assumingMemoryBound(to: Double.self)
                    
                    for i in 0..<sampleCount {
                        samples[2 * i] = Float(leftPtr[i])
                        samples[2 * i + 1] = Float(rightPtr[i])
                    }
                }
            } else {
                if bitsPerChannel == 16 {
                    let sampleCount = byteSize / MemoryLayout<Int16>.size
                    samples = [Float](repeating: 0.0, count: sampleCount * 2)
                    guard buffers.count >= 2,
                          let leftData = buffers[0].mData,
                          let rightData = buffers[1].mData else { return }
                    
                    let leftPtr = leftData.assumingMemoryBound(to: Int16.self)
                    let rightPtr = rightData.assumingMemoryBound(to: Int16.self)
                    
                    for i in 0..<sampleCount {
                        samples[2 * i] = Float(leftPtr[i]) / 32767.0
                        samples[2 * i + 1] = Float(rightPtr[i]) / 32767.0
                    }
                }
            }
        } else {
            // Already interleaved: copy entire buffer 0 directly
            if isFloat {
                if bitsPerChannel == 32 {
                    let totalSamples = byteSize / MemoryLayout<Float>.size
                    samples = [Float](repeating: 0.0, count: totalSamples)
                    let floatPtr = mData.assumingMemoryBound(to: Float.self)
                    for i in 0..<totalSamples {
                        samples[i] = floatPtr[i]
                    }
                } else if bitsPerChannel == 64 {
                    let totalSamples = byteSize / MemoryLayout<Double>.size
                    samples = [Float](repeating: 0.0, count: totalSamples)
                    let doublePtr = mData.assumingMemoryBound(to: Double.self)
                    for i in 0..<totalSamples {
                        samples[i] = Float(doublePtr[i])
                    }
                }
            } else {
                if bitsPerChannel == 16 {
                    let totalSamples = byteSize / MemoryLayout<Int16>.size
                    samples = [Float](repeating: 0.0, count: totalSamples)
                    let intPtr = mData.assumingMemoryBound(to: Int16.self)
                    for i in 0..<totalSamples {
                        samples[i] = Float(intPtr[i]) / 32767.0
                    }
                }
            }
        }
        
        if !samples.isEmpty {
            delegate?.screenCaptureAudioEngine(self, didCaptureAudioSamples: samples)
        }
    }
    
    // MARK: - SCStreamDelegate
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("ScreenCaptureKitAudioEngine: Stream stopped with error: \(error)")
        let wasRunning = isRunning
        isRunning = false
        if wasRunning {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.screenCaptureAudioEngineDidStop(self, withError: error)
            }
        }
    }
}
