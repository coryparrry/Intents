import Foundation
import Testing
@testable import FoundationEvals

@Suite(.timeLimit(.minutes(1)))
struct EvaluationReassessmentIntegrityTests {
    @Test(arguments: [ScoringMode.exactMatch, .containsExpected, .review])
    func deterministicReassessmentHonorsItsScoringContract(mode: ScoringMode) async throws {
        var suite = EvaluationSuite()
        suite.scoringMode = mode
        // A stale rubric must not override the active deterministic scorer.
        suite.criteria = "exact: \"WRONG\""
        suite.cases = [.init(name: "Saved", prompt: "Answer", expected: "READY")]
        let original = run(suite: suite, responses: ["READY"])
        let assessment = try await EvaluationReassessmentService().reassess(
            run: original, suite: suite, images: [], resolved: nil)
        let sample = try #require(assessment.samples.first)
        let expected = MetricScorer.evaluate(mode: mode, expected: "READY", response: "READY")
        #expect(sample.status == expected.status)
        #expect(sample.rationale == expected.rationale)
        #expect(sample.score == nil)
        #expect(sample.errorCategory == nil)
        #expect(sample.trace == nil)
        #expect(assessment.scoringContract?.scoringMode == mode)
        #expect(assessment.totalUsage == nil)
        var selected = original
        selected.assessments = [assessment]
        selected.selectedAssessmentID = assessment.id
        let restored = try CanonicalJSON.decode(EvaluationRun.self, from: CanonicalJSON.data(for: selected))
        #expect(restored.effectiveResults[0].status == expected.status)
        #expect(restored.results[0].response == "READY")
    }

    @Test(arguments: [ScoringMode.exactMatch, .containsExpected, .review])
    func deterministicReassessmentReappliesFieldAssertions(mode: ScoringMode) async throws {
        var suite = EvaluationSuite()
        suite.scoringMode = mode
        suite.criteria = "exact: \"WRONG\""
        suite.cases = [.init(name: "Saved", prompt: "Answer", expected: "{\"verified\":true}")]
        suite.cases[0].fieldAssertions = [.init(pointer: "/verified", operation: .equals, expectedValue: "true")]
        for response in ["{\"verified\":true}", "{\"verified\":false}"] {
            let assessment = try await EvaluationReassessmentService().reassess(
                run: run(suite: suite, responses: [response]), suite: suite, images: [], resolved: nil)
            #expect(assessment.samples[0].status == (response.contains("true") ? .passed : .failed))
            #expect(assessment.samples[0].score == nil)
        }
    }

    @Test(arguments: [false, true])
    func partialSampleUsageIsNotPresentedAsTheAssessmentTotal(missingFirst: Bool) async throws {
        let shapes: [CompatibleJudgeFixture.UsageShape] = missingFirst
            ? [.missing, .complete] : [.complete, .missing]
        let fixture = try CompatibleJudgeFixture(mode: .usageSequence(shapes))
        defer { fixture.stop() }
        let connection = EvaluationJudgeConnection(id: UUID(), name: "Usage fixture", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture")
        var suite = EvaluationSuite()
        suite.criteria = "The answer is supported by the evidence."
        suite.cases = [.init(name: "First", prompt: "Answer", expected: "READY"),
                       .init(name: "Second", prompt: "Answer again", expected: "READY")]
        suite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id,
            externalEvidenceApprovedAt: Date(), includeReferenceAttachments: false,
            approvedConnectionID: connection.id, approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest,
            approvedEvidencePolicyVersion: EvaluationJudgeConfiguration.currentEvidencePolicyVersion)
        let assessment = try await EvaluationReassessmentService().reassess(
            run: run(suite: suite, responses: ["READY", "READY"]), suite: suite, images: [],
            resolved: .init(connection: connection, apiKey: nil))
        #expect(fixture.completionRequestCount == 2)
        #expect(assessment.samples.allSatisfy { $0.status == .passed })
        #expect(assessment.samples.compactMap(\.usage).count == 1)
        #expect(assessment.totalUsage == nil)
    }

    @Test(arguments: [false, true])
    func cancelledInitialJudgeRequestCannotExposePartialUsageOrCost(urlCancellation: Bool) async throws {
        let transport = ReassessmentCancellationTransport(urlCancellation: urlCancellation)
        let client = EvaluationCompatibleJudgeClient(transport: { try await transport.send($0) })
        let connection = EvaluationJudgeConnection(id: UUID(), name: "Cancellation fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1/v1", modelID: "judge-fixture")
        var suite = EvaluationSuite()
        suite.criteria = "The answer is supported by the evidence."
        suite.cases = [.init(name: "First", prompt: "Answer", expected: "READY"),
                       .init(name: "Second", prompt: "Answer again", expected: "READY")]
        suite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id,
            externalEvidenceApprovedAt: Date(), includeReferenceAttachments: false,
            approvedConnectionID: connection.id, approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest,
            approvedEvidencePolicyVersion: EvaluationJudgeConfiguration.currentEvidencePolicyVersion)
        let assessment = try await EvaluationReassessmentService(client: client).reassess(
            run: run(suite: suite, responses: ["READY", "READY"]), suite: suite, images: [],
            resolved: .init(connection: connection, apiKey: nil), origin: .initialRun)
        #expect(await transport.callCount == 2)
        #expect(assessment.samples.count == 2)
        #expect(assessment.samples[0].status == .passed)
        #expect(assessment.samples[0].usage?.inputTokens == 10)
        #expect(assessment.samples[0].usage?.outputTokens == 5)
        #expect(assessment.samples[1].errorCategory == "cancelled")
        #expect(assessment.samples[1].usage == nil)
        #expect(assessment.totalUsage == nil)
        #expect(assessment.cost.availability == .unavailable)
        #expect(assessment.cost.usd == nil)
    }

    private func run(suite: EvaluationSuite, responses: [String]) -> EvaluationRun {
        let results = zip(suite.cases, responses).map { item, response in
            EvaluationSampleResult(caseID: item.id, caseName: item.name, repetition: 1,
                prompt: item.prompt, expected: item.expected, response: response,
                status: .unscored, score: nil, rationale: nil, durationMilliseconds: 10,
                usage: .init(), judgeDurationMilliseconds: nil, judgeUsage: nil,
                errorCategory: nil, errorMessage: nil, judgeErrorCategory: nil, judgeErrorMessage: nil)
        }
        return EvaluationRun(id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version,
            instructions: suite.instructions, criteria: suite.criteria, scoringMode: suite.scoringMode, repetitions: 1,
            judgePromptVersion: nil, judgePassingScore: nil, plannedSampleCount: results.count,
            suiteRevision: "fixture", plannedCases: suite.cases, startedAt: Date(), completedAt: Date(),
            cancelled: false, terminationReason: nil,
            environment: .init(operatingSystem: "Fixture", locale: "en", model: "Subject", modelContextSize: 4096),
            attachments: [], results: results)
    }
}

private actor ReassessmentCancellationTransport {
    let urlCancellation: Bool
    private(set) var callCount = 0

    init(urlCancellation: Bool) { self.urlCancellation = urlCancellation }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        callCount += 1
        if callCount == 2 {
            if urlCancellation { throw URLError(.cancelled) }
            throw CancellationError()
        }
        let verdict = #"{"requirements":[{"criterionIndex":1,"score":4,"rationale":"Supported by the saved evidence."}]}"#
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": verdict], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "cost": 0.125]
        ])
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil))
        return (body, response)
    }
}
