import Foundation
import Testing
@testable import FoundationEvals

struct DeveloperRunnerStoreTests {
    @MainActor
    @Test(arguments: ["completed", "cancelled", "developerRunner:cancelled", "developerRunner:deadlineExceeded",
                      "developerRunner:disconnected", "assessmentUnavailable"])
    func terminalRunsReplaceProgressWithoutChangingIdentity(reason: String) throws {
        let (_, original) = try FeatureCompletionTestFixture.make()
        var run = original
        run.terminationReason = reason == "completed" ? nil : reason
        var status: DeveloperRunStatus? = initialStatus(id: run.id)
        let initial = try #require(status)
        DeveloperRunnerStore.projectCompletion(.success(run), status: &status)
        let projected = try #require(status)
        let expected: DeveloperRunPhase
        switch reason {
        case "completed": expected = .completed
        case "cancelled", "developerRunner:cancelled": expected = .cancelled
        case "developerRunner:deadlineExceeded": expected = .timedOut
        case "developerRunner:disconnected": expected = .disconnected
        default: expected = .failed
        }
        #expect(projected.phase == expected)
        #expect(projected.detail == run.terminationReason)
        #expect(projected.completedSamples == run.results.count)
        #expect(projected.totalSamples == initial.totalSamples)
        #expect(projected.id == initial.id)
        #expect(projected.runnerID == initial.runnerID)
        #expect(projected.featureID == initial.featureID)
    }

    @MainActor
    @Test func failuresPreserveProgressAndMapCancellationDeadlineDisconnectAndGenericErrors() throws {
        let failures: [(any Error, DeveloperRunPhase, String)] = [
            (CancellationError(), .cancelled, "Run cancelled."),
            (DeveloperExecutionFailure(code: .cancelled, message: "Remote cancelled"), .cancelled, "Remote cancelled"),
            (DeveloperExecutionFailure(code: .deadlineExceeded, message: "Deadline"), .timedOut, "Deadline"),
            (DeveloperExecutionFailure(code: .disconnected, message: "Disconnected"), .disconnected, "Disconnected"),
            (DeveloperExecutionFailure(code: .featureNotFound, message: "Missing feature"), .failed, "Missing feature"),
            (FixtureFailure(), .failed, "Fixture failure")
        ]
        for (error, phase, detail) in failures {
            var status: DeveloperRunStatus? = initialStatus(id: UUID())
            DeveloperRunnerStore.projectCompletion(.failure(error), status: &status)
            #expect(status?.phase == phase)
            #expect(status?.detail == detail)
            #expect(status?.completedSamples == 3)
            #expect(status?.totalSamples == 7)
        }
    }

    @MainActor
    @Test func absentRunEntriesStayAbsentForSuccessAndFailure() throws {
        let (_, run) = try FeatureCompletionTestFixture.make()
        var status: DeveloperRunStatus?
        DeveloperRunnerStore.projectCompletion(.success(run), status: &status)
        #expect(status == nil)
        DeveloperRunnerStore.projectCompletion(.failure(CancellationError()), status: &status)
        #expect(status == nil)
    }

    @MainActor
    @Test func automationAdmissionRejectsMatchingParentAndClearsOnlyItsOwnBlocker() throws {
        let admission = ScenarioExecutionAdmission()
        let parent = UUID(), firstAutomation = UUID(), secondAutomation = UUID()
        try admission.acquire(parent)
        #expect(admission.allows(parent))
        admission.setAutomationBlocked(true, ownerID: firstAutomation)
        admission.setAutomationBlocked(true, ownerID: secondAutomation)
        #expect(!admission.allows(parent))
        #expect(!admission.allows(nil))
        admission.release(parent)
        #expect(throws: EvaluationStoreError.self) { try admission.acquire(UUID()) }
        admission.setAutomationBlocked(false, ownerID: firstAutomation)
        #expect(!admission.allows(nil))
        #expect(throws: EvaluationStoreError.self) { try admission.acquire(UUID()) }
        admission.setAutomationBlocked(false, ownerID: secondAutomation)
        #expect(admission.allows(nil))
        try admission.acquire(parent)
        #expect(admission.allows(parent))
        admission.release(parent)
    }

