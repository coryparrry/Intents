#if os(macOS)
import Foundation
import XCTest
import Synchronization
@testable import IntentsAutomationCore
@testable import IntentsAutomationNativeUI

@MainActor final class OwnershipRecoveryStoreTests: XCTestCase {
    func testRecoveryDisplaysPersistedOwnershipWithoutClearingOrRedispatching() async throws {
        let (_, root, _) = try await InstalledUIStoreTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let owner = try AutomationDeviceLeaseManager(storeURL: support.appendingPathComponent("target-leases.json"))
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        try await owner.reserveCampaign(runID: "interrupted-run", target: target)
        let reopened = AppAutomationStore(supportDirectory: support)
        await reopened.refreshRecovery()
        XCTAssertEqual(reopened.recoveryItems.count, 1)
        XCTAssertTrue(try XCTUnwrap(reopened.recoveryItems.first).detail.contains("still running"))
        await reopened.refreshRecovery()
        XCTAssertEqual(reopened.recoveryItems.first?.record.runID, "interrupted-run")
        XCTAssertNil(reopened.report)
        let absent = try await owner.campaignAbsent(target: target)
        XCTAssertFalse(absent)
        try await owner.releaseCampaign(runID: "interrupted-run", target: target)
        await reopened.refreshRecovery()
        XCTAssertTrue(reopened.recoveryItems.isEmpty)
    }
    func testCancelledUnresolvedAttemptCanResetAndRunAgain() async throws {
        let gate = RecoveryStartupGate(), calls = Mutex(0)
        let (model, root, _) = try await InstalledUIStoreTests().fixture(executor: { _, plan, _, _, id, _ in
            let first = calls.withLock { value in value += 1; return value == 1 }
            if first { await gate.hold() }
            return .init(attemptID: id, result: AutomationAssessment.assess(plan: plan, attemptID: id,
                subjectDispatched: !first, subjectCompleted: !first, observations: [], termination: first ? .cancelled : nil),
                receipts: [], resourcesReleased: !first)
        })
        defer { try? FileManager.default.removeItem(at: root) }
        await model.ownershipRecoveryTask?.value
        model.run(); await gate.waitUntilEntered()
        model.cancel(); await gate.release(); await model.task?.value
        XCTAssertNotNil(model.retainedUnresolvedNormalReport)
        XCTAssertFalse(model.canRun)
        await model.clearUnresolvedAttempt()
        XCTAssertNil(model.retainedUnresolvedNormalReport)
        XCTAssertNil(model.report); XCTAssertNil(model.recoveryError)
        XCTAssertTrue(model.canRun)
        model.run(); await model.task?.value
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertEqual(model.report?.resourcesReleased, true)
        XCTAssertEqual(model.report?.result.subjectDispatched, true)
    }

