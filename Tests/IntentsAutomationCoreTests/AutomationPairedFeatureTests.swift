#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationPairedFeatureTests: XCTestCase, @unchecked Sendable {
    private func fixture(expected: String? = "Actual response") throws -> (AutomationCase, RunApproval, URL) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("paired-campaign-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runnerID = UUID()
        var app = AppIdentity(logicalID: "selected-paired-app", bundleID: "example.RegisteredApp", platform: "ios")
        app.provenanceStrength = "pairedRegistration"
        var approval = RunApproval(runID: UUID().uuidString, app: app, target: .init(id: runnerID.uuidString, kind: .pairedRunner), environmentID: "trusted-registration", effects: [.observe], maximumActions: 1, disposable: false)
        let program = AutomationPairedFeatureProgram(runnerID: runnerID, registrationDigest: String(repeating: "a", count: 64), appVersion: "1.2", featureID: "summarize", featureVersion: "v2", instructions: "Summarize the supplied input", prompt: "A public subject input")
        let plan = try AutomationPairedFeaturePlanner.compile(app: app, program: program, approval: approval, expectedResponse: expected)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        return (plan, approval, root)
    }
    func testRunsRegisteredFeatureOnceReadsResponseSeparatelyAndSavesCanonicalEvidence() async throws {
        let (plan, approval, root) = try fixture(), client = PairedFixtureClient()
        let report = try await AutomationPairedFeatureCampaign.run(plan: plan, approval: approval, attemptID: UUID().uuidString, supportRoot: root, client: client)
        XCTAssertEqual(report.result.summary, .passed); XCTAssertTrue(report.resourcesReleased)
        let sent = await client.sent; XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(report.receipts.map(\.route), [.pairedFeature, .pairedFeature])
        XCTAssertEqual(report.receipts[1].observations.first?.value, .text("Actual response"))
        let cases = try AutomationCaseStore(root: root.appendingPathComponent("Cases")), frozen = try AutomationFrozenCase(plan: plan)
        let saved = try await cases.attempts(for: frozen)
        XCTAssertEqual(saved, [report])
        try AutomationRecordedEvidence.validate(report: report, plan: plan, expectedRunID: approval.runID)
        var processBound = plan.execution; processBound.lifecycle = .processContinuityRequired
        XCTAssertThrowsError(try processBound.pairedProgram?.validate(segment: processBound, target: plan.target), "Registration cannot prove remote process continuity")
    }
    func testExpectedAnswerNeverEntersSubjectProgramAndMissingOracleStaysUnassessed() async throws {
        let (plan, approval, root) = try fixture(expected: "Hidden expected answer"), client = PairedFixtureClient()
        let failed = try await AutomationPairedFeatureCampaign.run(plan: plan, approval: approval, attemptID: UUID().uuidString, supportRoot: root, client: client)
        XCTAssertEqual(failed.result.summary, .assertionFailed)
        let sent = await client.sent
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(sent), as: UTF8.self).contains("Hidden expected answer"))
        let (unassessed, nextApproval, nextRoot) = try fixture(expected: nil)
        let observed = try await AutomationPairedFeatureCampaign.run(plan: unassessed, approval: nextApproval, attemptID: UUID().uuidString, supportRoot: nextRoot, client: client)
        XCTAssertEqual(observed.result.summary, .executedUnassessed)
    }
    func testAmbiguousDisconnectRetainsLeaseAndPreventsDeviceOrPairedRedispatch() async throws {
        let (plan, approval, root) = try fixture(), client = PairedFixtureClient(disconnect: true)
        let report = try await AutomationPairedFeatureCampaign.run(plan: plan, approval: approval, attemptID: UUID().uuidString, supportRoot: root, client: client)
        XCTAssertFalse(report.resourcesReleased); XCTAssertFalse(report.result.assessed)
        let retained = try await AutomationPairedFeatureCampaign.hasRetainedOwnership(target: plan.target, supportRoot: root)
        XCTAssertTrue(retained)
        let recovered = try await AutomationPairedFeatureCampaign.hasAnyRetainedOwnership(supportRoot: root)
        XCTAssertTrue(recovered, "A new store must keep legacy paired execution blocked after restart")
        let leases = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
        do { _ = try await leases.acquire(runID: "other", target: .init(id: "other-device", kind: .physical), control: .system); XCTFail("Paired ambiguity released the device fence") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
        let next = try await AutomationPairedFeatureCampaign.run(plan: plan, approval: approval, attemptID: UUID().uuidString, supportRoot: root, client: client)
        XCTAssertFalse(next.result.subjectCompleted)
        let sent = await client.sent; XCTAssertEqual(sent.count, 1)
    }
    func testAbsentDesktopOwnerAndNoLocalChildrenCannotReconcileRemoteDispatch() async throws {
        let (plan, approval, root) = try fixture()
        let storeURL = root.appendingPathComponent("target-leases.json")
        let manager = try AutomationDeviceLeaseManager(storeURL: storeURL)
        let lease = try await manager.acquire(runID: approval.runID, target: plan.target, control: .system)
        let scope = AutomationScope(runID: approval.runID, attemptID: "remote-attempt", segmentID: plan.execution.id,
                                    leaseGeneration: lease.generation)
        try await manager.recordDispatch(.init(scope: scope, operationID: "remote-dispatch",
            payloadDigest: try AutomationFrozenCase.planDigest(plan)), lease: lease)
        let absent = AutomationProcessIdentity(pid: Int32.max, startIdentity: "absent-desktop-owner")
        XCTAssertEqual(absent.presence(), .absent)
        try AutomationLeaseStore(url: storeURL).transaction { state in
            state.campaigns[plan.target.leaseKey]!.owner = absent
        }
        let recovery = try AutomationDeviceLeaseManager(storeURL: storeURL)
        let records = try await recovery.recoveryRecords()
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(record.runners.isEmpty); XCTAssertNotNil(record.lastDispatch)
        do {
            try await recovery.reconcile(record, commandsDrained: true, ownedRunnerTerminated: true)
            XCTFail("Local absence must not acknowledge a remote feature")
        } catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        let retained = try await recovery.recoveryRecords()
        XCTAssertEqual(retained, records)
        do {
            _ = try await recovery.acquire(runID: "other", target: .init(id: "other-device", kind: .physical), control: .system)
            XCTFail("Unverified remote completion must retain the device fence")
        } catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
    }
    func testCurrentDesktopOwnerCannotResetRemoteDispatchWithoutCompletion() async throws {
        let (plan, approval, root) = try fixture()
        let manager = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
        let lease = try await manager.acquire(runID: approval.runID, target: plan.target, control: .system)
        let scope = AutomationScope(runID: approval.runID, attemptID: "remote-attempt", segmentID: plan.execution.id,
                                    leaseGeneration: lease.generation)
        try await manager.recordDispatch(.init(scope: scope, operationID: "remote-dispatch",
            payloadDigest: try AutomationFrozenCase.planDigest(plan)), lease: lease)
        let record = try await manager.currentRecord(lease)
        XCTAssertTrue(record.runners.isEmpty)
        do {
            try await manager.resetCurrentProcessCampaign(record)
            XCTFail("A local reset cannot acknowledge a remote feature")
        } catch { XCTAssertEqual(error as? AutomationContractError, .terminationUnverified) }
        let retained = try await manager.currentRecord(lease)
        XCTAssertEqual(retained, record)
    }
    func testChangedRegistrationNeverDispatchesAndWrongReplyCannotBecomeProof() async throws {
        let (plan, approval, root) = try fixture(), changed = PairedFixtureClient(changed: true)
        let denied = try await AutomationPairedFeatureCampaign.run(plan: plan, approval: approval, attemptID: UUID().uuidString, supportRoot: root, client: changed)
        XCTAssertFalse(denied.result.subjectDispatched)
        let sent = await changed.sent; XCTAssertTrue(sent.isEmpty)
        let (other, otherApproval, otherRoot) = try fixture()
        let wrong = try await AutomationPairedFeatureCampaign.run(plan: other, approval: otherApproval, attemptID: UUID().uuidString, supportRoot: otherRoot, client: PairedFixtureClient(wrongID: true))
        XCTAssertFalse(wrong.resourcesReleased); XCTAssertFalse(wrong.result.assessed)
    }
    func testPlannerRejectsBorrowedLocalBuildIdentityAndObserverDispatch() throws {
        let (plan, approval, _) = try fixture()
        var local = plan.app; local.productDigest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try AutomationPairedFeaturePlanner.compile(app: local, program: plan.execution.pairedProgram!, approval: approval, expectedResponse: nil))
        var changed = plan; changed.observations[0].pairedProgram?.mode = .execute
        var scoped = approval; scoped.approvedCaseDigest = try AutomationFrozenCase.planDigest(changed)
        XCTAssertThrowsError(try PlanValidator.validate(changed, approval: scoped, capabilities: .init(), purpose: .review))
    }
}
private actor PairedFixtureClient: AutomationPairedFeatureClient {
    var sent: [AutomationPairedFeatureProgram] = []
    let disconnect: Bool, changed: Bool, wrongID: Bool
    init(disconnect: Bool = false, changed: Bool = false, wrongID: Bool = false) { self.disconnect = disconnect; self.changed = changed; self.wrongID = wrongID }
    func validate(program: AutomationPairedFeatureProgram, app: AppIdentity) async throws {
        if changed { throw AutomationContractError.conflictingOperation }
    }
    func execute(program: AutomationPairedFeatureProgram, app: AppIdentity, requestID: UUID, runID: UUID, timeout: Duration) async throws -> AutomationPairedFeatureReply {
        sent.append(program)
        if disconnect { throw AutomationContractError.ambiguousDispatch }
        return .init(requestID: wrongID ? UUID() : requestID, response: "Actual response")
    }
}
#endif
