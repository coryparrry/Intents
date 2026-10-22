import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

@MainActor
struct EvaluationInitialAssessmentUsageTests {
    enum Scenario: CaseIterable, Sendable {
        case missingFirst, missingLast, allKnown, allUnknown
        case judgeFailure, subjectFailure, deterministic
    }

    @Test(arguments: Scenario.allCases)
    func productionRunRetainsUsageAvailability(scenario: Scenario) async throws {
        let connection = EvaluationJudgeConnection(id: UUID(), name: "Usage fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1/v1", modelID: "usage-fixture", generationPolicy: .portable)
        var suite = EvaluationSuite()
        suite.scoringMode = .modelJudge
        suite.criteria = scenario == .deterministic ? "exact: \"Correct fact\"" : "The response is factually correct."
        suite.cases = (0..<2).map { .init(name: "Case \($0)", prompt: "State the correct fact.", expected: "Correct fact") }
        suite.repetitions = 1
        suite.modelConfiguration.provider = .customHTTP
        suite.features.prewarm = false
        suite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id,
            externalEvidenceApprovedAt: Date(), includeReferenceAttachments: false,
            approvedConnectionID: connection.id, approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest,
            approvedEvidencePolicyVersion: EvaluationJudgeConfiguration.currentEvidencePolicyVersion)
        let transport = InitialAssessmentUsageTransport(scenario: scenario)
        let client = EvaluationCompatibleJudgeClient(transport: { try await transport.send($0) })
        let failingCaseID = scenario == .subjectFailure ? suite.cases[1].id : nil
        let run = await EvaluationRunner(compatibleJudgeClient: client).run(
            id: UUID(), suiteRevision: "usage-fixture", startedAt: Date(), suite: suite, images: [],
            model: InitialAssessmentUsageModel(failingCaseID: failingCaseID), contextSize: 131_072,
            modelName: "Fixture executor", admissionError: nil,
            externalJudge: .init(connection: connection, apiKey: nil),
            liveResponse: { _ in }, progress: { _, _, _ in })
        let restored = try CanonicalJSON.decode(EvaluationRun.self, from: CanonicalJSON.data(for: run))
        let assessment = try #require(restored.selectedAssessment)
        #expect(restored.results.count == 2)
        #expect(assessment.samples.count == 2)
        let known = assessment.samples.compactMap(\.usage)
        switch scenario {
        case .allKnown:
            #expect(known.count == 2)
            #expect(assessment.totalUsage?.inputTokens == 20)
            #expect(assessment.totalUsage?.outputTokens == 10)
            #expect(assessment.cost.usd == 0.2)
        case .subjectFailure:
            #expect(known.count == 1)
            #expect(restored.results[1].status == .error)
            #expect(restored.results[1].judgeDurationMilliseconds == nil)
            #expect(assessment.totalUsage?.inputTokens == 10)
            #expect(assessment.totalUsage?.outputTokens == 5)
            #expect(assessment.cost.usd == 0.1)
        case .deterministic:
            #expect(known.isEmpty)
            #expect(assessment.totalUsage == nil)
            #expect(restored.results.allSatisfy { $0.status == .passed && $0.judgeDurationMilliseconds == nil })
            #expect(await transport.requestCount == 0)
            #expect(assessment.cost.usd == 0)
        case .allUnknown:
            #expect(known.isEmpty)
            #expect(assessment.totalUsage == nil)
            #expect(assessment.cost.availability == .unavailable)
        case .missingFirst, .missingLast, .judgeFailure:
            #expect(known.count == 1)
            #expect(known.first?.inputTokens == 10)
            #expect(known.first?.outputTokens == 5)
            #expect(assessment.totalUsage == nil)
            #expect(assessment.cost.availability == .unavailable)
            if scenario == .judgeFailure {
                #expect(restored.results[1].judgeErrorCategory == "serviceUnavailable")
                #expect(restored.results[1].judgeDurationMilliseconds != nil)
            }
        }
    }
}

private actor InitialAssessmentUsageTransport {
    let scenario: EvaluationInitialAssessmentUsageTests.Scenario
    private(set) var requestCount = 0
    init(scenario: EvaluationInitialAssessmentUsageTests.Scenario) { self.scenario = scenario }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requestCount += 1
        if scenario == .judgeFailure, requestCount == 2 { throw URLError(.cannotConnectToHost) }
        let hasUsage = switch scenario {
        case .missingFirst: requestCount != 1
        case .missingLast: requestCount != 2
        case .allUnknown: false
        default: true
        }
        let verdict = #"{"requirements":[{"criterionIndex":1,"score":4,"rationale":"The response states the correct fact."}]}"#
        var envelope: [String: Any] = ["choices": [["message": ["content": verdict], "finish_reason": "stop"]],
                                       "model": "usage-fixture"]
        if hasUsage { envelope["usage"] = ["prompt_tokens": 10, "completion_tokens": 5, "cost": 0.1] }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONSerialization.data(withJSONObject: envelope), response)
    }
}

private struct InitialAssessmentUsageModel: LanguageModel {
    typealias Executor = InitialAssessmentUsageExecutor
    var failingCaseID: UUID?
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }
    var executorConfiguration: UUID? { failingCaseID }
}

private struct InitialAssessmentUsageExecutor: LanguageModelExecutor {
    typealias Model = InitialAssessmentUsageModel
    typealias Configuration = UUID?
    let failingCaseID: UUID?
    init(configuration: UUID?) throws { failingCaseID = configuration }
    func prewarm(model: Model, transcript: Transcript) {}
    func respond(to request: LanguageModelExecutorGenerationRequest, model: Model,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        if let failingCaseID,
           let value = request.metadata["evalCaseID"],
           try JSONDecoder().decode(String.self, from: Data(value.jsonString.utf8)) == failingCaseID.uuidString {
            throw FixtureSubjectFailure()
        }
        await channel.send(.response(action: .appendText("Correct fact", tokenCount: 5)))
    }
    private struct FixtureSubjectFailure: Error {}
}
