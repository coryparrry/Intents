import XCTest
@testable import IntentsAutomationCore

final class AutomationFreshEntityPlannerTests: XCTestCase, @unchecked Sendable {
    func testEachDeterministicAttemptCreatesAndChecksItsOwnRecord() async throws {
        let fixture = try FreshRecordPlanFixture(), driver = FreshRecordPlanDriver()
        let coordinator = try fixture.coordinator()
        var identities: Set<String> = []
        for attempt in ["first", "second"] {
            let report = try await coordinator.run(plan: fixture.plan, approval: fixture.approval,
                capabilities: fixture.capabilities, attemptID: attempt, driver: driver)
            XCTAssertEqual(report.result.summary, .passed)
            let current = try AutomationFreshFixtureEvidence.recordedIdentities(report: report, plan: fixture.plan)
            XCTAssertFalse(current.isEmpty)
            XCTAssertTrue(identities.isDisjoint(with: current))
            identities.formUnion(current)
        }
        let invocations = await driver.invocations
        XCTAssertEqual(invocations, 2)
    }



    func testReusedRecordWithCurrentAttemptNameStopsBeforeSubject() async throws {
        let fixture = try FreshRecordPlanFixture(), driver = FreshRecordPlanDriver()
        let coordinator = try fixture.coordinator()
        let first = try await coordinator.run(plan: fixture.plan, approval: fixture.approval,
            capabilities: fixture.capabilities, attemptID: "first", driver: driver)
        let excluded = try AutomationFreshFixtureEvidence.recordedIdentities(report: first, plan: fixture.plan)
        await driver.setReusedID("id-first")
        let second = try await coordinator.run(plan: fixture.plan, approval: fixture.approval,
            capabilities: fixture.capabilities, attemptID: "second", driver: driver, excludedEntityIDs: excluded)
        XCTAssertEqual(second.result.summary, .invalidFixture)
        XCTAssertFalse(second.result.subjectDispatched)
        XCTAssertTrue(second.resourcesReleased)
        let names = await driver.names
        XCTAssertEqual(names.last, try AutomationAttemptText.value(prefix: "Invoice", attemptID: "second"))
        let invocations = await driver.invocations
        XCTAssertEqual(invocations, 1)
    }

    func testReproductionSeedsOriginalFailureIdentityBeforeDispatch() async throws {
        let fixture = try FreshRecordPlanFixture(), originalDriver = FreshRecordPlanDriver(mode: .noChange)
        let original = try await fixture.coordinator().run(plan: fixture.plan, approval: fixture.approval,
            capabilities: fixture.capabilities, attemptID: "original", driver: originalDriver)
        XCTAssertEqual(original.result.summary, .assertionFailed)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = try AutomationCaseStore(root: root), frozen = try await cases.freeze(fixture.plan)
        try await cases.saveAttempt(original, for: frozen)
        let driver = FreshRecordPlanDriver(); await driver.setReusedID("id-original")
        let executor = FreshRecordCampaignExecutor(fixture: fixture, driver: driver)
        let result = try await AutomationReproduction(cases: cases).run(frozen: frozen, originalAttemptID: "original",
            approval: fixture.approval, capabilities: fixture.capabilities, limits: .init(), executor: executor)
        XCTAssertEqual(result.attempts.count, 1)
        XCTAssertEqual(result.attempts.first?.result.summary, .invalidFixture)
        XCTAssertFalse(result.attempts.first?.result.subjectDispatched ?? true)
        let invocations = await driver.invocations; XCTAssertEqual(invocations, 0)
        XCTAssertNoThrow(try result.validate())
    }

    func testComparisonSharesIdentityHistoryAcrossBuilds() async throws {
        let fixture = try FreshRecordPlanFixture(), baseline = try AutomationFrozenCase(plan: fixture.plan)
        var changedApp = fixture.plan.app; changedApp.productDigest = String(repeating: "b", count: 64)
        let candidate = try AutomationFixContract.candidate(from: baseline, app: changedApp)
        var afterApproval = fixture.approval; afterApproval.runID = "after"; afterApproval.app = changedApp
        afterApproval.approvedCaseDigest = candidate.digest
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = FreshRecordPlanDriver(); await driver.setReusedID("same-record")
        let executor = FreshRecordCampaignExecutor(fixture: fixture, driver: driver)
        let result = try await AutomationFixComparison(cases: .init(root: root)).run(baseline: baseline, candidate: candidate,
            attemptsPerBuild: 1, beforeApproval: fixture.approval, afterApproval: afterApproval,
            beforeCapabilities: fixture.capabilities, afterCapabilities: fixture.capabilities, limits: .init(),
            beforeExecutor: executor, afterExecutor: executor)
        XCTAssertEqual(result.before.first?.result.summary, .passed)
        XCTAssertEqual(result.after.first?.result.summary, .invalidFixture)
        XCTAssertFalse(result.after.first?.result.subjectDispatched ?? true)
        let invocations = await driver.invocations; XCTAssertEqual(invocations, 1)
        XCTAssertNoThrow(try result.validate())
    }

