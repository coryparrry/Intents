import XCTest
@testable import IntentsAutomationCore

final class AutomationCoordinatorTests: XCTestCase, @unchecked Sendable {
    private func fixture(cleanup: [AutomationSegment] = []) -> (AutomationCase, RunApproval) {
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "device", kind: .simulator)
        let plan = AutomationCase(id: "case", app: app, target: target, environmentID: "disposable",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Complete"),
            setup: [.init(id: "setup", kind: .ui, phase: .setup, operation: "Create")],
            observations: [.init(id: "readback", kind: .systemQuery, phase: .observe, operation: "Find")],
            requirements: [.init(observationID: "readback", expected: .bool(true), proof: .persistedState, justification: "Confirmed saved state")],
            cleanup: cleanup)
        return (plan, RunApproval(runID: "run", app: app, target: target, environmentID: "disposable", effects: [.observe], maximumActions: 10, disposable: true, approvedCaseDigest: try! AutomationFrozenCase.planDigest(plan)))
    }
    private func coordinator(leases: AutomationDeviceLeaseManager = .init()) throws -> AutomationCoordinator {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        return AutomationCoordinator(leases: leases, journal: try AutomationJournal(url: root.appendingPathComponent("journal.json")))
    }
    private let cleanupSegments: [AutomationSegment] = [
        .init(id: "cleanup", kind: .ui, phase: .cleanup, operation: "Delete"),
        .init(id: "cleanup-verify", kind: .systemIntent, phase: .cleanup, operation: "Reset"),
    ]
    private let completedHistory = ["acquire:setup:ui", "execute:setup", "release:setup", "acquire:subject:system", "execute:subject", "release:subject",
                                    "acquire:readback:system", "execute:readback", "release:readback"]
    private func campaignAvailable(_ leases: AutomationDeviceLeaseManager, target: TargetIdentity) async -> Bool {
        do { _ = try await leases.acquire(runID: "next-run", target: target, control: .system); return true } catch { return false }
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
    func testCleanupRunsAfterObservationsAndReleasesCampaign() async throws {
        let (plan, approval) = fixture(cleanup: cleanupSegments), driver = ContractDriver(), leases = AutomationDeviceLeaseManager()
        let report = try await coordinator(leases: leases).run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
        XCTAssertEqual(report.result.summary, .passed); XCTAssertTrue(report.resourcesReleased); XCTAssertTrue(report.executionSucceeded)
        XCTAssertEqual(report.receipts.map(\.segmentID), ["setup", "subject", "readback", "cleanup", "cleanup-verify"])
        let history = await driver.history
        XCTAssertEqual(history, completedHistory + ["acquire:cleanup:ui", "execute:cleanup", "release:cleanup",
                                                    "acquire:cleanup-verify:system", "execute:cleanup-verify", "release:cleanup-verify"])
        let available = await campaignAvailable(leases, target: plan.target); XCTAssertTrue(available)
    }
    func testIncompleteCleanupIsUnresolvedAndStopsLaterCleanup() async throws {
        let (plan, approval) = fixture(cleanup: cleanupSegments), driver = ContractDriver(incompleteSegment: "cleanup")
        let report = try await coordinator().run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
        XCTAssertEqual(report.result.summary, .unresolved); XCTAssertFalse(report.executionSucceeded)
        XCTAssertTrue(report.result.subjectCompleted); XCTAssertFalse(report.result.evidenceComplete); XCTAssertFalse(report.result.assessed)
        XCTAssertTrue(report.resourcesReleased)
        XCTAssertEqual(report.receipts.last?.segmentID, "cleanup"); XCTAssertEqual(report.receipts.last?.completed, false)
        let history = await driver.history
        XCTAssertEqual(history, completedHistory + ["acquire:cleanup:ui", "execute:cleanup", "release:cleanup"])
    }
    func testUnprovedCleanupReleaseKeepsCampaignBlocked() async throws {
        let (plan, approval) = fixture(cleanup: cleanupSegments), driver = ContractDriver(unreleasedSegment: "cleanup")
        let leases = AutomationDeviceLeaseManager(), runner = try coordinator(leases: leases)
        let report = try await runner.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
        XCTAssertEqual(report.result.summary, .unresolved); XCTAssertFalse(report.resourcesReleased); XCTAssertFalse(report.executionSucceeded)
        let history = await driver.history
        XCTAssertEqual(history, completedHistory + ["acquire:cleanup:ui", "execute:cleanup", "release:cleanup"])
        let available = await campaignAvailable(leases, target: plan.target); XCTAssertFalse(available)
        let second = try await runner.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "different", driver: driver)
        XCTAssertNotEqual(second.result.summary, .passed); XCTAssertFalse(second.result.subjectDispatched)
        let historyCount = await driver.history.count
        XCTAssertEqual(historyCount, history.count)
    }
    func testCleanupDriverFailureIsUnresolvedAndKeepsItsReleaseProof() async throws {
        for unreleased in [false, true] {
            let (plan, approval) = fixture(cleanup: cleanupSegments), leases = AutomationDeviceLeaseManager()
            let driver = ContractDriver(unreleasedSegment: unreleased ? "cleanup" : nil, failingSegment: "cleanup")
            let report = try await coordinator(leases: leases).run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
            XCTAssertEqual(report.result.summary, .unresolved); XCTAssertFalse(report.executionSucceeded)
            XCTAssertTrue(report.result.subjectCompleted); XCTAssertFalse(report.result.subjectDispatchUncertain); XCTAssertNil(report.result.policyDenial)
            XCTAssertEqual(report.resourcesReleased, !unreleased)
            XCTAssertEqual(report.receipts.map(\.segmentID), ["setup", "subject", "readback"])
            let history = await driver.history
            XCTAssertEqual(history, completedHistory + ["acquire:cleanup:ui", "execute:cleanup", "release:cleanup"])
            let available = await campaignAvailable(leases, target: plan.target); XCTAssertEqual(available, !unreleased)
        }
    }
    func testCancellationBeforeCleanupWithholdsReleaseAndCampaign() async throws {
        let (plan, approval) = fixture(cleanup: cleanupSegments), leases = AutomationDeviceLeaseManager()
        let runner = try coordinator(leases: leases), driver = ContractDriver(slowReleaseSegment: "readback", releaseDelay: .milliseconds(500))
        let task = Task { try await runner.run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver) }
        let startedDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await driver.history.contains("release:readback")) && ContinuousClock.now < startedDeadline { await Task.yield() }
        guard await driver.history.contains("release:readback") else {
            task.cancel(); _ = try? await task.value; XCTFail("Observation release never started within the test deadline"); return
        }
        task.cancel()
        let report = try await task.value
        XCTAssertEqual(report.result.summary, .cancelled); XCTAssertFalse(report.resourcesReleased)
        XCTAssertTrue(report.result.subjectCompleted); XCTAssertFalse(report.result.evidenceComplete)
        let history = await driver.history
        XCTAssertEqual(history, completedHistory)
        let available = await campaignAvailable(leases, target: plan.target); XCTAssertFalse(available)
    }
    func testDeadlineReachedBeforeCleanupTimesOutWithoutStartingIt() async throws {
        var (plan, approval) = fixture(cleanup: cleanupSegments); plan.budget.wallClockSeconds = 1
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let driver = ContractDriver(slowReleaseSegment: "readback", releaseDelay: .milliseconds(1500))
        let report = try await coordinator().run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
        XCTAssertEqual(report.result.summary, .timedOut); XCTAssertTrue(report.result.subjectCompleted)
        XCTAssertFalse(report.result.evidenceComplete); XCTAssertTrue(report.resourcesReleased)
        let history = await driver.history
        XCTAssertEqual(history, completedHistory)
    }
    func testFailedOrTimedOutSubjectNeverStartsCleanup() async throws {
        let (plan, approval) = fixture(cleanup: cleanupSegments), failing = ContractDriver(failingSegment: "subject")
        let failed = try await coordinator().run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: failing)
        XCTAssertEqual(failed.result.summary, .unresolved); XCTAssertTrue(failed.resourcesReleased)
        let failedHistory = await failing.history
        XCTAssertEqual(failedHistory, Array(completedHistory.prefix(6)))
        var (timed, timedApproval) = fixture(cleanup: cleanupSegments); timed.setup = []; timed.budget.wallClockSeconds = 1
        timedApproval.approvedCaseDigest = try AutomationFrozenCase.planDigest(timed)
        let slow = ContractDriver(delay: .seconds(30))
        let timedOut = try await coordinator().run(plan: timed, approval: timedApproval, capabilities: .init(), attemptID: "attempt", driver: slow)
        XCTAssertEqual(timedOut.result.summary, .timedOut)
        let slowHistory = await slow.history
        XCTAssertEqual(slowHistory, ["acquire:subject:system", "execute:subject", "release:subject"])
    }
    func testForeignSubjectReceiptIsAmbiguousDispatchNotEvidence() async throws {
        for forgery in ReceiptForgery.allCases {
            let (plan, approval) = fixture(cleanup: cleanupSegments), driver = ContractDriver(forgery: (segmentID: "subject", kind: forgery))
            let report = try await coordinator().run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
            XCTAssertEqual(report.result.summary, .unresolved, "\(forgery)"); XCTAssertTrue(report.result.subjectDispatchUncertain, "\(forgery)")
            XCTAssertFalse(report.result.subjectDispatched, "\(forgery)"); XCTAssertFalse(report.result.subjectCompleted, "\(forgery)")
            XCTAssertTrue(report.resourcesReleased, "\(forgery)"); XCTAssertFalse(report.executionSucceeded, "\(forgery)")
            XCTAssertEqual(report.receipts.map(\.segmentID), ["setup"], "\(forgery)")
            let history = await driver.history
            XCTAssertEqual(history, Array(completedHistory.prefix(6)), "\(forgery)")
        }
    }
    func testForeignCleanupReceiptIsUnresolvedAndNotRecorded() async throws {
        for forgery in ReceiptForgery.allCases {
            let (plan, approval) = fixture(cleanup: cleanupSegments), driver = ContractDriver(forgery: (segmentID: "cleanup", kind: forgery))
            let report = try await coordinator().run(plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", driver: driver)
            XCTAssertEqual(report.result.summary, .unresolved, "\(forgery)"); XCTAssertFalse(report.result.evidenceComplete, "\(forgery)")
            XCTAssertFalse(report.result.subjectDispatchUncertain, "\(forgery)"); XCTAssertTrue(report.resourcesReleased, "\(forgery)")
            XCTAssertEqual(report.receipts.map(\.segmentID), ["setup", "subject", "readback"], "\(forgery)")
            let history = await driver.history
            XCTAssertEqual(history, completedHistory + ["acquire:cleanup:ui", "execute:cleanup", "release:cleanup"], "\(forgery)")
        }
    }
}

