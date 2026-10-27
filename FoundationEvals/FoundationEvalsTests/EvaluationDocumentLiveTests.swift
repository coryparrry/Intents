import Foundation
import Testing
@testable import FoundationEvals

/// Opt-in device evidence, deliberately separate from deterministic CI coverage.
struct EvaluationDocumentLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_LIVE_SMOKE"] == "1",
                   "Requires an available on-device model and explicit live-smoke opt-in."))
    func inspectSyntheticCandidate() async throws {
        let candidate = try await EvaluationDocumentGenerator.candidate(source: DocumentTestFixture.source, passage: DocumentTestFixture.passage,
            questionType: "Apply a rule", existingQuestions: [])
        print("DOCUMENT_LIVE_CANDIDATE supported=\(candidate.supported) name=\(candidate.name) question=\(candidate.question) answer=\(candidate.answer) criteria=\(candidate.criteria) quotes=\(candidate.quotes)")
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTENTS_DOCUMENT_LIVE_SMOKE"] == "1",
                   "Requires an available on-device model and explicit live-smoke opt-in."))
    func boundedBatchPreservesFullYieldAndRunsFirstDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "document-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = UUID()
        let controller = EvaluationDocumentDraftController(directory: directory, projectID: projectID)
        controller.draft = .init(projectID: projectID, name: "Synthetic permissions guide",
            source: DocumentTestFixture.source, selectedPassageIDs: [DocumentTestFixture.passage.id], requestedCount: 5)
        controller.generate()
        await controller.waitUntilIdle()
        let draft = try #require(controller.draft)
        print("DOCUMENT_LIVE_BATCH " + String(decoding: try CanonicalJSON.data(for: draft), as: UTF8.self))
        #expect(controller.error == nil)
        #expect(draft.completedBatchIDs.union(Set(draft.issues.keys)).count <= 10)
        var first = try #require(draft.cases.first?.evaluationCase)
        // Only this isolated synthetic fixture is approved by the test.
        first.acceptDocumentReview()
        var suite = DocumentTestFixture.suite()
        suite.cases = [first]
        let run = await EvaluationRunner().run(id: UUID(), suiteRevision: "document-live-batch",
            startedAt: Date(), suite: suite, images: [], progress: { _, _, _ in })
        print("DOCUMENT_LIVE_BATCH_RUN " + String(decoding: try CanonicalJSON.data(for: run), as: UTF8.self))
        #expect(run.results.count == 1)
        #expect(run.errorCount == 0)
        #expect(run.scoredCount == 1)
    }

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
