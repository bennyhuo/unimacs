// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Cocoa
import Foundation
import Network

// MARK: - Lightweight Assertion Helpers

private var totalTestsRun = 0
private var totalAssertions = 0
private var failedTests: [String] = []

private func assertEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: @autoclosure () -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    let a = actual()
    let e = expected()
    if a != e {
        let failure = "[\(file):\(line)] Assertion failed: expected (\(e)), got (\(a)). \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertTrue(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if !condition() {
        let failure = "[\(file):\(line)] Assertion failed: expected true. \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertFalse(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if condition() {
        let failure = "[\(file):\(line)] Assertion failed: expected false. \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertNotNil<T>(
    _ value: @autoclosure () -> T?,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if value() == nil {
        let failure = "[\(file):\(line)] Assertion failed: expected non-nil. \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func runTest(_ name: String, _ block: () -> Void) {
    totalTestsRun += 1
    let failuresBefore = failedTests.count
    block()
    if failedTests.count == failuresBefore {
        print("✅ PASS: \(name)")
    } else {
        print("❌ FAIL: \(name)")
    }
}

private func waitUntil(timeout: TimeInterval = 5.0, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        CFRunLoopRunInMode(.defaultMode, 0.01, true)
    }
    return condition()
}

// MARK: - Test Doubles

private final class ChannelRecorder: MessageChannelDelegate, MessageListenerDelegate {
    let lock = NSLock()
    var acceptedChannels: [MessageChannel] = []
    var didConnectCount = 0
    var didFailCount = 0
    var didDisconnectCount = 0
    var receivedData = Data()

    var autoAttachAcceptedDelegate = true

    func listener(_ listener: MessageListener, didAcceptChannel channel: MessageChannel) {
        lock.lock()
        acceptedChannels.append(channel)
        let attach = autoAttachAcceptedDelegate
        lock.unlock()
        if attach {
            channel.delegate = self
            channel.activateReceiveCallbacks()
        }
    }

    func listenerShouldEnableEncryption(_ listener: MessageListener, forRemoteAddress address: String?) -> Bool {
        false
    }

    func channelDidConnect(_ channel: MessageChannel) {
        lock.lock()
        didConnectCount += 1
        lock.unlock()
    }

    func channelDidFailToConnect(_ channel: MessageChannel) {
        lock.lock()
        didFailCount += 1
        lock.unlock()
    }

    func channelDidDisconnect(_ channel: MessageChannel) {
        lock.lock()
        didDisconnectCount += 1
        lock.unlock()
    }

    func channel(_ channel: MessageChannel, didReceiveData data: Data) {
        lock.lock()
        receivedData.append(data)
        lock.unlock()
    }
}

private final class MockOutgoingTransfer: OutgoingTransfer {
    var payloadToSend: Data?
    var didComplete = false
    var didAbort = false

    override var type: String {
        "MockIncomingTransfer"
    }

    override func dataToTransfer() -> Data? {
        payloadToSend
    }

    override func _senderDataTransferCompleted() {
        didComplete = true
        super._senderDataTransferCompleted()
    }

    override func _senderDataTransferAborted() {
        didAbort = true
        super._senderDataTransferAborted()
    }
}

private final class MockIncomingTransfer: IncomingTransfer {
    var completedData: Data?
    var didComplete = false
    var didAbort = false
    var progressValues: [Float] = []

    override func _transferDidProgress(_ progress: Float) {
        progressValues.append(progress)
    }

    override func _prepareReceivedDataBeforeCompletion() {
        if let buffer = _data {
            completedData = Data(referencing: buffer)
        }
    }

    override func _receiverDataTransferCompleted() {
        didComplete = true
        super._receiverDataTransferCompleted()
    }

    override func _receiverDataTransferAborted() {
        didAbort = true
        super._receiverDataTransferAborted()
    }
}

private final class MockStreamingIncomingTransfer: IncomingTransfer {
    var streamedBytes = Data()
    var didComplete = false
    var didAbort = false

    override var shouldBufferIncomingData: Bool {
        false
    }

