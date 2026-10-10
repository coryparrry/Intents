import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationEntityIntegerTests: XCTestCase {
    private func catalog(descriptor: Any = 2, optional: Bool = false) throws -> ApplicationSurfaceCatalog {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Verification/Automation/Fixtures/DuplicateTasks/Metadata/extract.actionsdata")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var entities = try XCTUnwrap(document["entities"] as? [String: [String: Any]])
        var properties = try XCTUnwrap(entities["TaskEntity"]?["properties"] as? [[String: Any]])
        properties.append(["identifier": "sequence", "isOptional": optional,
                           "valueType": ["primitive": ["wrapper": ["typeIdentifier": descriptor]]]])
        entities["TaskEntity"]?["properties"] = properties; document["entities"] = entities
        let root = URL(fileURLWithPath: "/private/tmp/entity-integer-" + UUID().uuidString + ".app")
        let metadata = root.appendingPathComponent("Metadata.appintents")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: document).write(to: metadata.appendingPathComponent("extract.actionsdata"))
        let app = AppIdentity(logicalID: "integer-fixture", bundleID: "example.Subject", platform: "ios",
                              productDigest: try AutomationProductDigest.compute(bundle: root))
        return try AutomationSurfaceCatalogReader.read(app: app, product: root)
    }
    func testIntegerPropertyMetadataKeepsDiscoveryPartialAndRejectsUnqualifiedDescriptors() throws {
        let valid = try catalog()
        XCTAssertEqual(try XCTUnwrap(valid.entities?.first).properties["sequence"], "integer")
        XCTAssertTrue(try XCTUnwrap(valid.systemActions.first).parametersComplete)
        XCTAssertFalse(valid.systemDiscoveryComplete)
        for descriptor: Any in [true, "2", 2.5, -2, 7, 100] {
            let rejected = try catalog(descriptor: descriptor)
            XCTAssertTrue(rejected.entities?.isEmpty == true)
            XCTAssertFalse(try XCTUnwrap(rejected.systemActions.first).parametersComplete)
        }
        XCTAssertTrue(try catalog(optional: true).entities?.isEmpty == true)
    }
    func testCatalogIntegerPropertiesFreezeImportAndBindWithoutPrecisionLoss() throws {
        let catalog = try catalog(), entity = try XCTUnwrap(catalog.entities?.first)
        let query = AutomationHostProgram.Operation(id: "records", kind: .query, typeID: entity.typeID,
                                                   queryText: "Invoice", properties: entity.properties)
        var lookup = AutomationSegment(id: "lookup", kind: .systemQuery, phase: .setup, operation: "Query records", lifecycle: .persistedStateAcrossSegments)
        lookup.hostProgram = .init(operations: [query])
        var subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Select record", lifecycle: .persistedStateAcrossSegments)
        subject.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: "CompleteTaskIntent", resultCodec: "noValue")])
        let target = TargetIdentity(id: "owned", kind: .simulator)
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "lookup", leaseGeneration: 1)
        for exact in ["9007199254740993", "-9223372036854775808", "9223372036854775807"] {
            subject.inputBindings = [.init(producerSegmentID: "lookup", outputID: "records", destination: .hostParameter,
                operationID: "invoke", name: "task", uniqueEntity: .init(typeID: entity.typeID, matchingProperties: ["sequence": .integer(exact)]))]
            let plan = AutomationCase(id: "integer-binding", app: catalog.app, target: target, environmentID: "isolated", execution: subject, setup: [lookup])
            try AutomationInputResolver.validate(plan: plan)
            let frozen = try AutomationFrozenCase(plan: plan)
            let restored = try JSONDecoder().decode(AutomationFrozenCase.self, from: JSONEncoder().encode(frozen))
            try restored.validate(); XCTAssertEqual(restored.plan, plan)
            let output = try imported(exact: exact, query: query, scope: scope, app: catalog.app)
            let receipt = AutomationSegmentReceipt(scope: scope, app: plan.app, target: target, segmentID: "lookup",
                route: .systemQuery, dispatched: true, completed: true, verifiedOutputs: ["records": output], environmentID: "isolated")
            let bound = try AutomationInputResolver.resolve(segment: restored.plan.execution, receipts: [receipt], plan: restored.plan, runID: "run", attemptID: "attempt")
            XCTAssertEqual(bound.hostProgram?.operations[0].parameters["task"], .entity(typeID: entity.typeID, value: "actual-id"))
            if case .array(let records) = output, case .object(let record) = records[0], case .object(let properties) = record["properties"] {
                XCTAssertEqual(properties["sequence"], .integer(exact))
            } else { XCTFail("Imported query lost its typed properties") }
        }
        for invalid in ["9223372036854775808", "-9223372036854775809", "01", "1.0", "1e2"] {
            XCTAssertThrowsError(try imported(exact: invalid, query: query, scope: scope, app: catalog.app))
            XCTAssertThrowsError(try AutomationEntitySelection(typeID: entity.typeID, matchingProperties: ["sequence": .integer(invalid)]).validate(query: query))
        }
        for kind in ["text", "bool", "decimal"] {
            XCTAssertThrowsError(try imported(exact: "1", kind: kind, query: query, scope: scope, app: catalog.app))
        }
    }
    private func imported(exact: String, kind: String = "integer", query: AutomationHostProgram.Operation,
                          scope: AutomationScope, app: AppIdentity) throws -> AutomationValue {
        var properties: [String: Any] = (query.properties ?? [:]).mapValues { codec -> [String: Any] in
            codec == "bool" ? ["kind": "bool", "boolValue": false] : ["kind": "text", "value": "Invoice"]
        }
        properties["sequence"] = kind == "bool" ? ["kind": kind, "boolValue": true] : ["kind": kind, "value": exact]
        let value: [String: Any] = ["kind": "array", "items": [["kind": "entity", "typeId": query.typeID, "value": "actual-id", "properties": properties]]]
        let receipt: [String: Any] = ["schemaVersion": 2, "runner": ["pid": 123, "startIdentity": "123456:100", "executablePath": "/owned/Host.app/Host"],
            "runID": scope.runId, "attemptID": scope.attemptId, "segmentID": scope.segmentId, "leaseGeneration": scope.leaseGeneration,
            "bundleID": app.bundleID, "productDigest": app.productDigest!, "complete": true,
            "operations": [["operationID": query.id, "dispatched": true, "value": value]]]
        let imported = try AutomationHostReceiptImporter.importReceipt(JSONSerialization.data(withJSONObject: receipt), scope: scope,
            app: app, program: .init(operations: [query]))
        return try XCTUnwrap(imported.values[query.id])
    }
}
