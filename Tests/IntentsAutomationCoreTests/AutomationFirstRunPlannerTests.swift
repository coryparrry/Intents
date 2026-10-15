import XCTest
@testable import IntentsAutomationCore

final class AutomationFirstRunPlannerTests: XCTestCase {
    private let app = AppIdentity(logicalID: "selected", bundleID: "example.FirstRun", platform: "ios", productDigest: String(repeating: "a", count: 64))
    private let target = TargetIdentity(id: "00000000-0000-0000-0000-000000000001", kind: .simulator)
    private var approval: RunApproval { .init(runID: "review", app: app, target: target, environmentID: "owned", effects: [.observe, .navigate], maximumActions: 30, disposable: true) }
    private var capabilities: CapabilityProfile { .init(records: ["apple.intent.invoke": .init(state: .available, reason: "fixture host", probeVersion: "test", evidence: ["host"])]) }
    private func catalog(_ actions: [ApplicationSurfaceCatalog.SystemAction] = []) -> ApplicationSurfaceCatalog {
        .init(app: app, systemActions: actions, systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
    }
    private func action(_ id: String, parameters: [ApplicationSurfaceCatalog.SystemAction.Parameter] = []) -> ApplicationSurfaceCatalog.SystemAction {
        .init(id: id, typeName: id, title: id, parameters: parameters, parametersComplete: true, compiled: true, registered: false, executed: false, resultFamily: "noValue")
    }
    func testNativeMacFirstRunRetainsActionsAndReportsUnpreparedUI() throws {
        var nativeApp = app; nativeApp.platform = "macos"; nativeApp.productDigestVersion = 2
        nativeApp.canonicalBundlePath = "/private/tmp/FirstRun.app"
        let nativeTarget = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "first-run-session")
        let approved = RunApproval(runID: "review", app: nativeApp, target: nativeTarget, environmentID: "owned",
            effects: [.observe, .navigate], maximumActions: 30, disposable: true)
        let surface = ApplicationSurfaceCatalog(app: nativeApp, systemActions: [action("Independent")],
            systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        let proposal = try AutomationFirstRunPlanner.compile(catalog: surface, appName: "Example", approval: approved,
            capabilities: capabilities, includeActions: true, includeUI: true, localeIdentifier: "en_GB")
        XCTAssertTrue(proposal.plans.contains { $0.execution.operation == "Independent" })
        XCTAssertFalse(proposal.plans.contains { $0.execution.uiProgram != nil })
        XCTAssertTrue(proposal.gaps.contains { $0.contains("associated UI host") })
    }
    func testInvalidApprovedInputDoesNotFallBackToADefaultOrDiscardIndependentChecks() throws {
        var parameter = ApplicationSurfaceCatalog.SystemAction.Parameter(name: "enabled", family: "bool", optional: false)
        parameter.defaultValue = .bool(true)
        let catalog = catalog([action("Invalid", parameters: [parameter]), action("Independent")])
        var supplied = try evidence(catalog)
        supplied.unavailableActions = ["Invalid": "The supplied Boolean value is invalid"]
        let proposal = try compile(catalog, evidence: supplied, includeUI: true)
        XCTAssertEqual(proposal.plans.count, 2)
        XCTAssertTrue(proposal.plans.contains { $0.execution.kind == .observeOnly })
        XCTAssertTrue(proposal.plans.contains { $0.execution.operation == "Independent" })
        XCTAssertFalse(proposal.plans.contains { $0.execution.operation == "Invalid" })
        XCTAssertTrue(proposal.gaps.contains { $0.contains("Boolean value is invalid") })
    }
    func testSavedNavigationGoalCannotExceedTheFirstCampaignReadbackReservation() throws {
        let catalog = catalog()
        var plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Open the selected view",
            endpoint: "Complete", approvedText: "", expectedVisibleText: "", approval: approval, localeIdentifier: "en_GB")
        let runtimeDigest = String(repeating: "d", count: 64)
        plan.provenance["catalog"] = try AutomationRecipeContext.catalogDigest(catalog)
        plan.provenance["ui.runtimeManifestDigest"] = runtimeDigest
        var supplied = try evidence(catalog)
        supplied.runtimeContext = .init(app: app, target: target, environmentID: approval.environmentID,
            catalogDigest: supplied.catalogDigest, hostDigest: String(repeating: "b", count: 64), localeIdentifier: "en_GB",
            uiRuntimeManifestDigest: runtimeDigest)
        supplied.savedCases = [try AutomationFrozenCase(plan: plan)]
        let proposal = try compile(catalog, evidence: supplied, includeUI: true)
        XCTAssertEqual(proposal.plans.count, 1)
        XCTAssertEqual(proposal.plans.first?.execution.kind, .observeOnly)
        XCTAssertTrue(proposal.gaps.contains { $0.contains("37 operations") })
        plan.execution.uiProgram?.operations[0].goal?.maximumCalls = 9
        plan.execution.uiProgram?.operations[0].goal?.maximumActions = 15
        supplied.savedCases = [try AutomationFrozenCase(plan: plan)]
        let shorter = try compile(catalog, evidence: supplied, includeUI: true)
        XCTAssertEqual(shorter.plans.count, 1)
        XCTAssertEqual(shorter.plans.first?.execution.kind, .observeOnly)
        XCTAssertTrue(shorter.gaps.contains { $0.contains("28 operations") })
    }
    func testInitialObservationIsReadOnlyAndNeverClaimsBusinessPass() throws {
        let proposal = try AutomationFirstRunPlanner.compile(catalog: catalog(), appName: "Example", approval: approval, capabilities: capabilities, includeActions: false, includeUI: true, localeIdentifier: "en_GB")
        let plan = try XCTUnwrap(proposal.plans.first)
        XCTAssertEqual(plan.execution.kind, .observeOnly); XCTAssertTrue(plan.requirements.isEmpty)
        XCTAssertEqual(plan.execution.uiProgram?.operations.map(\.kind), [.locate])
        XCTAssertEqual(plan.budget.controllerCalls, 0)
        XCTAssertEqual(AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: []).summary, .executedUnassessed)
    }
    func testDeclaredDefaultsAndOmissionsAreUsedButMissingInputsAreNeverInvented() throws {
        var defaultInput = ApplicationSurfaceCatalog.SystemAction.Parameter(name: "enabled", family: "bool", optional: false)
        defaultInput.defaultValue = .bool(true)
        let actions = [action("Defaults", parameters: [defaultInput]), action("Missing", parameters: [.init(name: "record", family: "entity", optional: false)]), action("Optional", parameters: [.init(name: "text", family: "text", optional: true)])]
        let proposal = try AutomationFirstRunPlanner.compile(catalog: catalog(actions), appName: "Example", approval: approval, capabilities: capabilities, includeActions: true, includeUI: false, localeIdentifier: "en_GB")
        XCTAssertEqual(proposal.plans.map(\.execution.operation), ["Defaults", "Optional"])
        XCTAssertEqual(proposal.plans[0].execution.inputs["enabled"], .bool(true))
        XCTAssertEqual(proposal.plans[1].execution.inputs["text"], .omission)
        XCTAssertTrue(proposal.gaps.contains { $0.contains("Missing") && $0.contains("record") })
    }
    func testCampaignIsDeterministicAndLimitedToTwentyIncludingUI() throws {
        let actions = (0..<30).reversed().map { action("Action\($0)") }
        let proposal = try AutomationFirstRunPlanner.compile(catalog: catalog(actions), appName: "Example", approval: approval, capabilities: capabilities, includeActions: true, includeUI: true, localeIdentifier: "en_GB")
        XCTAssertEqual(proposal.plans.count, 19)
        XCTAssertEqual(proposal.plans.dropFirst().map(\.execution.operation), actions.map(\.id).sorted().prefix(18).map { $0 })
        XCTAssertEqual(2 + proposal.plans.dropFirst().count, 20, "Activation and readback consume the same shared operation budget as actions")
        XCTAssertTrue(proposal.gaps.contains { $0.contains("20") })
    }
    func testUnsupportedDeclaredActionDoesNotDiscardIndependentObservation() throws {
        var bad = action("Malformed")
        bad.resultFamily = "unsupported-result"
        let proposal = try AutomationFirstRunPlanner.compile(catalog: catalog([bad]), appName: "Example", approval: approval, capabilities: capabilities, includeActions: true, includeUI: true, localeIdentifier: "en_GB")
        XCTAssertEqual(proposal.plans.count, 1)
        XCTAssertEqual(proposal.plans[0].execution.kind, .observeOnly)
        XCTAssertFalse(proposal.gaps.isEmpty)
    }
    func testObservationRouteRejectsWritesAndControllerNavigation() throws {
        let proposal = try AutomationFirstRunPlanner.compile(catalog: catalog(), appName: "Example", approval: approval, capabilities: capabilities, includeActions: false, includeUI: true, localeIdentifier: "en_GB")
        for operation in [AutomationUIProgram.Operation(id: "tap", kind: .tap, locator: .init(.label, "Delete")), .init(id: "scroll", kind: .scroll, direction: "down")] {
            var changed = proposal.plans[0]; changed.execution.uiProgram?.operations = [operation]
            XCTAssertThrowsError(try PlanValidator.validate(changed, approval: approval, capabilities: capabilities, purpose: .review))
        }
    }
    func testActionsRequireExplicitInclusionAndNoAvailablePathRemainsAssessment() throws {
        let proposal = try AutomationFirstRunPlanner.compile(catalog: catalog([action("DeleteEverything")]), appName: "Example", approval: approval, capabilities: capabilities, includeActions: false, includeUI: false, localeIdentifier: "en_GB")
        XCTAssertTrue(proposal.plans.isEmpty); XCTAssertTrue(proposal.gaps.contains { $0.contains("not a test pass") })
    }

    private func evidence(_ catalog: ApplicationSurfaceCatalog, inputs: [String: [String: AutomationActionInput]] = [:]) throws -> AutomationFirstRunInputEvidence {
        .init(app: app, target: target, environmentID: approval.environmentID,
              catalogDigest: try AutomationRecipeContext.catalogDigest(catalog), inputs: inputs)
    }
    private func compile(_ catalog: ApplicationSurfaceCatalog, evidence: AutomationFirstRunInputEvidence? = nil,
                         approval: RunApproval? = nil, capabilities: CapabilityProfile? = nil,
                         includeUI: Bool = false) throws -> AutomationFirstRunProposal {
        try AutomationFirstRunPlanner.compile(catalog: catalog, appName: "Example", approval: approval ?? self.approval,
            capabilities: capabilities ?? self.capabilities, includeActions: true, includeUI: includeUI,
            localeIdentifier: "en_GB", inputEvidence: evidence)
    }
    func testObservedEnumCasesProduceDeterministicBoundedCoverage() throws {
        var catalog = catalog([action("Choose", parameters: [.init(name: "mode", family: "enum", optional: false, typeID: "Mode")])])
        catalog.enumerations = [.init(typeID: "Mode", title: "Mode", cases: (0..<25).reversed().map { .init(id: String(format: "case%02d", $0), title: "Observed case") })]
        let proposal = try compile(catalog)
        XCTAssertEqual(proposal.plans.count, 20)
        XCTAssertEqual(proposal.plans.map { $0.execution.inputs["mode"] }, (0..<20).map { .enumeration(typeID: "Mode", value: String(format: "case%02d", $0)) })
        XCTAssertEqual(Set(proposal.plans.map(\.id)).count, 20)
        XCTAssertEqual(proposal.plans.map(\.id), try compile(catalog).plans.map(\.id))
        XCTAssertTrue(proposal.gaps.contains { $0.contains("enum combinations") })
        XCTAssertTrue(proposal.plans.allSatisfy { $0.requirements.isEmpty && $0.budget.attempts == 1 })
        XCTAssertTrue(proposal.plans.allSatisfy { $0.execution.requiredCapabilities.contains("apple.codec.enum") })
        var executionApproval = approval
        executionApproval.approvedCaseDigest = try AutomationFrozenCase.planDigest(proposal.plans[0])
        XCTAssertThrowsError(try PlanValidator.validate(proposal.plans[0], approval: executionApproval, capabilities: capabilities),
            "Review coverage never grants a missing runtime codec capability")
    }
    func testEnumCrossProductIsBoundedAndExplicitSelectionIsRespected() throws {
        var catalog = catalog([action("Choose", parameters: [
            .init(name: "second", family: "enum", optional: false, typeID: "Mode"),
            .init(name: "first", family: "enum", optional: false, typeID: "Mode")])])
        catalog.enumerations = [.init(typeID: "Mode", title: "Mode", cases: [.init(id: "b", title: "B"), .init(id: "a", title: "A")])]
        XCTAssertEqual(try compile(catalog).plans.map { $0.execution.inputs }, [
            ["first": .enumeration(typeID: "Mode", value: "a"), "second": .enumeration(typeID: "Mode", value: "a")],
            ["first": .enumeration(typeID: "Mode", value: "a"), "second": .enumeration(typeID: "Mode", value: "b")],
            ["first": .enumeration(typeID: "Mode", value: "b"), "second": .enumeration(typeID: "Mode", value: "a")],
            ["first": .enumeration(typeID: "Mode", value: "b"), "second": .enumeration(typeID: "Mode", value: "b")]])
        let supplied = try evidence(catalog, inputs: ["Choose": ["first": .init(value: .enumeration(typeID: "Mode", value: "b"), origin: .userChoice, evidence: "Approved exact case")]])
        let explicit = try compile(catalog, evidence: supplied)
        XCTAssertEqual(explicit.plans.count, 2)
        XCTAssertTrue(explicit.plans.allSatisfy { $0.execution.inputs["first"] == .enumeration(typeID: "Mode", value: "b") })
    }
    func testMissingOrAmbiguousEnumMetadataRetainsGapAndIndependentView() throws {
        var catalog = catalog([action("Choose", parameters: [.init(name: "mode", family: "enum", optional: false, typeID: "Mode")])])
        for declarations: [ApplicationSurfaceCatalog.Enumeration] in [[], [.init(typeID: "Mode", title: "Mode", cases: [.init(id: "a", title: "A"), .init(id: "a", title: "Duplicate")])]] {
            catalog.enumerations = declarations
            let proposal = try compile(catalog, includeUI: true)
            XCTAssertEqual(proposal.plans.count, 1)
            XCTAssertTrue(proposal.gaps.contains { $0.contains("unambiguous observed enum") })
        }
    }
    func testRequiredRealInputsAreUsedAndNeverReplacedByInventedValues() throws {
        let catalog = catalog([action("Record", parameters: [.init(name: "name", family: "text", optional: false)])])
        let supplied = try evidence(catalog, inputs: ["Record": ["name": .init(value: .text("Actual approved fixture"), origin: .approvedExample, evidence: "Verified fixture in the selected owned environment")]])
        let proposal = try compile(catalog, evidence: supplied)
        XCTAssertEqual(proposal.plans.count, 1)
        XCTAssertEqual(proposal.plans[0].execution.inputs["name"], .text("Actual approved fixture"))
        XCTAssertTrue(proposal.plans[0].requirements.isEmpty)
        XCTAssertEqual(try compile(catalog).plans.count, 0)
    }
    func testStaleInputScopeRetainsObservationAndReportsExactMissingInput() throws {
        let catalog = catalog([action("Record", parameters: [.init(name: "name", family: "text", optional: false)])])
        for mutation in 0..<4 {
            var supplied = try evidence(catalog, inputs: ["Record": ["name": .init(value: .text("Real approved value"), origin: .userChoice, evidence: "Explicit approval")]])
            switch mutation {
            case 0: supplied.environmentID = "foreign"
            case 1: supplied.target = .init(id: "foreign", kind: .simulator)
            case 2: supplied.catalogDigest = String(repeating: "f", count: 64)
            default: supplied.app.productDigest = String(repeating: "b", count: 64)
            }
            let proposal = try compile(catalog, evidence: supplied, includeUI: true)
            XCTAssertEqual(proposal.plans.count, 1)
            XCTAssertEqual(proposal.plans[0].execution.kind, .observeOnly)
            XCTAssertTrue(proposal.gaps.contains { $0.contains("different app build") })
            XCTAssertTrue(proposal.gaps.contains { $0.contains("No trusted input for name") })
        }
    }
    func testWrongCodecEmptyEvidenceAndForgedEntityIDsRemainGaps() throws {
        let catalog = catalog([action("Record", parameters: [.init(name: "name", family: "text", optional: false)])])
        for input in [AutomationActionInput(value: .bool(true), origin: .userChoice, evidence: "Approval"), .init(value: .text("Not grounded"), origin: .approvedExample, evidence: " "), .init(value: .entity(typeID: "Task", value: "invented"), origin: .verifiedQuery, evidence: "Claimed query")] {
            let proposal = try compile(catalog, evidence: evidence(catalog, inputs: ["Record": ["name": input]]), includeUI: true)
            XCTAssertEqual(proposal.plans.count, 1)
            XCTAssertFalse(proposal.gaps.isEmpty)
        }
        let entityCatalog = self.catalog([action("Record", parameters: [.init(name: "task", family: "entity", optional: false, typeID: "Task")])])
        let forged = try evidence(entityCatalog, inputs: ["Record": ["task": .init(value: .entity(typeID: "Task", value: "invented"), origin: .verifiedQuery, evidence: "Claimed query")]])
        XCTAssertTrue(try compile(entityCatalog, evidence: forged).plans.isEmpty)
    }
    func testScopedApprovalLimitIncludesInitialActivationAndRead() throws {
        let catalog = catalog((0..<5).map { action("Action\($0)") })
        var approval = approval; approval.maximumActions = 3
        let proposal = try compile(catalog, approval: approval, includeUI: true)
        XCTAssertEqual(proposal.plans.count, 2)
        XCTAssertTrue(proposal.gaps.contains { $0.contains("3 approved operations") })
        approval.maximumActions = 1
        let minimal = try compile(catalog, approval: approval, includeUI: true)
        XCTAssertEqual(minimal.plans.count, 1)
        XCTAssertEqual(minimal.plans.first?.execution.kind, .systemIntent)
        XCTAssertTrue(minimal.gaps.contains { $0.contains("activation and readback") })
    }
    private func context(_ catalog: ApplicationSurfaceCatalog) throws -> AutomationRecipeContext {
        .init(app: app, target: target, environmentID: approval.environmentID,
            catalogDigest: try AutomationRecipeContext.catalogDigest(catalog), hostDigest: String(repeating: "c", count: 64),
            localeIdentifier: "en_GB", uiRuntimeManifestDigest: String(repeating: "d", count: 64))
    }
    func testCompatibleSavedCasesKeepTheirAssertionsAndBudgetPriority() throws {
        let catalog = catalog()
        var supplied = try evidence(catalog); supplied.runtimeContext = try context(catalog)
        var saved = try XCTUnwrap(compile(catalog, evidence: supplied, includeUI: true).plans.first)
        var observer = saved.execution; observer.id = "independent"; observer.kind = .ui; observer.phase = .observe
        observer.uiProgram = .init(operations: [.init(id: "destination", kind: .observeProperty, locator: .init(.label, "Actual destination"), property: "text")])
        saved.observations = [observer]
        saved.requirements = [.init(observationID: "independent", expected: .text("Actual destination"), proof: .visibleState, justification: "Previously approved exact app navigation requirement")]
        let frozen = try AutomationFrozenCase(plan: saved)
        supplied.savedCases = [frozen, frozen]
        var approval = approval; approval.maximumActions = 4
        let proposal = try compile(catalog, evidence: supplied, approval: approval, includeUI: true)
        XCTAssertEqual(proposal.plans, [saved], "Saved assertion contracts stay immutable and duplicate digests run once")
        XCTAssertEqual(proposal.plans.first?.requirements, saved.requirements)
        XCTAssertTrue(proposal.gaps.contains { $0.contains("activation and readback") })
    }
    func testSavedHostCaseIsDeduplicatedAndHostDriftRetainsGap() throws {
        let catalog = catalog([action("Record")])
        var supplied = try evidence(catalog); supplied.runtimeContext = try context(catalog)
        let saved = try XCTUnwrap(compile(catalog, evidence: supplied).plans.first)
        supplied.savedCases = [try AutomationFrozenCase(plan: saved)]
        XCTAssertEqual(try compile(catalog, evidence: supplied).plans, [saved])
        supplied.runtimeContext = .init(app: app, target: target, environmentID: approval.environmentID,
            catalogDigest: supplied.catalogDigest, hostDigest: String(repeating: "f", count: 64), localeIdentifier: "en_GB")
        let drifted = try compile(catalog, evidence: supplied)
        XCTAssertEqual(drifted.plans.count, 1, "Current independent coverage remains available")
        XCTAssertNotEqual(drifted.plans[0], saved)
        XCTAssertTrue(drifted.gaps.contains { $0.contains("different or unverified host build") })
    }
    func testSavedCasesRejectStaleEffectsAndRuntimeWithoutLosingView() throws {
        let catalog = catalog()
        var supplied = try evidence(catalog); supplied.runtimeContext = try context(catalog)
        let original = try XCTUnwrap(compile(catalog, evidence: supplied, includeUI: true).plans.first)
        for mutation in 0..<4 {
            var saved = original
            switch mutation {
            case 0: saved.environmentID = "foreign"
            case 1: saved.execution.effects.insert(.externalWrite)
            case 2: saved.provenance["ui.runtimeManifestDigest"] = String(repeating: "f", count: 64)
            default: saved.provenance["catalog"] = nil
            }
            supplied.savedCases = [try AutomationFrozenCase(plan: saved)]
            let proposal = try compile(catalog, evidence: supplied, includeUI: true)
            XCTAssertEqual(proposal.plans.count, 1)
            XCTAssertEqual(proposal.plans[0], original)
            XCTAssertTrue(proposal.gaps.contains { $0.contains("Saved case") })
        }
    }
    private func qualifiedRecipe(_ catalog: ApplicationSurfaceCatalog) throws -> AutomationFirstRunRecipeInput {
        let context = try context(catalog)
        var create = AutomationSegment(id: "create", kind: .ui, phase: .setup, operation: "Approved record creation",
            effects: [.observe, .navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        create.uiProgram = .init(operations: [.init(id: "open", kind: .tap, locator: .init(.testId, "add")),
            .init(id: "fill", kind: .fillBinding, locator: .init(.testId, "name"), binding: "name"),
            .init(id: "save", kind: .tap, locator: .init(.testId, "save"))], bindings: ["name": "Actual approved fixture"])
        var verifier = AutomationSegment(id: "verify", kind: .ui, phase: .observe, operation: "Independent fixture label read",
            effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        verifier.uiProgram = .init(operations: [.init(id: "title", kind: .observeProperty, locator: .init(.label, "Actual approved fixture"), property: "text")])
        var subject = verifier; subject.id = "subject"; subject.phase = .subject
        var plan = AutomationCase(id: "qualification", app: app, target: target, environmentID: context.environmentID,
            execution: subject, setup: [create], observations: [verifier])
        plan.provenance["ui.locale"] = context.localeIdentifier
        var approval = self.approval; approval.effects.insert(.fixtureWrite)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let receipts = [create, subject, verifier].enumerated().map { index, segment in
            AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: "qualified", segmentID: segment.id, leaseGeneration: index + 1),
                app: app, target: target, segmentID: segment.id, route: .ui, dispatched: true, completed: true,
                observations: segment.id == "verify" ? [.init(id: "verify", app: app, target: target, environmentID: context.environmentID,
                    attemptID: "qualified", stepID: "verify", route: .ui, proof: .visibleState, value: .text("Actual approved fixture"))] : [],
                verifiedOutputs: segment.id == "verify" ? ["title": .text("Actual approved fixture")] : nil, environmentID: context.environmentID)
        }
        let report = AutomationAttemptReport(attemptID: "qualified", result: AutomationAssessment.assess(plan: plan, attemptID: "qualified",
            subjectDispatched: true, subjectCompleted: true, observations: []), receipts: receipts, resourcesReleased: true)
        let recipe = try AutomationQualifiedSetupRecipe(candidate: .init(id: "approved-creation", producerSegmentID: "create", verifierSegmentID: "verify", fillBinding: "name", outputID: "title"),
            live: .init(context: context, plan: plan, approval: approval, report: report))
        return .init(recipe: recipe, context: context, text: "Fresh approved fixture", consumingParameter: "name")
    }
    func testQualifiedRecipeRequiresCurrentContextFreshTextAndApprovedEffects() throws {
        let catalog = catalog([action("Record", parameters: [.init(name: "name", family: "text", optional: false)])])
        var supplied = try evidence(catalog); supplied.runtimeContext = try context(catalog)
        supplied.recipes["Record"] = try qualifiedRecipe(catalog)
        var approval = approval; approval.effects.insert(.fixtureWrite); approval.maximumActions = 11
        let plan = try XCTUnwrap(compile(catalog, evidence: supplied, approval: approval).plans.first)
        XCTAssertEqual(plan.setup[0].uiProgram?.bindings["name"], "Fresh approved fixture")
        XCTAssertEqual(plan.execution.inputBindings?.first?.producerSegmentID, "recipe.verify")
        XCTAssertNil(plan.execution.inputs["name"])
        XCTAssertTrue(plan.requirements.isEmpty)
        approval.maximumActions = 10
        let bounded = try compile(catalog, evidence: supplied, approval: approval)
        XCTAssertTrue(bounded.plans.isEmpty)
        XCTAssertTrue(bounded.gaps.contains { $0.contains("need 11 operations") })
        approval.maximumActions = 20; approval.effects.remove(.fixtureWrite)
        XCTAssertTrue(try compile(catalog, evidence: supplied, approval: approval).plans.isEmpty)
        approval.effects.insert(.fixtureWrite)
        supplied.runtimeContext = nil
        XCTAssertTrue(try compile(catalog, evidence: supplied, approval: approval).plans.isEmpty)
        supplied.runtimeContext = try context(catalog); supplied.recipes["Record"]?.text = ""
        XCTAssertTrue(try compile(catalog, evidence: supplied, approval: approval).plans.isEmpty)
    }
    #if os(macOS)
    func testRealEntityChoicesCompileFreshLookupAndRespectItsReadbackBudget() throws {
        var catalog = catalog([action("Record", parameters: [.init(name: "task", family: "entity", optional: false, typeID: "Task")])])
        catalog.entities = [.init(typeID: "Task", title: "Task", queryIdentifier: "TaskQuery", properties: ["title": "text"], propertyTitles: [:])]
        var supplied = try evidence(catalog)
        supplied.entitySelections = ["Record": ["task": .init(id: "actual-app-id", typeID: "Task", properties: ["title": .text("Actual record")],
            sourceAttemptID: "query-attempt", app: app, target: target, environmentID: approval.environmentID,
            catalogDigest: try AutomationRecipeContext.catalogDigest(catalog))]]
        var capabilities = capabilities
        capabilities.records["apple.entity.query"] = .init(state: .available, reason: "Real query runner", probeVersion: "test", evidence: ["query-attempt"])
        let proposal = try compile(catalog, evidence: supplied, capabilities: capabilities)
        let plan = try XCTUnwrap(proposal.plans.first)
        XCTAssertEqual(plan.setup.first?.hostProgram?.operations.first?.queryIDs, ["actual-app-id"])
        XCTAssertEqual(plan.execution.inputBindings?.first?.name, "task")
        XCTAssertNil(plan.execution.inputs["task"])
        XCTAssertEqual(plan.observations.count, 1)
        XCTAssertTrue(plan.requirements.isEmpty)
        var approval = approval; approval.maximumActions = 2
        let limited = try compile(catalog, evidence: supplied, approval: approval, capabilities: capabilities)
        XCTAssertTrue(limited.plans.isEmpty)
        XCTAssertTrue(limited.gaps.contains { $0.contains("need 3 operations") })
        var stale = supplied
        stale.entitySelections["Record"]?["task"] = .init(id: "actual-app-id", typeID: "Task", properties: ["title": .text("Actual record")],
            sourceAttemptID: "query-attempt", app: app, target: target, environmentID: "foreign", catalogDigest: supplied.catalogDigest)
        XCTAssertTrue(try compile(catalog, evidence: stale, capabilities: capabilities).plans.isEmpty)
    }
    #endif
}
