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
            localeIdentifier: "en_GB")
    }
    private func attachUIHost(to plan: inout AutomationCase, context: AutomationRecipeContext) {
        plan.provenance["ui.backend"] = "xcuitest"
        plan.provenance["ui.preparedHostDigest"] = context.hostDigest
        plan.provenance["ui.preparedCatalogDigest"] = context.catalogDigest
    }
    func testCompatibleSavedCasesKeepTheirAssertionsAndBudgetPriority() throws {
        let catalog = catalog()
        var supplied = try evidence(catalog); supplied.runtimeContext = try context(catalog)
        var saved = try XCTUnwrap(compile(catalog, evidence: supplied, includeUI: true).plans.first)
        attachUIHost(to: &saved, context: try context(catalog))
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
    func testSavedCasesRejectStaleEffectsAndPreparedUIIdentityWithoutLosingView() throws {
        let catalog = catalog()
        var supplied = try evidence(catalog); supplied.runtimeContext = try context(catalog)
        let original = try XCTUnwrap(compile(catalog, evidence: supplied, includeUI: true).plans.first)
        var prepared = original
        attachUIHost(to: &prepared, context: try context(catalog))
        for mutation in 0..<8 {
            var saved = prepared
            switch mutation {
            case 0: saved.environmentID = "foreign"
            case 1: saved.execution.effects.insert(.externalWrite)
            case 2: saved.provenance["ui.preparedHostDigest"] = String(repeating: "f", count: 64)
            case 3: saved.provenance["ui.preparedCatalogDigest"] = String(repeating: "f", count: 64)
            case 4: saved.provenance["ui.locale"] = "fr_FR"
            case 5: saved.app.productDigest = String(repeating: "f", count: 64)
            case 6:
                saved.provenance["ui.backend"] = nil
                saved.provenance["ui.runtimeManifestDigest"] = String(repeating: "d", count: 64)
            default: saved.provenance["catalog"] = nil
            }
            supplied.savedCases = [try AutomationFrozenCase(plan: saved)]
            let proposal = try compile(catalog, evidence: supplied, includeUI: true)
            XCTAssertEqual(proposal.plans.count, 1)
            XCTAssertEqual(proposal.plans[0], original)
            XCTAssertTrue(proposal.gaps.contains { $0.contains("Saved case") })
        }
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
