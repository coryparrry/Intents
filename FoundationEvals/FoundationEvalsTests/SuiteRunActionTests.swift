import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct SuiteRunActionTests {
    @Test func appFeatureCanSaveItsInputsWithoutUnusedDesktopModelSettings() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.draftSuite.scoringMode = .exactMatch
        fixture.store.draftSuite.cases = [EvaluationCase(name: "App input", prompt: "Echo this", expected: "Echo this")]
        fixture.store.draftSuite.modelConfiguration.provider = .customHTTP
        fixture.store.draftSuite.modelConfiguration.customProviderSettings.endpoint = "unused-invalid-endpoint"
        #expect(fixture.store.validationIssue(for: fixture.store.draftSuite, includeModelReadiness: false) != nil)
        #expect(fixture.store.developerFeatureValidationIssue(for: fixture.store.draftSuite) == nil)
        #expect(fixture.store.saveSuite(forDeveloperFeature: true))
        let reloaded = EvaluationStore(supportDirectory: fixture.directory)
        #expect(reloaded.suite == fixture.store.draftSuite)
        #expect(reloaded.validationIssue(for: reloaded.suite, includeModelReadiness: false) != nil)
        // The same UI admission helper rejects inputs the connected protocol
        // cannot carry, instead of reporting a valid run and dropping them.
        fixture.store.draftSuite.cases[0].conversation.setupTurns = [.init(prompt: "Remember this")]
        #expect(fixture.store.developerFeatureValidationIssue(for: fixture.store.draftSuite)?.contains("conversation history") == true)
        #expect(!fixture.store.saveSuite(forDeveloperFeature: true))
    }

    @Test func unavailableDeviceDoesNotFallBackToLocalExecution() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.runners.selectedRunnerID = UUID()
        fixture.runners.selectedFeatureID = "test.echo"

        #expect(!fixture.runners.canStartRun(for: fixture.store))
        #expect(throws: EvaluationStoreError.self) {
            try fixture.runners.startSelectedRun(for: fixture.store)
        }
        #expect(fixture.store.activeRun == nil)
        #expect(!fixture.store.isRunning)
        #expect(fixture.store.runs.isEmpty)
        #expect(fixture.store.notice == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func deviceCancellationUsesTrackedTaskAndBlocksRunUntilTeardown() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runID = UUID()

        let cancelled: Bool = await withCheckedContinuation { completion in
            fixture.runners.startTrackedExecution(runID: runID) {
                // A device evaluation has no local activeRun or local runTask.
                try? await Task.sleep(for: .seconds(1))
                completion.resume(returning: Task.isCancelled)
            }
            #expect(fixture.store.activeRun == nil)
            #expect(fixture.runners.canCancelRun(for: fixture.store))
            #expect(!fixture.runners.canStartRun(for: fixture.store))
            // This Mac may still be selected while a device task is dispatched.
            #expect(fixture.runners.selectedRunnerID == nil)
            #expect(throws: EvaluationStoreError.self) {
                try fixture.runners.startSelectedRun(for: fixture.store)
            }

            fixture.runners.cancelCurrentRun(for: fixture.store)
            #expect(fixture.runners.executingRunID == runID)
            #expect(!fixture.runners.canStartRun(for: fixture.store))
        }

        #expect(cancelled)
        #expect(fixture.runners.executingRunID == nil)
        #expect(!fixture.runners.canCancelRun(for: fixture.store))
    }

    @Test(.timeLimit(.minutes(1)))
    func localRunAndCancelStillUseTheLocalEvaluator() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = try LifecycleCustomModelFixture()
        defer { model.stop() }
        fixture.store.draftSuite.scoringMode = .exactMatch
        fixture.store.draftSuite.cases = [EvaluationCase(
            name: "Local command", prompt: "Return the fixture response.",
            expected: "Deterministic fixture stream."
        )]
        fixture.store.draftSuite.modelConfiguration.provider = .customHTTP
        fixture.store.draftSuite.modelConfiguration.customProviderSettings.endpoint = model.endpoint(path: "/text")

        #expect(fixture.runners.canStartRun(for: fixture.store))
        try fixture.runners.startSelectedRun(for: fixture.store)
        let runID = try #require(fixture.store.activeRun?.id)
        #expect(fixture.runners.executingRunID == nil)
        #expect(fixture.runners.canCancelRun(for: fixture.store))

        fixture.runners.cancelCurrentRun(for: fixture.store)
        #expect(fixture.store.activeRun?.cancellationRequested == true)
        for _ in 0..<200 where fixture.store.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!fixture.store.isRunning)
        #expect(fixture.store.run(with: runID)?.cancelled == true)
        #expect(!fixture.runners.canCancelRun(for: fixture.store))
    }

    @Test func fileProcessingDisablesAndRejectsRun() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.isProcessingFiles = true

        #expect(!fixture.runners.canStartRun(for: fixture.store))
        #expect(throws: EvaluationStoreError.self) {
            try fixture.runners.startSelectedRun(for: fixture.store)
        }
        #expect(fixture.store.activeRun == nil)
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let store: EvaluationStore
        let runners: DeveloperRunnerStore

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = EvaluationStore(supportDirectory: directory)
            runners = DeveloperRunnerStore(evaluationStore: store)
        }

        func cleanup() {
            runners.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