    func testOrdinarySameRecordResetAllowsIdentityReuse() async throws {
        let fixture = try FreshRecordPlanFixture(), driver = FreshRecordPlanDriver()
        let bytes = try JSONEncoder().encode(fixture.plan)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        func fixedSelection(_ value: Any) -> Any {
            if let values = value as? [Any] { return values.map(fixedSelection) }
            guard var fields = value as? [String: Any] else { return value }
            if fields.removeValue(forKey: "attemptProperties") != nil {
                var properties = fields["matchingProperties"] as? [String: Any] ?? [:]
                properties["title"] = ["kind": "text", "value": "Invoice"]
                fields["matchingProperties"] = properties
            }
            if fields.removeValue(forKey: "attemptQueryPrefix") != nil { fields["queryText"] = "Invoice" }
            if fields.removeValue(forKey: "attemptTextBindings") != nil,
               var program = fields["uiProgram"] as? [String: Any] {
                program["bindings"] = ["approvedText": "Invoice"]; fields["uiProgram"] = program
            }
            return fields.mapValues(fixedSelection)
        }
        object = try XCTUnwrap(fixedSelection(object) as? [String: Any])
        let plan = try JSONDecoder().decode(AutomationCase.self, from: JSONSerialization.data(withJSONObject: object))
        var approval = fixture.approval; approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertFalse(AutomationFreshFixtureEvidence.requiresFreshIdentities(plan))
        await driver.setReusedID("same-record")
        let coordinator = try fixture.coordinator()
        for attempt in ["first", "second"] {
            let report = try await coordinator.run(plan: plan, approval: approval, capabilities: fixture.capabilities,
                attemptID: attempt, driver: driver, excludedEntityIDs: ["TaskEntity:same-record"])
            XCTAssertEqual(report.result.summary, .passed)
        }
        let invocations = await driver.invocations; XCTAssertEqual(invocations, 2)
    }

