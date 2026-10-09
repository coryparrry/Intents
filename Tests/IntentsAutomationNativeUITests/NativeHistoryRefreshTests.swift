#if os(macOS)
import Foundation
import Testing
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

struct NativeHistoryRefreshTests {
    @MainActor @Test func terminalCancellationDuringHeldHistoryRefreshCannotReopenRequest() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for cancelled in [false, true] {
            let reader = HeldAutomationCaseReader(), execution = AutomationCommandExecutionCounter()
            let model = commandStore(root: root, savedCasesReader: { await reader.read() }, runExecutor: { _, plan, approval, _, attemptID, _ in
                await execution.record()
                if cancelled { throw CancellationError() }
                let receipt = AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: attemptID, segmentID: plan.execution.id, leaseGeneration: 1),
                    app: plan.app, target: plan.target, segmentID: plan.execution.id, route: plan.execution.kind, dispatched: true, completed: true, environmentID: plan.environmentID)
                return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: true, subjectCompleted: true, observations: []), receipts: [receipt], resourcesReleased: true)
            })
            do {
                let preview = try model.previewCommand(), id = UUID()
                _ = try model.requestCommand(id: id, digest: preview.digest)
                model.run() // Simulates the native confirmation handler; the remote request alone never calls it.
                guard await reader.waitUntilHeld() else {
                    await reader.finish()
                    await model.closeAndWait()
                    Issue.record("The saved-case reader never entered its held refresh.")
                    return
                }
                let terminal = cancelled ? "cancelled" : "completed"
                #expect(try model.commandStatus(id: id).state == terminal)
                #expect(try model.cancelCommand(id: id).state == terminal)
                #expect(try model.requestCommand(id: id, digest: preview.digest).state == terminal)
                #expect(model.pendingCommandStatus == nil)
                await reader.finish()
                await model.closeAndWait()
                #expect(try model.commandStatus(id: id).state == terminal)
                #expect(await execution.calls == 1)
            } catch {
                await reader.finish()
                await model.closeAndWait()
                throw error
            }
        }
    }
    @Test func heldReaderEntryWaitIsBoundedAndLateReadCanBeReleased() async {
        let reader = HeldAutomationCaseReader()
        #expect(!(await reader.waitUntilHeld(timeout: 0.02)))
        await reader.finish()
        #expect(await reader.read().isEmpty)
    }
    @MainActor private func commandStore(root: URL, savedCasesReader: (@Sendable () async throws -> [AutomationFrozenCase])? = nil,
                                        runExecutor: AutomationNativeRunExecutor? = nil) -> AppAutomationStore {
        let app = AppIdentity(logicalID: "fixture", bundleID: "example.Fixture", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "unit-target", kind: .simulator)
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [.init(id: "ReadText", typeName: "ReadText", title: "Read text", parameters: [.init(name: "text", family: "text", optional: false)], parametersComplete: true, compiled: true, registered: false, executed: false)], systemDiscoveryComplete: true, uiDiscoveryComplete: false, gaps: [])
        let model = AppAutomationStore(supportDirectory: root, savedCasesReader: savedCasesReader, runExecutor: runExecutor)
        model.candidateID = "fixture"; model.configuration = "Debug"; model.simulatorID = target.id
        model.catalog = catalog; model.actionID = "ReadText"; model.inputs = ["text": "Original input"]
        model.effectChoice = "read"; model.effectsConfirmed = true
        model.prepared = .init(source: .init(sourceRoot: root.path, files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "unused", bundleID: "example.Host", configuration: "Debug", templateDigest: String(repeating: "b", count: 64)),
            host: .init(app: app, target: target, xctestrunPath: "unused", xctestrunDigest: String(repeating: "c", count: 64), subjectProductPath: "unused", hostBundlePath: "unused", hostProductDigest: String(repeating: "d", count: 64), hostBundleID: "example.Host", testTarget: "unused"), catalog: catalog, buildLogPath: "unused", buildLogTruncated: false)
        return model
    }
}

private actor AutomationCommandExecutionCounter {
    var calls = 0
    func record() { calls += 1 }
}
private actor HeldAutomationCaseReader {
    var started = false
    private let entrySignal = AsyncStream<Bool>.makeStream()
    private var pending: CheckedContinuation<[AutomationFrozenCase], Never>?
    private var finished = false
    func read() async -> [AutomationFrozenCase] {
        started = true
        if finished { return [] }
        return await withCheckedContinuation {
            pending = $0
            entrySignal.continuation.yield(true)
            entrySignal.continuation.finish()
        }
    }
    func waitUntilHeld(timeout: TimeInterval = 30) async -> Bool {
        let signal = entrySignal
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.setEventHandler {
            signal.continuation.yield(false)
            signal.continuation.finish()
        }
        timer.schedule(deadline: .now() + timeout)
        timer.resume()
        defer { timer.cancel() }
        return await signal.stream.first(where: { _ in true }) ?? false
    }
    func finish() { finished = true; pending?.resume(returning: []); pending = nil }
}

#endif
