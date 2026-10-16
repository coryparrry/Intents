import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationIdentifierEntityTests: XCTestCase {
    private func metadata() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Verification/Automation/Fixtures/IdentifierOnlyEntityMetadata/extract.actionsdata"))) as? [String: Any])
    }
    func testCapturedIdentifierQueryDoesNotInventPropertiesOrStringMatching() throws {
        let entities = AutomationEntityMetadata.read(try metadata())
        let entity = try XCTUnwrap(entities.only)
        XCTAssertEqual(entity.typeID, "TaskEntitySpec")
        XCTAssertEqual(entity.queryIdentifier, "Runner.TaskEntitySpecQuery")
        XCTAssertTrue(entity.properties.isEmpty)
        XCTAssertTrue(entity.propertyTitles.isEmpty)
        XCTAssertTrue(entity.usesSuggestedQuery)
        #if os(macOS)
        XCTAssertTrue(AutomationEntityQuery.acceptsQuery(entity: entity, text: ""))
        XCTAssertFalse(AutomationEntityQuery.acceptsQuery(entity: entity, text: "invented string search"))
        #endif
    }
    func testCapturedEntityInputIsCompleteWithoutClaimingRuntimeRegistration() throws {
        let product = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString + ".app")
        let directory = product.appendingPathComponent("Metadata.appintents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: product) }
        try JSONSerialization.data(withJSONObject: metadata()).write(to: directory.appendingPathComponent("extract.actionsdata"))
        let app = AppIdentity(logicalID: "captured", bundleID: "com.example.app", platform: "ios", productDigest: try AutomationProductDigest.compute(bundle: product))
        let catalog = try AutomationSurfaceCatalogReader.read(app: app, product: product)
        let action = try XCTUnwrap(catalog.systemActions.first { $0.id == "CompleteTaskIntentSpec" })
        XCTAssertTrue(action.parametersComplete)
        XCTAssertEqual(action.parameters.first?.family, "entity")
        XCTAssertEqual(action.parameters.first?.typeID, "TaskEntitySpec")
        XCTAssertFalse(action.registered)
        XCTAssertFalse(action.executed)
        XCTAssertFalse(catalog.systemDiscoveryComplete)
    }
    func testCapturedQueryRejectsForeignTypeUnknownCapabilitiesAndInventedProperties() throws {
        for mutation in 0..<5 {
            var root = try metadata()
            var queries = try XCTUnwrap(root["queries"] as? [String: [String: Any]])
            var entities = try XCTUnwrap(root["entities"] as? [String: [String: Any]])
            if mutation == 0 { queries["TaskEntitySpecQuery"]?["capabilities"] = 67 }
            if mutation == 1 { queries["TaskEntitySpecQuery"]?["entityType"] = "Foreign" }
            if mutation == 2 { queries["OtherQuery"] = queries["TaskEntitySpecQuery"] }
            if mutation == 3 { entities["TaskEntitySpec"]?["transient"] = true }
            if mutation == 4 { entities["TaskEntitySpec"]?["properties"] = [["identifier": "invented", "isOptional": false, "valueType": ["primitive": ["wrapper": ["typeIdentifier": 0]]]]] }
            root["queries"] = queries; root["entities"] = entities
            XCTAssertTrue(AutomationEntityMetadata.read(root).isEmpty)
        }
    }
    func testSuggestedSelectorIsExclusiveAndCannotBecomeAStorageRead() throws {
        let operation = AutomationHostProgram.Operation(id: "records", kind: .query, typeID: "TaskEntitySpec", querySuggested: true, properties: [:])
        let valid = AutomationHostProgram(operations: [operation])
        XCTAssertNoThrow(try valid.validate(route: .systemQuery, phase: .subject))
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let payload = try JSONDecoder().decode(AutomationJSON.self, from: valid.payload(
            scope: .init(runID: "run", attemptID: "attempt", segmentID: "query", leaseGeneration: 1), app: app, route: .systemQuery, phase: .subject))
        guard let encodedOperations = payload.object?["operations"], case .array(let operations) = encodedOperations else { return XCTFail("Missing operations") }
        XCTAssertEqual(operations.first?.object?["querySuggested"], .bool(true))
        XCTAssertNil(operations.first?.object?["queryText"])
        XCTAssertThrowsError(try valid.validate(route: .storageRead, phase: .observe))
        for mutate in 0..<3 {
            var bad = operation
            if mutate == 0 { bad.queryText = "" }
            if mutate == 1 { bad.queryIDs = ["actual"] }
            if mutate == 2 { bad.querySuggested = false }
            XCTAssertThrowsError(try AutomationHostProgram(operations: [bad]).validate(route: .systemQuery, phase: .subject))
        }
    }
    func testIdentifierSelectionRechecksExactlyOneFreshReturnedIdentity() throws {
        let query = AutomationHostProgram.Operation(id: "records", kind: .query, typeID: "TaskEntitySpec", queryIDs: ["actual"], properties: [:])
        let selection = AutomationEntitySelection(typeID: query.typeID, matchingProperties: [:], expectedIdentifier: "actual", expiresAt: Date().addingTimeInterval(60))
        let record = AutomationValue.object(["entity": .entity(typeID: query.typeID, value: "actual"), "properties": .object([:])])
        XCTAssertEqual(try selection.resolve(.array([record]), query: query), .entity(typeID: query.typeID, value: "actual"))
        for values in [[], [record, record], [.object(["entity": .entity(typeID: query.typeID, value: "substitute"), "properties": .object([:])])]] {
            XCTAssertThrowsError(try selection.resolve(.array(values), query: query))
        }
        var expired = selection; expired.expiresAt = Date().addingTimeInterval(-1)
        XCTAssertThrowsError(try expired.resolve(.array([record]), query: query))
        var collision = query; collision.querySuggested = true
        XCTAssertThrowsError(try selection.validate(query: collision))
        var invented = selection; invented.matchingProperties["title"] = .text("not declared")
        XCTAssertThrowsError(try invented.validate(query: query))
        let propertyless = AutomationEntitySelection(typeID: query.typeID, matchingProperties: [:])
        XCTAssertThrowsError(try propertyless.validate(query: query))
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
