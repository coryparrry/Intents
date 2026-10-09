import XCTest
@testable import IntentsAutomationCore

final class AutomationPlannerTests: XCTestCase {
    private let app = AppIdentity(logicalID: "selected", bundleID: "example.selected", platform: "ios", productDigest: String(repeating: "a", count: 64))
    private var catalog: ApplicationSurfaceCatalog {
        .init(app: app, systemActions: [.init(id: "ActualAction", typeName: "Subject.ActualAction", title: "Actual title",
            parameters: [.init(name: "query", family: "text", optional: false), .init(name: "optional", family: "text", optional: true)],
            parametersComplete: true, compiled: true, registered: false, executed: false)], systemDiscoveryComplete: false,
            uiDiscoveryComplete: false, gaps: ["Partial catalog"])
    }
    private var approval: RunApproval { .init(runID: "run", app: app, target: .init(id: "device", kind: .simulator), environmentID: "owned", effects: [.observe, .navigate], maximumActions: 10, disposable: true) }
    private var capabilities: CapabilityProfile { .init(records: ["apple.codec.text": .init(state: .available, reason: "synthetic text conversion fixture", probeVersion: "fixture", evidence: []), "apple.intent.invoke": .init(state: .available, reason: "contract fixture", probeVersion: "fixture", evidence: [])]) }
    private var input: [String: AutomationActionInput] { ["query": .init(value: .text("real supplied input"), origin: .approvedExample, evidence: "Approved input example")] }
    private var declaration: AutomationActionEffectDeclaration { .init(app: app, actionID: "ActualAction", effects: [.navigate], developerConfirmation: "Developer confirmed navigation semantics") }
    func testDeclaredInputsCompileWithoutInventingBusinessAssertions() throws {
        var profile = capabilities
        profile.records["siri"] = .init(state: .unavailable, reason: "Optional route absent", probeVersion: "fixture", evidence: [])
        let plan = try AutomationTemplatePlanner.compile(catalog: catalog, actionID: "ActualAction", inputs: input, declaredEffects: declaration, approval: approval, capabilities: profile)
        XCTAssertEqual(plan.execution.inputs["optional"], .omission)
        XCTAssertEqual(plan.execution.effects, [.navigate]); XCTAssertTrue(plan.requirements.isEmpty)
        XCTAssertFalse(plan.provenance.isEmpty)
        let result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [])
        XCTAssertEqual(result.summary, .executedUnassessed); XCTAssertFalse(result.assessed)
    }
    func testMissingDomainInputUnknownCodecAndCapabilityAreExplicitGaps() throws {
        XCTAssertEqual(AutomationTemplatePlanner.proposals(catalog: catalog).first?.missingInputs, ["query"])
        XCTAssertThrowsError(try AutomationTemplatePlanner.compile(catalog: catalog, actionID: "ActualAction", inputs: [:], declaredEffects: declaration, approval: approval, capabilities: capabilities))
        var unknown = catalog; unknown.systemActions[0].parametersComplete = false
        XCTAssertThrowsError(try AutomationTemplatePlanner.compile(catalog: unknown, actionID: "ActualAction", inputs: input, declaredEffects: declaration, approval: approval, capabilities: capabilities))
        XCTAssertThrowsError(try AutomationTemplatePlanner.compile(catalog: catalog, actionID: "ActualAction", inputs: input, declaredEffects: declaration, approval: approval, capabilities: .init()))
    }
    func testAllowedScopeIsNotTheActionsEffectClassification() {
        var declaration = declaration
        declaration.effects = [.externalWrite]
        XCTAssertThrowsError(try AutomationTemplatePlanner.compile(catalog: catalog, actionID: "ActualAction", inputs: input, declaredEffects: declaration, approval: approval, capabilities: capabilities))
        declaration.effects = [.navigate]; declaration.developerConfirmation = ""
        XCTAssertThrowsError(try AutomationTemplatePlanner.compile(catalog: catalog, actionID: "ActualAction", inputs: input, declaredEffects: declaration, approval: approval, capabilities: capabilities))
        declaration.developerConfirmation = "Confirmed"; declaration.actionID = "OtherAction"
        XCTAssertThrowsError(try AutomationTemplatePlanner.compile(catalog: catalog, actionID: "ActualAction", inputs: input, declaredEffects: declaration, approval: approval, capabilities: capabilities))
    }
    func testDifferentInputsProduceDistinctStableImmutableCases() throws {
        let first = try AutomationTemplatePlanner.compile(catalog: catalog, actionID: "ActualAction", inputs: input, declaredEffects: declaration, approval: approval, capabilities: capabilities)
        let same = try AutomationTemplatePlanner.compile(catalog: catalog, actionID: "ActualAction", inputs: input, declaredEffects: declaration, approval: approval, capabilities: capabilities)
        var changed = input; changed["query"]?.value = .text("another approved input")
        let second = try AutomationTemplatePlanner.compile(catalog: catalog, actionID: "ActualAction", inputs: changed, declaredEffects: declaration, approval: approval, capabilities: capabilities)
        XCTAssertEqual(first.id, same.id); XCTAssertNotEqual(first.id, second.id)
    }

}
