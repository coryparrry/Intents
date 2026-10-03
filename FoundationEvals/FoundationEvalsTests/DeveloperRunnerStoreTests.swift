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

    private func initialStatus(id: UUID) -> DeveloperRunStatus {
        .init(id: id, runnerID: UUID(), featureID: "fixture", phase: .running,
              completedSamples: 3, totalSamples: 7, detail: "Old progress")
    }

    private struct FixtureFailure: LocalizedError {
        var errorDescription: String? { "Fixture failure" }
    }
}
