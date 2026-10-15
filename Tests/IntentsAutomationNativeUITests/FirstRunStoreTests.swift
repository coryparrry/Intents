#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    func testFirstChecksNeedNoHandWrittenWorkflowAndRejectChangedHost() async throws {
        let (model, root, _) = try await fixture()
        try selectPreparedSource(model: model, root: root)
        model.uiInstruction = ""; model.uiEndpoint = ""; model.effectsConfirmed = false; model.effectChoice = ""
        XCTAssertTrue(model.canReviewFirstChecks)
        let review = try model.reviewFirstChecks()
        XCTAssertEqual(review.requests.count, 1)
        XCTAssertEqual(review.requests[0].plan.execution.kind, .observeOnly)
        model.prepared?.host.hostProductDigest = String(repeating: "f", count: 64)
        model.runFirstChecks(review)
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.message); XCTAssertTrue(model.firstRunReports.isEmpty)
    }
    func testAutomaticActionCampaignNeedsBusinessApprovalAndStopsOnUncertainDispatch() async throws {
        let facts = FirstRunFacts(uncertainAt: 1)
        let (model, root, _) = try await fixture(executor: { _, plan, approval, _, id, _ in await facts.execute(plan: plan, approval: approval, id: id) })
        try selectPreparedSource(model: model, root: root)
        var prepared = try XCTUnwrap(model.prepared)
        prepared.catalog.systemActions = ["First", "Second"].map { .init(id: $0, typeName: $0, title: $0, parameters: [], parametersComplete: true, compiled: true, registered: false, executed: false, resultFamily: "noValue") }
        model.prepared = prepared; model.catalog = prepared.catalog
        model.firstRunIncludesActions = true
        XCTAssertThrowsError(try model.reviewFirstChecks())
        model.effectChoice = "navigation"; model.firstRunEffectsConfirmed = true
        let review = try model.reviewFirstChecks(); XCTAssertEqual(review.requests.count, 3)
        model.runFirstChecks(review); await model.task?.value
        let count = await facts.count
        XCTAssertEqual(count, 1); XCTAssertEqual(model.firstRunReports.count, 1)
        XCTAssertFalse(model.canReviewFirstChecks)
        XCTAssertTrue(model.message?.contains("reconciliation") == true)
    }
    func testInstalledAppFirstChecksRetainPreparedHostGapWithoutDispatch() async throws {
        let (model, _, _) = try await fixture()
        let review = try model.reviewFirstChecks()
        XCTAssertTrue(review.requests.isEmpty)
        XCTAssertTrue(review.gaps.contains { $0.contains("prepared source build") })
        model.runFirstChecks(review)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.firstRunReports.isEmpty)
        XCTAssertEqual(model.firstRunGaps, review.gaps)
        XCTAssertEqual(model.message, review.gaps.joined(separator: "\n"))
    }
    func testFirstChecksCompleteAndRetainEachIndependentResult() async throws {
        let facts = FirstRunFacts(uncertainAt: nil)
        let (model, root, _) = try await fixture(executor: { _, plan, approval, _, id, _ in await facts.execute(plan: plan, approval: approval, id: id) })
        try selectPreparedSource(model: model, root: root)
        model.uiInstruction = ""; model.uiEndpoint = ""
        model.runFirstChecks(try model.reviewFirstChecks()); await model.task?.value
        XCTAssertEqual(model.firstRunReports.count, 1)
        XCTAssertEqual(model.firstRunReports[0].result.summary, .executedUnassessed)
        XCTAssertTrue(model.firstRunReports[0].resourcesReleased)
        XCTAssertFalse(model.busy)
    }
}
private actor FirstRunFacts {
    let uncertainAt: Int?
    var count = 0
    init(uncertainAt: Int?) { self.uncertainAt = uncertainAt }
    func execute(plan: AutomationCase, approval: RunApproval, id: String) -> AutomationAttemptReport {
        count += 1
        let uncertain = count == uncertainAt
        let receipt = AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: id, segmentID: plan.execution.id, leaseGeneration: count), app: plan.app, target: plan.target,
            segmentID: plan.execution.id, route: plan.execution.kind, dispatched: true, completed: !uncertain, environmentID: plan.environmentID)
        let result = AutomationAssessment.assess(plan: plan, attemptID: id, subjectDispatched: true, subjectCompleted: !uncertain, observations: [], termination: uncertain ? .unresolved : nil)
        return .init(attemptID: id, result: result, receipts: [receipt], resourcesReleased: !uncertain)
    }
}
#endif
