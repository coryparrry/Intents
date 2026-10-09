#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationEntityActionPlannerTests: XCTestCase {
    private let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
    private var target: TargetIdentity { .init(id: "owned", kind: .simulator) }
    private var catalog: ApplicationSurfaceCatalog {
        .init(app: app, systemActions: [.init(id: "CompleteTask", typeName: "Subject.CompleteTask", title: "Complete task",
            parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity")], parametersComplete: true,
            compiled: true, registered: false, executed: false)], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [],
            entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "Subject.TaskQuery",
                properties: ["title": "text", "owner": "text", "completed": "bool"], propertyTitles: [:])])
    }
    private var approval: RunApproval { .init(runID: "run", app: app, target: target, environmentID: "owned", effects: [.observe, .fixtureWrite], maximumActions: 20, disposable: true) }
    private var capabilities: CapabilityProfile { .init(records: ["apple.intent.invoke", "apple.entity.query", "apple.codec.entity", "apple.codec.bool"].reduce(into: [:]) {
        $0[$1] = .init(state: .available, reason: "Source fixture", probeVersion: "fixture", evidence: [])
    }) }
    private func choice(id: String = "personal", owner: String = "Personal", target: TargetIdentity? = nil, digest: String? = nil, environment: String = "owned", source: String = "query-attempt") throws -> AutomationQueryEntityChoice {
        .init(id: id, typeID: "TaskEntity", properties: ["title": .text("Send invoice"), "owner": .text(owner), "completed": .bool(false)],
            sourceAttemptID: source, app: app, target: target ?? self.target, environmentID: environment,
            catalogDigest: try digest ?? AutomationRecipeContext.catalogDigest(catalog))
    }
    private func compile(selected: AutomationQueryEntityChoice, protected: [AutomationQueryEntityChoice] = [], expected: Bool? = true) throws -> AutomationCase {
        try AutomationEntityActionPlanner.compile(catalog: catalog, actionID: "CompleteTask", textInputs: [:], selections: ["task": selected],
            protectedSelections: ["task": protected], expectations: expected.map { ["task": ["completed": .bool($0)]] } ?? [:],
            declaredEffects: .init(app: app, actionID: "CompleteTask", effects: [.fixtureWrite], developerConfirmation: "Complete this selected task; preserve explicitly chosen other records"),
            approval: approval, capabilities: capabilities)
    }
    func testDeclaredDefaultNeverDiscardsAnExplicitEntityChoiceForPrimitiveInput() throws {
        var declaration = catalog
        var flag = ApplicationSurfaceCatalog.SystemAction.Parameter(name: "flag", family: "bool", optional: false)
        flag.defaultValue = .bool(false)
        declaration.systemActions[0].parameters = [flag]
        let input = try choice(id: "personal", owner: "Personal", digest: AutomationRecipeContext.catalogDigest(declaration))
        let effects = AutomationActionEffectDeclaration(app: app, actionID: "CompleteTask", effects: [.fixtureWrite], developerConfirmation: "Explicit effect approval")
        XCTAssertThrowsError(try AutomationEntityActionPlanner.compile(catalog: declaration, actionID: "CompleteTask", textInputs: [:], selections: ["flag": input], expectations: [:], declaredEffects: effects, approval: approval, capabilities: capabilities))
        let plan = try AutomationEntityActionPlanner.compile(catalog: declaration, actionID: "CompleteTask", textInputs: [:], selections: [:], expectations: [:], declaredEffects: effects, approval: approval, capabilities: capabilities)
        XCTAssertEqual(plan.execution.inputs["flag"], .bool(false))
    }
    private func observed(_ plan: AutomationCase, personal: Bool, work: Bool) -> AutomationObservation {
        func records(_ id: String, _ owner: String, _ completed: Bool) -> AutomationValue {
            .array([.object(["entity": .entity(typeID: "TaskEntity", value: id), "properties": .object([
                "title": .text("Send invoice"), "owner": .text(owner), "completed": .bool(completed)])])])
        }
        return .init(id: plan.observations[0].id, app: app, target: target, environmentID: "owned", attemptID: "attempt",
            stepID: plan.observations[0].id, route: .systemQuery, proof: .appState,
            value: .object(["records": records("personal", "Personal", personal), "protected.0": records("work", "Work", work)]))
    }
    func testRealSelectionIsFreshlyResolvedAndIndependentChecksCatchWrongRecordAndMissingSave() throws {
        let plan = try compile(selected: choice(), protected: [choice(id: "work", owner: "Work")])
        XCTAssertNil(plan.execution.hostProgram?.operations[0].parameters["task"])
        XCTAssertEqual(plan.execution.inputBindings?.first?.producerSegmentID, "lookup.task")
        XCTAssertEqual(plan.setup[0].hostProgram?.operations[0].queryIDs, ["personal"])
        XCTAssertEqual(plan.setupChecks?.count, 2)
        for (personal, work, expected) in [(true, false, AttemptResult.Summary.passed), (false, true, .assertionFailed), (false, false, .assertionFailed)] {
            let result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true,
                observations: [observed(plan, personal: personal, work: work)])
            XCTAssertEqual(result.summary, expected); XCTAssertTrue(result.evidenceComplete)
            if work { XCTAssertEqual(result.failedObservations, ["business.task.completed", "business.task.protected.0.completed"]) }
        }
    }
    func testObserverCannotPassUsingSubstitutedIDWithIdenticalProperties() throws {
        let plan = try compile(selected: choice())
        var observation = observed(plan, personal: true, work: false)
        observation.value = .object(["records": .array([.object(["entity": .entity(typeID: "TaskEntity", value: "substitute"),
            "properties": .object(["title": .text("Send invoice"), "owner": .text("Personal"), "completed": .bool(true)])])])])
        let result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [observation])
        XCTAssertNotEqual(result.summary, .passed)
        XCTAssertFalse(result.assessed)
    }
    func testForeignOrStaleChoicesAndInventedTextEntityIDsNeverCompile() throws {
        for foreign in [try choice(target: .init(id: "foreign", kind: .simulator)), try choice(digest: String(repeating: "b", count: 64)), try choice(environment: "foreign")] {
            XCTAssertThrowsError(try compile(selected: foreign))
        }
        XCTAssertThrowsError(try compile(selected: choice(), protected: [choice(id: "work", owner: "Work", source: "other-query")]))
        XCTAssertThrowsError(try compile(selected: choice(), protected: [choice()]))
        XCTAssertThrowsError(try AutomationEntityActionPlanner.compile(catalog: catalog, actionID: "CompleteTask",
            textInputs: ["task": .init(value: .text("invented-entity-id"), origin: .userChoice, evidence: "raw text")], selections: [:], expectations: [:],
            declaredEffects: .init(app: app, actionID: "CompleteTask", effects: [.fixtureWrite], developerConfirmation: "Confirmed"), approval: approval, capabilities: capabilities))
    }
    func testInvocationDoesNotInventBusinessExpectationsAndActualChoiceChangesInvalidateCase() throws {
        let unassessed = try compile(selected: choice(), expected: nil)
        XCTAssertTrue(unassessed.requirements.isEmpty); XCTAssertEqual(unassessed.setupChecks?.count, 1)
        let first = try compile(selected: choice()), other = try compile(selected: choice(id: "different"))
        XCTAssertNotEqual(first.id, other.id)
        let changedOracle = try compile(selected: choice(), expected: false)
        XCTAssertNotEqual(first.id, changedOracle.id)
    }
}
#endif
