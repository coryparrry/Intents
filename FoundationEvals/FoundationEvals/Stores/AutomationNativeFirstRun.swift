#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationNativeFirstRunReview: Sendable, Identifiable {
    let id: String
    let requests: [AutomationNativeRunRequest]
    let gaps: [String]
    let appName: String
    let targetName: String
}

extension AppAutomationStore {
    var canReviewFirstChecks: Bool {
        canSelectApplicationFromCommand && candidate != nil && (candidate?.kind == .installedProduct ||
            (candidate?.kind == .sourceTarget && preparationDestination == .macOS) ||
            (prepared?.host.app.logicalID == candidateID && prepared?.host.app.configuration == configuration && prepared?.host.target == sourcePreparationTarget))
    }
    func reviewFirstChecks() throws -> AutomationNativeFirstRunReview {
        guard canReviewFirstChecks, let candidate else { throw AutomationContractError.missingEvidence("Prepare the selected app first") }
        if candidate.platform == "macos" || candidate.app?.platform == "macos" ||
            (candidate.kind == .sourceTarget && (preparationDestination == .macOS || prepared?.host.target.kind == .nativeMac)) {
            let gaps = ["Native Mac first checks require a qualified associated UI host. No checks will run on this Mac."]
            let fields = [candidate.id, configuration, String(firstRunIncludesActions)] + gaps
            return .init(id: AutomationArtifactRegistry.digest(try JSONEncoder().encode(fields)), requests: [], gaps: gaps,
                appName: candidate.name, targetName: "This Mac")
        }
        guard let catalog else { throw AutomationContractError.missingEvidence("Prepare the selected app first") }
        let subject: AutomationApplicationSubject
        if candidate.kind == .sourceTarget {
            guard let prepared else { throw AutomationContractError.invalidIdentity }
            subject = .prepared(prepared)
        } else {
            subject = .installedUI(try .init(bundleURL: URL(fileURLWithPath: candidate.containerPath), target: .init(id: simulatorID, kind: .simulator)))
        }
        let selectedPrepared: AutomationPreparedApplication?
        if case .prepared(let value) = subject { selectedPrepared = value } else { selectedPrepared = nil }
        guard subject.app == catalog.app else { throw AutomationContractError.conflictingOperation }
        var effects: Set<AutomationEffect> = [.observe, .navigate]
        if firstRunIncludesActions {
            guard firstRunEffectsConfirmed, ["navigation", "fixture", "external"].contains(effectChoice), effectChoice != "fixture" || disposable else {
                throw AutomationContractError.missingEvidence("Confirm the permitted effects of the listed app actions")
            }
            if effectChoice == "fixture" { effects.insert(.fixtureWrite) }
            if effectChoice == "external" { effects.insert(.externalWrite) }
        }
        let environment = "selected-simulator:" + subject.target.id
        let approval = RunApproval(runID: "automatic-checks", app: subject.app, target: subject.target, environmentID: environment,
            effects: effects, maximumActions: 30, disposable: disposable)
        let capabilities = selectedPrepared.map(AutomationNativeFreshFixtures.capabilities) ?? .init()
        var gaps: [String] = []
        if selectedPrepared == nil {
            gaps.append("App UI checks need a prepared source build and its XCUITest host.")
        }
        var inputEvidence: AutomationFirstRunInputEvidence?
        if let selectedPrepared {
            let context = AutomationRecipeContext(app: subject.app, target: subject.target, environmentID: environment,
                catalogDigest: try AutomationRecipeContext.catalogDigest(catalog), hostDigest: selectedPrepared.host.hostProductDigest,
                localeIdentifier: Locale.current.identifier)
            let typed = firstRunTypedInputs()
            var evidence = AutomationFirstRunInputEvidence(app: subject.app, target: subject.target, environmentID: environment,
                catalogDigest: context.catalogDigest, inputs: typed.inputs, savedCases: savedCases, runtimeContext: context)
            evidence.unavailableActions = typed.unavailableActions
            evidence.entitySelections = firstRunSelectedEntities()
            inputEvidence = evidence
        }
        let proposal = try AutomationFirstRunPlanner.compile(catalog: catalog, appName: candidate.name, approval: approval, capabilities: capabilities,
            includeActions: firstRunIncludesActions && selectedPrepared != nil,
            includeUI: selectedPrepared != nil, localeIdentifier: Locale.current.identifier, inputEvidence: inputEvidence)
        gaps += proposal.gaps
        if firstRunIncludesActions && selectedPrepared == nil { gaps.append("System actions need a prepared source build. This installed app can still be observed.") }
        let requests = try proposal.plans.map { initial in
            var plan = initial
            if let prepared = selectedPrepared { try AutomationNativePreparedEvidence.attachPreparedEvidence(to: &plan, prepared: prepared) }
            let needsUI = (plan.setup + [plan.execution] + plan.observations + plan.cleanup).contains(where: \.usesUIControl)
            if needsUI {
                if subject.target.kind == .simulator, selectedPrepared != nil {
                    plan.provenance["ui.backend"] = "xcuitest"
                    try AutomationNativeWorkflowSteps.applyBudget(to: &plan, approval: approval)
                }
            }
            plan.id = "first." + String(try AutomationFrozenCase.planDigest(plan).prefix(32))
            let digest = try AutomationFrozenCase.planDigest(plan)
            var scoped = approval; scoped.approvedCaseDigest = digest
            return AutomationNativeRunRequest(subject: subject, plan: plan, approval: scoped, capabilities: capabilities, installApproved: installApproved, digest: digest, caseDigest: digest)
        }
        let fields = requests.map { $0.digest + ":" + String($0.installApproved) + ":" + String($0.approval.disposable) } + gaps + [candidateID, String(firstRunIncludesActions)]
        let digest = AutomationArtifactRegistry.digest(try JSONEncoder().encode(fields))
        return .init(id: digest, requests: requests, gaps: gaps, appName: candidate.name,
            targetName: simulators.first { $0.id == subject.target.id }?.name ?? subject.target.id)
    }
    func runFirstChecks(_ reviewed: AutomationNativeFirstRunReview) {
        do {
            guard try reviewFirstChecks().id == reviewed.id,
                  reviewed.requests.allSatisfy({ $0.subject.target.kind != .nativeMac }) else { throw AutomationContractError.conflictingOperation }
        } catch { message = errorText(error); return }
        firstRunGaps = reviewed.gaps; firstRunReports = []
        guard !reviewed.requests.isEmpty else { message = reviewed.gaps.joined(separator: "\n"); return }
        invalidatePendingCommand(); selectionEpoch += 1
        message = nil; progress = "Starting checks…"
        task = Task {
            defer { progress = nil; task = nil; releaseScopeIfClosing() }
            do {
                let runner = try AutomationApplicationRunner(supportRoot: support, developerDirectory: developerDirectory)
                let budget = try AutomationCampaignBudget(limits: .firstCampaign)
                let campaignID = UUID().uuidString
                for (index, reviewedRequest) in reviewed.requests.enumerated() {
                    try Task.checkCancellation()
                    var request = reviewedRequest; request.approval.runID = campaignID
                    let attemptID = UUID().uuidString
                    try await budget.reserveAttempt(id: attemptID)
                    progress = "Check \(index + 1) of \(reviewed.requests.count): " + request.plan.execution.operation
                    let result: AutomationAttemptReport
                    do {
                        if let runExecutor {
                            result = try await runExecutor(request.subject, request.plan, request.approval, request.capabilities, attemptID, request.installApproved)
                        } else {
                            result = try await runner.run(subject: request.subject, plan: request.plan, approval: request.approval,
                                capabilities: request.capabilities, attemptID: attemptID, allowBootAndInstall: request.installApproved,
                                campaignBudget: budget)
                        }
                    } catch {
                        if let retained = try await runner.retainedAttempt(attemptID: attemptID, plan: request.plan, runID: campaignID) {
                            report = retained; firstRunReports.append(retained)
                            await importEvidence(plan: request.plan, report: retained)
                        }
                        throw error
                    }
                    try AutomationRecordedEvidence.validate(report: result, plan: request.plan, expectedRunID: campaignID)
                    report = result; firstRunReports.append(result)
                    reportDirectory = support.appendingPathComponent(attemptID)
                    await importEvidence(plan: request.plan, report: result)
                    guard result.resourcesReleased, !result.result.subjectDispatchUncertain else {
                        message = "Checks stopped because the last operation needs reconciliation. It will not be repeated automatically."
                        break
                    }
                }
                await refreshSavedCases()
            } catch { message = errorText(error); await refreshSavedCases() }
        }
    }
}
#endif
