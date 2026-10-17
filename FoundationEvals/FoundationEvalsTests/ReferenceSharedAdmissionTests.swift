import Foundation
import Testing
@testable import FoundationEvals

@Suite(.timeLimit(.minutes(1)))
struct ReferenceSharedAdmissionTests {
    @Test(arguments: [false, true])
    func exhaustedSharedAllowanceCapsAllRetainedEvidence(concurrent: Bool) async throws {
        let limiter = EvaluationToolCallLimiter(maximumCalls: 1)
        // A different tool has already consumed the shared allowance.
        try await limiter.beginCall()
        let workflow = EvaluationWorkflowRecorder()
        let parent = workflow.begin(kind: .generation, title: "Subject")
        workflow.activeParentID = parent
        let recorder = ReferenceToolRecorder(maximumCalls: 4, callLimiter: limiter, workflowRecorder: workflow)
        let tool = makeTool(recorder)
        let attempts = 128
        let successes = await attempt(tool, count: attempts, concurrent: concurrent)
        #expect(successes == 0)
        #expect(await recorder.attemptedCallTotal() == attempts)
        let traces = await recorder.snapshot()
        #expect(traces.count == ReferenceToolRecorder.maximumRecordedRejections)
        #expect(traces.allSatisfy { $0.outcome == "rejected" && $0.outputCharacterCount == 0 })
        let evidence = await recorder.evidenceText()
        #expect((evidence?.components(separatedBy: "Tool call ").count ?? 0) - 1 == traces.count)
        #expect((evidence?.utf8.count ?? 0) < 800)
        #expect(evidence?.contains("ORCHARD") == false)
        let spans = workflow.snapshot().spans.filter { $0.kind == .tool }
        #expect(spans.count == ReferenceToolRecorder.maximumRecordedRejections)
        #expect(spans.allSatisfy { $0.status == .failed && $0.parentID == parent })
        #expect(Set(spans.compactMap { $0.metadata["callIndex"].flatMap(Int.init) }) == Set(traces.map(\.callIndex)))
    }

    @Test(arguments: [false, true])
    func successfulCallsAndLaterSharedRejectionsHaveIndependentBounds(concurrent: Bool) async throws {
        let workflow = EvaluationWorkflowRecorder()
        let recorder = ReferenceToolRecorder(maximumCalls: 4,
            callLimiter: EvaluationToolCallLimiter(maximumCalls: 2), workflowRecorder: workflow)
        let tool = makeTool(recorder)
        for _ in 0..<2 {
            let output = try await tool.call(arguments: .init(query: "reference fact", maximumResults: 1))
            #expect(output.contains("ORCHARD"))
        }
        #expect(await attempt(tool, count: 128, concurrent: concurrent) == 0)
        #expect(await recorder.attemptedCallTotal() == 130)
        let traces = await recorder.snapshot()
        #expect(traces.filter { $0.outcome == "completed" }.count == 2)
        #expect(traces.filter { $0.outcome == "rejected" }.count == ReferenceToolRecorder.maximumRecordedRejections)
        let spans = workflow.snapshot().spans.filter { $0.kind == .tool }
        #expect(spans.count == 2 + ReferenceToolRecorder.maximumRecordedRejections)
        #expect(spans.filter { $0.status == .failed }.count == ReferenceToolRecorder.maximumRecordedRejections)
    }

    private func makeTool(_ recorder: ReferenceToolRecorder) -> ReferenceLookupTool {
        ReferenceLookupTool(index: .init(attachments: [
            .init(id: UUID(), name: "reference.txt", kind: .text,
                text: "The reference fact is ORCHARD.", storedFilename: nil, byteCount: 30, sha256: "fixture")
        ]), recorder: recorder)
    }

    private func attempt(_ tool: ReferenceLookupTool, count: Int, concurrent: Bool) async -> Int {
        if concurrent {
            return await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<count {
                    group.addTask {
                        do {
                            _ = try await tool.call(arguments: .init(query: "reference fact", maximumResults: 1))
                            return true
                        } catch { return false }
                    }
                }
                var successes = 0
                for await success in group where success { successes += 1 }
                return successes
            }
        }
        var successes = 0
        for _ in 0..<count {
            do {
                _ = try await tool.call(arguments: .init(query: "reference fact", maximumResults: 1))
                successes += 1
            } catch { }
        }
        return successes
    }
}
