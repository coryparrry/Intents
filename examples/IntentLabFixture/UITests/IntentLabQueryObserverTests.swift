import IntentLabContracts
@testable import IntentLabTesting
import Foundation
import XCTest

@available(macOS 27.0, iOS 27.0, *)
@MainActor
final class IntentLabQueryObserverTests: XCTestCase {
    func testQueryWaitCompletesOnMainActor() throws {
        let observed = try IntentLabQueryObserver.runBounded(deadlineSeconds: 2) {
            ["status": .boolean(true)]
        }
        XCTAssertEqual(observed["status"], .boolean(true))
    }

    func testGenericEntityQueryReadsFixtureNote() throws {
        let application = try NotesIntentLabIntegration().prepare(
            bundleIdentifier: "com.coryparry.IntentLabFixture", context: "query-positive", operationID: "reset"
        )
        defer { application.terminate() }
        let declaration = try makeQueryDeclaration(identifier: "packing-001")
        let observations = try IntentLabQueryObserver.observe(
            bundleIdentifier: "com.coryparry.IntentLabFixture", declaration: declaration, deadlineSeconds: 10
        )
        XCTAssertEqual(observations["queriedNoteTitle"], .string("Packing note"))
    }

    func testGenericEntityQueryRejectsMissingFixtureNote() throws {
        let application = try NotesIntentLabIntegration().prepare(
            bundleIdentifier: "com.coryparry.IntentLabFixture", context: "query-negative", operationID: "reset"
        )
        defer { application.terminate() }
        let declaration = try makeQueryDeclaration(identifier: "absent-note")
        XCTAssertThrowsError(try IntentLabQueryObserver.observe(
            bundleIdentifier: "com.coryparry.IntentLabFixture", declaration: declaration, deadlineSeconds: 10
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
