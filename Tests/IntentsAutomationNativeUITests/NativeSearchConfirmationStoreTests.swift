#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    func testPendingNativeRunCanBeReviewedAndConfirmedWhileApplicationSelectionIsBlocked() async throws {
        let (model, _, bundle) = try await fixture(executor: { _, plan, approval, _, attemptID, _ in
            try await NativeSearchFactExecutor().execute(frozen: AutomationFrozenCase(plan: plan), approval: approval,
                attemptID: attemptID, budget: .init(limits: .firstCampaign))
        })
        model.uiExpectedText = "Complete"
        let preview = try model.previewCommand(), requestID = UUID()
        _ = try model.requestCommand(id: requestID, digest: preview.digest)
        let selected = model.candidateID, epoch = model.selectionEpoch
        XCTAssertFalse(model.canSelectApplicationFromCommand)
        XCTAssertTrue(model.canReviewSelectedApplicationForRun)
        XCTAssertTrue(model.canRun)
        model.select(bundle)
        XCTAssertEqual(model.candidateID, selected)
        XCTAssertEqual(model.selectionEpoch, epoch)
        let review = try await model.prepareNativeConfirmation(.run)
        XCTAssertEqual(review.id, requestID)
        XCTAssertEqual(review.digest, preview.digest)
        XCTAssertFalse(model.canSelectApplicationFromCommand)
        XCTAssertTrue(model.canReviewSelectedApplicationForRun)
        try await model.confirmNativeRequest(review)
        await model.task?.value
        XCTAssertEqual(try model.commandStatus(id: requestID).state, "completed")
        XCTAssertEqual(model.report?.resourcesReleased, true)
        XCTAssertEqual(model.report?.result.subjectDispatched, true)
        XCTAssertNil(model.pendingCommandStatus)
    }
    func testRequestSearchRequiresConcreteResetAndSessionContract() async throws {
        let (model, root, _) = try await fixture()
        try selectPreparedSource(model: model, root: root)
        model.uiExpectedText = "Complete"; model.uiAlternatePhrases = "Show completed tasks"
        model.uiVarySubjectRequest = true; model.uiApprovedText = "List completed tasks"
        model.effectChoice = "fixture"; model.disposable = true
        model.uiRequestInputControl = "Request"; model.uiRequestResetControl = "New session"
        model.uiRequestSessionIdentity = "Session ID"; model.uiRequestEmptyStateControl = "Messages"
        model.uiRequestEmptyStateText = "Empty"; model.uiRequestSubmitControl = "Send"
        XCTAssertFalse(model.canFindFailures)
        XCTAssertTrue(model.failureSearchUnavailableReason?.contains("concrete") == true)
        XCTAssertThrowsError(try model.reviewNativeSearch())
    }
    func testConcreteNavigationCannotQueueControllerPhraseSearch() async throws {
        let (model, root, _) = try await fixture()
        try selectPreparedSource(model: model, root: root)
        model.uiExpectedText = "Complete"; model.uiAlternatePhrases = "Show tasks"
        XCTAssertTrue(model.canRun); XCTAssertFalse(model.canFindFailures)
        XCTAssertTrue(model.failureSearchUnavailableReason?.contains("fixed controls") == true)
        XCTAssertThrowsError(try model.reviewNativeSearch())
        await model.findFailures()
        XCTAssertNil(model.searchReport); XCTAssertFalse(model.busy)
    }
    func testUnavailableSearchCannotConsumeQueuedWorkflowApproval() async throws {
        let (model, root, _) = try await fixture()
        try selectPreparedSource(model: model, root: root)
        model.uiExpectedText = "Complete"; model.uiAlternatePhrases = "Show tasks"
        let preview = try model.previewCommand(), id = UUID()
        _ = try model.requestCommand(id: id, digest: preview.digest)
        await model.findFailures()
        XCTAssertEqual(try model.commandStatus(id: id).state, "awaitingApproval")
        XCTAssertNil(model.searchReport); XCTAssertFalse(model.busy)
    }
}
#endif
