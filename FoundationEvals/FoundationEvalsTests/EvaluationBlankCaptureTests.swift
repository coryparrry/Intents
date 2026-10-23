import Foundation
import Testing
@testable import FoundationEvals

private actor BlankCaptureJudgeTransport {
    private(set) var requestCount = 0

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requestCount += 1
        let verdict = "{\"requirements\":[{\"criterionIndex\":1,\"score\":1,\"rationale\":\"The captured response does not satisfy the semantic requirement.\"}]}"
        let data = try JSONSerialization.data(withJSONObject: [
            "model": "blank-capture-judge",
            "choices": [["message": ["role": "assistant", "content": verdict], "finish_reason": "stop"]]
        ])
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        ))
        return (data, response)
    }
}

struct EvaluationBlankCaptureTests {
    @Test(arguments: ["", " ", "READY"], [false, true])
    func successfulFeatureCaptureSurvivesSavingAndExactAssessment(response: String, initial: Bool) async throws {
        let literal = try #require(String(data: JSONEncoder().encode(response), encoding: .utf8))
        let suite = suite(criteria: "exact: \(literal)")
        let run = try await savedFeatureRun(suite: suite, response: response)
        let sample = try #require(run.results.first)
        #expect(sample.response == response)
        #expect(sample.responseWasCaptured == true)
        #expect(sample.errorCategory == nil)
        #expect(sample.errorMessage == nil)
        #expect(sample.hasCompleteSubjectEvidenceForJudging)
        let client = EvaluationCompatibleJudgeClient(transport: { _ in
            Issue.record("Exact checks must not invoke a model or network transport.")
            throw CancellationError()
        })

        let assessment = try await EvaluationReassessmentService(client: client).reassess(
            run: run, suite: suite, images: [], resolved: nil,
            origin: initial ? .initialRun : .reassessment
        )

        #expect(assessment.samples.first?.status == .passed)
        #expect(assessment.samples.first?.score == 4)
        #expect(assessment.samples.first?.errorCategory == nil)
        #expect(assessment.samples.first?.trace?.judgedCriterionIndexes == [])
    }

    @Test func successfullyCapturedBlankDoesNotPassAnUnmatchedExactRequirement() async throws {
        let suite = suite(criteria: #"exact: "READY""#)
        let run = try await savedFeatureRun(suite: suite, response: "")

        let assessment = try await EvaluationReassessmentService().reassess(
            run: run, suite: suite, images: [], resolved: nil
        )

        #expect(assessment.samples.first?.status == .failed)
        #expect(assessment.samples.first?.errorCategory == nil)
    }

    @Test(arguments: ["", " ", "READY"])
    func successfulFeatureCaptureReachesSemanticJudge(response: String) async throws {
        var suite = suite(criteria: "The response explains the requested fact.")
        var connection = EvaluationJudgeConnection(
            id: UUID(), name: "Injected transport", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1/v1", modelID: "blank-capture-judge"
        )
        connection.generationPolicy = .portable
        suite.judgeConfiguration = .init(
            mode: .connection, connectionID: connection.id,
            externalEvidenceApprovedAt: Date(), includeReferenceAttachments: false,
            approvedConnectionID: connection.id, approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest,
            approvedEvidencePolicyVersion: EvaluationJudgeConfiguration.currentEvidencePolicyVersion
        )
        let run = try await savedFeatureRun(suite: suite, response: response)
        let transport = BlankCaptureJudgeTransport()
        let client = EvaluationCompatibleJudgeClient(transport: { try await transport.send($0) })

        let assessment = try await EvaluationReassessmentService(client: client).reassess(
            run: run, suite: suite, images: [], resolved: .init(connection: connection, apiKey: nil)
        )

        #expect(await transport.requestCount == 1)
        #expect(assessment.samples.first?.status == .failed)
        #expect(assessment.samples.first?.score == 1)
        #expect(assessment.samples.first?.errorCategory == nil)
        #expect(assessment.samples.first?.trace?.judgedCriterionIndexes == [1])
    }

    @Test(arguments: [false, true])
    func failedOrLateCancelledFeatureCaptureRemainsUnavailable(lateCancellation: Bool) async throws {
        let suite = suite(criteria: #"exact: """#)
        let run = try await savedFeatureRun(
            suite: suite, response: "", fail: !lateCancellation, cancelBeforeReturn: lateCancellation
        )
        let sample = try #require(run.results.first)
        #expect(sample.status == .error)
        #expect(sample.responseWasCaptured == nil)
        #expect(sample.errorCategory == (lateCancellation ? "lateAfterCancellation" : "featureAdapterFailure"))
        #expect(!sample.hasCompleteSubjectEvidenceForJudging)

        let assessment = try await EvaluationReassessmentService().reassess(
            run: run, suite: suite, images: [], resolved: nil
        )

        #expect(assessment.samples.first?.status == .unscored)
        #expect(assessment.samples.first?.errorCategory == "incompleteSavedEvidence")
    }

    private func suite(criteria: String) -> EvaluationSuite {
        var suite = EvaluationSuite()
        suite.scoringMode = .modelJudge
        suite.criteria = criteria
        suite.repetitions = 1
        suite.cases = [.init(name: "Captured response", prompt: "Return the requested response.", expected: "")]
        return suite
    }

    private func savedFeatureRun(
        suite: EvaluationSuite, response: String, fail: Bool = false, cancelBeforeReturn: Bool = false
    ) async throws -> EvaluationRun {
        let adapter = ClosureFeatureAdapter(displayName: "Deterministic capture") { _ in
            if fail { throw URLError(.cannotDecodeContentData) }
            if cancelBeforeReturn { withUnsafeCurrentTask { $0?.cancel() } }
            return response
        }
        // Isolate intentional cancellation from the test's assessment task.
        let run = await Task {
            await EvaluationFeatureAdapterRunner().run(suiteRevision: "blank-capture-fixture", suite: suite, adapter: adapter)
        }.value
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "EvaluationBlankCaptureTests-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "saved-run.json")
        try CanonicalJSON.data(for: run).write(to: url)
        return try CanonicalJSON.decode(EvaluationRun.self, from: Data(contentsOf: url))
    }
}
