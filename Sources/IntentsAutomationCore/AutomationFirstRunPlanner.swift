import Foundation

public struct AutomationFirstRunProposal: Sendable {
    public var plans: [AutomationCase]
    public var gaps: [String]
}

/// A bounded first campaign uses declarations and scoped real inputs. Invocation
/// coverage remains unassessed unless a separate approved contract supplies assertions.
public enum AutomationFirstRunPlanner {
    public static func compile(catalog: ApplicationSurfaceCatalog, appName: String, approval: RunApproval,
                               capabilities: CapabilityProfile, includeActions: Bool, includeUI: Bool,
                               localeIdentifier: String,
                               inputEvidence: AutomationFirstRunInputEvidence? = nil) throws -> AutomationFirstRunProposal {
        guard catalog.app == approval.app, approval.effects.contains(.observe), approval.maximumActions >= 1 else {
            throw AutomationContractError.invalidIdentity
        }
        var plans: [AutomationCase] = [], gaps: [String] = [], plannedOperations = 0
        let operationLimit = min(20, approval.maximumActions)
        var trustedEvidence = inputEvidence
        if let inputEvidence, try !inputEvidence.matches(catalog: catalog, approval: approval) {
            trustedEvidence = nil
            gaps.append("Supplied inputs belong to a different app build, catalog, target or environment. Fresh approval or query evidence is required.")
        }
        if let context = trustedEvidence?.runtimeContext {
            do { try validateContext(context, catalog: catalog, approval: approval, localeIdentifier: localeIdentifier) }
            catch {
                trustedEvidence?.runtimeContext = nil
                gaps.append("Supplied runtime context is stale or incomplete. Saved cases need fresh compatibility evidence.")
            }
        }
        var plannedDigests = Set<String>()
        for frozen in (trustedEvidence?.savedCases ?? []).sorted(by: { $0.digest < $1.digest }) {
            do {
                try frozen.validate()
                guard !plannedDigests.contains(frozen.digest) else { continue }
                let plan = frozen.plan
                try validateSaved(plan, catalog: catalog, approval: approval, evidence: trustedEvidence,
                    capabilities: capabilities, localeIdentifier: localeIdentifier)
                guard includeActions || (plan.setup + [plan.execution] + plan.observations + plan.cleanup).allSatisfy({ $0.hostProgram == nil }),
                      includeUI || (plan.setup + [plan.execution] + plan.observations + plan.cleanup).allSatisfy({ $0.uiProgram == nil }) else {
                    throw AutomationContractError.missingEvidence("Its required routes are not included in this campaign")
                }
                let cost = try operationCount(plan, approval: approval)
                guard cost <= operationLimit - plannedOperations else {
                    throw AutomationContractError.missingEvidence("Its setup, subject and readback need " + String(cost) + " operations. " + limitGap(operationLimit))
                }
                plans.append(plan); plannedDigests.insert(frozen.digest); plannedOperations += cost
            } catch {
                gaps.append("Saved case " + frozen.plan.id + ": " + String(describing: error))
            }
        }
        if includeUI && approval.target.kind == .nativeMac {
            gaps.append("The initial Mac view requires a separately prepared associated UI host; action checks remain available.")
        }
        if includeUI && approval.target.kind != .nativeMac {
            guard approval.effects.contains(.navigate), !appName.isEmpty, appName.utf16.count <= 1024 else { throw AutomationContractError.invalidIdentity }
            if operationLimit - plannedOperations < 3 {
                gaps.append("The initial view needs three approved operations: activation, hierarchy readback and screenshot.")
            } else {
            var segment = AutomationSegment(id: "initial-view", kind: .observeOnly, phase: .subject,
                operation: "Read the selected app's initial view", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
            segment.uiProgram = .init(steps: [.init(id: "initial-hierarchy", kind: .readHierarchy)])
            var budget = AutomationBudget(); budget.subjectOperations = 3; budget.attempts = 1; budget.controllerCalls = 0; budget.uiActions = 1
            var plan = AutomationCase(id: "first-view", app: approval.app, target: approval.target, environmentID: approval.environmentID, execution: segment, budget: budget)
            plan.provenance = ["ui.locale": localeIdentifier, "expectation": "Initial accessibility observation only; no business correctness rule", "firstRun": "automatic observation", "ui.readback": "bounded-hierarchy-v1"]
            plan.provenance["catalog"] = try AutomationRecipeContext.catalogDigest(catalog)
            try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, purpose: .review)
            // Count every lowered host step, including the retained screenshot.
            let digest = try AutomationFrozenCase.planDigest(plan)
            if plannedDigests.insert(digest).inserted { plans.append(plan); plannedOperations += 3 }
            }
        }
        let actions = catalog.systemActions.sorted { $0.id < $1.id }
        if includeActions {
            for action in actions {
                if plannedOperations >= operationLimit { gaps.append(limitGap(operationLimit)); break }
                if let reason = trustedEvidence?.unavailableActions[action.id] {
                    gaps.append(action.title + ": " + reason)
                    continue
                }
                guard action.compiled, action.parametersComplete else { gaps.append(action.title + ": input declarations are incomplete."); continue }
                let declaration = AutomationActionEffectDeclaration(app: catalog.app, actionID: action.id, effects: approval.effects,
                    developerConfirmation: "Native approval of the listed automatic checks and permitted effects")
                do {
                    let variants = try inputs(action: action, catalog: catalog,
                        supplied: trustedEvidence?.inputs[action.id] ?? [:], limit: operationLimit - plannedOperations)
                    if variants.truncated { gaps.append(action.title + ": enum combinations exceed the first campaign budget; remaining cases are retained for advanced workflows.") }
                    for variant in variants.values {
                        var plan = try compileAction(catalog: catalog, action: action, inputs: variant,
                            evidence: trustedEvidence, declaredEffects: declaration, approval: approval,
                            capabilities: capabilities, localeIdentifier: localeIdentifier)
                        let cost = try operationCount(plan, approval: approval)
                        guard cost <= operationLimit - plannedOperations else {
                            gaps.append(action.title + ": setup, invocation and independent readback need " + String(cost) + " operations. " + limitGap(operationLimit))
                            break
                        }
                        plan.budget.attempts = 1
                        plan.budget.subjectOperations = plan.execution.hostProgram?.operations.count ?? 1
                        plan.budget.controllerCalls = 0
                        plan.budget.uiActions = max(1, uiOperationCount(plan))
                        plan.provenance["firstRun"] = "bounded declaration and trusted-input coverage; no inferred business expectation"
                        plan.provenance["catalog"] = try AutomationRecipeContext.catalogDigest(catalog)
                        if let context = trustedEvidence?.runtimeContext {
                            try validateContext(context, catalog: catalog, approval: approval, localeIdentifier: localeIdentifier)
                            plan.provenance["firstRun.hostDigest"] = context.hostDigest
                        }
                        plan.id = "first-run." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
                        let digest = try AutomationFrozenCase.planDigest(plan)
                        if plannedDigests.insert(digest).inserted { plans.append(plan); plannedOperations += cost }
                    }
                } catch AutomationContractError.missingEvidence(let reason) { gaps.append(action.title + ": " + reason) }
                catch AutomationContractError.invalidPlan(let reason) { gaps.append(action.title + ": " + reason) }
                catch { gaps.append(action.title + ": trusted input or setup evidence is incompatible (" + String(describing: error) + ").") }
            }
        } else if !actions.isEmpty {
            gaps.append("System actions are available. Include them after reviewing their permitted effects.")
        }
        if plans.isEmpty { gaps.append("No executable check has enough evidence yet. The discovery assessment is retained; it is not a test pass.") }
        return .init(plans: plans, gaps: gaps)
    }

