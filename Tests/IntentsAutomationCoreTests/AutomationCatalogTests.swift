import XCTest
@testable import IntentsAutomationCore

final class AutomationCatalogTests: XCTestCase {
    func testUnsupportedParametersCannotBecomeParameterlessActions() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString + ".app")
        let metadata = root.appendingPathComponent("Metadata.appintents")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var document: [String: Any] = ["version": 1, "generator": ["name": "xcode-tools", "version": "27A266a"], "actions": [
            "Action": ["identifier": "Action", "fullyQualifiedTypeName": "Subject.Action", "parameters": [["name": "missingType"],
                ["name": "query", "isOptional": false, "valueType": ["primitive": ["wrapper": ["typeIdentifier": 0]]]]]]]]
        func read() throws -> ApplicationSurfaceCatalog {
            try JSONSerialization.data(withJSONObject: document).write(to: metadata.appendingPathComponent("extract.actionsdata"))
            let app = AppIdentity(logicalID: "subject", bundleID: "example.subject", platform: "ios", productDigest: try AutomationProductDigest.compute(bundle: root))
            return try AutomationSurfaceCatalogReader.read(app: app, product: root)
        }
        let catalog = try read()
        XCTAssertEqual(catalog.systemActions.count, 1)
        XCTAssertFalse(catalog.systemActions[0].parametersComplete)
        XCTAssertEqual(catalog.systemActions[0].parameters[0].family, "text")
        XCTAssertFalse(catalog.systemActions[0].registered); XCTAssertFalse(catalog.systemDiscoveryComplete)
        document["generator"] = ["name": "xcode-tools", "version": "unqualified"]
        let unknown = try read(); XCTAssertTrue(unknown.systemActions.isEmpty); XCTAssertFalse(unknown.systemDiscoveryComplete)
        XCTAssertFalse(unknown.gaps.isEmpty)
    }
    func testCapturedEntityInputAndDeclaredPropertyCodecsRequireConsistentQueryMetadata() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Verification/Automation/Fixtures/DuplicateTasks/Metadata/extract.actionsdata")
        let captured = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString + ".app")
        let metadata = root.appendingPathComponent("Metadata.appintents")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func read(_ document: [String: Any]) throws -> ApplicationSurfaceCatalog {
            try JSONSerialization.data(withJSONObject: document).write(to: metadata.appendingPathComponent("extract.actionsdata"))
            let app = AppIdentity(logicalID: "captured", bundleID: "example.captured", platform: "ios", productDigest: try AutomationProductDigest.compute(bundle: root))
            return try AutomationSurfaceCatalogReader.read(app: app, product: root)
        }
        let valid = try read(captured), action = try XCTUnwrap(valid.systemActions.first), entity = try XCTUnwrap(valid.entities?.first)
        XCTAssertTrue(action.parametersComplete); XCTAssertEqual(action.parameters[0].family, "entity")
        XCTAssertEqual(action.parameters[0].typeID, "TaskEntity"); XCTAssertEqual(entity.properties["completed"], "bool")
        XCTAssertEqual(entity.queryIdentifier, "DuplicateTasks.TaskQuery"); XCTAssertFalse(valid.systemDiscoveryComplete)
        for kind in 0..<5 {
            var bad = captured
            var entities = try XCTUnwrap(bad["entities"] as? [String: [String: Any]])
            var queries = try XCTUnwrap(bad["queries"] as? [String: [String: Any]])
            if kind == 0 { entities["TaskEntity"]?["defaultQueryIdentifier"] = "foreign.Query" }
            else if kind == 1 { queries["TaskQuery"]?["entityType"] = "OtherEntity" }
            else if kind == 2 { entities["TaskEntity"]?["transient"] = true }
            else if kind == 3 { queries["DuplicateQuery"] = queries["TaskQuery"] }
            else {
                var properties = try XCTUnwrap(entities["TaskEntity"]?["properties"] as? [[String: Any]])
                properties[2]["valueType"] = ["primitive": ["wrapper": ["typeIdentifier": true]]]
                entities["TaskEntity"]?["properties"] = properties
            }
            bad["entities"] = entities; bad["queries"] = queries
            let rejected = try read(bad)
            XCTAssertFalse(try XCTUnwrap(rejected.systemActions.first).parametersComplete); XCTAssertTrue(rejected.entities?.isEmpty == true)
        }
    }
    func testCapturedURLDescriptorMapsToExplicitReferenceWithoutTextSubstitution() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString + ".app")
        let metadata = root.appendingPathComponent("Metadata.appintents")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor: [String: Any] = ["primitive": ["wrapper": ["typeIdentifier": 11]]]
        for optional in [false, true] {
            let document: [String: Any] = ["version": 1, "generator": ["name": "xcode-tools", "version": "27A266a"], "actions": [
                "URLInputProbeIntent": ["identifier": "URLInputProbeIntent", "fullyQualifiedTypeName": "Subject.URLInputProbeIntent",
                    "parameters": [["name": "url", "isOptional": optional, "valueType": descriptor]]],
                "URLResultProbeIntent": ["identifier": "URLResultProbeIntent", "fullyQualifiedTypeName": "Subject.URLResultProbeIntent",
                    "parameters": [], "outputType": descriptor]]]
            try JSONSerialization.data(withJSONObject: document).write(to: metadata.appendingPathComponent("extract.actionsdata"))
            let app = AppIdentity(logicalID: "url-fixture", bundleID: "example.Subject", platform: "ios", productDigest: try AutomationProductDigest.compute(bundle: root))
            let catalog = try AutomationSurfaceCatalogReader.read(app: app, product: root)
            let input = try XCTUnwrap(catalog.systemActions.first { $0.id == "URLInputProbeIntent" })
            let parameter = try XCTUnwrap(input.parameters.first)
            XCTAssertTrue(input.parametersComplete); XCTAssertEqual(parameter.family, "url")
            XCTAssertEqual(try AutomationCodecRegistry.input("https://example.invalid/typed-url", parameter: parameter, catalog: catalog).value,
                           .object(["url": .text("https://example.invalid/typed-url")]))
            XCTAssertThrowsError(try AutomationCodecRegistry.validate(.text("https://example.invalid/typed-url"), parameter: parameter, catalog: catalog))
            let result = try XCTUnwrap(catalog.systemActions.first { $0.id == "URLResultProbeIntent" })
            XCTAssertTrue(result.parametersComplete); XCTAssertEqual(result.resultFamily, "url")
            XCTAssertFalse(catalog.systemDiscoveryComplete)
        }
    }
    func testUnsupportedInputDetailsAreBoundedWithoutMakingOmittedInputsUsable() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString + ".app")
        let metadata = root.appendingPathComponent("Metadata.appintents")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parameters = (0..<50).map { ["name": "input" + String($0), "isOptional": false,
            "valueType": ["primitive": ["wrapper": ["typeIdentifier": 999]]]] as [String: Any] }
        let actions = Dictionary(uniqueKeysWithValues: (0..<3).map { index -> (String, [String: Any]) in
            let id = "Unsupported" + String(index)
            return (id, ["identifier": id, "fullyQualifiedTypeName": "Subject." + id, "parameters": parameters])
        })
        try JSONSerialization.data(withJSONObject: ["version": 1, "generator": ["name": "xcode-tools", "version": "27A266a"], "actions": actions])
            .write(to: metadata.appendingPathComponent("extract.actionsdata"))
        let app = AppIdentity(logicalID: "bounded", bundleID: "example.Subject", platform: "ios", productDigest: try AutomationProductDigest.compute(bundle: root))
        let catalog = try AutomationSurfaceCatalogReader.read(app: app, product: root)
        XCTAssertEqual(catalog.gaps.filter { $0.hasPrefix("Input ") }.count, 50)
        XCTAssertTrue(catalog.gaps.contains("Additional unsupported inputs: 100."))
        XCTAssertEqual(catalog.systemActions.count, 3)
        XCTAssertTrue(catalog.systemActions.allSatisfy { !$0.parametersComplete && $0.parameters.count == 50 && $0.parameters.allSatisfy { $0.family == nil } })
        XCTAssertFalse(catalog.systemDiscoveryComplete)
    }
    func testMissingMetadataIsPartialDiscovery() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppIdentity(logicalID: "subject", bundleID: "example.subject", platform: "ios", productDigest: try AutomationProductDigest.compute(bundle: root))
        let catalog = try AutomationSurfaceCatalogReader.read(app: app, product: root)
        XCTAssertTrue(catalog.systemActions.isEmpty); XCTAssertFalse(catalog.systemDiscoveryComplete); XCTAssertFalse(catalog.uiDiscoveryComplete)
    }
}
