import IntentLabCoreTesting
import IntentLabContracts
import XCTest

@available(iOS 27.0, *)
@MainActor
final class IntentLabSiriScenarioTests: XCTestCase {
    func testIntentLabScenario() throws {
        let evidence = try IntentLabSiriScenarioRunner.run(
            testCase: self,
            integration: NotesIntentLabIntegration()
        )
        for result in evidence.results where result.lane == .siri {
            XCTAssertEqual(result.executionStatus, .completed, "Siri attempt \(result.attempt) did not complete: \(result.diagnostic ?? "no diagnostic")")
            XCTAssertNotEqual(result.outcome, .failed, "Siri attempt \(result.attempt) failed its frozen assertions")
            XCTAssertNotEqual(result.outcome, .notObserved, "Siri attempt \(result.attempt) did not produce qualifying evidence")
        }
    }

    func testIntentLabConnection() throws {
        try IntentLabSiriScenarioRunner.checkConnection(testCase: self, integration: NotesIntentLabIntegration())
    }
}