private enum ReceiptForgery: CaseIterable, Sendable {
    case scope, leaseGeneration, app, target, segmentID, route, environment, completedWithoutDispatch
    func apply(to receipt: inout AutomationSegmentReceipt) {
        switch self {
        case .scope: receipt.scope.attemptId = "replayed-attempt"
        case .leaseGeneration: receipt.scope.leaseGeneration += 1
        case .app: receipt.app.bundleID = "example.Other"
        case .target: receipt.target = TargetIdentity(id: "other-device", kind: .simulator)
        case .segmentID: receipt.segmentID += "-other"
        case .route: receipt.route = receipt.route == .ui ? .systemQuery : .ui
        case .environment: receipt.environmentID = "production"
        case .completedWithoutDispatch: receipt.dispatched = false
        }
    }
}

private actor ContractDriver: AutomationRouteDriver {
    var history: [String] = []
    let omitObservation: Bool, unreleasedSegment: String?, throwOnExecute: Bool
    let delay: Duration?
    let sabotageJournal: URL?
    let uncleanedPayloadSegment: String?
    let remoteFailure: AutomationRPCError?
    let incompleteSegment: String?, failingSegment: String?
    let slowReleaseSegment: String?, releaseDelay: Duration
    let forgery: (segmentID: String, kind: ReceiptForgery)?
    init(omitObservation: Bool = false, unreleasedSegment: String? = nil, throwOnExecute: Bool = false, delay: Duration? = nil, sabotageJournal: URL? = nil, uncleanedPayloadSegment: String? = nil, remoteFailure: AutomationRPCError? = nil,
         incompleteSegment: String? = nil, failingSegment: String? = nil, slowReleaseSegment: String? = nil, releaseDelay: Duration = .zero, forgery: (segmentID: String, kind: ReceiptForgery)? = nil) {
        self.omitObservation = omitObservation; self.unreleasedSegment = unreleasedSegment; self.throwOnExecute = throwOnExecute
        self.delay = delay; self.sabotageJournal = sabotageJournal
        self.uncleanedPayloadSegment = uncleanedPayloadSegment
        self.remoteFailure = remoteFailure
        self.incompleteSegment = incompleteSegment; self.failingSegment = failingSegment
        self.slowReleaseSegment = slowReleaseSegment; self.releaseDelay = releaseDelay; self.forgery = forgery
    }
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) {
        history.append("acquire:\(segment.id):\(lease.control.rawValue)")
    }
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        history.append("execute:\(segment.id)")
        if let remoteFailure { throw remoteFailure }
        if throwOnExecute || segment.id == failingSegment { throw AutomationRPCError.dispatchedOutcomeUnknown }
        if let delay { try await Task.sleep(for: delay) }
        let observations: [AutomationObservation] = segment.phase == .observe && !omitObservation ? [AutomationObservation(id: segment.id, app: plan.app,
            target: plan.target, environmentID: plan.environmentID, attemptID: scope.attemptId, stepID: segment.id,
            route: segment.kind, proof: .persistedState, value: .bool(true))] : []
        var receipt = AutomationSegmentReceipt(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind,
                                               dispatched: true, completed: segment.id != incompleteSegment, observations: observations)
        if let forgery, forgery.segmentID == segment.id { forgery.kind.apply(to: &receipt) }
        return receipt
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
        history.append("release:\(scope.segmentId)")
        if scope.segmentId == slowReleaseSegment { try? await Task.sleep(for: releaseDelay) }
        if let sabotageJournal {
            try? FileManager.default.removeItem(at: sabotageJournal)
            try? FileManager.default.createDirectory(at: sabotageJournal, withIntermediateDirectories: true)
        }
        return .init(commandsDrained: true, runnerTerminated: scope.segmentId != unreleasedSegment, privatePayloadCleaned: scope.segmentId != uncleanedPayloadSegment)
    }
}
