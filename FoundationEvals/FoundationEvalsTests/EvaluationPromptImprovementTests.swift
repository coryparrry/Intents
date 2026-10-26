import Foundation
import CryptoKit
import Testing
@testable import FoundationEvals

struct EvaluationPromptImprovementTests {
    @Test func presentationExplainsSetupAndInterruptedResults() {
        var plan = makeImprovement()
        #expect(PromptImprovementPresentation.setupIssue(suite: plan.source, heldOutCaseIDs: plan.heldOutCaseIDs) == nil)
        #expect(PromptImprovementPresentation.setupIssue(suite: plan.source, heldOutCaseIDs: [])?.contains("practice") == true)
        let validSource = plan.source
        plan.source.repetitions = Int.max
        #expect(PromptImprovementPresentation.maximumSamples(suite: plan.source, heldOutCaseIDs: plan.heldOutCaseIDs) == nil)
        plan.source = validSource
        #expect(PromptImprovementPresentation.maximumSamples(suite: plan.source, heldOutCaseIDs: plan.heldOutCaseIDs) == 16)
        plan.source.cases = []
        #expect(PromptImprovementPresentation.setupIssue(suite: plan.source, heldOutCaseIDs: [])?.contains("at least two") == true)
        plan = makeImprovement()
        plan.source.scoringMode = .review
        #expect(PromptImprovementPresentation.setupIssue(suite: plan.source, heldOutCaseIDs: plan.heldOutCaseIDs)?.contains("scoring") == true)
        #expect(PromptImprovementPresentation(report: plan).title == "Comparison interrupted")
        #expect(PromptImprovementPresentation(report: plan, isActive: true).title == "Comparing instructions")
        plan.status = .cancelled
        #expect(PromptImprovementPresentation(report: plan).title == "Comparison cancelled")
        plan.status = .failed
        #expect(PromptImprovementPresentation(report: plan).detail.contains("haven’t changed"))
    }

