import Foundation
import FoundationModels
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import FoundationEvals

@MainActor
struct EvaluationObservedContextTests {
    @Test func freezesObservedRetainedResponsesAndProjectionWithoutTranscriptTracing() throws {
        let history = turn("Discarded customer", "Discarded response") + turn("Retained customer", "Observed response 483")
        let retained = EvaluationConversationRuntime.retainedHistory(history, policy: .retainRecentCompleteTurns, recentTurnCount: 1)
        let facing = EvaluationConversationRuntime.modelFacingHistory(retained, projection: .init(policy: .keepAll))
        let snapshot = EvaluationJudgeSubjectContext.capture(facing, instructions: "Summarize the customer request.")
        #expect(snapshot.unavailableReason == nil)
        #expect(snapshot.entries.map(\.role) == ["user", "assistant"])
        #expect(snapshot.evidenceText.contains("Observed response 483"))
        #expect(!snapshot.evidenceText.contains("Discarded"))
        let reset = EvaluationConversationRuntime.modelFacingHistory(retained, projection: .init(policy: .reset))
        #expect(EvaluationJudgeSubjectContext.capture(reset, instructions: "").entries.isEmpty)
        let unfinished = Transcript.Entry.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "Obsolete unfinished prompt"))]))
        let beforeNextPrompt = EvaluationConversationRuntime.modelFacingHistory(retained + [unfinished], projection: .init(policy: .reset))
        #expect(beforeNextPrompt.isEmpty)
        let retainedBeforeNextPrompt = EvaluationConversationRuntime.modelFacingHistory(retained + [unfinished], projection: .init(policy: .retainRecentCompleteTurns, retainedTurnCount: 1))
        #expect(retainedBeforeNextPrompt == retained)
        var suite = EvaluationSuite()
        suite.modelConfiguration.customizationSettings.captureTranscript = false
        let item = sample(suite: suite, context: snapshot)
        #expect(item.featureTrace?.transcript == nil)
        let restored = try CanonicalJSON.decode(EvaluationSampleResult.self, from: CanonicalJSON.data(for: item))
        #expect(restored.judgeSubjectContext == snapshot)
    }

    @Test func realSessionRunnerCapturesGeneratedSetupHistoryWithTracingDisabled() async throws {
        var suite = fixture().0
        suite.judgeConfiguration.mode = .sameModel
        suite.modelConfiguration.provider = .customHTTP
        suite.modelConfiguration.customizationSettings.captureTranscript = false
        suite.features.prewarm = false
        suite.cases[0].conversation.setupTurns = [.init(prompt: "Cancel order 483 and keep 484")]
        let run = await EvaluationRunner().run(id: UUID(), suiteRevision: "fixture", startedAt: Date(), suite: suite,
            images: [], model: ObservedContextModel(), contextSize: 131_072, modelName: "Fixture executor", admissionError: nil,
            externalJudge: nil, liveResponse: { _ in }, progress: { _, _, _ in })
        let result = try #require(run.results.first)
        #expect(result.errorMessage == nil)
        #expect(result.judgeErrorMessage == nil)
        #expect(result.status == .passed)
        #expect(result.featureTrace?.transcript == nil)
        #expect(result.judgeSubjectContext?.evidenceText.contains("Generated acknowledgement: cancel 483") == true)
        #expect(result.judgeTrace?.prompt.contains("Generated acknowledgement: cancel 483") == true)
        #expect(result.judgeSubjectContext?.entries.map(\.role) == ["user", "assistant"])
    }

    @Test func restoredHistoryAndSetupGeneratedResponsesReachJudgePrompt() throws {
        let history = turn("Remember order 483", "I will retain 483")
        let transcript = Transcript(entries: history)
        let json = String(decoding: try JSONEncoder().encode(transcript), as: UTF8.self)
        let restored = try EvaluationConversationRuntime.restoredHistory(from: .init(restoredTranscriptJSON: json))
        let context = EvaluationJudgeSubjectContext.capture(restored, instructions: "Observed instructions")
        let (suite, _) = fixture()
        let prompt = EvaluationRunner.judgePrompt(response: "483", evaluationCase: suite.cases[0], effectivePrompt: "Which order?",
            suite: suite, toolEvidence: nil, subjectContext: context)
        #expect(prompt.contains("observedModelFacingHistory:"))
        #expect(prompt.contains("I will retain 483"))
        #expect(prompt.contains("Observed instructions"))
    }

    @Test func missingLegacyMultiTurnEvidenceCannotBeInvented() throws {
        let single = EvaluationCase(name: "Single", prompt: "Hello", expected: "")
        #expect(try EvaluationJudgeSubjectContext.resolved(nil, evaluationCase: single).entries.isEmpty)
        var multi = single
        multi.conversation.setupTurns = [.init(prompt: "Remember 483")]
        #expect(throws: EvaluationJudgeSubjectContext.ContextError.self) {
            try EvaluationJudgeSubjectContext.resolved(nil, evaluationCase: multi)
        }
        // An observed empty projection is evidence; configured setup prompts alone are not.
        #expect(try EvaluationJudgeSubjectContext.resolved(.init(), evaluationCase: multi).entries.isEmpty)
        var failed = EvaluationJudgeSubjectContext()
        failed.unavailableReason = "Unsupported history"
        #expect(throws: EvaluationJudgeSubjectContext.ContextError.self) {
            try EvaluationJudgeSubjectContext.resolved(failed, evaluationCase: single)
        }
        var future = EvaluationJudgeSubjectContext()
        future.formatVersion = 99
        #expect(throws: EvaluationJudgeSubjectContext.ContextError.self) {
            try EvaluationJudgeSubjectContext.resolved(future, evaluationCase: single)
        }
    }

    @Test func contextCaptureRejectsOversizeInsteadOfTruncating() {
        let context = EvaluationJudgeSubjectContext.capture(turn(String(repeating: "x", count: EvaluationJudgeSubjectContext.maximumBytes), "answer"), instructions: "")
        #expect(context.unavailableReason != nil)
        #expect(context.entries.isEmpty)
    }

    @Test func sameModelAdmissionAccountsForObservedHistory() async throws {
        var suite = fixture().0
        suite.judgeConfiguration.mode = .sameModel
        suite.instructions = ""
        suite.modelConfiguration.maximumResponseTokens = 128
        let runner = EvaluationRunner()
        let counter = ObservedContextTokenCounter()
        _ = try await runner.preparedPrompt(for: suite.cases[0], suite: suite, images: [], contextSize: 8_192,
            tools: [], judgeSubjectContext: .init(), tokenCounter: counter)
        let large = EvaluationJudgeSubjectContext(entries: [.init(role: "assistant", content: String(repeating: "x", count: 12_000))])
        await #expect(throws: (any Error).self) {
            _ = try await runner.preparedPrompt(for: suite.cases[0], suite: suite, images: [], contextSize: 8_192,
                tools: [], judgeSubjectContext: large, tokenCounter: counter)
        }
    }

    @Test func initialScoringAndReloadedReassessmentUseIdenticalObservedContext() async throws {
        var (suite, connection) = fixture()
        suite.cases[0].conversation.setupTurns = [.init(prompt: "Remember the request")]
        let context = EvaluationJudgeSubjectContext.capture(turn("Cancel 483, keep 484", "Confirmed: cancel 483 only"), instructions: "Observed instructions")
        let transport = ObservedContextTransport(responses: [try completion(), try completion()])
        let client = EvaluationCompatibleJudgeClient(transport: { try await transport.send($0) })
        let resolved = EvaluationResolvedJudgeConnection(connection: connection, apiKey: nil)
        let outcome = await EvaluationRunner(compatibleJudgeClient: client).score(response: "483", evaluationCase: suite.cases[0],
            effectivePrompt: "Which order?", suite: suite, runID: UUID(), images: [], model: SystemLanguageModel.default,
            contextSize: 8_192, modelName: "No subject generation", externalJudge: resolved, toolEvidence: nil,
            subjectContext: context, tokenCounter: ObservedContextTokenCounter())
        #expect(outcome.status == .passed)
        var run = EvaluationRun(id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version, instructions: suite.instructions,
            criteria: suite.criteria, scoringMode: suite.scoringMode, repetitions: 1,
            startedAt: Date(), completedAt: Date(), cancelled: false,
            environment: .init(operatingSystem: "Fixture", locale: "en", model: "Fixture", modelContextSize: 8_192),
            attachments: [], results: [sample(suite: suite, context: context)])
        run.plannedCases = suite.cases
        let restored = try CanonicalJSON.decode(EvaluationRun.self, from: CanonicalJSON.data(for: run))
        suite.instructions = "Edited instructions must not replace observed input"
        let assessment = try await EvaluationReassessmentService(client: client).reassess(run: restored, suite: suite, images: [], resolved: resolved)
        #expect(assessment.samples.first?.status == .passed)
        let bodies = await transport.bodies()
        #expect(bodies.count == 2)
        let prompts = try bodies.map(userPrompt)
        #expect(prompts[0] == prompts[1])
        #expect(prompts[0].contains("Confirmed: cancel 483 only"))
        #expect(!prompts[0].contains("Edited instructions"))
    }

    @Test func unsupportedLegacyReassessmentRemainsReadableAndMakesNoRequest() async throws {
        var (suite, connection) = fixture()
        suite.cases[0].conversation.setupTurns = [.init(prompt: "Remember the order")]
        let item = sample(suite: suite, context: nil)
        var run = EvaluationRun(id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version, instructions: suite.instructions,
            criteria: suite.criteria, scoringMode: suite.scoringMode, repetitions: 1,
            startedAt: Date(), completedAt: Date(), cancelled: false,
            environment: .init(operatingSystem: "Fixture", locale: "en", model: "Fixture", modelContextSize: 8_192),
            attachments: [], results: [item])
        run.plannedCases = suite.cases
        let restored = try CanonicalJSON.decode(EvaluationRun.self, from: CanonicalJSON.data(for: run))
        let transport = ObservedContextTransport(responses: [])
        let client = EvaluationCompatibleJudgeClient(transport: { try await transport.send($0) })
        let assessment = try await EvaluationReassessmentService(client: client).reassess(run: restored, suite: suite, images: [],
            resolved: .init(connection: connection, apiKey: nil))
        #expect(assessment.samples.first?.status == .unscored)
        #expect(assessment.samples.first?.errorCategory == "incompleteSavedEvidence")
        #expect(await transport.bodies().isEmpty)
    }

    @Test func oldDisclosureApprovalRequiresExplicitRenewalAndDefinitionPreservesLocalVersion() throws {
        var (suite, connection) = fixture()
        #expect(suite.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: connection))
        let definition = EvaluationSuiteDefinition(suite: suite)
        #expect(definition.judgeConfiguration.approvedEvidencePolicyVersion == nil)
        #expect(definition.applyingLocalState(from: suite).judgeConfiguration.approvedEvidencePolicyVersion == EvaluationJudgeConfiguration.currentEvidencePolicyVersion)
        var object = try #require(JSONSerialization.jsonObject(with: CanonicalJSON.data(for: suite.judgeConfiguration)) as? [String: Any])
        object.removeValue(forKey: "approvedEvidencePolicyVersion")
        suite.judgeConfiguration = try CanonicalJSON.decode(EvaluationJudgeConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!suite.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: connection))
        suite.judgeConfiguration.approvedEvidencePolicyVersion = EvaluationJudgeConfiguration.currentEvidencePolicyVersion
        #expect(suite.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: connection))
    }

    @Test func mcpCannotMintTheExpandedEvidenceApproval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        try MCPWorkspaceControl.requireServerApproval(store.suite.judgeConfiguration, store: store)
        var forged = store.suite.judgeConfiguration
        forged.approvedEvidencePolicyVersion = EvaluationJudgeConfiguration.currentEvidencePolicyVersion
        #expect(throws: EvaluationStoreError.self) {
            try MCPWorkspaceControl.requireServerApproval(forged, store: store)
        }
    }

    @Test(arguments: [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier])
    func mediaTypeUsesBytesDespiteMissingOrMisleadingExtension(identifier: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reference.image")
        let bytes = try image(identifier: identifier)
        try bytes.write(to: url)
        var (suite, connection) = fixture()
        suite.judgeConfiguration.includeReferenceAttachments = true
        suite.judgeConfiguration.approvedIncludeReferenceAttachments = true
        connection.capabilities.multimodal = true
        suite.judgeConfiguration.approvedConnectionDigest = connection.disclosureDigest
        let transport = ObservedContextTransport(responses: [try completion()])
        let client = EvaluationCompatibleJudgeClient(transport: { try await transport.send($0) })
        _ = try await client.judge(response: "483", evaluationCase: suite.cases[0], effectivePrompt: "Which order?", suite: suite,
            images: [.init(label: "Reference", url: url)], toolEvidence: nil, resolved: .init(connection: connection, apiKey: nil))
        let body = try #require(await transport.bodies().first)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        let imagePart = try #require(parts.last?["image_url"] as? [String: String])
        let mime = try #require(UTType(identifier)?.preferredMIMEType)
        #expect(imagePart["url"] == "data:\(mime);base64,\(bytes.base64EncodedString())")
    }

    @Test func malformedImageBytesNeverReachTransport() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var (suite, connection) = fixture()
        connection.capabilities.multimodal = true
        suite.judgeConfiguration.includeReferenceAttachments = true
        suite.judgeConfiguration.approvedIncludeReferenceAttachments = true
        suite.judgeConfiguration.approvedConnectionDigest = connection.disclosureDigest
        let transport = ObservedContextTransport(responses: [])
        let client = EvaluationCompatibleJudgeClient(transport: { try await transport.send($0) })
        await #expect(throws: (any Error).self) {
            _ = try await client.judge(response: "483", evaluationCase: suite.cases[0], effectivePrompt: "Which order?", suite: suite,
                images: [.init(label: "Reference", url: url)], toolEvidence: nil, resolved: .init(connection: connection, apiKey: nil))
        }
        #expect(await transport.bodies().isEmpty)
    }

    private func fixture() -> (EvaluationSuite, EvaluationJudgeConnection) {
        let connection = EvaluationJudgeConnection(id: UUID(), name: "Fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1/v1", modelID: "fixture")
        var suite = EvaluationSuite()
        suite.scoringMode = .modelJudge
        suite.criteria = "Correctly summarizes the observed customer request."
        suite.cases = [.init(name: "Order", prompt: "Which order?", expected: "")]
        suite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id, externalEvidenceApprovedAt: Date(),
            includeReferenceAttachments: false, approvedConnectionID: connection.id, approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest,
            approvedEvidencePolicyVersion: EvaluationJudgeConfiguration.currentEvidencePolicyVersion)
        return (suite, connection)
    }

    private func sample(suite: EvaluationSuite, context: EvaluationJudgeSubjectContext?) -> EvaluationSampleResult {
        .init(caseID: suite.cases[0].id, caseName: "Order", repetition: 1, prompt: suite.cases[0].prompt,
            effectivePrompt: "Which order?", expected: "", response: "483", status: .unscored, score: nil, rationale: nil,
            durationMilliseconds: 1, usage: .init(), judgeDurationMilliseconds: nil, judgeUsage: nil,
            errorCategory: nil, errorMessage: nil, judgeErrorCategory: nil, judgeErrorMessage: nil, judgeSubjectContext: context)
    }

    private func turn(_ prompt: String, _ response: String) -> [Transcript.Entry] {
        [.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])),
         .response(Transcript.Response(metadata: [:], segments: [.text(Transcript.TextSegment(content: response))]))]
    }

    private func completion() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "{\"requirements\":[{\"criterionIndex\":1,\"score\":4,\"rationale\":\"Correct order.\"}]}"], "finish_reason": "stop"]]])
    }

    private func userPrompt(_ body: Data) throws -> String {
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        return try #require(messages[1]["content"] as? String)
    }

    private func image(identifier: String) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
}

