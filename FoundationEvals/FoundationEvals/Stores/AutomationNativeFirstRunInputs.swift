#if os(macOS)
import Foundation
import IntentsAutomationCore

extension AppAutomationStore {
    var canEditFirstRunInputs: Bool {
        canReviewFirstChecks && firstRunInputReviewID == nil
    }

    func firstRunInputParameters(for action: ApplicationSurfaceCatalog.SystemAction) -> [ApplicationSurfaceCatalog.SystemAction.Parameter] {
        action.parameters.filter { !$0.optional && $0.defaultValue == nil && $0.family != "enum" }
    }

    func setFirstRunInput(_ value: String?, actionID: String, parameter: String) {
        guard canEditFirstRunInputs else { return }
        invalidatePendingCommand()
        firstRunInputs[actionID, default: [:]][parameter] = value
    }

    func setFirstRunEntityQueryText(_ value: String, actionID: String, parameter: String) {
        guard canEditFirstRunInputs else { return }
        invalidatePendingCommand()
        firstRunEntityQueryTexts[actionID, default: [:]][parameter] = value
        firstRunEntityChoices[actionID]?[parameter] = nil
        firstRunSelectedEntityIDs[actionID]?[parameter] = nil
    }

    func selectFirstRunEntity(_ id: String, actionID: String, parameter: String) {
        guard canEditFirstRunInputs,
              id.isEmpty || firstRunEntityChoices[actionID]?[parameter]?.contains(where: { $0.id == id }) == true else { return }
        invalidatePendingCommand()
        firstRunSelectedEntityIDs[actionID, default: [:]][parameter] = id.isEmpty ? nil : id
    }

    /// Invalid inputs exclude only their action; the independent initial view remains usable.
    func firstRunTypedInputs() -> (inputs: [String: [String: AutomationActionInput]], unavailableActions: [String: String]) {
        guard let catalog else { return ([:], [:]) }
        var values: [String: [String: AutomationActionInput]] = [:], gaps: [String: String] = [:]
        for action in catalog.systemActions where firstRunInputs[action.id] != nil {
            do {
                let raw = firstRunInputs[action.id] ?? [:]
                guard Set(raw.keys).isSubset(of: Set(action.parameters.map(\.name))) else {
                    throw AutomationContractError.missingEvidence("Entered inputs no longer match this action")
                }
                for parameter in action.parameters {
                    if let text = raw[parameter.name] {
                        values[action.id, default: [:]][parameter.name] = try AutomationCodecRegistry.input(text, parameter: parameter, catalog: catalog)
                    }
                }
            } catch {
                values[action.id] = nil
                gaps[action.id] = errorText(error)
            }
        }
        return (values, gaps)
    }

    func firstRunSelectedEntities() -> [String: [String: AutomationQueryEntityChoice]] {
        var selected: [String: [String: AutomationQueryEntityChoice]] = [:]
        for (action, parameters) in firstRunSelectedEntityIDs {
            for (parameter, id) in parameters {
                if let choice = firstRunEntityChoices[action]?[parameter]?.first(where: { $0.id == id }) {
                    selected[action, default: [:]][parameter] = choice
                }
            }
        }
        return selected
    }

    func canFindFirstRunEntities(actionID: String, parameter: ApplicationSurfaceCatalog.SystemAction.Parameter) -> Bool {
        canEditFirstRunInputs && firstRunIncludesActions && pendingCommandStatus == nil &&
            (prepared?.host.target.kind == .simulator || prepared?.host.target.kind == .nativeMac) &&
            prepared?.catalog == catalog && prepared?.host.target == sourcePreparationTarget &&
            catalog?.systemActions.first(where: { $0.id == actionID && $0.compiled && $0.parametersComplete })?.parameters.contains(parameter) == true &&
            parameter.family == "entity" && entityDefinition(parameter) != nil &&
            entityDefinition(parameter).map { AutomationEntityQuery.acceptsQuery(entity: $0, text: $0.usesSuggestedQuery ? "" : firstRunEntityQueryTexts[actionID]?[parameter.name] ?? "") } == true
    }

