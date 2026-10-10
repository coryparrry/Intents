#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

extension AutomationPrivateMacAppleRouteDriverTests {
    struct PreparedSavedFixture: Sendable {
        let harness: MacFreshHarness, frozen: AutomationFrozenCase, original: AutomationAttemptReport
        let evidence: AutomationPrivateMacDaemonUnit.Evidence
        var dependencies: AutomationMacSavedWorkflowContract.Dependencies {
            .init(currentTarget: { harness.prepared.host.target }, runtime: { _ in evidence }, locale: { "en_GB" })
        }
    }
    func preparedSavedFixture() async throws -> PreparedSavedFixture {
        let h = try await macFreshHarness(mode: .noChange)
        let report = try await h.runner.run(prepared: h.prepared, plan: h.plan, approval: h.approval, capabilities: h.capabilities,
            attemptID: "original", allowBootAndInstall: false)
        XCTAssertEqual(report.result.summary, .assertionFailed); XCTAssertTrue(report.resourcesReleased)
        let evidence = AutomationPrivateMacDaemonUnit.Evidence(receiptSHA256: AutomationPrivateMacDaemonUnit.pinnedFillProgramReceiptSHA256,
            checkpointSHA256: String(repeating: "b", count: 64), fileCount: 5485, customerRuntimeEnabled: false, hardwareQualified: false, developerIDSigned: false)
        return .init(harness: h, frozen: try AutomationFrozenCase(plan: h.plan), original: report, evidence: evidence)
    }
    func preparedSavedReview(_ f: PreparedSavedFixture, original: AutomationAttemptReport? = nil, disposable: Bool = true,
                            dependencies: AutomationMacSavedWorkflowContract.Dependencies? = nil) throws -> AutomationMacSavedWorkflowContract.Reproduction {
        try AutomationMacSavedWorkflowContract.reproduction(frozen: f.frozen, original: original ?? f.original,
            prepared: f.harness.prepared, runtimeRoot: f.harness.root, runID: "review", disposable: disposable, dependencies: dependencies ?? f.dependencies)
    }
    func testPreparedMacSavedFreshFailureGetsExactReviewWithoutExecutionOrFixtureAuthority() async throws {
        let f = try await preparedSavedFixture(), review = try preparedSavedReview(f)
        XCTAssertEqual(review.frozen.digest, f.frozen.digest); XCTAssertEqual(review.originalAttemptID, "original")
        XCTAssertEqual(review.approval.approvedCaseDigest, f.frozen.digest); XCTAssertEqual(review.approval.target, f.harness.prepared.host.target)
        XCTAssertEqual(review.approval.effects, [.observe, .navigate, .fixtureWrite]); XCTAssertTrue(review.approval.disposable)
        XCTAssertEqual(review.capabilities.records["apple.intent.invoke"]?.state, .available)
        XCTAssertFalse(review.runtimeEvidence.customerRuntimeEnabled); XCTAssertFalse(review.runtimeEvidence.hardwareQualified)
        let names = await f.harness.driver.names; XCTAssertEqual(names.count, 1)
        let unrelated = try AutomationApplicationRunner(supportRoot: f.harness.root.appendingPathComponent("empty"), developerDirectory: f.harness.root)
        do { _ = try await unrelated.qualifyFreshFixture(bindings: AutomationFreshEntityPlanner.bindings(plan: f.frozen.plan)); XCTFail("Imported review minted live authority") } catch {}
    }
    func testPreparedMacSavedReviewRejectsUnreleasedForeignRuntimeLocaleSessionAndMissingConsent() async throws {
        let f = try await preparedSavedFixture()
        var report = f.original; report.resourcesReleased = false
        XCTAssertThrowsError(try preparedSavedReview(f, original: report))
        report = f.original; report.result.assessed = false; report.result.evidenceComplete = false
        XCTAssertThrowsError(try preparedSavedReview(f, original: report))
        report = f.original; report.receipts[0].environmentID = "foreign"
        XCTAssertThrowsError(try preparedSavedReview(f, original: report))
        var dependencies = f.dependencies; dependencies.locale = { "foreign" }
        XCTAssertThrowsError(try preparedSavedReview(f, dependencies: dependencies))
        dependencies = f.dependencies
        let changedEvidence = AutomationPrivateMacDaemonUnit.Evidence(receiptSHA256: AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256,
            checkpointSHA256: f.evidence.checkpointSHA256, fileCount: f.evidence.fileCount,
            customerRuntimeEnabled: false, hardwareQualified: false, developerIDSigned: false)
        dependencies.runtime = { _ in changedEvidence }
        XCTAssertThrowsError(try preparedSavedReview(f, dependencies: dependencies))
        dependencies = f.dependencies; dependencies.currentTarget = { var target = f.harness.prepared.host.target; target.loginSession = "foreign"; return target }
        XCTAssertThrowsError(try preparedSavedReview(f, dependencies: dependencies))
        XCTAssertThrowsError(try preparedSavedReview(f, disposable: false))
        let names = await f.harness.driver.names; XCTAssertEqual(names.count, 1)
    }
    func testPreparedMacSavedReviewRevalidatesSessionAndProductAfterIndependentRuntimeRead() async throws {
        for mode in 0..<2 {
            let f = try await preparedSavedFixture(); var dependencies = f.dependencies
            if mode == 0 {
                let sequence = AutomationMacSavedWorkflowContractTests.TargetSequence(f.harness.prepared.host.target)
                dependencies.currentTarget = { sequence.current() }
            } else {
                dependencies.runtime = { _ in
                    try Data("changed".utf8).write(to: URL(fileURLWithPath: f.harness.prepared.host.subjectProductPath).appendingPathComponent("Contents/MacOS/Subject"))
                    return f.evidence
                }
            }
            XCTAssertThrowsError(try preparedSavedReview(f, dependencies: dependencies))
            let names = await f.harness.driver.names; XCTAssertEqual(names.count, 1)
        }
    }
    func testPreparedMacSavedComparisonBindsTwoActualArtifactSetsAndSeparateApprovals() async throws {
        let f = try await preparedSavedFixture(), after = try await macFreshHarness(changedBuild: true)
        let review = try AutomationMacSavedWorkflowContract.comparison(frozen: f.frozen, original: f.original,
            before: f.harness.prepared, after: after.prepared, runtimeRoot: f.harness.root, runID: "compare", disposable: true, dependencies: f.dependencies)
        XCTAssertEqual(review.baseline, f.frozen); XCTAssertEqual(review.candidate.plan.preparedMacBuildArtifacts, try .init(prepared: after.prepared))
        XCTAssertEqual(review.baseline.oracleDigest, review.candidate.oracleDigest)
        XCTAssertEqual(review.beforeApproval.approvedCaseDigest, review.baseline.digest); XCTAssertEqual(review.afterApproval.approvedCaseDigest, review.candidate.digest)
        XCTAssertNotEqual(review.beforeApproval.runID, review.afterApproval.runID)
        XCTAssertEqual(review.beforeCapabilities.records["apple.entity.query"]?.state, .available)
        XCTAssertEqual(review.afterCapabilities.records["apple.entity.query"]?.state, .available)
        let names = await after.driver.names; XCTAssertTrue(names.isEmpty)
        var changed = after.prepared; changed.generatedHost.templateDigest = String(repeating: "f", count: 64)
        XCTAssertThrowsError(try AutomationMacSavedWorkflowContract.comparison(frozen: f.frozen, original: f.original,
            before: f.harness.prepared, after: changed, runtimeRoot: f.harness.root, runID: "compare", disposable: true, dependencies: f.dependencies))
    }

