import XCTest
@testable import IntentsAutomationCore

final class AutomationCodecTests: XCTestCase {
    func testDateInputAndResultSupportDoesNotInventDeclaredDateDefaults() throws {
        let catalog = try captured { root in
            var actions = try XCTUnwrap(root["actions"] as? [String: [String: Any]])
            actions["MetadataCodecParametersIntent"]?["outputType"] = ["primitive": ["wrapper": ["typeIdentifier": 8]]]
            root["actions"] = actions
        }
        let action = try XCTUnwrap(catalog.systemActions.first { $0.id == "MetadataCodecParametersIntent" })
        let date = try XCTUnwrap(action.parameters.first { $0.name == "date" })
        XCTAssertEqual(date.family, "date"); XCTAssertNil(date.defaultValue)
        XCTAssertEqual(action.resultFamily, "date")
        XCTAssertFalse(catalog.gaps.contains { $0.contains("Result projection is unsupported for " + action.id) })
        XCTAssertNoThrow(try AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: action.id, resultCodec: "date")]).validate(route: .systemIntent, phase: .subject))
    }
    private func captured(_ mutate: (inout [String: Any]) throws -> Void = { _ in }) throws -> ApplicationSurfaceCatalog {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Verification/Automation/Fixtures/CodecMetadata/extract.actionsdata")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        try mutate(&document)
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString + ".app")
        let metadata = root.appendingPathComponent("Metadata.appintents")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: document).write(to: metadata.appendingPathComponent("extract.actionsdata"))
        let app = AppIdentity(logicalID: "captured", bundleID: "example.captured", platform: "ios", productDigest: try AutomationProductDigest.compute(bundle: root))
        return try AutomationSurfaceCatalogReader.read(app: app, product: root)
    }
    func testActualSDKMetadataRetainsTypedDefaultsOptionalArrayAndClosedEnum() throws {
        let catalog = try captured(), action = try XCTUnwrap(catalog.systemActions.first(where: { $0.id == "MetadataCodecParametersIntent" }))
        let parameters = Dictionary(uniqueKeysWithValues: action.parameters.map { ($0.name, $0) })
        XCTAssertEqual(parameters["text"]?.defaultValue, .text("Fixture"))
        XCTAssertEqual(parameters["flag"]?.defaultValue, .bool(false))
        XCTAssertEqual(parameters["count"]?.defaultValue, .integer("42"))
        XCTAssertEqual(parameters["amount"]?.defaultValue, .decimal("1.25"))
        XCTAssertEqual(parameters["mode"]?.defaultValue, .enumeration(typeID: "MetadataFixtureMode", value: "careful"))
        XCTAssertEqual(parameters["optionalText"]?.optional, true); XCTAssertNil(parameters["optionalText"]?.defaultValue)
        XCTAssertEqual(parameters["names"]?.family, "textArray"); XCTAssertEqual(parameters["date"]?.family, "date")
        XCTAssertTrue(action.parametersComplete); XCTAssertEqual(action.resultFamily, "text")
        XCTAssertEqual(catalog.enumerations?.first?.cases.map(\.id), ["fast", "careful"])
        let primitive = try XCTUnwrap(catalog.systemActions.first(where: { $0.id == "MetadataPrimitiveInputsIntent" }))
        XCTAssertTrue(primitive.parametersComplete); XCTAssertEqual(primitive.resultFamily, "noValue")
        XCTAssertEqual(AutomationTemplatePlanner.proposals(catalog: catalog).first(where: { $0.id == primitive.id })?.missingInputs, [])
        XCTAssertFalse(catalog.systemDiscoveryComplete); XCTAssertFalse(primitive.registered)
    }
    func testCodecInputsPreserveIntegerPrecisionAndRejectWrongTypesBoundsAndEnumCases() throws {
        let catalog = try captured(), action = try XCTUnwrap(catalog.systemActions.first(where: { $0.id == "MetadataCodecParametersIntent" }))
        func input(_ name: String, _ text: String) throws -> AutomationActionInput {
            try AutomationCodecRegistry.input(text, parameter: XCTUnwrap(action.parameters.first(where: { $0.name == name })), catalog: catalog)
        }
        XCTAssertEqual(try input("count", "9007199254740993").value, .integer("9007199254740993"))
        XCTAssertEqual(try input("count", "-9223372036854775808").value, .integer("-9223372036854775808"))
        XCTAssertEqual(try input("flag", "false").value, .bool(false))
        XCTAssertEqual(try input("names", "[\"a\",\"b\"]").value, .array([.text("a"), .text("b")]))
        let date = AutomationDateInput(value: "2026-10-06T12:30:00.125Z", timeZone: "Europe/London")
        XCTAssertEqual(try input("date", date.encoded()).value, date.taggedValue)
        for raw in [#"{"value":"2026-10-06T12:30:00Z"}"#, #"{"value":"2026-10-06T12:30:00Z","timeZone":"Unknown/Zone"}"#, #"{"value":"2026-10-06","timeZone":"UTC"}"#, #"{"value":"2026-10-06T12:30:00Z","timeZone":"UTC","other":"x"}"#] { XCTAssertThrowsError(try input("date", raw)) }
        for (name, raw) in [("count", "9223372036854775808"), ("count", "01"), ("count", "1.0"), ("flag", "1"), ("amount", "1e3"), ("amount", "NaN"), ("mode", "invented"), ("names", "[1]"), ("date", "2026-10-06")] {
            XCTAssertThrowsError(try input(name, raw), name + ":" + raw)
        }
        let parameter = try XCTUnwrap(action.parameters.first(where: { $0.name == "mode" }))
        XCTAssertThrowsError(try AutomationCodecRegistry.validate(.enumeration(typeID: "Other", value: "careful"), parameter: parameter, catalog: catalog))
    }
    func testUnknownAndAmbiguousMetadataNeverUsesResolvableTypesOrInventedDefaults() throws {
        let catalog = try captured { root in
            var actions = try XCTUnwrap(root["actions"] as? [String: [String: Any]])
            var parameters = try XCTUnwrap(actions["MetadataPrimitiveInputsIntent"]?["parameters"] as? [[String: Any]])
            parameters[0]["valueType"] = ["primitive": ["wrapper": ["typeIdentifier": true]]]
            parameters[1]["typeSpecificMetadata"] = ["LNValueTypeSpecificMetadataKeyDefaultValue", ["int": ["wrapper": 2]]]
            actions["MetadataPrimitiveInputsIntent"]?["parameters"] = parameters
            root["actions"] = actions
            var enums = try XCTUnwrap(root["enums"] as? [[String: Any]])
            enums.append(enums[0]); root["enums"] = enums
        }
        let primitive = try XCTUnwrap(catalog.systemActions.first(where: { $0.id == "MetadataPrimitiveInputsIntent" }))
        XCTAssertNil(primitive.parameters[0].family); XCTAssertNil(primitive.parameters[1].defaultValue)
        XCTAssertFalse(primitive.parametersComplete); XCTAssertEqual(catalog.enumerations, [])
        let action = try XCTUnwrap(catalog.systemActions.first(where: { $0.id == "MetadataCodecParametersIntent" }))
        XCTAssertNil(action.parameters.first(where: { $0.name == "mode" })?.family)
    }
    func testDefaultPlannerProducesTypedHostInputsAndDoesNotInventBusinessPass() throws {
        let catalog = try captured(), action = try XCTUnwrap(catalog.systemActions.first(where: { $0.id == "MetadataPrimitiveInputsIntent" }))
        let target = TargetIdentity(id: "sim", kind: .simulator)
        let approval = RunApproval(runID: "run", app: catalog.app, target: target, environmentID: "env", effects: [.navigate], maximumActions: 20, disposable: false)
        var capabilities = CapabilityProfile()
        capabilities.records["apple.intent.invoke"] = .init(state: .available, reason: "test", probeVersion: "test", evidence: ["test"])
        for family in ["text", "integer", "decimal", "bool"] {
            capabilities.records["apple.codec." + family] = .init(state: .available, reason: "Synthetic conversion contract", probeVersion: "test", evidence: [])
        }
        let effects = AutomationActionEffectDeclaration(app: catalog.app, actionID: action.id, effects: [.navigate], developerConfirmation: "Approved navigation")
        let plan = try AutomationTemplatePlanner.compile(catalog: catalog, actionID: action.id, inputs: [:], declaredEffects: effects, approval: approval, capabilities: capabilities)
        XCTAssertEqual(plan.execution.inputs["count"], .integer("42")); XCTAssertEqual(plan.execution.inputs["flag"], .bool(false))
        XCTAssertEqual(plan.execution.inputs["optionalText"], .omission)
        XCTAssertTrue(plan.provenance["input.count"]?.hasPrefix("declaredDefault:") == true)
        XCTAssertTrue(plan.requirements.isEmpty)
        let forged = AutomationActionInput(value: .integer("99"), origin: .declaredDefault, evidence: "invented")
        XCTAssertThrowsError(try AutomationTemplatePlanner.compile(catalog: catalog, actionID: action.id, inputs: ["count": forged], declaredEffects: effects, approval: approval, capabilities: capabilities))
    }
    func testHostPayloadKeepsTextArrayElementsTypedAndRejectsNestedMixedValues() throws {
        let input = try AutomationHostProgram.hostInput(.array([.text("alpha"), .text("beta")]))
        guard case .object(let fields) = input, case .array(let items) = fields["items"] else { return XCTFail("Missing typed array bridge") }
        XCTAssertEqual(fields["kind"], .string("array"))
        XCTAssertEqual(items, [.object(["kind": .string("text"), "value": .string("alpha")]), .object(["kind": .string("text"), "value": .string("beta")])])
        XCTAssertThrowsError(try AutomationHostProgram.hostInput(.array([.integer("1")])))
        XCTAssertThrowsError(try AutomationHostProgram.hostInput(.array([.array([])])))
    }
    func testOldCatalogJSONOmitsNewFieldsAndStillDecodes() throws {
        let app = AppIdentity(logicalID: "old", bundleID: "example.old", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [.init(id: "Old", typeName: "Subject.Old", title: "Old", parameters: [.init(name: "text", family: "text", optional: true)], parametersComplete: true, compiled: true, registered: false, executed: false)], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        let encoded = try JSONEncoder().encode(catalog)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("defaultValue"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("enumerations"))
        XCTAssertEqual(try JSONDecoder().decode(ApplicationSurfaceCatalog.self, from: encoded), catalog)
    }
}
