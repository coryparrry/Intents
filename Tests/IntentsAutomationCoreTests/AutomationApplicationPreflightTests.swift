#if os(macOS)
import XCTest
import Synchronization
@testable import IntentsAutomationCore

final class AutomationApplicationPreflightTests: XCTestCase, @unchecked Sendable {
    func testMissingUIProgramStopsBeforeCreatingAnAttemptOrTouchingSimulator() async throws {
        try await rejectedBeforeMutation()
    }
    func testPreparationFailurePersistsWithoutInventingDispatchOrRelease() async throws {
        try await retainedPreparationFailure(error: .terminationUnverified, expectedSummary: .unresolved, released: false)
    }
    func testUnavailableTargetPersistsReleasedInfrastructureFailure() async throws {
        try await retainedPreparationFailure(error: .missingEvidence("fixture unavailable"), expectedSummary: .infrastructureFailed, released: true)
    }
    func testPersistenceFailureRetainsOriginalPreparationErrorAndTargetOwnership() async throws {
        try await retainedPreparationFailure(error: .terminationUnverified, expectedSummary: .unresolved, released: false, persistenceFails: true)
    }
    func testBothRoutesKeepTheCaseDeadlineThatStartedBeforeInventory() async throws {
        for ui in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try AutomationPreparedCodecRegressionTests.makeFixture(root: root.appendingPathComponent("prepared"))
            var plan = fixture.plan
            plan.budget.wallClockSeconds = 600
            if ui {
                plan.execution.kind = .ui; plan.execution.hostProgram = nil
                plan.execution.requiredCapabilities = []; plan.execution.effects = [.observe, .navigate]
                plan.execution.uiProgram = .init(operations: [.init(id: "open", kind: .tap, locator: .init(.testId, "open"))])
            }
            var approval = fixture.approval
            approval.effects = [.observe, .navigate]; approval.maximumActions = 10
            approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
            let target = plan.target, calls = PreparationInventoryCalls()
            // Model preflight having used the complete case: the runner's original
            // clock is fixed in the past, while each execution path sees real time.
            let started = ContinuousClock.now.advanced(by: .seconds(-601))
            let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: root,
                simulatorInventory: { _, _, timeout, deadline in
                    XCTAssertEqual(timeout, .seconds(600)); XCTAssertEqual(deadline, started.advanced(by: .seconds(600)))
                    await calls.increment()
                    return [.init(id: target.id, name: "Owned", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1", state: "Booted")]
                }, now: { started })
            let report = try await runner.run(prepared: fixture.prepared, plan: plan, approval: approval,
                capabilities: .init(), attemptID: "attempt", allowBootAndInstall: false)
            XCTAssertEqual(report.result.summary, .timedOut)
            XCTAssertFalse(report.result.subjectDispatched); XCTAssertTrue(report.receipts.isEmpty)
            XCTAssertTrue(report.resourcesReleased)
            let count = await calls.value; XCTAssertEqual(count, 1)
            let apple = root.appendingPathComponent("attempt/apple")
            if FileManager.default.fileExists(atPath: apple.path) {
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: apple.path).isEmpty)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attempt/xcuitest").path))
        }
    }
    func testInventoryUsesCampaignRemainderAndExpiryStopsBeforeDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try AutomationPreparedCodecRegressionTests.makeFixture(root: root.appendingPathComponent("prepared"))
        var plan = fixture.plan; plan.budget.wallClockSeconds = 600
        let start = ContinuousClock.now
        let clock = Mutex(start)
        var limits = AutomationCampaignLimits(); limits.wallClockSeconds = 100
        let budget = try AutomationCampaignBudget(limits: limits, now: { clock.withLock { $0 } })
        clock.withLock { $0 = start.advanced(by: .seconds(70)) }
        let target = plan.target, calls = PreparationInventoryCalls()
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: root,
            simulatorInventory: { _, _, timeout, deadline in
                XCTAssertEqual(timeout, .seconds(30)); XCTAssertEqual(deadline, start.advanced(by: .seconds(100)))
                await calls.increment()
                clock.withLock { $0 = start.advanced(by: .seconds(100)) }
                return [.init(id: target.id, name: "Owned", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1", state: "Booted")]
            }, now: { clock.withLock { $0 } })
        do {
            _ = try await runner.run(prepared: fixture.prepared, plan: plan, approval: fixture.approval,
                capabilities: .init(), attemptID: "attempt", allowBootAndInstall: false, campaignBudget: budget)
            XCTFail("Expired preflight dispatched")
        } catch { XCTAssertEqual(error as? AutomationRPCError, .timedOut) }
        let report = try JSONDecoder().decode(AutomationAttemptReport.self, from: Data(contentsOf: root.appendingPathComponent("attempt/report.json")))
        XCTAssertFalse(report.result.subjectDispatched); XCTAssertTrue(report.receipts.isEmpty)
        XCTAssertEqual(report.result.summary, .timedOut)
        XCTAssertTrue(report.resourcesReleased)
        let count = await calls.value; XCTAssertEqual(count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attempt/journal.json").path))
        do {
            _ = try await runner.run(prepared: fixture.prepared, plan: plan, approval: fixture.approval,
                capabilities: .init(), attemptID: "expired", allowBootAndInstall: false, campaignBudget: budget)
            XCTFail("Already-expired campaign queried inventory")
        } catch { XCTAssertEqual(error as? AutomationRPCError, .timedOut) }
        let finalCount = await calls.value; XCTAssertEqual(finalCount, 1)
    }
    private func retainedPreparationFailure(error: AutomationContractError, expectedSummary: AttemptResult.Summary, released: Bool, persistenceFails: Bool = false) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try AutomationPreparedCodecRegressionTests.makeFixture(root: root.appendingPathComponent("prepared"))
        let app = fixture.prepared.host.app
        let target = fixture.prepared.host.target
        let plan = AutomationCase(id: "preparation", app: app, target: target, environmentID: "disposable", execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Actual subject"))
        let prepared = fixture.prepared
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: plan.environmentID, effects: [.observe], maximumActions: 10, disposable: true)
        let calls = PreparationInventoryCalls()
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), simulatorInventory: { _, workspace, _, _ in
            await calls.increment()
            if persistenceFails { try FileManager.default.createDirectory(at: workspace.appendingPathComponent("report.json"), withIntermediateDirectories: false) }
            throw error
        })
        do { _ = try await runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", allowBootAndInstall: true); XCTFail("Preparation failed") }
        catch let caught {
            if persistenceFails { XCTAssertEqual((caught as? AutomationPreparationPersistenceFailure)?.preparationError as? AutomationContractError, error) }
            else { XCTAssertEqual(caught as? AutomationContractError, error) }
        }
        let observer = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
        do {
            let lease = try await observer.acquire(runID: "another-owner", target: target, control: .system)
            XCTAssertTrue(released, "Unproved preparation released target ownership")
            try await observer.release(lease, commandsDrained: true, ownedRunnerTerminated: true)
            try await observer.releaseCampaign(runID: "another-owner", target: target)
        } catch { XCTAssertFalse(released); XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        if persistenceFails {
            let cases = try AutomationCaseStore(root: root.appendingPathComponent("Cases"))
            let definitions = try await cases.definitions(); XCTAssertEqual(definitions.count, 1)
            let attempts = try await cases.attempts(for: XCTUnwrap(definitions.first)); XCTAssertTrue(attempts.isEmpty)
            return
        }
        let report = try JSONDecoder().decode(AutomationAttemptReport.self, from: Data(contentsOf: root.appendingPathComponent("attempt/report.json")))
        XCTAssertEqual(report.result.summary, expectedSummary); XCTAssertEqual(report.resourcesReleased, released)
        XCTAssertFalse(report.result.subjectDispatched); XCTAssertFalse(report.result.subjectCompleted)
        XCTAssertFalse(report.result.subjectDispatchUncertain); XCTAssertTrue(report.receipts.isEmpty)
        let recovered = try await runner.retainedAttempt(attemptID: "attempt", plan: plan, runID: approval.runID)
        XCTAssertEqual(recovered, report)
        var foreign = plan; foreign.execution.operation = "Different query"
        let otherPlan = try await runner.retainedAttempt(attemptID: "attempt", plan: foreign, runID: approval.runID)
        let otherRun = try await runner.retainedAttempt(attemptID: "attempt", plan: plan, runID: "foreign")
        XCTAssertNil(otherPlan); XCTAssertNil(otherRun)

        let cases = try AutomationCaseStore(root: root.appendingPathComponent("Cases"))
        let definitions = try await cases.definitions(); XCTAssertEqual(definitions.count, 1)
        let saved = try await cases.attempts(for: XCTUnwrap(definitions.first)); XCTAssertEqual(saved, [report])
        if !released {
            do { _ = try await runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt-retry", allowBootAndInstall: true); XCTFail("Same owner repeated uncertain preparation") }
            catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
            let count = await calls.value; XCTAssertEqual(count, 1)
            do { _ = try await observer.acquire(runID: "another-owner", target: target, control: .system); XCTFail("Failed reservation cleared earlier ownership") }
            catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        }

    }
    private func rejectedBeforeMutation() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try AutomationPreparedCodecRegressionTests.makeFixture(root: root.appendingPathComponent("prepared"))
        let app = fixture.prepared.host.app
        let target = fixture.prepared.host.target
        let plan = AutomationCase(id: "mixed", app: app, target: target, environmentID: "disposable",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Complete"),
            setup: [.init(id: "setup", kind: .ui, phase: .setup, operation: "Create")])
        let prepared = fixture.prepared
        var approval = RunApproval(runID: "run", app: app, target: target, environmentID: plan.environmentID,
            effects: [.observe], maximumActions: 10, disposable: true)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        do {
            _ = try await runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: .init(),
                attemptID: "attempt", allowBootAndInstall: true)
            XCTFail("A UI segment without concrete steps was allowed")
        } catch {
            XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Segment has no qualified XCUITest program"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attempt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Cases").path))
    }
}
private actor PreparationInventoryCalls {
    var value = 0
    func increment() { value += 1 }
}
#endif
