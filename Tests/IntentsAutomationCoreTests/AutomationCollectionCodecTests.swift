import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationCollectionCodecTests: XCTestCase {
    private func catalog(_ mutate: (inout [String: Any]) throws -> Void = { _ in }) throws -> ApplicationSurfaceCatalog {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Verification/Automation/Fixtures/CollectionMetadata/extract.actionsdata")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any]); try mutate(&document)
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString + ".app")
        let metadata = root.appendingPathComponent("Metadata.appintents")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: document).write(to: metadata.appendingPathComponent("extract.actionsdata"))
        let app = AppIdentity(logicalID: "captured", bundleID: "example.captured", platform: "ios", productDigest: try AutomationProductDigest.compute(bundle: root))
        return try AutomationSurfaceCatalogReader.read(app: app, product: root)
    }
    func testCapturedSDKCollectionsAndTemporalFamiliesRejectNestedArrays() throws {
        let captured = try catalog()
        let action = try XCTUnwrap(captured.systemActions.first { $0.id == "MetadataCollectionsAndTimeIntent" })
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: action.parameters.compactMap { p in p.family.map { (p.name, $0) } }),
                       ["flags": "boolArray", "counts": "integerArray", "amounts": "decimalArray", "dates": "dateArray", "duration": "duration", "calendar": "calendarComponents"])
        XCTAssertTrue(action.parametersComplete)
        for (name, family) in [("Bool", "boolArray"), ("Integer", "integerArray"), ("Decimal", "decimalArray"), ("Text", "textArray"), ("Date", "dateArray")] {
            XCTAssertEqual(captured.systemActions.first { $0.id == "Metadata" + name + "ArrayResultIntent" }?.resultFamily, family)
        }
        XCTAssertEqual(captured.systemActions.first { $0.id == "MetadataDateResultIntent" }?.resultFamily, "date")
        XCTAssertEqual(captured.systemActions.first { $0.id == "MetadataDurationResultIntent" }?.resultFamily, "duration")
        XCTAssertEqual(captured.systemActions.first { $0.id == "MetadataCalendarResultIntent" }?.resultFamily, "calendarComponents")
        let nested = try catalog { document in
            var actions = try XCTUnwrap(document["actions"] as? [String: [String: Any]])
            let array = try XCTUnwrap(actions["MetadataBoolArrayResultIntent"]?["outputType"])
            actions["MetadataBoolArrayResultIntent"]?["outputType"] = ["array": ["wrapper": ["capabilities": 3, "memberValueType": array]]]
            document["actions"] = actions
        }
        XCTAssertNil(nested.systemActions.first { $0.id == "MetadataBoolArrayResultIntent" }?.resultFamily)
    }
    func testTypedNativeInputParsingRetainsPrecisionAndRejectsMixedNestedAndInvalidCollections() throws {
        let captured = try catalog()
        func input(_ text: String, _ family: String) throws -> AutomationValue {
            try AutomationCodecRegistry.input(text, parameter: .init(name: "values", family: family, optional: false), catalog: captured).value
        }
        XCTAssertEqual(try input("[true,false]", "boolArray"), .array([.bool(true), .bool(false)]))
        XCTAssertEqual(try input("[9007199254740993,-9223372036854775808]", "integerArray"), .array([.integer("9007199254740993"), .integer("-9223372036854775808")]))
        XCTAssertEqual(try input("[\"0.000000001\",\"-0.0\"]", "decimalArray"), .array([.decimal("0.000000001"), .decimal("-0.0")]))
        let date = "[{\"value\":\"2026-10-25T00:30:00Z\",\"timeZone\":\"Europe/London\"}]"
        XCTAssertEqual(try input(date, "dateArray"), .array([.date("2026-10-25T00:30:00Z", timeZone: "Europe/London")]))
        for family in AutomationCodecRegistry.arrayFamilies { XCTAssertEqual(try input("[]", family), .array([])) }
        for (text, family) in [("[1]", "boolArray"), ("[true]", "integerArray"), ("[[1]]", "integerArray"), ("[9223372036854775808]", "integerArray"),
                               ("[1.25]", "decimalArray"), ("[\"1e3\"]", "decimalArray"), ("[\"NaN\"]", "decimalArray"),
                               ("[{\"value\":\"2026-02-30T00:00:00Z\",\"timeZone\":\"UTC\"}]", "dateArray"),
                               ("[{\"value\":\"2026-01-01T00:00:00Z\",\"timeZone\":\"UTC\",\"other\":\"x\"}]", "dateArray")] {
            XCTAssertThrowsError(try input(text, family))
        }
        XCTAssertThrowsError(try input("[" + Array(repeating: "true", count: 1001).joined(separator: ",") + "]", "boolArray"))
    }
    func testFrozenCollectionCodecRejectsUnboundAndConflictingTypes() throws {
        func validate(_ value: AutomationValue, codec: String?) throws {
            let operation = AutomationHostProgram.Operation(id: "invoke", kind: .invoke, typeID: "Intent", parameters: ["values": value], parameterCodecs: codec.map { ["values": $0] })
            try AutomationHostProgram(operations: [operation]).validate(route: .systemIntent, phase: .subject)
        }
        XCTAssertNoThrow(try validate(.array([.bool(true)]), codec: "boolArray"))
        XCTAssertThrowsError(try validate(.array([.bool(true)]), codec: nil))
        XCTAssertThrowsError(try validate(.array([.bool(true)]), codec: "integerArray"))
        XCTAssertThrowsError(try validate(.text("[]"), codec: "boolArray"))
        XCTAssertThrowsError(try validate(.array([]), codec: "nestedArray"))
        for family in AutomationCodecRegistry.arrayFamilies {
            XCTAssertNoThrow(try validate(.array([]), codec: family)); XCTAssertNoThrow(try validate(.omission, codec: family)); XCTAssertNoThrow(try validate(.null, codec: family))
        }
        let foreign = AutomationHostProgram.Operation(id: "invoke", kind: .invoke, typeID: "Intent", parameterCodecs: ["absent": "boolArray"])
        XCTAssertThrowsError(try AutomationHostProgram(operations: [foreign]).validate(route: .systemIntent, phase: .subject))
        let old = AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: "Intent", parameters: ["names": .array([.text("a")])])])
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(old), encoding: .utf8)); XCTAssertFalse(encoded.contains("parameterCodecs"))
    }
}

