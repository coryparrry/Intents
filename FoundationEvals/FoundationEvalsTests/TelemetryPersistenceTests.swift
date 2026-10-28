import Foundation
import Testing
@testable import FoundationEvals

@MainActor struct TelemetryPersistenceTests {
    /// Every damaged subsidiary file must fail the enclosing workspace load, without exposing its contents.
    @Test(arguments: ["suite.json", "suite-draft.json", "state.json", "active-run.json",
                      "pending-completed-runs.json", "Runs/corrupt.json", "SnapshotRuns/corrupt.json",
                      "judge-connections.json"])
    func subsidiaryLoadFailuresReachWorkspaceOutcome(filename: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seed = EvaluationStore(supportDirectory: directory)
        let target = filename == "judge-connections.json" ? directory : suiteDirectory(seed, root: directory)
        await seed.closeAndWait()
        let url = target.appending(path: filename)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("private fixture contents must never be diagnostic properties".utf8).write(to: url)
        let telemetry = recorder()
        let store = EvaluationStore(supportDirectory: directory, telemetry: telemetry)
        let finished = try #require(outcomes(telemetry, operation: "workspace_load").last)
        #expect(finished["outcome"] == "failed")
        #expect(finished["error_code"] == "storage")
        #expect(!telemetry.diagnosticReport().contains("private fixture contents"))
        await store.closeAndWait()
    }

