import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct TelemetryDeveloperRunnerTests {
    /// Counts durable remote executions even when the model assertion fails, without including its private evidence.
    @Test(arguments: ["READY", "private-fixture-response"])
    func completedExecutionRequiresSavedHistoryAndIgnoresAssertionVerdict(response: String) async throws {
        let fixture = try TelemetryRunnerFixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator(adapter: TelemetryRunnerAdapter { _ in response })
        let id = try coordinator.runSelectedSuite(on: fixture.runner.id, featureID: fixture.feature.id)
        await coordinator.waitForRun(id)
        let saved = try #require(EvaluationStore(supportDirectory: fixture.root).run(with: id))
        #expect(saved.results.first?.status == (response == "READY" ? .passed : .failed))
        #expect(coordinator.status(for: id)?.phase == .completed)
        fixture.expectTerminal(outcome: "succeeded", failure: nil, featureCount: 1)
        #expect(!fixture.client.events.map { String(describing: $0.properties) }.joined().contains("private-fixture"))
        await coordinator.closeAndWait()
    }

    /// Uses the real feature-run persistence path to distinguish structured remote termination from evaluation assertions.
    @Test(arguments: [DeveloperExecutionErrorCode.deadlineExceeded, .disconnected, .cancelled, .executionFailed])
    func runtimeFailuresNeverCountAsSuccessfulUse(code: DeveloperExecutionErrorCode) async throws {
        let fixture = try TelemetryRunnerFixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator(adapter: TelemetryRunnerAdapter { _ in
            throw DeveloperExecutionFailure(code: code, message: "private-fixture-error")
        })
        let id = try coordinator.runSelectedSuite(on: fixture.runner.id, featureID: fixture.feature.id)
        await coordinator.waitForRun(id)
        #expect(EvaluationStore(supportDirectory: fixture.root).run(with: id) != nil)
        let category: String
        switch code {
        case .deadlineExceeded: category = "timeout"
        case .disconnected: category = "device_unavailable"
        case .cancelled: category = "cancelled"
        default: category = "generation"
        }
        fixture.expectTerminal(outcome: code == .cancelled ? "cancelled" : "failed", failure: category, featureCount: 0)
        await coordinator.closeAndWait()
    }

    /// A retained run is not completed use until its first execution saves; later recovery must not invent another execution.
    @Test func failedHistorySaveAndRecoveryDoNotCountSuccessfulExecution() async throws {
        let fixture = try TelemetryRunnerFixture()
        defer { fixture.cleanUp() }
        fixture.writes.failHistory = true
        let coordinator = fixture.coordinator(adapter: TelemetryRunnerAdapter { _ in "READY" })
        let id = try coordinator.runSelectedSuite(on: fixture.runner.id, featureID: fixture.feature.id)
        await coordinator.waitForRun(id)
        #expect(fixture.store.hasUnsavedCompletedRun)
        #expect(coordinator.status(for: id)?.phase == .failed)
        fixture.expectTerminal(outcome: "failed", failure: "storage", featureCount: 0)
        fixture.writes.failHistory = false
        fixture.store.retryPendingRunSave()
        #expect(!fixture.store.hasUnsavedCompletedRun)
        #expect(EvaluationStore(supportDirectory: fixture.root).run(with: id) != nil)
        fixture.expectTerminal(outcome: "failed", failure: "storage", featureCount: 0)
        await coordinator.closeAndWait()
    }

    /// Rejects a disconnected runner with one bounded failure before any asynchronous execution is admitted.
    @Test func admissionFailureEndsTheOperationWithoutExecution() async throws {
        let fixture = try TelemetryRunnerFixture()
        defer { fixture.cleanUp() }
        let coordinator = DeveloperRunnerStore(evaluationStore: fixture.store, desktopID: UUID(), runnerSnapshots: { [] })
        #expect(throws: DeveloperExecutionFailure.self) {
            try coordinator.runSelectedSuite(on: fixture.runner.id, featureID: fixture.feature.id)
        }
        #expect(coordinator.executingRunID == nil)
        fixture.expectTerminal(outcome: "failed", failure: "device_unavailable", featureCount: 0)
        await coordinator.closeAndWait()
    }

    /// Cancellation finishes once after the real feature run retains its terminal history, even when cancellation repeats.
    @Test(.timeLimit(.minutes(1))) func cancellationIsRecordedAfterOwnedExecutionFinishes() async throws {
        let fixture = try TelemetryRunnerFixture()
        defer { fixture.cleanUp() }
        let entered = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish() }
        let coordinator = fixture.coordinator(adapter: TelemetryRunnerAdapter { _ in
            entered.continuation.yield(())
            try await Task.sleep(for: .seconds(60))
            return "READY"
        })
        let id = try coordinator.runSelectedSuite(on: fixture.runner.id, featureID: fixture.feature.id)
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        coordinator.cancelRun(id)
        coordinator.cancelRun(id)
        await coordinator.waitForRun(id)
        #expect(EvaluationStore(supportDirectory: fixture.root).run(with: id)?.cancelled == true)
        fixture.expectTerminal(outcome: "cancelled", failure: "cancelled", featureCount: 0)
        await coordinator.closeAndWait()
    }
}

