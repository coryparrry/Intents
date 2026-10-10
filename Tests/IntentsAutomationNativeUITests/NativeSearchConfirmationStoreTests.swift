#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    func testNativeSearchReviewRejectsChangedPhrasesOracleDestinationAndPermission() async throws {
        for mutation in 0..<4 {
            let (model, _, _) = try fixture(searchExecutor: { _, _, _, _, _ in
                XCTFail("Changed search dispatched"); throw AutomationContractError.invalidIdentity
            })
            model.uiExpectedText = "Complete"; model.uiAlternatePhrases = "Show tasks"
            let review = try model.reviewNativeSearch()
            XCTAssertTrue(review.message.contains("Show tasks")); XCTAssertTrue(review.message.contains(model.simulatorID))
            switch mutation {
            case 0: model.uiAlternatePhrases = "Open my tasks"
            case 1: model.uiExpectedText = "Different state"
            case 2: model.simulatorID = UUID().uuidString
            default: model.installApproved.toggle()
            }
            await model.findFailures(reviewed: review)
            XCTAssertFalse(model.busy); XCTAssertNil(model.searchReport); XCTAssertNil(model.report)
            XCTAssertNotNil(model.message)
        }
    }
    func testNativeSearchReviewRejectsSelectionABAAndCannotConsumeQueuedRun() async throws {
        let (model, _, _) = try fixture(searchExecutor: { _, _, _, _, _ in
            XCTFail("Stale search dispatched"); throw AutomationContractError.invalidIdentity
        })
        model.uiExpectedText = "Complete"; model.uiAlternatePhrases = "Show tasks"
        let review = try model.reviewNativeSearch(), target = model.simulatorID
        model.simulatorID = UUID().uuidString; model.preparationSelectionChanged()
        model.simulatorID = target; model.preparationSelectionChanged()
        await model.findFailures(reviewed: review)
        XCTAssertNil(model.searchReport); XCTAssertFalse(model.busy)
        let preview = try model.previewCommand(), id = UUID()
        _ = try model.requestCommand(id: id, digest: preview.digest)
        XCTAssertFalse(model.canFindFailures); XCTAssertThrowsError(try model.reviewNativeSearch())
        await model.findFailures(reviewed: review)
        XCTAssertEqual(model.pendingCommandStatus?.requestID, id); XCTAssertNil(model.searchReport)
    }
    func testMatchingNativeSearchReviewExecutesFrozenPhrasesAndOracleAndRejectsReuse() async throws {
        let (model, _, _) = try fixture(searchExecutor: { proposal, _, _, support, _ in
            XCTAssertEqual(proposal.baseline.plan.requirements.first?.expected, .text("Complete"))
            XCTAssertEqual(proposal.mutations.first?.frozen.plan.execution.uiProgram?.operations.first?.goal?.instruction, "Show tasks")
            let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
            return try await AutomationFailureSearch(cases: cases).run(baseline: proposal.baseline, mutations: proposal.mutations,
                approval: proposal.approval, capabilities: .init(), executor: NativeSearchFactExecutor())
        })
        model.uiExpectedText = "Complete"; model.uiAlternatePhrases = "Show tasks"
        let review = try model.reviewNativeSearch()
        await model.findFailures(reviewed: review)
        let result = try XCTUnwrap(model.searchReport)
        XCTAssertEqual(result.attempts.count, 4)
        await model.findFailures(reviewed: review)
        XCTAssertEqual(model.searchReport, result); XCTAssertFalse(model.busy)
    }
}
#endif
