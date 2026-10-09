import XCTest
@testable import IntentsAutomationCore

final class AutomationCoordinatorTests: XCTestCase, @unchecked Sendable {
    func testRetainedCampaignBlocksCompetitorUntilOwnerFinishesCleanup() async throws {
        for retained in [false, true] {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("leases.json")
            let owner = try AutomationDeviceLeaseManager(storeURL: file), competitor = try AutomationDeviceLeaseManager(storeURL: file)
            let journal = try AutomationJournal(url: root.appendingPathComponent("journal.json"))
            let coordinator = try AutomationCoordinator(leases: owner, journal: journal, cleanupTimeout: .seconds(10),
                releaseCampaignOnCompletion: !retained)
            let (plan, approval) = fixture()
            let report = try await coordinator.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: ContractDriver())
            XCTAssertTrue(report.resourcesReleased)
            if retained {
                do { try await competitor.reserveCampaign(runID: "competitor", target: plan.target); XCTFail("Cleanup ownership was handed off early") }
                catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
                let cleanup = try await owner.acquire(runID: approval.runID, target: plan.target, control: .system)
                try await owner.release(cleanup, commandsDrained: true, ownedRunnerTerminated: true)
                try await owner.releaseCampaign(runID: approval.runID, target: plan.target)
            }
            try await competitor.reserveCampaign(runID: "competitor", target: plan.target)
            try await competitor.releaseCampaign(runID: "competitor", target: plan.target)
        }
    }

    func testRetainedCampaignRemainsBlockedWhenControllerCleanupIsUnproved() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("leases.json")
        let owner = try AutomationDeviceLeaseManager(storeURL: file), competitor = try AutomationDeviceLeaseManager(storeURL: file)
        let coordinator = try AutomationCoordinator(leases: owner, journal: AutomationJournal(url: root.appendingPathComponent("journal.json")),
            cleanupTimeout: .seconds(10), releaseCampaignOnCompletion: false)
        let (plan, approval) = fixture()
        let report = try await coordinator.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt",
            driver: ContractDriver(unreleasedSegment: "setup"))
        XCTAssertFalse(report.resourcesReleased)
        do { try await competitor.reserveCampaign(runID: "competitor", target: plan.target); XCTFail("Unproved cleanup released ownership") }
        catch { XCTAssertEqual(error as? AutomationContractError, .targetBusy) }
    }
    private func fixture() -> (AutomationCase, RunApproval) {
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "device", kind: .simulator)
        let plan = AutomationCase(id: "case", app: app, target: target, environmentID: "disposable",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Complete"),
            setup: [.init(id: "setup", kind: .ui, phase: .setup, operation: "Create")],
            observations: [.init(id: "readback", kind: .systemQuery, phase: .observe, operation: "Find")],
            requirements: [.init(observationID: "readback", expected: .bool(true), proof: .persistedState, justification: "Confirmed saved state")])
        return (plan, RunApproval(runID: "run", app: app, target: target, environmentID: "disposable", effects: [.observe], maximumActions: 10, disposable: true, approvedCaseDigest: try! AutomationFrozenCase.planDigest(plan)))
    }
    private func coordinator() throws -> AutomationCoordinator {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        return AutomationCoordinator(leases: .init(), journal: try AutomationJournal(url: root.appendingPathComponent("journal.json")))
    }
    func testUntypedNullIsRejectedBeforeAnyDriverAcquisition() async throws {
        var (plan, approval) = fixture()
        plan.execution.lifecycle = .persistedStateAcrossSegments
        plan.execution.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: "Action", parameters: ["flag": .null], resultCodec: "noValue")])
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let driver = ContractDriver()
        do {
            _ = try await coordinator().run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
            XCTFail("Untyped null must not execute")
        } catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Nullable input conversion lacks its frozen parameter family")) }
        let history = await driver.history
        XCTAssertTrue(history.isEmpty)
    }
    func testControllersReleaseInOrderAndOnlyIndependentEvidencePasses() async throws {
        let (plan, approval) = fixture(), driver = ContractDriver()
        let report = try await coordinator().run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
        XCTAssertEqual(report.result.summary, .passed); XCTAssertTrue(report.resourcesReleased)
        let history = await driver.history
        XCTAssertEqual(history, ["acquire:setup:ui", "execute:setup", "release:setup", "acquire:subject:system", "execute:subject", "release:subject", "acquire:readback:system", "execute:readback", "release:readback"])
    }
    func testMissingIndependentEvidenceNeverBecomesNavigationPass() async throws {
        let (plan, approval) = fixture(), driver = ContractDriver(omitObservation: true)
        let report = try await coordinator().run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
        XCTAssertEqual(report.result.summary, .needsReview); XCTAssertTrue(report.result.subjectCompleted)
    }
    func testUnprovedReleaseStopsHandoffAndKeepsCampaignBlocked() async throws {
        let (plan, approval) = fixture(), driver = ContractDriver(unreleasedSegment: "setup")
        let runner = try coordinator()
        let report = try await runner.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
        XCTAssertFalse(report.resourcesReleased); XCTAssertFalse(report.result.subjectDispatched)
        let history = await driver.history
        XCTAssertEqual(history, ["acquire:setup:ui", "execute:setup", "release:setup"])
        let second = try await runner.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "different", driver: driver)
        XCTAssertNotEqual(second.result.summary, .passed)
        let historyCount = await driver.history.count
        XCTAssertEqual(historyCount, 3)
    }
    func testPrivatePayloadCleanupFailureStopsHandoffDespiteProvedProcessDrain() async throws {
        let (plan, approval) = fixture(), driver = ContractDriver(uncleanedPayloadSegment: "setup")
        let runner = try coordinator()
        let report = try await runner.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
        XCTAssertFalse(report.resourcesReleased); XCTAssertFalse(report.result.subjectDispatched)
        let history = await driver.history
        XCTAssertEqual(history, ["acquire:setup:ui", "execute:setup", "release:setup"])
        _ = try await runner.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "different", driver: driver)
        let count = await driver.history.count; XCTAssertEqual(count, 3)
    }
    func testCompletedOperationCannotActivateOrReplayOnReopenedAttempt() async throws {
        var (plan, approval) = fixture(); plan.setup = []; plan.observations = []; plan.requirements = []
        let runner = try coordinator(), driver = ContractDriver()
        let first = try await runner.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
        XCTAssertEqual(first.result.summary, .executedUnassessed)
        let prior = await driver.history
        let second = try await runner.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
        XCTAssertEqual(second.result.summary, .unresolved); XCTAssertTrue(second.result.subjectDispatchUncertain)
        let added = await driver.history.dropFirst(prior.count)
        XCTAssertEqual(Array(added), [])
    }
    func testAmbiguousDispatchIsNotCountedAsKnownExecutionOrNotRun() async throws {
        var (plan, approval) = fixture(); plan.setup = []
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let report = try await coordinator().run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: ContractDriver(throwOnExecute: true))
        XCTAssertEqual(report.result.summary, .unresolved); XCTAssertTrue(report.result.subjectDispatchUncertain)
        XCTAssertFalse(report.result.subjectDispatched)
        var counts = ScopeCounters(); counts.record(report.result)
        XCTAssertEqual(counts.dispatched, 0); XCTAssertEqual(counts.notRun, 0); XCTAssertEqual(counts.unresolved, 1)
    }
    func testActiveSubjectDeadlineIsEnforcedWithoutCallingItCompleted() async throws {
        var (plan, approval) = fixture(); plan.setup = []; plan.budget.wallClockSeconds = 1
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let start = ContinuousClock.now
        let report = try await coordinator().run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: ContractDriver(delay: .seconds(30)))
        XCTAssertEqual(report.result.summary, .timedOut); XCTAssertFalse(report.result.subjectCompleted)
        XCTAssertTrue(report.result.subjectDispatchUncertain)
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }
    func testAlreadyExpiredDeadlineCannotStartDriverWork() async throws {
        let work = AutomationBoundedTask<Bool>()
        do {
            _ = try await work.run(until: .now.advanced(by: .seconds(-1))) { XCTFail("Expired work must not start"); return true }
            XCTFail("Expected deadline rejection")
        } catch { XCTAssertEqual(error as? AutomationRPCError, .timedOut) }
        let started = await work.started; XCTAssertFalse(started)
    }
    func testJournalCompletionFailurePreservesReceiptAndDoesNotReleaseTwice() async throws {
        var (plan, approval) = fixture(); plan.setup = []; plan.observations = []; plan.requirements = []
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("journal.json")
        let runner = AutomationCoordinator(leases: .init(), journal: try AutomationJournal(url: journalURL))
        let driver = ContractDriver(sabotageJournal: journalURL)
        let report = try await runner.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
        XCTAssertEqual(report.result.summary, .unresolved)
        XCTAssertTrue(report.result.subjectDispatched); XCTAssertTrue(report.result.subjectCompleted)
        XCTAssertFalse(report.result.subjectDispatchUncertain); XCTAssertTrue(report.resourcesReleased)
        XCTAssertEqual(report.receipts.count, 1)
        let releases = await driver.history.filter { $0.hasPrefix("release:") }
        XCTAssertEqual(releases, ["release:subject"])
    }
    func testPolicyDenialSurvivesWorkerFailureAndSavedRoundTripWithoutStrengtheningEvidence() async throws {
        let (plan, approval) = fixture()
        for reason in AutomationPolicyDenialReason.allCases {
            let driver = ContractDriver(remoteFailure: .remote(code: -32000, message: "Action denied: " + reason.rawValue))
            let report = try await coordinator().run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
            XCTAssertEqual(report.result.policyDenial, reason)
            XCTAssertEqual(report.result.summary, .invalidFixture)
            XCTAssertFalse(report.result.subjectDispatched); XCTAssertFalse(report.result.subjectCompleted)
            XCTAssertFalse(report.result.assessed); XCTAssertTrue(report.resourcesReleased)
            XCTAssertEqual(try JSONDecoder().decode(AutomationAttemptReport.self, from: JSONEncoder().encode(report)), report)
            let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try AutomationCaseStore(root: root)
            let frozen = try await store.freeze(plan)
            try await store.saveAttempt(report, for: frozen)
            let saved = try await store.loadAttempt(id: report.attemptID, frozen: frozen)
            XCTAssertEqual(saved, report)
        }
    }
    func testRecordedSuccessCannotCarryAnUnexecutedPolicyDenial() async throws {
        let (plan, approval) = fixture()
        var report = try await coordinator().run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: ContractDriver())
        XCTAssertEqual(report.result.summary, .passed)
        report.result.policyDenial = .controllerNode
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: report, plan: plan))
    }
    func testUnrecognizedRemoteTextCannotEnterSavedPolicyDiagnostic() async throws {
        let (plan, approval) = fixture()
        for error in [AutomationRPCError.remote(code: -32000, message: "Action denied: private-canary"),
                      .remote(code: -32001, message: "Action denied: scopeLease"),
                      .remote(code: -32000, message: "Action denied: scopeLease private-canary")] {
            let report = try await coordinator().run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: ContractDriver(remoteFailure: error))
            XCTAssertNil(report.result.policyDenial)
            let bytes = try JSONEncoder().encode(report)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-canary"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertNil((object["result"] as? [String: Any])?["policyDenial"])
            XCTAssertEqual(try JSONDecoder().decode(AutomationAttemptReport.self, from: bytes), report)
        }
    }
    func testCancellationRetainsItsClassificationAndUnknownDispatch() async throws {
        var (plan, approval) = fixture(); plan.setup = []
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let runner = try coordinator(), driver = ContractDriver(delay: .seconds(30))
        let task = Task { try await runner.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver) }
        let startedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await driver.history.contains("execute:subject")) && ContinuousClock.now < startedDeadline { await Task.yield() }
        guard await driver.history.contains("execute:subject") else {
            task.cancel(); _ = try? await task.value; XCTFail("Subject never started within the test deadline"); return
        }
        task.cancel()
        let report = try await task.value
        XCTAssertEqual(report.result.summary, .cancelled); XCTAssertTrue(report.result.subjectDispatchUncertain)
        XCTAssertFalse(report.result.subjectCompleted)
    }
}

