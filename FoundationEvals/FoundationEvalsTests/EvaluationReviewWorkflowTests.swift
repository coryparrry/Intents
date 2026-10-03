import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationReviewWorkflowTests {
    @Test func legacyStateAndCaseDecodeWithoutReviewFields() throws {
        var value = try JSONSerialization.jsonObject(with: CanonicalJSON.data(for: EvaluationSuiteLocalState())) as! [String: Any]
        value.removeValue(forKey: "review")
        let state = try CanonicalJSON.decode(EvaluationSuiteLocalState.self, from: JSONSerialization.data(withJSONObject: value))
        #expect(state.review.annotations.isEmpty)
        let original = EvaluationCase(name: "Old", prompt: "Question", expected: "Answer")
        let decoded = try CanonicalJSON.decode(EvaluationCase.self, from: CanonicalJSON.data(for: original))
        #expect(decoded.reviewSource == nil)
    }

    @Test func unscoredHumanReviewPreservesOriginalOutputAndJudge() throws {
        let fixture = try ReviewFixture()
        var state = EvaluationReviewState()
        let review = fixture.annotation(verdict: .failed, tags: [" Wrong DATE ", "wrong date"])
        try EvaluationReviewWorkflow.save(review, sample: fixture.sample, state: &state)
        #expect(state.annotations.first?.tags == ["wrong date"])
        #expect(fixture.sample.sample.status == .unscored)
        #expect(fixture.sample.sample.response == "incorrect")
        var reassessed = fixture.run
        reassessed.selectedAssessmentID = UUID()
        #expect(try EvaluationReviewWorkflow.sourceDigest(run: reassessed, sample: fixture.sample.sample) == fixture.sample.sourceDigest)
    }

    @Test func missingAlteredOrIncompleteEvidenceCannotBeConfirmed() throws {
        var fixture = try ReviewFixture()
        var review = fixture.annotation(verdict: .failed)
        review.sourceDigest = "changed"
        #expect(throws: EvaluationReviewError.self) { try EvaluationReviewWorkflow.validated(review, sample: fixture.sample) }
        fixture.run.results[0].errorMessage = "Unavailable"
        let errored = fixture.sample
        let invalid = fixture.annotation(verdict: .passed)
        #expect(throws: EvaluationReviewError.self) { try EvaluationReviewWorkflow.validated(invalid, sample: errored) }
        let undecided = fixture.annotation(verdict: .needsEvidence)
        #expect(try EvaluationReviewWorkflow.validated(undecided, sample: errored).verdict == .needsEvidence)
        fixture.run.subjectEvidence?.digest = "invalid"
        #expect(!EvaluationReviewWorkflow.isCurrent(undecided, sample: fixture.sample))
    }

    @Test func textAndTagLimitsAndReviewIdentityAreEnforced() throws {
        let fixture = try ReviewFixture()
        var review = fixture.annotation(verdict: .failed)
        review.note = String(repeating: "x", count: 4_001)
        #expect(throws: EvaluationReviewError.self) { try EvaluationReviewWorkflow.validated(review, sample: fixture.sample) }
        review.note = "Specific failure"
        review.tags = (0..<7).map { "tag \($0)" }
        #expect(throws: EvaluationReviewError.self) { try EvaluationReviewWorkflow.validated(review, sample: fixture.sample) }
        review.tags = []
        var state = EvaluationReviewState()
        try EvaluationReviewWorkflow.save(review, sample: fixture.sample, state: &state)
        var other = try ReviewFixture()
        other.run.results[0].id = UUID()
        var collision = other.annotation(verdict: .failed)
        collision.id = review.id
        #expect(throws: EvaluationReviewError.self) { try EvaluationReviewWorkflow.save(collision, sample: other.sample, state: &state) }
    }

    @Test func suggestionsEnterPatternsOnlyAfterHumanAcceptance() throws {
        let fixture = try ReviewFixture()
        let proposal = EvaluationReviewProposal(id: UUID(), annotation: fixture.annotation(verdict: .failed, tags: ["wrong date"]))
        var state = EvaluationReviewState()
        try EvaluationReviewWorkflow.propose(proposal, sample: fixture.sample, state: &state)
        #expect(EvaluationReviewWorkflow.patterns(samples: [fixture.sample], state: state).isEmpty)
        try EvaluationReviewWorkflow.decideProposal(id: proposal.id, accept: true, sample: fixture.sample, state: &state)
        #expect(state.proposals.first?.status == .accepted)
        #expect(EvaluationReviewWorkflow.patterns(samples: [fixture.sample], state: state).first?.caseCount == 1)
        #expect(throws: EvaluationReviewError.self) { try EvaluationReviewWorkflow.decideProposal(id: proposal.id, accept: true, sample: fixture.sample, state: &state) }
        var changed = fixture
        changed.run.results[0].response = "different"
        #expect(EvaluationReviewWorkflow.patterns(samples: [changed.sample], state: state).isEmpty)
    }

    @Test func diverseQueueIsStableUniqueAndIncludesSuccessesAndAllCases() throws {
        var fixture = try ReviewFixture()
        var samples: [EvaluationReviewSample] = []
        for index in 0..<20 {
            fixture.run.id = UUID()
            fixture.run.results[0].id = UUID()
            fixture.run.results[0].caseID = fixture.suite.cases[0].id
            fixture.run.results[0].status = index % 2 == 0 ? .passed : .failed
            samples.append(fixture.sample)
        }
        let other = try ReviewFixture()
        samples.append(other.sample)
        let first = EvaluationReviewWorkflow.diverseQueue(samples)
        #expect(first.map(\.id) == EvaluationReviewWorkflow.diverseQueue(samples).map(\.id))
        #expect(Set(first.map(\.id)).count == samples.count)
        #expect(Set(first.prefix(4).map { $0.sample.caseID }).count == 2)
        #expect(first.contains { $0.sample.status == .passed })
    }

    @Test func promotionPreservesContextAndRequiresCorrectExpectedAnswer() throws {
        var fixture = try ReviewFixture()
        fixture.suite.cases[0].conversation.setupTurns = [.init(prompt: "Remember Alex")]
        fixture.suite.cases[0].fieldAssertions = [.init(pointer: "/date", operation: .exists)]
        try fixture.refresh()
        let review = fixture.annotation(verdict: .failed)
        let regression = try EvaluationReviewWorkflow.regression(annotation: review, sample: fixture.sample, suite: fixture.suite, expected: "correct")
        #expect(regression.id != fixture.suite.cases[0].id)
        #expect(regression.expected == "correct")
        #expect(regression.conversation == fixture.suite.cases[0].conversation)
        #expect(regression.fieldAssertions == fixture.suite.cases[0].fieldAssertions)
        #expect(regression.reviewSource?.sourceDigest == fixture.sample.sourceDigest)
        #expect(throws: EvaluationReviewError.self) {
            try EvaluationReviewWorkflow.regression(annotation: review, sample: fixture.sample, suite: fixture.suite, expected: "")
        }
        var changed = fixture.suite
        changed.instructions = "Different context"
        #expect(throws: EvaluationReviewError.self) {
            try EvaluationReviewWorkflow.regression(annotation: review, sample: fixture.sample, suite: changed, expected: "correct")
        }
        changed = fixture.suite
        changed.repetitions = 100
        #expect(throws: EvaluationReviewError.self) {
            try EvaluationReviewWorkflow.regression(annotation: review, sample: fixture.sample, suite: changed, expected: "correct")
        }
    }

    @Test func calibrationSeparatesContractsPartitionsAndUnavailableResults() throws {
        let fixture = try ReviewFixture()
        let contract = try EvaluationScoringContract(suite: fixture.suite)
        func result(expected: EvaluationResultStatus, actual: EvaluationResultStatus,
                    partition: EvaluationJudgeCheckPartition = .test, error: String? = nil) -> EvaluationJudgeCheckResult {
            let example = EvaluationReviewedJudgeExample(partition: partition, id: UUID(), sourceRunID: fixture.run.id,
                sourceAssessmentID: UUID(), sampleID: fixture.sample.sample.id, expectedStatus: expected,
                reason: "Human label", createdAt: Date(), scoringContract: contract)
            return .init(example: example, actualStatus: actual, passed: expected == actual, errorMessage: error)
        }
        let report = EvaluationJudgeCheckReport(connectionID: UUID(), results: [
            result(expected: .failed, actual: .passed), result(expected: .failed, actual: .failed),
            result(expected: .passed, actual: .failed), result(expected: .passed, actual: .passed),
            result(expected: .failed, actual: .unscored, error: "Timeout"),
            result(expected: .passed, actual: .passed, partition: .development)
        ])
        let heldOut = try #require(report.calibrationGroups.first { $0.partition == .test })
        #expect(heldOut.falsePassRate == 0.5)
        #expect(heldOut.falseFailureRate == 0.5)
        #expect(heldOut.unavailable == 1)
        #expect(heldOut.hasBothClasses)
        #expect(report.calibrationGroups.first { $0.partition == .development }?.falsePassRate == nil)
        var unknown = report.results[0]
        unknown.example.scoringContract = nil
        let legacy = EvaluationJudgeCheckReport(connectionID: UUID(), results: [unknown]).calibrationGroups[0]
        #expect(legacy.unavailable == 1)
        #expect(legacy.falsePassRate == nil)
    }

    @MainActor @Test func reviewPersistsAndFailedWriteRollsBack() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var failWrites = false
        let store = EvaluationStore(supportDirectory: directory, suiteLocalStateWriter: { data, url in
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        var fixture = try ReviewFixture(suite: store.suite)
        store.runs = [fixture.run]
        let review = fixture.annotation(verdict: .failed)
        try store.saveReview(review)
        failWrites = true
        var changed = review; changed.note = "A replacement review"
        #expect(throws: EvaluationStoreError.self) { try store.saveReview(changed) }
        #expect(store.suiteLocalState.review.annotations.first?.note == review.note)
        let loaded = EvaluationStore(supportDirectory: directory)
        #expect(loaded.suiteLocalState.review.annotations.first?.note == review.note)
        #expect(store.runs[0].results[0].status == .unscored)
        fixture.run.results[0].id = UUID()
        #expect(throws: EvaluationReviewError.self) { try store.saveReview(fixture.annotation(verdict: .failed)) }
    }

    @MainActor @Test func regressionIsDurableDeduplicatedAndDoesNotOverwriteDraftEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .modelJudge
        #expect(store.saveSuite())
        let fixture = try ReviewFixture(suite: store.suite)
        store.runs = [fixture.run]
        let annotation = fixture.annotation(verdict: .failed)
        try store.saveReview(annotation)
        store.draftSuite.name = "A user's unsaved name"
        let caseID = try store.promoteReviewToCase(reviewID: annotation.id, expected: "correct")
        #expect(store.suite.name == "A user's unsaved name")
        #expect(store.suite.cases.last?.id == caseID)
        #expect(try store.promoteReviewToCase(reviewID: annotation.id, expected: "different") == caseID)
        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.suite.cases.last?.reviewSource?.reviewID == annotation.id)
    }

    @Test func partitionChangesMoveEveryRepetitionAndRunOfACase() throws {
        var fixture = try ReviewFixture()
        let first = fixture.run
        fixture.run.id = UUID(); fixture.run.results[0].id = UUID()
        var state = EvaluationSuiteLocalState()
        for run in [first, fixture.run] {
            state.reviewedJudgeExamples.append(.init(id: UUID(), sourceRunID: run.id, sourceAssessmentID: UUID(),
                sampleID: run.results[0].id, expectedStatus: .failed, reason: "Human label", createdAt: Date()))
        }
        try EvaluationReviewJudgePartitions.assign(.test, caseID: first.results[0].caseID, state: &state, runs: [first, fixture.run])
        #expect(state.reviewedJudgeExamples.allSatisfy { $0.partition == .test })
    }

    @MainActor @Test func agentProposalsAreBoundedIdempotentAndCannotConfirmLabels() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let fixture = try ReviewFixture(suite: store.suite)
        store.runs = [fixture.run]
        let arguments = MCPReviewProposalArguments(suiteID: store.selectedSuiteID, proposalID: UUID(),
            runID: fixture.run.id, sampleID: fixture.sample.sample.id, sourceDigest: fixture.sample.sourceDigest,
            verdict: .failed, note: "Wrong entity selected", tags: ["wrong entity"])
        let parsed = try MCPToolCatalog.parse(name: "eval_propose_review", arguments: .encode(arguments))
        let authority = MCPStoreAuthority.make(store: store)
        let first = await authority.call(parsed)
        #expect(!first.isError)
        #expect(first.structuredContent.objectValue?["outcome"] == .string("committed"))
        #expect(store.suiteLocalState.review.annotations.isEmpty)
        #expect(store.suiteLocalState.review.proposals.first?.status == .pending)
        let retry = await authority.call(parsed)
        #expect(retry.structuredContent.objectValue?["outcome"] == .string("duplicate"))
        var changed = arguments; changed.note = "Different proposal"
        #expect(throws: EvaluationReviewError.self) { try EvaluationReviewMCP.propose(changed, store: store) }
    }

    @Test func reviewMCPRejectsUnboundedPagesAndUnknownApprovalFields() throws {
        let arguments = MCPReviewSamplesArguments(suiteID: UUID(), offset: 0, limit: 21)
        #expect(throws: MCPToolInputError.self) {
            try MCPToolCatalog.parse(name: "eval_list_review_samples", arguments: .encode(arguments))
        }
        let malformed: MCPJSONValue = .object(["suiteID": .string(UUID().uuidString), "accept": .bool(true)])
        #expect(throws: MCPToolInputError.self) {
            try MCPToolCatalog.parse(name: "eval_list_review_samples", arguments: malformed)
        }
    }

    @Test func sourceDigestIncludesSubjectDefinitionButIgnoresJudgeConfiguration() throws {
        var fixture = try ReviewFixture()
        let before = fixture.sample.sourceDigest
        fixture.run.suiteDefinition?.judgeConfiguration.connectionID = UUID()
        fixture.run.suiteDefinition?.criteria = "A changed rubric"
        #expect(fixture.sample.sourceDigest == before)
        fixture.run.suiteDefinition?.features.streamResponse.toggle()
        #expect(fixture.sample.sourceDigest != before)
    }

    @Test func judgeLabelsCannotReplayAgainstChangedOutputs() throws {
        var fixture = try ReviewFixture()
        let review = fixture.annotation(verdict: .failed)
        let example = EvaluationReviewedJudgeExample(reviewSource: .init(reviewID: review.id, runID: review.runID,
            sampleID: review.sampleID, sourceDigest: review.sourceDigest), id: UUID(), sourceRunID: review.runID,
            sourceAssessmentID: UUID(), sampleID: review.sampleID, expectedStatus: .failed, reason: review.note, createdAt: Date())
        try EvaluationReviewWorkflow.validateJudgeSource(example, run: fixture.run)
        fixture.run.results[0].response = "A different output"
        #expect(throws: EvaluationReviewError.self) { try EvaluationReviewWorkflow.validateJudgeSource(example, run: fixture.run) }
    }

    @Test func localSearchContextRequiresHistoricalIdentity() throws {
        var fixture = try ReviewFixture()
        fixture.suite.features.spotlightSearch.enabled = true
        fixture.suite.features.spotlightSearch.fileSource.folderPath = "/first-source"
        try fixture.refresh()
        var review = fixture.annotation(verdict: .failed)
        #expect(throws: EvaluationReviewError.self) {
            try EvaluationReviewWorkflow.regression(annotation: review, sample: fixture.sample, suite: fixture.suite, expected: "correct")
        }
        fixture.run.execution = .init(behaviorVersion: "fixture", configuration: fixture.suite.modelConfiguration,
            modelDisplayName: "Fixture", capabilities: [], toolNames: [], features: fixture.suite.features)
        review = fixture.annotation(verdict: .failed)
        _ = try EvaluationReviewWorkflow.regression(annotation: review, sample: fixture.sample, suite: fixture.suite, expected: "correct")
        fixture.suite.features.spotlightSearch.fileSource.folderPath = "/different-source"
        #expect(throws: EvaluationReviewError.self) {
            try EvaluationReviewWorkflow.regression(annotation: review, sample: fixture.sample, suite: fixture.suite, expected: "correct")
        }
    }

    @Test func clearingCoreAIResourcesCannotBypassHistoricalContext() throws {
        var fixture = try ReviewFixture()
        fixture.suite.modelConfiguration.provider = .coreAI
        fixture.suite.modelConfiguration.coreAI = .init(resourcesPath: "/original-model")
        try fixture.refresh()
        fixture.run.execution = .init(behaviorVersion: "fixture", configuration: fixture.suite.modelConfiguration,
            modelDisplayName: "Core AI", capabilities: [], toolNames: [], features: fixture.suite.features)
        let review = fixture.annotation(verdict: .failed)
        _ = try EvaluationReviewWorkflow.regression(annotation: review, sample: fixture.sample, suite: fixture.suite, expected: "correct")
        fixture.suite.modelConfiguration.coreAI?.clearResources()
        #expect(throws: EvaluationReviewError.self) {
            try EvaluationReviewWorkflow.regression(annotation: review, sample: fixture.sample, suite: fixture.suite, expected: "correct")
        }
    }

    @MainActor @Test func reviewDraftsSurviveNavigationAndRelaunchWithoutBecomingLabels() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var fixture = try ReviewFixture()
        let key = EvaluationReviewDraftStore.key(for: fixture.sample)
        let drafts = EvaluationReviewDraftStore(directory: directory)
        let draft = EvaluationReviewDraftStore.Draft(reviewID: UUID(), verdict: .failed, note: "Unfinished note", tags: "wrong date")
        drafts.update(draft, for: key); drafts.flush(key)
        #expect(drafts.draft(for: key) == draft)
        let reloaded = EvaluationReviewDraftStore(directory: directory)
        #expect(reloaded.draft(for: key) == draft)
        fixture.run.results[0].response = "Changed source"
        #expect(reloaded.draft(for: EvaluationReviewDraftStore.key(for: fixture.sample)) == nil)
        try reloaded.clear(key)
        #expect(EvaluationReviewDraftStore(directory: directory).draft(for: key) == nil)
    }

    @MainActor @Test func failedDraftWriteKeepsTheUnfinishedReviewInMemory() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("Existing file".utf8).write(to: file)
        let drafts = EvaluationReviewDraftStore(directory: file)
        let key = EvaluationReviewDraftStore.key(for: try ReviewFixture().sample)
        let draft = EvaluationReviewDraftStore.Draft(reviewID: UUID(), verdict: .failed, note: "Keep this note", tags: "date")
        drafts.update(draft, for: key); drafts.flush(key)
        #expect(drafts.error != nil)
        #expect(drafts.draft(for: key) == draft)
    }

    @MainActor @Test func olderJudgmentCorrectionInheritsHeldOutCase() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var fixture = try ReviewFixture(suite: store.suite)
        fixture.suite.scoringMode = .modelJudge
        try fixture.refresh()
        let assessment = try fixture.addAssessment()
        store.runs = [fixture.run]
        try store.saveReview(fixture.annotation(verdict: .failed))
        let review = try #require(store.suiteLocalState.review.annotations.first)
        try store.addReviewToJudgeChecks(reviewID: review.id, partition: .test)
        try store.markJudgmentIncorrect(runID: fixture.run.id, assessmentID: assessment.id,
            sampleID: fixture.run.results[0].id, correctedStatus: .failed, correctedScore: 1,
            reason: "Wrong date", collectAsJudgeCheck: true)
        #expect(store.suiteLocalState.reviewedJudgeExamples.count == 2)
        #expect(store.suiteLocalState.reviewedJudgeExamples.allSatisfy { $0.partition == .test })
        #expect(store.suiteLocalState.reviewedJudgeExamples.first?.reviewSource?.sourceDigest == review.sourceDigest)
    }

    @MainActor @Test func missingImageBytesBlockRegressionAndJudgeEnrollment() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .modelJudge
        #expect(store.saveSuite())
        var fixture = try ReviewFixture(suite: store.suite)
        let image = EvaluationSubjectAttachmentSnapshot(id: UUID(), name: "Image", kind: .image,
            byteCount: 4, sha256: String(repeating: "a", count: 64), storedFilename: nil, text: nil)
        fixture.run.subjectEvidence?.attachments = [image]
        fixture.run.subjectEvidence?.digest = try EvaluationSubjectEvidenceSnapshot.digest(
            instructions: fixture.suite.instructions, cases: fixture.suite.cases, attachments: [image])
        _ = try fixture.addAssessment()
        store.runs = [fixture.run]
        let review = fixture.annotation(verdict: .failed)
        try store.saveReview(review)
        #expect(throws: (any Error).self) { try store.promoteReviewToCase(reviewID: review.id, expected: "correct") }
        #expect(throws: (any Error).self) { try store.addReviewToJudgeChecks(reviewID: review.id, partition: .test) }
        #expect(store.suiteLocalState.reviewedJudgeExamples.isEmpty)
    }

    @MainActor @Test func corruptImageBytesFailIntegrityBeforePromotion() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var fixture = try ReviewFixture(suite: store.suite)
        let imageID = UUID()
        let image = EvaluationSubjectAttachmentSnapshot(id: imageID, name: "Image", kind: .image,
            byteCount: 4, sha256: String(repeating: "a", count: 64), storedFilename: "\(imageID).png", text: nil)
        fixture.run.subjectEvidence?.attachments = [image]
        fixture.run.subjectEvidence?.digest = try EvaluationSubjectEvidenceSnapshot.digest(
            instructions: fixture.suite.instructions, cases: fixture.suite.cases, attachments: [image])
        let evidenceDirectory = EvaluationWorkspacePersistence.suiteDirectory(supportDirectory: directory,
            projectID: store.selectedProjectID, suiteID: store.selectedSuiteID).appending(path: "RunEvidence/\(fixture.run.id)")
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: evidenceDirectory.appending(path: image.storedFilename!))
        #expect(throws: (any Error).self) { try store.validateReviewImageEvidence(fixture.run) }
    }

    @MainActor @Test func writeNativeReviewFixtureWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["EVAL_REVIEW_UI_FIXTURE"] else { return }
        let directory = URL(filePath: path)
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.name = "Review example"
        store.draftSuite.scoringMode = .modelJudge
        store.draftSuite.cases = [EvaluationCase(name: "Meeting date", prompt: "Move the meeting to Friday", expected: "Friday")]
        #expect(store.saveSuite())
        let fixture = try ReviewFixture(suite: store.suite)
        let suiteDirectory = EvaluationWorkspacePersistence.suiteDirectory(supportDirectory: directory,
            projectID: store.selectedProjectID, suiteID: store.selectedSuiteID)
        try CanonicalJSON.data(for: fixture.run).write(to: suiteDirectory.appending(path: "Runs/\(fixture.run.id).json"))
        struct NativeFixture: Encodable { var suite: EvaluationSuite; var run: EvaluationRun }
        try CanonicalJSON.data(for: NativeFixture(suite: store.suite, run: fixture.run))
            .write(to: directory.appending(path: "review-fixture.json"))
    }
}

