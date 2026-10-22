import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct MCPWorkspaceCompletionTests {
    @Test(arguments: [false, true])
    func lateWaiterRetainsItsOwnStateOrFailureAfterAnotherMutation(failed: Bool) async throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let completion = MCPWorkspaceControl.workflowCompletion(
            for: .init(name: "eval_experiment_run", arguments: .object([:])), store: store)
        completion.complete(error: failed ? "Operation A failed" : nil)
        let later = try store.createInstructionExperiment(name: "Operation B", candidateInstructions: "Later")
        store.notice = "Operation B failed"
        // A's tracker has deliberately not started consuming its result yet.
        let payload = await completion.wait()
        #expect(payload.isError == failed)
        if failed {
            #expect(payload.structuredContent.objectValue?["error"]?.objectValue?["message"] == .string("Operation A failed"))
        } else {
            let state = try #require(payload.structuredContent.objectValue?["localState"])
                .decode(EvaluationSuiteLocalState.self)
            #expect(state.experiments.isEmpty)
        }
        #expect(store.suiteLocalState.experiments.first?.id == later)
        #expect(store.notice == "Operation B failed")
    }

    @Test(.timeLimit(.minutes(1)))
    func lateJudgeTrackerRetainsFirstReportAfterSecondCheckCompletes() async throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = localConnection("A"), second = localConnection("B")
        try store.saveJudgeConnection(first, apiKey: nil)
        try store.saveJudgeConnection(second, apiKey: nil)
        let completion = MCPWorkspaceControl.workflowCompletion(
            for: .init(name: "eval_judge_checks_run", arguments: .object([:])), store: store)
        let finishedA = AsyncStream<Void>.makeStream()
        store.runJudgeChecks(connectionID: first.id) { error in
            completion.complete(error: error)
            finishedA.continuation.yield(())
            finishedA.continuation.finish()
        }
        for await _ in finishedA.stream { break }
        #expect(!store.isReassessing)
        let finishedB = AsyncStream<Void>.makeStream()
        store.runJudgeChecks(connectionID: second.id) { error in
            #expect(error == nil)
            finishedB.continuation.yield(())
            finishedB.continuation.finish()
        }
        for await _ in finishedB.stream { break }
        #expect(store.latestJudgeCheck?.connectionID == second.id)
        store.notice = "Later unrelated notice"
        let payload = await completion.wait()
        #expect(!payload.isError)
        let report = try #require(payload.structuredContent.objectValue?["report"])
            .decode(EvaluationJudgeCheckReport.self)
        #expect(report.connectionID == first.id)
        #expect(store.latestJudgeCheck?.connectionID == second.id)
    }

    @Test func targetMismatchRemainsAnErrorAfterSelectionIsRestored() async throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = store.selectedProjectID, suiteID = store.selectedSuiteID
        let completion = MCPWorkspaceControl.workflowCompletion(
            for: .init(name: "eval_reassess_run", arguments: .object([:])), store: store)
        _ = try store.createProject(name: "Other")
        completion.complete(error: nil)
        try store.switchWorkspace(projectID: projectID, suiteID: suiteID)
        let payload = await completion.wait()
        #expect(payload.isError)
        #expect(payload.structuredContent.objectValue?["error"]?.objectValue?["code"] == .string("needs_evidence"))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDoesNotConsumeAnotherOperationsCompletion() async {
        let first = MCPWorkspaceCompletion { _ in MCPControlService.committed(["operation": .string("A")]) }
        let waiter = Task { await first.wait() }
        waiter.cancel()
        let cancelled = await waiter.value
        #expect(cancelled.isError)
        #expect(cancelled.structuredContent.objectValue?["error"]?.objectValue?["code"] == .string("cancelled"))
        first.complete(error: nil)
        let second = MCPWorkspaceCompletion { _ in MCPControlService.committed(["operation": .string("B")]) }
        second.complete(error: nil)
        #expect(await second.wait().structuredContent.objectValue?["operation"] == .string("B"))
    }

    @Test func rejectedStoreOperationsAlwaysCompleteWithTheirOwnFailure() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String?] = []
        store.runExperiment(id: UUID()) { failures.append($0) }
        store.reassessRun(id: UUID(), connectionID: UUID()) { failures.append($0) }
        #expect(failures.count == 2)
        #expect(failures.allSatisfy { $0 != nil })
    }

    private func fixture() throws -> (EvaluationStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-completion-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (EvaluationStore(supportDirectory: root), root)
    }

    private func localConnection(_ name: String) -> EvaluationJudgeConnection {
        .init(id: UUID(), name: name, kind: .localCompatible, baseURL: "http://127.0.0.1:1234", modelID: "unused")
    }
}
