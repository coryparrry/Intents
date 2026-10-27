import Foundation
import Testing
@testable import FoundationEvals

/// Opt-in device evidence, deliberately separate from deterministic CI coverage.
struct EvaluationDocumentLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_LIVE_SMOKE"] == "1",
                   "Requires an available on-device model and explicit live-smoke opt-in."))
    func generateAndRunOneDocumentCaseOnDevice() async throws {
        #expect(EvaluationDocumentGenerator.availabilityIssue == nil)
        let generated = try #require(try await EvaluationDocumentGenerator.generate(
            source: DocumentTestFixture.source, passage: DocumentTestFixture.passage,
            questionType: "Apply a rule", existingQuestions: []))
        print("DOCUMENT_LIVE_DRAFT " + String(decoding: try CanonicalJSON.data(for: generated), as: UTF8.self))
        var suite = DocumentTestFixture.suite()
        // This is an isolated synthetic test fixture, not approval of a user's generated cases.
        var fixture = generated
        fixture.acceptDocumentReview()
        suite.cases = [fixture]
        let run = await EvaluationRunner().run(id: UUID(), suiteRevision: "document-live-smoke",
            startedAt: Date(), suite: suite, images: [], progress: { _, _, _ in })
        print("DOCUMENT_LIVE_RUN " + String(decoding: try CanonicalJSON.data(for: run), as: UTF8.self))
        #expect(run.results.count == 1)
        #expect(run.errorCount == 0)
        #expect(run.scoredCount == 1)
    }
}
