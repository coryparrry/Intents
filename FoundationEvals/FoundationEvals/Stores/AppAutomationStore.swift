#if os(macOS)
import Foundation
import Observation
import IntentsAutomationCore

@MainActor @Observable
final class AppAutomationStore {
    var intake: AutomationIntakeAssessment?
    var candidateID = ""
    var configuration = ""
    var simulators: [AutomationSimulator] = []
    var simulatorID = ""
    var physicalDeviceID = ""
    var siriRequest = ""
    var siriOracle = AutomationNativeSiriOracle()
    var siriCapabilities = CapabilityProfile()
    var preparationDestination: AutomationNativePreparationDestination = .simulator
    var prepared: AutomationPreparedApplication? {
        didSet {
            if let prepared, !preparedHistory.contains(prepared) {
                preparedHistory.append(prepared)
                if preparedHistory.count > 100 { preparedHistory.removeFirst() }
            }
        }
    }
    var preparedHistory: [AutomationPreparedApplication] = []
    var savedPreparedBaseline: AutomationPreparedApplication?
    var catalog: ApplicationSurfaceCatalog?
    var workflowRoute = "ui"
    var actionID = ""
    var inputs: [String: String] = [:]
    var entityQueryTexts: [String: String] = [:]
    var entityChoices: [String: [AutomationQueryEntityChoice]] = [:]
    var selectedEntityIDs: [String: String] = [:]
    var entityExpectedBooleans: [String: String] = [:]
    var protectedEntityIDs: [String: Set<String>] = [:]
    var entityQueryReport: AutomationAttemptReport?
    private(set) var unresolvedEntityQueryAttemptID: String?
    private let entityQueryExecutor: AutomationNativeEntityQueryExecutor?
    var effectChoice = ""
    var effectsConfirmed = false
    var disposable = false
    var installApproved = true
    var learnedSetupAttempts: [AutomationCapturedSetupAttempt] = []
    var learnedSetupRecipe: AutomationQualifiedNavigationSetupRecipe?
    var useLearnedSetup = false
    var freshNamePrefix = ""
    var freshNameProperty = ""
    var freshStateProperty = ""
    var freshInitialState = ""
    var freshExpectedState = ""
    var freshProtectOtherRecord = false
    var freshContextProperty = ""
    var freshSelectedContext = ""
    var freshProtectedContext = ""
    var freshContext: AutomationFreshEntityContext? {
        freshProtectOtherRecord ? .init(property: freshContextProperty, selectedValue: freshSelectedContext, protectedValue: freshProtectedContext) : nil
    }
    var freshGoalValid: Bool {
        var goal = AutomationNavigationGoal(id: "create", instruction: freshContext?.setupInstruction(uiInstruction) ?? uiInstruction,
            endpoint: .init(.label, uiEndpoint), maximumCalls: 12, maximumActions: 30)
        goal.saveControl = freshSaveControl.isEmpty ? nil : .init(.label, freshSaveControl)
        return (try? goal.validate()) != nil
    }
    var freshContextValid: Bool {
        guard let freshContext else { return true }
        guard let entity = freshEntity else { return false }
        return (try? freshContext.validate(entity: entity, nameProperty: freshNameProperty)) != nil
    }
    var uiInstruction = ""
    var uiEndpoint = ""
    var freshSaveControl = ""
    var uiApprovedText = ""
    var uiExpectedText = ""
    var uiObservationLabel = ""
    var uiObservationProperty = "text"
    var uiAlternatePhrases = ""
    var searchReport: AutomationFailureSearchReport?
    var savedSearches: [AutomationUIFailureSearchRecord] = []
    var viewedSearch: AutomationUIFailureSearchRecord?
    var reproductionReport: AutomationReproductionReport?
    var savedReproductions: [AutomationReproductionReport] = []
    var viewedReproduction: AutomationReproductionReport?
    var comparisonReport: AutomationFixComparisonReport?
    var savedComparisons: [AutomationFixComparisonReport] = []
    var viewedComparison: AutomationFixComparisonReport?
    private var fixedBundleURL: URL?
    private var fixedMacProduct: AutomationInstalledMacUIApplication?
    private var fixedProduct: AutomationInstalledUIApplication?
    private var hasFixedSecurityScope = false
    var savedViewedCase: AutomationFrozenCase?
    var savedViewedAttempts: [AutomationAttemptReport] = []
    var savedAttemptLoading = false
    var canLoadSavedAttemptSelection: Bool { !busy && !closing }
    var savedViewedReport: AutomationAttemptReport?
    var savedViewedDirectory: URL?
    var selectionEpoch = 0
    var savedViewRequestID: UUID?
    func canSaveCapsuleExport(_ selection: AutomationCapsuleExportSelection) -> Bool { selection.reviewed && !busy && !closing }
    let savedAttemptsReader: (@Sendable (AutomationFrozenCase) async throws -> [AutomationAttemptReport])?
    private let savedCasesReader: (@Sendable () async throws -> [AutomationFrozenCase])?
    private let runExecutor: AutomationNativeRunExecutor?
    private let searchExecutor: AutomationNativeSearchExecutor?
    private let comparisonExecutor: AutomationNativeFixComparisonExecutor?
    private let reproductionExecutor: AutomationNativeReproductionExecutor?
    private let reproductionPreflightReader: (@Sendable (AutomationFrozenCase, String, URL) async throws -> (AutomationFrozenCase, AutomationAttemptReport))?
    let macSavedRuntimeProvider: (@Sendable () throws -> AutomationNativeMacSavedRuntime)?
    let uiRuntimeProvider: (@Sendable () throws -> AutomationNativeUIRuntime)?
    var savedCases: [AutomationFrozenCase] = []
    private(set) var retainedUnresolvedNormalReport: AutomationAttemptReport?
    var report: AutomationAttemptReport? {
        didSet {
            if let report, !report.resourcesReleased || report.result.subjectDispatchUncertain { retainedUnresolvedNormalReport = report }
        }
    }
    private let evidenceImporter: (@Sendable (AutomationCase, AutomationAttemptReport, URL, AutomationEvidenceExposure) async throws -> AutomationNativeEvidenceDocument)?
    private var hasMigratedEvidenceHistory = false
    private var migratingEvidenceHistory = false
    private(set) var evidenceImportRevision = 0
    private(set) var evidenceImportMessage: String?
    @ObservationIgnored private var canonicalExposure: AutomationEvidenceExposure?
    @ObservationIgnored private var canonicalSavedExposure: AutomationEvidenceExposure?
    var canonicalEvidence: AutomationNativeEvidenceDocument? { didSet { if canonicalEvidence == nil { canonicalExposure = nil } } }
    var canonicalSavedEvidence: AutomationNativeEvidenceDocument? { didSet { if canonicalSavedEvidence == nil { canonicalSavedExposure = nil } } }
    var canonicalPresentation: AutomationNativeEvidencePresentation? {
        guard let document = canonicalEvidence else { return nil }; return try? canonicalExposure?.presentation(document)
    }
    var canonicalSavedPresentation: AutomationNativeEvidencePresentation? {
        guard let document = canonicalSavedEvidence else { return nil }; return try? canonicalSavedExposure?.presentation(document)
    }
    var reportDirectory: URL?
    var message: String?
    var progress: String?
    var selectedMacTarget: TargetIdentity?
    let nativeMacTargetReader: @Sendable () throws -> TargetIdentity
    private var selectedURL: URL?
    let sourceGrants: AutomationNativeSourceGrants
    var selectedSourceRoot: URL? {
        selectedURL.map { ["xcodeproj", "xcworkspace"].contains($0.pathExtension.lowercased()) ? $0.deletingLastPathComponent() : $0 }
    }
    private var hasSecurityScope = false
    var closing = false
    @ObservationIgnored private let telemetry: (any AutomationRunTelemetry)?
    private var task: Task<Void, Never>?
    var commandRequests: [UUID: AutomationNativeCommandStatus] = [:]
    var commandHistory = AutomationCommandHistory()
    var pendingCommand: UUID?
    var activeCommand: UUID?
    var pendingCommandStatus: AutomationNativeCommandStatus? { pendingCommand.flatMap { commandRequests[$0] } }
    let support: URL
    private let preparation = AutomationPreparation()
    private let preparationExecutor: AutomationNativePreparationExecutor?
    private let simulatorInventoryReader: AutomationNativeSimulatorInventoryReader
    private var simulatorInventoryRevision = 0
    private let developerDirectory: URL
    init(supportDirectory: URL, telemetry: (any AutomationRunTelemetry)? = nil, developerDirectory: URL = AutomationNativeToolchain.developerDirectory(),
         savedAttemptsReader: (@Sendable (AutomationFrozenCase) async throws -> [AutomationAttemptReport])? = nil,
         savedCasesReader: (@Sendable () async throws -> [AutomationFrozenCase])? = nil, runExecutor: AutomationNativeRunExecutor? = nil,
         uiRuntimeProvider: (@Sendable () throws -> AutomationNativeUIRuntime)? = nil,
         macSavedRuntimeProvider: (@Sendable () throws -> AutomationNativeMacSavedRuntime)? = nil,
         searchExecutor: AutomationNativeSearchExecutor? = nil,
         entityQueryExecutor: AutomationNativeEntityQueryExecutor? = nil,
         comparisonExecutor: AutomationNativeFixComparisonExecutor? = nil,
         reproductionExecutor: AutomationNativeReproductionExecutor? = nil,
         reproductionPreflightReader: (@Sendable (AutomationFrozenCase, String, URL) async throws -> (AutomationFrozenCase, AutomationAttemptReport))? = nil,
         nativeMacTargetReader: @escaping @Sendable () throws -> TargetIdentity = { try AutomationMacGUIIdentity.currentTarget() },
         evidenceImporter: (@Sendable (AutomationCase, AutomationAttemptReport, URL, AutomationEvidenceExposure) async throws -> AutomationNativeEvidenceDocument)? = nil,
         preparationExecutor: AutomationNativePreparationExecutor? = nil,
         sourceGrants: AutomationNativeSourceGrants? = nil,
         simulatorInventoryReader: @escaping AutomationNativeSimulatorInventoryReader = { try await AutomationSimulatorInventory.read(developerDirectory: $0, workspace: $1) }) {
        self.developerDirectory = developerDirectory
        self.preparationExecutor = preparationExecutor
        self.sourceGrants = sourceGrants ?? AutomationNativeSourceGrants()
        self.simulatorInventoryReader = simulatorInventoryReader
        self.macSavedRuntimeProvider = macSavedRuntimeProvider
        self.nativeMacTargetReader = nativeMacTargetReader
        self.evidenceImporter = evidenceImporter
        self.telemetry = telemetry
        support = supportDirectory; self.entityQueryExecutor = entityQueryExecutor; self.comparisonExecutor = comparisonExecutor; self.savedAttemptsReader = savedAttemptsReader
        self.savedCasesReader = savedCasesReader; self.runExecutor = runExecutor; self.uiRuntimeProvider = uiRuntimeProvider; self.searchExecutor = searchExecutor; self.reproductionExecutor = reproductionExecutor; self.reproductionPreflightReader = reproductionPreflightReader
    }
    var busy: Bool { progress != nil }
    var candidate: AutomationApplicationCandidate? { intake?.candidates.first { $0.id == candidateID } }
    var action: ApplicationSurfaceCatalog.SystemAction? { catalog?.systemActions.first { $0.id == actionID } }
    var canPrepare: Bool { !busy && !closing && candidate?.kind == .sourceTarget && !configuration.isEmpty && sourcePreparationTarget != nil }
    var isInstalledUI: Bool { candidate?.kind == .installedProduct && candidate?.app?.platform == "ios" }
    var isFreshRecordWorkflow: Bool { candidate?.kind == .sourceTarget && workflowRoute == "fresh" }
    var freshEntity: ApplicationSurfaceCatalog.Entity? {
        guard let action, action.parameters.count == 1, let parameter = action.parameters.first, parameter.family == "entity" else { return nil }
        return catalog?.entities?.first { $0.typeID == parameter.typeID }
    }
    var isUIWorkflow: Bool { isInstalledUI || isInstalledMacUI || (candidate?.kind == .sourceTarget && workflowRoute == "ui") }
    var canRun: Bool {
        guard !closing, !unresolvedNormalAttempt, !unresolvedSearch, !unresolvedReproduction, !unresolvedComparison, !unresolvedEntityQuery else { return false }
        if isSiriWorkflow { return canRunSiriSubmission }
        guard prepared?.host.target.kind != .nativeMac, candidate?.kind != .sourceTarget || preparationDestination == .simulator else { return false }
        if isUIWorkflow {
            return (isInstalledUI || preparedUISelectionMatches) && !busy && UUID(uuidString: simulatorID) != nil && !uiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                uiInstruction.utf16.count <= 4096 && !uiEndpoint.isEmpty && uiEndpoint.utf16.count <= 1024 &&
                uiExpectedText.utf16.count <= 1024 && uiObservationLabel.utf16.count <= 1024 && uiApprovedText.utf16.count <= 32768 &&
                ["text", "value", "checked", "selected"].contains(uiObservationProperty) &&
                (uiExpectedText.isEmpty || uiObservationProperty == "text" || !uiObservationLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
                (uiExpectedText.isEmpty || !["checked", "selected"].contains(uiObservationProperty) || ["true", "false"].contains(uiExpectedText)) &&
                !effectChoice.isEmpty && effectsConfirmed && (effectChoice != "fixture" || disposable) &&
                report?.result.subjectDispatchUncertain != true && report?.resourcesReleased != false
        }
        if isFreshRecordWorkflow {
            return !busy && preparedUISelectionMatches && action?.compiled == true && action?.parametersComplete == true &&
                freshEntity?.properties[freshNameProperty] == "text" && freshEntity?.properties[freshStateProperty] == "bool" && freshContextValid && freshGoalValid &&
                (try? AutomationAttemptText.value(prefix: freshNamePrefix, attemptID: "preview")) != nil &&
                !uiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && uiInstruction.utf16.count <= 4096 &&
                !uiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && uiEndpoint.utf16.count <= 1024 &&
                ["true", "false"].contains(freshInitialState) && ["true", "false"].contains(freshExpectedState) &&
                effectChoice == "fixture" && disposable && effectsConfirmed && report?.resourcesReleased != false && report?.result.subjectDispatchUncertain != true
        }
        return !busy && prepared?.host.app.logicalID == candidateID && prepared?.generatedHost.configuration == configuration &&
        prepared?.host.target.id == simulatorID && action?.parametersComplete == true && !effectChoice.isEmpty && effectsConfirmed &&
        (effectChoice != "fixture" || disposable) &&
        action?.parameters.allSatisfy({ parameter in
            if parameter.family == "entity" { return parameter.optional || selectedEntity(parameter.name) != nil }
            guard let catalog else { return false }
            if let raw = inputs[parameter.name] { return (try? AutomationCodecRegistry.input(raw, parameter: parameter, catalog: catalog)) != nil }
            return parameter.optional || (try? AutomationCodecRegistry.declaredDefault(parameter, catalog: catalog)) != nil
        }) == true &&
        report?.result.subjectDispatchUncertain != true && report?.resourcesReleased != false
    }
    private var unresolvedSearch: Bool {
        searchReport?.attempts.contains(where: { !$0.report.resourcesReleased || $0.report.result.subjectDispatchUncertain }) == true ||
        searchReport?.interruptions.contains(where: \.dispatchMayHaveOccurred) == true
    }
    private var unresolvedReproduction: Bool {
        reproductionReport?.attempts.contains(where: { !$0.resourcesReleased || $0.result.subjectDispatchUncertain }) == true ||
        reproductionReport?.interruption?.dispatchMayHaveOccurred == true
    }
    private var sourceSavedBaseline: AutomationPreparedApplication? {
        guard isUIWorkflow || isFreshRecordWorkflow, candidate?.kind == .sourceTarget, let frozen = savedViewedCase,
              let baseline = savedPreparedBaseline, baseline.host.app == frozen.plan.app,
              candidateID == baseline.host.app.logicalID, configuration == baseline.host.app.configuration,
              simulatorID == baseline.host.target.id else { return nil }
        if let selected = prepared, selected.host.app == baseline.host.app, selected != baseline { return nil }
        return baseline
    }
    private var permitsSavedWorkflow: Bool {
        guard let plan = savedViewedCase?.plan else { return false }
        if (try? AutomationFreshEntityPlanner.bindings(plan: plan)) != nil {
            return isFreshRecordWorkflow && effectChoice == "fixture" && disposable
        }
        let segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        return isUIWorkflow && effectChoice == "navigation" && segments.allSatisfy { $0.kind == .ui && $0.effects.isSubset(of: [.observe, .navigate]) }
    }
    var canReproduceSavedFailure: Bool { canUseSavedFailure(commandKind: .reproduction) }
    private func canUseSavedFailure(commandKind: AutomationNativeCommandKind) -> Bool {
        guard !busy, !closing, !unresolvedNormalAttempt, !unresolvedSearch, !unresolvedReproduction, !unresolvedComparison, !unresolvedEntityQuery, permitsSavedWorkflow,
              pendingCommandStatus == nil || pendingCommandStatus?.kind == commandKind,
              effectsConfirmed, permitsSavedWorkflow, let frozen = savedViewedCase,
              let original = savedViewedReport else { return false }
        if isInstalledMacUI {
            guard macSavedRuntimeProvider != nil, let target = selectedMacTarget, frozen.plan.target == target,
                  (try? nativeMacTargetReader()) == target, frozen.plan.app == candidate?.app else { return false }
        } else if UUID(uuidString: simulatorID) == nil { return false }
        return (isInstalledMacUI || (frozen.plan.app == (isInstalledUI ? candidate?.app : sourceSavedBaseline?.host.app) && frozen.plan.target.id == simulatorID)) &&
            original.result.summary == .assertionFailed && original.result.assessed && original.result.evidenceComplete &&
            original.resourcesReleased && !original.result.subjectDispatchUncertain &&
            report?.resourcesReleased != false && report?.result.subjectDispatchUncertain != true
    }
    func reproduceSavedFailure() async {
        guard canReproduceSavedFailure else { return }
        let commandID = pendingCommand
        guard commandID == nil || commandRequests[commandID!]?.kind == .reproduction else { return }
        let runID = commandID?.uuidString ?? UUID().uuidString
        pendingCommand = nil; activeCommand = commandID
        if let commandID { commandRequests[commandID]?.state = "running" }
        progress = "Verifying the saved failure…"; message = nil
        task = Task {
            defer { progress = nil; task = nil; activeCommand = nil; releaseScopeIfClosing() }
            do {
                let request = try await makeReproductionRequest(runID: runID)
                if let commandID {
                    guard activeCommand == commandID, commandRequests[commandID]?.state == "running",
                          commandRequests[commandID]?.kind == .reproduction,
                          commandRequests[commandID]?.digest == request.digest else {
                        commandRequests[commandID]?.state = "invalidated"
                        throw AutomationContractError.conflictingOperation
                    }
                }
                let proposal = request.proposal, subject = request.subject, runtime = request.runtime
                let casesRoot = support.appendingPathComponent("Cases")
                advanceSelection(); progress = "Reproducing the saved failure five times…"
                let result: AutomationReproductionReport
                if let reproductionExecutor { result = try await reproductionExecutor(proposal, subject, runtime, support, request.installApproved) }
                else { result = try await proposal.execute(subject: subject, runtime: runtime, support: support, developerDirectory: developerDirectory, allowBootAndInstall: request.installApproved) }
                reproductionReport = result
                guard result.frozen == proposal.frozen, result.originalFailure.attemptID == proposal.originalAttemptID,
                      result.runID == proposal.approval.runID else { throw AutomationContractError.conflictingOperation }
                let outcome = try AutomationNativeReproductionOutcome(result)
                if let commandID {
                    commandRequests[commandID]?.reproduction = outcome
                    commandRequests[commandID]?.resourcesReleased = outcome.resourcesReleased
                    commandRequests[commandID]?.state = "completed"
                }
                for attempt in [result.originalFailure] + result.attempts { await importEvidence(plan: result.frozen.plan, report: attempt, announce: false) }
                if evidenceImporter != nil { evidenceImportRevision += 1 }
                try await AutomationReproductionArchive(caseStoreRoot: casesRoot).save(result)
                await refreshSavedCases()
            } catch {
                message = errorText(error)
                if let commandID, !["completed", "invalidated"].contains(commandRequests[commandID]?.state ?? "") {
                    pendingCommand = nil
                    commandRequests[commandID]?.state = error is CancellationError ? "cancelled" : "failed"
                }
                await refreshSavedCases()
            }
        }
        await task?.value
    }
    private func makeReproductionRequest(runID: String) async throws -> AutomationNativeReproductionRequest {
        guard !closing, !unresolvedNormalAttempt, !unresolvedSearch, !unresolvedReproduction, !unresolvedComparison, !unresolvedEntityQuery, permitsSavedWorkflow, effectsConfirmed, permitsSavedWorkflow, let frozen = savedViewedCase, let original = savedViewedReport, let candidate else {
            throw AutomationContractError.missingEvidence("Select a released, assessed saved UI failure and its original app in the native window")
        }
        let epoch = selectionEpoch, viewID = savedViewRequestID, targetID = simulatorID, macTarget = selectedMacTarget
        let install = installApproved, approvedDisposable = disposable
        let casesRoot = support.appendingPathComponent("Cases")
        let stored: AutomationFrozenCase, failure: AutomationAttemptReport
        if let reproductionPreflightReader { (stored, failure) = try await reproductionPreflightReader(frozen, original.attemptID, casesRoot) }
        else {
            let cases = try AutomationCaseStore(root: casesRoot)
            stored = try await cases.load(id: frozen.plan.id, revision: frozen.plan.revision, digest: frozen.digest)
            failure = try await cases.loadAttempt(id: original.attemptID, frozen: stored)
        }
        try Task.checkCancellation()
        guard stored == frozen, failure == original else { throw AutomationContractError.conflictingOperation }
        guard !closing, selectionEpoch == epoch, savedViewRequestID == viewID,
              savedViewedCase == frozen, savedViewedReport == original, candidateID == candidate.id, simulatorID == targetID, selectedMacTarget == macTarget,
              !unresolvedNormalAttempt, !unresolvedSearch, !unresolvedReproduction, !unresolvedComparison, !unresolvedEntityQuery, effectsConfirmed, permitsSavedWorkflow,
              installApproved == install, disposable == approvedDisposable else { throw AutomationContractError.conflictingOperation }
        if isInstalledMacUI {
            guard let target = macTarget, try nativeMacTargetReader() == target, let provider = macSavedRuntimeProvider else { throw AutomationContractError.conflictingOperation }
            let selected = try AutomationInstalledMacUIApplication(bundleURL: URL(fileURLWithPath: candidate.containerPath), target: target)
            guard selected.app == candidate.app else { throw AutomationContractError.conflictingOperation }
            return try provider().reproduction(frozen: stored, original: failure, selected: selected, runID: runID)
        }
        let subject: AutomationApplicationSubject
        if isInstalledUI {
            let installed = try AutomationInstalledUIApplication(bundleURL: URL(fileURLWithPath: candidate.containerPath), target: .init(id: targetID, kind: .simulator))
            guard installed.app == candidate.app else { throw AutomationContractError.conflictingOperation }
            subject = .installedUI(installed)
        } else {
            guard let baseline = sourceSavedBaseline else { throw AutomationContractError.conflictingOperation }
            subject = .prepared(baseline)
        }
        let runtime = try uiRuntimeProvider?() ?? AutomationNativeUIRuntime.bundled(stateDirectory: support.appendingPathComponent("ui-preview"))
        let proposal = try AutomationNativeUIReproductionProposal.compile(frozen: stored, original: failure, subject: subject,
            runtime: runtime, runID: runID, disposable: approvedDisposable)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fields = ["case": stored.digest, "original": AutomationArtifactRegistry.digest(try encoder.encode(failure)),
            "runtime": runtime.manifestDigest, "runtimeTeam": runtime.runtime.expectedTeamID,
            "install": String(install), "disposable": String(approvedDisposable), "attempts": "5",
            "uiActions": String(proposal.limits.uiActions), "controllerCalls": String(proposal.limits.controllerCalls),
            "wallClockSeconds": String(proposal.limits.wallClockSeconds)]
        return .init(proposal: proposal, subject: subject, runtime: runtime.runtime, installApproved: install,
            digest: AutomationArtifactRegistry.digest(try encoder.encode(fields)))
    }
    private var unresolvedNormalAttempt: Bool { retainedUnresolvedNormalReport != nil || report?.result.subjectDispatchUncertain == true || report?.resourcesReleased == false }
    var canSelectApplicationFromCommand: Bool {
        !busy && !closing && pendingCommandStatus == nil && !unresolvedNormalAttempt && !unresolvedSearch &&
            !unresolvedReproduction && !unresolvedComparison && !unresolvedEntityQuery
    }
    private var unresolvedEntityQuery: Bool {
        if unresolvedEntityQueryAttemptID != nil { return true }
        return entityQueryReport?.resourcesReleased == false || entityQueryReport?.result.subjectDispatchUncertain == true
    }
    func selectedEntity(_ parameter: String) -> AutomationQueryEntityChoice? {
        entityChoices[parameter]?.first { $0.id == selectedEntityIDs[parameter] }
    }
    func entityDefinition(_ parameter: ApplicationSurfaceCatalog.SystemAction.Parameter) -> ApplicationSurfaceCatalog.Entity? {
        catalog?.entities?.first { $0.typeID == parameter.typeID }
    }
    func entityQueryChanged(_ parameter: String) {
        invalidatePendingCommand(); entityChoices[parameter] = nil; selectedEntityIDs[parameter] = nil; protectedEntityIDs[parameter] = nil
        entityExpectedBooleans = entityExpectedBooleans.filter { !$0.key.hasPrefix(parameter + ".") }
    }
    func canFindEntities(_ parameter: ApplicationSurfaceCatalog.SystemAction.Parameter) -> Bool {
        !busy && !closing && !unresolvedNormalAttempt && !unresolvedEntityQuery && !unresolvedSearch && !unresolvedReproduction && !unresolvedComparison &&
            pendingCommand == nil && !isUIWorkflow && preparedUISelectionMatches && parameter.family == "entity" && entityDefinition(parameter) != nil &&
            AutomationEntityQuery.acceptsQueryText(entityQueryTexts[parameter.name] ?? "")
    }
    func findEntities(_ parameter: ApplicationSurfaceCatalog.SystemAction.Parameter) async {
        guard canFindEntities(parameter), let prepared, let entity = entityDefinition(parameter), let action else { return }
        let epoch = selectionEpoch, text = entityQueryTexts[parameter.name] ?? "", install = installApproved
        let attemptID = UUID().uuidString
        let approval = RunApproval(runID: UUID().uuidString, app: prepared.host.app, target: prepared.host.target,
            environmentID: "selected-simulator:" + prepared.host.target.id, effects: [.observe], maximumActions: 20, disposable: disposable)
        let queryPlan: AutomationCase
        do { queryPlan = try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: text, approval: approval) }
        catch { message = errorText(error); return }
        progress = "Reading real records from this app…"; message = nil
        entityChoices[parameter.name] = nil; selectedEntityIDs[parameter.name] = nil; protectedEntityIDs[parameter.name] = nil
        task = Task {
            defer { progress = nil; task = nil; releaseScopeIfClosing() }
            do {
                let result: AutomationEntityQueryResult
                if let entityQueryExecutor { result = try await entityQueryExecutor(prepared, entity, text, approval, attemptID, install, support) }
                else {
                    let runner = try AutomationApplicationRunner(supportRoot: support, developerDirectory: developerDirectory)
                    result = try await AutomationEntityQuery.execute(runner: runner, prepared: prepared, entity: entity, text: text,
                        approval: approval, attemptID: attemptID, allowBootAndInstall: install)
                }
                // Retain unresolved device facts even if selection changed while reading.
                guard result.report.attemptID == attemptID else { throw AutomationContractError.conflictingOperation }
                entityQueryReport = result.report
                unresolvedEntityQueryAttemptID = nil
                await importEvidence(plan: queryPlan, report: result.report)
                try Task.checkCancellation()
                guard !closing, selectionEpoch == epoch, self.prepared == prepared, actionID == action.id,
                      entityQueryTexts[parameter.name] == text, installApproved == install else { throw AutomationContractError.conflictingOperation }
                entityChoices[parameter.name] = result.choices
                message = result.selectionGap ?? (result.choices.isEmpty ? "No records returned by this query." : nil)
                await refreshSavedCases()
            } catch {
                // A thrown preparation/persistence failure may have retained target ownership.
                // Keep its exact ID inspectable and block admission when no report was recovered.
                if entityQueryReport?.attemptID != attemptID { unresolvedEntityQueryAttemptID = attemptID }
                message = errorText(error) + " (query attempt " + attemptID + ")"
                await refreshSavedCases()
            }
        }
        await task?.value
    }
    private func clearEntitySelections() {
        entityQueryTexts = [:]; entityChoices = [:]; selectedEntityIDs = [:]; entityExpectedBooleans = [:]; protectedEntityIDs = [:]
    }
    private var unresolvedComparison: Bool {
        comparisonReport.map { ($0.before + $0.after).contains { !$0.resourcesReleased || $0.result.subjectDispatchUncertain } || $0.interruption?.dispatchMayHaveOccurred == true } ?? false
    }
    var canSelectFix: Bool { (isInstalledUI || isInstalledMacUI) && canReproduceSavedFailure && pendingCommand == nil }
    var canPrepareSourceFix: Bool { !isInstalledUI && !isInstalledMacUI && canPrepare && canReproduceSavedFailure && pendingCommand == nil }
    var canCheckFix: Bool {
        guard canUseSavedFailure(commandKind: .fixComparison) else { return false }
        if isInstalledMacUI { return fixedMacProduct != nil }
        guard installApproved else { return false }
        if isInstalledUI { return fixedProduct != nil }
        guard let before = sourceSavedBaseline, let after = prepared else { return false }
        return (try? AutomationNativeUIFixComparisonProposal.validatePreparedCandidate(before: before, after: after)) != nil
    }
    var fixedAppName: String? {
        if isInstalledUI || isInstalledMacUI { return fixedBundleURL?.lastPathComponent }
        guard let before = sourceSavedBaseline, let after = prepared,
              (try? AutomationNativeUIFixComparisonProposal.validatePreparedCandidate(before: before, after: after)) != nil else { return nil }
        return after.host.app.bundleID
    }
    func selectFixedBundle(_ url: URL) {
        guard canSelectFix else { return }
        clearFixedSelection()
        let scope = url.startAccessingSecurityScopedResource()
        do {
            guard let frozen = savedViewedCase else { throw AutomationContractError.conflictingOperation }
            if isInstalledMacUI {
                guard let target = selectedMacTarget, try nativeMacTargetReader() == target else { throw AutomationContractError.conflictingOperation }
                let product = try AutomationInstalledMacUIApplication.comparisonCandidate(bundleURL: url, target: target, baseline: frozen.plan.app)
                _ = try AutomationFixContract.candidate(from: frozen, app: product.app)
                fixedBundleURL = url; fixedMacProduct = product; hasFixedSecurityScope = scope; message = nil; return
            }
            let product = try AutomationInstalledUIApplication.comparisonCandidate(bundleURL: url,
                target: .init(id: simulatorID, kind: .simulator), baseline: frozen.plan.app)
            _ = try AutomationFixContract.candidate(from: frozen, app: product.app)
            fixedBundleURL = url; fixedProduct = product; hasFixedSecurityScope = scope; message = nil
        } catch { if scope { url.stopAccessingSecurityScopedResource() }; message = errorText(error) }
    }
    private func makeComparisonRequest(runID: String) async throws -> AutomationNativeFixComparisonRequest {
        guard let original = savedViewedReport else { throw AutomationContractError.conflictingOperation }
        let request = try await makeReproductionRequest(runID: runID)
        if case .installedMacUI(let before) = request.subject {
            guard let url = fixedBundleURL, let selected = fixedMacProduct, let provider = macSavedRuntimeProvider else { throw AutomationContractError.conflictingOperation }
            let after = try AutomationInstalledMacUIApplication.comparisonCandidate(bundleURL: url, target: before.target, baseline: before.app)
            guard after.app == selected.app else { throw AutomationContractError.conflictingOperation }
            return try provider().comparison(frozen: request.proposal.frozen, original: original, before: before, after: after, runID: runID)
        }
        guard installApproved else { throw AutomationContractError.conflictingOperation }
        let before = request.subject, after: AutomationApplicationSubject
        switch before {
        case .installedMacUI: throw AutomationContractError.missingEvidence("Mac installed-app execution is not qualified")
        case .installedPhysicalUI:
            throw AutomationContractError.missingEvidence("Unreadable installed apps cannot establish an exact-build comparison")
        case .installedUI(let baseline):
            guard let url = fixedBundleURL, let selected = fixedProduct else { throw AutomationContractError.conflictingOperation }
            let product = try AutomationInstalledUIApplication.comparisonCandidate(bundleURL: url, target: baseline.target, baseline: baseline.app)
            guard product.app == selected.app else { throw AutomationContractError.conflictingOperation }
            after = .installedUI(product)
        case .prepared(let baseline):
            guard let candidate = prepared else { throw AutomationContractError.conflictingOperation }
            try AutomationNativeUIFixComparisonProposal.validatePreparedCandidate(before: baseline, after: candidate)
            after = .prepared(candidate)
        }
        let runtime = try uiRuntimeProvider?() ?? AutomationNativeUIRuntime.bundled(stateDirectory: support.appendingPathComponent("ui-preview"))
        let proposal = try AutomationNativeUIFixComparisonProposal.compile(frozen: request.proposal.frozen, original: original,
            before: before, after: after, runtime: runtime, runID: runID, disposable: disposable)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fields = ["original": AutomationArtifactRegistry.digest(try encoder.encode(original)), "baseline": proposal.baseline.digest,
            "candidate": proposal.candidate.digest, "runtime": runtime.manifestDigest, "runtimeTeam": runtime.runtime.expectedTeamID,
            "beforeBuild": try comparisonBuildDigest(before), "afterBuild": try comparisonBuildDigest(after), "install": "true", "disposable": String(disposable),
            "attemptsPerBuild": String(proposal.attemptsPerBuild), "uiActions": String(proposal.limits.uiActions),
            "controllerCalls": String(proposal.limits.controllerCalls), "wallClockSeconds": String(proposal.limits.wallClockSeconds)]
        return .init(proposal: proposal, before: before, after: after, runtime: runtime.runtime,
            digest: AutomationArtifactRegistry.digest(try encoder.encode(fields)), originalAttemptID: original.attemptID)
    }
    private func comparisonBuildDigest(_ subject: AutomationApplicationSubject) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch subject {
        case .installedMacUI: throw AutomationContractError.missingEvidence("Mac installed-app execution is not qualified")
        case .installedPhysicalUI: throw AutomationContractError.missingEvidence("Unreadable installed apps cannot establish an exact-build comparison")
        case .installedUI(let app): return AutomationArtifactRegistry.digest(try encoder.encode(app.app))
        case .prepared(let app): return AutomationArtifactRegistry.digest(try encoder.encode(app))
        }
    }
    func checkFix() async {
        guard canCheckFix else { return }
        let commandID = pendingCommand
        guard commandID == nil || commandRequests[commandID!]?.kind == .fixComparison else { return }
        let runID = commandID?.uuidString ?? UUID().uuidString
        pendingCommand = nil; activeCommand = commandID
        if let commandID { commandRequests[commandID]?.state = "running" }
        progress = "Verifying both retained builds…"; message = nil
        task = Task {
            defer { progress = nil; task = nil; activeCommand = nil; clearFixedSelection(); releaseScopeIfClosing() }
            do {
                let request = try await makeComparisonRequest(runID: runID)
                if let commandID {
                    guard activeCommand == commandID, commandRequests[commandID]?.state == "running",
                          commandRequests[commandID]?.kind == .fixComparison, commandRequests[commandID]?.digest == request.digest else {
                        commandRequests[commandID]?.state = "invalidated"; throw AutomationContractError.conflictingOperation
                    }
                }
                try Task.checkCancellation()
                advanceSelection(); progress = "Checking the unchanged case 30 times on each build…"
                let result: AutomationFixComparisonReport
                if let comparisonExecutor { result = try await comparisonExecutor(request.proposal, request.before, request.after, request.runtime, support) }
                else { result = try await request.proposal.execute(before: request.before, after: request.after, runtime: request.runtime, support: support, developerDirectory: developerDirectory) }
                comparisonReport = result
                guard result.baseline == request.proposal.baseline, result.candidate == request.proposal.candidate,
                      result.beforeRunID == request.proposal.beforeApproval.runID, result.afterRunID == request.proposal.afterApproval.runID else { throw AutomationContractError.conflictingOperation }
                let outcome = try AutomationNativeFixComparisonOutcome(result, originalAttemptID: request.originalAttemptID)
                if let commandID {
                    commandRequests[commandID]?.comparison = outcome; commandRequests[commandID]?.resourcesReleased = outcome.resourcesReleased
                    commandRequests[commandID]?.state = "completed"
                }
                for attempt in result.before { await importEvidence(plan: result.baseline.plan, report: attempt, announce: false) }
                for attempt in result.after { await importEvidence(plan: result.candidate.plan, report: attempt, announce: false) }
                if evidenceImporter != nil { evidenceImportRevision += 1 }
                try await AutomationFixComparisonArchive(caseStoreRoot: support.appendingPathComponent("Cases")).save(result)
                await refreshSavedCases()
            } catch {
                message = errorText(error)
                if let commandID, !["completed", "invalidated"].contains(commandRequests[commandID]?.state ?? "") {
                    commandRequests[commandID]?.state = error is CancellationError ? "cancelled" : "failed"
                }
                await refreshSavedCases()
            }
        }
        await task?.value
    }
    func clearFixedSelection() {
        if hasFixedSecurityScope { fixedBundleURL?.stopAccessingSecurityScopedResource() }
        hasFixedSecurityScope = false; fixedBundleURL = nil; fixedProduct = nil; fixedMacProduct = nil
    }
    var canFindFailures: Bool {
        let phrases = uiAlternatePhrases.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return canRun && pendingCommandStatus == nil && isUIWorkflow && effectChoice == "navigation" && !uiExpectedText.isEmpty &&
            (1...2).contains(phrases.count) && Set(phrases).count == phrases.count && phrases.allSatisfy({ $0.utf16.count <= 4096 && $0 != uiInstruction })
    }
    func findFailures(reviewed: AutomationNativeSearchReview? = nil) async {
        guard canFindFailures else { return }
        let request: AutomationNativeRunRequest
        let proposal: AutomationNativeUIFailureSearchProposal
        let runID = UUID().uuidString
        do {
            request = try makeUIRunRequest(runID: runID)
            proposal = try .compile(plan: request.plan, approval: request.approval, alternatePhrases: uiAlternatePhrases)
            if let reviewed {
                guard reviewed.selectionEpoch == selectionEpoch, reviewed.digest == (try Self.nativeSearchDigest(request, proposal)) else {
                    throw AutomationContractError.conflictingOperation
                }
            }
        } catch { message = errorText(error); return }
        guard let runtime = request.uiRuntime else { return }
        advanceSelection(); report = nil; reportDirectory = nil; searchReport = nil; message = nil
        progress = "Exploring the approved UI phrases…"
        task = Task {
            defer { progress = nil; task = nil; releaseScopeIfClosing() }
            do {
                let result: AutomationFailureSearchReport
                if let searchExecutor { result = try await searchExecutor(proposal, request.subject, runtime, support, request.installApproved) }
                else { result = try await proposal.execute(subject: request.subject, runtime: runtime, support: support, developerDirectory: developerDirectory, allowBootAndInstall: request.installApproved) }
                // Retain uncertain results even if their archive cannot be written.
                searchReport = result
                for attempt in result.attempts {
                    if let frozen = ([proposal.baseline] + proposal.mutations.map(\.frozen)).first(where: { $0.digest == attempt.caseDigest }) {
                        await importEvidence(plan: frozen.plan, report: attempt.report, announce: false)
                    }
                }
                if evidenceImporter != nil { evidenceImportRevision += 1 }
                let archive = try AutomationUIFailureSearchArchive(caseStoreRoot: support.appendingPathComponent("Cases"))
                try await archive.save(.init(id: runID, runID: runID, baseline: proposal.baseline, mutations: proposal.mutations, report: result))
                await refreshSavedCases()
            } catch { message = errorText(error); await refreshSavedCases() }
        }
        await task?.value
    }
    func select(_ url: URL) {
        guard !busy else { return }
        sourceGrants.clear()
        if hasSecurityScope { selectedURL?.stopAccessingSecurityScopedResource() }
        selectedURL = url; hasSecurityScope = url.startAccessingSecurityScopedResource(); closing = false
        clearPrepared(); message = nil
        do {
            intake = try AutomationApplicationIntake.assess(url)
            candidateID = intake?.candidates.first?.id ?? ""
            selectCandidate()
        } catch { intake = nil; message = errorText(error) }
    }
    func selectCandidate() {
        guard !busy, !closing else { return }
        clearPrepared()
        configuration = candidate?.configurations.first ?? ""
        if isInstalledMacUI {
            do { selectedMacTarget = try nativeMacTargetReader() }
            catch { message = errorText(error) }
        }
        if let app = candidate?.app {
            do { catalog = try AutomationSurfaceCatalogReader.read(app: app, product: URL(fileURLWithPath: candidate!.containerPath)) }
            catch { message = errorText(error) }
        }
    }
    func refreshTargets() async {
        guard !busy, !closing else { return }
        guard needsSimulatorInventory else { return }
        simulatorInventoryRevision += 1
        let revision = simulatorInventoryRevision, selection = simulatorInventorySelection
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let targets = try await simulatorInventoryReader(developerDirectory, support)
            guard !busy, !closing, !Task.isCancelled, simulatorInventoryRevision == revision,
                  simulatorInventorySelection == selection, needsSimulatorInventory else { return }
            simulators = targets
            if !simulators.contains(where: { $0.id == simulatorID }) { simulatorID = simulators.first?.id ?? "" }
        } catch {
            guard !busy, !closing, !Task.isCancelled, simulatorInventoryRevision == revision,
                  simulatorInventorySelection == selection, needsSimulatorInventory else { return }
            message = errorText(error)
        }
    }
    func prepare(expectedTarget: TargetIdentity? = nil) {
        guard canPrepare, let candidate, let selectedURL, let target = sourcePreparationTarget else { return }
        guard expectedTarget == nil || target == expectedTarget else { message = "The build destination changed. Review it again."; return }
        message = nil; progress = "Freezing source and building an associated host…"
        let root = ["xcodeproj", "xcworkspace"].contains(selectedURL.pathExtension.lowercased()) ? selectedURL.deletingLastPathComponent() : selectedURL
        let destination = preparationDestination, epoch = selectionEpoch
        let approval = AutomationBuildApproval(sourceRoot: root.path, candidateID: candidate.id, configuration: configuration, target: target,
            additionalSourceRoots: sourceGrants.urls.map(\.path))
        task = Task {
            defer { progress = nil; task = nil; releaseScopeIfClosing() }
            do {
                let session = support.appendingPathComponent("prepare-" + UUID().uuidString)
                let value: AutomationPreparedApplication
                if let preparationExecutor { value = try await preparationExecutor(candidate, approval, session) }
                else {
                    guard let templates = Bundle.main.url(forResource: "AutomationHost", withExtension: nil) else {
                        throw AutomationContractError.missingEvidence("Associated host templates are missing from this app build")
                    }
                    value = try await preparation.prepare(candidate: candidate, approval: approval, sessionRoot: session,
                        templates: templates, developerDirectory: developerDirectory)
                }
                try Task.checkCancellation()
                guard !closing, self.selectedURL == selectedURL, candidateID == candidate.id,
                      configuration == approval.configuration, preparationDestination == destination,
                      selectionEpoch == epoch, sourcePreparationTarget == target,
                      sourceGrants.urls.map(\.path) == (approval.additionalSourceRoots ?? []) else {
                    throw AutomationContractError.conflictingOperation
                }
                try validatePreparedSelection(value, candidate: candidate, approval: approval)
                let siriProfile = try await AutomationSiriCapabilitySnapshot.resolve(prepared: value, capabilities: AutomationEntityQuery.capabilities(value))
                guard selectionEpoch == epoch, sourcePreparationTarget == target, !closing else { throw AutomationContractError.conflictingOperation }
                prepared = value; siriCapabilities = siriProfile; catalog = value.catalog; actionID = ""; report = nil
                message = target.kind == .nativeMac ? "Prepared a private Mac copy for inspection. Mac workflow execution is not available yet." : fixedAppName == nil ? "Prepared a private copy. Choose a workflow and its permitted effects." : "Prepared the changed source. The original build and saved checks are retained for Check fix."
            } catch { message = errorText(error) }
        }
    }
    func prepareAndWait() async { prepare(); await task?.value }
    func waitForPreparation() async { let active = task; await active?.value }
    func selectAction() { guard !busy else { return }; advanceSelection(); clearEntitySelections(); inputs = [:]; freshNameProperty = ""; freshStateProperty = ""; freshInitialState = ""; freshExpectedState = ""; freshProtectOtherRecord = false; freshContextProperty = ""; freshSelectedContext = ""; freshProtectedContext = ""; effectChoice = ""; effectsConfirmed = false; report = nil; message = nil }
    func workflowSelectionChanged() { guard !busy else { return }; advanceSelection(); effectsConfirmed = false; report = nil; message = nil }
    func effectSelectionChanged() { invalidatePendingCommand(); effectsConfirmed = false }
    func run() {
        guard canRun, pendingCommandStatus?.kind == nil else { return }
        let commandID = pendingCommand
        let runID = commandID?.uuidString ?? UUID().uuidString
        let request: AutomationNativeRunRequest
        do {
            request = try makeNativeRunRequest(runID: runID)
            if let commandID {
                guard commandRequests[commandID]?.digest == request.digest else {
                    invalidatePendingCommand()
                    throw AutomationContractError.conflictingOperation
                }
            }
        } catch { message = errorText(error); return }
        pendingCommand = nil; activeCommand = commandID
        if let commandID { commandRequests[commandID]?.state = "running" }
        advanceSelection()
        report = nil; canonicalEvidence = nil; reportDirectory = nil; message = nil; progress = "Running the approved action…"
        let attemptID = UUID().uuidString
        if let commandID {
            commandRequests[commandID]?.attemptID = attemptID
            commandRequests[commandID]?.caseID = request.plan.id
            commandRequests[commandID]?.revision = request.plan.revision
            commandRequests[commandID]?.caseDigest = request.caseDigest
        }
        let finishTelemetry = telemetry?.beginAutomationRun()
        task = Task {
            defer { progress = nil; task = nil; activeCommand = nil; releaseScopeIfClosing() }
            do {
                reportDirectory = support.appendingPathComponent(attemptID)
                let result: AutomationAttemptReport
                if let runExecutor {
                    result = try await runExecutor(request.subject, request.plan, request.approval, request.capabilities, attemptID, request.installApproved)
                } else {
                    let runner = try AutomationApplicationRunner(supportRoot: support, developerDirectory: developerDirectory)
                    result = try await runNativePreparedRequest(request, runner: runner, attemptID: attemptID)
                    if isFreshRecordWorkflow, !useLearnedSetup,
                       let bindings = try? AutomationFreshEntityPlanner.bindings(plan: request.plan),
                       let captured = try? await runner.captureFreshSetup(bindings: bindings) {
                        retainLearnedSetup(captured)
                    }
                }
                finishTelemetry?(.success(result))
                report = result
                if let commandID {
                    commandRequests[commandID]?.state = "completed"
                    commandRequests[commandID]?.result = result.result
                    commandRequests[commandID]?.resourcesReleased = result.resourcesReleased
                }
                await importEvidence(plan: request.plan, report: result)
                await refreshSavedCases()
            } catch {
                finishTelemetry?(.failure(error))
                message = errorText(error)
                if let commandID { commandRequests[commandID]?.state = error is CancellationError ? "cancelled" : "failed" }
                await refreshSavedCases()
            }
        }
    }
    func importEvidence(plan: AutomationCase, report: AutomationAttemptReport, announce: Bool = true) async {
        guard let evidenceImporter else { return }
        let epoch = selectionEpoch, savedRequestID = savedViewRequestID
        do {
            let frozen = try AutomationFrozenCase(plan: plan)
            let exposure = try reserveEvidenceExposure(frozen, attempts: [report])
            let document = try await evidenceImporter(plan, report, support, exposure)
            try document.validate()
            guard document.frozen.plan == plan, document.report == report else { throw AutomationContractError.conflictingOperation }
            if announce { evidenceImportRevision += 1 }
            if !closing, selectionEpoch == epoch, self.report == report { canonicalExposure = exposure; canonicalEvidence = document }
            if !Task.isCancelled, !closing, selectionEpoch == epoch, savedViewRequestID == savedRequestID, savedViewedCase?.plan == plan, savedViewedReport == report { canonicalSavedExposure = exposure; canonicalSavedEvidence = document }
        } catch {
            guard !closing, selectionEpoch == epoch, savedViewRequestID == savedRequestID else { return }
            evidenceImportMessage = "Native result import for attempt " + report.attemptID + " could not be verified. Its original record is retained: " + errorText(error)
        }
    }
    func migrateEvidenceHistory() async {
        guard !hasMigratedEvidenceHistory, !migratingEvidenceHistory, !closing, let evidenceImporter else { return }
        migratingEvidenceHistory = true; defer { migratingEvidenceHistory = false }
        do {
            let caseRoot = support.appendingPathComponent("Cases")
            guard FileManager.default.fileExists(atPath: caseRoot.path) else { hasMigratedEvidenceHistory = true; return }
            let cases = try AutomationCaseStore(readOnlyRoot: caseRoot)
            var count = 0
            for frozen in try await cases.definitions() {
                for report in try await cases.attempts(for: frozen) {
                    guard count < 1000 else { throw AutomationContractError.missingEvidence("Native history import exceeds 1000 attempts; original records remain available") }
                    let exposure = try reserveEvidenceExposure(frozen, attempts: [report])
                    let document = try await evidenceImporter(frozen.plan, report, support, exposure)
                    try document.validate()
                    guard document.frozen == frozen, document.report == report else { throw AutomationContractError.conflictingOperation }
                    count += 1
                }
            }
            hasMigratedEvidenceHistory = true; evidenceImportRevision += 1
        } catch { evidenceImportMessage = "Existing attempts remain saved; native history import is incomplete: " + errorText(error) }
    }
    func readSavedCases() async throws -> [AutomationFrozenCase] {
        if let savedCasesReader { return try await savedCasesReader() }
        return try await AutomationCaseStore(root: support.appendingPathComponent("Cases")).definitions()
    }
    func readSavedAttempt(caseID: String, revision: Int, digest: String, attemptID: String) async throws -> AutomationAttemptReport {
        let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
        let frozen = try await cases.load(id: caseID, revision: revision, digest: digest)
        return try await cases.loadAttempt(id: attemptID, frozen: frozen)
    }
    func refreshSavedCases() async {
        do {
            savedCases = try await readSavedCases()
            if FileManager.default.fileExists(atPath: support.appendingPathComponent("Cases/Searches").path) {
                savedSearches = try await AutomationUIFailureSearchArchive(caseStoreRoot: support.appendingPathComponent("Cases")).records()
            }
            if FileManager.default.fileExists(atPath: support.appendingPathComponent("Cases/FixComparisons").path) {
                savedComparisons = try await AutomationFixComparisonArchive(caseStoreRoot: support.appendingPathComponent("Cases")).records()
            }
            if FileManager.default.fileExists(atPath: support.appendingPathComponent("Cases/Reproductions").path) {
                savedReproductions = try await AutomationReproductionArchive(caseStoreRoot: support.appendingPathComponent("Cases")).records()
            }
        }
        catch { message = "Saved case integrity could not be verified." }
    }
    /// Read-only export snapshot. Capsule selection never changes execution approval or the viewed result.
    func capsuleExportSelection(_ frozen: AutomationFrozenCase) async throws -> (AutomationFrozenCase, [AutomationAttemptReport], AutomationEvidenceExposure) {
        guard !busy, !closing, savedCases.contains(frozen) else { throw AutomationContractError.invalidIdentity }
        let attempts: [AutomationAttemptReport]
        if let savedAttemptsReader { attempts = try await savedAttemptsReader(frozen) }
        else { attempts = try await AutomationCaseStore(readOnlyRoot: support.appendingPathComponent("Cases")).attempts(for: frozen) }
        guard !busy, !closing, savedCases.contains(frozen), attempts.count <= 100 else { throw AutomationContractError.invalidIdentity }
        let exposure = try reserveEvidenceExposure(frozen, attempts: attempts)
        return (frozen, attempts, exposure)
    }
    /// The approval reflects the review toggle, so the core export rejects an unreviewed selection.
    func exportCapsule(_ selection: AutomationCapsuleExportSelection, to url: URL) async throws {
        guard !busy, !closing else { throw AutomationContractError.targetBusy }
        try await Task.detached {
            try AutomationCaseCapsule.exportCompressed(frozen: selection.frozen, attempts: selection.attempts,
                approval: selection.approval, exposure: selection.exposure, to: url)
        }.value
    }
    private func reserveEvidenceExposure(_ frozen: AutomationFrozenCase, attempts: [AutomationAttemptReport]) throws -> AutomationEvidenceExposure {
        try AutomationEvidenceExposureAuthority(supportRoot: support).reserve(frozen: frozen, attempts: attempts)
    }
    func cancel() { task?.cancel() }
    func previewCommand() throws -> AutomationNativeCommandPreview {
        let request = try makeNativeRunRequest(runID: "preview")
        return .init(digest: request.digest, bundleID: request.plan.app.bundleID, targetID: request.plan.target.id,
            environmentID: request.plan.environmentID, action: request.plan.execution.operation,
            effects: request.approval.effects.map(\.rawValue).sorted(), maximumActions: request.approval.maximumActions,
            installApproved: request.installApproved, disposable: request.approval.disposable)
    }
    func previewReproductionCommand() async throws -> AutomationNativeReproductionPreview {
        guard canReproduceSavedFailure else { throw AutomationContractError.targetBusy }
        let request = try await makeReproductionRequest(runID: "preview")
        return .init(digest: request.digest, bundleID: request.subject.app.bundleID, targetID: request.subject.target.id,
            environmentID: request.proposal.frozen.plan.environmentID, caseID: request.proposal.frozen.plan.id,
            revision: request.proposal.frozen.plan.revision, caseDigest: request.proposal.frozen.digest,
            originalAttemptID: request.proposal.originalAttemptID, requestedAttempts: 5,
            installApproved: request.installApproved, disposable: request.proposal.approval.disposable)
    }
    func requestReproductionCommand(id: UUID, digest: String, nativeConfirmation: Bool = false) async throws -> AutomationNativeCommandStatus {
        guard !closing else { throw AutomationContractError.targetBusy }
        guard nativeConfirmation || !commandHistory.isNative(id) else { throw AutomationContractError.conflictingOperation }
        if let existing = commandRequests[id] {
            guard existing.digest == digest, existing.kind == .reproduction else { throw AutomationContractError.conflictingOperation }
            return existing
        }
        guard pendingCommand == nil, !busy, commandHistory.canAdmit(id, nativeConfirmation: nativeConfirmation, requests: commandRequests) else { throw AutomationContractError.targetBusy }
        let preview = try await previewReproductionCommand()
        // Durable reads suspend; an identical request may have queued meanwhile.
        if let existing = commandRequests[id] {
            guard existing.digest == digest, existing.kind == .reproduction else { throw AutomationContractError.conflictingOperation }
            return existing
        }
        guard !closing, !busy, pendingCommand == nil, commandHistory.canAdmit(id, nativeConfirmation: nativeConfirmation, requests: commandRequests),
              preview.digest == digest else { throw AutomationContractError.conflictingOperation }
        let status = AutomationNativeCommandStatus(requestID: id, digest: digest, state: "awaitingApproval", kind: .reproduction,
            originalAttemptID: preview.originalAttemptID, caseID: preview.caseID, revision: preview.revision, caseDigest: preview.caseDigest)
        commandRequests[id] = status; pendingCommand = id; commandHistory.admitted(id)
        message = "Review the saved failure and confirm Reproduce failure to run its frozen case five times."
        return status
    }
    func previewComparisonCommand() async throws -> AutomationNativeFixComparisonPreview {
        guard canCheckFix else { throw AutomationContractError.targetBusy }
        let request = try await makeComparisonRequest(runID: "preview")
        let proposal = request.proposal
        return .init(digest: request.digest, bundleID: request.before.app.bundleID, targetID: request.before.target.id,
            environmentID: proposal.baseline.plan.environmentID, caseID: proposal.baseline.plan.id, revision: proposal.baseline.plan.revision,
            caseDigest: proposal.baseline.digest, candidateCaseDigest: proposal.candidate.digest,
            beforeProductDigest: request.before.app.productDigest!, afterProductDigest: request.after.app.productDigest!,
            originalAttemptID: request.originalAttemptID, requestedAttemptsPerBuild: 30, installApproved: request.before.target.kind == .simulator, disposable: proposal.beforeApproval.disposable)
    }
    func requestComparisonCommand(id: UUID, digest: String, nativeConfirmation: Bool = false) async throws -> AutomationNativeCommandStatus {
        guard !closing else { throw AutomationContractError.targetBusy }
        guard nativeConfirmation || !commandHistory.isNative(id) else { throw AutomationContractError.conflictingOperation }
        if let existing = commandRequests[id] {
            guard existing.digest == digest, existing.kind == .fixComparison else { throw AutomationContractError.conflictingOperation }; return existing
        }
        guard pendingCommand == nil, !busy, commandHistory.canAdmit(id, nativeConfirmation: nativeConfirmation, requests: commandRequests) else { throw AutomationContractError.targetBusy }
        let preview = try await previewComparisonCommand()
        if let existing = commandRequests[id] {
            guard existing.digest == digest, existing.kind == .fixComparison else { throw AutomationContractError.conflictingOperation }; return existing
        }
        guard !closing, !busy, pendingCommand == nil, commandHistory.canAdmit(id, nativeConfirmation: nativeConfirmation, requests: commandRequests), preview.digest == digest else { throw AutomationContractError.conflictingOperation }
        let status = AutomationNativeCommandStatus(requestID: id, digest: digest, state: "awaitingApproval", kind: .fixComparison,
            originalAttemptID: preview.originalAttemptID, caseID: preview.caseID, revision: preview.revision, caseDigest: preview.caseDigest)
        commandRequests[id] = status; pendingCommand = id; commandHistory.admitted(id)
        message = "Review both builds and confirm Check fix to compare the unchanged case 30 times per build."
        return status
    }
    func commandStatus(id: UUID) throws -> AutomationNativeCommandStatus {
        guard let status = commandRequests[id] else { throw AutomationContractError.missingEvidence("This native execution request is unavailable") }
        return status
    }
    func cancelCommand(id: UUID) throws -> AutomationNativeCommandStatus {
        guard commandRequests[id] != nil else { throw AutomationContractError.missingEvidence("This native execution request is unavailable") }
        if pendingCommand == id { pendingCommand = nil; commandRequests[id]?.state = "cancelled" }
        else if activeCommand == id, ["running", "cancelling"].contains(commandRequests[id]!.state) {
            commandRequests[id]?.state = "cancelling"; cancel()
        }
        return commandRequests[id]!
    }
    func invalidatePendingCommand() {
        if let pendingCommand { commandRequests[pendingCommand]?.state = "invalidated" }
        pendingCommand = nil
    }
    func close() {
        closing = true; canonicalEvidence = nil; advanceSelection()
        cancel()
        if !busy { releaseScopeIfClosing() }
    }
    func closeAndWait() async {
        let active = task
        close()
        await active?.value
    }
    func preparationSelectionChanged() {
        advanceSelection()
        if let prepared, prepared.generatedHost.configuration != configuration || prepared.host.target != sourcePreparationTarget { clearPrepared() }
    }
    func selectAdditionalSourceFolder(_ url: URL) throws {
        guard !busy, !closing, candidate?.kind == .sourceTarget, let root = selectedSourceRoot else { throw AutomationContractError.targetBusy }
        try sourceGrants.add(url, primary: root)
        clearPrepared(); message = nil
    }
    func removeAdditionalSourceFolder(_ url: URL) {
        guard !busy, !closing, sourceGrants.urls.contains(url) else { return }
        sourceGrants.remove(url); clearPrepared(); message = nil
    }
    private func releaseScopeIfClosing() {
        if closing { clearFixedSelection(); sourceGrants.clear() }
        if closing, hasSecurityScope { selectedURL?.stopAccessingSecurityScopedResource(); hasSecurityScope = false }
    }
    func clearSavedView() { if !busy { clearFixedSelection() }; viewedComparison = nil; savedPreparedBaseline = nil; savedViewRequestID = nil; savedViewedReport = nil; savedViewedAttempts = []; savedAttemptLoading = false; canonicalSavedEvidence = nil; savedViewedCase = nil; savedViewedDirectory = nil; viewedSearch = nil; viewedReproduction = nil }
    private func advanceSelection() { invalidatePendingCommand(); selectionEpoch += 1; clearSavedView() }
    private func clearPrepared() { selectedMacTarget = nil; advanceSelection(); clearEntitySelections(); prepared = nil; siriCapabilities = .init(); siriRequest = ""; siriOracle = .init(); catalog = nil; report = nil; workflowRoute = "ui"; actionID = ""; inputs = [:]; effectChoice = ""; effectsConfirmed = false; uiInstruction = ""; uiEndpoint = ""; freshSaveControl = ""; uiApprovedText = ""; uiExpectedText = ""; uiObservationLabel = ""; uiObservationProperty = "text"; uiAlternatePhrases = ""; freshNamePrefix = ""; freshNameProperty = ""; freshStateProperty = ""; freshInitialState = ""; freshExpectedState = ""; freshProtectOtherRecord = false; freshContextProperty = ""; freshSelectedContext = ""; freshProtectedContext = ""; searchReport = nil }
    private func errorText(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled. Any pending dispatch is retained for review." }
        if let contract = error as? AutomationContractError {
            switch contract {
            case .invalidPlan(let reason), .missingEvidence(let reason): return reason
            case .targetBusy: return "The selected target is owned by another or unresolved run. Review its retained evidence before continuing."
            case .conflictingOperation: return "The selected source or prepared product changed. Prepare a fresh copy."
            case .ambiguousDispatch, .terminationUnverified: return "An operation or controller release is unresolved. Its journal is retained; it will not be retried automatically."
            default: break
            }
        }
        return "Preparation or execution could not be verified: \(error)"
    }
}

