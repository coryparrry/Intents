import XCTest
@testable import IntentsAutomationCore

final class AutomationRPCTests: XCTestCase, @unchecked Sendable {
    func testQualifiedShutdownResponseAfterFormerDeadlineRetainsNegativeProof() async throws {
        let (frames, sender) = AsyncStream<Data>.makeStream()
        let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
        var iterator = frames.makeAsyncIterator()
        let operation = Task { try await AutomationSidecarShutdown.request(rpc) }
        let nextFrame = await iterator.next()
        let outbound = try XCTUnwrap(nextFrame)
        let frame = try JSONDecoder().decode(AutomationJSON.self, from: outbound)
        XCTAssertEqual(frame.object?["method"], .string("shutdown"))
        let id = try XCTUnwrap(frame.object?["id"]?.string)
        // The old 20s deadline would lose this response. No real device is used.
        try await Task.sleep(for: .seconds(21))
        let response: AutomationJSON = .object(["jsonrpc": .string("2.0"), "id": .string(id),
            "result": .object(["resourcesReleased": .bool(false), "cleanupReason": .string("sessionUnreleased")])])
        try await rpc.receive(JSONEncoder().encode(response) + Data([10]))
        let result = try await operation.value
        XCTAssertEqual(result.object?["resourcesReleased"], .bool(false))
        await rpc.close()
    }
    func testReverseCallbackDoesNotBlockOutstandingReply() async throws {
        let (frames, sender) = AsyncStream<Data>.makeStream()
        let gate = RPCGate()
        let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in await gate.wait(); return .object(["allowed": .bool(true)]) })
        var iterator = frames.makeAsyncIterator()
        let operation = Task { try await rpc.request(.runSegment, params: .object([:])) }
        let nextFrame = await iterator.next()
        let outbound = try XCTUnwrap(nextFrame)
        let id = try XCTUnwrap(JSONDecoder().decode(AutomationJSON.self, from: outbound).object?["id"]?.string)
        try await rpc.receive(Data(#"{"jsonrpc":"2.0","id":"node-1","method":"policy.reviewAction","params":{}}"#.utf8) + Data([10]))
        try await rpc.receive(Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":null}\n".utf8))
        let result = try await operation.value
        XCTAssertEqual(result, .null)
        await gate.finish()
        let nextReply = await iterator.next()
        let reverseReply = try XCTUnwrap(nextReply)
        XCTAssertEqual(try JSONDecoder().decode(AutomationJSON.self, from: reverseReply).object?["result"], .object(["allowed": .bool(true)]))
        await rpc.close()
    }
    func testDispatchedTimeoutIsAmbiguousAndLateResponseIsDiscarded() async throws {
        let (frames, sender) = AsyncStream<Data>.makeStream()
        let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
        var iterator = frames.makeAsyncIterator()
        let operation = Task { try await rpc.request(.runSegment, params: .object([:]), timeout: .milliseconds(10)) }
        let nextFrame = await iterator.next()
        let outbound = try XCTUnwrap(nextFrame)
        let id = try XCTUnwrap(JSONDecoder().decode(AutomationJSON.self, from: outbound).object?["id"]?.string)
        do { _ = try await operation.value; XCTFail("Must not infer action termination") }
        catch { XCTAssertEqual(error as? AutomationRPCError, .dispatchedOutcomeUnknown) }
        try await rpc.receive(Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":null}\n".utf8))
        await rpc.close()
    }
    func testMalformedReplyFailsPendingRequestAndSplitUTF8IsAccepted() async throws {
        let (frames, sender) = AsyncStream<Data>.makeStream()
        let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
        var iterator = frames.makeAsyncIterator()
        let operation = Task { try await rpc.request(.hello, params: .object([:])) }
        let nextFrame = await iterator.next()
        let outbound = try XCTUnwrap(nextFrame)
        let id = try XCTUnwrap(JSONDecoder().decode(AutomationJSON.self, from: outbound).object?["id"]?.string)
        let response = Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":\"é\"}\n".utf8)
        let split = try XCTUnwrap(response.firstIndex(of: 0xC3)) + 1
        try await rpc.receive(Data(response[..<split])); try await rpc.receive(Data(response[split...]))
        let result = try await operation.value
        XCTAssertEqual(result, .string("é"))
        do { try await rpc.receive(Data(#"{"jsonrpc":"2.0","id":"host-1","result":null,"error":{"code":1,"message":"bad"}}"#.utf8) + Data([10])); XCTFail("Both reply branches must be rejected") }
        catch { XCTAssertEqual(error as? AutomationRPCError, .invalidFrame) }
    }
    func testClosedEndpointNeverRepliesToLateReverseCallback() async throws {
        let gate = RPCGate()
        let lateReply = expectation(description: "No reply after close"); lateReply.isInverted = true
        let rpc = AutomationRPC(send: { _ in lateReply.fulfill() }, reverse: { _, _ in
            await gate.wait(); return .object(["allowed": .bool(true)])
        })
        try await rpc.receive(Data(#"{"jsonrpc":"2.0","id":"node-1","method":"policy.reviewAction","params":{}}"#.utf8) + Data([10]))
        await rpc.close(); await gate.finish()
        await fulfillment(of: [lateReply], timeout: 0.1)
    }
    #if os(macOS)
    func testRealPackagedSidecarHandshakeThroughNativeProcess() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = ProcessInfo.processInfo.environment["INTENTS_AUTOMATION_TEST_BUNDLE"].map { URL(fileURLWithPath: $0) }
        let node = bundle?.appendingPathComponent("Contents/Helpers/IntentsAutomationNode") ?? root.appendingPathComponent("Tools/IntentsAutomation/.runtime/node-v24.21.0-darwin-arm64/bin/node")
        let entry = bundle?.appendingPathComponent("Contents/Resources/Automation/dist/src/main.js") ?? root.appendingPathComponent("Tools/IntentsAutomation/dist/src/main.js")
        let helper = bundle?.appendingPathComponent("Contents/Helpers/agent-device-macos-helper")
        guard FileManager.default.isExecutableFile(atPath: node.path) else { throw XCTSkip("Pinned build-time runtime not provisioned") }
        let state = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("automation-rpc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let configuration: AutomationSidecarProcess.Configuration
        if let bundle {
            configuration = try AutomationRuntimeBundle.verifiedConfiguration(bundleURL: bundle, stateDirectory: state, expectedTeamID: "3Z3955EFRE")
        } else { configuration = .init(node: node, entry: entry, stateDirectory: state, helper: helper) }
        let owner = try AutomationSidecarProcess(configuration: configuration, reverse: { _, _ in .object(["allowed": .bool(false)]) })
        try await owner.start()
        let hello: AutomationJSON
        do { hello = try await owner.handshake() }
        catch {
            let message = await owner.diagnosticsSummary()
            _ = await owner.stop()
            XCTFail("Actual sidecar handshake failed: \(message)"); throw error
        }
        XCTAssertEqual(hello.object?["mixedHandoffQualified"], .bool(false))
        let response = try await owner.rpc.request(.shutdown, params: .object(["protocolVersion": .number(1)]))
        XCTAssertEqual(response.object?["resourcesReleased"], .bool(true))
        let stopped = await owner.stop()
        XCTAssertTrue(stopped)
    }
    #endif
}

private actor RPCGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var finished = false
    func wait() async { if finished { return }; await withCheckedContinuation { continuations.append($0) } }
    func finish() { finished = true; continuations.forEach { $0.resume() }; continuations.removeAll() }
}

extension AutomationRPCTests {
    func testFrameAtExactByteLimitIsAcceptedAcrossChunks() async throws {
        let (frames, sender) = AsyncStream<Data>.makeStream()
        let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
        var iterator = frames.makeAsyncIterator()
        let operation = Task { try await rpc.request(.hello, params: .object([:])) }
        let id = try await nextRequestID(&iterator, sender)
        let frame = paddedResultFrame(id: id, byteCount: rpcFrameLimit)
        XCTAssertEqual(frame.count, rpcFrameLimit)
        // A buffer holding exactly the limit is still admissible while the terminator is pending.
        try await rpc.receive(frame)
        try await rpc.receive(Data([10]))
        let result = try await operation.value
        XCTAssertEqual(result.string?.utf8.count, rpcFrameLimit - paddedResultOverhead(id: id))
        await rpc.close()
    }

    func testTerminatedLineOverByteLimitClosesEndpointAndFailsPendingRequest() async throws {
        let (frames, sender) = AsyncStream<Data>.makeStream()
        let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
        var iterator = frames.makeAsyncIterator()
        let operation = Task { try await rpc.request(.hello, params: .object([:])) }
        let id = try await nextRequestID(&iterator, sender)
        // Otherwise valid JSON, so only the size bound can reject it.
        let oversized = paddedResultFrame(id: id, byteCount: rpcFrameLimit + 1)
        await assertRPCError(.invalidFrame) { try await rpc.receive(oversized + Data([10])) }
        await assertRPCError(.disconnected) { try await operation.value }
        await assertRPCError(.disconnected) { try await rpc.request(.status, params: .object([:])) }
        // A closed endpoint ignores further bytes rather than resurrecting state.
        try await rpc.receive(rpcLine(#"{"jsonrpc":"2.0","id":"host-1","result":null}"#))
    }

    func testUnterminatedBufferOverByteLimitIsAmbiguousForMutatingRequest() async throws {
        let (frames, sender) = AsyncStream<Data>.makeStream()
        let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
        var iterator = frames.makeAsyncIterator()
        let operation = Task { try await rpc.request(.runSegment, params: .object([:])) }
        let id = try await nextRequestID(&iterator, sender)
        let oversized = paddedResultFrame(id: id, byteCount: rpcFrameLimit + 1)
        try await rpc.receive(Data(oversized.prefix(rpcFrameLimit)))
        await assertRPCError(.invalidFrame) { try await rpc.receive(Data(oversized.suffix(1))) }
        await assertRPCError(.dispatchedOutcomeUnknown) { try await operation.value }
    }

    func testInvalidUTF8LineIsRejected() async throws {
        let (frames, sender) = AsyncStream<Data>.makeStream()
        let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
        var iterator = frames.makeAsyncIterator()
        let operation = Task { try await rpc.request(.hello, params: .object([:])) }
        let id = try await nextRequestID(&iterator, sender)
        let line = Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":\"".utf8) + Data([0xFF, 0xFE]) + Data("\"}\n".utf8)
        await assertRPCError(.invalidFrame) { try await rpc.receive(line) }
        await assertRPCError(.disconnected) { try await operation.value }
    }

    func testDecodeDepthLimitAcceptsThirtyNineNestedArraysAndRejectsForty() async throws {
        let (frames, sender) = AsyncStream<Data>.makeStream()
        let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
        var iterator = frames.makeAsyncIterator()
        let accepted = Task { try await rpc.request(.hello, params: .object([:])) }
        let acceptedID = try await nextRequestID(&iterator, sender)
        // The reply object is depth 0, so the innermost of 39 result arrays sits at coding depth 39.
        try await rpc.receive(rpcLine("{\"jsonrpc\":\"2.0\",\"id\":\"\(acceptedID)\",\"result\":\(nestedArrays(39))}"))
        let result = try await accepted.value
        XCTAssertEqual(result, nestedArrayValue(39))

        let rejected = Task { try await rpc.request(.hello, params: .object([:])) }
        let rejectedID = try await nextRequestID(&iterator, sender)
        do {
            try await rpc.receive(rpcLine("{\"jsonrpc\":\"2.0\",\"id\":\"\(rejectedID)\",\"result\":\(nestedArrays(40))}"))
            XCTFail("Frames nested past the decode depth bound must be rejected")
        } catch {}
        await assertRPCError(.disconnected) { try await rejected.value }
        await assertRPCError(.disconnected) { try await rpc.request(.status, params: .object([:])) }
    }

    func testReverseRequestsOutsideAllowlistOrMalformedAreRejectedWithoutInvokingHost() async throws {
        let frames = [
            #"{"jsonrpc":"2.0","id":"node-1","method":"shell.exec","params":{}}"#,
            #"{"jsonrpc":"2.0","id":"node-1","method":"policy.reviewAction"}"#,
            #"{"jsonrpc":"2.0","id":"node-1","method":"policy.reviewAction","params":{},"extra":true}"#,
            #"{"jsonrpc":"2.0","id":"","method":"policy.reviewAction","params":{}}"#,
            "{\"jsonrpc\":\"2.0\",\"id\":\"\(String(repeating: "n", count: 129))\",\"method\":\"policy.reviewAction\",\"params\":{}}",
            #"{"jsonrpc":"1.0","id":"node-1","method":"policy.reviewAction","params":{}}"#,
        ]
        for frame in frames {
            let calls = RPCCallLog()
            let rpc = AutomationRPC(send: { _ in }, reverse: { method, _ in await calls.record(method); return .null })
            await assertRPCError(.invalidFrame, frame) { try await rpc.receive(rpcLine(frame)) }
            await assertRPCError(.disconnected, frame) { try await rpc.request(.status, params: .object([:])) }
            let recorded = await calls.methods
            XCTAssertEqual(recorded, [], frame)
        }
    }

    func testDuplicateInFlightReverseIDIsRejected() async throws {
        let gate = RPCGate()
        let rpc = AutomationRPC(send: { _ in }, reverse: { _, _ in await gate.wait(); return .null })
        let frame = rpcLine(#"{"jsonrpc":"2.0","id":"node-1","method":"policy.reviewAction","params":{}}"#)
        try await rpc.receive(frame)
        await assertRPCError(.invalidFrame) { try await rpc.receive(frame) }
        await assertRPCError(.disconnected) { try await rpc.request(.status, params: .object([:])) }
        await gate.finish()
    }

    func testSeventeenthConcurrentReverseRequestIsRejected() async throws {
        let gate = RPCGate()
        let rpc = AutomationRPC(send: { _ in }, reverse: { _, _ in await gate.wait(); return .null })
        for index in 1...16 {
            try await rpc.receive(rpcLine("{\"jsonrpc\":\"2.0\",\"id\":\"node-\(index)\",\"method\":\"controller.decide\",\"params\":{}}"))
        }
        await assertRPCError(.invalidFrame) {
            try await rpc.receive(rpcLine(#"{"jsonrpc":"2.0","id":"node-17","method":"controller.decide","params":{}}"#))
        }
        await gate.finish()
    }

    func testThrowingReverseHandlerRepliesWithFixedDenial() async throws {
        let (frames, sender) = AsyncStream<Data>.makeStream()
        let calls = RPCCallLog()
        let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { method, _ in
            await calls.record(method); throw RPCTestFailure()
        })
        var iterator = frames.makeAsyncIterator()
        try await rpc.receive(rpcLine(#"{"jsonrpc":"2.0","id":"node-7","method":"mac.helper.run","params":{"secret":"[REDACTED]"}}"#))
        let reply = try await nextFrame(&iterator, sender)
        XCTAssertEqual(reply.last, 10)
        XCTAssertEqual(try JSONDecoder().decode(AutomationJSON.self, from: reply), .object([
            "jsonrpc": .string("2.0"), "id": .string("node-7"),
            "error": .object(["code": .number(-32000), "message": .string("Host request was denied")]),
        ]))
        let recorded = await calls.methods
        XCTAssertEqual(recorded, ["mac.helper.run"])
        await rpc.close()
    }

    func testSixtyFifthPendingRequestHitsRequestLimitWithoutClosing() async throws {
        let (frames, sender) = AsyncStream<Data>.makeStream()
        let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
        var iterator = frames.makeAsyncIterator()
        var operations: [Task<AutomationJSON, any Error>] = []
        for _ in 0..<64 { operations.append(Task { try await rpc.request(.hello, params: .object([:])) }) }
        var ids: [String] = []
        for _ in 0..<64 { ids.append(try await nextRequestID(&iterator, sender)) }
        XCTAssertEqual(Set(ids), Set((1...64).map { "host-\($0)" }))
        await assertRPCError(.requestLimit) { try await rpc.request(.status, params: .object([:])) }

        try await rpc.receive(rpcLine("{\"jsonrpc\":\"2.0\",\"id\":\"\(ids[0])\",\"result\":null}"))
        let admitted = Task { try await rpc.request(.status, params: .object([:])) }
        let admittedID = try await nextRequestID(&iterator, sender)
        XCTAssertEqual(admittedID, "host-65", "A rejected request must not consume an id")
        try await rpc.receive(rpcLine("{\"jsonrpc\":\"2.0\",\"id\":\"\(admittedID)\",\"result\":true}"))
        let admittedResult = try await admitted.value
        XCTAssertEqual(admittedResult, .bool(true))

        await rpc.close()
        var resolved = 0, disconnected = 0
        for operation in operations {
            do { _ = try await operation.value; resolved += 1 }
            catch { if error as? AutomationRPCError == .disconnected { disconnected += 1 } else { XCTFail("\(error)") } }
        }
        XCTAssertEqual(resolved, 1)
        XCTAssertEqual(disconnected, 63)
    }

    func testOutboundRequestFrameShape() async throws {
        let (frames, sender) = AsyncStream<Data>.makeStream()
        let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
        var iterator = frames.makeAsyncIterator()
        let operation = Task { try await rpc.request(.secretRunProgram, params: .object(["binding": .string("b")])) }
        let outbound = try await nextFrame(&iterator, sender)
        XCTAssertEqual(outbound.last, 10)
        XCTAssertNil(outbound.dropLast().firstIndex(of: 10))
        XCTAssertEqual(try JSONDecoder().decode(AutomationJSON.self, from: outbound), .object([
            "jsonrpc": .string("2.0"), "id": .string("host-1"), "method": .string("secret.runProgram"),
            "params": .object(["binding": .string("b")]),
        ]))
        await rpc.close()
        await assertRPCError(.dispatchedOutcomeUnknown) { try await operation.value }
    }

    func testCancellationAndTimeoutAreAmbiguousOnlyForMutatingMethods() async throws {
        let cases: [(AutomationRPC.Method, AutomationRPCError, AutomationRPCError)] = [
            (.hello, .cancelled, .timedOut), (.inventory, .cancelled, .timedOut), (.probe, .cancelled, .timedOut), (.status, .cancelled, .timedOut),
            (.acquire, .dispatchedOutcomeUnknown, .dispatchedOutcomeUnknown), (.runSegment, .dispatchedOutcomeUnknown, .dispatchedOutcomeUnknown),
            (.secretRunProgram, .dispatchedOutcomeUnknown, .dispatchedOutcomeUnknown), (.release, .dispatchedOutcomeUnknown, .dispatchedOutcomeUnknown),
            (.cancel, .dispatchedOutcomeUnknown, .dispatchedOutcomeUnknown), (.shutdown, .dispatchedOutcomeUnknown, .dispatchedOutcomeUnknown),
        ]
        for (method, onCancel, onTimeout) in cases {
            let (frames, sender) = AsyncStream<Data>.makeStream()
            let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
            var iterator = frames.makeAsyncIterator()
            let cancelled = Task { try await rpc.request(method, params: .object([:])) }
            _ = try await nextRequestID(&iterator, sender)
            cancelled.cancel()
            await assertRPCError(onCancel, method.rawValue) { try await cancelled.value }

            let timed = Task { try await rpc.request(method, params: .object([:]), timeout: .milliseconds(10)) }
            _ = try await nextRequestID(&iterator, sender)
            await assertRPCError(onTimeout, method.rawValue) { try await timed.value }
            await rpc.close()
        }
    }

    func testSendFailureIsAmbiguousOnlyForMutatingMethods() async throws {
        let rpc = AutomationRPC(send: { _ in throw RPCTestFailure() }, reverse: { _, _ in .null })
        await assertRPCError(.disconnected) { try await rpc.request(.hello, params: .object([:])) }
        await assertRPCError(.disconnected) { try await rpc.request(.status, params: .object([:])) }
        await assertRPCError(.dispatchedOutcomeUnknown) { try await rpc.request(.runSegment, params: .object([:])) }
        await assertRPCError(.dispatchedOutcomeUnknown) { try await rpc.request(.release, params: .object([:])) }
        await rpc.close()
        await assertRPCError(.disconnected) { try await rpc.request(.runSegment, params: .object([:])) }
    }

    func testWellFormedRemoteErrorMapsToRemoteAndKeepsEndpointOpen() async throws {
        let (frames, sender) = AsyncStream<Data>.makeStream()
        let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
        var iterator = frames.makeAsyncIterator()
        let refused = Task { try await rpc.request(.runSegment, params: .object([:])) }
        let refusedID = try await nextRequestID(&iterator, sender)
        try await rpc.receive(rpcLine("{\"jsonrpc\":\"2.0\",\"id\":\"\(refusedID)\",\"error\":{\"code\":-32000,\"message\":\"Sidecar refused\"}}"))
        await assertRPCError(.remote(code: -32000, message: "Sidecar refused")) { try await refused.value }

        let message = String(repeating: "m", count: 4096)
        let bounded = Task { try await rpc.request(.hello, params: .object([:])) }
        let boundedID = try await nextRequestID(&iterator, sender)
        try await rpc.receive(rpcLine("{\"jsonrpc\":\"2.0\",\"id\":\"\(boundedID)\",\"error\":{\"code\":\(Int32.min),\"message\":\"\(message)\"}}"))
        await assertRPCError(.remote(code: Int(Int32.min), message: message)) { try await bounded.value }

        let followUp = Task { try await rpc.request(.status, params: .object([:])) }
        let followUpID = try await nextRequestID(&iterator, sender)
        try await rpc.receive(rpcLine("{\"jsonrpc\":\"2.0\",\"id\":\"\(followUpID)\",\"result\":\"ok\"}"))
        let result = try await followUp.value
        XCTAssertEqual(result, .string("ok"))
        await rpc.close()
    }

    func testMalformedRemoteErrorFailsPendingAsInvalidFrameAndCloses() async throws {
        let errors = [
            #"{"code":1.5,"message":"bad"}"#,
            #"{"code":"1","message":"bad"}"#,
            #"{"code":2147483648,"message":"bad"}"#,
            #"{"code":-2147483649,"message":"bad"}"#,
            #"{"code":1}"#,
            #"{"code":1,"message":7}"#,
            "{\"code\":1,\"message\":\"\(String(repeating: "m", count: 4097))\"}",
            #"{"code":1,"message":"bad","data":{}}"#,
            #""bad""#,
        ]
        for error in errors {
            let (frames, sender) = AsyncStream<Data>.makeStream()
            let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
            var iterator = frames.makeAsyncIterator()
            let operation = Task { try await rpc.request(.hello, params: .object([:])) }
            let id = try await nextRequestID(&iterator, sender)
            let label = String(error.prefix(64))
            await assertRPCError(.invalidFrame, label) { try await rpc.receive(rpcLine("{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"error\":\(error)}")) }
            await assertRPCError(.invalidFrame, label) { try await operation.value }
            await assertRPCError(.disconnected, label) { try await rpc.request(.status, params: .object([:])) }
        }
    }

    func testReplyForUnissuedIDIsRejectedAndNeverResolvesPendingRequest() async throws {
        for forged in ["host-2", "host-0", "host--1", "host-x", "node-1"] {
            let (frames, sender) = AsyncStream<Data>.makeStream()
            let rpc = AutomationRPC(send: { sender.yield($0) }, reverse: { _, _ in .null })
            var iterator = frames.makeAsyncIterator()
            let operation = Task { try await rpc.request(.hello, params: .object([:])) }
            let id = try await nextRequestID(&iterator, sender)
            XCTAssertEqual(id, "host-1")
            await assertRPCError(.invalidFrame, forged) { try await rpc.receive(rpcLine("{\"jsonrpc\":\"2.0\",\"id\":\"\(forged)\",\"result\":\"forged\"}")) }
            await assertRPCError(.disconnected, forged) { try await operation.value }
        }
    }
}

private let rpcFrameLimit = 1_048_576

private func rpcLine(_ json: String) -> Data { Data(json.utf8) + Data([10]) }

private func paddedResultOverhead(id: String) -> Int { "{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":\"\"}".utf8.count }

private func paddedResultFrame(id: String, byteCount: Int) -> Data {
    let padding = String(repeating: "a", count: byteCount - paddedResultOverhead(id: id))
    return Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":\"\(padding)\"}".utf8)
}

private func nestedArrays(_ depth: Int) -> String { String(repeating: "[", count: depth) + String(repeating: "]", count: depth) }

private func nestedArrayValue(_ depth: Int) -> AutomationJSON {
    (1..<depth).reduce(AutomationJSON.array([])) { inner, _ in .array([inner]) }
}

/// Bounded read: a frame that is never sent fails the test instead of hanging the suite.
private func nextFrame(_ iterator: inout AsyncStream<Data>.AsyncIterator, _ stream: AsyncStream<Data>.Continuation,
                       file: StaticString = #filePath, line: UInt = #line) async throws -> Data {
    let watchdog = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { stream.finish() } }
    defer { watchdog.cancel() }
    let frame = await iterator.next()
    return try XCTUnwrap(frame, "No outbound frame within 5s", file: file, line: line)
}

private func nextRequestID(_ iterator: inout AsyncStream<Data>.AsyncIterator, _ stream: AsyncStream<Data>.Continuation,
                           file: StaticString = #filePath, line: UInt = #line) async throws -> String {
    let outbound = try await nextFrame(&iterator, stream, file: file, line: line)
    return try XCTUnwrap(JSONDecoder().decode(AutomationJSON.self, from: outbound).object?["id"]?.string, file: file, line: line)
}

private func assertRPCError<T>(_ expected: AutomationRPCError, _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
                               _ body: () async throws -> T) async {
    do { _ = try await body(); XCTFail("Expected \(expected). \(message)", file: file, line: line) }
    catch { XCTAssertEqual(error as? AutomationRPCError, expected, message, file: file, line: line) }
}

private struct RPCTestFailure: Error {}

private actor RPCCallLog {
    private(set) var methods: [String] = []
    func record(_ method: String) { methods.append(method) }
}
