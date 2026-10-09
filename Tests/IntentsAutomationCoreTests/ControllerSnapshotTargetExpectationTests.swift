import XCTest
@testable import IntentsAutomationControllerProbe

final class ControllerSnapshotTargetExpectationTests: XCTestCase {
    func testWrongObservedTapDoesNotPassProgressExpectation() throws {
        try ControllerSnapshotTargetExpectation.validate(["work"], kinds: ["tap"], observed: ["add", "work"])
        XCTAssertTrue(ControllerSnapshotTargetExpectation.matches(["work"], node: "work"))
        XCTAssertFalse(ControllerSnapshotTargetExpectation.matches(["work"], node: "add"))
        XCTAssertFalse(ControllerSnapshotTargetExpectation.matches(["work"], node: nil))
    }
    func testTargetGradingIsOptionalForExistingUnconstrainedCases() throws {
        try ControllerSnapshotTargetExpectation.validate(nil, kinds: ["finish"], observed: [])
        XCTAssertTrue(ControllerSnapshotTargetExpectation.matches(nil, node: nil))
    }
    func testInvalidOrUnobservedGradingTargetsAreRejected() {
        for ids in [[], ["work", "work"], ["foreign"], Array(repeating: "work", count: 31)] {
            XCTAssertThrowsError(try ControllerSnapshotTargetExpectation.validate(ids, kinds: ["tap"], observed: ["work"]))
        }
        for kinds in [[], ["finish"], ["tap", "cannotProceed"]] {
            XCTAssertThrowsError(try ControllerSnapshotTargetExpectation.validate(["work"], kinds: kinds, observed: ["work"]))
        }
    }
}
