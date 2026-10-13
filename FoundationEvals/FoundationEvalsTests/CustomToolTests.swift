import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

struct CustomToolTests {
    @Test func fixtureToolUsesDynamicArgumentsAndRecordsEvidence() async throws {
        let recorder = EvaluationCustomToolRecorder(maximumCalls: 2)
        let definition = EvaluationCustomToolDefinition(
            name: "weather_lookup",
            description: "Looks up fixture weather for a city.",
            parameters: [
                EvaluationSchemaField(
                    name: "city",
                    description: "The city to look up.",
                    type: .string
                )
            ],
            fixtureResponse: "Clear, 18 C"
        )
        let tool = try EvaluationCustomTool(
            definition: definition,
            recorder: recorder,
            httpClient: FailingHTTPClient(),
            tokenCounter: FixedTokenCounter(count: 8)
        )

        let output = try await tool.call(
            arguments: GeneratedContent(properties: ["city": "London"])
        )
        let traces = await recorder.snapshot()

        #expect(output == "Clear, 18 C")
        #expect(traces.count == 1)
        #expect(traces[0].toolName == "weather_lookup")
        #expect(traces[0].argumentsJSON.contains("London"))
        #expect(traces[0].output == "Clear, 18 C")
        #expect(traces[0].outcome == .succeeded)
        #expect(await recorder.evidenceText().contains("Clear, 18 C"))
    }

