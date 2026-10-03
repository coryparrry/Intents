import Foundation
import Testing
@testable import FoundationEvals

struct StructuredFeatureEvidenceTests {
    @Test func structuredDeveloperEvidenceRoundTrips() throws {
        var sample = makeSample()
        sample.structuredFeatureEvidence = .init(
            encodedValue: Data(#"{"selectedNoteID":"packing-001"}"#.utf8),
            encodedValueTypeName: "FixtureSummary",
            metadata: ["fixture": "packing-notes-v1"]
        )

        let decoded = try JSONDecoder().decode(EvaluationSampleResult.self, from: JSONEncoder().encode(sample))
        #expect(decoded.structuredFeatureEvidence?.encodedValue == sample.structuredFeatureEvidence?.encodedValue)
        #expect(decoded.structuredFeatureEvidence?.encodedValueTypeName == "FixtureSummary")
        #expect(decoded.structuredFeatureEvidence?.metadata == ["fixture": "packing-notes-v1"])
    }

    @Test func oldSampleWithoutStructuredEvidenceStillLoads() throws {
        let data = try JSONEncoder().encode(makeSample())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "structuredFeatureEvidence")

        let decoded = try JSONDecoder().decode(
            EvaluationSampleResult.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.structuredFeatureEvidence == nil)
    }

    private func makeSample() -> EvaluationSampleResult {
        EvaluationSampleResult(
            caseID: UUID(), caseName: "Feature output", repetition: 1,
            prompt: "Summarize the packing note", effectivePrompt: nil,
            expected: "", response: "Pack the passport.", status: .unscored,
            score: nil, rationale: nil, durationMilliseconds: 12,
            usage: .init(), judgeDurationMilliseconds: nil, judgeUsage: nil,
            errorCategory: nil, errorMessage: nil, judgeErrorCategory: nil,
            judgeErrorMessage: nil
        )
    }
}