    func testAmbiguousOrWrongAttemptFixtureNeverInvokesSubject() async throws {
        for mode in [FreshRecordPlanDriver.Mode.duplicate, .wrongName] {
            let fixture = try FreshRecordPlanFixture(), driver = FreshRecordPlanDriver(mode: mode)
            let report = try await fixture.coordinator().run(plan: fixture.plan, approval: fixture.approval,
                capabilities: fixture.capabilities, attemptID: "first", driver: driver)
            XCTAssertEqual(report.result.summary, .invalidFixture); XCTAssertFalse(report.result.subjectDispatched)
            let invocations = await driver.invocations
            XCTAssertEqual(invocations, 0)
        }
    }
    func testSuccessfulInvocationCannotReplaceIndependentBusinessFailure() async throws {
        let fixture = try FreshRecordPlanFixture(), driver = FreshRecordPlanDriver(mode: .noChange)
        let report = try await fixture.coordinator().run(plan: fixture.plan, approval: fixture.approval,
            capabilities: fixture.capabilities, attemptID: "first", driver: driver)
        XCTAssertTrue(report.result.subjectCompleted); XCTAssertEqual(report.result.summary, .assertionFailed)
        XCTAssertEqual(report.result.failedObservations, ["business.state"])
    }
    func testDifferentObserverIDWithSameNameCannotPassOrImportAsPassed() async throws {
        let fixture = try FreshRecordPlanFixture(), driver = FreshRecordPlanDriver(mode: .wrongObserver)
        var report = try await fixture.coordinator().run(plan: fixture.plan, approval: fixture.approval,
            capabilities: fixture.capabilities, attemptID: "first", driver: driver)
        XCTAssertEqual(report.result.summary, .needsReview)
        report.result.summary = .passed; report.result.assessed = true; report.result.evidenceComplete = true; report.result.missingObservations = []
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: report, plan: fixture.plan))
    }
    func testDuplicateNamesUseRealOwnerPropertiesAndProtectOtherActualID() async throws {
        let fixture = try FreshRecordPlanFixture(protected: true)
        let driver = FreshRecordPlanDriver()
        let report = try await fixture.coordinator().run(plan: fixture.plan, approval: fixture.approval,
            capabilities: fixture.capabilities, attemptID: "first", driver: driver)
        XCTAssertEqual(report.result.summary, .passed)
        let observedIDs = await driver.observedIDs
        XCTAssertEqual(observedIDs, ["id-first", "protected-first"])
        XCTAssertEqual(try AutomationFreshEntityPlanner.bindings(plan: fixture.plan).count, 2)
        XCTAssertEqual(fixture.plan.setupChecks?.count, 2)
        XCTAssertEqual(fixture.plan.requirements.map(\.expected), [.bool(true), .bool(false)])
        XCTAssertEqual(fixture.plan.execution.inputBindings?.first?.uniqueEntity?.matchingProperties, ["owner": .text("Work")])
        XCTAssertEqual(fixture.plan.setup.count, 3)
        XCTAssertEqual(fixture.plan.setup[0].uiProgram?.bindings, [:])
        XCTAssertEqual(fixture.plan.setup[1].uiProgram?.bindings, [:])
        XCTAssertEqual(fixture.plan.setup[0].attemptTextBindings, ["approvedText": "Invoice"])
        XCTAssertEqual(fixture.plan.setup[0].attemptTextBindings, fixture.plan.setup[1].attemptTextBindings)
        for (segment, contextValue) in zip(fixture.plan.setup.dropLast(), ["Work", "Personal"]) {
            let program = try XCTUnwrap(segment.uiProgram)
            XCTAssertEqual(program.operations.map(\.kind), [.tap, .fillBinding, .tap, .tap, .assertEndpoint])
            XCTAssertEqual(program.operations.map(\.id), ["open", "name", "context", "save", "saved"])
            XCTAssertEqual(program.operations.map(\.locator), [.init(.testId, "task.create"), .init(.testId, "task.title"),
                .init(.label, contextValue, role: .button), .init(.testId, "task.add"), .init(.label, "Tasks")])
            XCTAssertEqual(program.operations.map(\.binding), [nil, "approvedText", nil, nil, nil])
        }
        let filledContexts = await driver.contexts
        XCTAssertEqual(filledContexts, ["Work", "Personal"])
        XCTAssertEqual(fixture.plan.requirements.count, 2)
        // Both selections deliberately have the same name; ownership disambiguates.
        XCTAssertEqual(fixture.plan.setupChecks?[0].entityProperty?.selection.attemptProperties,
                       fixture.plan.setupChecks?[1].entityProperty?.selection.attemptProperties)
    }
    func testWrongRecordAndCollateralMutationFailIndependentBusinessChecks() async throws {
        let fixture = try FreshRecordPlanFixture(protected: true)
        for mode: FreshRecordPlanDriver.Mode in [.wrongRecord, .bothChanged] {
            let driver = FreshRecordPlanDriver(mode: mode)
            let report = try await fixture.coordinator().run(plan: fixture.plan, approval: fixture.approval,
                capabilities: fixture.capabilities, attemptID: "first", driver: driver)
            XCTAssertEqual(report.result.summary, .assertionFailed)
            let invocations = await driver.invocations
            XCTAssertEqual(invocations, 1)
        }
    }
    func testProtectedOwnerAmbiguityStopsBeforeMutation() async throws {
        let fixture = try FreshRecordPlanFixture(protected: true)
        let driver = FreshRecordPlanDriver(mode: .duplicateProtected)
        let report = try await fixture.coordinator().run(plan: fixture.plan, approval: fixture.approval,
            capabilities: fixture.capabilities, attemptID: "first", driver: driver)
        XCTAssertEqual(report.result.summary, .invalidFixture)
        let invocations = await driver.invocations
        XCTAssertEqual(invocations, 0)
    }
    func testCreationUsesExactApprovedControlsAndAttemptNameBinding() throws {
        let fixture = try FreshRecordPlanFixture()
        let program = try XCTUnwrap(fixture.plan.setup.first?.uiProgram)
        XCTAssertEqual(program.operations.map(\.kind), [.tap, .fillBinding, .tap, .assertEndpoint])
        XCTAssertEqual(program.operations.map(\.id), ["open", "name", "save", "saved"])
        XCTAssertEqual(program.operations.map(\.locator), [.init(.testId, "task.create"), .init(.testId, "task.title"),
            .init(.testId, "task.add"), .init(.label, "Tasks")])
        XCTAssertEqual(program.operations.map(\.binding), [nil, "approvedText", nil, nil])
        XCTAssertEqual(program.bindings, [:], "The attempt name is supplied only when the approved case runs")
        XCTAssertEqual(fixture.plan.setup.first?.attemptTextBindings, ["approvedText": "Invoice"])
        let alreadyOpen = try FreshRecordPlanFixture(createControl: nil)
        XCTAssertEqual(alreadyOpen.plan.setup.first?.uiProgram?.operations.map(\.kind), [.fillBinding, .tap, .assertEndpoint])
    }
    func testExplicitContextFieldsFillOnlyApprovedSelectedAndProtectedBindings() async throws {
        let fixture = try FreshRecordPlanFixture(protected: true, contextEntry: .init(.testId, "task.owner"))
        for (segment, contextValue) in zip(fixture.plan.setup.dropLast(), ["Work", "Personal"]) {
            let program = try XCTUnwrap(segment.uiProgram)
            XCTAssertEqual(program.bindings, ["context": contextValue])
            XCTAssertEqual(program.operations.map(\.kind), [.tap, .fillBinding, .fillBinding, .tap, .assertEndpoint])
            XCTAssertEqual(program.operations.map(\.locator), [.init(.testId, "task.create"), .init(.testId, "task.title"),
                .init(.testId, "task.owner"), .init(.testId, "task.add"), .init(.label, "Tasks")])
            XCTAssertEqual(program.operations.map(\.binding), [nil, "approvedText", "context", nil, nil])
        }
        let driver = FreshRecordPlanDriver()
        let report = try await fixture.coordinator().run(plan: fixture.plan, approval: fixture.approval,
            capabilities: fixture.capabilities, attemptID: "first", driver: driver)
        XCTAssertEqual(report.result.summary, .passed)
        let filledContexts = await driver.contexts
        XCTAssertEqual(filledContexts, ["Work", "Personal"])
        let names = await driver.names
        XCTAssertEqual(names, [try AutomationAttemptText.value(prefix: "Invoice", attemptID: "first")])
    }
    func testMissingNameOrSaveFieldRejectsCreationBeforeExecution() throws {
        for makeFixture in [
            { try FreshRecordPlanFixture(nameEntry: nil) },
            { try FreshRecordPlanFixture(saveControl: nil) }
        ] {
            XCTAssertThrowsError(try makeFixture()) { error in
                guard let contractError = error as? AutomationContractError, case .invalidPlan(let message) = contractError else {
                    return XCTFail("Missing exact locator was not rejected: \(error)")
                }
                XCTAssertTrue(message.contains("name field and Save control"))
            }
        }
    }
    func testProtectedContextRequiresRealDistinctNonNamePropertyAndBoundedValues() throws {
        let fixture = try FreshRecordPlanFixture(protected: true)
        let entity = ApplicationSurfaceCatalog.Entity(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery",
            properties: ["title": "text", "owner": "text", "completed": "bool"], propertyTitles: [:])
        for context in [AutomationFreshEntityContext(property: "title", selectedValue: "Work", protectedValue: "Personal"),
                        .init(property: "owner", selectedValue: "Work", protectedValue: "Work"),
                        .init(property: "missing", selectedValue: "Work", protectedValue: "Personal"),
                        .init(property: "owner", selectedValue: "Work", protectedValue: " "),
                        .init(property: "owner", selectedValue: "Work", protectedValue: String(repeating: "x", count: 129))] {
            XCTAssertThrowsError(try context.validate(entity: entity, nameProperty: "title"))
        }
        var plan = fixture.plan; plan.setupChecks?.removeLast()
        XCTAssertThrowsError(try AutomationFreshEntityPlanner.bindings(plan: plan))
    }
    func testRejectsUnapprovedNamesAndSelectorReplacement() throws {
        let fixture = try FreshRecordPlanFixture()
        var approval = fixture.approval; approval.disposable = false
        XCTAssertThrowsError(try PlanValidator.validate(fixture.plan, approval: approval, capabilities: fixture.capabilities))
        var plan = fixture.plan; plan.setup[0].uiProgram?.bindings["approvedText"] = "replacement"
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: fixture.approval, capabilities: fixture.capabilities))
        plan = fixture.plan; plan.observations[0].hostProgram?.operations[0].queryText = "replacement"
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: fixture.approval, capabilities: fixture.capabilities))
        plan = fixture.plan; plan.execution.inputBindings?[0].uniqueEntity?.attemptProperties = ["title": "Other"]
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: fixture.approval, capabilities: fixture.capabilities))
        XCTAssertThrowsError(try AutomationAttemptText.value(prefix: "line\nbreak", attemptID: "first"))
    }
    func testOwnerStepsCannotUseDifferentAttemptNamesOrBorrowOriginalApproval() throws {
        let fixture = try FreshRecordPlanFixture(protected: true)
        var changed = fixture.plan
        changed.setup[1].attemptTextBindings = ["approvedText": "Different"]
        XCTAssertThrowsError(try AutomationFreshEntityPlanner.bindings(plan: changed))
        XCTAssertThrowsError(try PlanValidator.validate(changed, approval: fixture.approval, capabilities: fixture.capabilities))
        changed = fixture.plan; changed.setup.remove(at: 1)
        XCTAssertThrowsError(try PlanValidator.validate(changed, approval: fixture.approval, capabilities: fixture.capabilities))
    }
}
private struct FreshRecordPlanFixture {
    var plan: AutomationCase
    var approval: RunApproval
    var capabilities: CapabilityProfile
    init(protected: Bool = false,
         createControl: AutomationUIProgram.Locator? = .init(.testId, "task.create"),
         nameEntry: AutomationUIProgram.Locator? = .init(.testId, "task.title"),
         saveControl: AutomationUIProgram.Locator? = .init(.testId, "task.add"),
         contextEntry: AutomationUIProgram.Locator? = nil) throws {
        let app = AppIdentity(logicalID: "fixture", bundleID: "example.Fixture", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "simulator", kind: .simulator)
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [.init(id: "Complete", typeName: "Complete", title: "Complete task",
            parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity")], parametersComplete: true, compiled: true, registered: false, executed: false)],
            systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [], entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery", properties: protected ? ["title": "text", "completed": "bool", "owner": "text"] : ["title": "text", "completed": "bool"], propertyTitles: [:])])
        capabilities = .init(records: Dictionary(uniqueKeysWithValues: ["apple.entity.query", "apple.intent.invoke", "apple.codec.entity"].map { ($0, .init(state: .available, reason: "test", probeVersion: "test", evidence: [])) }))
        approval = .init(runID: "run", app: app, target: target, environmentID: "test", effects: [.observe, .navigate, .fixtureWrite], maximumActions: 30, disposable: true)
        plan = try AutomationFreshEntityPlanner.compile(catalog: catalog, actionID: "Complete", instruction: "Create a task using approvedText and save it", endpoint: "Tasks", namePrefix: "Invoice", nameProperty: "title", stateProperty: "completed", initialState: false, expectedState: true, approval: approval, capabilities: capabilities, localeIdentifier: "en_GB", context: protected ? .init(property: "owner", selectedValue: "Work", protectedValue: "Personal") : nil, saveControl: saveControl, createControl: createControl, nameEntry: nameEntry, contextEntry: protected ? contextEntry : nil)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
    }
    func coordinator() throws -> AutomationCoordinator {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return .init(leases: try .init(storeURL: root.appendingPathComponent("leases.json")), journal: try .init(url: root.appendingPathComponent("journal.json")))
    }
}
actor FreshRecordPlanDriver: AutomationRouteDriver {
    enum Mode: Sendable { case normal, duplicate, wrongName, noChange, wrongObserver, wrongRecord, bothChanged, duplicateProtected }
    let mode: Mode
    var names: [String] = [], observedIDs: [String] = [], contexts: [String] = []
    var invocations = 0
    var reusedID: String?
    var title = "", entityID = "", completed = false
    var selectedContext: String?, protectedContext: String?, protectedID = "", protectedCompleted = false
    init(mode: Mode = .normal) { self.mode = mode }
    func setReusedID(_ value: String) { reusedID = value }
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws { }
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        var output: AutomationValue?, observations: [AutomationObservation] = []
        switch segment.id {
        case "fixture.create":
            title = segment.uiProgram?.bindings["approvedText"] ?? ""; names.append(title)
            entityID = reusedID ?? "id-" + scope.attemptId; completed = false
            selectedContext = segment.uiProgram?.bindings["context"] ?? segment.uiProgram?.operations.first(where: { $0.id == "context" })?.locator?.value; protectedContext = nil
            if let selectedContext { contexts.append(selectedContext) }
            protectedID = "protected-" + scope.attemptId; protectedCompleted = false
            XCTAssertFalse(title.isEmpty); XCTAssertNil(segment.attemptTextBindings)
        case "fixture.create.protected":
            XCTAssertEqual(segment.uiProgram?.bindings["approvedText"], title)
            protectedContext = segment.uiProgram?.bindings["context"] ?? segment.uiProgram?.operations.first(where: { $0.id == "context" })?.locator?.value
            if let protectedContext { contexts.append(protectedContext) }
            XCTAssertNil(segment.attemptTextBindings)
        case "fixture.lookup":
            XCTAssertEqual(segment.hostProgram?.operations.first?.queryText, title)
            output = records()
        case "subject":
            XCTAssertEqual(segment.hostProgram?.operations.first?.parameters["task"], .entity(typeID: "TaskEntity", value: entityID))
            invocations += 1; completed = mode != .noChange && mode != .wrongRecord
            protectedCompleted = mode == .wrongRecord || mode == .bothChanged
        case "state", "protected.state":
            let id = segment.id == "state" ? entityID : protectedID
            XCTAssertEqual(segment.hostProgram?.operations.first?.queryIDs, [id]); observedIDs.append(id)
            output = mode == .wrongObserver ? .array([.object(["entity": .entity(typeID: "TaskEntity", value: "foreign-id"), "properties": .object(["title": .text(title), "completed": .bool(true)])])]) : records(ids: [id])
            observations = [.init(id: segment.id, app: plan.app, target: plan.target, environmentID: plan.environmentID,
                attemptID: scope.attemptId, stepID: segment.id, route: .systemQuery, proof: .appState, value: output!)]
        default: XCTFail("Unexpected segment")
        }
        return .init(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind,
            dispatched: true, completed: true, observations: observations, verifiedOutputs: output.map { ["record": $0] }, environmentID: plan.environmentID)
    }
    func records(ids: [String]? = nil) -> AutomationValue {
        var properties: AutomationValue = .object(["title": .text(mode == .wrongName ? "foreign" : title), "completed": .bool(completed)])
        if let selectedContext, case .object(var fields) = properties { fields["owner"] = .text(selectedContext); properties = .object(fields) }
        var records: [AutomationValue] = [.object(["entity": .entity(typeID: "TaskEntity", value: entityID), "properties": properties])]
        if mode == .duplicate { records.append(.object(["entity": .entity(typeID: "TaskEntity", value: "other"), "properties": properties])) }
        if let protectedContext {
            let fields: AutomationValue = .object(["title": .text(title), "owner": .text(protectedContext), "completed": .bool(protectedCompleted)])
            records.append(.object(["entity": .entity(typeID: "TaskEntity", value: protectedID), "properties": fields]))
            if mode == .duplicateProtected { records.append(.object(["entity": .entity(typeID: "TaskEntity", value: "duplicate-protected"), "properties": fields])) }
        }
        if let ids { records = records.filter { record in
            guard case .object(let fields) = record, case .entity(_, let id) = fields["entity"] else { return false }; return ids.contains(id)
        } }
        return .array(records)
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof { .init(commandsDrained: true, runnerTerminated: true) }
}

private struct FreshRecordCampaignExecutor: AutomationCampaignAttemptExecutor {
    let fixture: FreshRecordPlanFixture
    let driver: FreshRecordPlanDriver
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                 budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        try await execute(frozen: frozen, approval: approval, attemptID: attemptID, budget: budget, excludedEntityIDs: [])
    }
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                 budget: AutomationCampaignBudget, excludedEntityIDs: Set<String>) async throws -> AutomationAttemptReport {
        try await fixture.coordinator().run(plan: frozen.plan, approval: approval, capabilities: fixture.capabilities,
            attemptID: attemptID, driver: driver, excludedEntityIDs: excludedEntityIDs)
    }
}
