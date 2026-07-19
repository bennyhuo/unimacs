// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import Network
import AVFoundation

/// Delegate to receive decoded PCM samples from the network stream
protocol AudioStreamManagerDelegate: AnyObject {
    func audioStreamManager(_ manager: AudioStreamManager, didReceiveMicSamples samples: [Float])
    func audioStreamManager(_ manager: AudioStreamManager, didReceiveSysSamples samples: [Float])
}

final class AudioStreamManager {
    
    enum PacketType: UInt8 {
        case micFloatPCM = 1
        case micInt16PCM = 2
        case sysFloatPCM = 3
        case sysInt16PCM = 4
    }
    
    private let queue = DispatchQueue(label: "com.unimacs.audiostream", qos: .userInteractive)
    private var sysListener: NWListener?
    private var micListener: NWListener?
    private var sysSenderConnection: NWConnection?
    private var micSenderConnection: NWConnection?
    private var sequenceNumber: UInt32 = 0
    private var sentPacketCount = 0
    private var receivedPacketCount = 0
    
    weak var delegate: AudioStreamManagerDelegate?
    private(set) var sysLocalPort: UInt16 = 0
    private(set) var micLocalPort: UInt16 = 0
    
    var localPort: UInt16 { sysLocalPort }
    
    // Config settings
    var useCompression: Bool = false // If true, converts Float to Int16 before sending
    
    init() {}
    
