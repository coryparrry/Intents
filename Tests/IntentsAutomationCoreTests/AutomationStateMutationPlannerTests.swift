import XCTest
@testable import IntentsAutomationCore

final class AutomationStateMutationPlannerTests: XCTestCase, @unchecked Sendable {
    func testConcreteSetupCannotEnterArchivedControllerMutationOrHostExecution() throws {
        let fixture = try StateSearchFixture()
        XCTAssertThrowsError(try AutomationStateMutationPlanner.propose(baseline: .init(plan: fixture.concretePlan), context: fixture.context))
        // Archived controller cases remain inspectable proposals, never current driver authority.
        XCTAssertThrowsError(try AutomationXCUITestPlan.assemble(plan: fixture.plan, approval: fixture.approval,
            attemptID: "archived-controller", leaseGeneration: 1)) { error in
            XCTAssertEqual(error as? AutomationContractError, .invalidPlan("XCUITest requires explicit UI steps"))
        }
    }
    func testStateMutationsAndPairPreserveSubjectObserverAndOracle() throws {
        let fixture = try StateSearchFixture(), frozen = try AutomationFrozenCase(plan: fixture.plan)
        let proposal = try AutomationStateMutationPlanner.propose(baseline: frozen, context: fixture.context)
        XCTAssertEqual(proposal.mutations.map(\.kinds), [[.duplicateLabel], [.unrelatedData], [.duplicateLabel, .unrelatedData]])
        XCTAssertEqual(proposal.reductions.count, 5)
        for mutation in proposal.mutations {
            XCTAssertEqual(mutation.frozen.oracleDigest, frozen.oracleDigest)
            XCTAssertEqual(mutation.frozen.plan.execution, fixture.plan.execution)
            XCTAssertEqual(mutation.frozen.plan.observations, fixture.plan.observations)
            XCTAssertEqual(mutation.frozen.plan.setup.count, 3)
            XCTAssertEqual(try AutomationFreshEntityPlanner.bindings(plan: mutation.frozen.plan).count, mutation.kinds.count + 1)
            var approval = fixture.approval; approval.approvedCaseDigest = mutation.frozen.digest
            try PlanValidator.validate(mutation.frozen.plan, approval: approval, capabilities: fixture.capabilities)
        }
    }
    func testNoContextNeverInventsDuplicateIdentityAndUncheckedExtrasAreRejected() throws {
        let fixture = try StateSearchFixture(), frozen = try AutomationFrozenCase(plan: fixture.plan)
        let proposal = try AutomationStateMutationPlanner.propose(baseline: frozen)
        XCTAssertEqual(proposal.mutations.map(\.kinds), [[.unrelatedData]])
        XCTAssertFalse(proposal.gaps.isEmpty)
        var changed = proposal.mutations[0].frozen.plan
        changed.setupChecks?.removeLast()
        XCTAssertThrowsError(try AutomationStateMutationPlanner.bindings(plan: changed))
    }
    func testApprovedSaveControlKeepsEachMutationToOneAdditionalSave() throws {
        let fixture = try StateSearchFixture()
        var plan = fixture.plan
        plan.setup[0].uiProgram?.operations[0].goal?.saveControl = .init(.label, "Save")
        let proposal = try AutomationStateMutationPlanner.propose(baseline: .init(plan: plan), context: fixture.context)
        XCTAssertEqual(proposal.mutations.map(\.kinds), [[.duplicateLabel], [.unrelatedData]])
        XCTAssertTrue(proposal.gaps.contains { $0.contains("one-save-per-step") })
        XCTAssertTrue(proposal.mutations.allSatisfy { $0.frozen.plan.setup[1].attemptTextBindings?.count == 1 })
    }
    func testMutationContextMustMatchTheReviewedTargetAndReadableProperty() throws {
        let fixture = try StateSearchFixture(), baseline = try AutomationFrozenCase(plan: fixture.plan)
        for context in [AutomationFreshEntityContext(property: "owner", selectedValue: "Wrong", protectedValue: "Personal"),
                        .init(property: "title", selectedValue: "Work", protectedValue: "Personal"),
                        .init(property: "owner", selectedValue: "Work", protectedValue: "Work")] {
            XCTAssertThrowsError(try AutomationStateMutationPlanner.propose(baseline: baseline, context: context))
        }
    }
    func testQualifiedSearchConfirmsReducesAndReloadsVerifiedHistory() async throws {
        let fixture = try StateSearchFixture(), baseline = try AutomationFrozenCase(plan: fixture.plan)
        let proposal = try AutomationStateMutationPlanner.propose(baseline: baseline, context: fixture.context)
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("state-search-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = try AutomationCaseStore(root: root), budget = try AutomationCampaignBudget(limits: .init())
        let executor = StateSearchExecutor(coordinator: .init(leases: .init(), journal: try .init(url: root.appendingPathComponent("journal.json"))), capabilities: fixture.capabilities)
        var approval = AutomationSearchApproval(run: fixture.approval, approvedDigests: Set(([baseline] + proposal.mutations.map(\.frozen)).map(\.digest)))
        var qualifications: [AutomationSearchQualification] = []
        for frozen in [baseline] + proposal.mutations.map(\.frozen) {
            _ = try await cases.freeze(frozen.plan)
            var scoped = fixture.approval; scoped.approvedCaseDigest = frozen.digest
            var evidence: [AutomationLiveRecipeEvidence] = []
            let context = AutomationRecipeContext(app: frozen.plan.app, target: frozen.plan.target, environmentID: frozen.plan.environmentID,
                catalogDigest: String(repeating: "c", count: 64), hostDigest: String(repeating: "d", count: 64), localeIdentifier: "en_GB", uiRuntimeManifestDigest: String(repeating: "e", count: 64))
            for _ in 0..<2 {
                let id = UUID().uuidString; try await budget.reserveAttempt(id: id)
                let report = try await executor.execute(frozen: frozen, approval: scoped, attemptID: id, budget: budget)
                XCTAssertTrue(report.resourcesReleased); XCTAssertTrue(report.result.subjectCompleted)
                try await cases.saveAttempt(report, for: frozen)
                qualifications.append(.init(caseDigest: frozen.digest, report: report))
                evidence.append(.init(context: context, plan: frozen.plan, approval: scoped, report: report))
            }
            approval.qualifiedFixtures[frozen.digest] = try .init(bindings: AutomationFreshEntityPlanner.bindings(plan: frozen.plan), evidence: evidence)
        }
        var report = try await AutomationFailureSearch(cases: cases).run(baseline: baseline, mutations: proposal.mutations, reductions: proposal.reductions,
            approval: approval, capabilities: fixture.capabilities, executor: executor, campaignBudget: budget)
        report.qualificationAttempts = qualifications
        XCTAssertEqual(report.qualificationAttempts?.count, 8)
        XCTAssertTrue(report.confirmations.contains(where: \.confirmed))
        XCTAssertTrue(report.attempts.contains { $0.stage == .reduction })
        XCTAssertEqual(report.finalReproduction?.matchingFailures, 5)
        let record = AutomationUIFailureSearchRecord(id: "search", runID: fixture.approval.runID, baseline: baseline, mutations: proposal.mutations, report: report, reductions: proposal.reductions)
        XCTAssertEqual(record.schemaVersion, 2)
        let archive = try AutomationUIFailureSearchArchive(caseStoreRoot: root)
        try await archive.save(record)
        let loaded = try await archive.load(id: "search"); XCTAssertEqual(loaded, record)
        var altered = report; altered.finalReproduction?.matchingFailures = 0
        XCTAssertThrowsError(try AutomationUIFailureSearchRecord(id: "tampered", runID: fixture.approval.runID, baseline: baseline, mutations: proposal.mutations, report: altered, reductions: proposal.reductions).validate())
    }
}
private struct StateSearchFixture {
    let context = AutomationFreshEntityContext(property: "owner", selectedValue: "Work", protectedValue: "Personal")
    var plan: AutomationCase
    let concretePlan: AutomationCase
    var approval: RunApproval
    var capabilities: CapabilityProfile
    init() throws {
        let app = AppIdentity(logicalID: "fixture", bundleID: "example.State", platform: "ios", productDigest: String(repeating: "a", count: 64)), target = TargetIdentity(id: "simulator", kind: .simulator)
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [.init(id: "Complete", typeName: "Complete", title: "Complete task", parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity")], parametersComplete: true, compiled: true, registered: false, executed: false)], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [], entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery", properties: ["title": "text", "completed": "bool", "owner": "text"], propertyTitles: [:])])
        capabilities = .init(records: Dictionary(uniqueKeysWithValues: ["apple.entity.query", "apple.intent.invoke", "apple.codec.entity"].map { ($0, .init(state: .available, reason: "test fixture", probeVersion: "test", evidence: [])) }))
        approval = .init(runID: "run", app: app, target: target, environmentID: "test", effects: [.observe, .navigate, .fixtureWrite], maximumActions: 30, disposable: true)
        plan = try AutomationFreshEntityPlanner.compile(catalog: catalog, actionID: "Complete", instruction: "Create and save a task", endpoint: "Tasks", namePrefix: "Invoice", nameProperty: "title", stateProperty: "completed", initialState: false, expectedState: true, approval: approval, capabilities: capabilities, localeIdentifier: "en_GB", context: context,
            saveControl: .init(.testId, "task.save"), includeProtectedRecord: false,
            nameEntry: .init(.testId, "task.title"), contextEntry: .init(.testId, "task.owner"))
        concretePlan = plan
        // Explicit archived controller proposal fixture. Synthetic receipts below exercise
        // historic mutation validation; they cannot authorize the current XCUITest driver.
        let goal = AutomationNavigationGoal(id: "create", instruction: "Create and save a task in the approved selectedContext",
            endpoint: .init(.label, "Tasks"), maximumCalls: 12, maximumActions: 30,
            minimumBindingUses: ["approvedText": 1], allowedFillBindings: ["approvedText"], selectionBindings: ["selectedContext"])
        plan.setup[0].uiProgram = .init(operations: [.init(id: "create", kind: .navigateGoal, goal: goal)],
            bindings: ["selectedContext": context.selectedValue])
        plan.provenance["ui.backend"] = "archived-controller-fixture"
        plan.provenance["ui.runtimeManifestDigest"] = String(repeating: "e", count: 64)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
    }
}
private struct StateSearchExecutor: AutomationFreshFixtureAttemptExecutor {
    let coordinator: AutomationCoordinator
    let capabilities: CapabilityProfile
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        try await coordinator.run(plan: frozen.plan, approval: approval, capabilities: capabilities, attemptID: attemptID, driver: StateSearchDriver())
    }
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget, fixtureTracker: AutomationFreshFixtureTracker) async throws -> AutomationAttemptReport {
        try await coordinator.run(plan: frozen.plan, approval: approval, capabilities: capabilities, attemptID: attemptID, driver: StateSearchDriver(), fixtureTracker: fixtureTracker)
    }
}
private actor StateSearchDriver: AutomationRouteDriver {
    var records: [String: [String: AutomationValue]] = [:]
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws {}
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        var output: AutomationValue?, observations: [AutomationObservation] = []
        if segment.kind == .ui {
            let bindings = segment.uiProgram?.bindings ?? [:]
            for name in ["approvedText", "duplicateName", "extraName"] {
                if let title = bindings[name] { records[scope.attemptId + "." + name] = ["title": .text(title), "owner": .text(bindings["selectedContext"] ?? bindings["additionalContext"] ?? "Work"), "completed": .bool(false)] }
            }
        } else if segment.kind == .systemIntent {
            guard case .entity(_, let id) = segment.hostProgram?.operations.first?.parameters["task"], records[id] != nil else { throw AutomationContractError.invalidIdentity }
            // Seeded test control: this app fails whenever unrelated/duplicate data is present.
            let completed = records.count == 1
            records[id]?["completed"] = .bool(completed)
        } else {
            let ids = segment.hostProgram?.operations.first?.queryIDs
            output = .array(records.keys.sorted().filter { ids == nil || ids!.contains($0) }.map { .object(["entity": .entity(typeID: "TaskEntity", value: $0), "properties": .object(records[$0]!)]) })
            if segment.phase == .observe { observations = [.init(id: segment.id, app: plan.app, target: plan.target, environmentID: plan.environmentID, attemptID: scope.attemptId, stepID: segment.id, route: .systemQuery, proof: .appState, value: output!)] }
        }
        return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind, dispatched: true, completed: true,
            observations: observations, verifiedOutputs: output.map { ["record": $0] }, environmentID: plan.environmentID)
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof { .init(commandsDrained: true, runnerTerminated: true) }
}
