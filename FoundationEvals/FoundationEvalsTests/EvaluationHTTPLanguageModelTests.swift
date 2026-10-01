import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

struct EvaluationHTTPLanguageModelTests {
    @Test func customProviderDefaultsAreLoopbackOnlyAndAdvertiseExplicitCapabilities() throws {
        var configuration = EvaluationCustomProviderConfiguration()
        configuration.supportsGuidedGeneration = true
        configuration.supportsReasoning = true
        configuration.supportsToolCalling = true
        let model = EvaluationHTTPLanguageModel(configuration: configuration)

        #expect(configuration.validationIssue == nil)
        #expect(configuration.validatedEndpoint?.absoluteString == configuration.endpoint)
        #expect(configuration.contextSize == 8_192)
        #expect(!configuration.capabilities.contains(.vision))
        #expect(configuration.capabilities.contains(.guidedGeneration))
        #expect(configuration.capabilities.contains(.reasoning))
        #expect(configuration.capabilities.contains(.toolCalling))
        #expect(model.contextSize == configuration.contextSize)
    }

    @Test func customProviderRejectsNonliteralAndReservedEndpoints() {
        let rejected = [
            "https://127.0.0.1:19096/generate",
            "http://localhost:19096/generate",
            "http://[::1]:19096/generate",
            "http://127.0.0.1/generate",
            "http://user:password@127.0.0.1:19096/generate",
            "http://127.0.0.1:19096/generate?token=secret",
            "http://127.0.0.1:19096/generate#fragment",
            "http://127.0.0.1:17873/generate"
        ]

        for endpoint in rejected {
            var configuration = EvaluationCustomProviderConfiguration()
            configuration.endpoint = endpoint
            #expect(configuration.validationIssue != nil)
            #expect(configuration.validatedEndpoint == nil)
        }
    }

    @Test func requestEnvelopeCarriesTranscriptToolsSchemaOptionsContextAndMetadata() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let tool = Transcript.ToolDefinition(
            name: "lookup",
            description: "Looks up a value.",
            parameters: String.generationSchema
        )
        let metadata: [String: any ConvertibleToGeneratedContent] = [
            "attempt": 3,
            "source": "test"
        ]
        let request = LanguageModelExecutorGenerationRequest(
            id: id,
            transcript: Transcript(),
            enabledTools: [tool],
            schema: String.generationSchema,
            generationOptions: GenerationOptions(
                samplingMode: .random(top: 7, seed: 42),
                temperature: 0.25,
                maximumResponseTokens: 128,
                toolCallingMode: .required
            ),
            contextOptions: ContextOptions(includeSchemaInPrompt: false, reasoningLevel: .custom("fixture")),
            metadata: metadata
        )

        var providerConfiguration = EvaluationCustomProviderConfiguration()
        providerConfiguration.contextSize = 32_768
        providerConfiguration.supportsGuidedGeneration = true
        providerConfiguration.supportsReasoning = true
        let body = try EvaluationHTTPGenerationRequest.makeBody(
            from: request,
            configuration: providerConfiguration
        )
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(object["options"] as? [String: Any])
        let sampling = try #require(options["sampling"] as? [String: Any])
        let context = try #require(object["context"] as? [String: Any])
        let provider = try #require(object["provider"] as? [String: Any])
        let encodedMetadata = try #require(object["metadata"] as? [String: Any])
        let tools = try #require(object["enabledTools"] as? [[String: Any]])