    func testPreparedMacSavedUIOnlyReviewNeedsNoDisposableFixtureOrAppleCapability() async throws {
        let f = try await preparedSavedFixture(), prepared = f.harness.prepared
        var subject = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "Open", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        subject.uiProgram = .init(operations: [.init(id: "tap", kind: .tap, locator: .init(.label, "Ready"))])
        var observer = subject; observer.id = "observer"; observer.phase = .observe
        observer.uiProgram = .init(operations: [.init(id: "status", kind: .observeProperty, locator: .init(.testId, "status"), property: "text")])
        var plan = AutomationCase(id: "prepared-ui-only", app: prepared.host.app, target: prepared.host.target,
            environmentID: f.frozen.plan.environmentID, execution: subject, observations: [observer],
            requirements: [.init(observationID: "observer", expected: .text("Expected"), proof: .visibleState, justification: "Independent visible state")])
        plan.preparedMacBuildArtifacts = try .init(prepared: prepared)
        plan.provenance["ui.locale"] = "en_GB"; plan.provenance["ui.privateMacReceiptSHA256"] = f.evidence.receiptSHA256
        let observation = AutomationObservation(id: "observer", app: plan.app, target: plan.target, environmentID: plan.environmentID,
            attemptID: "ui-original", stepID: "observer", route: .ui, proof: .visibleState, value: .text("Different"))
        let receipts = [subject, observer].enumerated().map { index, segment in
            AutomationSegmentReceipt(scope: .init(runID: "ui-original-run", attemptID: "ui-original", segmentID: segment.id, leaseGeneration: index + 1),
                app: plan.app, target: plan.target, segmentID: segment.id, route: .ui, dispatched: true, completed: true,
                observations: segment.phase == .observe ? [observation] : [], environmentID: plan.environmentID)
        }
        let original = AutomationAttemptReport(attemptID: "ui-original", result: AutomationAssessment.assess(plan: plan, attemptID: "ui-original",
            subjectDispatched: true, subjectCompleted: true, observations: [observation], receipts: receipts, runID: "ui-original-run"), receipts: receipts, resourcesReleased: true)
        let frozen = try AutomationFrozenCase(plan: plan)
        let review = try AutomationMacSavedWorkflowContract.reproduction(frozen: frozen, original: original, prepared: prepared,
            runtimeRoot: f.harness.root, runID: "review-ui", disposable: false, dependencies: f.dependencies)
        XCTAssertEqual(review.approval.effects, [.observe, .navigate]); XCTAssertFalse(review.approval.disposable)
        XCTAssertTrue(review.capabilities.records.isEmpty); XCTAssertEqual(review.frozen.oracleDigest, frozen.oracleDigest)
        for mode in 0..<2 {
            var changed = plan
            if mode == 0 {
                changed.execution.uiProgram = .init(operations: [.init(id: "fill", kind: .fillBinding, locator: .init(.label, "Name"), binding: "text")], bindings: ["text": "Unapproved input"])
            } else {
                var goal = AutomationNavigationGoal(id: "goal", instruction: "Enter approved text", endpoint: .init(.label, "Ready"))
                goal.allowedFillBindings = ["text"]; goal.minimumBindingUses = ["text": 1]
                changed.execution.uiProgram = .init(operations: [.init(id: "goal", kind: .navigateGoal, goal: goal)], bindings: ["text": "Unapproved input"])
            }
            let changedFrozen = try AutomationFrozenCase(plan: changed)
            let navigationApproval = RunApproval(runID: "review-ui", app: changed.app, target: changed.target, environmentID: changed.environmentID,
                effects: [.observe, .navigate], maximumActions: 30, disposable: false, approvedCaseDigest: changedFrozen.digest)
            try PlanValidator.validate(changed, approval: navigationApproval, capabilities: .init())
            try AutomationRecordedEvidence.validate(report: original, plan: changed)
            XCTAssertThrowsError(try AutomationMacSavedWorkflowContract.reproduction(frozen: changedFrozen, original: original, prepared: prepared,
                runtimeRoot: f.harness.root, runID: "review-ui", disposable: false, dependencies: f.dependencies))
        }
        var navigation = plan
        let goal = AutomationNavigationGoal(id: "goal", instruction: "Open the destination", endpoint: .init(.label, "Ready"))
        navigation.execution.uiProgram = .init(operations: [.init(id: "goal", kind: .navigateGoal, goal: goal)])
        let navigationReview = try AutomationMacSavedWorkflowContract.reproduction(frozen: AutomationFrozenCase(plan: navigation), original: original,
            prepared: prepared, runtimeRoot: f.harness.root, runID: "review-navigation", disposable: false, dependencies: f.dependencies)
        XCTAssertEqual(navigationReview.approval.effects, [.observe, .navigate])
    }
}
#endif
