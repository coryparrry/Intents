import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationPromptImprovementTests {
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
        try reopened.applyPromptImprovement(id: report.id)
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