        #expect(object["protocolVersion"] as? Int == 1)
        #expect(object["requestID"] as? String == id.uuidString)
        #expect(object["mode"] as? String == "guided")
        #expect(object["transcript"] != nil)
        #expect(object["schema"] != nil)
        #expect(tools.first?["name"] as? String == "lookup")
        #expect(tools.first?["parameters"] != nil)
        #expect(sampling["kind"] as? String == "randomTopK")
        #expect(sampling["topK"] as? Int == 7)
        #expect(sampling["seed"] as? Int == 42)
        #expect(options["temperature"] as? Double == 0.25)
        #expect(options["maximumResponseTokens"] as? Int == 128)
        #expect(options["toolCallingMode"] as? String == "required")
        #expect(context["includeSchemaInPrompt"] as? Bool == false)
        #expect(context["reasoningLevel"] as? String == "custom:fixture")
        #expect(provider["contextSize"] as? Int == 32_768)
        #expect(provider["capabilities"] as? [String] == ["guidedGeneration", "reasoning"])
        #expect(encodedMetadata["attempt"] as? Int == 3)
        #expect(encodedMetadata["source"] as? String == "test")
    }

    @Test func eventProtocolMapsTextGuidedReasoningToolAndUsageEvents() throws {
        let decoder = JSONDecoder()
        func decode(_ json: String) throws -> EvaluationHTTPGenerationEvent {
            try decoder.decode(EvaluationHTTPGenerationEvent.self, from: Data(json.utf8))
        }

        #expect(
            try decode(#"{"kind":"response","content":"Hello","tokenCount":1}"#)
                .command(expectsGuidedResponse: false)
            == .responseAppend(entryID: nil, segmentID: nil, content: "Hello", tokenCount: 1, guided: false)
        )
        #expect(
            try decode(#"{"kind":"guidedResponse","action":"replace","entryID":"r1","segmentID":"s1","content":"{\"answer\":\"ok\"}","tokenCount":4}"#)
                .command(expectsGuidedResponse: true)
            == .responseReplace(
                entryID: "r1",
                segmentID: "s1",
                content: #"{"answer":"ok"}"#,
                tokenCount: 4,
                guided: true
            )
        )
        #expect(
            try decode(#"{"kind":"reasoning","content":"Check input.","tokenCount":2}"#)
                .command(expectsGuidedResponse: false)
            == .reasoningAppend(entryID: nil, segmentID: nil, content: "Check input.", tokenCount: 2)
        )
        #expect(
            try decode(#"{"kind":"reasoningSignature","entryID":"reasoning-1","signatureBase64":"yv4=","tokenCount":0}"#)
                .command(expectsGuidedResponse: false)
            == .reasoningSignature(entryID: "reasoning-1", signature: Data([0xCA, 0xFE]), tokenCount: 0)
        )
        #expect(
            try decode(#"{"kind":"toolCall","entryID":"calls-1","callID":"call-1","toolName":"lookup","content":"{\"query\":\"swift\"}","tokenCount":3}"#)
                .command(expectsGuidedResponse: false)
            == .toolCallArguments(
                entryID: "calls-1",
                callID: "call-1",
                toolName: "lookup",
                content: #"{"query":"swift"}"#,
                tokenCount: 3
            )
        )
        #expect(
            try decode(#"{"kind":"usage","usageTarget":"response","usage":{"inputTokens":10,"cachedInputTokens":4,"outputTokens":5,"reasoningTokens":2}}"#)
                .command(expectsGuidedResponse: false)
            == .usage(
                target: .response,
                value: .init(inputTokens: 10, cachedInputTokens: 4, outputTokens: 5, reasoningTokens: 2)
            )
        )
    }

    @Test func eventProtocolRejectsModeMismatchAndMalformedToolCalls() throws {
        let decoder = JSONDecoder()
        let guided = try decoder.decode(
            EvaluationHTTPGenerationEvent.self,
            from: Data(#"{"kind":"guidedResponse","content":"{}","tokenCount":1}"#.utf8)
        )
        let malformedTool = try decoder.decode(
            EvaluationHTTPGenerationEvent.self,
            from: Data(#"{"kind":"toolCall","toolName":"lookup","content":"{}","tokenCount":1}"#.utf8)
        )
        let invalidUsage = try decoder.decode(
            EvaluationHTTPGenerationEvent.self,
            from: Data(#"{"kind":"usage","usageTarget":"response","usage":{"inputTokens":2,"cachedInputTokens":3,"outputTokens":1,"reasoningTokens":0}}"#.utf8)
        )

        do {
            _ = try guided.command(expectsGuidedResponse: false)
            Issue.record("Expected guided output to be rejected for a text request.")
        } catch let error as EvaluationHTTPProviderError {
            #expect(error.localizedDescription.contains("guidedResponse"))
        }
        do {
            _ = try malformedTool.command(expectsGuidedResponse: false)
            Issue.record("Expected a tool call without callID to be rejected.")
        } catch let error as EvaluationHTTPProviderError {
            #expect(error.localizedDescription.contains("callID"))
        }
        do {
            _ = try invalidUsage.command(expectsGuidedResponse: false)
            Issue.record("Expected inconsistent usage counts to be rejected.")
        } catch let error as EvaluationHTTPProviderError {
            #expect(error.localizedDescription.contains("usage counts"))
        }
    }

    @Test func ndjsonBufferEnforcesBoundsBeforeReceivingANewline() throws {
        var eventBounded = EvaluationHTTPNDJSONBuffer(
            maximumEventBytes: 3,
            maximumResponseBytes: 10
        )
        do {
            for byte in Data("four".utf8) {
                _ = try eventBounded.append(byte)
            }
            Issue.record("Expected a no-newline event to be rejected at its byte limit.")
        } catch let error as EvaluationHTTPProviderError {
            #expect(error.localizedDescription.contains("event exceeded 3 bytes"))
        }

        var responseBounded = EvaluationHTTPNDJSONBuffer(
            maximumEventBytes: 10,
            maximumResponseBytes: 3
        )
        do {
            for byte in Data("four".utf8) {
                _ = try responseBounded.append(byte)
            }
            Issue.record("Expected the aggregate response byte limit to be enforced.")
        } catch let error as EvaluationHTTPProviderError {
            #expect(error.localizedDescription.contains("response exceeded 3 bytes"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func delayedLoopbackFixturePublishesBeforeSDKStreamCompletion() async throws {
        let fixture = try RunningCustomModelFixture(streamDelay: 0.4)
        defer { fixture.stop() }

        let caseID = UUID()
        let recorder = HTTPPartialResponseRecorder()
        var configuration = EvaluationCustomProviderConfiguration()
        configuration.endpoint = "http://127.0.0.1:\(fixture.port)/text"
        let model = EvaluationHTTPLanguageModel(
            configuration: configuration,
            liveResponseObserver: EvaluationHTTPLiveResponseObserver { update in
                await recorder.record(update)
            }
        )
        let session = LanguageModelSession(model: model)
        var suite = EvaluationSuite()
        suite.modelConfiguration.provider = .customHTTP
        suite.modelConfiguration.customProvider = configuration
        suite.features.streamResponse = true

        let started = ContinuousClock.now
        let response = try await EvaluationFeatureResponse.generate(
            session: session,
            prompt: Prompt { "Return the fixture response." },
            suite: suite,
            metadata: [
                "evalCaseID": caseID.uuidString,
                "repetition": 1
            ]
        )
        let completedMilliseconds = started.milliseconds(to: .now)
        let updates = await recorder.updates
        let firstContentMilliseconds = try #require(response.firstContentMilliseconds)

        #expect(response.content == "Deterministic fixture stream.")
        #expect(updates.first?.caseID == caseID)
        #expect(updates.first?.content == "Deterministic ")
        #expect(updates.last?.content == response.content)
        #expect(completedMilliseconds - firstContentMilliseconds > 500)
    }

    @Test(.timeLimit(.minutes(1)))
    func runnerStreamingUpdatesRetainCaseNamesAcrossRepetitions() async throws {
        let fixture = try RunningCustomModelFixture(streamDelay: 0.05)
        defer { fixture.stop() }
        let recorder = RunnerLiveResponseRecorder()
        var suite = EvaluationSuite()
        suite.scoringMode = .review
        suite.repetitions = 2
        suite.cases = [
            EvaluationCase(name: "First case", prompt: "First prompt", expected: ""),
            EvaluationCase(name: "Second case", prompt: "Second prompt", expected: "")
        ]
        suite.modelConfiguration.provider = .customHTTP
        suite.modelConfiguration.customProviderSettings.endpoint = "http://127.0.0.1:\(fixture.port)/text"
        suite.features.streamResponse = true

        let run = await EvaluationRunner().run(
            id: UUID(), suiteRevision: "test", startedAt: Date(), suite: suite, images: [],
            liveResponse: { await recorder.record($0) }
        ) { _, _, _ in }

        #expect(run.results.count == 4)
        #expect(run.results.allSatisfy { $0.response == "Deterministic fixture stream." })
        let updates = await recorder.updates
        for evaluationCase in suite.cases {
            for repetition in 1...suite.repetitions {
                let sampleUpdates = updates.filter {
                    $0.caseID == evaluationCase.id && $0.repetition == repetition
                }
                #expect(sampleUpdates.contains { $0.content == "Deterministic " })
                #expect(sampleUpdates.allSatisfy { $0.caseName == evaluationCase.name })
                #expect(sampleUpdates.allSatisfy { $0.turnName == "Scored prompt" })
            }
        }
    }

    @Test func providerFailuresKeepRunControlCategories() {
        #expect(
            EvaluationRunner.traceError(
                EvaluationHTTPProviderError.backend(
                    code: "modelUnavailable",
                    message: "The configured model is offline."
                )
            ).category == "modelUnavailable"
        )
        #expect(
            EvaluationRunner.traceError(EvaluationHTTPProviderError.httpStatus(429)).category
                == "rateLimited"
        )
        #expect(
            EvaluationRunner.traceError(EvaluationHTTPProviderError.httpStatus(503)).category
                == "serviceUnavailable"
        )
        #expect(
            EvaluationRunner.traceError(
                EvaluationHTTPProviderError.backend(code: "backendSpecific", message: "Retry later.")
            ).category == "customProviderError"
        )

        for error: EvaluationHTTPProviderError in [
            .httpStatus(408),
            .backend(code: "invalidConfiguration", message: "Configuration changed."),
            .backend(code: "backendSpecific", message: "Retry later."),
        ] {
            #expect(EvaluationRunner.stopsBatch(for: EvaluationRunner.traceError(error).category))
        }

        let erasedProviderError = ErasedExecutorError(
            message: EvaluationHTTPProviderError.backend(
                code: "backendSpecific",
                message: "Retry later."
            ).localizedDescription
        )
        #expect(EvaluationRunner.traceError(erasedProviderError).category == "customProviderError")
        #expect(
            EvaluationRunner.traceError(
                ErasedExecutorError(message: URLError(.timedOut).localizedDescription)
            ).category == "timeout"
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func customProviderFailureStopsRemainingSamples() async throws {
        let fixture = try RunningCustomModelFixture(streamDelay: 0)
        defer { fixture.stop() }

        var suite = EvaluationSuite()
        suite.scoringMode = .review
        suite.repetitions = 2
        suite.cases.append(EvaluationCase(name: "Second", prompt: "Second prompt", expected: ""))
        suite.modelConfiguration.provider = .customHTTP
        suite.modelConfiguration.customProviderSettings.endpoint =
            "http://127.0.0.1:\(fixture.port)/error"

        let run = await EvaluationRunner().run(
            id: UUID(),
            suiteRevision: "test",
            startedAt: Date(),
            suite: suite,
            images: []
        ) { _, _, _ in }

        #expect(run.results.count == 1)
        #expect(run.terminationReason == "customProviderError")
        #expect(run.stoppedEarly)
        #expect(!run.cancelled)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingFromPartialObserverPreventsACompletedResponse() async throws {
        let fixture = try RunningCustomModelFixture(streamDelay: 0.4)
        defer { fixture.stop() }

        var configuration = EvaluationCustomProviderConfiguration()
        configuration.endpoint = "http://127.0.0.1:\(fixture.port)/text"
        let model = EvaluationHTTPLanguageModel(configuration: configuration)
        let session = LanguageModelSession(model: model)
        var suite = EvaluationSuite()
        suite.modelConfiguration.provider = .customHTTP
        suite.modelConfiguration.customProvider = configuration
        suite.features.streamResponse = true

        let responseTask = Task {
            try await EvaluationFeatureResponse.generate(
                session: session,
                prompt: Prompt { "Return the fixture response." },
                suite: suite,
                metadata: [:]
            ) { content in
                if content == "Deterministic fixture stream." {
                    withUnsafeCurrentTask { task in task?.cancel() }
                }
            }
        }

        switch await responseTask.result {
        case .success:
            Issue.record("Expected cancellation from the partial observer to abort the response.")
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }
}

private struct ErasedExecutorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private actor HTTPPartialResponseRecorder {
    private(set) var updates: [EvaluationHTTPLiveResponseUpdate] = []

    func record(_ update: EvaluationHTTPLiveResponseUpdate) {
        updates.append(update)
    }
}

private actor RunnerLiveResponseRecorder {
    private(set) var updates: [EvaluationLiveResponse] = []

    func record(_ update: EvaluationLiveResponse) {
        updates.append(update)
    }
}

private final class RunningCustomModelFixture {
    let port: Int
    private let process: Process

    init(streamDelay: Double) throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repository = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repository.appending(path: "examples/custom_model_fixture_server.py")
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            script.path,
            "--port", "0",
            "--stream-delay", String(streamDelay)
        ]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        self.process = process

        let readyData = output.fileHandleForReading.availableData
        let ready = String(decoding: readyData, as: UTF8.self)
        let port = ready
            .split(separator: "\n")
            .compactMap { line in
                line.split(separator: " ").last.flatMap { URL(string: String($0))?.port }
            }
            .first
        guard let port else {
            process.terminate()
            process.waitUntilExit()
            let remainingOutput = output.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errors.fileHandleForReading.readDataToEndOfFile()
            throw RunningCustomModelFixtureError.invalidReadyMessage(
                stdout: ready + String(decoding: remainingOutput, as: UTF8.self),
                stderr: String(decoding: errorOutput, as: UTF8.self),
                terminationStatus: process.terminationStatus
            )
        }
        self.port = port
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}

private enum RunningCustomModelFixtureError: LocalizedError {
    case invalidReadyMessage(stdout: String, stderr: String, terminationStatus: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidReadyMessage(let stdout, let stderr, let terminationStatus):
            """
            The custom model fixture did not publish a valid ready endpoint (status \(terminationStatus)).
            stdout: \(stdout.debugDescription)
            stderr: \(stderr.debugDescription)
            """
        }
    }
}

private extension ContinuousClock.Instant {
    func milliseconds(to other: Self) -> Double {
        let elapsed = duration(to: other).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }
}
