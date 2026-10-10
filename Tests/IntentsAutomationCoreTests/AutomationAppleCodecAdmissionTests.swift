#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

private func checkCodecAdmission(plan original: AutomationCase, approval originalApproval: RunApproval,
                                 scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease,
                                 makeDriver: (RunApproval, CapabilityProfile) throws -> any AutomationRouteDriver,
                                 calls: () async -> [String]) async throws {
    var plan = original
    plan.execution.hostProgram?.operations[0].parameters = ["value": .text("Synthetic input")]
    plan.execution.requiredCapabilities = ["apple.codec.text"]
    var approval = originalApproval
    approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
    for state in [CapabilityProfile.State.unknown, .unavailable, .consentRequired] {
        let capabilities = CapabilityProfile(records: ["apple.codec.text": .init(state: state, reason: "Synthetic", probeVersion: "test", evidence: [])])
        let driver = try makeDriver(approval, capabilities)
        do {
            try await driver.acquire(plan: plan, segment: plan.execution, scope: scope, lease: lease)
            XCTFail("Unavailable conversion acquired a direct driver")
        } catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Input and result conversion has not been verified for this app and target")) }
        var wrong = scope; wrong.attemptId = "foreign"
        let foreign = await driver.release(scope: wrong, lease: lease)
        XCTAssertFalse(foreign.commandsDrained); XCTAssertFalse(foreign.runnerTerminated)
        let denied = await driver.release(scope: scope, lease: lease)
        XCTAssertTrue(denied.commandsDrained); XCTAssertTrue(denied.runnerTerminated)
        let observed = await calls(); XCTAssertTrue(observed.isEmpty)
    }
    let available = CapabilityProfile(records: ["apple.codec.text": .init(state: .available, reason: "Synthetic setter", probeVersion: "test", evidence: [])])
    var undeclared = plan; undeclared.execution.requiredCapabilities = []
    approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(undeclared)
    let undeclaredDriver = try makeDriver(approval, available)
    do {
        try await undeclaredDriver.acquire(plan: undeclared, segment: undeclared.execution, scope: scope, lease: lease)
        XCTFail("Missing frozen family acquired")
    } catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Input and result conversion has not been verified for this app and target")) }
    let missingProof = await undeclaredDriver.release(scope: scope, lease: lease)
    XCTAssertTrue(missingProof.commandsDrained); XCTAssertTrue(missingProof.runnerTerminated)
    var nullable = plan; nullable.execution.hostProgram?.operations[0].parameters = ["value": .null]
    approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(nullable)
    let nullableDriver = try makeDriver(approval, available)
    do {
        try await nullableDriver.acquire(plan: nullable, segment: nullable.execution, scope: scope, lease: lease)
        XCTFail("Unannotated null acquired")
    } catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Nullable input conversion lacks its frozen parameter family")) }
    let nullProof = await nullableDriver.release(scope: scope, lease: lease)
    XCTAssertTrue(nullProof.commandsDrained); XCTAssertTrue(nullProof.runnerTerminated)
    let observed = await calls(); XCTAssertTrue(observed.isEmpty)
    approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
    let driver = try makeDriver(approval, available)
    try await driver.acquire(plan: plan, segment: plan.execution, scope: scope, lease: lease)
    let proof = await driver.release(scope: scope, lease: lease)
    XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated)
    let released = await calls(); XCTAssertEqual(released.count, 2)
}

private func checkResolvedCodecAdmission(plan original: AutomationCase, approval originalApproval: RunApproval,
                                         scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease,
                                         makeDriver: (RunApproval) throws -> any AutomationResolvedRouteDriver,
                                         calls: () async -> [String]) async throws {
    var plan = original
    var query = AutomationSegment(id: "lookup", kind: .systemQuery, phase: .setup, operation: "Read", lifecycle: .persistedStateAcrossSegments)
    query.hostProgram = .init(operations: [.init(id: "records", kind: .query, typeID: "Entity", queryText: "Synthetic")])
    plan.setup = [query]
    plan.execution.inputBindings = [.init(producerSegmentID: "lookup", outputID: "records", destination: .hostParameter,
        operationID: plan.execution.hostProgram!.operations[0].id, name: "value")]
    var approval = originalApproval; approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
    XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
    let receipt = AutomationSegmentReceipt(scope: .init(runID: scope.runId, attemptID: scope.attemptId, segmentID: "lookup", leaseGeneration: 1),
        app: plan.app, target: plan.target, segmentID: "lookup", route: .systemQuery, dispatched: true, completed: true,
        verifiedOutputs: ["records": .array([])], environmentID: plan.environmentID)
    let resolved = try AutomationInputResolver.resolveForExecution(segment: plan.execution, receipts: [receipt], plan: plan,
        runID: scope.runId, attemptID: scope.attemptId)
    XCTAssertEqual(resolved.segment.hostProgram?.operations[0].parameters["value"], .array([]))
    let driver = try makeDriver(approval)
    do {
        try await driver.acquireResolved(plan: plan, segment: resolved.segment, scope: scope, lease: lease, authority: resolved.authority)
        XCTFail("Resolved undeclared collection acquired")
    } catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Input and result conversion has not been verified for this app and target")) }
    let observed = await calls(); XCTAssertTrue(observed.isEmpty)
    let proof = await driver.release(scope: scope, lease: lease)
    XCTAssertTrue(proof.commandsDrained); XCTAssertTrue(proof.runnerTerminated)
}

