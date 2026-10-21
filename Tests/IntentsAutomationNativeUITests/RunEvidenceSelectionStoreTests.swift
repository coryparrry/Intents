#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    func testChangingApplicationCandidateActionOrWorkflowClearsCurrentAttemptEvidence() async throws {
        for change in ["application", "candidate", "action", "workflow"] {
            let (model, root, bundle) = try await fixture(evidenceImporter: { plan, report, _, _ in
                try .init(frozen: AutomationFrozenCase(plan: plan), report: report, artifacts: [])
            })
            let frozen = try await saveFailure(model: model, root: root)
            let report = try XCTUnwrap(model.savedViewedReport)
            model.report = report
            model.reportDirectory = model.support.appendingPathComponent(report.attemptID)
            await model.importEvidence(plan: frozen.plan, report: report)
            XCTAssertNotNil(model.canonicalPresentation, change)
            switch change {
            case "application": model.select(bundle)
            case "candidate": model.selectCandidate()
            case "action": model.selectAction()
            default: model.workflowSelectionChanged()
            }
            XCTAssertNil(model.report, change)
            XCTAssertNil(model.reportDirectory, change)
            XCTAssertNil(model.canonicalEvidence, change)
            XCTAssertNil(model.canonicalPresentation, change)
            await model.task?.value
        }
    }

    func testReplacingCurrentReportDropsPreviousAttemptEvidence() async throws {
        let (model, root, _) = try await fixture(evidenceImporter: { plan, report, _, _ in
            try .init(frozen: AutomationFrozenCase(plan: plan), report: report, artifacts: [])
        })
        let frozen = try await saveFailure(model: model, root: root)
        let previous = try XCTUnwrap(model.savedViewedReport)
        model.report = previous
        model.reportDirectory = model.support.appendingPathComponent(previous.attemptID)
        await model.importEvidence(plan: frozen.plan, report: previous)
        XCTAssertNotNil(model.canonicalPresentation)
        let result = AutomationAssessment.assess(plan: frozen.plan, attemptID: "next",
            subjectDispatched: false, subjectCompleted: false, observations: [], termination: .unresolved)
        let next = AutomationAttemptReport(attemptID: "next", result: result, receipts: [], resourcesReleased: false)
        model.report = next
        XCTAssertEqual(model.report, next)
        XCTAssertEqual(model.retainedUnresolvedNormalReport, next)
        XCTAssertNil(model.reportDirectory)
        XCTAssertNil(model.canonicalEvidence)
        XCTAssertNil(model.canonicalPresentation)
        // Ordinary execution creates its evidence directory before returning the report.
        let nextDirectory = model.support.appendingPathComponent(next.attemptID)
        model.report = nil
        model.reportDirectory = nextDirectory
        model.report = next
        XCTAssertEqual(model.reportDirectory, nextDirectory)
    }
}
#endif
