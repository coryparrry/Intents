import IntentLabContracts
import IntentLabTesting
import Foundation
import XCTest

@available(macOS 27.0, iOS 27.0, *)
@MainActor
final class IntentLabQueryObserverTests: XCTestCase {
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

    func testGenericEntityQueryReadsFixtureNote() throws {
        let application = try NotesIntentLabIntegration().prepare(
            bundleIdentifier: "com.coryparry.IntentLabFixture.integration-tests", context: "query-positive", operationID: "reset"
        )
        defer { application.terminate() }
        let declaration = try makeQueryDeclaration(identifier: "packing-001")
        let observations = try IntentLabQueryObserver.observe(
            bundleIdentifier: "com.coryparry.IntentLabFixture.integration-tests", declaration: declaration, deadlineSeconds: 10
        )
        XCTAssertEqual(observations["queriedNoteTitle"], .string("Packing note"))
    }

    func testGenericEntityQueryRejectsMissingFixtureNote() throws {
        let application = try NotesIntentLabIntegration().prepare(
            bundleIdentifier: "com.coryparry.IntentLabFixture.integration-tests", context: "query-negative", operationID: "reset"
        )
        defer { application.terminate() }
        let declaration = try makeQueryDeclaration(identifier: "absent-note")
        XCTAssertThrowsError(try IntentLabQueryObserver.observe(
            bundleIdentifier: "com.coryparry.IntentLabFixture.integration-tests", declaration: declaration, deadlineSeconds: 10
        )) { XCTAssertTrue($0 is IntentLabQueryObservationError) }
    }

    private func makeQueryDeclaration(identifier: String) throws -> IntentLabIntegrationDeclaration {
        let bundle = Bundle(for: IntentLabQueryObserverTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "IntentLabIntegration", withExtension: "json"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["queryOperations"] = [[
            "id": "notes-by-stable-id", "source": "entityQuery", "typeIdentifier": "NoteEntity",
            "identifiers": [identifier]
        ]]
        json["observers"] = [[
            "id": "queriedNoteTitle", "source": "entityQuery", "operationID": "notes-by-stable-id",
            "selector": "\(identifier).title", "type": ["primitive": ["_0": "string"]]
        ]]
        let declaration = try JSONDecoder.intentLab.decode(
            IntentLabIntegrationDeclaration.self, from: JSONSerialization.data(withJSONObject: json)
        )
        try declaration.validate()
        return declaration
    }

    func testSummaryDeclarationProjectsReturnedStringAndObservesAppOutput() throws {
        let bundle = Bundle(for: IntentLabQueryObserverTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "IntentLabIntegration", withExtension: "json"))
        let declaration = try JSONDecoder.intentLab.decode(
            IntentLabIntegrationDeclaration.self, from: Data(contentsOf: url)
        )
        try declaration.validate()
        let action = try XCTUnwrap(declaration.actions.first { $0.id == "SummarizeNoteIntent" })
        XCTAssertEqual(action.parameters.map(\.name), ["note"])
        XCTAssertEqual(action.parameters.first?.type, .entity(typeIdentifier: "NoteEntity"))
        XCTAssertEqual(declaration.resultProjections.first { $0.id == "generatedSummary" }?.path.first?.name, "value")
        XCTAssertEqual(declaration.observers.first { $0.id == "visibleSummary" }?.selector, "intent-lab-visible-summary")
        XCTAssertNotEqual(declaration.observers.first { $0.id == "applicationEvent" }?.selector,
                          declaration.observers.first { $0.id == "visibleSummary" }?.selector)
    }

    func testSummaryCompletionRejectsActionLabelAndStaleOrWrongSource() {
        let integration = NotesIntentLabIntegration()
        let context = "siri-current-attempt"
        let base: [String: IntentLabValue] = [
            "invocationContext": .string(context),
            "selectedNoteID": .string("packing-001"),
            "applicationEvent": .string("SummarizeNoteIntent:packing-001"),
            "summarySourceNoteID": .string("packing-001"),
            "summarySourceContentDigest": .string(String(repeating: "a", count: 64)),
            "summaryContext": .string(context),
            "summaryCompletionID": .string(UUID().uuidString),
            "visibleSummary": .string("The note lists a passport, blue charger, and rain jacket.")
        ]
        XCTAssertTrue(integration.completed(observations: base, context: context))
        for key in ["visibleSummary", "summarySourceContentDigest", "summaryCompletionID"] {
            var missing = base
            missing.removeValue(forKey: key)
            XCTAssertFalse(integration.completed(observations: missing, context: context), "Missing \(key) must fail")
        }
        var stale = base
        stale["summaryContext"] = .string("siri-previous-attempt")
        XCTAssertFalse(integration.completed(observations: stale, context: context))
        var wrongSource = base
        wrongSource["summarySourceNoteID"] = .string("packing-002")
        XCTAssertFalse(integration.completed(observations: wrongSource, context: context))
        var wrongEvent = base
        wrongEvent["applicationEvent"] = .string("SummarizeNoteIntent:packing-002")
        XCTAssertFalse(integration.completed(observations: wrongEvent, context: context))
        var labelOnly = base
        labelOnly["visibleSummary"] = .string(" ")
        XCTAssertFalse(integration.completed(observations: labelOnly, context: context))
    }

    func testPreparedAppHasNoFabricatedSummary() throws {
        let integration = NotesIntentLabIntegration()
        let application = try integration.prepare(
            bundleIdentifier: "com.coryparry.IntentLabFixture.integration-tests", context: "no-summary", operationID: "reset"
        )
        defer { application.terminate() }
        let observations = try integration.observe(application: application)
        XCTAssertNil(observations["visibleSummary"])
        XCTAssertNil(observations["visibleResponse"])
        XCTAssertEqual(observations["noteStoreMutationCount"], .integer(0))
    }

    func testPreparedRunnerAdvertisesCombinedSubjectFeature() throws {
        let application = try NotesIntentLabIntegration().prepare(
            bundleIdentifier: "com.coryparry.IntentLabFixture.integration-tests", context: "feature-discovery", operationID: "reset"
        )
        defer { application.terminate() }
        application.tabBars.buttons["Runner"].tap()
        let feature = application.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "intent-lab.summarize-note-subject · v1"))
            .firstMatch
        XCTAssertTrue(feature.waitForExistence(timeout: 10), "The combined subject feature must be discoverable")
    }
}