    /// Fresh workspaces, preserved stale drafts, and successfully recovered interrupted runs remain successful loads.
    @Test(arguments: ["fresh", "stale-draft", "interrupted-run", "missing-suite"])
    func loadOutcomesDistinguishRecoveryNoticesFromFailure(scenario: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seed = EvaluationStore(supportDirectory: directory)
        let target = suiteDirectory(seed, root: directory)
        await seed.closeAndWait()
        let runID = UUID()
        if scenario == "stale-draft" {
            let draft = PersistenceDraftFixture(canonicalRevision: "obsolete-revision", suite: seed.suite)
            try CanonicalJSON.data(for: draft).write(to: target.appending(path: "suite-draft.json"))
        } else if scenario == "interrupted-run" {
            let checkpoint = PersistenceCheckpointFixture(
                summary: EvaluationActiveRun(id: runID, suiteRevision: try seed.currentSuiteRevision(),
                    startedAt: Date(), completedSamples: 0, totalSamples: 1, cancellationRequested: false,
                    projectID: seed.selectedProjectID, suiteID: seed.selectedSuiteID),
                suite: seed.suite, results: []
            )
            try CanonicalJSON.data(for: checkpoint).write(to: target.appending(path: "active-run.json"))
        } else if scenario == "missing-suite" {
            try FileManager.default.removeItem(at: target.appending(path: "suite.json"))
        }
        let telemetry = recorder()
        let store = EvaluationStore(supportDirectory: directory, telemetry: telemetry)
        let finished = try #require(outcomes(telemetry, operation: "workspace_load").last)
        #expect(finished["outcome"] == (scenario == "missing-suite" ? "failed" : "succeeded"))
        if scenario == "interrupted-run" {
            #expect(store.run(with: runID)?.terminationReason == "interrupted")
            #expect(store.notice != nil)
        }
        if scenario == "stale-draft" { #expect(store.notice != nil) }
        await store.closeAndWait()
    }

    /// Snapshot progress emits at most one issue despite repeated failures and keeps boundary writes observable.
    @Test(arguments: [false, true])
    func snapshotProgressFailuresAreBounded(failProgress: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let telemetry = recorder()
        var writes = 0
        let store = EvaluationStore(supportDirectory: directory, telemetry: telemetry, checkpointWriter: { data, url in
            writes += 1
            if failProgress, (2...5).contains(writes) { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        try prepareFeatureSuite(store, repetitions: 4)
        let run = try await store.runFeatureAdapterSnapshot(
            id: UUID(), projectID: store.selectedProjectID, suite: store.suite,
            expectedRevision: store.currentSuiteRevision(),
            adapter: ClosureFeatureAdapter(displayName: "Persistence fixture") { _ in "RESULT" }
        )
        #expect(run.results.count == 4)
        #expect(writes == 6)
        let checkpoints = outcomes(telemetry, operation: "run_checkpoint")
        #expect(checkpoints.count == 2)
        #expect(checkpoints.allSatisfy { $0["outcome"] == "succeeded" })
        let issues = telemetry.recentDiagnostics.filter {
            $0.event == "foundation_evals_diagnostic_issue" && $0.properties["operation"] == "run_checkpoint"
        }
        #expect(issues.count == (failProgress ? 1 : 0))
        if failProgress { #expect(issues.first?.properties["error_code"] == "permission") }
        #expect(outcomes(telemetry, operation: "run_save").last?["outcome"] == "succeeded")
        await store.closeAndWait()
    }

    /// Snapshot progress keeps the initial checkpoint's consent generation after diagnostic sharing changes.
    @Test func snapshotProgressDoesNotUploadAcrossConsentChanges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsName = "TelemetryPersistenceConsent.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(false, forKey: TelemetryController.consentKey)
        let client = DiagnosticRecordingClient()
        let telemetry = TelemetryController(defaults: defaults,
            configuration: .init(projectToken: "phc_test", host: "https://telemetry.invalid"),
            makeClient: { _ in client }, discardPendingCrashes: {})
        var writes = 0
        let store = EvaluationStore(supportDirectory: directory, telemetry: telemetry, checkpointWriter: { data, url in
            writes += 1
            if writes == 3 { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        try prepareFeatureSuite(store, repetitions: 2)
        _ = try await store.runFeatureAdapterSnapshot(
            id: UUID(), projectID: store.selectedProjectID, suite: store.suite,
            expectedRevision: store.currentSuiteRevision(),
            adapter: ClosureFeatureAdapter(displayName: "Persistence fixture") { _ in "RESULT" }
        ) { completed, _ in
            if completed == 1 { await MainActor.run { telemetry.setDiagnosticsEnabled(true) } }
        }
        #expect(telemetry.recentDiagnostics.contains {
            $0.event == "foundation_evals_diagnostic_issue" && $0.properties["operation"] == "run_checkpoint"
        })
        #expect(!client.events.contains { $0.name == "foundation_evals_diagnostic_issue" })
        #expect(client.events.contains {
            $0.name == "foundation_evals_operation_finished" && $0.properties["operation"] as? String == "run_save"
        })
        await store.closeAndWait()
    }

    /// Repeated active progress write failures emit one issue while completed results still reach history.
    @Test(.timeLimit(.minutes(1)))
    func activeProgressFailuresAreBounded() async throws {
        let fixture = try LifecycleCustomModelFixture()
        defer { fixture.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let telemetry = recorder()
        var writes = 0
        let store = EvaluationStore(supportDirectory: directory, telemetry: telemetry, checkpointWriter: { data, url in
            writes += 1
            if writes > 1 { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        try prepareFeatureSuite(store, repetitions: 3)
        store.draftSuite.cases[0].expected = "Deterministic fixture stream."
        store.draftSuite.modelConfiguration.provider = .customHTTP
        store.draftSuite.modelConfiguration.customProviderSettings.endpoint = fixture.endpoint(path: "/text")
        try #require(store.saveSuite())
        let id = UUID()
        _ = try store.startRun(id: id, expectedRevision: store.currentSuiteRevision())
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let finished = !store.isRunning
        await store.closeAndWait()
        try #require(finished)
        #expect(store.run(with: id)?.results.count == 3)
        #expect(writes == 4)
        #expect(outcomes(telemetry, operation: "run_checkpoint").count == 1)
        #expect(telemetry.recentDiagnostics.filter {
            $0.event == "foundation_evals_diagnostic_issue" && $0.properties["operation"] == "run_checkpoint"
        }.count == 1)
        #expect(outcomes(telemetry, operation: "run_save").last?["outcome"] == "succeeded")
    }

    /// Active evaluations finish telemetry after history storage and retain execution failure or cancellation priority.
    @Test(.timeLimit(.minutes(1)), arguments: ["saved", "storage", "execution", "cancelled"])
    func activeEvaluationOutcomesRequireSavedHistory(scenario: String) async throws {
        let fixture = try LifecycleCustomModelFixture()
        defer { fixture.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsName = "TelemetryHistoryOutcome.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: TelemetryController.consentKey)
        let client = DiagnosticRecordingClient()
        let telemetry = TelemetryController(defaults: defaults,
            configuration: .init(projectToken: "phc_test", host: "https://telemetry.invalid"),
            makeClient: { _ in client }, discardPendingCrashes: {})
        var writes = 0
        let store = EvaluationStore(supportDirectory: directory, telemetry: telemetry, runWriter: { data, url in
            writes += 1
            #expect(outcomes(telemetry, operation: "evaluation").isEmpty)
            #expect(!client.events.contains {
                $0.name == "intents_feature_used" && $0.properties["feature"] as? String == "evaluation"
            })
            if scenario != "saved" { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        try prepareFeatureSuite(store)
        store.draftSuite.cases[0].expected = "Deterministic fixture stream."
        store.draftSuite.modelConfiguration.provider = .customHTTP
        store.draftSuite.modelConfiguration.customProviderSettings.endpoint = fixture.endpoint(
            path: scenario == "execution" ? "/error" : "/text"
        )
        try #require(store.saveSuite())
        let id = UUID()
        _ = try store.startRun(id: id, expectedRevision: store.currentSuiteRevision())
        if scenario == "cancelled" { _ = try store.cancelRun(id: id) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let finished = !store.isRunning
        await store.closeAndWait()
        try #require(finished)
        #expect(writes == 1)
        let run = try #require(store.run(with: id))
        if scenario == "saved" || scenario == "storage" {
            #expect(run.results.first?.response == "Deterministic fixture stream.")
            #expect(run.results.first?.status == .passed)
        }
        let evaluations = outcomes(telemetry, operation: "evaluation")
        #expect(evaluations.count == 1)
        let evaluation = try #require(evaluations.first)
        let expectedFailure: String? = switch scenario {
        case "storage": "storage"
        case "execution": "provider"
        case "cancelled": "cancelled"
        default: nil
        }
        #expect(evaluation["error_code"] == expectedFailure)
        #expect(evaluation["outcome"] == (scenario == "saved" ? "succeeded" : scenario == "cancelled" ? "cancelled" : "failed"))
        let features = client.events.filter {
            $0.name == "intents_feature_used" && $0.properties["feature"] as? String == "evaluation"
        }
        #expect(features.count == (scenario == "saved" ? 1 : 0))
        #expect(store.hasUnsavedCompletedRun == (scenario != "saved"))
        #expect(store.runs.contains { $0.id == id } == (scenario == "saved"))
        let saves = outcomes(telemetry, operation: "run_save")
        #expect(saves.count == 1)
        #expect(saves.first?["outcome"] == (scenario == "saved" ? "succeeded" : "failed"))
        #expect(saves.first?["error_code"] == (scenario == "saved" ? nil : "permission"))
    }

    /// A snapshot history writer's failure or cancellation is reported, and retry saves its existing output.
    @Test(arguments: ["permission", "cancelled"])
    func snapshotHistoryFailuresAndRetriesAreRecorded(failure: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let telemetry = recorder()
        var failWrite = true
        let store = EvaluationStore(supportDirectory: directory, telemetry: telemetry, runWriter: { data, url in
            if failWrite {
                if failure == "cancelled" { throw CancellationError() }
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        })
        try prepareFeatureSuite(store)
        let id = UUID()
        await #expect(throws: EvaluationStoreError.self) {
            try await store.runFeatureAdapterSnapshot(
                id: id, projectID: store.selectedProjectID, suite: store.suite,
                expectedRevision: store.currentSuiteRevision(),
                adapter: ClosureFeatureAdapter(displayName: "Persistence fixture") { _ in "RESULT" }
            )
        }
        let failed = try #require(outcomes(telemetry, operation: "run_save").last)
        #expect(failed["outcome"] == (failure == "cancelled" ? "cancelled" : "failed"))
        #expect(failed["error_code"] == failure)
        failWrite = false
        let saved = try #require(try store.retrySnapshotRunSave(
            id: id, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID
        ))
        #expect(saved.results.first?.response == "RESULT")
        #expect(outcomes(telemetry, operation: "run_save").last?["outcome"] == "succeeded")
        #expect(outcomes(telemetry, operation: "run_save").count == 2)
        await store.closeAndWait()
    }

    /// An initial active checkpoint failure is observed before any provider execution starts.
    @Test func initialActiveCheckpointFailureIsRecorded() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let telemetry = recorder()
        let store = EvaluationStore(supportDirectory: directory, telemetry: telemetry,
            checkpointWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        try prepareFeatureSuite(store)
        store.draftSuite.modelConfiguration.provider = .customHTTP
        store.draftSuite.modelConfiguration.customProviderSettings.endpoint = "http://127.0.0.1:12345/text"
        try #require(store.saveSuite())
        #expect(throws: EvaluationStoreError.self) {
            try store.startRun(id: UUID(), expectedRevision: store.currentSuiteRevision())
        }
        #expect(!store.isRunning)
        #expect(outcomes(telemetry, operation: "run_checkpoint").last?["outcome"] == "failed")
        #expect(outcomes(telemetry, operation: "run_checkpoint").last?["error_code"] == "permission")
    }

    /// Cancelling an evaluation still saves evidence; successful checkpoint writes are not mislabeled as cancelled.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func activeCancellationPreservesCheckpointAndSaveOutcomes(failCancellationWrite: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let telemetry = recorder()
        var writes = 0
        let store = EvaluationStore(supportDirectory: directory, telemetry: telemetry, checkpointWriter: { data, url in
            writes += 1
            if failCancellationWrite, writes == 2 { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        try prepareFeatureSuite(store)
        store.draftSuite.modelConfiguration.provider = .customHTTP
        store.draftSuite.modelConfiguration.customProviderSettings.endpoint = "http://127.0.0.1:12345/text"
        try #require(store.saveSuite())
        let id = UUID()
        _ = try store.startRun(id: id, expectedRevision: store.currentSuiteRevision())
        if failCancellationWrite {
            #expect(throws: EvaluationStoreError.self) { try store.cancelRun(id: id) }
        } else {
            _ = try store.cancelRun(id: id)
        }
        await store.closeAndWait()
        #expect(store.run(with: id)?.cancelled == true)
        let checkpoints = outcomes(telemetry, operation: "run_checkpoint")
        #expect(checkpoints.count == 2)
        #expect(checkpoints.first?["outcome"] == "succeeded")
        #expect(checkpoints.last?["outcome"] == (failCancellationWrite ? "failed" : "succeeded"))
        #expect(outcomes(telemetry, operation: "evaluation").last?["outcome"] == "cancelled")
        #expect(outcomes(telemetry, operation: "run_save").last?["outcome"] == "succeeded")
    }

    /// Creates a recorder with no configured transport and no production crash-cache interaction.
    private func recorder() -> TelemetryController {
        TelemetryController(defaults: UserDefaults(suiteName: "TelemetryPersistence.\(UUID())")!,
                            configuration: nil, discardPendingCrashes: {})
    }

    /// Selects operation finishes from the local content-free report without requiring diagnostic consent.
    private func outcomes(_ telemetry: TelemetryController, operation: String) -> [[String: String]] {
        telemetry.recentDiagnostics.filter {
            $0.event == "foundation_evals_operation_finished" && $0.properties["operation"] == operation
        }.map(\.properties)
    }

    /// Creates isolated workspace storage removed by each owning test.
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TelemetryPersistence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Resolves the selected suite's private fixture directory without using user storage.
    private func suiteDirectory(_ store: EvaluationStore, root: URL) -> URL {
        EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: root, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID
        )
    }

    /// Saves a deterministic exact-match suite that does not require a model or judge for feature execution.
    private func prepareFeatureSuite(_ store: EvaluationStore, repetitions: Int = 1) throws {
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.repetitions = repetitions
        store.draftSuite.cases = [EvaluationCase(name: "Fixture", prompt: "request", expected: "RESULT")]
        try #require(store.saveSuite())
    }
}

private struct PersistenceDraftFixture: Codable {
    var canonicalRevision: String
    var suite: EvaluationSuite
}

private struct PersistenceCheckpointFixture: Codable {
    var summary: EvaluationActiveRun
    var suite: EvaluationSuite
    var results: [EvaluationSampleResult]
}
