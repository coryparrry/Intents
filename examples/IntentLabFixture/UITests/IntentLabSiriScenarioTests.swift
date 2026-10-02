import IntentLabCoreTesting
import IntentLabContracts
import XCTest

@available(iOS 27.0, *)
@MainActor
final class IntentLabSiriScenarioTests: XCTestCase {
    func testReadOnlyResetCleanupUsesTheShippedDeclarationAndAdapter() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "IntentLabIntegration", withExtension: "json"))
        let declaration = try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self,
            from: Data(contentsOf: url))
        try declaration.validate()
        XCTAssertTrue(declaration.allowsCleanupOperation("reset"))
        let integration = NotesIntentLabIntegration()
        XCTAssertThrowsError(try integration.cleanup(bundleIdentifier: declaration.targetBundleIdentifier,
            context: "read-only-cleanup", operationID: "undeclared-reset"))
        // Cleanup launches the fixture and verifies its empty baseline before terminating it.
        XCTAssertNoThrow(try integration.cleanup(bundleIdentifier: declaration.targetBundleIdentifier,
            context: "read-only-cleanup", operationID: "reset"))
    }

    func testIntentLabScenario() throws {
        let scenarioData = try XCTUnwrap(
            IntentLabPayloadLoader.environmentData(named: "IntentLabScenario"),
            "A bound scenario is required for the fixture's Siri route check."
        )
        let scenario = try JSONDecoder().decode(IntentLabScenario.self, from: scenarioData)
        let evidence = try IntentLabSiriScenarioRunner.run(
            testCase: self,
            integration: NotesIntentLabIntegration()
        )
        for result in evidence.results where result.lane == .siri {
            XCTAssertEqual(result.executionStatus, .completed, "Siri attempt \(result.attempt) did not complete: \(result.diagnostic ?? "no diagnostic")")
            XCTAssertNotEqual(result.outcome, .failed, "Siri attempt \(result.attempt) failed its frozen assertions")
            XCTAssertNotEqual(result.outcome, .notObserved, "Siri attempt \(result.attempt) did not produce qualifying evidence")
            if ["OpenNoteIntent", "SummarizeNoteIntent"].contains(scenario.directControl.intentIdentifier) {
                guard case .string(let event)? = result.observations["applicationEvent"] else {
                    XCTFail("Siri attempt \(result.attempt) did not capture the app's executed intent.")
                    continue
                }
                XCTAssertTrue(
                    event.hasPrefix("\(scenario.directControl.intentIdentifier):"),
                    "Siri attempt \(result.attempt) executed \(event), not \(scenario.directControl.intentIdentifier)."
                )
            }
        }
    }

    func testIntentLabConnection() throws {
        try IntentLabSiriScenarioRunner.checkConnection(testCase: self, integration: NotesIntentLabIntegration())
    }
}