    @MainActor
    @Test func pairedAutomationBlocksOrdinaryEvaluationBeforeSuiteValidation() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let evaluation = EvaluationStore(supportDirectory: root)
        let runners = DeveloperRunnerStore(evaluationStore: evaluation)
        runners.automationExecutionBlocked = true
        defer { runners.automationExecutionBlocked = false }
        do {
            _ = try evaluation.startRun(id: UUID(), expectedRevision: "unreviewed-suite")
            Issue.record("An ordinary evaluation started during paired automation.")
        } catch EvaluationStoreError.resourceConflict(let message) {
            #expect(message.contains("coordinated execution"))
        } catch {
            Issue.record("Expected admission to reject the run before suite validation: \(error)")
        }
        #expect(!evaluation.hasActiveExecution)
        runners.automationExecutionBlocked = false
        #expect(ScenarioExecutionAdmission.shared.allows(nil))
    }

    @MainActor
    @Test func pairedAutomationBlocksDeveloperSnapshotBeforeRunnerLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let evaluation = EvaluationStore(supportDirectory: root)
        let runners = DeveloperRunnerStore(evaluationStore: evaluation)
        runners.automationExecutionBlocked = true
        defer { runners.automationExecutionBlocked = false }
        let adapter = ClosureFeatureAdapter(displayName: "Unused paired-admission fixture") { _ in
            Issue.record("The adapter ran despite paired automation owning admission.")
            return "unexpected dispatch"
        }
        do {
            _ = try await runners.runFeatureSnapshot(id: UUID(), projectID: UUID(), suite: evaluation.suite,
                expectedRevision: "unreviewed-suite", runnerID: UUID(), featureID: "missing-runner", adapter: adapter)
            Issue.record("A developer snapshot started during paired automation.")
        } catch EvaluationStoreError.resourceConflict {
            #expect(runners.executingRunID == nil)
        } catch {
            Issue.record("Expected admission to reject the snapshot before runner lookup: \(error)")
        }
        runners.automationExecutionBlocked = false
        do {
            _ = try await runners.runFeatureSnapshot(id: UUID(), projectID: UUID(), suite: evaluation.suite,
                expectedRevision: "unreviewed-suite", runnerID: UUID(), featureID: "missing-runner", adapter: adapter)
            Issue.record("The fixture unexpectedly found a connected runner.")
        } catch let failure as DeveloperExecutionFailure {
            #expect(failure.code == .disconnected)
            #expect(runners.executingRunID == nil)
        } catch {
            Issue.record("Clearing the block should restore normal runner lookup: \(error)")
        }
    }

    @MainActor
    @Test func clearingOneRunnerStorePreservesOtherStoresAutomationBlock() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DeveloperRunnerStore(evaluationStore: EvaluationStore(supportDirectory: root.appending(path: "first")))
        let second = DeveloperRunnerStore(evaluationStore: EvaluationStore(supportDirectory: root.appending(path: "second")))
        first.automationExecutionBlocked = true
        second.automationExecutionBlocked = true
        defer {
            first.automationExecutionBlocked = false
            second.automationExecutionBlocked = false
        }
        first.automationExecutionBlocked = false
        #expect(!ScenarioExecutionAdmission.shared.allows(nil))
        let competingOwner = UUID()
        defer { ScenarioExecutionAdmission.shared.release(competingOwner) }
        #expect(throws: EvaluationStoreError.self) { try ScenarioExecutionAdmission.shared.acquire(competingOwner) }
        second.automationExecutionBlocked = false
        #expect(ScenarioExecutionAdmission.shared.allows(nil))
    }

    private func initialStatus(id: UUID) -> DeveloperRunStatus {
        .init(id: id, runnerID: UUID(), featureID: "fixture", phase: .running,
              completedSamples: 3, totalSamples: 7, detail: "Old progress")
    }

    private struct FixtureFailure: LocalizedError {
        var errorDescription: String? { "Fixture failure" }
    }
}
