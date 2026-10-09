import XCTest
@testable import IntentsAutomationCore

final class AutomationCompletionTests: XCTestCase, @unchecked Sendable {
    func testLateCleanupProofCannotReleaseOwnershipOrStartApple() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppIdentity(logicalID: "app", bundleID: "example.app", platform: "ios")
        let target = TargetIdentity(id: "device", kind: .simulator)
        let plan = AutomationCase(id: "case", app: app, target: target, environmentID: "owned",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "subject"),
            setup: [.init(id: "setup", kind: .ui, phase: .setup, operation: "setup")])
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "owned",
            effects: [.observe], maximumActions: 10, disposable: true)
        let leases = AutomationDeviceLeaseManager(), driver = GatedCleanupDriver()
        let coordinator = try AutomationCoordinator(leases: leases, journal: .init(url: root.appendingPathComponent("journal.json")), cleanupTimeout: .milliseconds(100))
        let report = try await coordinator.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
        XCTAssertFalse(report.resourcesReleased); XCTAssertFalse(report.result.subjectDispatched)
        let ownedLease = await driver.lease
        let lease = try XCTUnwrap(ownedLease)
        await driver.finishCleanup()
        try await driver.waitForCompletion()
        let current = await leases.isCurrent(lease); XCTAssertTrue(current)
        do { _ = try await leases.acquire(runID: "other", target: target, control: .system); XCTFail("Late proof released target") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        let dispatched = await driver.dispatched; XCTAssertEqual(dispatched, ["setup"])
        XCTAssertFalse(report.resourcesReleased)
    }
    func testSlowVerifiedCleanupFinishesWithoutRepeatingExpiredExecution() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppIdentity(logicalID: "app", bundleID: "example.app", platform: "ios")
        let target = TargetIdentity(id: "device", kind: .simulator)
        var budget = AutomationBudget(); budget.wallClockSeconds = 1
        let plan = AutomationCase(id: "case", app: app, target: target, environmentID: "owned",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "subject"), budget: budget)
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "owned",
            effects: [.observe], maximumActions: 10, disposable: true)
        let leases = AutomationDeviceLeaseManager(), driver = SlowCleanupDriver()
        let coordinator = AutomationCoordinator(leases: leases, journal: try .init(url: root.appendingPathComponent("journal.json")))
        let report = try await coordinator.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
        XCTAssertTrue(report.executionSucceeded); XCTAssertTrue(report.resourcesReleased)
        let dispatches = await driver.dispatches; XCTAssertEqual(dispatches, 1)
        let next = try await leases.acquire(runID: "next", target: target, control: .ui)
        try await leases.release(next, commandsDrained: true, ownedRunnerTerminated: true)
    }
    func testUnresolvedCompletedSubjectCannotExitSuccessfully() {
        let result = AttemptResult(summary: .executedUnassessed, subjectDispatched: true, subjectCompleted: true,
            assessed: false, evidenceComplete: true, failedObservations: [], missingObservations: [])
        var report = AutomationAttemptReport(attemptID: "attempt", result: result, receipts: [], resourcesReleased: true)
        XCTAssertTrue(report.executionSucceeded)
        for summary in [AttemptResult.Summary.unresolved, .assertionFailed, .invalidFixture, .cancelled, .timedOut] {
            report.result.summary = summary; XCTAssertFalse(report.executionSucceeded)
        }
        report.result = result; report.result.evidenceComplete = false; XCTAssertFalse(report.executionSucceeded)
        report.result = result; report.result.subjectDispatchUncertain = true; XCTAssertFalse(report.executionSucceeded)
        report.result = result; report.resourcesReleased = false; XCTAssertFalse(report.executionSucceeded)
    }
    func testUIReadbackActivationNeedsNavigationApprovalBeforeDispatch() throws {
        let app = AppIdentity(logicalID: "app", bundleID: "example.app", platform: "ios")
        let target = TargetIdentity(id: "device", kind: .simulator)
        var observer = AutomationSegment(id: "readback", kind: .ui, phase: .observe, operation: "readback",
            effects: [.observe], lifecycle: .persistedStateAcrossSegments)
        observer.uiProgram = .init(operations: [.init(id: "value", kind: .observeProperty, locator: .init(.testId, "value"), property: "text")])
        var plan = AutomationCase(id: "case", app: app, target: target, environmentID: "owned",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "subject"), observations: [observer])
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "owned",
            effects: [.observe, .navigate], maximumActions: 10, disposable: true)
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        plan.observations[0].effects.insert(.navigate)
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        plan.observations[0].lifecycle = .noActivation
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
    }
}

private actor SlowCleanupDriver: AutomationRouteDriver {
    var dispatches = 0
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) {}
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) -> AutomationSegmentReceipt {
        dispatches += 1
        return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind,
            dispatched: true, completed: true, environmentID: plan.environmentID)
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
        try? await Task.sleep(for: .seconds(6))
        return .init(commandsDrained: true, runnerTerminated: true)
    }
}

private actor GatedCleanupDriver: AutomationRouteDriver {
    var lease: AutomationDeviceLeaseManager.Lease?
    var dispatched: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var completed = false
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) {}
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) -> AutomationSegmentReceipt {
        dispatched.append(segment.id)
        return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind,
            dispatched: true, completed: true, environmentID: plan.environmentID)
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
        self.lease = lease
        await withCheckedContinuation { gate = $0 }
        completed = true
        return .init(commandsDrained: true, runnerTerminated: true)
    }
    func finishCleanup() { gate?.resume(); gate = nil }
    func waitForCompletion() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !completed {
            guard ContinuousClock.now < deadline else { throw AutomationContractError.terminationUnverified }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