private actor ContractDriver: AutomationRouteDriver {
    var history: [String] = []
    let omitObservation: Bool, unreleasedSegment: String?, throwOnExecute: Bool
    let delay: Duration?
    let sabotageJournal: URL?
    let uncleanedPayloadSegment: String?
    let remoteFailure: AutomationRPCError?
    init(omitObservation: Bool = false, unreleasedSegment: String? = nil, throwOnExecute: Bool = false, delay: Duration? = nil, sabotageJournal: URL? = nil, uncleanedPayloadSegment: String? = nil, remoteFailure: AutomationRPCError? = nil) {
        self.omitObservation = omitObservation; self.unreleasedSegment = unreleasedSegment; self.throwOnExecute = throwOnExecute
        self.delay = delay; self.sabotageJournal = sabotageJournal
        self.uncleanedPayloadSegment = uncleanedPayloadSegment
        self.remoteFailure = remoteFailure
    }
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) {
        history.append("acquire:\(segment.id):\(lease.control.rawValue)")
    }
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        history.append("execute:\(segment.id)")
        if let remoteFailure { throw remoteFailure }
        if throwOnExecute { throw AutomationRPCError.dispatchedOutcomeUnknown }
        if let delay { try await Task.sleep(for: delay) }
        let observations: [AutomationObservation] = segment.phase == .observe && !omitObservation ? [AutomationObservation(id: segment.id, app: plan.app,
            target: plan.target, environmentID: plan.environmentID, attemptID: scope.attemptId, stepID: segment.id,
            route: segment.kind, proof: .persistedState, value: .bool(true))] : []
        return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind, dispatched: true, completed: true, observations: observations)
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) -> AutomationReleaseProof {
        history.append("release:\(scope.segmentId)")
        if let sabotageJournal {
            try? FileManager.default.removeItem(at: sabotageJournal)
            try? FileManager.default.createDirectory(at: sabotageJournal, withIntermediateDirectories: true)
        }
        return .init(commandsDrained: true, runnerTerminated: scope.segmentId != unreleasedSegment, privatePayloadCleaned: scope.segmentId != uncleanedPayloadSegment)
    }
}