extension AutomationCollectionCodecTests {
    func testDurationInputRequiresExactDeclaredComponentsAndFrozenCodec() throws {
        let captured = try catalog(), parameter = ApplicationSurfaceCatalog.SystemAction.Parameter(name: "duration", family: "duration", optional: false)
        let parsed = try AutomationCodecRegistry.input(#"{"seconds":"9007199254740993","attoseconds":"123456789012345678"}"#, parameter: parameter, catalog: captured)
        XCTAssertEqual(parsed.value, .object(["seconds": .integer("9007199254740993"), "attoseconds": .integer("123456789012345678")]))
        let bound = AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: "Intent", parameters: ["duration": parsed.value], parameterCodecs: ["duration":"duration"])])
        XCTAssertNoThrow(try bound.validate(route: .systemIntent, phase: .subject))
        let unbound = AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: "Intent", parameters: ["duration": parsed.value])])
        XCTAssertThrowsError(try unbound.validate(route: .systemIntent, phase: .subject))
        for wire in [#"{"seconds":1,"attoseconds":"0"}"#, #"{"seconds":"1","attoseconds":"-1"}"#, #"{"seconds":"-1","attoseconds":"1"}"#,
                     #"{"seconds":"1","attoseconds":"1000000000000000000"}"#, #"{"seconds":"9223372036854775808","attoseconds":"0"}"#,
                     #"{"seconds":"-0","attoseconds":"0"}"#, #"{"seconds":"0","attoseconds":"00"}"#, #"{"seconds":"1","attoseconds":"0","other":"x"}"#] {
            XCTAssertThrowsError(try AutomationCodecRegistry.input(wire, parameter: parameter, catalog: captured))
        }
    }
    func testDurationDeclarationRequiresExactCapturedNativeTypeIdentity() throws {
        let forged = try catalog { document in
            var actions = try XCTUnwrap(document["actions"] as? [String: [String: Any]])
            var output = try XCTUnwrap(actions["MetadataDurationResultIntent"]?["outputType"] as? [String: Any])
            var entity = try XCTUnwrap(output["entity"] as? [String: Any]), wrapper = try XCTUnwrap(entity["wrapper"] as? [String: Any])
            var codable = try XCTUnwrap(wrapper["codable"] as? [String: Any]); codable["mangledTypeName"] = "ArbitraryCodable"
            wrapper["codable"] = codable; entity["wrapper"] = wrapper; output["entity"] = entity
            actions["MetadataDurationResultIntent"]?["outputType"] = output; document["actions"] = actions
        }
        XCTAssertNil(forged.systemActions.first { $0.id == "MetadataDurationResultIntent" }?.resultFamily)
    }
}

