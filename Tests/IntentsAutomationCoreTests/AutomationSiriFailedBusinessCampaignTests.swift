#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationSiriFailedBusinessCampaignTests: XCTestCase, @unchecked Sendable {
    private struct Executor: AutomationCampaignAttemptExecutor {
        let authorities: [String: AutomationSiriRouteAuthority]
        func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                     budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
            try AutomationSiriRepeatableQualification.validate(plan: frozen.plan, approval: approval, authority: authorities[frozen.digest])
            // The selected record stays unchanged: deterministic wrong-record or omitted-save business failure.
            return SiriSubmissionQualificationTestFixture.report(plan: frozen.plan, approval: approval, attemptID: attemptID)
        }
    }
    func testFailedBusinessQualificationReachesFiveConfirmationsAndFinalReproduction() async throws {
        let f = try SiriSubmissionQualificationTestFixture.make()
        let baseline = try AutomationFrozenCase(plan: f.plan)
        let mutations = try ["Finish Approved task in Example", "Mark Approved task complete in Example"].map {
            try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .siriRecognizedText, request: $0,
                semanticJustification: "Same approved operation and independent record oracle")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = try AutomationCaseStore(root: root), registry = AutomationSiriQualificationAuthority()
        let approval = AutomationSearchApproval(run: f.approval, approvedDigests: Set(([baseline] + mutations.map(\.frozen)).map(\.digest)), limits: .init())
        XCTAssertEqual(approval.limits.attempts, 100); XCTAssertEqual(AutomationCampaignLimits.firstCampaign.attempts, 20)
        let dependencies = AutomationSiriSearchCampaign.Dependencies(qualify: { frozen, scoped, attemptID, _ in
            let report = SiriSubmissionQualificationTestFixture.report(plan: frozen.plan, approval: scoped, attemptID: attemptID)
            try await cases.saveAttempt(report, for: frozen)
            try await registry.record(prepared: f.prepared, plan: frozen.plan, approval: scoped, report: report,
                submission: SiriSubmissionQualificationTestFixture.submission(plan: frozen.plan, report: report))
            return report
        }, authority: { frozen, scoped in
            await registry.admission(prepared: f.prepared, plan: frozen.plan, approval: scoped)
        }, executor: { Executor(authorities: $0) })
        let result = try await AutomationSiriSearchCampaign.run(baseline: baseline, mutations: mutations, approval: approval,
            prepared: f.prepared, capabilities: f.capabilities, cases: cases, dependencies: dependencies)
        XCTAssertEqual(result.stopReason, "Approved search population completed")
        XCTAssertEqual(result.qualificationAttempts?.count, 6)
        XCTAssertTrue(result.qualificationAttempts?.allSatisfy { $0.report.result.summary == .assertionFailed } == true)
        XCTAssertEqual(result.confirmations.count, 2)
        XCTAssertTrue(result.confirmations.allSatisfy { $0.complete && $0.confirmed && $0.matchingFailures == 5 && $0.unassessed == 0 })
        XCTAssertEqual(result.finalReproduction?.attempts.count, 5); XCTAssertTrue(result.finalReproduction?.confirmed == true)
        XCTAssertNotNil(result.bestConfirmedCaseDigest)
        XCTAssertGreaterThan(result.usage.attempts, 20); XCTAssertLessThanOrEqual(result.usage.attempts, 100)
        // Historical save/load retains failure facts without restoring runtime authority.
        let archive = try AutomationUIFailureSearchArchive(caseStoreRoot: root)
        let record = AutomationUIFailureSearchRecord(id: "deterministic-siri-business-failure", runID: f.approval.runID,
            baseline: baseline, mutations: mutations, report: result)
        try await archive.save(record)
        let restored = try await archive.load(id: record.id); XCTAssertEqual(restored, record)
        XCTAssertThrowsError(try AutomationSiriRepeatableQualification.validate(plan: restored.baseline.plan, approval: f.approval, authority: nil))
    }
}
#endif
