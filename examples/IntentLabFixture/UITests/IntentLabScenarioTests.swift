import IntentLabTesting
import XCTest

@available(iOS 27.0, *)
@MainActor
final class IntentLabScenarioTests: XCTestCase {
    func testIntentLabScenario() throws {
        try IntentLabScenarioRunner.run(testCase: self, integration: NotesIntentLabIntegration())
    }

    func testIntentLabScenarioStandalone() throws {
        let evidence = try IntentLabScenarioRunner.run(
            testCase: self, integration: NotesIntentLabIntegration()
        )
        for result in evidence.results {
            XCTAssertEqual(result.executionStatus, .completed)
            XCTAssertEqual(result.outcome, .passed,
                           result.actionFailureReason?.rawValue ?? result.diagnostic ?? "requirement unmet")
        }
    }

    func testIntentLabConnection() throws {
        try IntentLabScenarioRunner.checkConnection(testCase: self, integration: NotesIntentLabIntegration())
    }

    func testIntentLabReadiness() throws {
        try IntentLabScenarioRunner.testIntentLabReadiness(testCase: self, integration: NotesIntentLabIntegration())
    }
}
