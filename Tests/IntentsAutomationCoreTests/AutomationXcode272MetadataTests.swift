import XCTest
@testable import IntentsAutomationCore

final class AutomationXcode272MetadataTests: XCTestCase {
    func testCapturedMetadataPreservesFamiliesDefaultsAndEvidenceBoundaries() throws {
        let catalog = try captured()
        XCTAssertEqual(catalog.systemActions.count, 4)
        XCTAssertFalse(catalog.systemDiscoveryComplete)
        XCTAssertFalse(catalog.uiDiscoveryComplete)
        XCTAssertTrue(catalog.systemActions.allSatisfy { $0.compiled && !$0.registered && !$0.executed })
        let ordinary = try XCTUnwrap(catalog.systemActions.first { $0.id == "MetadataCodecParametersIntent" })
        XCTAssertTrue(ordinary.parametersComplete)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: ordinary.parameters.map { ($0.name, $0.family) }), [
            "text": "text", "flag": "bool", "count": "integer", "amount": "decimal",
            "optionalText": "text", "names": "textArray", "date": "date", "mode": "enum"
        ])
        XCTAssertEqual(ordinary.parameters.first { $0.name == "text" }?.defaultValue, .text("Fixture"))
        XCTAssertEqual(ordinary.parameters.first { $0.name == "flag" }?.defaultValue, .bool(false))
        XCTAssertEqual(ordinary.parameters.first { $0.name == "count" }?.defaultValue, .integer("42"))
        XCTAssertEqual(ordinary.parameters.first { $0.name == "amount" }?.defaultValue, .decimal("1.25"))
        XCTAssertEqual(ordinary.parameters.first { $0.name == "mode" }?.defaultValue,
                       .enumeration(typeID: "MetadataFixtureMode", value: "careful"))
        XCTAssertEqual(ordinary.parameters.first { $0.name == "optionalText" }?.optional, true)
        XCTAssertEqual(ordinary.resultFamily, "text")
        let extended = try XCTUnwrap(catalog.systemActions.first { $0.id == "MetadataExtendedInputsIntent" })
        XCTAssertTrue(extended.parametersComplete)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: extended.parameters.map { ($0.name, $0.family) }), [
            "duration": "duration", "calendar": "calendarComponents", "url": "url", "file": "intentFile",
            "entity": "entity", "flags": "boolArray", "counts": "integerArray",
            "amounts": "decimalArray", "dates": "dateArray"
        ])
        XCTAssertEqual(extended.resultFamily, "noValue")
        XCTAssertEqual(catalog.entities?.map(\.typeID), ["MetadataFixtureEntity"])
        XCTAssertEqual(catalog.enumerations?.first?.cases.map(\.id).sorted(), ["careful", "fast"])
        let probe = try XCTUnwrap(catalog.systemActions.first { $0.id == "HostProbeIntent" })
        XCTAssertTrue(probe.parametersComplete)
        XCTAssertEqual(probe.parameters, [.init(name: "sample", family: "text", optional: false)])
    }

    func testUnknownGeneratorSchemaAndMalformedEnvelopeRemainIncomplete() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["version"] = 2 },
            { $0["generator"] = ["name": "xcode-tools", "version": "27B5028g"] },
            { $0["generator"] = ["name": "foreign", "version": "27B5028f"] },
            { $0["generator"] = ["name": "xcode-tools"] },
            { $0["actions"] = [] }
        ]
        for mutate in mutations {
            let catalog = try captured(mutate)
            XCTAssertTrue(catalog.systemActions.isEmpty)
            XCTAssertFalse(catalog.systemDiscoveryComplete)
            XCTAssertTrue(catalog.gaps.contains { $0.hasPrefix("Unknown built metadata format") })
        }
    }

    func testUnsupportedAndMalformedNewBuildInputsCannotBecomeParameterlessActions() throws {
        for malformed in [false, true] {
            let catalog = try captured { document in
                var actions = try XCTUnwrap(document["actions"] as? [String: [String: Any]])
                var action = try XCTUnwrap(actions["HostProbeIntent"])
                var parameters = try XCTUnwrap(action["parameters"] as? [[String: Any]])
                if malformed { parameters[0].removeValue(forKey: "isOptional") }
                else { parameters[0]["valueType"] = ["primitive": ["wrapper": ["typeIdentifier": 999]]] }
                action["parameters"] = parameters
                actions["HostProbeIntent"] = action
                document["actions"] = actions
            }
            let action = try XCTUnwrap(catalog.systemActions.first { $0.id == "HostProbeIntent" })
            XCTAssertFalse(action.parametersComplete)
            XCTAssertFalse(action.registered)
            XCTAssertFalse(action.executed)
            if !malformed {
                XCTAssertEqual(action.parameters.count, 1)
                XCTAssertNil(action.parameters[0].family)
            }
        }
    }

    func testIdentifierOnlyQueryRemainsUnsupported() throws {
        let catalog = try captured { document in
            var queries = try XCTUnwrap(document["queries"] as? [String: [String: Any]])
            // Also captured from the SDK: EntityQuery lacks the string-query capability.
            queries["MetadataFixtureQuery"]?["capabilities"] = 66
            document["queries"] = queries
        }
        XCTAssertEqual(catalog.entities, [])
        let action = try XCTUnwrap(catalog.systemActions.first { $0.id == "MetadataExtendedInputsIntent" })
        XCTAssertFalse(action.parametersComplete)
        XCTAssertNil(action.parameters.first { $0.name == "entity" }?.family)
    }

    private func captured(_ mutate: (inout [String: Any]) throws -> Void = { _ in }) throws -> ApplicationSurfaceCatalog {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Verification/Automation/Fixtures/Xcode272Metadata/extract.actionsdata")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        try mutate(&document)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        let metadata = root.appendingPathComponent("Contents/Resources/Metadata.appintents")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: document).write(to: metadata.appendingPathComponent("extract.actionsdata"))
        let app = AppIdentity(logicalID: "captured", bundleID: "com.intents.fixture.mac-host", platform: "macos",
                              productDigest: try AutomationProductDigest.compute(bundle: root))
        return try AutomationSurfaceCatalogReader.read(app: app, product: root)
    }
}
