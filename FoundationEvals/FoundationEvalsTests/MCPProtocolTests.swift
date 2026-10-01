import Foundation
import Testing
@testable import FoundationEvals

struct MCPProtocolTests {
    @Test func initializeNegotiatesCodexStandardVersion() async throws {
        let response = await makeHandler().handle(try initializeRequest())
        let result = try #require(responseJSON(response)["result"])

        #expect(response.status == 200)
        #expect(result["protocolVersion"] == .string("2025-06-18"))
        #expect(result["serverInfo"]?["name"] == .string("foundation-evals"))

        let instructions = try #require(result["instructions"]?.stringValue)
        let referencedTools = Set(instructions.split {
            !$0.isLetter && !$0.isNumber && $0 != "_"
        }.filter { $0.hasPrefix("eval_") }.map(String.init))
        #expect(!referencedTools.isEmpty)
        #expect(referencedTools.isSubset(of: Set(MCPToolCatalog.definitions.map(\.name))))
    }

    @Test func initializeReturnsSupportedVersionWhenClientRequestsAnotherVersion() async throws {
        let response = await makeHandler().handle(try initializeRequest(protocolVersion: "2099-01-01"))
        let result = try #require(responseJSON(response)["result"])

        #expect(response.status == 200)
        #expect(result["protocolVersion"] == .string("2025-06-18"))
    }

    @Test func pingUsesStandardProtocol() async throws {
        let response = await makeHandler().handle(try standardRequest(method: "ping"))

        #expect(response.status == 200)
        #expect(try responseJSON(response)["result"] == .object([:]))
    }

    @Test func malformedJSONAndInvalidEnvelopeUseDistinctJSONRPCErrors() async throws {
        let handler = makeHandler()
        let malformed = await handler.handle(MCPHTTPRequest(
            method: "POST",
            headers: baseHeaders,
            body: Data(#"{"jsonrpc":"2.0""#.utf8)
        ))
        let invalidEnvelope = await handler.handle(MCPHTTPRequest(
            method: "POST",
            headers: baseHeaders,
            body: Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)
        ))

        #expect(malformed.status == 400)
        #expect(try responseJSON(malformed)["error"]?["code"] == .integer(-32_700))
        #expect(invalidEnvelope.status == 400)
        #expect(try responseJSON(invalidEnvelope)["error"]?["code"] == .integer(-32_600))
    }

    @Test func jsonValuePreservesUnsignedIntegersBeyondInt64() throws {
        let original = MCPJSONValue.unsigned(UInt64.max)
        let encoded = try JSONEncoder.sorted.encode(original)
        let decoded = try JSONDecoder().decode(MCPJSONValue.self, from: encoded)

        #expect(decoded == original)
        #expect(String(decoding: encoded, as: UTF8.self) == "18446744073709551615")
    }

    @Test func suiteParserPreservesFullSeedAndEnforcesDomainControlBounds() throws {
        var configuration = MCPModelConfiguration(
            samplingMode: .probability,
            temperatureEnabled: true,
            temperature: 1,
            seedEnabled: true,
            seed: UInt64.max,
            topK: 1_000,
            probabilityThreshold: 0.01,
            maximumResponseTokens: 4_096,
            maximumInputTokens: 32_768,
            referenceMode: .inline,
            contextPolicy: .fitReferences,
            maximumToolCalls: 4
        )
        func arguments() throws -> MCPJSONValue {
            try MCPJSONValue.encode(MCPReplaceSuiteArguments(
                expectedRevision: "revision",
                confirmDeletes: false,
                suite: MCPSuiteDeclaration(
                    name: "",
                    version: "",
                    instructions: "",
                    scoringMode: .review,
                    repetitions: 1,
                    rubricRequirements: ["Useful"],
                    modelConfiguration: configuration,
                    cases: [MCPCaseDeclaration(id: UUID(), name: "", prompt: "Evaluate this.", expected: "")]
                )
            ))
        }

        let parsed = try MCPToolCatalog.parse(name: "eval_replace_suite", arguments: arguments())
        guard case .replaceSuite(let replacement) = parsed else {
            Issue.record("Expected a typed suite replacement.")
            return
        }
        #expect(replacement.suite.modelConfiguration.seed == UInt64.max)

        var root = try #require(arguments().objectValue)
        var suite = try #require(root["suite"]?.objectValue)
        suite["undeclared"] = .bool(true)
        root["suite"] = .object(suite)
        #expect(throws: MCPToolInputError.self) {
            try MCPToolCatalog.parse(name: "eval_replace_suite", arguments: .object(root))
        }