@MainActor
private final class TelemetryRunnerFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "TelemetryRunner-\(UUID())")
    let defaultsName = "TelemetryRunner.\(UUID())"
    let client = TelemetryRunnerRecordingClient()
    let writes = TelemetryRunnerWriteState()
    let store: EvaluationStore
    let runner: DeveloperRunnerSnapshot
    let feature = DeveloperFeatureDescriptor(id: "private-fixture-feature", displayName: "private-fixture-label", version: "1",
        inputTypeName: "FoundationEvalsDeveloper.DeveloperTextFeatureInput", outputTypeName: "String")

    /// Builds temporary history, isolated consent, and a fake telemetry destination without starting runner discovery.
    init() throws {
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: TelemetryController.consentKey)
        defaults.set(true, forKey: TelemetryController.diagnosticsConsentKey)
        let client = client, writes = writes
        let telemetry = TelemetryController(defaults: defaults,
            configuration: .init(projectToken: "phc_test", host: "https://telemetry.invalid"),
            makeClient: { _ in client }, discardPendingCrashes: {})
        store = EvaluationStore(supportDirectory: root, telemetry: telemetry, runWriter: { data, url in
            if writes.failHistory { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [.init(name: "private-fixture-case", prompt: "private-fixture-prompt", expected: "READY")]
        try #require(store.saveSuite())
        runner = .init(identity: .init(id: UUID(), displayName: "private-fixture-device", platform: .mac,
            operatingSystem: "fixture", hardwareModel: "fixture", appBundleIdentifier: "private-fixture.bundle", appVersion: "1"),
            features: [feature], state: .connected)
        client.events = []
    }

    /// Substitutes only transport execution while keeping the real evaluation history and coordinator telemetry boundaries.
    func coordinator(adapter: any EvaluationFeatureAdapter) -> DeveloperRunnerStore {
        let runner = runner, store = store
        return DeveloperRunnerStore(evaluationStore: store, desktopID: UUID(), runnerSnapshots: { [runner] },
            runOverride: { id, revision in
                try await store.runFeatureAdapter(id: id, expectedRevision: revision, adapter: adapter)
            })
    }

    /// Asserts a single paired operation and the exact number of successful feature-use events.
    func expectTerminal(outcome: String, failure: String?, featureCount: Int) {
        let starts = client.events.filter { $0.name == "foundation_evals_operation_started" && $0.properties["operation"] as? String == "app_intent_run" }
        let finishes = client.events.filter { $0.name == "foundation_evals_operation_finished" && $0.properties["operation"] as? String == "app_intent_run" }
        #expect(starts.count == 1 && finishes.count == 1)
        #expect(starts.first?.properties["operation_id"] as? String == finishes.first?.properties["operation_id"] as? String)
        #expect(finishes.first?.properties["outcome"] as? String == outcome)
        #expect(finishes.first?.properties["error_code"] as? String == failure)
        #expect(client.events.filter { $0.properties["feature"] as? String == "app_intent_run" }.count == featureCount)
    }

    /// Removes only this fixture's temporary storage and isolated preferences.
    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
}

@MainActor
private final class TelemetryRunnerWriteState {
    var failHistory = false
}

private struct TelemetryRunnerAdapter: EvaluationFeatureAdapter {
    let displayName = "private-fixture-adapter"
    let operation: @Sendable (EvaluationFeatureInput) async throws -> String

    /// Returns deterministic synthetic output or a structured failure without contacting a runner or model.
    func evaluate(_ input: EvaluationFeatureInput) async throws -> EvaluationFeatureOutput {
        .init(response: try await operation(input))
    }
}

@MainActor
private final class TelemetryRunnerRecordingClient: TelemetryClient {
    var events: [TelemetryEvent] = []
    /// Retains typed events in memory so fixtures cannot upload synthetic data.
    func capture(_ event: TelemetryEvent) { events.append(event) }
    /// Has no pending transport queue to discard.
    func stopAndDiscard() {}
}