    func findFirstRunEntities(actionID: String, parameter: ApplicationSurfaceCatalog.SystemAction.Parameter) async {
        guard canFindFirstRunEntities(actionID: actionID, parameter: parameter), let prepared,
              let entity = entityDefinition(parameter) else { return }
        if entity.usesSuggestedQuery { firstRunEntityQueryTexts[actionID, default: [:]][parameter.name] = "" }
        let epoch = selectionEpoch, text = firstRunEntityQueryTexts[actionID]?[parameter.name] ?? "", install = installApproved
        let environment = prepared.host.target.kind == .nativeMac
            ? "selected-mac-session:" + (prepared.host.target.loginSession ?? "")
            : "selected-simulator:" + prepared.host.target.id
        let attemptID = UUID().uuidString
        let approval = RunApproval(runID: UUID().uuidString, app: prepared.host.app, target: prepared.host.target,
            environmentID: environment, effects: [.observe], maximumActions: 20, disposable: disposable)
        let queryPlan: AutomationCase
        do { queryPlan = try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: text, approval: approval) }
        catch { message = errorText(error); return }
        do { try beginExecutionAdmission() } catch { message = errorText(error); return }
        invalidatePendingCommand()
        progress = "Reading real records from this app…"; message = nil
        firstRunEntityChoices[actionID]?[parameter.name] = nil
        firstRunSelectedEntityIDs[actionID]?[parameter.name] = nil
        task = Task {
            defer { progress = nil; task = nil; releaseScopeIfClosing(); finishExecutionAdmission() }
            var queryStarted = false
            do {
                try Task.checkCancellation()
                guard !isClosingForFirstRunInputs, selectionEpoch == epoch, self.prepared == prepared,
                      catalog == prepared.catalog, prepared.host.target == sourcePreparationTarget,
                      firstRunEntityQueryTexts[actionID]?[parameter.name] == text, installApproved == install else {
                    throw AutomationContractError.conflictingOperation
                }
                let result: AutomationEntityQueryResult
                queryStarted = true
                if let entityQueryExecutor {
                    result = try await entityQueryExecutor(prepared, entity, text, approval, attemptID, install, support)
                } else {
                    let runner = try AutomationApplicationRunner(supportRoot: support, developerDirectory: developerDirectory)
                    result = try await AutomationEntityQuery.execute(runner: runner, prepared: prepared, entity: entity,
                        text: text, approval: approval, attemptID: attemptID, allowBootAndInstall: install)
                }
                guard result.report.attemptID == attemptID else { throw AutomationContractError.conflictingOperation }
                // Preserve target ownership and evidence even when a selection changed during the read.
                entityQueryReport = result.report; unresolvedEntityQueryAttemptID = nil
                if !result.report.resourcesReleased || result.report.result.subjectDispatchUncertain {
                    retainUnresolvedRequest(runID: approval.runID, target: queryPlan.target)
                }
                await importEvidence(plan: queryPlan, report: result.report)
                try Task.checkCancellation()
                guard !isClosingForFirstRunInputs, selectionEpoch == epoch, self.prepared == prepared,
                      catalog == prepared.catalog, prepared.host.target == sourcePreparationTarget,
                      firstRunEntityQueryTexts[actionID]?[parameter.name] == text, installApproved == install else {
                    throw AutomationContractError.conflictingOperation
                }
                guard result.report.resourcesReleased, !result.report.result.subjectDispatchUncertain else {
                    message = "This query needs reconciliation before more checks can run. (query attempt " + attemptID + ")"
                    await refreshSavedCases(); return
                }
                firstRunEntityChoices[actionID, default: [:]][parameter.name] = result.choices
                if !entity.usesSuggestedQuery && result.choices.count == 1 { firstRunSelectedEntityIDs[actionID, default: [:]][parameter.name] = result.choices[0].id }
                message = result.selectionGap ?? (result.choices.isEmpty ? "No records returned by this query." : nil)
                await refreshSavedCases()
            } catch {
                if queryStarted && entityQueryReport?.attemptID != attemptID {
                    unresolvedEntityQueryAttemptID = attemptID
                    retainUnresolvedRequest(runID: approval.runID, target: queryPlan.target)
                }
                message = errorText(error) + " (query attempt " + attemptID + ")"
                await refreshSavedCases()
            }
        }
        await task?.value
    }
}
#endif
