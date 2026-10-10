import XCTest
@testable import IntentsAutomationCore

final class AutomationSetupRecipeTests: XCTestCase {
    private func catalog(_ app: AppIdentity) -> ApplicationSurfaceCatalog {
        var parameter = ApplicationSurfaceCatalog.SystemAction.Parameter(name: "query", family: "text", optional: false)
        // A qualified fresh binding must override even a real declared default.
        parameter.defaultValue = .text("Declared stale value")
        return .init(app: app, systemActions: [.init(id: "ActualAction", typeName: "Subject.ActualAction", title: "Actual action", parameters: [parameter], parametersComplete: true, compiled: true, registered: false, executed: false)], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
    }
    private func fixture() throws -> (AutomationSetupRecipeCandidate, AutomationLiveRecipeEvidence) {
        let app = AppIdentity(logicalID: "selected", bundleID: "example.app", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "owned", kind: .simulator)
        let context = AutomationRecipeContext(app: app, target: target, environmentID: "disposable", catalogDigest: try AutomationRecipeContext.catalogDigest(catalog(app)), hostDigest: String(repeating: "c", count: 64), localeIdentifier: "en_GB")
        var create = AutomationSegment(id: "create", kind: .ui, phase: .setup, operation: "Observed creation controls", effects: [.observe, .navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        create.uiProgram = .init(operations: [.init(id: "open", kind: .tap, locator: .init(.testId, "add")), .init(id: "fill", kind: .fillBinding, locator: .init(.testId, "name"), binding: "name"), .init(id: "save", kind: .tap, locator: .init(.testId, "save"))], bindings: ["name": "Synthetic original", "clearSearch": ""])
        create.uiProgram?.operations.append(.init(id: "clear", kind: .fillBinding, locator: .init(.testId, "search"), binding: "clearSearch"))
        var verify = AutomationSegment(id: "verify", kind: .ui, phase: .observe, operation: "Independent full label readback", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        verify.uiProgram = .init(operations: [.init(id: "title", kind: .observeProperty, locator: .init(.label, "Listed, Synthetic original"), property: "text")])
        var read = verify; read.id = "subject"; read.phase = .subject
        var plan = AutomationCase(id: "qualification", app: app, target: target, environmentID: context.environmentID, execution: read, setup: [create], observations: [verify])
        plan.provenance["ui.locale"] = context.localeIdentifier
        var approval = RunApproval(runID: "run", app: app, target: target, environmentID: context.environmentID, effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        try PlanValidator.validate(plan, approval: approval, capabilities: .init())
        let receipts = [create, read, verify].enumerated().map { index, segment in
            AutomationSegmentReceipt(scope: .init(runID: "run", attemptID: "attempt", segmentID: segment.id, leaseGeneration: index + 1), app: app, target: target, segmentID: segment.id, route: .ui, dispatched: true, completed: true,
                observations: segment.id == "verify" ? [.init(id: "verify", app: app, target: target, environmentID: context.environmentID,
                    attemptID: "attempt", stepID: "verify", route: .ui, proof: .visibleState, value: .text("Listed, Synthetic original"))] : [],
                verifiedOutputs: segment.id == "verify" ? ["title": .text("Listed, Synthetic original")] : nil, environmentID: context.environmentID)
        }
        let result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [])
        let report = AutomationAttemptReport(attemptID: "attempt", result: result, receipts: receipts, resourcesReleased: true)
        let candidate = AutomationSetupRecipeCandidate(id: "create.observed", producerSegmentID: "create", verifierSegmentID: "verify", fillBinding: "name", outputID: "title", labelPrefix: "Listed, ")
        return (candidate, .init(context: context, plan: plan, approval: approval, report: report))
    }
    func testQualificationRequiresCompleteApprovedLiveEndpointAndFreshInstantiation() throws {
        let (candidate, live) = try fixture()
        let recipe = try AutomationQualifiedSetupRecipe(candidate: candidate, live: live)
        let setup = try recipe.instantiate(text: "Synthetic next run", context: live.context, segmentPrefix: "fresh")
        XCTAssertEqual(recipe.qualificationAttemptID, "attempt")
        XCTAssertEqual(setup.map(\.id), ["fresh.create", "fresh.verify"])
        XCTAssertTrue(setup.allSatisfy { $0.phase == .setup })
        XCTAssertEqual(setup[0].uiProgram?.bindings["name"], "Synthetic next run")
        XCTAssertEqual(setup[0].uiProgram?.bindings["clearSearch"], "")
        XCTAssertEqual(setup[1].uiProgram?.operations[0].locator, .init(.label, "Listed, Synthetic next run"))
        XCTAssertNil(setup[1].inputBindings)
        XCTAssertEqual(live.plan.setup[0].uiProgram?.bindings["name"], "Synthetic original")
    }
    func testMissingPartialWrongAndForeignOutputsCannotQualify() throws {
        let (candidate, live) = try fixture()
        for mutation in 0..<8 {
            var report = live.report
            switch mutation {
            case 0: report.resourcesReleased = false
            case 1: report.result.evidenceComplete = false
            case 2: report.receipts[2].verifiedOutputs = nil
            case 3: report.receipts[2].verifiedOutputs = ["title": .text("Different item")]
            case 4: report.receipts[2].environmentID = nil
            case 5: report.receipts[2].scope.runId = "foreign"
            case 6: report.receipts[2].completed = false
            default: report.receipts.removeLast()
            }
            XCTAssertThrowsError(try AutomationQualifiedSetupRecipe(candidate: candidate, live: .init(context: live.context, plan: live.plan, approval: live.approval, report: report)))
        }
    }
    func testQualificationRejectsUnapprovedLocaleAndDependentOrMutatingPlans() throws {
        let (candidate, live) = try fixture()
        var approval = live.approval; approval.approvedCaseDigest = nil
        XCTAssertThrowsError(try AutomationQualifiedSetupRecipe(candidate: candidate, live: .init(context: live.context, plan: live.plan, approval: approval, report: live.report)))
        approval = live.approval; approval.disposable = false
        XCTAssertThrowsError(try AutomationQualifiedSetupRecipe(candidate: candidate, live: .init(context: live.context, plan: live.plan, approval: approval, report: live.report)))
        var plan = live.plan; plan.provenance["ui.locale"] = "fr_FR"
        approval = live.approval; approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertThrowsError(try AutomationQualifiedSetupRecipe(candidate: candidate, live: .init(context: live.context, plan: plan, approval: approval, report: live.report)))
        plan = live.plan; plan.execution.uiProgram?.operations[0].kind = .tap; plan.execution.uiProgram?.operations[0].property = nil
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertThrowsError(try AutomationQualifiedSetupRecipe(candidate: candidate, live: .init(context: live.context, plan: plan, approval: approval, report: live.report)))
        plan = live.plan; var prerequisite = plan.setup[0]; prerequisite.id = "prerequisite"; plan.setup.insert(prerequisite, at: 0)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertThrowsError(try AutomationQualifiedSetupRecipe(candidate: candidate, live: .init(context: live.context, plan: plan, approval: approval, report: live.report)))
    }
    func testReuseRejectsEveryCompatibilityChangeAndOversizeOrEmptyInput() throws {
        let (candidate, live) = try fixture()
        let recipe = try AutomationQualifiedSetupRecipe(candidate: candidate, live: live)
        let context = live.context
        let variants = [
            AutomationRecipeContext(app: .init(logicalID: "selected", bundleID: "example.app", platform: "ios", productDigest: String(repeating: "d", count: 64)), target: context.target, environmentID: context.environmentID, catalogDigest: context.catalogDigest, hostDigest: context.hostDigest, localeIdentifier: context.localeIdentifier),
            AutomationRecipeContext(app: context.app, target: .init(id: "other", kind: .simulator), environmentID: context.environmentID, catalogDigest: context.catalogDigest, hostDigest: context.hostDigest, localeIdentifier: context.localeIdentifier),
            AutomationRecipeContext(app: context.app, target: context.target, environmentID: "other", catalogDigest: context.catalogDigest, hostDigest: context.hostDigest, localeIdentifier: context.localeIdentifier),
            AutomationRecipeContext(app: context.app, target: context.target, environmentID: context.environmentID, catalogDigest: String(repeating: "d", count: 64), hostDigest: context.hostDigest, localeIdentifier: context.localeIdentifier),
            AutomationRecipeContext(app: context.app, target: context.target, environmentID: context.environmentID, catalogDigest: context.catalogDigest, hostDigest: String(repeating: "d", count: 64), localeIdentifier: context.localeIdentifier),
            AutomationRecipeContext(app: context.app, target: context.target, environmentID: context.environmentID, catalogDigest: context.catalogDigest, hostDigest: context.hostDigest, localeIdentifier: "fr_FR")
        ]
        for variant in variants { XCTAssertThrowsError(try recipe.instantiate(text: "new", context: variant, segmentPrefix: "fresh")) }
        for input in ["", String(repeating: "a", count: 1025)] { XCTAssertThrowsError(try recipe.instantiate(text: input, context: context, segmentPrefix: "fresh")) }
        XCTAssertThrowsError(try recipe.instantiate(text: "new", context: context, segmentPrefix: "../path"))
    }
    func testPlannerBindsOnlyFreshOutputAndRejectsMissingForeignOrDuplicateInput() throws {
        let (candidate, live) = try fixture()
        let recipe = try AutomationQualifiedSetupRecipe(candidate: candidate, live: live)
        var approval = live.approval; approval.approvedCaseDigest = nil
        let declaration = AutomationActionEffectDeclaration(app: live.context.app, actionID: "ActualAction", effects: [.observe], developerConfirmation: "Approved read-only invocation")
        let capabilities = CapabilityProfile(records: ["apple.intent.invoke", "apple.codec.text"].reduce(into: [:]) { $0[$1] = .init(state: .available, reason: "Synthetic conversion contract", probeVersion: "fixture", evidence: []) })
        let plan = try AutomationTemplatePlanner.compile(catalog: catalog(live.context.app), actionID: "ActualAction", inputs: [:], declaredEffects: declaration, approval: approval, capabilities: capabilities, recipe: recipe, recipeContext: live.context, recipeText: "Synthetic fresh", consumingParameter: "query")
        XCTAssertNil(plan.execution.hostProgram?.operations[0].parameters["query"])
        XCTAssertEqual(plan.setup.count, 2)
        let receipts = [AutomationSegmentReceipt(scope: .init(runID: "run", attemptID: "fresh-attempt", segmentID: "recipe.verify", leaseGeneration: 2), app: plan.app, target: plan.target, segmentID: "recipe.verify", route: .ui, dispatched: true, completed: true, verifiedOutputs: ["title": .text("Listed, Synthetic fresh")], environmentID: plan.environmentID)]
        let resolved = try AutomationInputResolver.resolve(segment: plan.execution, receipts: receipts, plan: plan, runID: "run", attemptID: "fresh-attempt")
        XCTAssertEqual(resolved.hostProgram?.operations[0].parameters["query"], .text("Listed, Synthetic fresh"))
        XCTAssertThrowsError(try AutomationInputResolver.resolve(segment: plan.execution, receipts: live.report.receipts, plan: plan, runID: "run", attemptID: "fresh-attempt"))
        let duplicate = ["query": AutomationActionInput(value: .text("literal"), origin: .userChoice, evidence: "Approved input")]
        XCTAssertThrowsError(try AutomationTemplatePlanner.compile(catalog: catalog(live.context.app), actionID: "ActualAction", inputs: duplicate, declaredEffects: declaration, approval: approval, capabilities: capabilities, recipe: recipe, recipeContext: live.context, recipeText: "new", consumingParameter: "query"))
        XCTAssertThrowsError(try AutomationTemplatePlanner.compile(catalog: catalog(live.context.app), actionID: "ActualAction", inputs: [:], declaredEffects: declaration, approval: approval, capabilities: capabilities, recipe: recipe, recipeContext: live.context, recipeText: "new", consumingParameter: "invented"))
        approval.effects.remove(.fixtureWrite)
        XCTAssertThrowsError(try AutomationTemplatePlanner.compile(catalog: catalog(live.context.app), actionID: "ActualAction", inputs: [:], declaredEffects: declaration, approval: approval, capabilities: capabilities, recipe: recipe, recipeContext: live.context, recipeText: "new", consumingParameter: "query"))
    }
    func testCandidateRoundTripRemainsOnlyData() throws {
        let (candidate, _) = try fixture()
        let decoded = try JSONDecoder().decode(AutomationSetupRecipeCandidate.self, from: JSONEncoder().encode(candidate))
        XCTAssertEqual(decoded, candidate)
        // The qualified recipe and live certificate deliberately have no Decodable conformance.
    }
}