    private static func limitGap(_ limit: Int) -> String {
        "The first campaign is limited to " + String(limit) + " approved operations. Further actions remain available in advanced workflows."
    }

    private static func inputs(action: ApplicationSurfaceCatalog.SystemAction, catalog: ApplicationSurfaceCatalog,
                               supplied: [String: AutomationActionInput], limit: Int) throws
        -> (values: [[String: AutomationActionInput]], truncated: Bool) {
        guard Set(supplied.keys).isSubset(of: Set(action.parameters.map(\.name))) else {
            throw AutomationContractError.missingEvidence("Supplied inputs no longer match the declared parameters")
        }
        var variants = [supplied], truncated = false
        for parameter in action.parameters.sorted(by: { $0.name < $1.name }) where parameter.family == "enum" && supplied[parameter.name] == nil {
            let matches = (catalog.enumerations ?? []).filter { $0.typeID == parameter.typeID }
            guard matches.count == 1, let enumeration = matches.first, !enumeration.cases.isEmpty,
                  Set(enumeration.cases.map(\.id)).count == enumeration.cases.count else {
                throw AutomationContractError.missingEvidence("No unambiguous observed enum cases for " + parameter.name)
            }
            var next: [[String: AutomationActionInput]] = []
            for variant in variants {
                for item in enumeration.cases.sorted(by: { $0.id < $1.id }) {
                    if next.count == limit { truncated = true; break }
                    let value = AutomationValue.enumeration(typeID: enumeration.typeID, value: item.id)
                    try AutomationCodecRegistry.validate(value, parameter: parameter, catalog: catalog)
                    var candidate = variant
                    candidate[parameter.name] = .init(value: value, origin: .approvedExample,
                        evidence: "Observed case in the exact built SDK enum metadata, included in the reviewed first campaign")
                    next.append(candidate)
                }
            }
            variants = next
        }
        return (variants, truncated)
    }

