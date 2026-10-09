import Foundation
import Testing
@testable import FoundationEvals
@testable import IntentsAutomationCore

struct AutomationMCPTests {
    @Test func automationActionsRemainDiscoverableThroughTheCompactCatalog() throws {
        for name in ["eval_list_automation_apps", "eval_preview_automation", "eval_request_automation_run"] {
            let described = MCPActionDiscovery.respond(.describe(name: name))
            #expect(described.structuredContent.objectValue?["action"]?.objectValue?["name"]?.stringValue == name)
            #expect(!MCPToolCatalog.definitions.contains { $0.name == name })
        }
    }
    @Test func appSelectionSchemasCannotAdmitPathsOrExecutionAuthority() throws {
        let digest = String(repeating: "a", count: 64)
        #expect(try #require(MCPToolCatalog.allDefinitions.first { $0.name == "eval_list_automation_apps" }).annotations.readOnlyHint)
        #expect(!(try #require(MCPToolCatalog.allDefinitions.first { $0.name == "eval_select_automation_app" }).annotations.readOnlyHint))
        _ = try MCPToolCatalog.parse(name: "eval_select_automation_app", arguments: .object(["appID": .string("selected-source#TARGET"), "snapshotDigest": .string(digest)]))
        #expect(throws: MCPToolInputError.self) { try MCPToolCatalog.parse(name: "eval_list_automation_apps", arguments: .object(["path": .string("/private/tmp/foreign.app")])) }
        for extra in ["path", "run", "approval", "installApproved"] {
            #expect(throws: MCPToolInputError.self) { try MCPToolCatalog.parse(name: "eval_select_automation_app", arguments: .object(["appID": .string("known"), "snapshotDigest": .string(digest), extra: .bool(true)])) }
        }
        #expect(throws: MCPToolInputError.self) { try MCPToolCatalog.parse(name: "eval_select_automation_app", arguments: .object(["appID": .string(""), "snapshotDigest": .string(digest)])) }
    }
    @Test func executionRequestSchemasCannotCarryApprovalOrArbitraryPlans() throws {
        let id = UUID().uuidString, digest = String(repeating: "a", count: 64)
        for name in ["eval_preview_automation", "eval_preview_automation_reproduction", "eval_preview_automation_fix", "eval_get_automation_request"] {
            #expect(try #require(MCPToolCatalog.allDefinitions.first { $0.name == name }).annotations.readOnlyHint)
        }
        _ = try MCPToolCatalog.parse(name: "eval_request_automation_reproduction", arguments: .object(["requestID": .string(id), "digest": .string(digest)]))
        _ = try MCPToolCatalog.parse(name: "eval_request_automation_fix", arguments: .object(["requestID": .string(id), "digest": .string(digest)]))
        _ = try MCPToolCatalog.parse(name: "eval_request_automation_run", arguments: .object(["requestID": .string(id), "digest": .string(digest)]))
        for extra in ["approval", "plan", "installApproved", "originalAttemptID", "requestedAttempts"] {
            #expect(throws: MCPToolInputError.self) { try MCPToolCatalog.parse(name: "eval_request_automation_reproduction", arguments: .object(["requestID": .string(id), "digest": .string(digest), extra: .bool(true)])) }
            #expect(throws: MCPToolInputError.self) { try MCPToolCatalog.parse(name: "eval_request_automation_fix", arguments: .object(["requestID": .string(id), "digest": .string(digest), extra: .bool(true)])) }
            #expect(throws: MCPToolInputError.self) { try MCPToolCatalog.parse(name: "eval_request_automation_run", arguments: .object(["requestID": .string(id), "digest": .string(digest), extra: .bool(true)])) }
        }
        #expect(throws: MCPToolInputError.self) { try MCPToolCatalog.parse(name: "eval_preview_automation", arguments: .object(["run": .bool(true)])) }
    }
    @MainActor @Test func remoteRequestsWaitForNativeApprovalAndNeverRetryOrCancelOtherRuns() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = commandStore(root: root)
        let preview = try model.previewCommand(), id = UUID()
        let first = try model.requestCommand(id: id, digest: preview.digest)
        #expect(first.state == "awaitingApproval"); #expect(!model.busy); #expect(model.report == nil)
        #expect(try model.requestCommand(id: id, digest: preview.digest).state == "awaitingApproval")
        #expect(throws: AutomationContractError.self) { try model.requestCommand(id: id, digest: String(repeating: "b", count: 64)) }
        #expect(throws: AutomationContractError.self) { try model.cancelCommand(id: UUID()) }
        #expect(model.pendingCommandStatus?.requestID == id)
        #expect(try model.cancelCommand(id: id).state == "cancelled")
        #expect(try model.requestCommand(id: id, digest: preview.digest).state == "cancelled")
        #expect(model.pendingCommandStatus == nil); #expect(!model.busy)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @MainActor @Test func changedInputsInstallOrDisposableScopeInvalidateBeforeNativeDispatch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        for change in 0..<3 {
            let model = commandStore(root: root)
            let id = UUID(), preview = try model.previewCommand()
            _ = try model.requestCommand(id: id, digest: preview.digest)
            switch change {
            case 0: model.inputs["text"] = "Changed after preview"
            case 1: model.installApproved.toggle()
            default: model.disposable.toggle()
            }
            model.run()
            #expect(try model.commandStatus(id: id).state == "invalidated")
            #expect(!model.busy); #expect(model.report == nil)
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }
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
    @Test func readToolsHaveStrictSchemasAndReadOnlyAnnotations() throws {
        for name in ["eval_list_automation_cases", "eval_get_automation_attempt"] {
            let definition = try #require(MCPToolCatalog.allDefinitions.first { $0.name == name })
            #expect(definition.annotations.readOnlyHint)
        }
        _ = try MCPToolCatalog.parse(name: "eval_list_automation_cases", arguments: .object(["limit": .integer(1)]))
        for arguments in [MCPJSONValue.object(["limit": .integer(0)]), .object(["limit": .integer(51)]), .object(["run": .bool(true)]), .object(["cursor": .string("../case")])] {
            #expect(throws: MCPToolInputError.self) { try MCPToolCatalog.parse(name: "eval_list_automation_cases", arguments: arguments) }
        }
        #expect(throws: MCPToolInputError.self) {
            try MCPToolCatalog.parse(name: "eval_get_automation_attempt", arguments: .object(["caseID": .string("../case"), "revision": .integer(1), "digest": .string(String(repeating: "a", count: 64)), "attemptID": .string("attempt")]))
        }
    }
    @MainActor @Test func savedCaseReadsShareStoreWithoutDeviceOrBuildDispatch() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root), support = store.overviewStorageDirectory.appendingPathComponent("Automation")
        let automation = AppAutomationStore(supportDirectory: support)
        let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
        var app = AppIdentity(logicalID: "fixture", bundleID: "example.Fixture", platform: "ios")
        app.canonicalBundlePath = "/private/tmp/reviewed-fixture.app"
        let plan = AutomationCase(id: "saved", app: app, target: .init(id: "unit-target", kind: .simulator), environmentID: "unit",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "ContractAction"))
        let frozen = try await cases.freeze(plan)
        let receipt = AutomationSegmentReceipt(scope: .init(runID: "unit-run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 1), app: app, target: plan.target,
            segmentID: "subject", route: .systemIntent, dispatched: true, completed: true)
        let report = AutomationAttemptReport(attemptID: "attempt", result: AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: []), receipts: [receipt], resourcesReleased: true)
        try await cases.saveAttempt(report, for: frozen)
        let authority = MCPStoreAuthority.make(store: store, automationStore: automation)
        let listed = await authority.call(.listAutomationCases(.init(limit: 10, cursor: nil)))
        #expect(!listed.isError); #expect(listed.structuredContent.objectValue?["total"] == .integer(1))
        #expect(!(try listed.structuredContent.jsonText()).contains("/private/tmp"))
        let read = await authority.call(.getAutomationAttempt(.init(caseID: "saved", revision: 1, digest: frozen.digest, attemptID: "attempt")))
        #expect(!read.isError); #expect(read.structuredContent.objectValue?["result"]?.objectValue?["summary"] == .string("executedUnassessed"))
        #expect(automation.prepared == nil); #expect(automation.report == nil); #expect(!automation.busy)
        var other = plan; other.id = "other"; let otherFrozen = try await cases.freeze(other)
        let foreign = await authority.call(.getAutomationAttempt(.init(caseID: "other", revision: 1, digest: otherFrozen.digest, attemptID: "attempt")))
        #expect(foreign.isError)
    }
    @MainActor @Test func paginationRejectsChangedFrozenPopulation() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root), support = store.overviewStorageDirectory.appendingPathComponent("Automation")
        let automation = AppAutomationStore(supportDirectory: support), cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
        var plan = AutomationCase(id: "a", app: .init(logicalID: "fixture", bundleID: "example.Fixture", platform: "ios"), target: .init(id: "unit", kind: .simulator), environmentID: "unit",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "ContractAction"))
        _ = try await cases.freeze(plan); plan.id = "b"; _ = try await cases.freeze(plan)
        let authority = MCPStoreAuthority.make(store: store, automationStore: automation)
        let first = await authority.call(.listAutomationCases(.init(limit: 1, cursor: nil)))
        let cursor = try #require(first.structuredContent.objectValue?["nextCursor"]?.stringValue)
        let second = await authority.call(.listAutomationCases(.init(limit: 1, cursor: cursor)))
        #expect(!second.isError)
        plan.id = "c"; _ = try await cases.freeze(plan)
        let changed = await authority.call(.listAutomationCases(.init(limit: 1, cursor: cursor)))
        #expect(changed.isError)
    }
    @MainActor @Test func heldSavedReadCannotOverwriteNewSelectionOrCurrentResult() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = HeldAutomationSavedReader()
        let model = AppAutomationStore(supportDirectory: root, savedAttemptsReader: { frozen in try await reader.read(frozen) })
        let plan = AutomationCase(id: "fixture", app: .init(logicalID: "fixture", bundleID: "example.Fixture", platform: "ios"), target: .init(id: "unit", kind: .simulator), environmentID: "unit",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "ContractAction"))
        let frozen = try AutomationFrozenCase(plan: plan)
        let task = Task { await model.showSavedCase(frozen) }
        let deadline = Date().addingTimeInterval(2)
        while !(await reader.started) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let started = await reader.started; #expect(started)
        model.select(root.appendingPathComponent("unavailable-new-selection.xcodeproj"))
        let selectionMessage = model.message
        await reader.finish()
        await task.value
        #expect(model.report == nil); #expect(model.savedViewedReport == nil); #expect(model.message == selectionMessage)
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

private actor HeldAutomationSavedReader {
    var started = false
    private var pending: CheckedContinuation<[AutomationAttemptReport], Never>?
    private var finished = false
    func read(_ frozen: AutomationFrozenCase) async throws -> [AutomationAttemptReport] {
        started = true; if finished { return [] }; return await withCheckedContinuation { pending = $0 }
    }
    func finish() { finished = true; pending?.resume(returning: []); pending = nil }
}
