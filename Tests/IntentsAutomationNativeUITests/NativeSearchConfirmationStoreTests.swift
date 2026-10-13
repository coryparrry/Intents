#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    func testConcreteNavigationCannotQueueControllerPhraseSearch() async throws {
        let (model, root, _) = try await fixture()
        try selectPreparedSource(model: model, root: root)
        model.uiExpectedText = "Complete"; model.uiAlternatePhrases = "Show tasks"
        XCTAssertTrue(model.canRun); XCTAssertFalse(model.canFindFailures)
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
