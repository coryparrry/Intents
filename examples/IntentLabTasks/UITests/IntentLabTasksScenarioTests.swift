import IntentLabTesting
import XCTest

@available(iOS 27.0, *)
@MainActor
final class IntentLabScenarioTests: XCTestCase {
    func testIntentLabScenario() throws {
        try IntentLabScenarioRunner.run(testCase: self, integration: TaskIntegration())
    }

    func testIntentLabConnection() throws {
        try IntentLabScenarioRunner.checkConnection(testCase: self, integration: TaskIntegration())
    }

    func testIntentLabReadiness() throws {
        try IntentLabScenarioRunner.testIntentLabReadiness(testCase: self, integration: TaskIntegration())
    }
}