struct AutomationNativeCommandPreview: Codable, Sendable {
    var digest: String
    var bundleID: String
    var targetID: String
    var environmentID: String
    var action: String
    var effects: [String]
    var maximumActions: Int
    var installApproved: Bool
    var disposable: Bool
}
struct AutomationNativeCommandStatus: Codable, Sendable {
    var requestID: UUID
    var digest: String
    var state: String
    var kind: AutomationNativeCommandKind? = nil
    var originalAttemptID: String? = nil
    var reproduction: AutomationNativeReproductionOutcome? = nil
    var comparison: AutomationNativeFixComparisonOutcome? = nil
    var attemptID: String? = nil
    var result: AttemptResult? = nil
    var resourcesReleased: Bool? = nil
    var caseID: String? = nil
    var revision: Int? = nil
    var caseDigest: String? = nil
}
struct AutomationNativeRunRequest {
    var subject: AutomationApplicationSubject
    var uiRuntime: AutomationUIRuntime?
    var plan: AutomationCase
    var approval: RunApproval
    var capabilities: CapabilityProfile
    var installApproved: Bool
    var digest: String
    var caseDigest: String
    var siriQualification = false
}
typealias AutomationNativeRunExecutor = @Sendable (AutomationApplicationSubject, AutomationCase, RunApproval, CapabilityProfile, String, Bool) async throws -> AutomationAttemptReport

#endif