    func testShutdownFailureKeepsUnresolvedReport() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/reset-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppAutomationStore(supportDirectory: root, recoverySimulatorShutdown: { _, _, _ in
            throw AutomationContractError.terminationUnverified
        })
        model.simulatorID = UUID().uuidString
        let target = TargetIdentity(id: model.simulatorID, kind: .simulator)
        let owner = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
        try await owner.reserveCampaign(runID: "cancelled", target: target)
        model.report = .init(attemptID: "cancelled", result: .init(summary: .cancelled,
            subjectDispatched: false, subjectCompleted: false, assessed: false, evidenceComplete: false,
            failedObservations: [], missingObservations: []), receipts: [], resourcesReleased: false)
        let unresolved = model.report
        model.retainUnresolvedRequest(runID: "cancelled", target: target)
        await model.clearUnresolvedAttempt()
        XCTAssertEqual(model.report, unresolved); XCTAssertNotNil(model.recoveryError)
        XCTAssertEqual(model.retainedUnresolvedRequestTargets["cancelled"], target)
        let absent = try await owner.campaignAbsent(target: target); XCTAssertFalse(absent)
    }

    func testStartupReconcilesAbsentAndReplacedOwners() async throws {
        for absent in [false, true] {
            let root = URL(fileURLWithPath: "/private/tmp/startup-recovery-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("target-leases.json")
            let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
            var dead = try AutomationProcessIdentity.current()
            if absent { dead.pid = 999_999_999 } else { dead.startIdentity = "replaced-start-identity" }
            try AutomationLeaseStore(url: url).transaction { state in
                state.campaigns[target.leaseKey] = .init(runID: "old", target: target, owner: dead, ownerToken: "old-owner")
                state.generations[target.leaseKey] = 1
            }
            let model = AppAutomationStore(supportDirectory: root)
            await model.ownershipRecoveryTask?.value
            XCTAssertTrue(model.recoveryItems.isEmpty); XCTAssertNil(model.recoveryError)
            let next = try AutomationDeviceLeaseManager(storeURL: url)
            let lease = try await next.acquire(runID: "new", target: target, control: .system)
            XCTAssertEqual(lease.generation, 2)
        }
    }

    func testResetWaitForStartupCannotInterruptANewOperation() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/reset-startup-race-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppAutomationStore(supportDirectory: root)
        await model.ownershipRecoveryTask?.value
        let gate = RecoveryStartupGate()
        model.ownershipRecoveryTask = Task { await gate.hold() }
        await gate.waitUntilEntered()
        let reset = Task { await model.clearUnresolvedAttempt() }
        await Task.yield()
        model.progress = "Running the approved action…"
        await gate.release(); await reset.value
        XCTAssertEqual(model.progress, "Running the approved action…")
        XCTAssertNil(model.message)
    }

    func testResetRefusesLiveRunnerBeforeShuttingDownSimulator() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/reset-active-runner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shutdowns = Mutex(0)
        let model = AppAutomationStore(supportDirectory: root, recoverySimulatorShutdown: { _, _, _ in
            shutdowns.withLock { $0 += 1 }
        })
        await model.ownershipRecoveryTask?.value
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let owner = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
        let lease = try await owner.acquire(runID: "active", target: target, control: .ui)
        let scope = AutomationScope(runID: "active", attemptID: "attempt", segmentID: "subject", leaseGeneration: lease.generation)
        try await owner.recordRunner(.init(scope: scope, process: .current(), role: .nativeCommand, executablePath: "/usr/bin/xcrun"), lease: lease)
        await model.clearUnresolvedAttempt()
        XCTAssertEqual(shutdowns.withLock { $0 }, 0)
        XCTAssertNotNil(model.recoveryError)
        let held = await owner.isCurrent(lease); XCTAssertTrue(held)
    }

    func testIdleStoreCannotResetAnotherSameProcessCampaignBetweenCommands() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/reset-foreign-same-process-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shutdowns = Mutex(0)
        let model = AppAutomationStore(supportDirectory: root, recoverySimulatorShutdown: { _, _, _ in shutdowns.withLock { $0 += 1 } })
        await model.ownershipRecoveryTask?.value
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let owner = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
        try await owner.reserveCampaign(runID: "another-live-request", target: target)
        await model.refreshRecovery()
        XCTAssertTrue(model.hasUnresolvedOwnership)
        await model.clearUnresolvedAttempt()
        XCTAssertEqual(shutdowns.withLock { $0 }, 0)
        XCTAssertNotNil(model.recoveryError)
        let absent = try await owner.campaignAbsent(target: target); XCTAssertFalse(absent)
        try await owner.releaseCampaign(runID: "another-live-request", target: target)
    }

    func testFinishedCurrentProcessRequestCanResetItsExactCampaign() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/reset-finished-same-process-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shutdowns = Mutex(0)
        let model = AppAutomationStore(supportDirectory: root, recoverySimulatorShutdown: { _, _, _ in shutdowns.withLock { $0 += 1 } })
        await model.ownershipRecoveryTask?.value
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let owner = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
        let lease = try await owner.acquire(runID: "finished-request", target: target, control: .system)
        model.retainUnresolvedRequest(runID: "finished-request", target: target)
        await model.clearUnresolvedAttempt()
        XCTAssertEqual(shutdowns.withLock { $0 }, 1)
        XCTAssertNil(model.recoveryError)
        let current = await owner.isCurrent(lease); XCTAssertFalse(current)
        XCTAssertTrue(model.retainedUnresolvedRequestTargets.isEmpty)
    }

    func testResetPreservesCompletedIndependentReportsWhenOnlyNormalAttemptIsUnresolved() async throws {
        let helper = InstalledUIStoreTests()
        let (model, root, _) = try await helper.fixture()
        try helper.selectPreparedSource(model: model, root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        await model.ownershipRecoveryTask?.value
        let request = try model.makeNativeRunRequest(runID: "later-unresolved-normal")
        let frozen = try AutomationFrozenCase(plan: request.plan)
        let result = AutomationAssessment.assess(plan: request.plan, attemptID: "completed", subjectDispatched: true,
            subjectCompleted: true, observations: [])
        let completed = AutomationAttemptReport(attemptID: "completed", result: result, receipts: [], resourcesReleased: true)
        let search = AutomationFailureSearchReport(baselineDigest: frozen.digest,
            attempts: [.init(stage: .baseline, caseDigest: frozen.digest, report: completed)])
        var reproduction = AutomationReproductionReport(frozen: frozen, runID: "completed-reproduction", originalFailure: completed)
        for index in 0..<5 {
            var attempt = completed; attempt.attemptID = "reproduction-" + String(index)
            reproduction.record(attempt)
        }
        let comparison = AutomationFixComparisonReport(contractDigest: frozen.contractDigest, baseline: frozen, candidate: frozen,
            requestedAttemptsPerBuild: 1, beforeRunID: "completed.before", afterRunID: "completed.after", before: [completed], after: [completed])
        model.entityQueryReport = completed; model.searchReport = search
        model.reproductionReport = reproduction; model.comparisonReport = comparison
        XCTAssertFalse(model.hasUnresolvedOwnership)
        model.report = .init(attemptID: "later-unresolved", result: .init(summary: .cancelled,
            subjectDispatched: false, subjectCompleted: false, assessed: false, evidenceComplete: false,
            failedObservations: [], missingObservations: []), receipts: [], resourcesReleased: false)
        model.retainUnresolvedRequest(runID: request.approval.runID, target: request.plan.target)
        await model.clearUnresolvedAttempt()
        XCTAssertNil(model.recoveryError); XCTAssertNil(model.report)
        XCTAssertEqual(model.entityQueryReport, completed); XCTAssertEqual(model.searchReport, search)
        XCTAssertEqual(model.reproductionReport, reproduction); XCTAssertEqual(model.comparisonReport, comparison)
        XCTAssertFalse(model.hasUnresolvedOwnership); XCTAssertTrue(model.canRun)
    }

    func testEveryActiveUnresolvedReportCanResetWithoutRemovingSavedEvidence() async throws {
        for kind in ["entity", "search", "reproduction", "comparison", "normal"] {
            let helper = InstalledUIStoreTests()
            let (model, root, _) = try await helper.fixture()
            try helper.selectPreparedSource(model: model, root: root)
            defer { try? FileManager.default.removeItem(at: root) }
            await model.ownershipRecoveryTask?.value
            let request = try model.makeNativeRunRequest(runID: "finished-" + kind)
            let frozen = try AutomationFrozenCase(plan: request.plan)
            var result = AutomationAssessment.assess(plan: request.plan, attemptID: "uncertain", subjectDispatched: false,
                subjectCompleted: false, observations: [], termination: .unresolved)
            result.subjectDispatchUncertain = true
            let report = AutomationAttemptReport(attemptID: "uncertain", result: result, receipts: [], resourcesReleased: true)
            let interruption = AutomationSearchInterruption(attemptID: "uncertain", caseDigest: frozen.digest,
                stage: .baseline, dispatchMayHaveOccurred: true, reason: "simulated uncertain attempt")
            switch kind {
            case "entity": model.entityQueryReport = report
            case "search": model.searchReport = .init(baselineDigest: frozen.digest, interruptions: [interruption])
            case "reproduction":
                var reproduction = AutomationReproductionReport(frozen: frozen, runID: request.approval.runID, originalFailure: report)
                reproduction.interruption = interruption; model.reproductionReport = reproduction
            case "comparison": model.comparisonReport = .init(contractDigest: "synthetic", baseline: frozen, candidate: frozen,
                requestedAttemptsPerBuild: 30, beforeRunID: request.approval.runID, afterRunID: "after", interruption: interruption)
            default: model.report = report
            }
            model.retainUnresolvedRequest(runID: request.approval.runID, target: request.plan.target)
            model.savedViewedReport = report; model.savedViewedCase = frozen
            XCTAssertTrue(model.hasUnresolvedOwnership); XCTAssertFalse(model.canRun)
            await model.clearUnresolvedAttempt()
            XCTAssertNil(model.recoveryError, kind)
            XCTAssertNil(model.report); XCTAssertNil(model.entityQueryReport); XCTAssertNil(model.searchReport)
            XCTAssertNil(model.reproductionReport); XCTAssertNil(model.comparisonReport)
            XCTAssertFalse(model.hasUnresolvedOwnership); XCTAssertTrue(model.canRun)
            XCTAssertEqual(model.savedViewedReport, report); XCTAssertEqual(model.savedViewedCase, frozen)
        }
    }

    func testStartupLeavesLegacyIntentLabOwnershipForItsJournalRecovery() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/legacy-intentlab-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = TargetIdentity(id: UUID().uuidString, kind: .physical)
        let url = root.appendingPathComponent("target-leases.json")
        try AutomationLeaseStore(url: url).transaction { state in
            state.campaigns[target.leaseKey] = .init(runID: "intent-lab-old-journal", target: target,
                owner: .init(pid: Int32.max, startIdentity: "old"), ownerToken: "old-owner")
            state.generations[target.leaseKey] = 1
        }
        let model = AppAutomationStore(supportDirectory: root)
        await model.ownershipRecoveryTask?.value
        XCTAssertTrue(model.recoveryItems.isEmpty)
        XCTAssertNotNil(try AutomationLeaseStore(url: url).read().campaigns[target.leaseKey])
    }

    func testPairedCampaignSurvivesStartupAndExplicitResetForAbsentAndRetainedOwners() async throws {
        for absentOwner in [true, false] {
            let root = URL(fileURLWithPath: "/private/tmp/paired-reset-fence-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("target-leases.json")
            let target = TargetIdentity(id: UUID().uuidString, kind: .pairedRunner)
            let owner = try AutomationDeviceLeaseManager(storeURL: url), runID = "paired-unresolved"
            if absentOwner {
                var departed = try AutomationProcessIdentity.current(); departed.pid = 999_999_999
                try AutomationLeaseStore(url: url).transaction { state in
                    state.campaigns[target.leaseKey] = .init(runID: runID, target: target, owner: departed, ownerToken: "departed-owner")
                    state.generations[target.leaseKey] = 1
                }
            } else {
                try await owner.reserveCampaign(runID: runID, target: target)
            }
            let model = AppAutomationStore(supportDirectory: root)
            await model.ownershipRecoveryTask?.value
            XCTAssertNotNil(try AutomationLeaseStore(url: url).read().campaigns[target.leaseKey])
            XCTAssertEqual(model.recoveryItems.map(\.record.runID), [runID])
            if !absentOwner {
                model.pairedExecutionUnresolved = true
                model.retainUnresolvedRequest(runID: runID, target: target)
            }
            await model.refreshRecovery()
            await model.clearUnresolvedAttempt()
            XCTAssertNotNil(model.recoveryError)
            let absent = try await owner.campaignAbsent(target: target)
            XCTAssertFalse(absent)
            XCTAssertEqual(model.recoveryItems.map(\.record.runID), [runID])
            if !absentOwner {
                XCTAssertTrue(model.pairedExecutionUnresolved)
                XCTAssertEqual(model.retainedUnresolvedRequestTargets[runID], target)
                XCTAssertFalse(model.canSelectApplicationFromCommand)
            }
        }
    }

}
private actor RecoveryStartupGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; entry?.resume(); entry = nil
        await withCheckedContinuation { completion = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entry = $0 } }
    }
    func release() { completion?.resume(); completion = nil }
}

#endif