private actor ObservedContextTransport {
    var responses: [Data]
    var requests: [Data] = []
    init(responses: [Data]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request.httpBody ?? Data())
        guard !responses.isEmpty, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (responses.removeFirst(), response)
    }
    func bodies() -> [Data] { requests }
}

private struct ObservedContextTokenCounter: EvaluationPromptInputTokenCounting {
    func tokenCount(for prompt: Prompt) async throws -> Int { String(describing: prompt).utf8.count }
    func tokenCount(for instructions: Instructions) async throws -> Int { 0 }
    func tokenCount(for schema: GenerationSchema) async throws -> Int { 0 }
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int { 0 }
    func tokenCount(for tools: [any Tool]) async throws -> Int { 0 }
    func tokenCount(forText text: String) async throws -> Int { text.utf8.count }
}


private struct ObservedContextModel: LanguageModel {
    typealias Executor = ObservedContextExecutor
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration]) }
    var executorConfiguration: Bool { false }
    var contextSize: Int { 131_072 }
}

private struct ObservedContextExecutor: LanguageModelExecutor {
    typealias Model = ObservedContextModel
    typealias Configuration = Bool
    init(configuration: Bool) throws {}
    func prewarm(model: Model, transcript: Transcript) {}
    func respond(to request: LanguageModelExecutorGenerationRequest, model: Model,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let role = request.metadata["role"].flatMap {
            try? JSONDecoder().decode(String.self, from: Data($0.jsonString.utf8))
        }
        let content: String
        if request.schema != nil {
            content = "{\"requirement1\":{\"score\":4,\"rationale\":\"Correctly cancels order 483.\"}}"
        } else {
            content = role == "setup" ? "Generated acknowledgement: cancel 483" : "483"
        }
        await channel.send(.response(action: .appendText(content, tokenCount: 8)))
    }
}
