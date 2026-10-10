import XCTest
@testable import IntentsAutomationCore

final class AutomationPreparedProgramContractTests: XCTestCase {
    private func fixture(family: String = "text", value: AutomationValue = .text("selected"), codec: String? = nil) -> (AutomationCase, ApplicationSurfaceCatalog) {
        let app = AppIdentity(logicalID: "app", bundleID: "example.app", platform: "ios")
        var action = ApplicationSurfaceCatalog.SystemAction(id: "Action", typeName: "Action", title: "Action",
            parameters: [.init(name: "input", family: family, optional: false)], parametersComplete: true, compiled: true, registered: false, executed: false)
        action.resultFamily = "bool"
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [action], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        var segment = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Action",
            requiredCapabilities: ["apple.intent.invoke", "apple.codec." + family, "apple.codec.bool"], effects: [.fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        segment.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: "Action", parameters: ["input": value], resultCodec: "bool", parameterCodecs: codec.map { ["input": $0] })])
        let plan = AutomationCase(id: "case", app: app, target: .init(id: "sim", kind: .simulator), environmentID: "owned", execution: segment)
        return (plan, catalog)
    }

    func testLiteralFamiliesAndStructuredCodecAnnotationsMustMatch() throws {
        let cases: [(String, AutomationValue, AutomationValue, String?)] = [
            ("text", .text("text"), .bool(true), nil), ("bool", .bool(true), .text("true"), nil),
            ("integer", .integer("7"), .text("7"), nil), ("decimal", .decimal("1.5"), .integer("1"), nil),
            ("date", .date("2026-10-08T00:00:00Z", timeZone: "UTC"), .text("2026-10-08"), nil),
            ("textArray", .array([.text("x")]), .array([.bool(true)]), "textArray"),
            ("duration", .object(["seconds": .integer("3"), "attoseconds": .integer("0")]), .text("3 seconds"), "duration")
        ]
        for (family, valid, invalid, codec) in cases {
            let (plan, catalog) = fixture(family: family, value: valid, codec: codec)
            XCTAssertNoThrow(try AutomationPreparedProgramContract.validate(plan, catalog: catalog), family)
            var wrong = plan; wrong.execution.hostProgram?.operations[0].parameters["input"] = invalid
            XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(wrong, catalog: catalog), family)
            if codec != nil {
                wrong = plan; wrong.execution.hostProgram?.operations[0].parameterCodecs = nil
                XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(wrong, catalog: catalog), family)
                wrong.execution.hostProgram?.operations[0].parameterCodecs = ["input": "boolArray"]
                XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(wrong, catalog: catalog), family)
            }
        }
    }

    func testExactActionAndFieldDeclarationsAreRequired() throws {
        let (plan, catalog) = fixture()
        for index in 0..<7 {
            var wrong = catalog
            switch index {
            case 0: wrong.systemActions = []
            case 1: wrong.systemActions.append(wrong.systemActions[0])
            case 2: wrong.systemActions[0].compiled = false
            case 3: wrong.systemActions[0].parametersComplete = false
            case 4: wrong.systemActions[0].parameters.append(wrong.systemActions[0].parameters[0])
            case 5: wrong.systemActions[0].parameters[0].family = nil
            default: wrong.systemActions[0].parameters[0].name = "other"
            }
            XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(plan, catalog: wrong), String(index))
        }
        var wrong = plan; wrong.execution.hostProgram?.operations[0].parameters["unknown"] = .text("extra")
        XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(wrong, catalog: catalog))
        wrong = plan; wrong.execution.hostProgram?.operations[0].parameters = [:]
        XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(wrong, catalog: catalog))
    }

    func testOptionalDefaultAndNoValueRetainTheirDeclaredMeaning() throws {
        let (plan, catalog) = fixture()
        for value in [AutomationValue.null, .omission] {
            var wrong = plan; wrong.execution.hostProgram?.operations[0].parameters["input"] = value
            XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(wrong, catalog: catalog))
            var optional = catalog; optional.systemActions[0].parameters[0].optional = true
            XCTAssertNoThrow(try AutomationPreparedProgramContract.validate(wrong, catalog: optional))
        }
        var omitted = plan; omitted.execution.hostProgram?.operations[0].parameters = [:]
        var defaulted = catalog; defaulted.systemActions[0].parameters[0].defaultValue = .text("default")
        XCTAssertNoThrow(try AutomationPreparedProgramContract.validate(omitted, catalog: defaulted))
        for codec in [String?.none, "noValue", "bool"] {
            var copy = plan; copy.execution.hostProgram?.operations[0].resultCodec = codec
            XCTAssertNoThrow(try AutomationPreparedProgramContract.validate(copy, catalog: catalog))
        }
        var wrong = plan; wrong.execution.hostProgram?.operations[0].resultCodec = "text"
        XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(wrong, catalog: catalog))
        var unsupported = catalog; unsupported.systemActions[0].resultFamily = nil
        XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(plan, catalog: unsupported))
        wrong.execution.hostProgram?.operations[0].resultCodec = "noValue"
        XCTAssertNoThrow(try AutomationPreparedProgramContract.validate(wrong, catalog: unsupported))
    }

    func testEnumAndEntityReferencesRequireSelectedTypeIdentity() throws {
        for family in ["enum", "entity"] {
            let value: AutomationValue = family == "enum" ? .enumeration(typeID: "Selected", value: "one") : .entity(typeID: "Selected", value: "one")
            var (plan, catalog) = fixture(family: family, value: value)
            catalog.systemActions[0].parameters[0].typeID = "Selected"
            catalog.enumerations = [.init(typeID: "Selected", title: "Selected", cases: [.init(id: "one", title: "One")])]
            catalog.entities = [.init(typeID: "Selected", title: "Selected", queryIdentifier: "Query", properties: [:], propertyTitles: [:])]
            XCTAssertNoThrow(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
            plan.execution.hostProgram?.operations[0].parameters["input"] = family == "enum" ? .enumeration(typeID: "Foreign", value: "one") : .entity(typeID: "Foreign", value: "one")
            XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
        }
    }

    func testDeferredProducerFamilyMustMatchEvenForOptionalOrDefaultedFields() throws {
        var (plan, catalog) = fixture()
        var producer = AutomationSegment(id: "producer", kind: .ui, phase: .setup, operation: "Read", effects: [.observe], lifecycle: .persistedStateAcrossSegments)
        producer.uiProgram = .init(operations: [.init(id: "output", kind: .observeProperty, locator: .init(.testId, "field"), property: "value")])
        plan.setup = [producer]; plan.execution.hostProgram?.operations[0].parameters = [:]
        plan.execution.inputBindings = [.init(producerSegmentID: "producer", outputID: "output", destination: .hostParameter, operationID: "invoke", name: "input")]
        XCTAssertNoThrow(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
        for optional in [true, false] {
            catalog.systemActions[0].parameters[0].family = "bool"
            catalog.systemActions[0].parameters[0].optional = optional
            catalog.systemActions[0].parameters[0].defaultValue = optional ? nil : .bool(false)
            XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
        }
        plan.setup[0].uiProgram?.operations[0].property = "checked"
        XCTAssertNoThrow(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
        plan.execution.inputBindings?[0].name = "unknown"
        XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
    }

    func testDeferredHostResultsAndEntitySelectionsRetainTheirTypes() throws {
        var (plan, catalog) = fixture(family: "bool", value: .bool(true))
        var producer = plan.execution; producer.id = "producer"; producer.phase = .setup
        producer.hostProgram?.operations[0].id = "output"
        plan.setup = [producer]; plan.execution.hostProgram?.operations[0].parameters = [:]
        plan.execution.inputBindings = [.init(producerSegmentID: "producer", outputID: "output", destination: .hostParameter, operationID: "invoke", name: "input")]
        XCTAssertNoThrow(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
        catalog.systemActions[0].parameters[0].family = "text"
        XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))

        var (entityPlan, entityCatalog) = fixture(family: "entity", value: .entity(typeID: "Selected", value: "one"))
        entityCatalog.systemActions[0].parameters[0].typeID = "Selected"
        entityCatalog.entities = [.init(typeID: "Selected", title: "Selected", queryIdentifier: "Query", properties: ["title": "text"], propertyTitles: [:])]
        var query = AutomationSegment(id: "query", kind: .systemQuery, phase: .setup, operation: "Lookup", effects: [.observe], lifecycle: .persistedStateAcrossSegments)
        query.hostProgram = .init(operations: [.init(id: "output", kind: .query, typeID: "Selected", queryText: "one", properties: ["title": "text"])])
        entityPlan.setup = [query]; entityPlan.execution.hostProgram?.operations[0].parameters = [:]
        entityPlan.execution.inputBindings = [.init(producerSegmentID: "query", outputID: "output", destination: .hostParameter, operationID: "invoke", name: "input",
            uniqueEntity: .init(typeID: "Selected", matchingProperties: ["title": .text("one")]))]
        XCTAssertNoThrow(try AutomationPreparedProgramContract.validate(entityPlan, catalog: entityCatalog))
        entityCatalog.systemActions[0].parameters[0].typeID = "Foreign"
        XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(entityPlan, catalog: entityCatalog))
    }

    func testQueriesRequireUniqueDeclaredEntityAndExactPropertyFamilies() throws {
        var (plan, catalog) = fixture()
        catalog.entities = [.init(typeID: "Selected", title: "Selected", queryIdentifier: "Query", properties: ["title": "text", "done": "bool", "count": "integer"], propertyTitles: [:])]
        plan.execution.kind = .systemQuery
        plan.execution.hostProgram = .init(operations: [.init(id: "query", kind: .query, typeID: "Selected", queryText: "one")])
        for properties in [Dictionary<String, String>?.none, [:], ["title": "text"], ["title": "text", "done": "bool", "count": "integer"]] {
            plan.execution.hostProgram?.operations[0].properties = properties
            XCTAssertNoThrow(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
        }
        for properties in [["unknown": "text"], ["title": "bool"], ["done": "text"], ["count": "decimal"]] {
            plan.execution.hostProgram?.operations[0].properties = properties
            XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
        }
        plan.execution.hostProgram?.operations[0].properties = nil
        for index in 0..<4 {
            var wrong = catalog
            switch index {
            case 0: wrong.entities = nil
            case 1:
                let duplicate = try XCTUnwrap(wrong.entities?.first)
                wrong.entities?.append(duplicate)
            case 2: wrong.entities?[0].typeID = "Foreign"
            default: wrong.entities?[0].queryIdentifier = ""
            }
            XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(plan, catalog: wrong), String(index))
        }
    }
}
