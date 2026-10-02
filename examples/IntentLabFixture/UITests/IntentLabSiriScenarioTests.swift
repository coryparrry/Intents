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
        let dirtyApp = try integration.prepare(bundleIdentifier: declaration.targetBundleIdentifier,
            context: "read-only-cleanup", operationID: "reset")
        let summarize = dirtyApp.buttons["Summarize Packing note"]
        XCTAssertTrue(summarize.waitForExistence(timeout: 5))
        summarize.tap()
        let selected = dirtyApp.staticTexts["intent-lab-selected-note-id"]
        let selectedNote = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "packing-001"), object: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [selectedNote], timeout: 5), .completed)
        dirtyApp.terminate()
        // The reset must clear previously selected state, even after relaunch.
        XCTAssertNoThrow(try integration.cleanup(bundleIdentifier: declaration.targetBundleIdentifier,
            context: "read-only-cleanup", operationID: "reset"))
        let relaunched = XCUIApplication(bundleIdentifier: declaration.targetBundleIdentifier)
        relaunched.launchArguments = ["-intent-lab-context", "read-only-cleanup-verification"]
        relaunched.launch()
        defer { relaunched.terminate() }
        XCTAssertNoThrow(try NotesIntentLabIntegration.verifyReset(integration.observe(application: relaunched)))
    }

    func testResetVerificationRejectsIncompleteOrDirtyState() throws {
        let baseline: [String: IntentLabValue] = ["selectedNoteID": .string("none"),
            "noteStoreMutationCount": .integer(0), "applicationEvent": .string("none")]
        XCTAssertNoThrow(try NotesIntentLabIntegration.verifyReset(baseline))
        for dirty in [[:], ["selectedNoteID": IntentLabValue.string("packing-001")],
                      ["noteStoreMutationCount": .integer(1)], ["applicationEvent": .string("old-event")]] {
            var observations = baseline
            if dirty.isEmpty { observations.removeValue(forKey: "selectedNoteID") }
            else { observations.merge(dirty) { _, replacement in replacement } }
            XCTAssertThrowsError(try NotesIntentLabIntegration.verifyReset(observations))
        }
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
