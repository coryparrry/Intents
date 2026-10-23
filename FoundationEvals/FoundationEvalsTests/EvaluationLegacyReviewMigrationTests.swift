import CryptoKit
import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationLegacyReviewMigrationTests {
    @Test func oldLabelsProposalsAndLinkedJudgeSourcesUpgradeTogether() throws {
        let fixture = try legacyFixture()
        let decoded = try CanonicalJSON.decode(EvaluationSuiteLocalState.self, from: CanonicalJSON.data(for: fixture.state))
        #expect(decoded.review.annotations[0].sourceDigestVersion == nil)
        let sample = try #require(EvaluationReviewWorkflow.samples(runs: [fixture.run], suiteID: fixture.run.suiteID).first)
        #expect(!EvaluationReviewWorkflow.isCurrent(fixture.state.review.annotations[0], sample: sample))
        let migrated = try #require(try EvaluationReviewWorkflow.migratingLegacySources(in: decoded, runs: [fixture.run]))
        #expect(migrated.review.annotations[0].sourceDigestVersion == 2)
        #expect(migrated.review.annotations[0].sourceDigest == sample.sourceDigest)
        #expect(migrated.review.proposals[0].annotation.sourceDigest == sample.sourceDigest)
        #expect(migrated.review.proposals[0].status == .pending)
        #expect(migrated.reviewedJudgeExamples[0].reviewSource?.sourceDigest == sample.sourceDigest)
        #expect(migrated.review.annotations[0].id == fixture.state.review.annotations[0].id)
        #expect(migrated.review.annotations[0].updatedAt == fixture.state.review.annotations[0].updatedAt)
        #expect(EvaluationReviewWorkflow.patterns(samples: [sample], state: migrated.review).map(\.tag) == ["logic"])
        #expect(try EvaluationReviewWorkflow.migratingLegacySources(in: migrated, runs: [fixture.run]) == nil)
    }

    @Test func unavailableRunsRemainEligibleUntilTheirEvidenceIsRestored() throws {
        var available = try legacyFixture()
        let missing = try legacyFixture()
        var state = available.state
        state.review.annotations += missing.state.review.annotations
        state.review.proposals += missing.state.review.proposals
        state.reviewedJudgeExamples += missing.state.reviewedJudgeExamples
        let first = try #require(try EvaluationReviewWorkflow.migratingLegacySources(in: state, runs: [available.run]))
        #expect(first.review.annotations[0].sourceDigestVersion == 2)
        #expect(first.review.annotations[1].sourceDigestVersion == nil)
        #expect(first.review.proposals[1].annotation.sourceDigestVersion == nil)
        #expect(first.reviewedJudgeExamples[1].reviewSource == missing.state.reviewedJudgeExamples[0].reviewSource)
        #expect(try EvaluationReviewWorkflow.migratingLegacySources(in: first, runs: [available.run]) == nil)

        available.run.instructions += " changed after its migration"
        let restored = try #require(try EvaluationReviewWorkflow.migratingLegacySources(in: first, runs: [available.run, missing.run]))
        #expect(restored.review.annotations[0].sourceDigest == first.review.annotations[0].sourceDigest)
        let samples = EvaluationReviewWorkflow.samples(runs: [available.run], suiteID: available.run.suiteID)
        let availableSample = try #require(samples.first)
        #expect(!EvaluationReviewWorkflow.isCurrent(restored.review.annotations[0], sample: availableSample))
        let restoredSample = try #require(EvaluationReviewWorkflow.samples(runs: [missing.run], suiteID: missing.run.suiteID).first)
        #expect(restored.review.annotations[1].sourceDigestVersion == 2)
        #expect(EvaluationReviewWorkflow.isCurrent(restored.review.annotations[1], sample: restoredSample))
        #expect(restored.review.proposals[1].annotation.sourceDigest == restoredSample.sourceDigest)
        #expect(restored.reviewedJudgeExamples[1].reviewSource?.sourceDigest == restoredSample.sourceDigest)
    }

    @Test func changedOriginalEvidenceDoesNotResurrectAStaleLabel() throws {
        var fixture = try legacyFixture()
        fixture.run.results[0].response = "Changed recorded response"
        let migrated = try #require(try EvaluationReviewWorkflow.migratingLegacySources(in: fixture.state, runs: [fixture.run]))
        let sample = try #require(EvaluationReviewWorkflow.samples(runs: [fixture.run], suiteID: fixture.run.suiteID).first)
        #expect(migrated.review.annotations[0].sourceDigest == fixture.state.review.annotations[0].sourceDigest)
        #expect(!EvaluationReviewWorkflow.isCurrent(migrated.review.annotations[0], sample: sample))
        #expect(EvaluationReviewWorkflow.patterns(samples: [sample], state: migrated.review).isEmpty)
    }

    @Test(arguments: ["instructions", "attachments", "conversation"])
    func upgradedLabelsRemainBoundToPreviouslyUnhashedInputs(change: String) throws {
        var fixture = try legacyFixture()
        let migrated = try #require(try EvaluationReviewWorkflow.migratingLegacySources(in: fixture.state, runs: [fixture.run]))
        switch change {
        case "instructions": fixture.run.instructions += " changed"
        case "attachments": fixture.run.attachments.append(.init(name: "Reference", kind: .text, byteCount: 1, sha256: "changed"))
        default: fixture.run.plannedCases?[0].conversation.setupTurns = [.init(prompt: "Changed history")]
        }
        let sample = try #require(EvaluationReviewWorkflow.samples(runs: [fixture.run], suiteID: fixture.run.suiteID).first)
        #expect(!EvaluationReviewWorkflow.isCurrent(migrated.review.annotations[0], sample: sample))
        #expect(try EvaluationReviewWorkflow.migratingLegacySources(in: migrated, runs: [fixture.run]) == nil)
        var state = migrated.review
        #expect(throws: EvaluationReviewError.self) {
            try EvaluationReviewWorkflow.decideProposal(id: state.proposals[0].id, accept: true, sample: sample, state: &state)
        }
    }

    @MainActor @Test(arguments: [false, true])
    func persistedMigrationSurvivesReopenAndFailedWritesPreserveOldBytes(rejectWrite: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seed = EvaluationStore(supportDirectory: directory)
        var fixture = try legacyFixture(suite: seed.suite)
        fixture.run.projectID = seed.selectedProjectID
        let suiteDirectory = EvaluationWorkspacePersistence.suiteDirectory(supportDirectory: directory,
            projectID: seed.selectedProjectID, suiteID: seed.selectedSuiteID)
        await seed.closeAndWait()
        let stateURL = suiteDirectory.appending(path: "state.json")
        let runURL = suiteDirectory.appending(path: "Runs/\(fixture.run.id.uuidString).json")
        let oldBytes = try CanonicalJSON.data(for: fixture.state)
        try oldBytes.write(to: stateURL, options: .atomic)
        try CanonicalJSON.data(for: fixture.run).write(to: runURL, options: .atomic)
        let loaded = EvaluationStore(supportDirectory: directory, suiteLocalStateWriter: { data, url in
            if rejectWrite { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        if rejectWrite {
            #expect(try Data(contentsOf: stateURL) == oldBytes)
            #expect(loaded.suiteLocalState.review.annotations[0].sourceDigestVersion == nil)
            #expect(loaded.notice != nil)
        } else {
            #expect(loaded.suiteLocalState.review.annotations[0].sourceDigestVersion == 2)
            #expect(EvaluationReviewWorkflow.patterns(samples: loaded.reviewSamples, state: loaded.suiteLocalState.review).map(\.tag) == ["logic"])
        }
        await loaded.closeAndWait()
        let reopened = EvaluationStore(supportDirectory: directory)
        #expect(EvaluationReviewWorkflow.patterns(samples: reopened.reviewSamples, state: reopened.suiteLocalState.review).map(\.tag) == ["logic"])
        let persisted = try CanonicalJSON.decode(EvaluationSuiteLocalState.self, from: Data(contentsOf: stateURL))
        #expect(persisted.review.annotations[0].sourceDigestVersion == 2)
        await reopened.closeAndWait()
        fixture.run.instructions += " changed after migration"
        try CanonicalJSON.data(for: fixture.run).write(to: runURL, options: .atomic)
        let changed = EvaluationStore(supportDirectory: directory)
        #expect(EvaluationReviewWorkflow.patterns(samples: changed.reviewSamples, state: changed.suiteLocalState.review).isEmpty)
        await changed.closeAndWait()
    }

    private func legacyFixture(suite supplied: EvaluationSuite? = nil) throws -> (run: EvaluationRun, state: EvaluationSuiteLocalState) {
        var suite = supplied ?? EvaluationSuite()
        if suite.cases.isEmpty { suite.cases = [.init(name: "Case", prompt: "Question", expected: "READY")] }
        let item = suite.cases[0]
        let sample = EvaluationSampleResult(caseID: item.id, caseName: item.name, repetition: 1,
            prompt: item.prompt, expected: item.expected, response: "incorrect", status: .unscored,
            score: nil, rationale: nil, durationMilliseconds: 1, usage: .init())
        var run = EvaluationRun(id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version,
            instructions: suite.instructions, criteria: suite.criteria, scoringMode: suite.scoringMode,
            repetitions: suite.repetitions, startedAt: Date(timeIntervalSince1970: 1), completedAt: Date(timeIntervalSince1970: 2),
            cancelled: false, environment: .init(operatingSystem: "macOS 27", locale: "en_GB", model: "Fixture", modelContextSize: 4096),
            attachments: [], results: [sample])
        run.plannedCases = suite.cases
        // Reproduce the pre-upgrade wire shape independently of the current digest implementation.
        struct V1Source: Encodable {
            var runID: UUID
            var sample: EvaluationSampleResult
            var subjectEvidence: EvaluationSubjectEvidenceSnapshot? = nil
            var subjectContext: String? = nil
            var environment: EvaluationEnvironment
            var execution: EvaluationExecutionTrace? = nil
            var developerExecution: EvaluationDeveloperExecution? = nil
        }
        let oldDigest = SHA256.hash(data: try CanonicalJSON.data(for: V1Source(runID: run.id,
            sample: sample, environment: run.environment), prettyPrinted: false)).map { String(format: "%02x", $0) }.joined()
        var annotation = EvaluationReviewAnnotation(id: UUID(), runID: run.id, sampleID: sample.id,
            sourceDigest: oldDigest, verdict: .failed, note: "Wrong answer", tags: ["logic"], updatedAt: Date(timeIntervalSince1970: 3))
        annotation.sourceDigestVersion = nil
        var proposalAnnotation = annotation
        proposalAnnotation.id = UUID()
        var state = EvaluationSuiteLocalState()
        state.review.annotations = [annotation]
        state.review.proposals = [.init(id: UUID(), annotation: proposalAnnotation)]
        state.reviewedJudgeExamples = [.init(reviewSource: .init(reviewID: annotation.id, runID: run.id,
            sampleID: sample.id, sourceDigest: oldDigest), id: UUID(), sourceRunID: run.id,
            sourceAssessmentID: UUID(), sampleID: sample.id, expectedStatus: .failed, reason: "Wrong answer",
            createdAt: Date(timeIntervalSince1970: 3))]
        return (run, state)
    }
}
