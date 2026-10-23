import CryptoKit
import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationReviewWorkflowTests {
    @Test func reviewSamplesFollowSavedHistoryAfterClockRollback() throws {
        let fixture = try ReviewFixture()
        var first = fixture.run
        first.historySequence = 10
        first.startedAt = Date(timeIntervalSince1970: 200)
        first.completedAt = Date(timeIntervalSince1970: 201)
        var second = fixture.run
        second.id = UUID()
        second.historySequence = 11
        second.startedAt = Date(timeIntervalSince1970: 100)
        second.completedAt = Date(timeIntervalSince1970: 101)
        let ordered = EvaluationReviewWorkflow.samples(runs: [first, second], suiteID: fixture.suite.id)
        #expect(ordered.map { $0.run.id } == [second.id, first.id])
        first.historySequence = nil
        second.historySequence = nil
        let legacy = EvaluationReviewWorkflow.samples(runs: [second, first], suiteID: fixture.suite.id)
        #expect(legacy.map { $0.run.id } == [first.id, second.id])
    }

    @Test func regressionPreservesReferenceWhitespaceAndValidatesOriginalLength() throws {
        let fixture = try ReviewFixture()
        let annotation = fixture.annotation(verdict: .failed)
        let expected = "  exact answer  \n"
        let regression = try EvaluationReviewWorkflow.regression(annotation: annotation,
            sample: fixture.sample, suite: fixture.suite, expected: expected)
        #expect(regression.expected == expected)
        for invalid in [" \t\r\n ", String(repeating: " ", count: EvaluationStore.maximumFieldCharacters) + "x"] {
            #expect(throws: EvaluationReviewError.self) {
                try EvaluationReviewWorkflow.regression(annotation: annotation,
                    sample: fixture.sample, suite: fixture.suite, expected: invalid)
            }
        }
    }

    @MainActor @Test(arguments: [4_000, 4_001])
    func mcpReviewUsesTheSameUnicodeCharacterLimitAsNativeReview(characterCount: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let fixture = try ReviewFixture(suite: store.suite)
        store.runs = [fixture.run]
        var annotation = fixture.annotation(verdict: .failed)
        annotation.note = String(repeating: "界", count: characterCount)
        let allowed = characterCount <= 4_000
        if allowed {
            #expect(try EvaluationReviewWorkflow.validated(annotation, sample: fixture.sample).note == annotation.note)
        } else {
            #expect(throws: EvaluationReviewError.self) {
                _ = try EvaluationReviewWorkflow.validated(annotation, sample: fixture.sample)
            }
        }
        let call = try MCPToolCatalog.parse(name: "eval_review_save", arguments: .object([
            "operationID": .string(UUID().uuidString),
            "projectID": .string(store.selectedProjectID.uuidString),
            "suiteID": .string(store.selectedSuiteID.uuidString),
            "expectedRevision": .string(store.suiteRevision),
            "expectedWorkspaceRevision": .string(try MCPWorkspaceControl.revision(store)),
            "confirmHumanReview": .bool(true),
            "annotationJSON": .string(String(decoding: try JSONEncoder().encode(annotation), as: UTF8.self)),
        ]))
        let result = await MCPStoreAuthority.make(store: store).call(call)
        #expect(result.isError == !allowed)
        #expect(store.suiteLocalState.review.annotations.count == (allowed ? 1 : 0))
        if allowed { #expect(store.suiteLocalState.review.annotations.first?.note == annotation.note) }
    }

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

    @MainActor @Test func savingAnOlderReviewIDBecomesCurrentOnlyAfterPersistenceSucceeds() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var failWrites = false
        let store = EvaluationStore(supportDirectory: directory, suiteLocalStateWriter: { data, url in
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let fixture = try ReviewFixture(suite: store.suite)
        store.runs = [fixture.run]
        var restoredDraft = fixture.annotation(verdict: .failed, tags: ["wrong date"])
        try store.saveReview(restoredDraft)
        let laterReview = fixture.annotation(verdict: .passed)
        try store.saveReview(laterReview)
        restoredDraft.note = "Confirmed the original date failure."
        // Currentness follows the successful save, not caller-controlled timestamps.
        restoredDraft.updatedAt = .distantPast

        failWrites = true
        #expect(throws: EvaluationStoreError.self) { try store.saveReview(restoredDraft) }
        #expect(store.suiteLocalState.review.annotation(runID: fixture.run.id, sampleID: fixture.sample.sample.id)?.id == laterReview.id)
        let afterFailure = EvaluationStore(supportDirectory: directory)
        #expect(afterFailure.suiteLocalState.review.annotation(runID: fixture.run.id, sampleID: fixture.sample.sample.id)?.id == laterReview.id)

        failWrites = false
        try store.saveReview(restoredDraft)
        let reloaded = EvaluationStore(supportDirectory: directory)
        for state in [store.suiteLocalState.review, reloaded.suiteLocalState.review] {
            let current = try #require(state.annotation(runID: fixture.run.id, sampleID: fixture.sample.sample.id))
            #expect(current.id == restoredDraft.id)
            #expect(current.note == restoredDraft.note)
            #expect(current.verdict == .failed)
            #expect(state.annotations.count == 2)
            #expect(Set(state.annotations.map(\.id)) == [restoredDraft.id, laterReview.id])
            #expect(EvaluationReviewWorkflow.patterns(samples: [fixture.sample], state: state).first?.tag == "wrong date")
        }
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

    @Test func reviewMCPOffsetBoundsDoNotLimitHistorySize() throws {
        for offset in [0, 10_000, 10_020, Int.max] {
            _ = try MCPToolCatalog.parse(name: "eval_list_review_samples", arguments: .encode(
                MCPReviewSamplesArguments(suiteID: UUID(), offset: offset, limit: 20)
            ))
        }
        #expect(throws: MCPToolInputError.self) {
            try MCPToolCatalog.parse(name: "eval_list_review_samples", arguments: .encode(
                MCPReviewSamplesArguments(suiteID: UUID(), offset: -1, limit: 20)
            ))
        }
    }

    @MainActor @Test func reviewMCPNextOffsetCanBrowseBeyondTenThousandSamples() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let fixture = try ReviewFixture(suite: store.suite)
        store.runs = (0..<158).map { index in
            var run = fixture.run
            run.id = UUID()
            run.startedAt = Date(timeIntervalSince1970: Double(index))
            run.results = (0..<64).map { repetition in
                var sample = fixture.run.results[0]
                sample.id = UUID()
                sample.repetition = repetition + 1
                return sample
            }
            return run
        }
        let page = try EvaluationReviewMCP.list(.init(suiteID: store.selectedSuiteID, offset: 10_000, limit: 20), store: store)
        #expect(page.structuredContent.objectValue?["total"] == .integer(10_112))
        let nextOffset = try #require(page.structuredContent.objectValue?["nextOffset"])
        #expect(nextOffset == .integer(10_020))
        let call = try MCPToolCatalog.parse(name: "eval_list_review_samples", arguments: .object([
            "suiteID": .string(store.selectedSuiteID.uuidString), "offset": nextOffset, "limit": .integer(20)
        ]))
        guard case .listReviewSamples(let arguments) = call else {
            Issue.record("Expected review page request")
            return
        }
        let nextPage = try EvaluationReviewMCP.list(arguments, store: store)
        guard case .array(let first)? = page.structuredContent.objectValue?["samples"],
              case .array(let second)? = nextPage.structuredContent.objectValue?["samples"] else {
            Issue.record("Expected review sample arrays")
            return
        }
        #expect(first.count == 20)
        #expect(second.count == 20)
        let pageIDsAreDisjoint = Set(first.compactMap { $0.objectValue?["sampleID"]?.stringValue }).isDisjoint(with:
            second.compactMap { $0.objectValue?["sampleID"]?.stringValue })
        #expect(pageIDsAreDisjoint)
        let end = try EvaluationReviewMCP.list(.init(suiteID: store.selectedSuiteID, offset: Int.max, limit: 20), store: store)
        #expect(end.structuredContent.objectValue?["samples"] == .array([]))
        #expect(end.structuredContent.objectValue?["nextOffset"] == .null)
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

    @Test(arguments: ["instructions", "attachments", "conversation"])
    func legacyReviewCurrentnessIncludesSavedSubjectInputs(change: String) throws {
        var fixture = try ReviewFixture()
        fixture.run.subjectEvidence = nil
        fixture.run.suiteDefinition = nil
        let annotation = fixture.annotation(verdict: .failed)
        let proposal = EvaluationReviewProposal(id: UUID(), annotation: annotation)
        var state = EvaluationReviewState()
        try EvaluationReviewWorkflow.propose(proposal, sample: fixture.sample, state: &state)
        switch change {
        case "instructions": fixture.run.instructions += " Changed instructions"
        case "attachments": fixture.run.attachments.append(.init(name: "Reference", kind: .text, byteCount: 7, sha256: "changed"))
        default: fixture.run.plannedCases?[0].conversation.setupTurns = [.init(prompt: "Changed history")]
        }
        #expect(!EvaluationReviewWorkflow.isCurrent(annotation, sample: fixture.sample))
        #expect(throws: EvaluationReviewError.self) {
            try EvaluationReviewWorkflow.decideProposal(id: proposal.id, accept: true, sample: fixture.sample, state: &state)
        }
        #expect(state.annotations.isEmpty)
        #expect(state.proposals.first?.status == .pending)
        try EvaluationReviewWorkflow.decideProposal(id: proposal.id, accept: false, sample: fixture.sample, state: &state)
        #expect(state.proposals.first?.status == .rejected)
    }

    @Test func completeEvidenceKeepsTheExistingReviewDigestFormat() throws {
        // The pre-fix source format is the compatibility contract for modern saved reviews.
        struct Context: Encodable {
            var instructions: String
            var model: EvaluationModelConfiguration
            var features: EvaluationFeatureConfiguration
        }
        struct OriginalSource: Encodable {
            var runID: UUID
            var sample: EvaluationSampleResult
            var subjectEvidence: EvaluationSubjectEvidenceSnapshot?
            var subjectContext: Context?
            var environment: EvaluationEnvironment
            var execution: EvaluationExecutionTrace?
            var developerExecution: EvaluationDeveloperExecution?
        }
        let fixture = try ReviewFixture()
        let run = fixture.run
        let source = OriginalSource(runID: run.id, sample: run.results[0], subjectEvidence: run.subjectEvidence,
            subjectContext: run.suiteDefinition.map { .init(instructions: $0.instructions, model: $0.modelConfiguration, features: $0.features) },
            environment: run.environment, execution: run.execution, developerExecution: run.developerExecution)
        let originalDigest = SHA256.hash(data: try CanonicalJSON.data(for: source, prettyPrinted: false))
            .map { String(format: "%02x", $0) }.joined()
        #expect(fixture.sample.sourceDigest == originalDigest)
    }

    @Test func judgeLabelsCannotReplayAgainstChangedOutputs() throws {
        var fixture = try ReviewFixture()
        let assessment = try fixture.addAssessment()
        let review = fixture.annotation(verdict: .failed)
        let example = EvaluationReviewedJudgeExample(reviewSource: .init(reviewID: review.id, runID: review.runID,
            sampleID: review.sampleID, sourceDigest: review.sourceDigest), id: UUID(), sourceRunID: review.runID,
            sourceAssessmentID: assessment.id, sampleID: review.sampleID, expectedStatus: .failed, reason: review.note, createdAt: Date())
        try EvaluationReviewWorkflow.validateJudgeSource(example, run: fixture.run)
        fixture.run.results[0].response = "A different output"
        #expect(throws: EvaluationReviewError.self) { try EvaluationReviewWorkflow.validateJudgeSource(example, run: fixture.run) }
    }

    @MainActor @Test(arguments: ["foreignRun", "duplicateAssessment", "duplicateSample"])
    func invalidAssessmentIdentityCannotEnrollOrReplayHumanJudgeChecks(kind: String) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var fixture = try ReviewFixture(suite: store.suite)
        fixture.suite.scoringMode = .modelJudge
        try fixture.refresh()
        var assessment = try fixture.addAssessment()
        let annotation = fixture.annotation(verdict: .failed)
        let example = EvaluationReviewedJudgeExample(reviewSource: .init(reviewID: annotation.id,
            runID: annotation.runID, sampleID: annotation.sampleID, sourceDigest: annotation.sourceDigest),
            id: UUID(), sourceRunID: fixture.run.id, sourceAssessmentID: assessment.id, sampleID: annotation.sampleID,
            expectedStatus: .failed, reason: annotation.note, createdAt: Date())
        try EvaluationReviewWorkflow.validateJudgeSource(example, run: fixture.run)
        switch kind {
        case "foreignRun": assessment.runID = UUID()
        case "duplicateSample":
            var duplicate = assessment.samples[0]
            duplicate.id = UUID()
            assessment.samples.append(duplicate)
        default: break
        }
        fixture.run.assessments = kind == "duplicateAssessment" ? [assessment, assessment] : [assessment]
        #expect(EvaluationReviewWorkflow.isCurrent(annotation, sample: fixture.sample))
        #expect(throws: EvaluationReviewError.self) {
            try EvaluationReviewWorkflow.validateJudgeSource(example, run: fixture.run)
        }
        store.runs = [fixture.run]
        try store.saveReview(annotation)
        #expect(throws: EvaluationReviewError.self) { try store.addReviewToJudgeChecks(reviewID: annotation.id, partition: .test) }
        #expect(store.suiteLocalState.reviewedJudgeExamples.isEmpty)
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

    @MainActor @Test func beginningShutdownSavesReviewDraftsBeforeTheirDebounceRuns() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let fixture = try ReviewFixture(suite: store.suite)
        let key = EvaluationReviewDraftStore.key(for: fixture.sample)
        let draft = EvaluationReviewDraftStore.Draft(reviewID: UUID(), verdict: .failed, note: "Last edit before quitting", tags: "date")
        store.reviewDrafts.update(draft, for: key)
        store.reviewDrafts.update(draft, for: "cleared")
        try store.reviewDrafts.clear("cleared")
        // No suspension: the 400 ms debounce task cannot run before shutdown.
        store.beginClosing()
        let reloaded = EvaluationReviewDraftStore(directory: directory.appending(path: "ReviewDrafts"))
        #expect(reloaded.draft(for: key) == draft)
        #expect(reloaded.draft(for: "cleared") == nil)
        #expect(store.suiteLocalState.review.annotations.isEmpty)
    }

    @MainActor @Test func flushingReviewDraftsRetriesFailedWritesAndKeepsFailuresVisible() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let drafts = EvaluationReviewDraftStore(directory: directory)
        let draft = EvaluationReviewDraftStore.Draft(reviewID: UUID(), verdict: .failed, note: "Keep this note", tags: "date")
        try FileManager.default.createDirectory(at: directory.appending(path: "a.json"), withIntermediateDirectories: true)
        drafts.update(draft, for: "a")
        drafts.flush("a")
        #expect(drafts.error != nil)
        drafts.update(draft, for: "z")
        drafts.flushPendingDrafts()
        #expect(drafts.error != nil)
        #expect(drafts.draft(for: "a") == draft)
        #expect(EvaluationReviewDraftStore(directory: directory).draft(for: "z") == draft)

        try FileManager.default.removeItem(at: directory.appending(path: "a.json"))
        drafts.flushPendingDrafts()
        #expect(drafts.error == nil)
        #expect(EvaluationReviewDraftStore(directory: directory).draft(for: "a") == draft)
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