    @Test func recorderEnforcesOneLimitAcrossDifferentTools() async throws {
        let recorder = EvaluationCustomToolRecorder(maximumCalls: 1)
        let first = try EvaluationCustomTool(
            definition: fixture(name: "first_tool"),
            recorder: recorder,
            httpClient: FailingHTTPClient(),
            tokenCounter: FixedTokenCounter(count: 1)
        )
        let second = try EvaluationCustomTool(
            definition: fixture(name: "second_tool"),
            recorder: recorder,
            httpClient: FailingHTTPClient(),
            tokenCounter: FixedTokenCounter(count: 1)
        )
        let arguments = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))

        _ = try await first.call(arguments: arguments)
        do {
            _ = try await second.call(arguments: arguments)
            Issue.record("Expected the shared recorder to reject the second tool call.")
        } catch let error as EvaluationCustomToolError {
            guard case .callLimitReached(maximum: 1) = error else {
                Issue.record("Unexpected tool error: \(error)")
                return
            }
        }

        let traces = await recorder.snapshot()
        #expect(traces.map(\.toolName) == ["first_tool", "second_tool"])
        #expect(traces.map(\.outcome) == [.succeeded, .rejected])
    }

    @Test func invalidDefinitionsExplainIdentifierIDAndEndpointFailures() {
        let duplicateFieldID = UUID()
        let duplicateToolID = UUID()
        let fields = [
            EvaluationSchemaField(id: duplicateFieldID, name: "one"),
            EvaluationSchemaField(id: duplicateFieldID, name: "two")
        ]
        let tools = [
            EvaluationCustomToolDefinition(
                id: duplicateToolID,
                name: "one_tool",
                description: "First tool.",
                parameters: fields
            ),
            EvaluationCustomToolDefinition(
                id: duplicateToolID,
                name: "two_tool",
                description: "Second tool."
            )
        ]
        let unsafeEndpoint = EvaluationCustomToolDefinition(
            name: "network_tool",
            description: "Attempts to leave loopback.",
            mode: .localHTTP,
            endpoint: "https://example.com:443/run?token=secret"
        )

        #expect(tools[0].validationIssue?.contains("field IDs must be unique") == true)
        #expect(EvaluationFeatureConfiguration(tools: tools).validationIssue != nil)
        #expect(unsafeEndpoint.validationIssue?.contains("http://127.0.0.1") == true)
        #expect(
            EvaluationCustomToolDefinition(
                name: "mcp_tool",
                description: "Targets the MCP listener.",
                mode: .localHTTP,
                endpoint: "http://127.0.0.1:17873"
            ).validationIssue?.contains("reserved") == true
        )
        #expect(EvaluationSchemaField(name: "not valid").validationIssue != nil)

        let oversizedInactiveEndpoint = EvaluationCustomToolDefinition(
            name: "fixture_tool",
            description: "Uses a fixture while retaining endpoint draft text.",
            mode: .fixture,
            fixtureResponse: "ok",
            endpoint: String(repeating: "x", count: 513)
        )
        let oversizedInactiveFixture = EvaluationCustomToolDefinition(
            name: "http_tool",
            description: "Uses HTTP while retaining fixture draft text.",
            mode: .localHTTP,
            fixtureResponse: String(repeating: "x", count: 4_097),
            endpoint: "http://127.0.0.1:19090/run"
        )
        #expect(oversizedInactiveEndpoint.validationIssue?.contains("512") == true)
        #expect(oversizedInactiveFixture.validationIssue?.contains("4096") == true)
    }

    @Test func requestEnvelopeIsAJSONObjectAndHonorsPayloadBound() throws {
        let body = try EvaluationCustomTool.requestBody(
            toolName: "lookup",
            argumentsJSON: #"{"count":2,"term":"swift"}"#
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let arguments = try #require(object["arguments"] as? [String: Any])

        #expect(object["toolName"] as? String == "lookup")
        #expect(arguments["term"] as? String == "swift")
        #expect(arguments["count"] as? Int == 2)

        do {
            _ = try EvaluationCustomTool.requestBody(
                toolName: "lookup",
                argumentsJSON: #"{"value":"\#(String(repeating: "x", count: 17_000))"}"#
            )
            Issue.record("Expected an oversized request to be rejected.")
        } catch {
            #expect(error.localizedDescription.contains("exceeded"))
        }
    }

    @Test func cancellationIsRecordedAndPropagated() async throws {
        let recorder = EvaluationCustomToolRecorder(maximumCalls: 1)
        let tool = try EvaluationCustomTool(
            definition: EvaluationCustomToolDefinition(
                name: "slow_tool",
                description: "Waits until cancelled.",
                mode: .localHTTP,
                endpoint: "http://127.0.0.1:19091/run"
            ),
            recorder: recorder,
            httpClient: SuspendingHTTPClient(),
            tokenCounter: FixedTokenCounter(count: 1)
        )
        let task = Task {
            try await tool.call(
                arguments: GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
            )
        }

        while await recorder.snapshot().isEmpty {
            await Task.yield()
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation to propagate from the endpoint client.")
        } catch is CancellationError {
            // Expected.
        }

        #expect(await recorder.snapshot().first?.outcome == .cancelled)
    }

    @Test func endpointFailuresAreRecorded() async throws {
        let recorder = EvaluationCustomToolRecorder(maximumCalls: 1)
        let tool = try EvaluationCustomTool(
            definition: EvaluationCustomToolDefinition(
                name: "failing_tool",
                description: "Returns a bridge failure.",
                mode: .localHTTP,
                endpoint: "http://127.0.0.1:19092/run"
            ),
            recorder: recorder,
            httpClient: FailingHTTPClient(),
            tokenCounter: FixedTokenCounter(count: 1)
        )

        do {
            _ = try await tool.call(
                arguments: GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
            )
            Issue.record("Expected the endpoint error to propagate.")
        } catch {
            #expect(error.localizedDescription == "Bridge unavailable")
        }

        let trace = try #require(await recorder.snapshot().first)
        #expect(trace.outcome == .failed)
        #expect(trace.errorDescription == "Bridge unavailable")
    }

    @Test func releasingHTTPClientReleasesItsSession() async throws {
        weak var retainedSession: URLSession?
        autoreleasepool {
            let session = URLSession(
                configuration: .ephemeral,
                delegate: EvaluationNoRedirectDelegate(),
                delegateQueue: nil
            )
            let client = EvaluationLocalHTTPToolClient(session: session)
            withExtendedLifetime(client) {
                retainedSession = session
            }
        }
        defer { retainedSession?.invalidateAndCancel() }
        for _ in 0..<100 where retainedSession != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(retainedSession == nil)
    }

    @Test func outputOverContextReserveIsRejectedAndRecorded() async throws {
        let recorder = EvaluationCustomToolRecorder(maximumCalls: 1)
        let tool = try EvaluationCustomTool(
            definition: fixture(name: "verbose_tool"),
            recorder: recorder,
            httpClient: FailingHTTPClient(),
            tokenCounter: ArgumentOutputTokenCounter(
                argumentCount: 1,
                outputCount: EvaluationCustomTool.maximumOutputTokens + 1
            )
        )

        do {
            _ = try await tool.call(
                arguments: GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
            )
            Issue.record("Expected the output token reserve to be enforced.")
        } catch {
            #expect(error.localizedDescription.contains("512-token output limit"))
        }

        let trace = try #require(await recorder.snapshot().first)
        #expect(trace.outcome == .rejected)
        #expect(trace.output == "ok")
    }

    @Test func argumentsOverContextLimitNeverInvokeHTTP() async throws {
        let recorder = EvaluationCustomToolRecorder(maximumCalls: 1)
        let httpClient = RecordingHTTPClient()
        let tool = try EvaluationCustomTool(
            definition: EvaluationCustomToolDefinition(
                name: "guarded_tool",
                description: "Must reject oversized arguments before HTTP.",
                parameters: [EvaluationSchemaField(name: "query")],
                mode: .localHTTP,
                endpoint: "http://127.0.0.1:19095/run"
            ),
            recorder: recorder,
            httpClient: httpClient,
            tokenCounter: ArgumentOutputTokenCounter(
                argumentCount: EvaluationCustomTool.maximumArgumentTokens + 1,
                outputCount: 1
            )
        )

        do {
            _ = try await tool.call(
                arguments: GeneratedContent(properties: ["query": "bounded bytes, excessive tokens"])
            )
            Issue.record("Expected the argument token limit to reject the call.")
        } catch {
            #expect(error.localizedDescription.contains("256-token argument limit"))
        }

        #expect(await httpClient.callCount == 0)
        let trace = try #require(await recorder.snapshot().first)
        #expect(trace.outcome == .rejected)
        #expect(trace.output == nil)
        #expect(trace.errorDescription?.contains("256-token argument limit") == true)
    }

    private func fixture(name: String) -> EvaluationCustomToolDefinition {
        EvaluationCustomToolDefinition(
            name: name,
            description: "A deterministic fixture.",
            fixtureResponse: "ok"
        )
    }
}

private struct SuspendingHTTPClient: EvaluationCustomToolHTTPClient {
    func post(body: Data, to endpoint: URL) async throws -> String {
        try await Task.sleep(for: .seconds(30))
        return "unexpected"
    }
}

private struct FailingHTTPClient: EvaluationCustomToolHTTPClient {
    func post(body: Data, to endpoint: URL) async throws -> String {
        throw StubError.bridgeUnavailable
    }
}

private struct FixedTokenCounter: EvaluationCustomToolTokenCounting {
    var count: Int

    func tokenCount(for text: String) async throws -> Int {
        count
    }
}

private struct ArgumentOutputTokenCounter: EvaluationCustomToolTokenCounting {
    var argumentCount: Int
    var outputCount: Int

    func tokenCount(for text: String) async throws -> Int {
        text.first == "{" ? argumentCount : outputCount
    }
}

private actor RecordingHTTPClient: EvaluationCustomToolHTTPClient {
    private(set) var callCount = 0

    func post(body: Data, to endpoint: URL) async throws -> String {
        callCount += 1
        return "unexpected"
    }
}

private enum StubError: LocalizedError {
    case bridgeUnavailable

    var errorDescription: String? { "Bridge unavailable" }
}
