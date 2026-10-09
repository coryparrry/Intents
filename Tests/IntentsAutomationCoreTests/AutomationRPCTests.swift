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
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    func wait() async { if finished { return }; await withCheckedContinuation { continuation = $0 } }
    func finish() { finished = true; continuation?.resume(); continuation = nil }
}
