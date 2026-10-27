import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

struct EvaluationDocumentJudgeIsolationTests {
    /// Exercise external review only after synthetic controls explicitly authorize the selected judge.
    @Test @MainActor func optedInSyntheticControlsReachTheExternalTransport() async throws {
        var connection = EvaluationJudgeConnection(id: UUID(), name: "Fixture", kind: .customCompatible,
            baseURL: "https://judge.invalid", modelID: "fixture")
        connection.capabilities.contextWindowTokens = 32_768
        var value = DocumentTestFixture.suite().cases[0]
        value.criteriaOverride = ["States that members cannot export."]
        let suite = EvaluationDocumentQualityTests.controlSuite(value: value, connection: connection).effectiveSuite(for: value)
        let client = EvaluationCompatibleJudgeClient(transport: { request in
            let requestBody = try #require(request.httpBody)
            #expect(String(decoding: requestBody, as: UTF8.self).contains("Retained source"))
            let verdict = "{\"requirements\":[{\"criterionIndex\":1,\"score\":4,\"rationale\":\"Members are explicitly prohibited from exporting.\"}]}"
            let body = try JSONSerialization.data(withJSONObject: ["model": "fixture",
                "choices": [["message": ["content": verdict]]]])
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
            return (body, response)
        })
        let result = try await client.judge(response: "Members cannot export.", evaluationCase: value,
            effectivePrompt: "Retained source: " + DocumentTestFixture.passage.text, suite: suite,
            images: [], toolEvidence: nil, resolved: .init(connection: connection, apiKey: nil))
        #expect(result.judgment.score == 4)
        #expect(result.identity.requestedModelID == "fixture")
        #expect(!EvaluationDocumentQualityTests.controlSuite(value: value, connection: nil).judgeConfiguration.usesExternalConnection)
    }

    /// Keep capacity admission aligned with the actual semantic payload while avoiding transport for literal-only checks.
    @Test func externalAdmissionMatchesTheSemanticRequestAndSkipsExactOnlyCases() throws {
        var suite = DocumentTestFixture.suite()
        let longLiteral = "exact: \"" + String(repeating: "X", count: 3_800) + "\""
        suite.cases[0].criteriaOverride = [longLiteral, longLiteral.replacingOccurrences(of: "X", with: "Y"), "States readiness."]
        var connection = EvaluationJudgeConnection(id: UUID(), name: "Fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1234", modelID: "fixture")
        connection.capabilities.contextWindowTokens = 12_000
        let admission = try #require(EvaluationRunner.externalDocumentJudgeAdmission(evaluationCase: suite.cases[0],
            effectivePrompt: "Retained source", suite: suite, subjectContext: nil, connection: connection))
        #expect(admission.configuration.criteriaCount == 1)
        #expect(!admission.prompt.contains(String(repeating: "X", count: 100)))
        try EvaluationCompatibleJudgeClient.validateDocumentBudget(prompt: admission.prompt, configuration: admission.configuration,
            connection: connection, candidateReserve: 4_096)
        let combined = EvaluationRunner.documentJudgePrompt(response: "", evaluationCase: suite.cases[0],
            effectivePrompt: "Retained source", suite: suite.effectiveSuite(for: suite.cases[0]), subjectContext: nil)
        #expect(throws: (any Error).self) {
            try EvaluationCompatibleJudgeClient.validateDocumentBudget(prompt: combined,
                configuration: EvaluationCompatibleJudgeClient.requestConfiguration(for: connection, criteriaCount: 3, documentEvidence: true),
                connection: connection, candidateReserve: 4_096)
        }
        suite.cases[0].criteriaOverride = [longLiteral]
        #expect(EvaluationRunner.externalDocumentJudgeAdmission(evaluationCase: suite.cases[0], effectivePrompt: "Source",
            suite: suite, subjectContext: nil, connection: connection) == nil)
    }
    /// Prevent a later requirement failure from publishing a partial score or losing the shared judge identity.
    @Test(arguments: [false, true])
    func separateRequirementsPreserveIdentityAndNeverPublishPartialScore(failSecond: Bool) async throws {
        let suite = DocumentTestFixture.suite()
        let value = suite.cases[0]
        let model = DocumentJudgeFixtureModel(executorConfiguration: .init(id: UUID(), failSecond: failSecond))
        let recorder = EvaluationWorkflowRecorder()
        let parent = recorder.begin(kind: .sample, title: "Fixture sample")
        recorder.activeParentID = parent
        let outcome = await EvaluationRunner().score(response: "Members cannot export. Owners can.",
            evaluationCase: value, effectivePrompt: value.prompt + "\n" + DocumentTestFixture.passage.text,
            suite: suite, runID: UUID(), images: [], model: model, contextSize: 32_768,
            modelName: "Document judge fixture", externalJudge: nil, toolEvidence: nil,
            tokenCounter: DocumentJudgeFixtureTokenCounter(), workflowRecorder: recorder)
        #expect(recorder.activeParentID == parent)
        recorder.finish(parent)
        let spans = recorder.snapshot().spans
        let enclosing = try #require(spans.first { $0.id == parent })
        let judges = spans.filter { $0.kind == .judge }
        #expect(judges.count == 2)
        #expect(judges.allSatisfy { $0.parentID == parent
            && $0.startOffsetMilliseconds >= enclosing.startOffsetMilliseconds
            && $0.startOffsetMilliseconds + $0.durationMilliseconds <= enclosing.startOffsetMilliseconds + enclosing.durationMilliseconds })
        let trace = try #require(outcome.trace)
        #expect(trace.attempts?.count == 2)
        #expect(trace.attempts?.map(\.judgedCriterionIndexes) == [[1], [2]])
        #expect(trace.attempts?.allSatisfy { $0.prompt.contains(DocumentTestFixture.passage.text) } == true)
        #expect(trace.attempts?.allSatisfy { $0.prompt.contains("Members cannot export. Owners can.") } == true)
        #expect(trace.attempts?[0].prompt.contains("Identifies the owner role.") == false)
        #expect(trace.attempts?[1].prompt.contains("States that members cannot export.") == false)
        if failSecond {
            #expect(outcome.score == nil)
            #expect(outcome.status != .passed)
            #expect(trace.checks?.map(\.criterionIndex) == [1])
            #expect(trace.validationError != nil)
        } else {
            #expect(outcome.score == 2)
            #expect(outcome.status == .failed)
            #expect(trace.checks?.map(\.criterionIndex) == [1, 2])
            #expect(trace.checks?.map(\.score) == [4, 2])
            #expect(trace.judgedCriterionIndexes == [1, 2])
        }
    }

    /// Combine local literal checks with semantic scoring without replacing the retained external verdict.
    @Test func mixedLiteralAndSemanticChecksKeepTheSingleRawVerdict() async throws {
        var suite = DocumentTestFixture.suite()
        suite.cases[0].criteriaOverride = ["The response is exactly READY.", "States readiness."]
        let value = suite.cases[0]
        let model = DocumentJudgeFixtureModel(executorConfiguration: .init(id: UUID(), failSecond: false))
        let outcome = await EvaluationRunner().score(response: "READY", evaluationCase: value,
            effectivePrompt: value.prompt + DocumentTestFixture.passage.text, suite: suite, runID: UUID(),
            images: [], model: model, contextSize: 32_768, modelName: "Fixture", externalJudge: nil,
            toolEvidence: nil, tokenCounter: DocumentJudgeFixtureTokenCounter())
        #expect(outcome.score == 4)
        #expect(outcome.trace?.attempts?.count == 1)
        #expect(outcome.trace?.rawResponse == outcome.trace?.attempts?.first?.rawResponse)
        #expect(outcome.trace?.rawResponse?.isEmpty == false)
        #expect(outcome.trace?.attempts?.first?.judgedCriterionIndexes == [2])
        #expect(outcome.trace?.checks?.map(\.criterionIndex) == [1, 2])
    }
}

