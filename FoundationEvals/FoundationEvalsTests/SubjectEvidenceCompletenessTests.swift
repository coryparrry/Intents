import Foundation
import Testing
@testable import FoundationEvals

struct SubjectEvidenceCompletenessTests {
    @Test func generationErrorMessageMakesPartialResponseIncompleteWithoutCategory() {
        let result = sample(response: "Partial response", errorMessage: "Generation stopped")

        #expect(!result.hasCompleteSubjectEvidenceForJudging)
    }

    @Test func normalCompleteResponseIsComplete() {
        let result = sample(response: "Complete response")

        #expect(result.hasCompleteSubjectEvidenceForJudging)
    }

    @Test func judgeOnlyErrorDoesNotInvalidateCompleteSubjectEvidence() {
        let result = sample(
            response: "Complete response",
            status: .error,
            judgeErrorCategory: "judgeUnavailable",
            judgeErrorMessage: "The judge could not be reached"
        )

        #expect(result.hasCompleteSubjectEvidenceForJudging)
    }

    @Test(arguments: ["", " ", "\n\t"])
    func legacyBlankResponseDoesNotProveCapture(response: String) {
        #expect(!sample(response: response).hasCompleteSubjectEvidenceForJudging)
    }

    @Test(arguments: ["", " ", "\n\t"])
    func capturedBlankResponseIsCompleteEvenAfterJudgeError(response: String) throws {
        let result = sample(
            response: response, responseWasCaptured: true, status: .error,
            judgeErrorCategory: "judgeUnavailable", judgeErrorMessage: "Judge unavailable"
        )
        let saved = try CanonicalJSON.data(for: result, prettyPrinted: false)
        let decoded = try CanonicalJSON.decode(EvaluationSampleResult.self, from: saved)

        #expect(decoded.responseWasCaptured == true)
        #expect(decoded.response == response)
        #expect(decoded.hasCompleteSubjectEvidenceForJudging)
    }

    @Test(arguments: ["", "Partial response"], [false, true])
    func captureMarkerCannotOverrideSubjectErrors(response: String, messageOnly: Bool) {
        let result = sample(
            response: response, responseWasCaptured: true, status: .error,
            errorCategory: messageOnly ? nil : "cancelled",
            errorMessage: messageOnly ? "Generation stopped" : nil
        )

        #expect(!result.hasCompleteSubjectEvidenceForJudging)
    }

    @Test(arguments: ["", " ", "Complete response"])
    func legacyEncodingOmitsCaptureMarkerAndRoundTripsUnchanged(response: String) throws {
        let result = sample(response: response)
        let saved = try CanonicalJSON.data(for: result, prettyPrinted: false)
        let object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(object["responseWasCaptured"] == nil)
        let decoded = try CanonicalJSON.decode(EvaluationSampleResult.self, from: saved)

        #expect(decoded.responseWasCaptured == nil)
        #expect(decoded.hasCompleteSubjectEvidenceForJudging == !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(try CanonicalJSON.data(for: decoded, prettyPrinted: false) == saved)
    }

    @Test func falseCaptureMarkerDoesNotProveBlankCapture() throws {
        let result = sample(response: "", responseWasCaptured: false)
        let decoded = try CanonicalJSON.decode(
            EvaluationSampleResult.self, from: CanonicalJSON.data(for: result)
        )
        #expect(decoded.responseWasCaptured == false)
        #expect(!decoded.hasCompleteSubjectEvidenceForJudging)
    }

    private func sample(
        response: String,
        responseWasCaptured: Bool? = nil,
        status: EvaluationResultStatus = .passed,
        errorCategory: String? = nil,
        errorMessage: String? = nil,
        judgeErrorCategory: String? = nil,
        judgeErrorMessage: String? = nil
    ) -> EvaluationSampleResult {
        EvaluationSampleResult(
            caseID: UUID(),
            caseName: "Subject evidence",
            repetition: 1,
            prompt: "Prompt",
            expected: "Expected",
            response: response,
            responseWasCaptured: responseWasCaptured,
            status: status,
            score: nil,
            rationale: nil,
            durationMilliseconds: 1,
            usage: EvaluationUsage(),
            errorCategory: errorCategory,
            errorMessage: errorMessage,
            judgeErrorCategory: judgeErrorCategory,
            judgeErrorMessage: judgeErrorMessage
        )
    }
}