    /// Start listening for incoming system audio packets (Client role)
    func startSysListener(completion: @escaping (UInt16) -> Void) throws {
        stopSysListener()
        
        let params = NWParameters.udp
        let listener = try NWListener(using: params, on: .any)
        
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    NSLog("AudioStreamManager: SysListener ready on port \(port)")
                    self?.sysLocalPort = port
                    completion(port)
                } else {
                    NSLog("AudioStreamManager: SysListener ready but port is nil")
                    completion(0)
                }
            case .failed(let error):
                NSLog("AudioStreamManager: SysListener failed with error: \(error)")
            default:
                break
            }
        }
        
        listener.newConnectionHandler = { [weak self] connection in
            self?.setupInboundConnection(connection)
        }
        
        listener.start(queue: queue)
        self.sysListener = listener
    }
    
    func stopSysListener() {
        sysListener?.cancel()
        sysListener = nil
        sysLocalPort = 0
    }
    
    /// Start listening for incoming mic audio packets (Server role)
    func startMicListener(completion: @escaping (UInt16) -> Void) throws {
        stopMicListener()
        
        let params = NWParameters.udp
        let listener = try NWListener(using: params, on: .any)
        
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    NSLog("AudioStreamManager: MicListener ready on port \(port)")
                    self?.micLocalPort = port
                    completion(port)
                } else {
                    NSLog("AudioStreamManager: MicListener ready but port is nil")
                    completion(0)
                }
            case .failed(let error):
                NSLog("AudioStreamManager: MicListener failed with error: \(error)")
            default:
                break
            }
        }
        
        listener.newConnectionHandler = { [weak self] connection in
            self?.setupInboundConnection(connection)
        }
        
        listener.start(queue: queue)
        self.micListener = listener
    }
    
    func stopMicListener() {
        micListener?.cancel()
        micListener = nil
        micLocalPort = 0
    }
    
    /// Connect to peer's UDP port for sending system audio (Host/Server role)
    func startSysSender(toHost host: String, port: UInt16) {
        stopSysSender()
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .udp)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("AudioStreamManager: Outbound UDP sysSender ready to \(host):\(port)")
            case .failed(let error):
                NSLog("AudioStreamManager: Outbound UDP sysSender failed: \(error)")
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        self.sysSenderConnection = connection
    }
    
    func stopSysSender() {
        sysSenderConnection?.cancel()
        sysSenderConnection = nil
    }
    
    /// Connect to peer's UDP port for sending mic audio (Client role)
    func startMicSender(toHost host: String, port: UInt16) {
        stopMicSender()
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .udp)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("AudioStreamManager: Outbound UDP micSender ready to \(host):\(port)")
            case .failed(let error):
                NSLog("AudioStreamManager: Outbound UDP micSender failed: \(error)")
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        self.micSenderConnection = connection
    }
    
    func stopMicSender() {
        micSenderConnection?.cancel()
        micSenderConnection = nil
    }
    
    func stopSender() {
        stopSysSender()
        stopMicSender()
        sequenceNumber = 0
    }
    
    /// Send audio samples (PCM Floats) to the peer
    func sendAudio(samples: [Float], isSystemAudio: Bool) {
        guard let connection = isSystemAudio ? sysSenderConnection : micSenderConnection else { return }
        
        // MTU-safe chunk size: 320 samples * 4 bytes (Float) = 1280 bytes + 7 bytes header = 1287 bytes
        let maxChunkSize = 320
        var offset = 0
        while offset < samples.count {
            let chunkLength = min(maxChunkSize, samples.count - offset)
            let chunk = Array(samples[offset..<(offset + chunkLength)])
            
            sendAudioChunk(chunk, over: connection, isSystemAudio: isSystemAudio)
            
            offset += chunkLength
        }
    }
    
    private func sendAudioChunk(_ chunk: [Float], over connection: NWConnection, isSystemAudio: Bool) {
        sentPacketCount += 1
        if sentPacketCount == 1 || sentPacketCount % 1000 == 0 {
            debugLog("AudioStreamManager: Sent \(sentPacketCount) chunks (isSystem: \(isSystemAudio), size: \(chunk.count) samples)", module: .network)
        }
        
        var packetData = Data()
        
        // 1. Header: Magic "TA" (2 bytes), Type (1 byte), Sequence (4 bytes)
        packetData.append(contentsOf: [0x54, 0x41]) // "TA"
        
        let type: PacketType
        if isSystemAudio {
            type = useCompression ? .sysInt16PCM : .sysFloatPCM
        } else {
            type = useCompression ? .micInt16PCM : .micFloatPCM
        }
        packetData.append(type.rawValue)
        
        var seq = sequenceNumber.bigEndian
        withUnsafeBytes(of: &seq) { packetData.append(contentsOf: $0) }
        sequenceNumber &+= 1
        
        // 2. Payload
        if useCompression {
            // Convert Float to Int16 (-32768 to 32767)
            var intSamples = [Int16](repeating: 0, count: chunk.count)
            for i in 0..<chunk.count {
                let s = max(-1.0, min(1.0, chunk[i]))
                intSamples[i] = Int16(s * 32767.0)
            }
            intSamples.withUnsafeBytes { ptr in
                packetData.append(ptr.bindMemory(to: UInt8.self).baseAddress!, count: ptr.count)
            }
        } else {
            chunk.withUnsafeBytes { ptr in
                packetData.append(ptr.bindMemory(to: UInt8.self).baseAddress!, count: ptr.count)
            }
        }
        
        connection.send(content: packetData, completion: .contentProcessed({ error in
            if let error = error {
                NSLog("AudioStreamManager: Failed to send audio packet: \(error)")
            }
        }))
    }
    
    // MARK: - Inbound Connection Processing
    
    private func setupInboundConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("AudioStreamManager: Inbound connection failed: \(error)")
            }
        }
        connection.start(queue: queue)
        receiveNextPacket(on: connection)
    }
    
    private func receiveNextPacket(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if let content = content, !content.isEmpty {
                self.processInboundPacket(content)
            }
            if error == nil {
                self.receiveNextPacket(on: connection)
            }
        }
    }
    
    private func processInboundPacket(_ data: Data) {
        guard data.count >= 7 else { return }
        
        // Check magic
        guard data[0] == 0x54 && data[1] == 0x41 else { return }
        
        // Parse type
        guard let type = PacketType(rawValue: data[2]) else { return }
        
        receivedPacketCount += 1
        if receivedPacketCount == 1 || receivedPacketCount % 500 == 0 {
            debugLog("AudioStreamManager: Received \(receivedPacketCount) packets (type: \(type.rawValue), size: \(data.count) bytes)", module: .network)
        }
        
        // Parse sequence
        var seq: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &seq) { ptr in
            data.copyBytes(to: ptr, from: 3..<7)
        }
        seq = UInt32(bigEndian: seq)
        
        let payload = data.subdata(in: 7..<data.count)
        var samples = [Float]()
        
        switch type {
        case .micFloatPCM, .sysFloatPCM:
            let floatCount = payload.count / MemoryLayout<Float>.size
            samples = [Float](repeating: 0, count: floatCount)
            _ = samples.withUnsafeMutableBytes { ptr in
                payload.copyBytes(to: ptr)
            }
            
        case .micInt16PCM, .sysInt16PCM:
            let intCount = payload.count / MemoryLayout<Int16>.size
            var intSamples = [Int16](repeating: 0, count: intCount)
            _ = intSamples.withUnsafeMutableBytes { ptr in
                payload.copyBytes(to: ptr)
            }
            // Decompress: Convert Int16 to Float
            samples = intSamples.map { Float($0) / 32767.0 }
        }
        
        if !samples.isEmpty {
            let isSys = (type == .sysFloatPCM || type == .sysInt16PCM)
            if isSys {
                delegate?.audioStreamManager(self, didReceiveSysSamples: samples)
            } else {
                delegate?.audioStreamManager(self, didReceiveMicSamples: samples)
            }
        }
    }
}
