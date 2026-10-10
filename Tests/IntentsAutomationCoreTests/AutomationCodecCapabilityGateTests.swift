import XCTest
@testable import IntentsAutomationCore

final class AutomationCodecCapabilityGateTests: XCTestCase {
    private func fixture() -> (AutomationCase, ApplicationSurfaceCatalog, RunApproval, CapabilityProfile) {
        let app = AppIdentity(logicalID: "selected", bundleID: "example.selected", platform: "ios")
        var action = ApplicationSurfaceCatalog.SystemAction(id: "Action", typeName: "Action", title: "Action",
            parameters: [.init(name: "input", family: "text", optional: false)], parametersComplete: true, compiled: true, registered: false, executed: false)
        action.resultFamily = "bool"
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [action], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        let target = TargetIdentity(id: "sim", kind: .simulator)
        let approval = RunApproval(runID: "run", app: app, target: target, environmentID: "owned",
            effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true)
        let capabilities = CapabilityProfile(records: ["apple.intent.invoke": .init(state: .available, reason: "Synthetic host route", probeVersion: "test", evidence: [])])
        var subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "Action",
            requiredCapabilities: ["apple.intent.invoke"], effects: [.fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        subject.hostProgram = .init(operations: [.init(id: "invoke", kind: .invoke, typeID: "Action", parameters: ["input": .text("selected")], resultCodec: "bool")])
        let plan = AutomationCase(id: "case", app: app, target: target, environmentID: "owned", execution: subject)
        return (AutomationCodecRequirements.applying(to: plan, catalog: catalog), catalog, approval, capabilities)
    }
    func testReviewPreservesUnknownConversionAndCannotAuthorizeExecution() throws {
        let (plan, catalog, approval, capabilities) = fixture()
        XCTAssertEqual(Set(plan.execution.requiredCapabilities), ["apple.intent.invoke", "apple.codec.text", "apple.codec.bool"])
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, purpose: .review))
        XCTAssertNoThrow(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities))
        XCTAssertNil(capabilities.records["apple.codec.text"]); XCTAssertNil(capabilities.records["apple.codec.bool"])
        var missing = plan; missing.execution.requiredCapabilities.removeAll { $0 == "apple.codec.text" }
        XCTAssertThrowsError(try PlanValidator.validate(missing, approval: approval, capabilities: capabilities, purpose: .review))
        var pretending = plan; pretending.provenance["ui.executionAvailability"] = "available"
        XCTAssertThrowsError(try PlanValidator.validate(pretending, approval: approval, capabilities: capabilities))
        var synthetic = capabilities
        for family in ["text", "bool"] { synthetic.records["apple.codec." + family] = .init(state: .available, reason: "Synthetic conversion contract", probeVersion: "test", evidence: []) }
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: synthetic))
        for state in [CapabilityProfile.State.unknown, .unavailable, .consentRequired] {
            synthetic.records["apple.codec.text"]?.state = state
            XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: synthetic))
        }
    }
    func testEveryActiveInputAndProjectedResultDerivesItsOwnFamily() throws {
        let values: [(AutomationValue, String?, String)] = [
            (.text("x"), nil, "text"), (.bool(true), nil, "bool"), (.integer("1"), nil, "integer"), (.decimal("1.5"), nil, "decimal"),
            (.date("2026-10-08T00:00:00Z", timeZone: "UTC"), nil, "date"), (.enumeration(typeID: "Enum", value: "one"), nil, "enum"),
            (.entity(typeID: "Entity", value: "one"), nil, "entity"), (.array([.text("x")]), "textArray", "textArray"),
            (.array([.integer("1")]), "integerArray", "integerArray"), (.object([:]), "duration", "duration"),
            (.object([:]), "calendarComponents", "calendarComponents"), (.object(["url": .text("https://example.invalid")]), "url", "url")
        ]
        for (value, annotation, family) in values {
            let program = AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: "Action", parameters: ["input": value], resultCodec: "noValue", parameterCodecs: annotation.map { ["input": $0] })])
            XCTAssertEqual(program.requiredCodecCapabilities, ["apple.codec." + family])
        }
        for family in ["text", "bool", "integer", "decimal", "date", "textArray", "boolArray", "integerArray", "decimalArray", "dateArray", "duration", "calendarComponents", "url"] {
            let program = AutomationHostProgram(operations: [.init(id: "invoke", kind: .invoke, typeID: "Action", resultCodec: family)])
            XCTAssertEqual(program.requiredCodecCapabilities, ["apple.codec." + family])
        }
    }
    func testOptionalOmissionDoesNotRequireConversionButNullKeepsDeclaredFamily() throws {
        var (plan, catalog, approval, capabilities) = fixture()
        catalog.systemActions[0].parameters[0].family = "bool"; catalog.systemActions[0].parameters[0].optional = true
        plan.execution.hostProgram?.operations[0].resultCodec = "noValue"
        plan.execution.hostProgram?.operations[0].parameters["input"] = .omission
        plan.execution.requiredCapabilities = ["apple.intent.invoke"]
        plan = AutomationCodecRequirements.applying(to: plan, catalog: catalog)
        XCTAssertEqual(plan.execution.requiredCapabilities, ["apple.intent.invoke"])
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities))
        plan.execution.hostProgram?.operations[0].parameters["input"] = .null
        XCTAssertThrowsError(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
        plan = AutomationCodecRequirements.applying(to: plan, catalog: catalog)
        XCTAssertTrue(plan.execution.requiredCapabilities.contains("apple.codec.bool"))
        XCTAssertEqual(plan.execution.hostProgram?.operations[0].parameterCodecs?["input"], "bool")
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, purpose: .review))
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities))
        var synthetic = capabilities
        synthetic.records["apple.codec.bool"] = .init(state: .available, reason: "Synthetic nullable setter", probeVersion: "test", evidence: [])
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: synthetic))
        XCTAssertNoThrow(try AutomationPreparedProgramContract.validate(plan, catalog: catalog))
    }
    func testUntypedNullCannotDispatchEvenWithAnAvailableUnboundFamily() throws {
        var (plan, _, approval, capabilities) = fixture()
        plan.execution.hostProgram?.operations[0].parameters = ["input": .null]
        plan.execution.hostProgram?.operations[0].resultCodec = "noValue"
        capabilities.records["apple.codec.text"] = .init(state: .available, reason: "Synthetic", probeVersion: "test", evidence: [])
        capabilities.records["apple.codec.bool"] = .init(state: .available, reason: "Synthetic", probeVersion: "test", evidence: [])
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, purpose: .review))
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities))
    }
    func testDeferredTypedProducerCannotHideItsDestinationRequirement() throws {
        var (plan, catalog, approval, capabilities) = fixture()
        catalog.systemActions[0].parameters[0].family = "bool"
        var producer = AutomationSegment(id: "producer", kind: .ui, phase: .setup, operation: "Read checked", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        producer.uiProgram = .init(operations: [.init(id: "output", kind: .observeProperty, locator: .init(.testId, "checkbox"), property: "checked")])
        plan.setup = [producer]; plan.execution.hostProgram?.operations[0].parameters = [:]
        plan.execution.inputBindings = [.init(producerSegmentID: producer.id, outputID: "output", destination: .hostParameter, operationID: "invoke", name: "input")]
        plan.execution.requiredCapabilities = ["apple.intent.invoke"]
        plan = AutomationCodecRequirements.applying(to: plan, catalog: catalog)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertEqual(Set(plan.execution.requiredCapabilities), ["apple.intent.invoke", "apple.codec.bool"])
        XCTAssertNoThrow(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, purpose: .review))
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities))
        plan.execution.requiredCapabilities.removeAll { $0 == "apple.codec.bool" }
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, purpose: .review))
    }
    func testTemplateReviewCanProduceFrozenCaseWithoutMintingConversionAvailability() throws {
        let (_, catalog, approval, capabilities) = fixture()
        let effects = AutomationActionEffectDeclaration(app: catalog.app, actionID: "Action", effects: [.fixtureWrite], developerConfirmation: "Synthetic controlled fixture")
        let inputs = ["input": AutomationActionInput(value: .text("selected"), origin: .approvedExample, evidence: "Synthetic example")]
        let plan = try AutomationTemplatePlanner.compile(catalog: catalog, actionID: "Action", inputs: inputs, declaredEffects: effects, approval: approval, capabilities: capabilities, purpose: .review)
        XCTAssertNoThrow(try AutomationFrozenCase(plan: plan))
        XCTAssertThrowsError(try AutomationTemplatePlanner.compile(catalog: catalog, actionID: "Action", inputs: inputs, declaredEffects: effects, approval: approval, capabilities: capabilities))
        XCTAssertFalse(capabilities.supports(plan.execution.requiredCapabilities))
    }
}
