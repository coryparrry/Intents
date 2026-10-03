import IntentLabCoreTesting
import IntentLabContracts
import XCTest

@available(iOS 27.0, *)
@MainActor
final class IntentLabScenarioTests: XCTestCase {
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
