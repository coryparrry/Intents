#if os(macOS)
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    func testFreshRecordRunsWithoutOfferingUnsupportedControllerMutations() async throws {
        let (model, root, _) = try await fixture()
        try selectFreshSource(model: model, root: root)
        model.workflowRoute = "freshSearch"
        XCTAssertTrue(model.canRun)
        XCTAssertFalse(model.canFindFailures)
        XCTAssertTrue(model.failureSearchUnavailableReason?.contains("concrete") == true)
        XCTAssertThrowsError(try model.reviewNativeSearch())
    }
    func testUnavailableRecordSearchCannotDispatchOrSaveReport() async throws {
        let (model, root, _) = try await fixture(searchExecutor: { _, _, _, _ in
            XCTFail("Unavailable record mutation search dispatched"); throw AutomationContractError.invalidIdentity
        })
        try selectFreshSource(model: model, root: root)
        model.workflowRoute = "freshSearch"
        await model.findFailures()
        XCTAssertNil(model.searchReport); XCTAssertTrue(model.savedSearches.isEmpty); XCTAssertFalse(model.busy)
    }
}
#endif