extension AutomationCollectionCodecTests {
    func testCalendarInputPreservesRelativeValuesAndRejectsUnknownOrUnboundContext() throws {
        let captured = try catalog(), parameter = ApplicationSurfaceCatalog.SystemAction.Parameter(name:"calendar",family:"calendarComponents",optional:false)
        let input = try AutomationCodecRegistry.input(#"{"components":{"month":"-2","nanosecond":"123456789"}}"#, parameter:parameter,catalog:captured)
        XCTAssertEqual(input.value,.object(["components":.object(["month":.integer("-2"),"nanosecond":.integer("123456789")])]))
        let program = AutomationHostProgram(operations:[.init(id:"invoke",kind:.invoke,typeID:"Intent",parameters:["calendar":input.value],parameterCodecs:["calendar":"calendarComponents"])])
        XCTAssertNoThrow(try program.validate(route:.systemIntent,phase:.subject))
        XCTAssertThrowsError(try AutomationHostProgram(operations:[.init(id:"invoke",kind:.invoke,typeID:"Intent",parameters:["calendar":input.value])]).validate(route:.systemIntent,phase:.subject))
        for wire in [#"{"components":{"day":1}}"#, #"{"components":{"unknown":"1"}}"#, #"{"components":{"year":"9223372036854775807"}}"#,
                     #"{"components":{"day":"01"}}"#, #"{"components":{},"timeZone":"invalid-zone"}"#, #"{"components":{},"timeZone":null}"#,
                     #"{"components":{},"timeZone":"America/New_York","calendar":{"identifier":"gregorian","timeZone":"Europe/London","firstWeekday":1,"minimumDaysInFirstWeek":1}}"#,
                     #"{"components":{},"calendar":{"identifier":"hebrew","timeZone":"UTC","firstWeekday":1,"minimumDaysInFirstWeek":1}}"#,
                     #"{"components":{},"calendar":{"identifier":"gregorian","timeZone":"UTC","firstWeekday":0,"minimumDaysInFirstWeek":1}}"#,
                     #"{"components":{},"calendar":{"identifier":"gregorian","timeZone":"UTC","firstWeekday":1,"minimumDaysInFirstWeek":1,"extra":"x"}}"#] {
            XCTAssertThrowsError(try AutomationCodecRegistry.input(wire,parameter:parameter,catalog:captured))
        }
    }
    func testCalendarListDeclarationDoesNotInventAnUnimplementedArrayAdapter() throws {
        let unsupported = try catalog { document in
            var actions = try XCTUnwrap(document["actions"] as? [String:[String:Any]])
            actions["MetadataBoolArrayResultIntent"]?["outputType"] = ["array":["wrapper":["capabilities":3,"memberValueType":["primitive":["wrapper":["typeIdentifier":9]]]]]]
            document["actions"] = actions
        }
        XCTAssertNil(unsupported.systemActions.first{$0.id=="MetadataBoolArrayResultIntent"}?.resultFamily)
    }
}