        configuration.temperature = 1.01
        #expect(throws: MCPToolInputError.self) {
            try MCPToolCatalog.parse(name: "eval_replace_suite", arguments: arguments())
        }
    }

    @Test func closedToolArgumentsRejectUndeclaredTopLevelProperties() throws {
        let arguments = MCPJSONValue.object([
            "runID": .string(UUID().uuidString),
            "unexpected": .bool(true)
        ])

        #expect(throws: MCPToolInputError.self) {
            try MCPToolCatalog.parse(name: "eval_cancel_run", arguments: arguments)
        }
    }

    @Test func securityAndTransportBoundsRejectBeforeDispatch() async throws {
        let recorder = MCPCallRecorder()
        let authority = MCPAuthority(
            call: { call in
                await recorder.record(call)
                return MCPToolPayload(structuredContent: .object(["outcome": .string("committed")]))
            },
            readResource: { _ in .failure(uri: "", code: "missing", message: "Missing") }
        )
        let handler = MCPProtocolHandler(
            authority: authority,
            maximumBodyBytes: 32
        )

        let methodResponse = await handler.handle(MCPHTTPRequest(method: "GET"))
        var hostRequest = try initializeRequest()
        hostRequest.headers["host"] = "example.com"
        let hostResponse = await handler.handle(hostRequest)
        var originRequest = try initializeRequest()
        originRequest.headers["origin"] = "https://example.com"
        let originResponse = await handler.handle(originRequest)
        var oversizedRequest = try initializeRequest()
        oversizedRequest.body = Data(repeating: 0x41, count: 33)
        let oversizedResponse = await handler.handle(oversizedRequest)

        #expect(methodResponse.status == 405)
        #expect(methodResponse.headers["Allow"] == "POST")
        #expect(hostResponse.status == 403)
        #expect(originResponse.status == 403)
        #expect(oversizedResponse.status == 413)
        #expect(await recorder.count == 0)
    }

    @Test func contentTypeRequiresJSONMediaTypeAndAllowsParameters() async throws {
        let handler = makeHandler()
        var invalid = try initializeRequest()
        invalid.headers["content-type"] = "application/jsonx"
        var parameterized = try initializeRequest()
        parameterized.headers["content-type"] = "application/json; charset=utf-8"

        let invalidResponse = await handler.handle(invalid)
        let parameterizedResponse = await handler.handle(parameterized)

        #expect(invalidResponse.status == 415)
        #expect(parameterizedResponse.status == 200)
    }

    @Test func admissionLimitRejectsExcessConcurrentRequests() async throws {
        let gate = MCPRequestGate()
        let authority = MCPAuthority(
            call: { _ in
                await gate.hold()
                return MCPToolPayload(structuredContent: .object(["outcome": .string("committed")]))
            },
            readResource: { _ in .failure(uri: "", code: "missing", message: "Missing") }
        )
        let handler = MCPProtocolHandler(
            authority: authority,
            maximumConcurrentRequests: 1
        )
        let request = try standardRequest(
            method: "tools/call",
            parameters: ["name": .string("eval_get_state"), "arguments": .object([:])]
        )

        let admitted = Task { await handler.handle(request) }
        await gate.waitUntilHeld()
        let rejected = await handler.handle(request)
        await gate.release()
        let completed = await admitted.value

        #expect(rejected.status == 503)
        #expect(rejected.headers["Retry-After"] == "1")
        #expect(completed.status == 200)
    }

    @Test func toolCatalogIsDeterministicTypedAndComplete() async throws {
        let handler = makeHandler()
        let first = await handler.handle(try standardRequest(method: "tools/list"))
        let second = await handler.handle(try standardRequest(method: "tools/list"))
        let tools = try #require(responseJSON(first)["result"]?["tools"]?.arrayValue)

        #expect(first.body == second.body)
        #expect(tools.count == 10)
        #expect(tools.compactMap { $0["name"]?.stringValue } == [
            "eval_get_state",
            "eval_replace_suite",
            "eval_upload_attachment",
            "eval_remove_attachment",
            "eval_start_run",
            "eval_get_run",
            "eval_list_runs",
            "eval_analyze_run",
            "eval_cancel_run",
            "eval_delete_run"
        ])
        #expect(tools.allSatisfy {
            $0["inputSchema"]?["$schema"] == .string("https://json-schema.org/draft/2020-12/schema")
        })
    }

    @Test func toolCallsAreTypedAndReturnStructuredAndTextContent() async throws {
        let recorder = MCPCallRecorder()
        let authority = MCPAuthority(
            call: { call in
                await recorder.record(call)
                return MCPToolPayload(structuredContent: .object([
                    "outcome": .string("committed"), "revision": .string("r2")
                ]))
            },
            readResource: { _ in .failure(uri: "", code: "missing", message: "Missing") }
        )
        let handler = MCPProtocolHandler(authority: authority)
        let response = await handler.handle(
            try standardRequest(
                method: "tools/call",
                parameters: ["name": .string("eval_get_state"), "arguments": .object([:])]
            )
        )
        let result = try #require(responseJSON(response)["result"])

        #expect(response.status == 200)
        #expect(result["structuredContent"]?["outcome"] == .string("committed"))
        #expect(result["content"]?.arrayValue?.first?["type"] == .string("text"))
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("committed") == true)
        #expect(await recorder.count == 1)
    }

    @Test func destructiveToolsRequireExplicitConfirmation() async throws {
        let recorder = MCPCallRecorder()
        let authority = MCPAuthority(
            call: { call in
                await recorder.record(call)
                return MCPToolPayload(structuredContent: .object([:]))
            },
            readResource: { _ in .failure(uri: "", code: "missing", message: "Missing") }
        )
        let handler = MCPProtocolHandler(authority: authority)
        let response = await handler.handle(
            try standardRequest(
                method: "tools/call",
                parameters: [
                    "name": .string("eval_delete_run"),
                    "arguments": .object([
                        "runID": .string(UUID().uuidString),
                        "confirm": .bool(false)
                    ])
                ]
            )
        )

        #expect(response.status == 200)
        #expect(try responseJSON(response)["error"]?["code"] == .integer(-32_602))
        #expect(await recorder.count == 0)
    }

    @Test func resourceReadAcceptsOpaqueUUID() async throws {
        let id = UUID()
        let uri = "foundation-evals://runs/\(id.uuidString)"
        let authority = MCPAuthority(
            call: { _ in .failure(code: "unexpected", message: "Unexpected") },
            readResource: { request in
                #expect(request == .run(id))
                return .text(uri: uri, mimeType: "application/json", text: #"{"id":"run"}"#)
            }
        )
        let handler = MCPProtocolHandler(authority: authority)
        let response = await handler.handle(
            try standardRequest(
                method: "resources/read",
                parameters: ["uri": .string(uri)]
            )
        )

        #expect(response.status == 200)
        #expect(try responseJSON(response)["result"]?["contents"]?.arrayValue?.first?["uri"] == .string(uri))
    }

    @Test func unsupportedProtocolAdvertisesImplementedVersion() async throws {
        var request = try standardRequest(method: "tools/list")
        request.headers["mcp-protocol-version"] = "2099-01-01"
        let response = await makeHandler().handle(request)
        let error = try #require(responseJSON(response)["error"])

        #expect(response.status == 400)
        #expect(error["code"] == .integer(-32_022))
        #expect(error["data"]?["supported"] == .array([.string("2025-06-18")]))
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil,
        "Requires loopback client access that the production app deliberately does not request."
    ))
    func hummingbirdServerBindsLoopbackAndSurfacesPortConflicts() async throws {
        let port = 27_873
        let gate = MCPRequestGate()
        let authority = MCPAuthority(
            call: { _ in
                await gate.hold()
                return MCPToolPayload(structuredContent: .object(["outcome": .string("committed")]))
            },
            readResource: { _ in .failure(uri: "", code: "missing", message: "Missing") }
        )
        let server = MCPServer(
            port: port,
            authority: authority,
            maximumConcurrentRequests: 1
        )
        try await server.start()

        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.httpBody = try rpcBody(
                id: 1,
                method: "initialize",
                params: [
                    "protocolVersion": .string("2025-06-18"),
                    "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("test"), "version": .string("1")])
                ]
            )
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = try #require((response as? HTTPURLResponse)?.statusCode)
            guard status == 200 else {
                Issue.record("Expected HTTP 200, got \(status) with \(data.count) response bytes.")
                await server.stop()
                return
            }
            let json = try JSONDecoder().decode(MCPJSONValue.self, from: data)
            #expect(json["result"]?["protocolVersion"] == .string("2025-06-18"))

            var invalidMediaType = request
            invalidMediaType.setValue("application/jsonx", forHTTPHeaderField: "Content-Type")
            let (_, invalidMediaTypeResponse) = try await URLSession.shared.data(for: invalidMediaType)
            #expect((invalidMediaTypeResponse as? HTTPURLResponse)?.statusCode == 415)

            func toolCallRequest(id: Int) throws -> URLRequest {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
                request.httpMethod = "POST"
                request.httpBody = try rpcBody(
                    id: id,
                    method: "tools/call",
                    params: [
                        "name": .string("eval_get_state"),
                        "arguments": .object([:])
                    ]
                )
                request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                return request
            }

            let admitted = Task { try await URLSession.shared.data(for: toolCallRequest(id: 3)) }
            await gate.waitUntilHeld()
            do {
                let (_, rejectedResponse) = try await URLSession.shared.data(for: toolCallRequest(id: 4))
                #expect((rejectedResponse as? HTTPURLResponse)?.statusCode == 503)
                await gate.release()
                let (_, completedResponse) = try await admitted.value
                #expect((completedResponse as? HTTPURLResponse)?.statusCode == 200)
            } catch {
                await gate.release()
                _ = try? await admitted.value
                throw error
            }

            let duplicate = MCPServer(port: port, authority: authority)
            do {
                try await duplicate.start()
                await duplicate.stop()
                Issue.record("Expected the occupied fixed port to fail.")
            } catch let error as MCPServerError {
                guard case .startFailed = error else {
                    Issue.record("Expected a port-conflict startup error, got \(error).")
                    await server.stop()
                    return
                }
            }
            await server.stop()

            let rebound = MCPServer(port: port, authority: authority)
            try await rebound.start()
            await rebound.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    private func makeHandler() -> MCPProtocolHandler {
        MCPProtocolHandler(
            authority: MCPAuthority(
                call: { _ in MCPToolPayload(structuredContent: .object(["outcome": .string("committed")])) },
                readResource: { _ in .failure(uri: "", code: "missing", message: "Missing") }
            )
        )
    }

    private func standardRequest(
        method: String,
        parameters: [String: MCPJSONValue] = [:]
    ) throws -> MCPHTTPRequest {
        var headers = baseHeaders
        headers["MCP-Protocol-Version"] = "2025-06-18"
        return MCPHTTPRequest(
            method: "POST",
            headers: headers,
            body: try rpcBody(id: 1, method: method, params: parameters)
        )
    }

    private func initializeRequest(protocolVersion: String = "2025-06-18") throws -> MCPHTTPRequest {
        MCPHTTPRequest(
            method: "POST",
            headers: baseHeaders,
            body: try rpcBody(
                id: 1,
                method: "initialize",
                params: [
                    "protocolVersion": .string(protocolVersion),
                    "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("test"), "version": .string("1")])
                ]
            )
        )
    }

    private var baseHeaders: [String: String] {
        [
            "Host": "127.0.0.1:17873",
            "Content-Type": "application/json"
        ]
    }

    private func rpcBody(id: Int, method: String, params: [String: MCPJSONValue]) throws -> Data {
        try JSONEncoder.sorted.encode(MCPJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(Int64(id)),
            "method": .string(method),
            "params": .object(params)
        ]))
    }

    private func responseJSON(_ response: MCPHTTPResponse) throws -> MCPJSONValue {
        try JSONDecoder().decode(MCPJSONValue.self, from: #require(response.body))
    }
}

private actor MCPCallRecorder {
    private(set) var count = 0

    func record(_ call: MCPToolCall) {
        count += 1
    }
}

private actor MCPRequestGate {
    private var isHeld = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        isHeld = true
        let waiters = heldWaiters
        heldWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilHeld() async {
        if isHeld { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private extension MCPJSONValue {
    subscript(_ key: String) -> MCPJSONValue? { objectValue?[key] }

    var arrayValue: [MCPJSONValue]? {
        guard case .array(let values) = self else { return nil }
        return values
    }
}
