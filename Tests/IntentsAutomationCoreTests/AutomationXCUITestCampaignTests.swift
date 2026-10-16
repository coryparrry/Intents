#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationXCUITestCampaignTests: XCTestCase {
    func testWholeCaseReservesActualOperationsWithoutControllerCalls() async throws {
        let (plan, approval) = try fixture()
        let steps = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval,
            attemptID: "attempt", leaseGeneration: 1)
        let budget = try AutomationCampaignBudget(limits: .init())
        try await AutomationXCUITestCampaign.reserveBudget(steps, plan: plan, attemptID: "attempt", budget: budget)
        let usage = await budget.snapshot()
        XCTAssertEqual(usage.reservedSubjectOperations, 2)
        XCTAssertEqual(usage.reservedCleanupOperations, 2)
        XCTAssertEqual(usage.reservedUIActions, 3)
        XCTAssertEqual(usage.controllerCalls, 0)
    }

    func testDeterministicHostAcceptsZeroControllerBudget() async throws {
        var (plan, approval) = try fixture()
        plan.budget.controllerCalls = 0
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let steps = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "zero-model", leaseGeneration: 1)
        var limits = AutomationCampaignLimits(); limits.controllerCalls = 0
        let budget = try AutomationCampaignBudget(limits: limits)
        try await AutomationXCUITestCampaign.reserveBudget(steps, plan: plan, attemptID: "zero-model", budget: budget)
        let usage = await budget.snapshot()
        XCTAssertEqual(usage.controllerCalls, 0)
        XCTAssertEqual(usage.reservedUIActions, 3)
    }

    func testCleanupCannotBypassSharedActionLimit() async throws {
        let (plan, approval) = try fixture()
        let steps = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval,
            attemptID: "attempt", leaseGeneration: 1)
        var limits = AutomationCampaignLimits(); limits.uiActions = 2
        let budget = try AutomationCampaignBudget(limits: limits)
        do {
            try await AutomationXCUITestCampaign.reserveBudget(steps, plan: plan, attemptID: "attempt", budget: budget)
            XCTFail("The cleanup action exceeded the campaign limit")
        } catch {
            XCTAssertEqual(error as? AutomationCampaignBudgetError, .exhausted("UI actions"))
        }
        let usage = await budget.snapshot()
        XCTAssertEqual(usage.controllerCalls, 0)
        XCTAssertEqual(usage.reservedCleanupOperations, 0)
    }

    func testSimulatorAlreadyAbsentTerminationIsAcknowledgedWithoutAcceptingOtherErrors() {
        let absent = "domain=NSPOSIXErrorDomain, code=3: found nothing to terminate"
        XCTAssertTrue(AutomationXCUITestRouteDriver.terminationSucceeded(exitStatus: 3, output: absent))
        XCTAssertTrue(AutomationXCUITestRouteDriver.terminationSucceeded(exitStatus: 0, output: ""))
        XCTAssertFalse(AutomationXCUITestRouteDriver.terminationSucceeded(exitStatus: 13, output: absent))
        XCTAssertFalse(AutomationXCUITestRouteDriver.terminationSucceeded(exitStatus: 3, output: "permission denied"))
        XCTAssertFalse(AutomationXCUITestRouteDriver.terminationSucceeded(exitStatus: 3, output: "another domain: found nothing to terminate"))
    }

    func testBudgetOrCaseDeadlineFailureRetainsRootCampaignUntilOwnerFinishesSimulatorCleanup() async throws {
        for expiredCase in [false, true] {
            for releaseOnCompletion in [false, true] {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let file = root.appendingPathComponent("leases.json")
                let owner = try AutomationDeviceLeaseManager(storeURL: file), competitor = try AutomationDeviceLeaseManager(storeURL: file)
                let (plan, approval) = try fixture()
                try await owner.reserveCampaign(runID: approval.runID, target: plan.target)
                var limits = AutomationCampaignLimits(); limits.uiActions = expiredCase ? 1000 : 0
                let budget = try AutomationCampaignBudget(limits: limits)
                let prepared = AutomationPreparedAppleHost(app: plan.app, target: plan.target,
                    xctestrunPath: root.appendingPathComponent("unused.xctestrun").path, xctestrunDigest: String(repeating: "b", count: 64),
                    subjectProductPath: root.appendingPathComponent("unused-subject.app").path, hostBundlePath: root.appendingPathComponent("unused-host.app").path,
                    hostProductDigest: String(repeating: "c", count: 64), hostBundleID: "example.host.xctrunner", testTarget: "Host")
                let journal = try AutomationJournal(url: root.appendingPathComponent("journal.json"))
                let artifacts = try AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts"))
                let report = try await AutomationXCUITestCampaign.run(prepared: prepared, plan: plan, approval: approval,
                    capabilities: .init(), attemptID: "attempt", root: root, developerDirectory: URL(fileURLWithPath: "/unused"),
                    leases: owner, journal: journal, artifacts: artifacts, releaseVerifier: nil, campaignBudget: budget,
                    caseDeadline: expiredCase ? ContinuousClock.now.advanced(by: .seconds(-1)) : nil,
                    releaseCampaignOnCompletion: releaseOnCompletion)
                XCTAssertTrue(report.resourcesReleased)
                XCTAssertFalse(report.result.subjectDispatched)
                XCTAssertEqual(report.result.summary, expiredCase ? .timedOut : .infrastructureFailed)
                if !releaseOnCompletion {
                    do { try await competitor.reserveCampaign(runID: "competitor", target: plan.target); XCTFail("Cleanup root ownership was handed off") }
                    catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
                    let cleanup = try await owner.acquire(runID: approval.runID, target: plan.target, control: .system)
                    try await owner.release(cleanup, commandsDrained: true, ownedRunnerTerminated: true)
                    try await owner.releaseCampaign(runID: approval.runID, target: plan.target)
                }
                try await competitor.reserveCampaign(runID: "competitor", target: plan.target)
                try await competitor.releaseCampaign(runID: "competitor", target: plan.target)
            }
        }
    }

    private func fixture() throws -> (AutomationCase, RunApproval) {
        let app = AppIdentity(logicalID: "fixture", bundleID: "example.fixture", platform: "ios",
            productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "simulator", kind: .simulator)
        var subject = AutomationSegment(id: "subject", kind: .ui, phase: .subject,
            operation: "Open", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        subject.uiProgram = .init(operations: [.init(id: "open", kind: .tap, locator: .init(.testId, "open"))])
        var cleanup = subject; cleanup.id = "cleanup"; cleanup.phase = .cleanup
        let plan = AutomationCase(id: "workflow", app: app, target: target, environmentID: "disposable",
            execution: subject, cleanup: [cleanup])
        var approval = RunApproval(runID: "run", app: app, target: target, environmentID: plan.environmentID,
            effects: [.observe, .navigate], maximumActions: 30, disposable: true)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        return (plan, approval)
    }
}
#endif
