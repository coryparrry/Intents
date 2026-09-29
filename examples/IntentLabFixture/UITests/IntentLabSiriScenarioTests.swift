import IntentLabCoreTesting
import IntentLabContracts
import XCTest

@available(iOS 27.0, *)
@MainActor
final class IntentLabScenarioTests: XCTestCase {
    func testIntentLabScenario() throws {
        _ = try IntentLabSiriScenarioRunner.run(
            testCase: self,
            integration: NotesIntentLabIntegration()
        )
    }

    /// Developers can select this entry point in Xcode/CI when they want a
    /// failed requirement to fail XCTest. The host selects the capture test above.
    func testIntentLabScenarioStandalone() throws {
        let evidence = try IntentLabSiriScenarioRunner.run(
            testCase: self, integration: NotesIntentLabIntegration()
        )
        for result in evidence.results where result.lane == .siri {
            XCTAssertEqual(result.executionStatus, .completed, "Siri attempt \(result.attempt) did not complete: \(result.diagnostic ?? "no diagnostic")")
            XCTAssertEqual(result.outcome, .passed,
                           "Siri attempt \(result.attempt): \(result.actionFailureReason?.rawValue ?? result.diagnostic ?? "requirement unmet")")
        }
    }

    func testIntentLabConnection() throws {
        try IntentLabSiriScenarioRunner.checkConnection(testCase: self, integration: NotesIntentLabIntegration())
    }

    func testIntentLabReadiness() throws {
        try IntentLabSiriScenarioRunner.testIntentLabReadiness(testCase: self, integration: NotesIntentLabIntegration())
    }
}
