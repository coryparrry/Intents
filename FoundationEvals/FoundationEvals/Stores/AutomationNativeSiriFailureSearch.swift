#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationNativeSiriSearchReview: Sendable {
    let request: AutomationNativeRunRequest
    let baseline: AutomationFrozenCase
    let mutations: [AutomationMutationCase]
    let approval: AutomationSearchApproval
    let digest: String
    let selectionEpoch: Int
    let message: String
}
typealias AutomationNativeSiriSearchExecutor = @Sendable (AutomationNativeSiriSearchReview, URL) async throws -> AutomationFailureSearchReport

extension AppAutomationStore {
    var siriResetActions: [ApplicationSurfaceCatalog.SystemAction] {
        (catalog?.systemActions ?? []).filter { action in
            action.compiled && action.registered && action.parametersComplete && action.parameters.count == 2 &&
                (action.resultFamily == nil || action.resultFamily == "noValue") &&
                action.parameters.filter { $0.family == "entity" && $0.typeID == siriOracle.entityType }.count == 1 &&
                action.parameters.filter { $0.family == "bool" }.count == 1
        }
    }
    var canFindSiriFailures: Bool {
        let phrases = siriAlternatePhrases.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let account = siriAccountEnvironment.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSiriWorkflow && canRun && pendingCommandStatus == nil && siriOracle.enabled && siriOracleIsValid &&
            siriResetActions.contains { $0.id == siriResetActionID } && !account.isEmpty && account.utf16.count <= 256 &&
            !account.contains("\0") && (1...2).contains(phrases.count) && Set(phrases).count == phrases.count &&
            phrases.allSatisfy { $0 != siriRequest && $0.utf16.count <= 2048 && !$0.contains("\0") }
    }
    func reviewSiriFailureSearch() throws -> AutomationNativeSiriSearchReview {
        guard canFindSiriFailures, let prepared, let catalog else { throw AutomationContractError.conflictingOperation }
        var request = try makeSiriRunRequest(runID: UUID().uuidString)
        request.plan.environmentID += ":account:" + siriAccountEnvironment.trimmingCharacters(in: .whitespacesAndNewlines)
        request.approval.environmentID = request.plan.environmentID
        request.plan = try AutomationSiriResetPlan.restoring(request.plan, catalog: catalog,
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
            message: "Device: \(request.plan.target.id)\nApp: \(request.plan.app.bundleID)\nDisposable account/session: \(siriAccountEnvironment)\nReset action: \(siriResetActions.first { $0.id == siriResetActionID }?.title ?? siriResetActionID)\nInitial state: \(siriOracle.initialState); expected state: \(siriOracle.expectedState)\n\nApproved requests:\n" + ([siriRequest] + phrases).joined(separator: "\n") + "\n\nEvery attempt restores only the selected test record and checks its state before and after the approved request. Business assertion failures remain failures. You approve the variants as meaning the same operation. Search is limited to 100 total attempts and one hour; resource release and cancellation remain required. Intents may install the selected app on this exact device. Submitted recognised text is retained; this does not prove microphone recognition or installed remote bytes.")
    }
    func findSiriFailures(reviewed: AutomationNativeSiriSearchReview) async {
        do {
            let current = try reviewSiriFailureSearch()
            guard current.digest == reviewed.digest, current.selectionEpoch == reviewed.selectionEpoch,
                  case .prepared(let prepared) = reviewed.request.subject else { throw AutomationContractError.conflictingOperation }
            advanceSelection(); report = nil; reportDirectory = nil; searchReport = nil; message = nil
            progress = "Running the approved Siri phrases on the selected device…"
            task = Task {
                defer { progress = nil; task = nil; releaseScopeIfClosing() }
                do {
                    let result: AutomationFailureSearchReport
                    if let siriSearchExecutor { result = try await siriSearchExecutor(reviewed, support) }
                    else {
                        let runner = try AutomationApplicationRunner(supportRoot: support, developerDirectory: developerDirectory)
                        let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
                        result = try await AutomationSiriSearchCampaign.run(baseline: reviewed.baseline, mutations: reviewed.mutations,
                            approval: reviewed.approval, prepared: prepared, capabilities: reviewed.request.capabilities, runner: runner, cases: cases)
                    }
                    searchReport = result
                    await retainUnresolvedReservation(runID: reviewed.approval.run.runID, target: reviewed.baseline.plan.target)
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
                } catch {
                    await retainUnresolvedReservation(runID: reviewed.approval.run.runID, target: reviewed.baseline.plan.target)
                    message = errorText(error); await refreshSavedCases()
                }
            }
            await task?.value
        } catch { message = errorText(error) }
    }
}
#endif
