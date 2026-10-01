import IntentLabTesting
import XCTest

@available(iOS 27.0, *)
@MainActor
final class IntentLabScenarioTests: XCTestCase {
    func testIntentLabScenario() throws {
        try IntentLabScenarioRunner.run(testCase: self, integration: NotesIntentLabIntegration())
    }

    func testIntentLabConnection() throws {
        try IntentLabScenarioRunner.checkConnection(testCase: self, integration: NotesIntentLabIntegration())
    }
}