private func checkCoordinatorCodecDenial(plan original: AutomationCase, approval originalApproval: RunApproval,
                                        root: URL, leases: AutomationDeviceLeaseManager, initial: AutomationDeviceLeaseManager.Lease,
                                        makeDriver: (RunApproval) throws -> any AutomationRouteDriver,
                                        calls: () async -> [String]) async throws {
    try await leases.release(initial, commandsDrained: true, ownedRunnerTerminated: true)
    var plan = original; plan.execution.hostProgram?.operations[0].parameters = ["value": .text("Synthetic")]
    plan.execution.requiredCapabilities = ["apple.codec.text"]
    var approval = originalApproval; approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
    let capabilities = CapabilityProfile(records: ["apple.codec.text": .init(state: .available, reason: "Synthetic coordinator", probeVersion: "test", evidence: [])])
    let driver = try makeDriver(approval)
    let coordinator = AutomationCoordinator(leases: leases, journal: try .init(url: root.appendingPathComponent("codec-journal.json")))
    let report = try await coordinator.run(plan: plan, approval: approval, capabilities: capabilities, attemptID: "mismatch", driver: driver)
    XCTAssertTrue(report.resourcesReleased); XCTAssertFalse(report.result.subjectDispatched)
    let observed = await calls(); XCTAssertTrue(observed.isEmpty)
    let next = try await leases.acquire(runID: approval.runID, target: plan.target, control: .system)
    try await leases.release(next, commandsDrained: true, ownedRunnerTerminated: true)
}

extension AutomationAppleRouteDriverTests {
    func testResolvedSimulatorCodecIsCheckedBeforePreparation() async throws {
        let h = try await fixture()
        try await checkResolvedCodecAdmission(plan: h.plan, approval: h.approval, scope: h.scope, lease: h.lease,
            makeDriver: { try self.driver(h, approval: $0) }, calls: { await h.release.calls })
    }
    func testCoordinatorSimulatorProfileMismatchReleasesWithoutExternalWork() async throws {
        let h = try await fixture()
        try await checkCoordinatorCodecDenial(plan: h.plan, approval: h.approval, root: h.root, leases: h.leases, initial: h.lease,
            makeDriver: { try self.driver(h, approval: $0) }, calls: { await h.release.calls })
    }
    func testDirectSimulatorDriverRequiresCodecAdmissionBeforeControllerPreparation() async throws {
        let h = try await fixture()
        try await checkCodecAdmission(plan: h.plan, approval: h.approval, scope: h.scope, lease: h.lease,
            makeDriver: { try self.driver(h, approval: $0, capabilities: $1) }, calls: { await h.release.calls })
    }
}
extension AutomationPrivateMacAppleRouteDriverTests {
    func testResolvedMacCodecIsCheckedBeforePreparation() async throws {
        let h = try await fixture()
        try await checkResolvedCodecAdmission(plan: h.plan, approval: h.approval, scope: h.scope, lease: h.lease,
            makeDriver: { try self.driver(h, approval: $0) }, calls: { await h.release.calls })
    }
    func testCoordinatorMacProfileMismatchReleasesWithoutExternalWork() async throws {
        let h = try await fixture()
        try await checkCoordinatorCodecDenial(plan: h.plan, approval: h.approval, root: h.root, leases: h.leases, initial: h.lease,
            makeDriver: { try self.driver(h, approval: $0) }, calls: { await h.release.calls })
    }
    func testDirectMacDriverRequiresCodecAdmissionBeforeControllerPreparation() async throws {
        let h = try await fixture()
        try await checkCodecAdmission(plan: h.plan, approval: h.approval, scope: h.scope, lease: h.lease,
            makeDriver: { try self.driver(h, approval: $0, capabilities: $1) }, calls: { await h.release.calls })
    }
}
#endif