private struct ReviewFixture {
    var suite: EvaluationSuite
    var run: EvaluationRun
    var sample: EvaluationReviewSample {
        EvaluationReviewWorkflow.samples(runs: [run], suiteID: suite.id)[0]
    }
    init(suite: EvaluationSuite? = nil) throws {
        var suite = suite ?? EvaluationSuite()
        if suite.cases.isEmpty { suite.cases = [.init(name: "Case", prompt: "Question", expected: "correct")] }
        self.suite = suite
        let source = suite.cases[0]
        let result = EvaluationSampleResult(caseID: source.id, caseName: source.name, repetition: 1,
            prompt: source.prompt, expected: source.expected, response: "incorrect", status: .unscored,
            score: nil, rationale: nil, durationMilliseconds: 1, usage: .init())
        run = EvaluationRun(id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version,
            instructions: suite.instructions, criteria: suite.criteria, scoringMode: suite.scoringMode,
            repetitions: suite.repetitions, startedAt: Date(timeIntervalSince1970: 1), completedAt: Date(timeIntervalSince1970: 2),
            cancelled: false, environment: .init(operatingSystem: "macOS 27", locale: "en_GB", model: "Apple on-device", modelContextSize: 4096),
            attachments: [], results: [result])
        try refresh()
    }
    mutating func refresh() throws {
        run.suiteDefinition = EvaluationSuiteDefinition(suite: suite)
        run.plannedCases = suite.cases
        run.subjectEvidence = .init(instructions: suite.instructions, cases: suite.cases, attachments: [],
            digest: try EvaluationSubjectEvidenceSnapshot.digest(instructions: suite.instructions, cases: suite.cases, attachments: []))
    }
    mutating func addAssessment() throws -> EvaluationAssessment {
        let judge = EvaluationJudgeIdentity(mode: .sameModel, connectionID: nil, connectionName: "Fixture", endpointKind: nil,
            baseURL: nil, requestedModelID: "fixture", reportedModelID: nil, provider: nil, providerOrder: [])
        let assessment = EvaluationAssessment(id: UUID(), runID: run.id, createdAt: Date(), origin: .reassessment,
            judge: judge, promptVersion: EvaluationRunner.judgePromptVersion, rubric: suite.criteria,
            passingScore: EvaluationSuite.judgePassingScore,
            samples: run.results.map { .init(id: UUID(), sampleID: $0.id, status: .passed, score: 4, rationale: "Fixture",
                trace: nil, errorCategory: nil, errorMessage: nil, usage: nil, durationMilliseconds: 1) },
            totalUsage: nil, durationMilliseconds: 1, cost: .init(availability: .unavailable, usd: nil, explanation: "Fixture"),
            supersedesAssessmentID: nil, scoringContract: try EvaluationScoringContract(suite: suite), subjectEvidenceDigest: run.subjectEvidence?.digest)
        run.assessments = [assessment]
        return assessment
    }
    func annotation(verdict: EvaluationReviewVerdict, tags: [String] = []) -> EvaluationReviewAnnotation {
        .init(id: UUID(), runID: run.id, sampleID: sample.sample.id, sourceDigest: sample.sourceDigest,
              verdict: verdict, note: "The output selected the wrong date.", tags: tags, updatedAt: Date())
    }
}
