import Foundation
import Testing
@testable import FoundationEvals

struct MCPTransportRegressionTests {
    @Test func resourceFailuresUseResourceAndInternalErrorCodes() async throws {
        let runID = UUID()
        let uri = "foundation-evals://runs/\(runID.uuidString)"

        let missing = await handler(resource: .failure(uri: uri, code: "not_found", message: "Run was not found."))
            .handle(try resourceRequest(uri: uri))
        #expect(missing.status == 200)
        #expect(try responseJSON(missing)["error"]?["code"] == .integer(-32_002))
        #expect(try responseJSON(missing)["error"]?["data"]?["uri"] == .string(uri))

        let persistenceFailure = await handler(
            resource: .failure(uri: uri, code: "persistence_failed", message: "Could not read the run.")
        ).handle(try resourceRequest(uri: uri))
        #expect(persistenceFailure.status == 200)
        #expect(try responseJSON(persistenceFailure)["error"]?["code"] == .integer(-32_603))
    }

    @Test func invalidAuthorityResourcePayloadIsAnInternalError() async throws {
        let runID = UUID()
        let uri = "foundation-evals://runs/\(runID.uuidString)"
        let invalidPayload = MCPResourcePayload(
            uri: "foundation-evals://runs/\(UUID().uuidString)",
            mimeType: "application/json",
            text: "{}",
            blob: nil,
            isError: false
        )

        let response = await handler(resource: invalidPayload).handle(try resourceRequest(uri: uri))

        #expect(response.status == 200)
        #expect(try responseJSON(response)["error"]?["code"] == .integer(-32_603))
    }

    @MainActor
    @Test func unexpectedServerStopClearsRuntimeAndAllowsExplicitReconnect() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MCPTransportRegressionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = EvaluationStore(supportDirectory: directory)
        let factory = TestServerFactory()
        let runtime = FoundationEvalsMCPRuntime(
            store: store,
            serverFactory: { configuration in factory.make(configuration) }
        )
        let defaults = UserDefaults(suiteName: "MCPTransportRegressionTests-\(UUID().uuidString)")!
        let controller = MCPSettingsController(serverControl: MCPServerControl(
            start: { configuration in try await runtime.start(configuration) },
            stop: { await runtime.stop() }
        ), userDefaults: defaults)
        runtime.settingsController = controller

        await controller.startServer()
        #expect(controller.serverState == .running)
        #expect(factory.creationCount == 1)
        let firstServer = try #require(factory.latest)

        await firstServer.failUnexpectedly()
        #expect(controller.serverState == .failed)
        #expect(controller.notice?.contains("stopped unexpectedly") == true)
        #expect(factory.creationCount == 1)

        await controller.startServer()
        #expect(controller.serverState == .running)
        #expect(factory.creationCount == 2)

        await firstServer.failUnexpectedly()
        #expect(controller.serverState == .running)
    }

    @MainActor
    @Test func stopDuringSuspendedStartupStopsListenerAndAllowsRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MCPTransportRegressionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let factory = TestServerFactory(suspendFirstStart: true)
        let runtime = FoundationEvalsMCPRuntime(
            store: EvaluationStore(supportDirectory: directory),
            serverFactory: { configuration in factory.make(configuration) }
        )
        let configuration = try CodexMCPConfiguration()
        let starting = Task { try await runtime.start(configuration) }
        let firstServer = await factory.waitForLatest()
        await firstServer.waitUntilStartSuspends()

        await runtime.stop()

        do {
            try await starting.value
            Issue.record("Expected the interrupted startup to fail.")
        } catch let error as MCPServerError {
            guard case .stoppedAfterReady = error else {
                Issue.record("Expected stoppedAfterReady, got \(error).")
                return
            }
        }
        #expect(await firstServer.stopCount == 1)

        try await runtime.start(configuration)
        #expect(factory.creationCount == 2)
        await runtime.stop()
    }

    private func handler(resource: MCPResourcePayload) -> MCPProtocolHandler {
        MCPProtocolHandler(authority: MCPAuthority(
            call: { _ in .failure(code: "unexpected", message: "Unexpected") },
            readResource: { _ in resource }
        ))
    }

    private func resourceRequest(uri: String) throws -> MCPHTTPRequest {
        MCPHTTPRequest(
            method: "POST",
            headers: [
                "Host": "127.0.0.1:17873",
                "Content-Type": "application/json",
                "MCP-Protocol-Version": "2025-06-18"
            ],
            body: try JSONEncoder.sorted.encode(MCPJSONValue.object([
                "jsonrpc": .string("2.0"),
                "id": .integer(1),
                "method": .string("resources/read"),
                "params": .object(["uri": .string(uri)])
            ]))
        )
    }

    private func responseJSON(_ response: MCPHTTPResponse) throws -> MCPJSONValue {
        try JSONDecoder().decode(MCPJSONValue.self, from: #require(response.body))
    }
}

@MainActor
private final class TestServerFactory {
    private let suspendFirstStart: Bool
    private(set) var creationCount = 0
    private(set) var latest: TestMCPServer?
    private var latestWaiters: [CheckedContinuation<TestMCPServer, Never>] = []

    init(suspendFirstStart: Bool = false) {
        self.suspendFirstStart = suspendFirstStart
    }

    func make(_ configuration: MCPRuntimeServerConfiguration) -> TestMCPServer {
        creationCount += 1
        let server = TestMCPServer(
            configuration: configuration,
            suspendsStart: suspendFirstStart && creationCount == 1
        )
        latest = server
        let waiters = latestWaiters
        latestWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: server) }
        return server
    }

    func waitForLatest() async -> TestMCPServer {
        if let latest { return latest }
        return await withCheckedContinuation { latestWaiters.append($0) }
    }
}

private actor TestMCPServer: MCPServerLifecycle {
    let configuration: MCPRuntimeServerConfiguration
    let suspendsStart: Bool
    private(set) var stopCount = 0
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: MCPRuntimeServerConfiguration, suspendsStart: Bool) {
        self.configuration = configuration
        self.suspendsStart = suspendsStart
    }

    func start() async throws {
        guard suspendsStart else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func stop() async {
        stopCount += 1
        startContinuation?.resume()
        startContinuation = nil
    }

    func waitUntilStartSuspends() async {
        if startContinuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func failUnexpectedly() async {
        await configuration.onUnexpectedStop(.stoppedAfterReady("test failure"))
    }
}

private extension MCPJSONValue {
    subscript(_ key: String) -> MCPJSONValue? { objectValue?[key] }
}