    private static func compileAction(catalog: ApplicationSurfaceCatalog, action: ApplicationSurfaceCatalog.SystemAction,
                                      inputs: [String: AutomationActionInput], evidence: AutomationFirstRunInputEvidence?,
                                      declaredEffects: AutomationActionEffectDeclaration, approval: RunApproval,
                                      capabilities: CapabilityProfile, localeIdentifier: String) throws -> AutomationCase {
        #if os(macOS)
        let selections = evidence?.entitySelections[action.id] ?? [:]
        if !selections.isEmpty {
            return try AutomationEntityActionPlanner.compile(catalog: catalog, actionID: action.id,
                textInputs: inputs, selections: selections, expectations: [:], declaredEffects: declaredEffects,
                approval: approval, capabilities: capabilities, purpose: .review)
        }
        #endif
        return try AutomationTemplatePlanner.compile(catalog: catalog, actionID: action.id, inputs: inputs,
            declaredEffects: declaredEffects, approval: approval, capabilities: capabilities, purpose: .review)
    }

    private static func operationCount(_ plan: AutomationCase, approval: RunApproval) throws -> Int {
        if (plan.setup + [plan.execution] + plan.observations + plan.cleanup).contains(where: { $0.uiProgram != nil }) {
            var counted = plan
            counted.budget.uiActions = 300; counted.budget.subjectOperations = 300
            var reviewed = approval; reviewed.maximumActions = 300
            reviewed.approvedCaseDigest = try AutomationFrozenCase.planDigest(counted)
            let hosted = try AutomationXCUITestPlan.assemble(plan: counted, approval: reviewed,
                attemptID: "first-run-budget", leaseGeneration: 1).steps.count
            // Storage observers run after the host drains and are deliberately
            // excluded from its steps. They still consume campaign operations.
            let durable = try AutomationXCUITestPlan.durableObservationSuffix(plan: counted)
                .reduce(0) { $0 + ($1.hostProgram?.operations.count ?? 0) }
            return hosted + durable
        }
        return (plan.setup + [plan.execution] + plan.observations + plan.cleanup).reduce(0) { total, segment in
            total + (segment.hostProgram?.operations.count ?? uiOperationCount(segment))
        }
    }
    private static func validateContext(_ context: AutomationRecipeContext, catalog: ApplicationSurfaceCatalog,
                                        approval: RunApproval, localeIdentifier: String) throws {
        try context.validate()
        guard context.app == catalog.app, context.target == approval.target,
              context.environmentID == approval.environmentID, context.localeIdentifier == localeIdentifier,
              context.catalogDigest == (try AutomationRecipeContext.catalogDigest(catalog)) else {
            throw AutomationContractError.missingEvidence("Current runtime context does not match the selected app, catalog, target, environment and locale")
        }
    }
    private static func validateSaved(_ plan: AutomationCase, catalog: ApplicationSurfaceCatalog, approval: RunApproval,
                                      evidence: AutomationFirstRunInputEvidence?, capabilities: CapabilityProfile,
                                      localeIdentifier: String) throws {
        guard plan.app == catalog.app, plan.target == approval.target, plan.environmentID == approval.environmentID,
              let evidence, plan.provenance["catalog"] == evidence.catalogDigest || plan.preparedMacBuildArtifacts?.catalogDigest == evidence.catalogDigest || plan.preparedSimulatorBuildArtifacts?.catalogDigest == evidence.catalogDigest else {
            throw AutomationContractError.missingEvidence("Saved case does not match the exact app build, catalog, target and environment")
        }
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        if segments.contains(where: { $0.hostProgram != nil || $0.uiProgram != nil }) {
            guard let context = evidence.runtimeContext else { throw AutomationContractError.missingEvidence("Saved case needs current runtime compatibility evidence") }
            try validateContext(context, catalog: catalog, approval: approval, localeIdentifier: localeIdentifier)
            if segments.contains(where: { $0.hostProgram != nil }) {
                guard plan.preparedMacBuildArtifacts?.hostProductDigest == context.hostDigest || plan.preparedSimulatorBuildArtifacts?.hostProductDigest == context.hostDigest || plan.provenance["firstRun.hostDigest"] == context.hostDigest else {
                    throw AutomationContractError.missingEvidence("Saved case belongs to a different or unverified host build")
                }
            }
            if segments.contains(where: { $0.uiProgram != nil }) {
                guard plan.provenance["ui.locale"] == localeIdentifier else { throw AutomationContractError.missingEvidence("Saved case belongs to a different or unverified UI locale") }
                guard plan.provenance["ui.backend"] == "xcuitest",
                      plan.preparedSimulatorBuildArtifacts?.hostProductDigest == context.hostDigest
                        || plan.preparedMacBuildArtifacts?.hostProductDigest == context.hostDigest
                        || plan.provenance["ui.preparedHostDigest"] == context.hostDigest
                        || plan.provenance["firstRun.hostDigest"] == context.hostDigest,
                      plan.preparedSimulatorBuildArtifacts?.catalogDigest == context.catalogDigest
                        || plan.preparedMacBuildArtifacts?.catalogDigest == context.catalogDigest
                        || plan.provenance["ui.preparedCatalogDigest"] == context.catalogDigest else {
                    throw AutomationContractError.missingEvidence("Saved case belongs to a different prepared UI host or catalog")
                }
            }
        }
        var reviewApproval = approval
        reviewApproval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        try PlanValidator.validate(plan, approval: reviewApproval, capabilities: capabilities, purpose: .review)
    }
    private static func uiOperationCount(_ plan: AutomationCase) -> Int {
        (plan.setup + [plan.execution] + plan.observations + plan.cleanup).reduce(0) { $0 + ($1.uiProgram == nil ? 0 : uiOperationCount($1)) }
    }
    private static func uiOperationCount(_ segment: AutomationSegment) -> Int {
        guard let program = segment.uiProgram else { return 1 }
        let mutations = program.operations.filter { [.tap, .fillBinding, .scroll].contains($0.kind) }.count
        let reads = program.operations.reduce(0) { count, operation in
            switch operation.kind {
            case .observeProperty, .readProperty, .locate, .assertEndpoint: return count + 1
            default: return count
            }
        }
        // Include activation and the fresh read following each explicit program mutation.
        return 1 + max(1, reads) + 2 * mutations
    }
}
