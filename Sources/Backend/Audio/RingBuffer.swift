// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// A lock-free, single-producer single-consumer (SPSC) ring buffer for Float audio samples.
/// Designed for real-time CoreAudio contexts where the reader thread must never block.
///
/// Thread safety model:
/// - Exactly one thread writes (network/capture thread) — the "producer"
/// - Exactly one thread reads (CoreAudio render thread) — the "consumer"
/// - No locks are used; correctness is ensured via monotonic counters and memory barriers
/// - Buffer capacity is rounded up to the next power of 2 for efficient modular arithmetic
public final class RingBuffer {
    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int  // capacity - 1, for bitwise AND instead of modulo
    
    /// Monotonically increasing byte-position counters.
    /// `writePos` is only incremented by the producer thread.
    /// `readPos` is only incremented by the consumer thread.
    /// On Apple platforms (ARM64/x86-64), aligned Int loads and stores are atomic.
    private var writePos: Int = 0
    private var readPos: Int = 0
    
    /// Initialize the buffer with a minimum capacity.
    /// The actual capacity is rounded up to the next power of 2.
    /// - Parameter capacity: The minimum number of Float samples the buffer can hold.
    public init(capacity requestedCapacity: Int) {
        let cap = Self.nextPowerOf2(requestedCapacity)
        self.capacity = cap
        self.mask = cap - 1
        self.buffer = .allocate(capacity: cap)
        self.buffer.initialize(repeating: 0.0, count: cap)
    }
    
    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }
    
    // MARK: - Status (safe to call from either thread)
    
    /// Number of samples available to read. May conservatively under-report.
    public var availableRead: Int {
        return writePos &- readPos
    }
    
    /// Free space (in samples) available for writing. May conservatively under-report.
    public var availableWrite: Int {
        return capacity &- (writePos &- readPos)
    }
    
    // MARK: - Producer API (call from writer thread only)
    
    /// Write float samples into the ring buffer using batch memcpy.
    /// - Parameter data: Array of float samples to write.
    /// - Returns: The actual number of samples written.
    @discardableResult
    public func write(_ data: [Float]) -> Int {
        let w = writePos
        let r = readPos
        let freeSpace = capacity &- (w &- r)
        let toWrite = min(data.count, freeSpace)
        guard toWrite > 0 else { return 0 }
        
        let writeOffset = w & mask
        let firstSegment = min(toWrite, capacity - writeOffset)
        
        data.withUnsafeBufferPointer { src in
            guard let srcBase = src.baseAddress else { return }
            // First segment: writeOffset to end-of-buffer (or less)
            buffer.advanced(by: writeOffset).update(from: srcBase, count: firstSegment)
            if firstSegment < toWrite {
                // Second segment: wrap around to buffer start
                buffer.update(from: srcBase.advanced(by: firstSegment), count: toWrite - firstSegment)
            }
        }
        
        // Barrier: ensure buffer data is committed before writePos becomes visible to reader
        OSMemoryBarrier()
        writePos = w &+ toWrite
        return toWrite
    }
    
    /// Write from a raw pointer into the ring buffer using batch memcpy.
    @discardableResult
    public func write(from pointer: UnsafePointer<Float>, count: Int) -> Int {
        let w = writePos
        let r = readPos
        let freeSpace = capacity &- (w &- r)
        let toWrite = min(count, freeSpace)
        guard toWrite > 0 else { return 0 }
        
        let writeOffset = w & mask
        let firstSegment = min(toWrite, capacity - writeOffset)
        
        buffer.advanced(by: writeOffset).update(from: pointer, count: firstSegment)
        if firstSegment < toWrite {
            buffer.update(from: pointer.advanced(by: firstSegment), count: toWrite - firstSegment)
        }
        
        OSMemoryBarrier()
        writePos = w &+ toWrite
        return toWrite
    }
    
    // MARK: - Consumer API (call from reader thread only; real-time safe)
    
    /// Read float samples from the ring buffer into a Swift array using batch memcpy.
    /// Safe for real-time audio render threads: no locks, no allocation, no syscalls.
    @discardableResult
    public func read(into data: inout [Float], count: Int) -> Int {
        let r = readPos
        let w = writePos
        // Barrier: ensure we observe buffer data written before the writePos we just loaded
        OSMemoryBarrier()
        
        let available = w &- r
        let toRead = min(count, available)
        guard toRead > 0 else { return 0 }
        
        let readOffset = r & mask
        let firstSegment = min(toRead, capacity - readOffset)
        
        data.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            dstBase.update(from: buffer.advanced(by: readOffset), count: firstSegment)
            if firstSegment < toRead {
                dstBase.advanced(by: firstSegment).update(from: buffer, count: toRead - firstSegment)
            }
        }
        
        // Barrier: ensure buffer reads complete before readPos update becomes visible to writer
        OSMemoryBarrier()
        readPos = r &+ toRead
        return toRead
    }
    
    /// Read float samples from the ring buffer into a raw pointer using batch memcpy.
    /// Safe for real-time audio render threads.
    @discardableResult
    public func read(into pointer: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let r = readPos
        let w = writePos
        OSMemoryBarrier()
        
        let available = w &- r
        let toRead = min(count, available)
        guard toRead > 0 else { return 0 }
        
        let readOffset = r & mask
        let firstSegment = min(toRead, capacity - readOffset)
        
        pointer.update(from: buffer.advanced(by: readOffset), count: firstSegment)
        if firstSegment < toRead {
            pointer.advanced(by: firstSegment).update(from: buffer, count: toRead - firstSegment)
        }
        
        OSMemoryBarrier()
        readPos = r &+ toRead
        return toRead
    }
    
    /// Clear the ring buffer. Must only be called when no concurrent reader/writer is active.
    public func clear() {
        readPos = 0
        writePos = 0
    }
    
    // MARK: - Helpers
    
    private static func nextPowerOf2(_ n: Int) -> Int {
        guard n > 1 else { return 1 }
        var v = n - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v |= v >> 32
        return v + 1
    }
}
