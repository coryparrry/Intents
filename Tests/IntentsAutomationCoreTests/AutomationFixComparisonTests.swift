import XCTest
@testable import IntentsAutomationCore

final class AutomationFixComparisonTests: XCTestCase, @unchecked Sendable {
    private func baseline() throws -> AutomationFrozenCase {
        try .init(plan: .init(id: "fix-contract", app: .init(logicalID: "fixture", bundleID: "example.Fixture", platform: "ios", productDigest: String(repeating: "a", count: 64)),
            target: .init(id: "fixture", kind: .simulator), environmentID: "unit",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "ActualIntent"),
            observations: [.init(id: "observer", kind: .ui, phase: .observe, operation: "Read")],
            requirements: [.init(observationID: "observer", expected: .bool(true), proof: .visibleState, justification: "Unit contract")]))
    }
    private func candidate(_ base: AutomationFrozenCase) throws -> AutomationFrozenCase {
        var app = base.plan.app; app.productDigest = String(repeating: "b", count: 64)
        return try AutomationFixContract.candidate(from: base, app: app)
    }
    func testUnreadablePhysicalInstallCannotClaimAnExactBuildFixComparison() throws {
        var plan = try baseline().plan
        plan.target = .init(id: "00008140-001049013EF3401C", kind: .physical)
        let base = try AutomationFrozenCase(plan: plan)
        var app = plan.app; app.productDigest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try AutomationFixContract.candidate(from: base, app: app))
        plan.app = app; plan.revision += 1
        XCTAssertThrowsError(try AutomationFixContract.validate(baseline: base, candidate: .init(plan: plan)))
    }
    func testOracleInputObserverAndHarnessChangesCannotMasqueradeAsCodeOnlyFix() throws {
        let base = try baseline(), changed = try candidate(base)
        try AutomationFixContract.validate(baseline: base, candidate: changed)
        var plan = changed.plan; plan.requirements[0].expected = .bool(false)
        XCTAssertThrowsError(try AutomationFixContract.validate(baseline: base, candidate: .init(plan: plan)))
        plan = changed.plan; plan.execution.inputs["request"] = .text("different business request")
        XCTAssertThrowsError(try AutomationFixContract.validate(baseline: base, candidate: .init(plan: plan)))
        plan = changed.plan; plan.observations[0].operation = "OtherRead"
        XCTAssertThrowsError(try AutomationFixContract.validate(baseline: base, candidate: .init(plan: plan)))
        plan = changed.plan; plan.provenance["controllerDigest"] = "new harness"
        XCTAssertThrowsError(try AutomationFixContract.validate(baseline: base, candidate: .init(plan: plan)))
    }
    func testFreshSeparatelyApprovedBuildPopulationsRetainObservedCounts() async throws {
        let base = try baseline(), changed = try candidate(base)
        let before = RunApproval(runID: "before", app: base.plan.app, target: base.plan.target, environmentID: "unit", effects: [.observe], maximumActions: 20, disposable: true, approvedCaseDigest: base.digest)
        let after = RunApproval(runID: "after", app: changed.plan.app, target: changed.plan.target, environmentID: "unit", effects: [.observe], maximumActions: 20, disposable: true, approvedCaseDigest: changed.digest)
        let cases = try AutomationCaseStore(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
        let result = try await AutomationFixComparison(cases: cases).run(baseline: base, candidate: changed, attemptsPerBuild: 3,
            beforeApproval: before, afterApproval: after, limits: .init(), beforeExecutor: FixFixtureExecutor(value: false), afterExecutor: FixFixtureExecutor(value: true))
        XCTAssertEqual(result.before.count, 3); XCTAssertEqual(result.after.count, 3)
        XCTAssertEqual(result.beforeCounters.failed, 3); XCTAssertEqual(result.afterCounters.failed, 0); XCTAssertEqual(result.afterCounters.assessed, 3)
        XCTAssertEqual(Set((result.before + result.after).map(\.attemptID)).count, 6)
        XCTAssertFalse(result.environmentQualificationComplete); XCTAssertNil(result.stopReason)
    }
    func testMismatchedApprovalCannotEnterEitherExecutor() async throws {
        let base = try baseline(), changed = try candidate(base)
        let before = RunApproval(runID: "before", app: base.plan.app, target: base.plan.target, environmentID: "unit", effects: [.observe], maximumActions: 20, disposable: true, approvedCaseDigest: base.digest)
        let after = RunApproval(runID: "after", app: changed.plan.app, target: changed.plan.target, environmentID: "unit", effects: [.observe], maximumActions: 20, disposable: true, approvedCaseDigest: changed.digest)
        for kind in 0..<3 {
            var bad = before
            if kind == 0 { bad.target.id = "foreign-target" }
            else if kind == 1 { bad.environmentID = "foreign-environment" }
            else { bad.effects = [] }
            let cases = try AutomationCaseStore(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
            do { _ = try await AutomationFixComparison(cases: cases).run(baseline: base, candidate: changed, attemptsPerBuild: 1,
                beforeApproval: bad, afterApproval: after, limits: .init(), beforeExecutor: NeverEnterFixExecutor(), afterExecutor: NeverEnterFixExecutor()); XCTFail("Mismatched authority accepted") } catch { }
        }
    }

    func testCancellationStopsBeforeCandidateAndCannotBeStrippedFromHistory() async throws {
        let base = try baseline(), changed = try candidate(base)
        let before = RunApproval(runID: "cancel.before", app: base.plan.app, target: base.plan.target, environmentID: "unit", effects: [.observe], maximumActions: 20, disposable: true, approvedCaseDigest: base.digest)
        let after = RunApproval(runID: "cancel.after", app: changed.plan.app, target: changed.plan.target, environmentID: "unit", effects: [.observe], maximumActions: 20, disposable: true, approvedCaseDigest: changed.digest)
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await AutomationFixComparison(cases: .init(root: root)).run(baseline: base, candidate: changed, attemptsPerBuild: 3,
            beforeApproval: before, afterApproval: after, limits: .init(), beforeExecutor: FixStoppedExecutor(), afterExecutor: NeverEnterFixExecutor())
        XCTAssertEqual(result.before.count, 1); XCTAssertTrue(result.after.isEmpty); XCTAssertFalse(result.complete)
        try result.validate()
        let archive = try AutomationFixComparisonArchive(caseStoreRoot: root)
        try await archive.save(result)
        let reopened = try await archive.load(runID: before.runID); XCTAssertEqual(reopened, result)
        var forged = result; forged.stopReason = nil
        XCTAssertThrowsError(try forged.validate())
        do { try await archive.save(result); XCTFail("Comparison overwritten") } catch { }
        let foreign = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: foreign) }
        do { try await AutomationFixComparisonArchive(caseStoreRoot: foreign).save(result); XCTFail("Unstored facts accepted") } catch { }
    }
    func testComparisonReportRejectsRecountingForeignRunAndDuplicateAttempts() async throws {
        let base = try baseline(), changed = try candidate(base)
        let before = RunApproval(runID: "count.before", app: base.plan.app, target: base.plan.target, environmentID: "unit", effects: [.observe], maximumActions: 20, disposable: true, approvedCaseDigest: base.digest)
        let after = RunApproval(runID: "count.after", app: changed.plan.app, target: changed.plan.target, environmentID: "unit", effects: [.observe], maximumActions: 20, disposable: true, approvedCaseDigest: changed.digest)
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await AutomationFixComparison(cases: .init(root: root)).run(baseline: base, candidate: changed, attemptsPerBuild: 2,
            beforeApproval: before, afterApproval: after, limits: .init(), beforeExecutor: FixFixtureExecutor(value: false), afterExecutor: FixFixtureExecutor(value: true))
        XCTAssertTrue(result.complete); try result.validate()
        for kind in 0..<4 {
            var changed = result
            if kind == 0 { changed.beforeCounters.failed = 0 }
            else if kind == 1 { changed.beforeRunID = "foreign" }
            else if kind == 2 { changed.after[1].attemptID = changed.before[0].attemptID }
            else { changed.environmentQualificationComplete = true }
            XCTAssertThrowsError(try changed.validate())
        }
    }

}
private struct FixFixtureExecutor: AutomationCampaignAttemptExecutor {
    var value: Bool
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        let plan = frozen.plan
        try await budget.reserveOperations(id: attemptID + ".subject", phase: .subject, count: 1)
        let observation = AutomationObservation(id: "observer", app: plan.app, target: plan.target, environmentID: plan.environmentID, attemptID: attemptID, stepID: "observer", route: .ui, proof: .visibleState, value: .bool(value))
        let receipts = [AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: attemptID, segmentID: "subject", leaseGeneration: 1), app: plan.app, target: plan.target, segmentID: "subject", route: .systemIntent, dispatched: true, completed: true),
            AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: attemptID, segmentID: "observer", leaseGeneration: 2), app: plan.app, target: plan.target, segmentID: "observer", route: .ui, dispatched: true, completed: true, observations: [observation])]
        return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: true, subjectCompleted: true, observations: [observation]), receipts: receipts, resourcesReleased: true)
    }
}

private struct NeverEnterFixExecutor: AutomationCampaignAttemptExecutor {
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        XCTFail("Executor entered without matching authority"); throw AutomationContractError.invalidIdentity
    }
}

private struct FixStoppedExecutor: AutomationCampaignAttemptExecutor {
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        .init(attemptID: attemptID, result: .init(summary: .cancelled, subjectDispatched: false, subjectCompleted: false, assessed: false, evidenceComplete: false, failedObservations: [], missingObservations: []), receipts: [], resourcesReleased: true)
    }
}
