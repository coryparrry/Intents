#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationNativeSiriConversionReview: Sendable {
    let scopeDigest: String
    let request: AutomationNativeRunRequest
    let actionID: String
    let digest: String
    let selectionEpoch: Int
    let message: String
}
struct AutomationNativeSiriSearchReview: Sendable {
    let request: AutomationNativeRunRequest
    let baseline: AutomationFrozenCase
    let mutations: [AutomationMutationCase]
    let approval: AutomationSearchApproval
    let digest: String
    let selectionEpoch: Int
    let message: String
}

extension AppAutomationStore {
    func retainSiriResetQualificationOwnership(runID: String, target: TargetIdentity) {
        siriResetQualificationUnresolved = true
        siriResetQualificationOwnership = (runID, target)
        siriResetConversionScopeDigest = nil; siriResetConversionDeadline = nil
        retainUnresolvedRequest(runID: runID, target: target)
    }

    var siriResetActions: [ApplicationSurfaceCatalog.SystemAction] {
        (catalog?.systemActions ?? []).filter { action in
            action.compiled && action.registered && action.parametersComplete && action.parameters.count == 2 &&
                (action.resultFamily == nil || action.resultFamily == "noValue") &&
                action.parameters.filter { $0.family == "entity" && $0.typeID == siriOracle.entityType }.count == 1 &&
                action.parameters.filter { $0.family == "bool" }.count == 1
        }
    }
    var canQualifySiriResetConversion: Bool {
        let environment = siriAccountEnvironment.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSiriWorkflow && canRun && siriOracle.enabled && siriOracleIsValid && pendingCommandStatus == nil &&
            siriResetActions.contains { $0.id == siriResetActionID } && !environment.isEmpty && environment.utf16.count <= 256 && !environment.contains("\0")
    }
    func reviewSiriResetConversion() throws -> AutomationNativeSiriConversionReview {
        guard canQualifySiriResetConversion, let prepared, let scopeDigest = siriConversionSelectionDigest else { throw AutomationContractError.conflictingOperation }
        var request = try makeSiriRunRequest(runID: UUID().uuidString)
        request.plan.environmentID += ":account:" + siriAccountEnvironment.trimmingCharacters(in: .whitespacesAndNewlines)
        request.approval.environmentID = request.plan.environmentID
        request.approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(request.plan)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = AutomationArtifactRegistry.digest(try encoder.encode([request.approval.approvedCaseDigest!, siriResetActionID,
            prepared.host.hostProductDigest, prepared.host.xctestrunDigest, String(request.installApproved)]))
        return .init(scopeDigest: scopeDigest, request: request, actionID: siriResetActionID, digest: digest, selectionEpoch: selectionEpoch,
            message: "Device: \(request.plan.target.id)\nApp: \(request.plan.app.bundleID)\nDisposable account/session: \(siriAccountEnvironment)\nRecord: \(siriOracle.recordName)\nReset definition: \(siriResetActionID)\n\nIntents may install the selected prepared app, query this exact record, then construct the reset action and assign/read back its record and Boolean parameters. This check never runs the reset action or Siri and makes no business-data changes. At most two bounded attempts and ten minutes; owned runner release is required. Remote installed bytes remain unverified.")
    }
    func qualifySiriResetConversion(reviewed: AutomationNativeSiriConversionReview) async {
        do {
            let current = try reviewSiriResetConversion()
            guard current.digest == reviewed.digest, current.selectionEpoch == reviewed.selectionEpoch,
                  case .prepared(let prepared) = reviewed.request.subject else { throw AutomationContractError.conflictingOperation }
            advanceSelection(); siriResetConversionScopeDigest = nil; siriResetConversionDeadline = nil
            message = nil; progress = "Reading the selected record and checking physical parameter conversion…"
            task = Task {
                defer { task = nil; progress = nil; releaseScopeIfClosing() }
                do {
                    let runner = try AutomationApplicationRunner(supportRoot: support, developerDirectory: developerDirectory)
                    let result = try await runner.qualifyPhysicalSiriResetInputs(prepared: prepared, baseline: reviewed.request.plan,
                        actionID: reviewed.actionID, approval: reviewed.request.approval, capabilities: reviewed.request.capabilities,
                        attemptID: UUID().uuidString, allowInstall: reviewed.request.installApproved)
                    report = result.queryReport
                    if !result.resourcesReleased {
                        retainSiriResetQualificationOwnership(runID: reviewed.request.approval.runID, target: reviewed.request.plan.target)
                    }
                    if result.qualified {
                        siriResetConversionScopeDigest = reviewed.scopeDigest
                        siriResetConversionDeadline = result.expiresAt
                        siriCapabilities = try await runner.qualifiedPhysicalSiriResetCapabilities(prepared: prepared,
                            baseline: reviewed.request.plan, actionID: reviewed.actionID, approval: reviewed.request.approval,
                            capabilities: reviewed.request.capabilities)
                        message = "Read-only physical record and Boolean conversion qualified. Review the approved Siri phrases before searching."
                    } else { message = result.failure ?? "Physical parameter conversion was not qualified" }
                    await refreshSavedCases()
                } catch {
                    if let contract = error as? AutomationContractError, [.terminationUnverified, .ambiguousDispatch, .unknownLease].contains(contract) {
                        retainSiriResetQualificationOwnership(runID: reviewed.request.approval.runID, target: reviewed.request.plan.target)
                    }
                    message = errorText(error); await refreshSavedCases()
                }
            }
            await task?.value
        } catch { message = errorText(error) }
    }
    var siriConversionSelectionDigest: String? {
        guard let prepared else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fields = [prepared.host.app.productDigest ?? "", prepared.host.hostProductDigest, prepared.host.xctestrunDigest,
            prepared.host.target.id, siriResetActionID, siriAccountEnvironment.trimmingCharacters(in: .whitespacesAndNewlines),
            siriOracle.entityType, siriOracle.nameProperty, siriOracle.recordName, siriOracle.stateProperty,
            siriOracle.initialState, siriOracle.expectedState]
        return (try? encoder.encode(fields)).map(AutomationArtifactRegistry.digest)
    }
    var siriSearchConversionGap: String? {
        if siriCapabilities.supports(["apple.intent.invoke", "apple.codec.bool", "apple.codec.entity"]),
           siriResetConversionScopeDigest == siriConversionSelectionDigest, siriResetConversionScopeDigest != nil,
           let deadline = siriResetConversionDeadline, ContinuousClock.now < deadline { return nil }
        return "Repeated Siri trials require live physical-device qualification of the reset action's record and Boolean conversion. Use the read-only conversion check below before searching. It reads the real record and assigns parameters without running the reset action. The single existing-record Siri state check above remains available."
    }
    var canFindSiriFailures: Bool {
        let phrases = siriAlternatePhrases.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let account = siriAccountEnvironment.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSiriWorkflow && canRun && pendingCommandStatus == nil && siriOracle.enabled && siriOracleIsValid &&
            siriSearchConversionGap == nil &&
            siriResetActions.contains { $0.id == siriResetActionID } && !account.isEmpty && account.utf16.count <= 256 &&
            !account.contains("\0") && (1...2).contains(phrases.count) && Set(phrases).count == phrases.count &&
            phrases.allSatisfy { $0 != siriRequest && $0.utf16.count <= 2048 && !$0.contains("\0") }
    }
    func reviewSiriFailureSearch() throws -> AutomationNativeSiriSearchReview {
        guard canFindSiriFailures, let prepared, let catalog else { throw AutomationContractError.conflictingOperation }
        var request = try makeSiriRunRequest(runID: UUID().uuidString)
        request.plan.environmentID += ":account:" + siriAccountEnvironment.trimmingCharacters(in: .whitespacesAndNewlines)
        request.approval.environmentID = request.plan.environmentID
        request.plan = try AutomationSiriRepeatableQualification.restoring(request.plan, catalog: catalog,
            actionID: siriResetActionID, approval: request.approval, capabilities: request.capabilities)
        let baseline = try AutomationFrozenCase(plan: request.plan)
        request.approval.approvedCaseDigest = baseline.digest
        let phrases = siriAlternatePhrases.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let mutations = try phrases.map { try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .siriRecognizedText,
            request: $0, semanticJustification: "Developer approves this exact wording as the same record operation with the same outcome") }
        let approval = AutomationSearchApproval(run: request.approval,
            approvedDigests: Set(([baseline] + mutations.map(\.frozen)).map(\.digest)), limits: .init())
        let digestFields = [baseline.digest] + mutations.map { $0.frozen.digest } +
            [prepared.host.hostProductDigest, prepared.host.xctestrunDigest, String(request.installApproved)]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = AutomationArtifactRegistry.digest(try encoder.encode(digestFields))
        return .init(request: request, baseline: baseline, mutations: mutations, approval: approval, digest: digest,
            selectionEpoch: selectionEpoch,
            message: "Device: \(request.plan.target.id)\nApp: \(request.plan.app.bundleID)\nDisposable account/session: \(siriAccountEnvironment)\nReset action: \(siriResetActions.first { $0.id == siriResetActionID }?.title ?? siriResetActionID)\nInitial state: \(siriOracle.initialState); expected state: \(siriOracle.expectedState)\n\nApproved requests:\n" + ([siriRequest] + phrases).joined(separator: "\n") + "\n\nEvery attempt first restores only the independently selected test record. Each exact request must complete two safe live submission-channel qualifications before search; business assertion failures remain failures and can receive five confirmation trials. You approve the variants as meaning the same operation. Qualification and search share 100 total attempts and one hour; resource release and cancellation remain required. Intents may install the selected app on this exact device. Submitted recognised text is retained; this does not prove microphone recognition or installed remote bytes.")
    }
    func findSiriFailures(reviewed: AutomationNativeSiriSearchReview) async {
        do {
            let current = try reviewSiriFailureSearch()
            guard current.digest == reviewed.digest, current.selectionEpoch == reviewed.selectionEpoch,
                  case .prepared(let prepared) = reviewed.request.subject else { throw AutomationContractError.conflictingOperation }
            advanceSelection(); report = nil; reportDirectory = nil; searchReport = nil; message = nil
            progress = "Qualifying each approved Siri phrase on the selected device…"
            task = Task {
                defer { progress = nil; task = nil; releaseScopeIfClosing() }
                do {
                    let runner = try AutomationApplicationRunner(supportRoot: support, developerDirectory: developerDirectory)
                    let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
                    let result = try await AutomationSiriSearchCampaign.run(baseline: reviewed.baseline, mutations: reviewed.mutations,
                        approval: reviewed.approval, prepared: prepared, capabilities: reviewed.request.capabilities, runner: runner, cases: cases)
                    searchReport = result
                    let definitions = [reviewed.baseline] + reviewed.mutations.map(\.frozen)
                    for attempt in result.qualificationAttempts ?? [] {
                        if let frozen = definitions.first(where: { $0.digest == attempt.caseDigest }) { await importEvidence(plan: frozen.plan, report: attempt.report, announce: false) }
                    }
                    for attempt in result.attempts {
                        if let frozen = definitions.first(where: { $0.digest == attempt.caseDigest }) { await importEvidence(plan: frozen.plan, report: attempt.report, announce: false) }
                    }
                    noteCampaignEvidenceImport()
                    let archive = try AutomationUIFailureSearchArchive(caseStoreRoot: support.appendingPathComponent("Cases"))
                    try await archive.save(.init(id: reviewed.request.approval.runID, runID: reviewed.request.approval.runID,
                        baseline: reviewed.baseline, mutations: reviewed.mutations, report: result))
                    await refreshSavedCases()
                } catch { message = errorText(error); await refreshSavedCases() }
            }
            await task?.value
        } catch { message = errorText(error) }
    }
}
#endif
