import XCTest
import IntentLabContracts
@testable import IntentLabTesting

@available(macOS 27.0, iOS 27.0, *)
@MainActor
final class IntentLabQueryObserverTests: XCTestCase {
    func testQueryWaitCompletesOnMainActor() throws {
        let observed = try IntentLabQueryObserver.runBounded(deadlineSeconds: 2) {
            ["status": .boolean(true)]
        }

        XCTAssertEqual(observed["status"], .boolean(true))
    }

    func testEntityQueryRejectsMissingAndDuplicateRecords() throws {
        XCTAssertNoThrow(try IntentLabQueryObserver.validateEntityIdentifiers(
            expected: ["task-001", "task-002"], actual: ["task-002", "task-001"]
        ))
        XCTAssertThrowsError(try IntentLabQueryObserver.validateEntityIdentifiers(
            expected: ["task-001", "task-002"], actual: ["task-001"]
        )) { XCTAssertTrue($0 is IntentLabQueryObservationError) }
        XCTAssertThrowsError(try IntentLabQueryObserver.validateEntityIdentifiers(
            expected: ["task-001", "task-002"], actual: ["task-001", "task-001"]
        )) { XCTAssertTrue($0 is IntentLabQueryObservationError) }
    }

    func testQueryDeadlineCancelsPendingObservation() {
        XCTAssertThrowsError(try IntentLabQueryObserver.runBounded(deadlineSeconds: 0.02) {
            try await Task.sleep(for: .seconds(2))
            return ["status": .boolean(true)]
        }) { XCTAssertTrue($0 is IntentLabQueryObservationError) }
    }
}
