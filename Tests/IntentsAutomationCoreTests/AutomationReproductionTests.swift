import XCTest
@testable import IntentsAutomationCore

final class AutomationReproductionTests: XCTestCase, @unchecked Sendable {
    private func fixture(legacy: Bool = false, caseRoot: URL? = nil) async throws -> (AutomationFrozenCase, RunApproval, AutomationCaseStore) {
        let root = caseRoot ?? URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = AppIdentity(logicalID: "selected", bundleID: "example.UI", platform: "ios")
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        var approval = RunApproval(runID: "reproduction", app: app, target: target, environmentID: "owned", effects: [.observe, .navigate], maximumActions: 30, disposable: true)
        var plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Open controls", endpoint: "Controls", expectedVisibleText: "50%", observationLabel: "Volume", observationProperty: "value", approval: approval, localeIdentifier: "en_GB")
        if legacy { plan.requirements[0].checkID = nil }
        var muted = AutomationSegment(id: "muted", kind: .ui, phase: .observe, operation: "Read mute state", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        muted.uiProgram = .init(operations: [.init(id: "read-mute", kind: .observeProperty, locator: .init(.label, "Mute"), property: "checked")])
        plan.observations.append(muted)
        plan.requirements.append(.init(observationID: "muted", expected: .bool(false), proof: .visibleState, justification: "Independent mute check", checkID: "business.muted"))
        let frozen = try AutomationFrozenCase(plan: plan), cases = try AutomationCaseStore(root: root)
        approval.approvedCaseDigest = frozen.digest
        _ = try await cases.freeze(plan)
        let original = ReproductionFactExecutor.report(frozen: frozen, runID: "original-run", attemptID: "original", outcome: .matching)
        try await cases.saveAttempt(original, for: frozen)
        return (frozen, approval, cases)
    }
    func testFiveFreshAttemptsRetainMatchingOtherPassAndMissingEvidenceCounts() async throws {
        let (frozen, approval, cases) = try await fixture()
        let executor = ReproductionFactExecutor([.matching, .passed, .other, .unassessed, .matching])
        let report = try await AutomationReproduction(cases: cases).run(frozen: frozen, originalAttemptID: "original", approval: approval, limits: .firstCampaign, executor: executor)
        XCTAssertTrue(report.complete); XCTAssertTrue(report.reproduced)
        XCTAssertEqual(report.matchingFailures, 2); XCTAssertEqual(report.assessedPasses, 1)
        XCTAssertEqual(report.otherFailures, 1); XCTAssertEqual(report.unassessed, 1)
        XCTAssertEqual(report.counters.planned, 5); XCTAssertEqual(report.counters.assessed, 4)
        XCTAssertEqual(Set(report.attempts.map(\.attemptID)).count, 5)
        XCTAssertFalse(report.attempts.contains(where: { $0.attemptID == "original" }))
        var fabricated = report; fabricated.matchingFailures = 3
        XCTAssertThrowsError(try fabricated.validate())
        fabricated = report; fabricated.signature = ["business.muted"]
        XCTAssertThrowsError(try fabricated.validate())
    }
    func testLegacyObservationLabelIsTheActualFrozenFailureSignature() async throws {
        let (frozen, approval, cases) = try await fixture(legacy: true)
        let report = try await AutomationReproduction(cases: cases).run(frozen: frozen, originalAttemptID: "original", approval: approval, limits: .firstCampaign, executor: ReproductionFactExecutor([.matching]))
        XCTAssertEqual(report.signature, ["visible-state"]); XCTAssertEqual(report.matchingFailures, 5)
    }
    func testSavedReproductionReopensAndRequiresTheActualStoredParentFailure() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let (frozen, approval, cases) = try await fixture(caseRoot: root)
        let report = try await AutomationReproduction(cases: cases).run(frozen: frozen, originalAttemptID: "original", approval: approval,
            limits: .firstCampaign, executor: ReproductionFactExecutor([.matching]))
        let archive = try AutomationReproductionArchive(caseStoreRoot: root)
        try await archive.save(report)
        let reopened = try AutomationReproductionArchive(caseStoreRoot: root)
        let loaded = try await reopened.load(runID: report.runID)
        XCTAssertEqual(loaded, report)
        let records = try await reopened.records(); XCTAssertEqual(records, [report])
        do { try await reopened.save(report); XCTFail("Overwrote immutable reproduction") } catch {}
        var inventedParent = report
        inventedParent.originalFailure = ReproductionFactExecutor.report(frozen: frozen, runID: "original-run", attemptID: "unsaved", outcome: .matching)
        try inventedParent.validate()
        do { try await reopened.save(inventedParent); XCTFail("Accepted an unsaved parent failure") } catch {}
        do { _ = try await reopened.load(runID: "../escape"); XCTFail("Traversed archive") } catch {}
    }
    func testExactApprovalAndActualSavedFailureAreRequiredBeforeExecutor() async throws {
        let (frozen, approval, cases) = try await fixture(), executor = ReproductionFactExecutor([.matching])
        var wrong = approval; wrong.approvedCaseDigest = String(repeating: "a", count: 64)
        for (id, scope) in [("original", wrong), ("missing", approval)] {
            do { _ = try await AutomationReproduction(cases: cases).run(frozen: frozen, originalAttemptID: id, approval: scope, limits: .firstCampaign, executor: executor); XCTFail("Accepted missing or unapproved reproduction") } catch {}
        }
        let passed = ReproductionFactExecutor.report(frozen: frozen, runID: "old", attemptID: "passed", outcome: .passed)
        try await cases.saveAttempt(passed, for: frozen)
        do { _ = try await AutomationReproduction(cases: cases).run(frozen: frozen, originalAttemptID: "passed", approval: approval, limits: .firstCampaign, executor: executor); XCTFail("A saved pass became a failure") } catch {}
        let calls = await executor.calls; XCTAssertEqual(calls, 0)
    }
    func testCanonicalCancellationStopsImmediatelyAndFifthCancellationIsNotCompletion() async throws {
        let populations: [[ReproductionFactExecutor.Outcome]] = [[.cancelled], [.matching, .matching, .matching, .matching, .cancelled]]
        for outcomes in populations {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let (frozen, approval, cases) = try await fixture(caseRoot: root), executor = ReproductionFactExecutor(outcomes)
            let report = try await AutomationReproduction(cases: cases).run(frozen: frozen, originalAttemptID: "original", approval: approval, limits: .firstCampaign, executor: executor)
            let calls = await executor.calls
            XCTAssertEqual(calls, outcomes.count); XCTAssertEqual(report.stopReason, "Cancelled")
            XCTAssertFalse(report.complete); XCTAssertFalse(report.reproduced)
            var stripped = report; stripped.stopReason = nil
            XCTAssertFalse(stripped.complete)
            XCTAssertThrowsError(try stripped.validate())
            let archive = try AutomationReproductionArchive(caseStoreRoot: root)
            do { try await archive.save(stripped); XCTFail("A stripped cancellation was archived") } catch {}
            if outcomes.count == 1 {
                var continued = report
                continued.record(ReproductionFactExecutor.report(frozen: frozen, runID: approval.runID, attemptID: "after-cancel", outcome: .matching))
                continued.usage.attempts += 1
                XCTAssertThrowsError(try continued.validate())
            }
        }
    }
    func testInterruptedExecutorRetainsOneUnknownDispatchAndCannotManufactureAReproduction() async throws {
        let (frozen, approval, cases) = try await fixture(), executor = ReproductionFactExecutor([.interrupted])
        let report = try await AutomationReproduction(cases: cases).run(frozen: frozen, originalAttemptID: "original", approval: approval, limits: .firstCampaign, executor: executor)
        XCTAssertTrue(report.attempts.isEmpty); XCTAssertEqual(report.interruption?.dispatchMayHaveOccurred, true)
        XCTAssertEqual(report.counters.unresolved, 1); XCTAssertEqual(report.usage.attempts, 1)
        XCTAssertFalse(report.complete); XCTAssertFalse(report.reproduced)
        let calls = await executor.calls; XCTAssertEqual(calls, 1)
    }
}
private actor ReproductionFactExecutor: AutomationCampaignAttemptExecutor {
    enum Outcome: Sendable { case matching, passed, other, unassessed, cancelled, interrupted }
    let outcomes: [Outcome]
    var calls = 0
    init(_ outcomes: [Outcome]) { self.outcomes = outcomes }
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) throws -> AutomationAttemptReport {
        let outcome = outcomes[min(calls, outcomes.count - 1)]; calls += 1
        if outcome == .interrupted { throw CancellationError() }
        return Self.report(frozen: frozen, runID: approval.runID, attemptID: attemptID, outcome: outcome)
    }
    static func report(frozen: AutomationFrozenCase, runID: String, attemptID: String, outcome: Outcome) -> AutomationAttemptReport {
        // Source-contract facts only; not accessibility or hardware qualification.
        let plan = frozen.plan
        if outcome == .cancelled {
            return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: false, subjectCompleted: false, observations: [], termination: .cancelled), receipts: [], resourcesReleased: true)
        }
        let observations: [AutomationObservation] = outcome == .unassessed ? [] : plan.observations.enumerated().map { index, segment in
            let value: AutomationValue = index == 0 ? .text(outcome == .matching ? "40%" : "50%") : .bool(outcome == .other)
            return .init(id: segment.id, app: plan.app, target: plan.target, environmentID: plan.environmentID, attemptID: attemptID, stepID: segment.id, route: .ui, proof: .visibleState, value: value)
        }
        let receipts = ([plan.execution] + plan.observations).enumerated().map { index, segment in
            AutomationSegmentReceipt(scope: .init(runID: runID, attemptID: attemptID, segmentID: segment.id, leaseGeneration: index + 1), app: plan.app, target: plan.target, segmentID: segment.id, route: .ui, dispatched: true, completed: true, observations: observations.filter { $0.id == segment.id })
        }
        return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: true, subjectCompleted: true, observations: observations), receipts: receipts, resourcesReleased: true)
    }
}