    @Test func presentationTracksTheSelectedSuggestionAndProtectsNewEdits() async throws {
        let plan = makeImprovement()
        let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id)
        var result = try await makeRunner(harness).run(plan) { try await harness.save($0) }
        #expect(PromptImprovementPresentation(report: result).title == "A better suggestion is ready")
        #expect(PromptImprovementPresentation(report: result, isStale: true).title == "Your suite has changed")
        #expect(PromptImprovementPresentation(report: result).step == 3)
        #expect(PromptImprovementPresentation.scoreSummary(nil) == "Not run")
        #expect(PromptImprovementPresentation.scoreSummary(result.heldOutCandidate) == "2 / 2")
        var partial = try #require(result.heldOutCandidate)
        partial.cancelled = true
        #expect(PromptImprovementPresentation.scoreSummary(partial) == "Incomplete")
        result.appliedAt = Date()
        #expect(PromptImprovementPresentation(report: result, isStale: true).title == "Suggestion applied")
        let checkpoints = await harness.checkpoints
        #expect(Set(checkpoints.map { PromptImprovementPresentation(report: $0).step }) == Set([1, 2, 3]))
        #expect(PromptImprovementPresentation(report: plan).step == 0)
    }

    @Test(arguments: ["empty", "all", "unknown", "duplicate", "unscored", "repetitions"])
    func invalidPlansNeverCallTheModel(mutation: String) async throws {
        var plan = makeImprovement()
        switch mutation {
        case "empty": plan.heldOutCaseIDs = []
        case "all": plan.heldOutCaseIDs = Set(plan.source.cases.map(\.id))
        case "unknown": plan.heldOutCaseIDs = [UUID()]
        case "duplicate": plan.source.cases.append(plan.source.cases[0])
        case "unscored": plan.source.scoringMode = .review
        default: plan.source.repetitions = Int.max
        }
        let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id)
        await #expect(throws: (any Error).self) {
            _ = try await makeRunner(harness).run(plan) { try await harness.save($0) }
        }
        #expect(await harness.evaluations.isEmpty)
        #expect(await harness.generatorCalls == 0)
    }

    @Test func selectsUsingDevelopmentThenValidatesOnlyTheWinner() async throws {
        let plan = makeImprovement()
        let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id)
        let result = try await makeRunner(harness).run(plan) { try await harness.save($0) }
        #expect(result.canApply)
        #expect(result.selectedCandidate?.instructions == "Clear instructions")
        #expect(result.runs.count == 5)
        #expect(result.runs.allSatisfy { $0.promptImprovementID == result.id })
        #expect(result.source == plan.source)
        #expect(result.maximumSamples == 16)
        let generationInput = try #require(await harness.generatorInput)
        #expect(!generationInput.cases.contains { plan.heldOutCaseIDs.contains($0.id) })
        let data = try EvaluationPromptImprovementGenerator.inputData(
            development: generationInput, baseline: result.developmentBaseline!
        )
        #expect(!data.contains("SECRET HELD OUT"))
        let generationEvidence = try #require(JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any])
        #expect(generationEvidence["criteria"] as? String == "")
        #expect((generationEvidence["scoring"] as? String)?.contains("complete response equals") == true)
        let heldRuns = await harness.evaluations.filter { $0.cases.contains { plan.heldOutCaseIDs.contains($0.id) } }
        #expect(heldRuns.map(\.instructions) == [plan.source.instructions, "Clear instructions"])
        let decoded = try CanonicalJSON.decode(EvaluationPromptImprovement.self, from: CanonicalJSON.data(for: result))
        #expect(decoded.canApply)
        #expect(decoded.heldOutCaseIDs == result.heldOutCaseIDs)
    }

    @Test func heldOutRegressionCannotBeApplied() async throws {
        let plan = makeImprovement()
        let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id, behavior: .heldOutRegression)
        let result = try await makeRunner(harness).run(plan) { try await harness.save($0) }
        #expect(result.status == .completed)
        #expect(!result.canApply)
        #expect(result.heldOutCandidate?.passedCount == 0)
    }

    @Test func noDevelopmentImprovementLeavesHeldOutUntouched() async throws {
        let plan = makeImprovement()
        let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id, behavior: .noImprovement)
        let result = try await makeRunner(harness).run(plan) { try await harness.save($0) }
        #expect(result.status == .noImprovement)
        #expect(result.selectedCandidateID == nil)
        #expect(result.heldOutBaseline == nil)
        #expect(await harness.evaluations.count == 3)
    }

    @Test func developmentTiesUseTheFirstCandidate() async throws {
        let plan = makeImprovement()
        let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id, behavior: .tie)
        let report = try await makeRunner(harness).run(plan) { try await harness.save($0) }
        #expect(report.selectedCandidate?.instructions == "Clear instructions")
    }

    @Test func anEqualAggregateCannotHideAHeldOutCaseRegression() async throws {
        let plan = makeImprovement()
        let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id)
        var report = try await makeRunner(harness).run(plan) { try await harness.save($0) }
        let extra = EvaluationCase(name: "Another held-out", prompt: "Another secret", expected: "Expected")
        report.source.cases.append(extra)
        report.heldOutCaseIDs.insert(extra.id)
        report.heldOutBaseline = await harness.evaluate(report.heldOutSuite)
        var candidateSuite = report.heldOutSuite
        candidateSuite.instructions = "Clear instructions"
        var candidate = await harness.evaluate(candidateSuite)
        for index in candidate.results.indices where candidate.results[index].caseID != extra.id {
            candidate.results[index].status = .failed
        }
        report.heldOutCandidate = candidate
        #expect(report.heldOutCandidate?.passedCount == report.heldOutBaseline?.passedCount)
        #expect(!report.canApply)
    }

    @Test func changedExecutionSettingsInvalidateARecommendation() async throws {
        let plan = makeImprovement()
        let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id)
        var report = try await makeRunner(harness).run(plan) { try await harness.save($0) }
        #expect(report.canApply)
        report.heldOutCandidate?.suiteDefinition?.criteria = "Different scoring"
        #expect(!report.canApply)
        report.source.repetitions = 0
        #expect(!report.canApply)
    }

    @Test(arguments: [ImprovementHarness.Behavior.incomplete, .duplicate, .judgeError, .missingDefinition])
    fileprivate func incompleteOrInvalidEvidenceStopsBeforeGeneration(behavior: ImprovementHarness.Behavior) async throws {
        let plan = makeImprovement()
        let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id, behavior: behavior)
        await #expect(throws: (any Error).self) {
            _ = try await makeRunner(harness).run(plan) { try await harness.save($0) }
        }
        #expect(await harness.generatorCalls == 0)
        #expect(await harness.evaluations.count == 1)
        #expect(await harness.checkpoints.last?.developmentBaseline != nil)
        #expect(await harness.checkpoints.last?.canApply == false)
    }

    @Test(arguments: ["empty", "duplicate", "unchanged", "oversized"])
    func invalidAlternativesAreNeverEvaluated(kind: String) async throws {
        let plan = makeImprovement()
        let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id)
        let runner = EvaluationPromptImprovementRunner(generate: { suite, _ in
            switch kind {
            case "empty": return ["", "Alternative"]
            case "duplicate": return ["Same", " Same "]
            case "unchanged": return [suite.instructions, "Alternative"]
            default: return [String(repeating: "x", count: 32_001), "Alternative"]
            }
        }, evaluate: { await harness.evaluate($0) })
        await #expect(throws: (any Error).self) {
            _ = try await runner.run(plan) { try await harness.save($0) }
        }
        #expect(await harness.evaluations.count == 1)
    }

    @Test func cancellationAfterFinalGenerationCannotRecommendAChange() async throws {
        let plan = makeImprovement()
        let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id, behavior: .cancelLast)
        let task = Task {
            try await makeRunner(harness).run(plan) { try await harness.save($0) }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await harness.checkpoints.last?.canApply == false)
    }

    @Test func checkpointFailureStopsFurtherWork() async throws {
        let plan = makeImprovement()
        let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id)
        await #expect(throws: CocoaError.self) {
            _ = try await makeRunner(harness).run(plan) { _ in throw CocoaError(.fileWriteNoPermission) }
        }
        #expect(await harness.evaluations.count == 1)
        #expect(await harness.generatorCalls == 0)
    }

    #if DEBUG
    @Test func testSuggestionsRequireAnIsolatedDebugLaunch() {
        let flag = "--prompt-improvement-test-suggestions"
        #expect(!EvaluationPromptImprovementGenerator.usesTestSuggestions(arguments: [flag], environment: [:]))
        #expect(!EvaluationPromptImprovementGenerator.usesTestSuggestions(
            arguments: [flag, "--evaluation-storage", "relative"], environment: [:]))
        #expect(!EvaluationPromptImprovementGenerator.usesTestSuggestions(
            arguments: ["--evaluation-storage", "/tmp/isolated"], environment: [:]))
        #expect(EvaluationPromptImprovementGenerator.usesTestSuggestions(
            arguments: [flag, "--evaluation-storage", "/tmp/isolated"], environment: [:]))
    }
    #endif

    @Test func legacyStateDefaultsToNoImprovementHistory() throws {
        var object = try #require(JSONSerialization.jsonObject(with: CanonicalJSON.data(for: EvaluationSuiteLocalState())) as? [String: Any])
        object.removeValue(forKey: "promptImprovements")
        let state = try CanonicalJSON.decode(EvaluationSuiteLocalState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(state.promptImprovements.isEmpty)
    }

    @Test @MainActor func applicationRejectsDraftChangesAndRollsBackFailedPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        var source = makeImprovement().source
        source.id = store.suite.id
        store.draftSuite = source
        #expect(store.saveSuite())
        var plan = makeImprovement()
        plan.source = store.suite
        plan.heldOutCaseIDs = [store.suite.cases.last!.id]
        let harness = ImprovementHarness(heldOutID: store.suite.cases.last!.id)
        let report = try await makeRunner(harness).run(plan) { try await harness.save($0) }
        var state = EvaluationSuiteLocalState()
        state.promptImprovements = [report]
        let directory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: root, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID
        )
        try CanonicalJSON.data(for: state).write(to: directory.appending(path: "state.json"))
        let reopened = EvaluationStore(supportDirectory: root)
        let initialSelection = reopened.selection
        try reopened.savePromptImprovementCheckpoint(report)
        #expect(reopened.selection == initialSelection)
        #expect(reopened.runs.count == 5)
        let cancelledCheckpoint = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try reopened.savePromptImprovementCheckpoint(report)
        }
        await #expect(throws: CancellationError.self) { try await cancelledCheckpoint.value }
        reopened.draftSuite.instructions = "My pending edit"
        #expect(throws: (any Error).self) { try reopened.applyPromptImprovement(id: report.id) }
        #expect(reopened.draftSuite.instructions == "My pending edit")
        reopened.draftSuite = reopened.suite
        let noticeBeforeApplication = reopened.notice
        try reopened.applyPromptImprovement(id: report.id)
        #expect(reopened.notice == noticeBeforeApplication)
        #expect(reopened.suite.instructions == "Clear instructions")
        #expect(reopened.suiteLocalState.promptImprovements[0].appliedAt != nil)
        #expect(throws: (any Error).self) { try reopened.applyPromptImprovement(id: report.id) }

        let secondRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        try FileManager.default.copyItem(at: root, to: secondRoot)
        // Restore the frozen suite and unapplied report to exercise a state-write failure after suite save.
        let secondDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: secondRoot, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID
        )
        try CanonicalJSON.data(for: report.source).write(to: secondDirectory.appending(path: "suite.json"))
        try? FileManager.default.removeItem(at: secondDirectory.appending(path: "suite-draft.json"))
        try CanonicalJSON.data(for: state).write(to: secondDirectory.appending(path: "state.json"))
        let failing = EvaluationStore(supportDirectory: secondRoot, suiteLocalStateWriter: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        #expect(throws: (any Error).self) { try failing.applyPromptImprovement(id: report.id) }
        #expect(failing.suite.instructions == report.source.instructions)
        #expect(failing.draftSuite.instructions == report.source.instructions)
        #expect(failing.suiteLocalState.promptImprovements[0].appliedAt == nil)
    }

    @Test func criticalReleaseCasesAreScopedToEachPartition() async throws {
        var plan = makeImprovement()
        let developmentID = plan.source.cases[0].id
        let heldOutID = plan.source.cases.last!.id
        plan.source.releasePolicy.criticalCaseIDs = [developmentID, heldOutID]
        #expect(plan.developmentSuite.releasePolicy.criticalCaseIDs == [developmentID])
        #expect(plan.heldOutSuite.releasePolicy.criticalCaseIDs == [heldOutID])
        #expect(plan.source.releasePolicy.criticalCaseIDs == [developmentID, heldOutID])
        let harness = ImprovementHarness(heldOutID: heldOutID)
        let report = try await makeRunner(harness).run(plan) { try await harness.save($0) }
        #expect(report.canApply)
        #expect(report.source.releasePolicy == plan.source.releasePolicy)
    }

    @Test @MainActor func comparisonHistoryDoesNotReplaceDefaultReleaseEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        var source = makeImprovement().source
        source.id = store.suite.id
        source.releasePolicy.required = true
        store.draftSuite = source
        #expect(store.saveSuite())
        let expectedByPrompt = Dictionary(uniqueKeysWithValues: source.cases.map { ($0.prompt, $0.expected) })
        let full = try await store.runFeatureAdapter(
            expectedRevision: store.suiteRevision,
            adapter: ClosureFeatureAdapter(displayName: "Release fixture") { expectedByPrompt[$0.prompt] ?? "" }
        )
        #expect(store.releaseCheckReport(runID: nil).outcome == .passed)
        let plan = EvaluationPromptImprovement(source: store.suite, heldOutCaseIDs: [source.cases.last!.id])
        let harness = ImprovementHarness(heldOutID: source.cases.last!.id)
        let report = try await makeRunner(harness).run(plan) { try await harness.save($0) }
        let comparisons = report.runs.enumerated().map { index, original in
            var run = original
            run.historySequence = (full.historySequence ?? 0) + UInt64(index) + 1
            return run
        }
        try store.saveCompletedRuns(comparisons)
        let partial = try #require(store.runs.first)
        #expect(partial.promptImprovementID == report.id)
        #expect(store.releaseCheckReport(runID: nil).runID == full.id)
        #expect(store.releaseCheckReport(runID: nil).outcome == .passed)
        #expect(store.releaseCheckReport(runID: partial.id).outcome == .incompleteOrIncompatibleEvidence)
        let project = try store.projectReleaseCheckReport(projectID: store.selectedProjectID)
        #expect(project.outcome == .passed)
        #expect(project.suites.first?.report.runID == full.id)
        let reopened = EvaluationStore(supportDirectory: root)
        #expect(reopened.runs.first?.promptImprovementID == report.id)
        #expect(reopened.releaseCheckReport(runID: nil).runID == full.id)
        #expect(try reopened.projectReleaseCheckReport(projectID: reopened.selectedProjectID).suites.first?.report.runID == full.id)
        let summary = SuiteOverviewSummary(record: reopened.selectedSuiteRecord, suite: reopened.suite,
            currentRevision: reopened.suiteRevision, draft: nil, runs: reopened.runs, localState: reopened.suiteLocalState)
        #expect(summary.state == .passed)
        #expect(summary.latestRunID == full.id)
        #expect(summary.latestScoredRunID == full.id)
        #expect(summary.history.map(\.id) == [full.id])
        let persistedFull = try #require(reopened.runs.first { $0.id == full.id })
        let loaded = await WorkspaceOverviewLoader().load(project: reopened.selectedProject, directory: root)
        let loadedSummary = try #require(loaded.first { $0.id == reopened.selectedSuiteID })
        #expect(loadedSummary.state == .passed)
        #expect(loadedSummary.latestRunID == full.id)
        #expect(loadedSummary.lastCheckedAt == persistedFull.startedAt)
        #expect(loadedSummary.latestScoredRunID == full.id)
        #expect(loadedSummary.history.map(\.id) == [full.id])
        let comparisonOnly = SuiteOverviewSummary(record: reopened.selectedSuiteRecord, suite: reopened.suite,
            currentRevision: reopened.suiteRevision, draft: nil, runs: comparisons, localState: reopened.suiteLocalState)
        #expect(comparisonOnly.state == .notRun)
        #expect(comparisonOnly.history.isEmpty)
        #expect(comparisonOnly.latestRunID == nil)
    }

    @Test @MainActor func rejectedSnapshotCleansOnlyItsUnpublishedEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        var source = makeImprovement().source
        source.id = store.suite.id
        source.modelConfiguration.provider = .customHTTP
        var provider = EvaluationCustomProviderConfiguration()
        provider.supportsVision = true
        source.modelConfiguration.customProvider = provider
        let directory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: root, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID
        )
        let imageID = UUID()
        let filename = imageID.uuidString + ".png"
        let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        let attachments = directory.appending(path: "Attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try image.write(to: attachments.appending(path: filename))
        source.attachments = [.init(id: imageID, name: "Fixture", kind: .image, text: nil,
                                    storedFilename: filename, byteCount: image.count, sha256: digest)]
        store.draftSuite = source
        #expect(store.saveSuite())
        let evidence = directory.appending(path: "RunEvidence")
        let protected = evidence.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        let protectedFile = protected.appending(path: "saved-evidence")
        try Data("Keep existing evidence".utf8).write(to: protectedFile)
        for _ in 0..<2 {
            do {
                _ = try await store.evaluatePromptImprovementVariant(
                    source, imageDigests: ["file-1": String(repeating: "0", count: 64)], externalJudge: nil
                )
                Issue.record("A mismatched snapshot must be rejected before model execution")
            } catch {
                #expect(error.localizedDescription.contains("reference image changed"))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: evidence.path) == [protected.lastPathComponent])
            #expect(try Data(contentsOf: protectedFile) == Data("Keep existing evidence".utf8))
            #expect(try Data(contentsOf: attachments.appending(path: filename)) == image)
        }
    }

    @Test(arguments: 0..<5)
    func deletingAnyComparisonRunInvalidatesTheRecommendation(index: Int) async throws {
        let plan = makeImprovement()
        let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id)
        var report = try await makeRunner(harness).run(plan) { try await harness.save($0) }
        let id = report.runs[index].id
        report.removeRun(id: id)
        #expect(report.status == .failed)
        #expect(!report.canApply)
        #expect(report.runs.count == 4)
        #expect(!report.runs.contains { $0.id == id })
        let reopened = try CanonicalJSON.decode(EvaluationPromptImprovement.self, from: CanonicalJSON.data(for: report))
        #expect(!reopened.canApply)
        #expect(!reopened.runs.contains { $0.id == id })
    }

    @Test(arguments: [false, true]) @MainActor
    func deletingComparisonEvidenceUpdatesItsOwningSuite(foreignSuite: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, report) = try await makeStoreWithComparison(root: root)
        let ownerID = store.selectedSuiteID
        let directory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: root, projectID: store.selectedProjectID, suiteID: ownerID)
        let run = try #require(report.heldOutCandidate)
        let evidence = directory.appending(path: "RunEvidence/\(run.id)")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try Data("Private image".utf8).write(to: evidence.appending(path: "image.png"))
        if foreignSuite { _ = try store.createSuite(name: "Other suite") }
        #expect(try store.deleteRunDurably(id: run.id))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "Runs/\(run.id).json").path))
        #expect(!FileManager.default.fileExists(atPath: evidence.path))
        let bytes = try Data(contentsOf: directory.appending(path: "state.json"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains(run.id.uuidString))
        let state = try CanonicalJSON.decode(EvaluationSuiteLocalState.self, from: bytes)
        let saved = try #require(state.promptImprovements.first)
        #expect(saved.heldOutCandidate == nil)
        #expect(saved.runs.count == 4)
        #expect(!saved.canApply)
        #expect(state.promptImprovements.last?.canApply == true)
        if foreignSuite {
            #expect(store.suiteLocalState.promptImprovements.isEmpty)
            try store.switchSuite(id: ownerID)
        }
        #expect(store.suiteLocalState.promptImprovements.first?.heldOutCandidate == nil)
        #expect(throws: (any Error).self) { try store.applyPromptImprovement(id: report.id) }
        let reopened = EvaluationStore(supportDirectory: root)
        #expect(reopened.suiteLocalState.promptImprovements.first?.heldOutCandidate == nil)
        #expect(reopened.runs.count == 9)
    }

    @Test(arguments: [false, true]) @MainActor
    func failedComparisonStateWritePreservesTheRun(foreignSuite: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, report) = try await makeStoreWithComparison(root: root)
        let directory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: root, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID)
        let stateURL = directory.appending(path: "state.json")
        let original = try Data(contentsOf: stateURL)
        if foreignSuite { _ = try store.createSuite(name: "Other suite") }
        let failing = EvaluationStore(supportDirectory: root, suiteLocalStateWriter: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let run = try #require(report.heldOutCandidate)
        #expect(throws: (any Error).self) { try failing.deleteRunDurably(id: run.id) }
        #expect(try Data(contentsOf: stateURL) == original)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Runs/\(run.id).json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "RunDeletions/\(run.id).json").path))
        if !foreignSuite {
            #expect(failing.suiteLocalState.promptImprovements.first?.canApply == true)
            #expect(failing.runs.contains { $0.id == run.id })
        }
    }

    @Test(arguments: ["directory", "move"]) @MainActor
    func failedRunStagingPreservesTheComparison(failure: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, report) = try await makeStoreWithComparison(root: root)
        let directory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: root, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID)
        let run = try #require(report.heldOutCandidate)
        let stateURL = directory.appending(path: "state.json")
        let original = try Data(contentsOf: stateURL)
        let deletions = directory.appending(path: "RunDeletions")
        store.selection = .run(run.id)
        if failure == "directory" {
            try Data("Blocked directory".utf8).write(to: deletions)
        } else {
            try FileManager.default.createDirectory(at: deletions, withIntermediateDirectories: true)
            try Data("Existing destination".utf8).write(to: deletions.appending(path: "\(run.id).json"))
        }
        #expect(throws: (any Error).self) { try store.deleteRunDurably(id: run.id) }
        #expect(try Data(contentsOf: stateURL) == original)
        #expect(store.suiteLocalState.promptImprovements.first?.canApply == true)
        #expect(store.run(with: run.id) != nil)
        #expect(store.runs.contains { $0.id == run.id })
        #expect(store.selection == .run(run.id))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Runs/\(run.id).json").path))
    }

    @Test @MainActor
    func clearingHistoryRemovesComparisonsAndRetriesFailedStateWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, report) = try await makeStoreWithComparison(root: root)
        let directory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: root, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID)
        let run = try #require(report.heldOutCandidate)
        let evidence = directory.appending(path: "RunEvidence/\(run.id)")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let image = evidence.appending(path: "image.png")
        try Data("Private image".utf8).write(to: image)
        let stateURL = directory.appending(path: "state.json")
        let original = try Data(contentsOf: stateURL)
        var fails = true
        let failing = EvaluationStore(supportDirectory: root, suiteLocalStateWriter: { data, url in
            if fails { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        #expect(throws: (any Error).self) { try failing.clearRunHistory() }
        #expect(try Data(contentsOf: stateURL) == original)
        #expect(FileManager.default.fileExists(atPath: image.path))
        #expect(failing.suiteLocalState.promptImprovements.count == 2)
        fails = false
        try failing.clearRunHistory()
        #expect(failing.runs.isEmpty)
        #expect(failing.suiteLocalState.promptImprovements.isEmpty)
        #expect(failing.suite == store.suite)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "RunEvidence").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "RunDeletions").path))
        let reopened = EvaluationStore(supportDirectory: root)
        #expect(reopened.runs.isEmpty)
        #expect(reopened.suiteLocalState.promptImprovements.isEmpty)
        #expect(reopened.suite == store.suite)
    }
}

@MainActor
private func makeStoreWithComparison(root: URL) async throws -> (EvaluationStore, EvaluationPromptImprovement) {
    let store = EvaluationStore(supportDirectory: root)
    var plan = makeImprovement()
    plan.source.id = store.suite.id
    store.draftSuite = plan.source
    #expect(store.saveSuite())
    plan.source = store.suite
    let harness = ImprovementHarness(heldOutID: plan.source.cases.last!.id)
    let report = try await makeRunner(harness).run(plan) { try await harness.save($0) }
    // An unrelated comparison must retain its evidence and recommendation.
    var otherPlan = plan
    otherPlan.id = UUID()
    let otherHarness = ImprovementHarness(heldOutID: plan.source.cases.last!.id)
    let other = try await makeRunner(otherHarness).run(otherPlan) { try await otherHarness.save($0) }
    var state = EvaluationSuiteLocalState()
    state.promptImprovements = [report, other]
    let directory = EvaluationWorkspacePersistence.suiteDirectory(
        supportDirectory: root, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID)
    try CanonicalJSON.data(for: state).write(to: directory.appending(path: "state.json"))
    let reopened = EvaluationStore(supportDirectory: root)
    try reopened.savePromptImprovementCheckpoint(report)
    try reopened.savePromptImprovementCheckpoint(other)
    return (reopened, report)
}

private func makeImprovement() -> EvaluationPromptImprovement {
    var suite = EvaluationSuite()
    suite.scoringMode = .exactMatch
    suite.repetitions = 2
    suite.cases = [
        EvaluationCase(name: "First", prompt: "Development one", expected: "answer"),
        EvaluationCase(name: "Second", prompt: "Development two", expected: "answer"),
        EvaluationCase(name: "Held out", prompt: "SECRET HELD OUT", expected: "SECRET HELD OUT ANSWER")
    ]
    return EvaluationPromptImprovement(source: suite, heldOutCaseIDs: [suite.cases.last!.id])
}

private func makeRunner(_ harness: ImprovementHarness) -> EvaluationPromptImprovementRunner {
    EvaluationPromptImprovementRunner(generate: { await harness.generate($0, $1) }, evaluate: { await harness.evaluate($0) })
}

private actor ImprovementHarness {
    enum Behavior: Sendable { case normal, heldOutRegression, noImprovement, incomplete, duplicate, judgeError, cancelLast, tie, missingDefinition }
    let heldOutID: UUID
    let behavior: Behavior
    private(set) var evaluations: [EvaluationSuite] = []
    private(set) var generatorCalls = 0
    private(set) var generatorInput: EvaluationSuite?
    private(set) var checkpoints: [EvaluationPromptImprovement] = []

    init(heldOutID: UUID, behavior: Behavior = .normal) { self.heldOutID = heldOutID; self.behavior = behavior }

    func generate(_ suite: EvaluationSuite, _ baseline: EvaluationRun) -> [String] {
        generatorCalls += 1
        generatorInput = suite
        return ["Clear instructions", "Robust instructions"]
    }

    func save(_ report: EvaluationPromptImprovement) throws { checkpoints.append(report) }

    func evaluate(_ suite: EvaluationSuite) -> EvaluationRun {
        evaluations.append(suite)
        var results: [EvaluationSampleResult] = []
        for test in suite.cases {
            for repetition in 1...suite.repetitions {
                let isHeldOut = test.id == heldOutID
                let pass: Bool
                if isHeldOut { pass = behavior != .heldOutRegression || suite.instructions != "Clear instructions" }
                else {
                    pass = behavior != .noImprovement && (suite.instructions == "Clear instructions"
                        || (behavior == .tie && suite.instructions == "Robust instructions"))
                }
                results.append(EvaluationSampleResult(
                    caseID: test.id, caseName: test.name, repetition: repetition, prompt: test.prompt,
                    expected: test.expected, response: pass ? test.expected : "wrong", status: pass ? .passed : .failed,
                    durationMilliseconds: 1, usage: EvaluationUsage()
                ))
            }
        }
        if behavior == .incomplete { results.removeLast() }
        if behavior == .duplicate { results[1] = results[0] }
        if behavior == .judgeError { results[0].judgeErrorCategory = "unavailable" }
        if behavior == .cancelLast && evaluations.count == 5 { withUnsafeCurrentTask { $0?.cancel() } }
        return EvaluationRun(
            id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version,
            instructions: suite.instructions, criteria: suite.criteria, scoringMode: suite.scoringMode,
            repetitions: suite.repetitions, plannedSampleCount: suite.cases.count * suite.repetitions,
            plannedCases: suite.cases, startedAt: Date(), completedAt: Date(), cancelled: false,
            environment: EvaluationEnvironment(operatingSystem: "Test", locale: "en", model: "Test", modelContextSize: 8192),
            attachments: [], results: results,
            suiteDefinition: behavior == .missingDefinition ? nil : EvaluationSuiteDefinition(suite: suite)
        )
    }
}
