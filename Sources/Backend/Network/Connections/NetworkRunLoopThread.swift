// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only
//
//  A dedicated, process-lifetime thread that runs a CFRunLoop to host all
//  message-connection sockets.
//  The ObjC `TPTCPSocket` binds its CFRunLoop source to `CFRunLoopGetCurrent()`
//  at connect/listen/accept time, so the run loop a socket lives on is decided by
//  whichever thread performs those calls. Historically that ended up being the
//  main run loop, which meant socket callbacks (data/connect/accept/close) and the
//  message pump competed with UI, hot borders and pasteboard writes on the main
//  thread — large clipboard transfers could stall the control connection's I/O.
//  This thread gives every message connection a stable home off the main run loop.
//  We only use the existing (proven) ObjC socket API (`_setRunLoop:` via
//  connect/listen running on this thread); the socket implementation is untouched.

import Foundation

/// Owns a single long-lived CFRunLoop used to host all message-connection sockets.
final class NetworkRunLoopThread {
    static let shared = NetworkRunLoopThread()

    private let thread: Thread
    private let runLoop: CFRunLoop

    private init() {
        let ready = DispatchSemaphore(value: 0)
        var capturedRunLoop: CFRunLoop?

        let t = Thread {
            capturedRunLoop = CFRunLoopGetCurrent()
            // A keep-alive port prevents CFRunLoopRun from returning when no socket
            // sources are currently attached.
            let keepAlive = NSMachPort()
            RunLoop.current.add(keepAlive, forMode: .common)
            ready.signal()
            while true {
                CFRunLoopRunInMode(.defaultMode, 1.0e9, false)
            }
        }
        t.name = "com.teleport.network.runloop"
        t.qualityOfService = .userInitiated
        t.stackSize = 1024 * 1024
        t.start()

        ready.wait()

        self.thread = t
        self.runLoop = capturedRunLoop!
    }

    /// Whether the caller is already executing on the network thread.
    private var isCurrent: Bool {
        Thread.current == thread
    }

    /// Schedule a block to run on the network thread (fire-and-forget).
    func async(_ block: @escaping () -> Void) {
        if isCurrent {
            block()
            return
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Run a block on the network thread and wait for its result.
    /// Safe to call from the network thread itself (runs inline to avoid deadlock).
    ///
    /// The closure is `@escaping` *on purpose*: it is handed to
    /// `CFRunLoopPerformBlock`, which can keep the performed block retained for a
    /// short moment after it calls `sem.signal()` — i.e. past the point where our
    /// `sem.wait()` returns. Wrapping a non-escaping closure with
    /// `withoutActuallyEscaping` here tripped the runtime escape check
    /// ("closure argument was escaped in withoutActuallyEscaping block") and
    /// crashed. The `sem.wait()` still guarantees the block has fully executed
    /// before we read `result`, so the semantics are unchanged.
    @discardableResult
    func sync<T>(_ block: @escaping () -> T) -> T {
        if isCurrent {
            return block()
        }
        var result: T?
        let sem = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            result = block()
            sem.signal()
        }
        CFRunLoopWakeUp(runLoop)
        sem.wait()
        return result!
    }
}