    override func _receivedData(_ data: Data) {
        _lock.lock()
        streamedBytes.append(data)
        _receivedDataLength &+= UInt64(data.count)
        let received = _receivedDataLength
        let total = _totalDataLength
        _lock.unlock()
        _reportReceiveProgressIfNeeded(currentReceived: received, total: total)
    }

    override func _receiverDataTransferCompleted() {
        didComplete = true
        super._receiverDataTransferCompleted()
    }

    override func _receiverDataTransferAborted() {
        didAbort = true
        super._receiverDataTransferAborted()
    }
}

// MARK: - Test Suite

@main
struct NWMessageChannelAndTransferTests {
    static func main() {
        print("=== Running NWMessageChannel & Transfer Pure-Swift Unit Tests ===")

        // Ensure listener binds to 0.0.0.0 during local loopback unit tests
        NetworkConfigurationWatcher.shared.selectedLocalIpAddress = NetworkUtils.anyIPv4Address

        runTest("testInvalidHostAndPortFailImmediately") {
            let channel = MessageTransportFactory.makeChannel()
            assertEqual(channel.state, .disconnectedState)
            assertFalse(channel.connect(toHost: "", port: 12345), "Empty host should fail immediately")
            assertNotNil(channel.lastFailureReason)
            assertFalse(channel.connect(toHost: "127.0.0.1", port: 0), "Port 0 on connect should fail immediately")
            assertFalse(channel.send(Data([1, 2, 3])), "Sending while disconnected should return false")
        }

        runTest("testListenerEphemeralPortAndPortCollisionRetry") {
            let listener1 = MessageTransportFactory.makeListener()
            var port1: Int32 = 0
            assertTrue(listener1.start(onPort: &port1, tries: 1), "Ephemeral port bind should succeed")
            assertTrue(port1 > 0, "Assigned ephemeral port should be > 0, got \(port1)")

            // Bind a second listener starting at port1 with tries=10; should land on >= port1
            let listener2 = MessageTransportFactory.makeListener()
            var port2: Int32 = port1
            assertTrue(listener2.start(onPort: &port2, tries: 10), "Second listener should succeed")
            assertTrue(port2 > 0)

            listener1.stop()
            listener2.stop()
        }

        runTest("testBidirectionalChannelDataAndCleanAddresses") {
            let serverRecorder = ChannelRecorder()
            let clientRecorder = ChannelRecorder()

            let listener = MessageTransportFactory.makeListener()
            listener.delegate = serverRecorder
            var port: Int32 = 0
            assertTrue(listener.start(onPort: &port, tries: 1))
            defer { listener.stop() }

            let client = MessageTransportFactory.makeChannel()
            client.delegate = clientRecorder
            client.setNoDelay(true)
            assertTrue(client.connect(toHost: "127.0.0.1", port: port))

            assertTrue(waitUntil {
                clientRecorder.lock.lock()
                let connected = clientRecorder.didConnectCount == 1
                clientRecorder.lock.unlock()
                serverRecorder.lock.lock()
                let accepted = serverRecorder.acceptedChannels.count == 1
                serverRecorder.lock.unlock()
                return connected && accepted
            }, "Client and server should connect")

            assertEqual(client.state, .connectedState)
            assertEqual(client.remoteAddress, "127.0.0.1")
            assertFalse(client.localAddress?.contains("%") ?? true, "localAddress must not contain % interface scope")

            let serverChannel = serverRecorder.acceptedChannels[0]
            assertEqual(serverChannel.state, .connectedState)
            assertEqual(serverChannel.remoteAddress, "127.0.0.1")
            assertFalse(serverChannel.localAddress?.contains("%") ?? true, "server localAddress must not contain % interface scope")

            let payloadC2S = Data((0..<100_000).map { UInt8($0 & 0xFF) })
            assertTrue(client.send(payloadC2S))

            assertTrue(waitUntil {
                serverRecorder.lock.lock()
                defer { serverRecorder.lock.unlock() }
                return serverRecorder.receivedData.count == payloadC2S.count
            }, "Server should receive full 100KB payload")
            assertEqual(serverRecorder.receivedData, payloadC2S)

            let payloadS2C = Data("Hello back from pure Swift NWMessageChannel!".utf8)
            assertTrue(serverChannel.send(payloadS2C))

            assertTrue(waitUntil {
                clientRecorder.lock.lock()
                defer { clientRecorder.lock.unlock() }
                return clientRecorder.receivedData.count == payloadS2C.count
            }, "Client should receive server reply")
            assertEqual(clientRecorder.receivedData, payloadS2C)

            // Explicit close by client should NOT trigger clientRecorder.didDisconnectCount,
            // but MUST trigger serverRecorder.didDisconnectCount via graceful FIN.
            client.close()
            assertEqual(client.state, .disconnectedState)

            assertTrue(waitUntil {
                serverRecorder.lock.lock()
                defer { serverRecorder.lock.unlock() }
                return serverRecorder.didDisconnectCount == 1
            }, "Server should observe clean disconnect when client closes")

            clientRecorder.lock.lock()
            let clientDisconnects = clientRecorder.didDisconnectCount
            clientRecorder.lock.unlock()
            assertEqual(clientDisconnects, 0, "Explicit close() on client should not fire channelDidDisconnect on client")
            serverChannel.close()
        }

        runTest("testPendingInboundBufferedUntilDelegateAttached") {
            let serverRecorder = ChannelRecorder()
            serverRecorder.autoAttachAcceptedDelegate = false
            let clientRecorder = ChannelRecorder()

            let listener = MessageTransportFactory.makeListener()
            listener.delegate = serverRecorder
            var port: Int32 = 0
            assertTrue(listener.start(onPort: &port, tries: 1))
            defer { listener.stop() }

            let client = MessageTransportFactory.makeChannel()
            client.delegate = clientRecorder
            assertTrue(client.connect(toHost: "127.0.0.1", port: port))

            assertTrue(waitUntil {
                serverRecorder.lock.lock()
                defer { serverRecorder.lock.unlock() }
                return serverRecorder.acceptedChannels.count == 1 && client.state == .connectedState
            })

            let earlyPayload = Data("Early handshake bytes before delegate wired".utf8)
            assertTrue(client.send(earlyPayload))

            // Give NWConnection a moment to read into pendingInbound while delegate is still nil
            CFRunLoopRunInMode(.defaultMode, 0.05, true)

            let accepted = serverRecorder.acceptedChannels[0]
            accepted.delegate = serverRecorder

            assertTrue(waitUntil {
                serverRecorder.lock.lock()
                defer { serverRecorder.lock.unlock() }
                return serverRecorder.receivedData == earlyPayload
            }, "Buffered inbound data should flush as soon as delegate is attached")

            client.close()
            accepted.close()
        }

        runTest("testFixedLengthMultiBlockTransferRoundTrip") {
            // 650 KB payload (> 2 * 256 KB BLOCK_SIZE) to exercise multi-chunk sending and receiving
            let expectedPayload = Data((0..<665_600).map { UInt8(($0 * 31) & 0xFF) })

            let incoming = MockIncomingTransfer(uid: "test-fixed-transfer")
            let outgoing = MockOutgoingTransfer()
            outgoing.payloadToSend = expectedPayload
            assertTrue(outgoing.prepareToSendData())
            assertEqual(outgoing.totalDataLength(), UInt64(expectedPayload.count))

            let host = RemoteHost(identifier: "test-host", address: "127.0.0.1", port: 44276)
            var port: Int32 = 0
            assertTrue(incoming.prepareToReceiveData(
                withInfoDict: outgoing.infoDict(),
                from: host,
                onPort: &port,
                delegate: NSObject()
            ))
            assertTrue(port > 0)

            let channel = MessageTransportFactory.makeChannel()
            channel.setNoDelay(false)
            outgoing.setChannel(channel)
            assertTrue(channel.connect(toHost: "127.0.0.1", port: port))

            assertTrue(waitUntil(timeout: 8.0) {
                outgoing.didComplete && incoming.didComplete
            }, "Both outgoing and incoming fixed-size transfers should complete")

            assertFalse(outgoing.didAbort)
            assertFalse(incoming.didAbort)
            assertEqual(incoming.completedData?.count, expectedPayload.count)
            assertEqual(incoming.completedData, expectedPayload)
        }

        runTest("testUnknownLengthStreamingTransferCompletesOnEOF") {
            // Simulates IncomingPasteboardFileTransfer where dataLength == 0 and EOF marks completion
            let streamedPayload = Data((0..<300_000).map { UInt8(($0 * 17) & 0xFF) })

            let incoming = MockStreamingIncomingTransfer(uid: "test-stream-transfer")
            let requestInfo = TransferRequestInfo(
                uid: incoming.uid,
                type: "MockStreamingIncomingTransfer",
                dataLength: 0,
                expectedDataLength: UInt64(streamedPayload.count),
                shouldEncrypt: false
            )

            let host = RemoteHost(identifier: "test-host", address: "127.0.0.1", port: 44276)
            var port: Int32 = 0
            assertTrue(incoming.prepareToReceiveData(
                withInfoDict: requestInfo.infoDict,
                from: host,
                onPort: &port,
                delegate: NSObject()
            ))

            let clientRecorder = ChannelRecorder()
            let senderChannel = MessageTransportFactory.makeChannel()
            senderChannel.delegate = clientRecorder
            assertTrue(senderChannel.connect(toHost: "127.0.0.1", port: port))

            assertTrue(waitUntil {
                senderChannel.state == .connectedState
            })

            // Send in 3 chunks then close to signal EOF
            let chunk1 = streamedPayload.subdata(in: 0..<100_000)
            let chunk2 = streamedPayload.subdata(in: 100_000..<200_000)
            let chunk3 = streamedPayload.subdata(in: 200_000..<300_000)
            assertTrue(senderChannel.send(chunk1))
            assertTrue(senderChannel.send(chunk2))
            assertTrue(senderChannel.send(chunk3))
            senderChannel.close()

            assertTrue(waitUntil(timeout: 5.0) {
                incoming.didComplete
            }, "Streaming incoming transfer should complete on graceful EOF")

            assertFalse(incoming.didAbort)
            assertEqual(incoming.streamedBytes.count, streamedPayload.count)
            assertEqual(incoming.streamedBytes, streamedPayload)
        }

        runTest("testIncompleteFixedLengthTransferAbortsOnPrematureDisconnect") {
            let incoming = MockIncomingTransfer(uid: "test-incomplete-transfer")
            let requestInfo = TransferRequestInfo(
                uid: incoming.uid,
                type: "MockIncomingTransfer",
                dataLength: 100_000,
                expectedDataLength: 100_000,
                shouldEncrypt: false
            )

            let host = RemoteHost(identifier: "test-host", address: "127.0.0.1", port: 44276)
            var port: Int32 = 0
            assertTrue(incoming.prepareToReceiveData(
                withInfoDict: requestInfo.infoDict,
                from: host,
                onPort: &port,
                delegate: NSObject()
            ))

            let clientRecorder = ChannelRecorder()
            let senderChannel = MessageTransportFactory.makeChannel()
            senderChannel.delegate = clientRecorder
            assertTrue(senderChannel.connect(toHost: "127.0.0.1", port: port))

            assertTrue(waitUntil {
                senderChannel.state == .connectedState
            })

            // Send only 10 KB out of 100 KB and close prematurely
            assertTrue(senderChannel.send(Data(repeating: 0xAB, count: 10_000)))
            senderChannel.close()

            assertTrue(waitUntil(timeout: 5.0) {
                incoming.didAbort
            }, "Incoming transfer should abort when peer disconnects before sending full dataLength")
            assertFalse(incoming.didComplete)
        }

        print("=== Test Summary: \(totalTestsRun) tests (\(totalAssertions) assertions), \(failedTests.count) failures ===")
        if !failedTests.isEmpty {
            exit(1)
        }
    }
}
