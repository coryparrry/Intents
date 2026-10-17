#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacHostCallerIntegrationTests: XCTestCase, @unchecked Sendable {
    private let app = AppIdentity(logicalID: "caller", bundleID: "example.MacCaller", platform: "macos",
        productDigest: String(repeating: "a", count: 64))
    private let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "caller-session")
    private var capabilities: CapabilityProfile {
        .init(records: ["apple.intent.invoke", "apple.entity.query", "apple.codec.entity", "apple.codec.text", "apple.codec.bool"].reduce(into: [:]) {
            $0[$1] = .init(state: .available, reason: "Caller fixture", probeVersion: "fixture", evidence: [])
        })
    }
    private func approval(maximum: Int, effects: Set<AutomationEffect> = [.observe, .navigate]) -> RunApproval {
        .init(runID: "run", app: app, target: target, environmentID: "fixture", effects: effects,
            maximumActions: maximum, disposable: true)
    }
    private func catalog(entityInput: Bool) -> ApplicationSurfaceCatalog {
        let actions: [ApplicationSurfaceCatalog.SystemAction] = entityInput ? [
            .init(id: "CompleteTask", typeName: "Fixture.CompleteTask", title: "Complete task",
                parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity")],
                parametersComplete: true, compiled: true, registered: false, executed: false, resultFamily: "noValue")
        ] : (0..<2).map { index in
            .init(id: "Action\(index)", typeName: "Fixture.Action\(index)", title: "Action \(index)", parameters: [],
                parametersComplete: true, compiled: true, registered: false, executed: false, resultFamily: "noValue")
        }
        return .init(app: app, systemActions: actions, systemDiscoveryComplete: true, uiDiscoveryComplete: false, gaps: [],
            entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "Fixture.TaskQuery",
                properties: ["title": "text", "completed": "bool"], propertyTitles: [:])])
    }
    private func choice(_ catalog: ApplicationSurfaceCatalog) throws -> AutomationQueryEntityChoice {
        .init(id: "task-1", typeID: "TaskEntity", properties: ["title": .text("Selected task"), "completed": .bool(false)],
            sourceAttemptID: "query-attempt", app: app, target: target, environmentID: "fixture",
            catalogDigest: try AutomationRecipeContext.catalogDigest(catalog))
    }
    private func wire(_ plan: AutomationCase, approval: RunApproval) throws -> UIHostPlan {
        var exact = approval
        exact.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        return try AutomationXCUITestPlan.assemble(plan: plan, approval: exact, attemptID: "attempt", leaseGeneration: 1)
    }
    private func importCompleted(_ wire: UIHostPlan, plan: AutomationCase) throws -> [AutomationSegmentReceipt] {
        let data = try wire.steps.enumerated().map { index, step in
            let value: UIHostValue?
            if step.kind == .query {
                value = .init(kind: "array", items: [.init(kind: "entity", value: "task-1", typeId: "TaskEntity",
                    properties: ["title": .init(kind: "text", value: "Selected task"), "completed": .init(kind: "bool", boolValue: false)])])
            } else if step.kind == .invokeIntent { value = .init(kind: "noValue") }
            else { value = nil }
            return try JSONEncoder().encode(UIHostStepReceipt(plan: wire, index: index, dispatched: true, completed: true, value: value))
        }
        return try AutomationXCUITestReceiptImporter.importReceipts(data, uiPlan: wire, plan: plan)
    }
    private func reserve(_ wire: UIHostPlan, plan: AutomationCase, subject: Int, setup: Int = 0,
                         observer: Int = 0, uiActions: Int) async throws -> AutomationCampaignUsage {
        var limits = AutomationCampaignLimits()
        limits.subjectOperations = subject; limits.setupOperations = setup; limits.observerOperations = observer; limits.uiActions = uiActions
        let budget = try AutomationCampaignBudget(limits: limits)
        try await AutomationXCUITestCampaign.reserveBudget(wire, plan: plan, attemptID: "attempt", budget: budget)
        return await budget.snapshot()
    }

    func testObserveOnlyEntityQueryProducerKeepsNoActivationAndReadOnlyReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-query-caller-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var prepared = try AutomationPreparedCodecRegressionTests.makeFixture(root: root).prepared
        prepared.host.app = app; prepared.host.target = target; prepared.catalog = catalog(entityInput: true)
        let entity = try XCTUnwrap(prepared.catalog.entities?.first)
        let approved = approval(maximum: 1, effects: [.observe])
        let plan = try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: "Selected", approval: approved)
        let wire = try wire(plan, approval: approved)
        XCTAssertEqual(plan.execution.effects, [.observe])
        XCTAssertEqual(wire.steps.map(\.kind), [.query])
        let receipts = try importCompleted(wire, plan: plan)
        XCTAssertEqual(receipts.count, 1); XCTAssertTrue(receipts[0].completed)
        let usage = try await reserve(wire, plan: plan, subject: 1, uiActions: 0)
        XCTAssertEqual(usage.reservedSubjectOperations, 1); XCTAssertEqual(usage.reservedUIActions, 0)
    }

    func testEntityActionProducerKeepsLookupReadOnlyWhileChargingApprovedActivation() async throws {
        let catalog = catalog(entityInput: true), selected = try choice(catalog)
        let approved = approval(maximum: 5, effects: [.observe, .navigate, .fixtureWrite])
        let plan = try AutomationEntityActionPlanner.compile(catalog: catalog, actionID: "CompleteTask", textInputs: [:],
            selections: ["task": selected], expectations: [:], declaredEffects: .init(app: app, actionID: "CompleteTask",
                effects: [.fixtureWrite], developerConfirmation: "Complete the chosen task"), approval: approved, capabilities: capabilities)
        XCTAssertEqual(plan.setup[0].effects, [.observe])
        XCTAssertEqual(plan.observations[0].effects, [.observe])
        let wire = try wire(plan, approval: approved)
        XCTAssertEqual(wire.steps.map(\.kind), [.launch, .query, .checkFreshness, .invokeIntent, .query])
        XCTAssertEqual(wire.steps.first?.segmentID, plan.setup[0].id)
        XCTAssertTrue(try importCompleted(wire, plan: plan).allSatisfy(\.completed))
        let usage = try await reserve(wire, plan: plan, subject: 1, setup: 3, observer: 1, uiActions: 1)
        XCTAssertEqual(usage.reservedSetupOperations, 3); XCTAssertEqual(usage.reservedSubjectOperations, 1)
        XCTAssertEqual(usage.reservedObserverOperations, 1); XCTAssertEqual(usage.reservedUIActions, 1)
        var tooSmall = approved; tooSmall.maximumActions = 4
        XCTAssertThrowsError(try self.wire(plan, approval: tooSmall))
        do { _ = try await reserve(wire, plan: plan, subject: 1, setup: 2, observer: 1, uiActions: 1); XCTFail("Missing setup allowance admitted") }
        catch { XCTAssertEqual(error as? AutomationCampaignBudgetError, .exhausted("setup operations")) }
    }

    func testFirstRunHostOnlyProducerCountsEveryLaunchAndInvocationAtApprovalBoundary() async throws {
        let catalog = catalog(entityInput: false)
        for maximum in 1...4 {
            let approved = approval(maximum: maximum)
            let proposal = try AutomationFirstRunPlanner.compile(catalog: catalog, appName: "Caller", approval: approved,
                capabilities: capabilities, includeActions: true, includeUI: false, localeIdentifier: "en_GB")
            XCTAssertEqual(proposal.plans.count, maximum / 2)
            for plan in proposal.plans {
                XCTAssertEqual(plan.budget.subjectOperations, 2); XCTAssertEqual(plan.budget.uiActions, 1)
                let wire = try wire(plan, approval: approved)
                XCTAssertEqual(wire.steps.map(\.kind), [.launch, .invokeIntent])
                XCTAssertTrue(try importCompleted(wire, plan: plan).allSatisfy(\.completed))
                let usage = try await reserve(wire, plan: plan, subject: 2, uiActions: 1)
                XCTAssertEqual(usage.reservedSubjectOperations, 2); XCTAssertEqual(usage.reservedUIActions, 1)
                do { _ = try await reserve(wire, plan: plan, subject: 1, uiActions: 1); XCTFail("Missing launch allowance admitted") }
                catch { XCTAssertEqual(error as? AutomationCampaignBudgetError, .exhausted("subject operations")) }
            }
        }
    }

    func testFirstRunEntityProducerCountsLookupActivationFreshnessInvocationAndReadback() async throws {
        let catalog = catalog(entityInput: true), selected = try choice(catalog)
        for maximum in [4, 5] {
            let approved = approval(maximum: maximum, effects: [.observe, .navigate, .fixtureWrite])
            var evidence = AutomationFirstRunInputEvidence(app: app, target: target, environmentID: "fixture",
                catalogDigest: try AutomationRecipeContext.catalogDigest(catalog), inputs: [:])
            evidence.entitySelections = ["CompleteTask": ["task": selected]]
            let proposal = try AutomationFirstRunPlanner.compile(catalog: catalog, appName: "Caller", approval: approved,
                capabilities: capabilities, includeActions: true, includeUI: false, localeIdentifier: "en_GB", inputEvidence: evidence)
            XCTAssertEqual(proposal.plans.count, maximum == 5 ? 1 : 0)
            if let plan = proposal.plans.first {
                XCTAssertEqual(plan.budget.subjectOperations, 1); XCTAssertEqual(plan.budget.uiActions, 1)
                let wire = try wire(plan, approval: approved)
                XCTAssertEqual(wire.steps.count, 5)
                XCTAssertTrue(try importCompleted(wire, plan: plan).allSatisfy(\.completed))
                _ = try await reserve(wire, plan: plan, subject: 1, setup: 3, observer: 1, uiActions: 1)
            }
        }
    }
}
#endif