private actor DocumentJudgeFixtureCalls {
    static let shared = DocumentJudgeFixtureCalls()
    var calls: [UUID: Int] = [:]
    /// Return the next scripted fixture response so retry tests can observe attempt order.
    func next(_ id: UUID) -> Int { let value = calls[id, default: 0]; calls[id] = value + 1; return value }
}
private struct DocumentJudgeFixtureModel: LanguageModel {
    typealias Executor = DocumentJudgeFixtureExecutor
    struct Configuration: Hashable, Sendable { var id: UUID; var failSecond: Bool }
    var executorConfiguration: Configuration
    var capabilities: LanguageModelCapabilities { .init([.guidedGeneration]) }
}
private struct DocumentJudgeFixtureExecutor: LanguageModelExecutor {
    typealias Model = DocumentJudgeFixtureModel
    typealias Configuration = Model.Configuration
    let configuration: Configuration
    /// Create a deterministic model fixture without loading live model resources.
    init(configuration: Configuration) throws { self.configuration = configuration }
    /// Satisfy the model warmup contract without starting a live runtime.
    func prewarm(model: Model, transcript: Transcript) {}
    /// Return the scripted model response while preserving the runner request contract.
    func respond(to request: LanguageModelExecutorGenerationRequest, model: Model,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let index = await DocumentJudgeFixtureCalls.shared.next(configuration.id)
        if index > 0, configuration.failSecond { throw CocoaError(.fileReadUnknown) }
        let score = index == 0 ? 4 : 2
        let content = "{\"requirement1\":{\"rationale\":\"Fixture evidence.\",\"score\":\(score)}}"
        await channel.send(.response(action: .appendText(content, tokenCount: 8)))
    }
}
private struct DocumentJudgeFixtureTokenCounter: EvaluationPromptInputTokenCounting {
    /// Return a controlled token estimate so admission and context-budget boundaries remain reproducible.
    func tokenCount(for prompt: Prompt) async throws -> Int { 100 }
    /// Return a controlled token estimate so admission and context-budget boundaries remain reproducible.
    func tokenCount(for instructions: Instructions) async throws -> Int { 100 }
    /// Return a controlled token estimate so admission and context-budget boundaries remain reproducible.
    func tokenCount(for schema: GenerationSchema) async throws -> Int { 100 }
    /// Return a controlled token estimate so admission and context-budget boundaries remain reproducible.
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int { 0 }
    /// Return a controlled token estimate so admission and context-budget boundaries remain reproducible.
    func tokenCount(for tools: [any Tool]) async throws -> Int { 0 }
    /// Return a controlled token estimate so admission and context-budget boundaries remain reproducible.
    func tokenCount(forText text: String) async throws -> Int { 100 }
}
