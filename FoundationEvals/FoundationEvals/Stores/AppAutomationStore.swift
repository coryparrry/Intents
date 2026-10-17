#if os(macOS)
import Foundation
import Observation
import IntentsAutomationCore
#if canImport(FoundationEvalsDeveloper)
import FoundationEvalsDeveloper
#endif

@MainActor @Observable
final class AppAutomationStore {
    var intake: AutomationIntakeAssessment?
    var candidateID = ""
    var restoredCandidateID: String?
    var configuration = ""
    var simulators: [AutomationSimulator] = []
    var simulatorID = ""
    var physicalDeviceID = ""
    var physicalDevices: [AutomationPhysicalDevice] = []
    var siriRequest = ""
    var siriOracle = AutomationNativeSiriOracle()
    var siriAlternatePhrases = ""
    var siriResetActionID = ""
    var siriAccountEnvironment = ""
    var siriCapabilities = CapabilityProfile()
    var preparationDestination: AutomationNativePreparationDestination = .simulator
    var includesSourceDependencies = false
    var servedJavaScriptProfile: AutomationServedJavaScriptProfile?
    var automaticMetroRecipe: AutomationMetroAutomaticRecipe?
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
    var pairedClient: DeveloperRunnerClient?
    var pairedCanStart: (@MainActor () -> Bool)?
    let executionAdmissionOwnerID = UUID()
    var executionCanStart: (@MainActor () -> Bool)?
    var executionOwnershipChanged: (@MainActor (Bool) -> Void)? {
        didSet { publishedExecutionBlock = nil; publishExecutionOwnership() }
    }
    @ObservationIgnored private var executionAdmissionHeld = false
    @ObservationIgnored private var initialOwnershipCheckPending = true
    @ObservationIgnored private var publishedExecutionBlock: Bool?
    var pairedFeatureID = ""
    var pairedPrompt = ""
    var pairedInstructions = ""
    var pairedExpectedResponse = ""
    var pairedEffectsConfirmed = false
    var pairedExecutionUnresolved = false { didSet { publishExecutionOwnership() } }
    var firstRunIncludesActions = false
    var firstRunEffectsConfirmed = false
    var firstRunReports: [AutomationAttemptReport] = []
    var firstRunGaps: [String] = []
    var firstRunInputReviewID: String?
    var firstRunInputs: [String: [String: String]] = [:]
    var firstRunEntityQueryTexts: [String: [String: String]] = [:]
    var firstRunEntityChoices: [String: [String: [AutomationQueryEntityChoice]]] = [:]
    var firstRunSelectedEntityIDs: [String: [String: String]] = [:]
    var workflowRoute = "ui"
    var actionID = ""
    var inputs: [String: String] = [:]
    var entityQueryTexts: [String: String] = [:]
    var entityChoices: [String: [AutomationQueryEntityChoice]] = [:]
    var selectedEntityIDs: [String: String] = [:]
    var entityExpectedBooleans: [String: String] = [:]
    var protectedEntityIDs: [String: Set<String>] = [:]
    var entityQueryReport: AutomationAttemptReport? { didSet { publishExecutionOwnership() } }
    var unresolvedEntityQueryAttemptID: String? { didSet { publishExecutionOwnership() } }
    let entityQueryExecutor: AutomationNativeEntityQueryExecutor?
    var effectChoice = ""
    var effectsConfirmed = false
    var disposable = false
    var installApproved = true
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
        (try? AutomationNativeWorkflowSteps.locator(freshNameEntryControl)) != nil &&
        (try? AutomationNativeWorkflowSteps.locator(freshSaveControl)) != nil &&
        (try? AutomationNativeWorkflowSteps.locator(uiEndpoint)) != nil &&
        (freshContextEntryControl.isEmpty || (try? AutomationNativeWorkflowSteps.locator(freshContextEntryControl)) != nil) &&
        (freshCreateControl.isEmpty || (try? AutomationNativeWorkflowSteps.locator(freshCreateControl)) != nil)
    }
    var concreteUIWorkflowValid: Bool {
        guard let program = try? AutomationNativeWorkflowSteps.program(tapControls: uiTapControls, textEntry: uiTextEntryControl,
            approvedText: uiApprovedText, submitControl: uiSubmitControl, endpoint: uiEndpoint) else { return false }
        return program.operations.count + 2 + (uiExpectedText.isEmpty ? 0 : 1) <= 30
    }
    var freshContextValid: Bool {
        guard let freshContext else { return true }
        guard let entity = freshEntity else { return false }
        return (try? freshContext.validate(entity: entity, nameProperty: freshNameProperty)) != nil
    }
    var uiInstruction = ""
    var uiEndpoint = ""
    var freshSaveControl = ""
    var freshCreateControl = ""
    var freshNameEntryControl = ""
    var freshContextEntryControl = ""
    var uiTapControls = ""
    var uiTextEntryControl = ""
    var uiSubmitControl = ""
    var uiApprovedText = ""
    var uiExpectedText = ""
    var uiObservationLabel = ""
    var uiObservationProperty = "text"
    var searchReport: AutomationFailureSearchReport? { didSet { publishExecutionOwnership() } }
    var savedSearches: [AutomationUIFailureSearchRecord] = []
    var viewedSearch: AutomationUIFailureSearchRecord?
    var reproductionReport: AutomationReproductionReport? { didSet { publishExecutionOwnership() } }
    var savedReproductions: [AutomationReproductionReport] = []
    var viewedReproduction: AutomationReproductionReport?
    var comparisonReport: AutomationFixComparisonReport? { didSet { publishExecutionOwnership() } }
    var savedComparisons: [AutomationFixComparisonReport] = []
    var viewedComparison: AutomationFixComparisonReport?
    private var fixedBundleURL: URL?
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
    let runExecutor: AutomationNativeRunExecutor?
    let siriSearchExecutor: AutomationNativeSiriSearchExecutor?
    private let comparisonExecutor: AutomationNativeFixComparisonExecutor?
    private let reproductionExecutor: AutomationNativeReproductionExecutor?
    private let reproductionPreflightReader: (@Sendable (AutomationFrozenCase, String, URL) async throws -> (AutomationFrozenCase, AutomationAttemptReport))?
    var savedCases: [AutomationFrozenCase] = []
    var savedHistoryNotice: String?
    private(set) var retainedUnresolvedNormalReport: AutomationAttemptReport?
    private(set) var retainedUnresolvedNormalTarget: TargetIdentity?
    /// Actual destinations of finished requests whose reports or reservations remain unresolved.
    private(set) var retainedUnresolvedRequestTargets: [String: TargetIdentity] = [:] { didSet { publishExecutionOwnership() } }
    @ObservationIgnored var ownershipRecoveryTask: Task<Void, Never>?
    let recoverySimulatorShutdown: @Sendable (TargetIdentity, URL, URL) async throws -> Void
    var recoveryItems: [AutomationNativeRecoveryItem] = [] { didSet { publishExecutionOwnership() } }
    var recoveryError: String? { didSet { publishExecutionOwnership() } }
    var recoveryLoading = false
    var closingForOwnershipRecovery: Bool { closing }
    var report: AutomationAttemptReport? {
        didSet {
            if let report, !report.resourcesReleased || report.result.subjectDispatchUncertain {
                retainedUnresolvedNormalReport = report
                retainedUnresolvedNormalTarget = prepared?.host.target ?? sourcePreparationTarget
                    ?? (isInstalledUI && UUID(uuidString: simulatorID) != nil ? .init(id: simulatorID, kind: .simulator) : selectedMacTarget)
            }
            publishExecutionOwnership()
        }
    }
    private let evidenceImporter: (@Sendable (AutomationCase, AutomationAttemptReport, URL, AutomationEvidenceExposure) async throws -> AutomationNativeEvidenceDocument)?
    private var hasMigratedEvidenceHistory = false
    private var migratingEvidenceHistory = false
    private(set) var evidenceImportRevision = 0
    func noteCampaignEvidenceImport() {
        if evidenceImporter != nil { evidenceImportRevision += 1 }
    }
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
    var recentApplications: [AutomationRecentApplication] = []
    var recentApplicationsError: String?
    var progress: String?
    var selectedMacTarget: TargetIdentity?
    let nativeMacTargetReader: @Sendable () throws -> TargetIdentity
    var selectedURL: URL?
    let sourceGrants: AutomationNativeSourceGrants
    var selectedSourceRoot: URL? {
        selectedURL.map { ["xcodeproj", "xcworkspace"].contains($0.pathExtension.lowercased()) ? $0.deletingLastPathComponent() : $0 }
    }
    var isClosingForFirstRunInputs: Bool { closing }
    private(set) var requestVerificationCancellationID = UUID()
    private let physicalInventoryReader: AutomationNativePhysicalInventoryReader
    private(set) var installedToolchains: [AutomationNativeToolchainChoice] = []
    let defaultDeveloperDirectoryPath: String
    private var reviewedToolchainMetadata: [String: String] = [:]
    var hasExplicitToolchainSelection: Bool { !reviewedToolchainMetadata.isEmpty }
    var selectedToolchainMetadataDigest: String? { reviewedToolchainMetadata[developerDirectory.path] }
    private let installedToolchainReader: (URL) -> [AutomationNativeToolchainChoice]
    var hasSecurityScope = false
    var securityScopedURL: URL?
    var closing = false
    @ObservationIgnored private let telemetry: (any AutomationRunTelemetry)?
    var task: Task<Void, Never>?
    var commandRequests: [UUID: AutomationNativeCommandStatus] = [:]
    var commandHistory = AutomationCommandHistory()
    var pendingCommand: UUID?
    var activeCommand: UUID?
    var pendingCommandStatus: AutomationNativeCommandStatus? { pendingCommand.flatMap { commandRequests[$0] } }
    let support: URL
    private let preparation = AutomationPreparation()
    private let preparationExecutor: AutomationNativePreparationExecutor?
    private let simulatorInventoryReader: AutomationNativeSimulatorInventoryReader
    let intakeAssessor: @Sendable (URL) throws -> AutomationIntakeAssessment
    private let selectionCatalogReader: @Sendable (AppIdentity, URL) throws -> ApplicationSurfaceCatalog
    private let physicalTargetResolver: @Sendable (TargetIdentity, URL, URL) async throws -> TargetIdentity
    var resolvedPhysicalDeviceIdentifiers: [String: String] = [:]
    private var simulatorInventoryRevision = 0
    private let launchDeveloperDirectory: URL
    let xcodeSettings: AutomationNativeXcodeSettings
    var selectedXcodePath: String {
        get { xcodeSettings.path(for: preparationDestination) }
        set { guard !busy else { return }; xcodeSettings.setPath(newValue, for: preparationDestination); retainEffectiveToolchainSelection(); advanceSelection() }
    }
    var runXcodePathOverride: String {
        get { xcodeSettings.runOverride }
        set { guard !busy else { return }; xcodeSettings.runOverride = newValue; retainEffectiveToolchainSelection(); advanceSelection() }
    }
    var developerDirectory: URL {
        xcodeSettings.developerDirectory(for: isInstalledMacUI ? .macOS : preparationDestination, fallback: preparedDeveloperFallback)
    }
    private var preparedDeveloperFallback: URL {
        guard let path = prepared?.selectedDeveloperDirectoryPath else { return launchDeveloperDirectory }
        return URL(fileURLWithPath: path)
    }
    func developerDirectory(for target: TargetIdentity) -> URL {
        let destination: AutomationNativePreparationDestination = switch target.kind {
        case .simulator: .simulator
        case .physical: .physical
        case .nativeMac, .pairedRunner: .macOS
        }
        return xcodeSettings.developerDirectory(for: destination, fallback: preparedDeveloperFallback)
    }
    init(supportDirectory: URL, telemetry: (any AutomationRunTelemetry)? = nil, developerDirectory: URL = AutomationNativeToolchain.developerDirectory(),
         xcodeSettings: AutomationNativeXcodeSettings? = nil,
         savedAttemptsReader: (@Sendable (AutomationFrozenCase) async throws -> [AutomationAttemptReport])? = nil,
         savedCasesReader: (@Sendable () async throws -> [AutomationFrozenCase])? = nil, runExecutor: AutomationNativeRunExecutor? = nil,
         siriSearchExecutor: AutomationNativeSiriSearchExecutor? = nil,
         entityQueryExecutor: AutomationNativeEntityQueryExecutor? = nil,
         comparisonExecutor: AutomationNativeFixComparisonExecutor? = nil,
         reproductionExecutor: AutomationNativeReproductionExecutor? = nil,
         reproductionPreflightReader: (@Sendable (AutomationFrozenCase, String, URL) async throws -> (AutomationFrozenCase, AutomationAttemptReport))? = nil,
         nativeMacTargetReader: @escaping @Sendable () throws -> TargetIdentity = { try AutomationMacGUIIdentity.currentTarget() },
         evidenceImporter: (@Sendable (AutomationCase, AutomationAttemptReport, URL, AutomationEvidenceExposure) async throws -> AutomationNativeEvidenceDocument)? = nil,
         preparationExecutor: AutomationNativePreparationExecutor? = nil,
         sourceGrants: AutomationNativeSourceGrants? = nil,
         recoverySimulatorShutdown: @escaping @Sendable (TargetIdentity, URL, URL) async throws -> Void = { try await AppAutomationStore.shutdownRecoverySimulator($0, developerDirectory: $1, workspace: $2) },
         physicalTargetResolver: @escaping @Sendable (TargetIdentity, URL, URL) async throws -> TargetIdentity = { try await AutomationPhysicalDeviceInventory.canonicalTarget($0, developerDirectory: $1, workspace: $2) },
         intakeAssessor: @escaping @Sendable (URL) throws -> AutomationIntakeAssessment = { try AutomationApplicationIntake.assess($0) },
         selectionCatalogReader: @escaping @Sendable (AppIdentity, URL) throws -> ApplicationSurfaceCatalog = { try AutomationSurfaceCatalogReader.read(app: $0, product: $1) },
         simulatorInventoryReader: @escaping AutomationNativeSimulatorInventoryReader = { try await AutomationSimulatorInventory.read(developerDirectory: $0, workspace: $1) },
         physicalInventoryReader: @escaping AutomationNativePhysicalInventoryReader = { try await AutomationPhysicalDeviceInventory.read(developerDirectory: $0, workspace: $1) },
         installedToolchainReader: @escaping (URL) -> [AutomationNativeToolchainChoice] = { AutomationNativeToolchain.installedChoices(configured: $0) }) {
        self.physicalInventoryReader = physicalInventoryReader
        self.installedToolchainReader = installedToolchainReader
        defaultDeveloperDirectoryPath = developerDirectory.path
        let discoveredToolchains = installedToolchainReader(developerDirectory)
        installedToolchains = discoveredToolchains
        self.physicalTargetResolver = physicalTargetResolver
        self.intakeAssessor = intakeAssessor; self.selectionCatalogReader = selectionCatalogReader
        self.recoverySimulatorShutdown = recoverySimulatorShutdown
        launchDeveloperDirectory = developerDirectory
        self.xcodeSettings = xcodeSettings ?? AutomationNativeXcodeSettings()
        self.preparationExecutor = preparationExecutor
        self.sourceGrants = sourceGrants ?? AutomationNativeSourceGrants()
        self.simulatorInventoryReader = simulatorInventoryReader
        self.nativeMacTargetReader = nativeMacTargetReader
        self.evidenceImporter = evidenceImporter
        self.telemetry = telemetry
        support = supportDirectory; self.entityQueryExecutor = entityQueryExecutor; self.comparisonExecutor = comparisonExecutor; self.savedAttemptsReader = savedAttemptsReader
        self.savedCasesReader = savedCasesReader; self.runExecutor = runExecutor; self.siriSearchExecutor = siriSearchExecutor
        self.reproductionExecutor = reproductionExecutor; self.reproductionPreflightReader = reproductionPreflightReader
        ownershipRecoveryTask = Task { [weak self] in
            guard let self else { return }
            await reconcileAbandonedOwnership()
            await restorePairedOwnership()
            initialOwnershipCheckPending = false
            publishExecutionOwnership()
        }
        loadRecentApplications()
        restoreLatestPreparation()
    }
    var busy: Bool { progress != nil }
    /// This process shares admission with Intent Lab and ordinary evaluations.
    /// Durable target ownership remains in each engine's own lease store.
    var permitsExecutionAdmission: Bool {
        if executionAdmissionHeld { return true }
        guard executionCanStart?() != false else { return false }
        return executionOwnershipChanged == nil || (!initialOwnershipCheckPending && recoveryError == nil && !hasUnresolvedOwnership)
    }
    func beginExecutionAdmission(allowingRecovery: Bool = false) throws {
        guard !executionAdmissionHeld, !closing, executionCanStart?() != false,
              allowingRecovery || permitsExecutionAdmission else {
            throw AutomationContractError.targetBusy
        }
        executionAdmissionHeld = true
        publishExecutionOwnership()
    }
    func finishExecutionAdmission() {
        executionAdmissionHeld = false
        publishExecutionOwnership()
    }
    private func publishExecutionOwnership() {
        guard let executionOwnershipChanged else { return }
        let blocked = executionAdmissionHeld || initialOwnershipCheckPending || hasUnresolvedOwnership || recoveryError != nil
        guard publishedExecutionBlock != blocked else { return }
        publishedExecutionBlock = blocked
        executionOwnershipChanged(blocked)
    }
    var candidate: AutomationApplicationCandidate? { intake?.candidates.first { $0.id == candidateID } }
    var action: ApplicationSurfaceCatalog.SystemAction? { catalog?.systemActions.first { $0.id == actionID } }
    var canPrepare: Bool { !busy && !closing && candidate?.kind == .sourceTarget && !configuration.isEmpty && sourcePreparationTarget != nil && ((servedJavaScriptProfile == nil && automaticMetroRecipe == nil) || preparationDestination == .simulator) }
    var isInstalledUI: Bool { candidate?.kind == .installedProduct && candidate?.app?.platform == "ios" }
    var isFreshRecordWorkflow: Bool { candidate?.kind == .sourceTarget && workflowRoute == "fresh" }
    var freshEntity: ApplicationSurfaceCatalog.Entity? {
        guard let action, action.parameters.count == 1, let parameter = action.parameters.first, parameter.family == "entity" else { return nil }
        return catalog?.entities?.first { $0.typeID == parameter.typeID }
    }
    var isUIWorkflow: Bool { isInstalledUI || isInstalledMacUI || (candidate?.kind == .sourceTarget && workflowRoute == "ui") }
    var canRun: Bool {
        guard permitsExecutionAdmission, !closing, !pairedExecutionUnresolved, !unresolvedNormalAttempt, !unresolvedSearch, !unresolvedReproduction, !unresolvedComparison, !unresolvedEntityQuery else { return false }
        if isSiriWorkflow { return canRunSiriSubmission }
        guard prepared?.host.target.kind != .nativeMac, candidate?.kind != .sourceTarget || preparationDestination == .simulator else { return false }
        if isUIWorkflow {
            return preparedUISelectionMatches && concreteUIWorkflowValid && !busy && UUID(uuidString: simulatorID) != nil && !uiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
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
        searchReport?.interruptions.contains(where: \.dispatchMayHaveOccurred) == true ||
        searchReport?.qualificationAttempts?.contains(where: { !$0.report.resourcesReleased || $0.report.result.subjectDispatchUncertain }) == true
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
        guard permitsExecutionAdmission, !busy, !closing, !unresolvedNormalAttempt, !unresolvedSearch, !unresolvedReproduction, !unresolvedComparison, !unresolvedEntityQuery, permitsSavedWorkflow,
              pendingCommandStatus == nil || pendingCommandStatus?.kind == commandKind,
              effectsConfirmed, let frozen = savedViewedCase,
              let original = savedViewedReport else { return false }
        guard !isMacWorkflowUnavailable, frozen.plan.target.kind == .simulator, UUID(uuidString: simulatorID) != nil else { return false }
        return frozen.plan.app == (isInstalledUI ? candidate?.app : sourceSavedBaseline?.host.app) && frozen.plan.target.id == simulatorID &&
            original.result.summary == .assertionFailed && original.result.assessed && original.result.evidenceComplete &&
            original.resourcesReleased && !original.result.subjectDispatchUncertain &&
            report?.resourcesReleased != false && report?.result.subjectDispatchUncertain != true
    }
    func reproduceSavedFailure() async {
        guard canReproduceSavedFailure else { return }
        let commandID = pendingCommand
        guard commandID == nil || commandRequests[commandID!]?.kind == .reproduction else { return }
        do { try beginExecutionAdmission() } catch { message = errorText(error); return }
        let runID = commandID?.uuidString ?? UUID().uuidString
        pendingCommand = nil; activeCommand = commandID
        if let commandID { commandRequests[commandID]?.state = "running" }
        progress = "Verifying the saved failure…"; message = nil
        task = Task {
            defer { progress = nil; task = nil; activeCommand = nil; releaseScopeIfClosing(); finishExecutionAdmission() }
            var executedRequest: (String, TargetIdentity)?
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
                let proposal = request.proposal, subject = request.subject
                let casesRoot = support.appendingPathComponent("Cases")
                advanceSelection(); progress = "Reproducing the saved failure five times…"
                executedRequest = (proposal.approval.runID, proposal.frozen.plan.target)
                let result: AutomationReproductionReport
                if let reproductionExecutor { result = try await reproductionExecutor(proposal, subject, support, request.installApproved) }
                else { result = try await proposal.execute(subject: subject, support: support, developerDirectory: developerDirectory(for: request.subject.target), allowBootAndInstall: request.installApproved) }
                reproductionReport = result
                if unresolvedReproduction { retainUnresolvedRequest(runID: proposal.approval.runID, target: proposal.frozen.plan.target) }
                guard result.frozen == proposal.frozen, result.originalFailure.attemptID == proposal.originalAttemptID,
                      result.runID == proposal.approval.runID else { throw AutomationContractError.conflictingOperation }
                let outcome = try AutomationNativeReproductionOutcome(result)
                if let commandID {
                    commandRequests[commandID]?.reproduction = outcome
                    commandRequests[commandID]?.resourcesReleased = outcome.resourcesReleased
                    commandRequests[commandID]?.state = result.stopReason == "Cancelled" || result.attempts.contains { $0.result.summary == .cancelled } ? "cancelled" : "completed"
                }
                for attempt in [result.originalFailure] + result.attempts { await importEvidence(plan: result.frozen.plan, report: attempt, announce: false) }
                if evidenceImporter != nil { evidenceImportRevision += 1 }
                try await AutomationReproductionArchive(caseStoreRoot: casesRoot).save(result)
                await refreshSavedCases()
            } catch {
                if let (runID, target) = executedRequest { await retainUnresolvedReservation(runID: runID, target: target) }
                message = errorText(error)
                if let commandID, !["completed", "cancelled", "invalidated"].contains(commandRequests[commandID]?.state ?? "") {
                    pendingCommand = nil
                    commandRequests[commandID]?.state = error is CancellationError ? "cancelled" : "failed"
                }
                await refreshSavedCases()
            }
        }
        await task?.value
    }
    private func makeReproductionRequest(runID: String) async throws -> AutomationNativeReproductionRequest {
        guard !closing, !isMacWorkflowUnavailable, !unresolvedNormalAttempt, !unresolvedSearch, !unresolvedReproduction, !unresolvedComparison, !unresolvedEntityQuery, permitsSavedWorkflow, effectsConfirmed, let frozen = savedViewedCase, let original = savedViewedReport, let candidate else {
            throw AutomationContractError.missingEvidence("Select a released, assessed saved UI failure and its original app in the native window")
        }
        let epoch = selectionEpoch, viewID = savedViewRequestID, targetID = simulatorID
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
              savedViewedCase == frozen, savedViewedReport == original, candidateID == candidate.id, simulatorID == targetID,
              !unresolvedNormalAttempt, !unresolvedSearch, !unresolvedReproduction, !unresolvedComparison, !unresolvedEntityQuery, effectsConfirmed, permitsSavedWorkflow,
              installApproved == install, disposable == approvedDisposable else { throw AutomationContractError.conflictingOperation }
        let subject: AutomationApplicationSubject
        if isInstalledUI {
            let installed = try AutomationInstalledUIApplication(bundleURL: URL(fileURLWithPath: candidate.containerPath), target: .init(id: targetID, kind: .simulator))
            guard installed.app == candidate.app else { throw AutomationContractError.conflictingOperation }
            subject = .installedUI(installed)
        } else {
            guard let baseline = sourceSavedBaseline else { throw AutomationContractError.conflictingOperation }
            subject = .prepared(baseline)
        }
        let proposal = try AutomationNativeUIReproductionProposal.compile(frozen: stored, original: failure, subject: subject,
            runID: runID, disposable: approvedDisposable)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fields = ["case": stored.digest, "original": AutomationArtifactRegistry.digest(try encoder.encode(failure)),
            "install": String(install), "disposable": String(approvedDisposable), "attempts": "5",
            "uiActions": String(proposal.limits.uiActions), "controllerCalls": String(proposal.limits.controllerCalls),
            "wallClockSeconds": String(proposal.limits.wallClockSeconds)]
        return .init(proposal: proposal, subject: subject, installApproved: install,
            digest: AutomationArtifactRegistry.digest(try encoder.encode(fields)))
    }
    private var unresolvedNormalAttempt: Bool { !retainedUnresolvedRequestTargets.isEmpty || retainedUnresolvedNormalReport != nil || report?.result.subjectDispatchUncertain == true || report?.resourcesReleased == false }
    var hasUnresolvedActiveAttempt: Bool { pairedExecutionUnresolved || unresolvedNormalAttempt || unresolvedEntityQuery || unresolvedSearch || unresolvedReproduction || unresolvedComparison }
    var hasUnresolvedOwnership: Bool { !recoveryItems.isEmpty || hasUnresolvedActiveAttempt }
    private var permitsApplicationReview: Bool {
        !busy && !closing && !pairedExecutionUnresolved &&
            !unresolvedNormalAttempt && !unresolvedSearch && !unresolvedReproduction &&
            !unresolvedComparison && !unresolvedEntityQuery
    }
    var canSelectApplicationFromCommand: Bool { permitsApplicationReview && pendingCommandStatus == nil }
    var canReviewSelectedApplicationForRun: Bool {
        permitsApplicationReview && (pendingCommandStatus == nil ||
            (pendingCommandStatus?.kind == nil && pendingCommandStatus?.state == "awaitingApproval"))
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
        permitsExecutionAdmission && !busy && !closing && !pairedExecutionUnresolved && !unresolvedNormalAttempt && !unresolvedEntityQuery && !unresolvedSearch && !unresolvedReproduction && !unresolvedComparison &&
            pendingCommand == nil && !isUIWorkflow && preparedUISelectionMatches && parameter.family == "entity" && entityDefinition(parameter) != nil &&
            entityDefinition(parameter).map { AutomationEntityQuery.acceptsQuery(entity: $0, text: $0.usesSuggestedQuery ? "" : entityQueryTexts[parameter.name] ?? "") } == true
    }
    func findEntities(_ parameter: ApplicationSurfaceCatalog.SystemAction.Parameter) async {
        guard canFindEntities(parameter), let prepared, let entity = entityDefinition(parameter), let action else { return }
        if entity.usesSuggestedQuery { entityQueryTexts[parameter.name] = "" }
        let epoch = selectionEpoch, text = entityQueryTexts[parameter.name] ?? "", install = installApproved
        let attemptID = UUID().uuidString
        let environment = prepared.host.target.kind == .nativeMac
            ? "selected-mac-session:" + (prepared.host.target.loginSession ?? "")
            : "selected-simulator:" + prepared.host.target.id
        let approval = RunApproval(runID: UUID().uuidString, app: prepared.host.app, target: prepared.host.target,
            environmentID: environment, effects: [.observe], maximumActions: 20, disposable: disposable)
        let queryPlan: AutomationCase
        do { queryPlan = try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: text, approval: approval) }
        catch { message = errorText(error); return }
        do { try beginExecutionAdmission() } catch { message = errorText(error); return }
        progress = "Reading real records from this app…"; message = nil
        entityChoices[parameter.name] = nil; selectedEntityIDs[parameter.name] = nil; protectedEntityIDs[parameter.name] = nil
        task = Task {
            defer { progress = nil; task = nil; releaseScopeIfClosing(); finishExecutionAdmission() }
            do {
                let result: AutomationEntityQueryResult
                if let entityQueryExecutor { result = try await entityQueryExecutor(prepared, entity, text, approval, attemptID, install, support) }
                else {
                    let runner = try AutomationApplicationRunner(supportRoot: support, developerDirectory: developerDirectory(for: prepared.host.target))
                    result = try await AutomationEntityQuery.execute(runner: runner, prepared: prepared, entity: entity, text: text,
                        approval: approval, attemptID: attemptID, allowBootAndInstall: install)
                }
                // Retain unresolved device facts even if selection changed while reading.
                guard result.report.attemptID == attemptID else { throw AutomationContractError.conflictingOperation }
                entityQueryReport = result.report
                unresolvedEntityQueryAttemptID = nil
                if unresolvedEntityQuery { retainUnresolvedRequest(runID: approval.runID, target: queryPlan.target) }
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
                if entityQueryReport?.attemptID != attemptID {
                    unresolvedEntityQueryAttemptID = attemptID
                    retainUnresolvedRequest(runID: approval.runID, target: queryPlan.target)
                }
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
    var canSelectFix: Bool { isInstalledUI && canReproduceSavedFailure && pendingCommand == nil }
    var canPrepareSourceFix: Bool { !isInstalledUI && !isInstalledMacUI && canPrepare && canReproduceSavedFailure && pendingCommand == nil }
    var canCheckFix: Bool {
        guard canUseSavedFailure(commandKind: .fixComparison) else { return false }
        guard installApproved else { return false }
        if isInstalledUI { return fixedProduct != nil }
        guard let before = sourceSavedBaseline, let after = prepared else { return false }
        return (try? AutomationNativeUIFixComparisonProposal.validatePreparedCandidate(before: before, after: after)) != nil
    }
    var fixedAppName: String? {
        if isInstalledUI { return fixedBundleURL?.lastPathComponent }
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
            let product = try AutomationInstalledUIApplication.comparisonCandidate(bundleURL: url,
                target: .init(id: simulatorID, kind: .simulator), baseline: frozen.plan.app)
            _ = try AutomationFixContract.candidate(from: frozen, app: product.app)
            fixedBundleURL = url; fixedProduct = product; hasFixedSecurityScope = scope; message = nil
        } catch { if scope { url.stopAccessingSecurityScopedResource() }; message = errorText(error) }
    }
    private func makeComparisonRequest(runID: String) async throws -> AutomationNativeFixComparisonRequest {
        guard let original = savedViewedReport else { throw AutomationContractError.conflictingOperation }
        let request = try await makeReproductionRequest(runID: runID)
        guard installApproved else { throw AutomationContractError.conflictingOperation }
        let before = request.subject, after: AutomationApplicationSubject
        switch before {
        case .installedMacUI: throw AutomationContractError.missingEvidence("Mac installed-app execution is unavailable")
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
        let proposal = try AutomationNativeUIFixComparisonProposal.compile(frozen: request.proposal.frozen, original: original,
            before: before, after: after, runID: runID, disposable: disposable)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fields = ["original": AutomationArtifactRegistry.digest(try encoder.encode(original)), "baseline": proposal.baseline.digest,
            "candidate": proposal.candidate.digest,
            "beforeBuild": try comparisonBuildDigest(before), "afterBuild": try comparisonBuildDigest(after), "install": "true", "disposable": String(disposable),
            "attemptsPerBuild": String(proposal.attemptsPerBuild), "uiActions": String(proposal.limits.uiActions),
            "controllerCalls": String(proposal.limits.controllerCalls), "wallClockSeconds": String(proposal.limits.wallClockSeconds)]
        return .init(proposal: proposal, before: before, after: after,
            digest: AutomationArtifactRegistry.digest(try encoder.encode(fields)), originalAttemptID: original.attemptID)
    }
    private func comparisonBuildDigest(_ subject: AutomationApplicationSubject) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch subject {
        case .installedMacUI: throw AutomationContractError.missingEvidence("Mac installed-app execution is unavailable")
        case .installedPhysicalUI: throw AutomationContractError.missingEvidence("Unreadable installed apps cannot establish an exact-build comparison")
        case .installedUI(let app): return AutomationArtifactRegistry.digest(try encoder.encode(app.app))
        case .prepared(let app): return AutomationArtifactRegistry.digest(try encoder.encode(app))
        }
    }
    func checkFix() async {
        guard canCheckFix else { return }
        let commandID = pendingCommand
        guard commandID == nil || commandRequests[commandID!]?.kind == .fixComparison else { return }
        do { try beginExecutionAdmission() } catch { message = errorText(error); return }
        let runID = commandID?.uuidString ?? UUID().uuidString
        pendingCommand = nil; activeCommand = commandID
        if let commandID { commandRequests[commandID]?.state = "running" }
        progress = "Verifying both retained builds…"; message = nil
        task = Task {
            defer { progress = nil; task = nil; activeCommand = nil; clearFixedSelection(); releaseScopeIfClosing(); finishExecutionAdmission() }
            var executedRequests: [(String, TargetIdentity)] = []
            do {
                let request = try await makeComparisonRequest(runID: runID)
                if let commandID {
                    guard activeCommand == commandID, commandRequests[commandID]?.state == "running",
                          commandRequests[commandID]?.kind == .fixComparison, commandRequests[commandID]?.digest == request.digest else {
                        commandRequests[commandID]?.state = "invalidated"; throw AutomationContractError.conflictingOperation
                    }
                }
                try Task.checkCancellation()
                advanceSelection(); progress = "Checking the unchanged case three times on each build…"
                executedRequests = [(request.proposal.beforeApproval.runID, request.proposal.baseline.plan.target),
                    (request.proposal.afterApproval.runID, request.proposal.candidate.plan.target)]
                let result: AutomationFixComparisonReport
                if let comparisonExecutor { result = try await comparisonExecutor(request.proposal, request.before, request.after, support) }
                else { result = try await request.proposal.execute(before: request.before, after: request.after, support: support, developerDirectory: developerDirectory(for: request.before.target)) }
                comparisonReport = result
                if unresolvedComparison {
                    retainUnresolvedRequest(runID: request.proposal.beforeApproval.runID, target: request.proposal.baseline.plan.target)
                    retainUnresolvedRequest(runID: request.proposal.afterApproval.runID, target: request.proposal.candidate.plan.target)
                }
                guard result.baseline == request.proposal.baseline, result.candidate == request.proposal.candidate,
                      result.beforeRunID == request.proposal.beforeApproval.runID, result.afterRunID == request.proposal.afterApproval.runID else { throw AutomationContractError.conflictingOperation }
                let outcome = try AutomationNativeFixComparisonOutcome(result, originalAttemptID: request.originalAttemptID)
                if let commandID {
                    commandRequests[commandID]?.comparison = outcome; commandRequests[commandID]?.resourcesReleased = outcome.resourcesReleased
                    commandRequests[commandID]?.state = result.stopReason == "Cancelled" || (result.before + result.after).contains { $0.result.summary == .cancelled } ? "cancelled" : "completed"
                }
                for attempt in result.before { await importEvidence(plan: result.baseline.plan, report: attempt, announce: false) }
                for attempt in result.after { await importEvidence(plan: result.candidate.plan, report: attempt, announce: false) }
                if evidenceImporter != nil { evidenceImportRevision += 1 }
                try await AutomationFixComparisonArchive(caseStoreRoot: support.appendingPathComponent("Cases")).save(result)
                await refreshSavedCases()
            } catch {
                for (runID, target) in executedRequests { await retainUnresolvedReservation(runID: runID, target: target) }
                message = errorText(error)
                if let commandID, !["completed", "cancelled", "invalidated"].contains(commandRequests[commandID]?.state ?? "") {
                    commandRequests[commandID]?.state = error is CancellationError ? "cancelled" : "failed"
                }
                await refreshSavedCases()
            }
        }
        await task?.value
    }
    func clearFixedSelection() {
        if hasFixedSecurityScope { fixedBundleURL?.stopAccessingSecurityScopedResource() }
        hasFixedSecurityScope = false; fixedBundleURL = nil; fixedProduct = nil
    }
    func select(_ url: URL, rememberHistory: Bool = true) {
        guard canSelectApplicationFromCommand else { return }
        if url.pathExtension.lowercased() == "ipa" { importIPA(url); return }
        sourceGrants.clear()
        includesSourceDependencies = false; servedJavaScriptProfile = nil; automaticMetroRecipe = nil
        if hasSecurityScope { securityScopedURL?.stopAccessingSecurityScopedResource() }
        hasSecurityScope = url.startAccessingSecurityScopedResource()
        securityScopedURL = hasSecurityScope ? url : nil
        selectedURL = url; closing = false; intake = nil; candidateID = ""
        clearPrepared(); message = nil
        let epoch = selectionEpoch, assess = intakeAssessor
        progress = "Reading selected app…"
        task = Task {
            defer { progress = nil; task = nil; releaseScopeIfClosing() }
            do {
                let (canonical, assessment) = try await AutomationNativeOffMainVerification.run {
                    let canonical = try AutomationPath.canonical(url)
                    return (canonical, try assess(canonical))
                }
                guard !closing, selectionEpoch == epoch else { return }
                selectedURL = canonical; intake = assessment
                candidateID = assessment.candidates.first?.id ?? ""
                try await loadSelectedCandidate(epoch: epoch)
                guard !closing, selectionEpoch == epoch else { return }
                if rememberHistory, !assessment.candidates.isEmpty { rememberApplication(canonical) }
            } catch {
                guard !closing, selectionEpoch == epoch else { return }
                message = errorText(error)
            }
        }
    }
    func candidateSelectionChanged() {
        let restored = restoredCandidateID
        restoredCandidateID = nil
        guard restored != candidateID else { return }
        selectCandidate()
    }
    func selectCandidate() {
        guard !busy, !closing else { return }
        restoredCandidateID = nil
        clearPrepared(); message = nil
        let epoch = selectionEpoch
        progress = "Reading selected app…"
        task = Task {
            defer { progress = nil; task = nil; releaseScopeIfClosing() }
            do { try await loadSelectedCandidate(epoch: epoch) }
            catch {
                guard !closing, selectionEpoch == epoch else { return }
                message = errorText(error)
            }
        }
    }
    private func loadSelectedCandidate(epoch: Int) async throws {
        try Task.checkCancellation()
        guard !closing, selectionEpoch == epoch else { return }
        guard let selected = candidate else { configuration = ""; return }
        configuration = selected.configurations.first(where: { $0.caseInsensitiveCompare("Debug") == .orderedSame }) ?? selected.configurations.first ?? ""
        if isInstalledMacUI {
            do { selectedMacTarget = try nativeMacTargetReader() }
            catch { message = errorText(error) }
        }
        if let app = selected.app {
            let read = selectionCatalogReader, product = URL(fileURLWithPath: selected.containerPath)
            let value = try await AutomationNativeOffMainVerification.run { try read(app, product) }
            guard !closing, selectionEpoch == epoch, candidate == selected else { return }
            catalog = value
        }
    }
    func refreshTargets() async {
        guard !busy, !closing else { return }
        guard needsSimulatorInventory || needsPhysicalInventory else { return }
        simulatorInventoryRevision += 1
        let revision = simulatorInventoryRevision, selection = simulatorInventorySelection
        let inventoryTarget = TargetIdentity(id: needsPhysicalInventory ? physicalDeviceID : simulatorID, kind: needsPhysicalInventory ? .physical : .simulator)
        let selectedDeveloper = developerDirectory(for: inventoryTarget)
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if needsPhysicalInventory {
                let targets = try await physicalInventoryReader(selectedDeveloper, support)
                guard !busy, !closing, !Task.isCancelled, simulatorInventoryRevision == revision,
                      simulatorInventorySelection == selection, needsPhysicalInventory,
                      developerDirectory(for: inventoryTarget) == selectedDeveloper else { return }
                physicalDevices = targets
                let available = targets.filter(\.available)
                if physicalDeviceID.isEmpty {
                    if available.count == 1 { physicalDeviceID = available[0].id }
                } else if !available.contains(where: { $0.id == physicalDeviceID }) { physicalDeviceID = "" }
                return
            }
            let targets = try await simulatorInventoryReader(selectedDeveloper, support)
            guard !busy, !closing, !Task.isCancelled, simulatorInventoryRevision == revision,
                  simulatorInventorySelection == selection, needsSimulatorInventory,
                  developerDirectory(for: inventoryTarget) == selectedDeveloper else { return }
            simulators = targets
            if !simulators.contains(where: { $0.id == simulatorID }) { simulatorID = simulators.first?.id ?? "" }
        } catch {
            guard !busy, !closing, !Task.isCancelled, simulatorInventoryRevision == revision,
                  simulatorInventorySelection == selection, needsSimulatorInventory || needsPhysicalInventory,
                  developerDirectory(for: inventoryTarget) == selectedDeveloper else { return }
            if needsPhysicalInventory { physicalDevices = []; physicalDeviceID = "" }
            message = errorText(error)
        }
    }
    func prepare(expectedTarget: TargetIdentity? = nil) {
        guard canPrepare, let candidate, let selectedURL, let target = sourcePreparationTarget else { return }
        guard expectedTarget == nil || target == expectedTarget else { message = "The build destination changed. Review it again."; return }
        message = nil; progress = "Freezing source and building an associated host…"
        let root = ["xcodeproj", "xcworkspace"].contains(selectedURL.pathExtension.lowercased()) ? selectedURL.deletingLastPathComponent() : selectedURL
        let destination = preparationDestination, epoch = selectionEpoch
        let reviewedDeveloper = developerDirectory(for: target)
        let exactToolchain = hasExplicitToolchainSelection
        let reviewedToolchainMetadata = exactToolchain ? selectedToolchainMetadataDigest : nil
        let reviewedApproval = AutomationBuildApproval(sourceRoot: root.path, candidateID: candidate.id, configuration: configuration, target: target,
            additionalSourceRoots: sourceGrants.urls.map(\.path), includesDependencies: includesSourceDependencies,
            servedJavaScriptProfile: servedJavaScriptProfile, automaticMetroRecipe: automaticMetroRecipe)
        task = Task {
            defer { progress = nil; task = nil; releaseScopeIfClosing() }
            do {
                var approval = reviewedApproval
                if let digest = reviewedToolchainMetadata {
                    guard currentInstalledToolchainChoices().contains(where: { $0.directory == reviewedDeveloper && $0.metadataDigest == digest }) else {
                        throw AutomationContractError.missingEvidence("The reviewed Xcode installation changed. Refresh Xcodes and review the build again.")
                    }
                }
                let session = support.appendingPathComponent("prepare-" + UUID().uuidString)
                if target.kind == .physical {
                    let workspace = support
                    try await AutomationNativeOffMainVerification.run {
                        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700])
                    }
                    let resolved = try await physicalTargetResolver(target, reviewedDeveloper, support)
                    try Task.checkCancellation()
                    guard !closing, selectionEpoch == epoch, self.selectedURL == selectedURL, candidateID == candidate.id,
                          sourcePreparationTarget == target, preparationDestination == destination,
                          configuration == approval.configuration,
                          includesSourceDependencies == (approval.includesDependencies == true),
                          servedJavaScriptProfile == approval.servedJavaScriptProfile,
                          automaticMetroRecipe == approval.automaticMetroRecipe,
                          sourceGrants.urls.map(\.path) == (approval.additionalSourceRoots ?? []),
                          resolved.id == target.id, resolved.kind == .physical,
                          let identifier = resolved.physicalDeviceIdentifier, UUID(uuidString: identifier) != nil else {
                        throw AutomationContractError.conflictingOperation
                    }
                    resolvedPhysicalDeviceIdentifiers[target.id.lowercased()] = identifier
                    approval.target = resolved
                }
                let value: AutomationPreparedApplication
                if let preparationExecutor { value = try await preparationExecutor(candidate, approval, session) }
                else {
                    guard let templates = Bundle.main.url(forResource: "AutomationHost", withExtension: nil) else {
                        throw AutomationContractError.missingEvidence("Associated host templates are missing from this app build")
                    }
                    value = try await preparation.prepare(candidate: candidate, approval: approval, sessionRoot: session,
                        templates: templates, developerDirectory: reviewedDeveloper, requireConfiguredDeveloperDirectory: exactToolchain, reviewedToolchainMetadataDigest: reviewedToolchainMetadata)
                }
                try Task.checkCancellation()
                guard !closing, self.selectedURL == selectedURL, candidateID == candidate.id,
                      configuration == approval.configuration, preparationDestination == destination,
                      selectionEpoch == epoch, sourcePreparationTarget == approval.target,
                      developerDirectory(for: approval.target) == reviewedDeveloper,
                      includesSourceDependencies == (approval.includesDependencies == true),
                      servedJavaScriptProfile == approval.servedJavaScriptProfile,
                      automaticMetroRecipe == approval.automaticMetroRecipe,
                      sourceGrants.urls.map(\.path) == (approval.additionalSourceRoots ?? []) else {
                    throw AutomationContractError.conflictingOperation
                }
                if let digest = reviewedToolchainMetadata {
                    guard currentInstalledToolchainChoices().contains(where: { $0.directory == reviewedDeveloper && $0.metadataDigest == digest }) else {
                        throw AutomationContractError.missingEvidence("The reviewed Xcode installation changed. Refresh Xcodes and review the build again.")
                    }
                }
                try validatePreparedSelection(value, candidate: candidate, approval: approval)
                if exactToolchain, value.selectedDeveloperDirectoryPath != reviewedDeveloper.path {
                    throw AutomationContractError.missingEvidence("The selected Xcode could not prepare this app. Refresh or choose another installed Xcode, then review the build again.")
                }
                if let path = value.selectedDeveloperDirectoryPath {
                    let selectedDeveloper = try AutomationPath.canonical(URL(fileURLWithPath: path))
                    guard selectedDeveloper.path == path else { throw AutomationContractError.conflictingOperation }
                }
                let siriProfile = AutomationPreparedCapabilities.base(value)
                guard selectionEpoch == epoch, sourcePreparationTarget == approval.target,
                      developerDirectory(for: approval.target) == reviewedDeveloper, !closing else { throw AutomationContractError.conflictingOperation }
                if let digest = reviewedToolchainMetadata {
                    guard currentInstalledToolchainChoices().contains(where: { $0.directory == reviewedDeveloper && $0.metadataDigest == digest }) else {
                        throw AutomationContractError.missingEvidence("The reviewed Xcode installation changed. Refresh Xcodes and review the build again.")
                    }
                }
                prepared = value; siriCapabilities = siriProfile; catalog = value.catalog; actionID = ""; report = nil
                message = target.kind == .nativeMac
                    ? "Prepared a private Mac copy for inspection. Mac workflow execution is not available yet."
                    : fixedAppName == nil ? "Prepared a private copy. Choose a workflow and its permitted effects." : "Prepared the changed source. The original build and saved checks are retained for Check fix."
            } catch { message = errorText(error) }
        }
    }
    func prepareAndWait() async { prepare(); await task?.value }
    func waitForPreparation() async { let active = task; await active?.value }
    func currentInstalledToolchainChoices() -> [AutomationNativeToolchainChoice] { installedToolchainReader(developerDirectory) }
    private func retainEffectiveToolchainSelection() {
        guard hasExplicitToolchainSelection, reviewedToolchainMetadata[developerDirectory.path] == nil,
              let choice = currentInstalledToolchainChoices().first(where: { $0.directory == developerDirectory }) else { return }
        // Each path keeps its reviewed identity when moving between destinations.
        // Returning to an installation that changed still requires explicit reselection.
        reviewedToolchainMetadata[choice.directory.path] = choice.metadataDigest
    }
    func refreshInstalledToolchains() {
        guard !busy, !closing else { return }
        installedToolchains = installedToolchainReader(developerDirectory)
    }
    func selectInstalledToolchain(_ id: String) throws {
        guard !busy, !closing else { throw AutomationContractError.targetBusy }
        guard let reviewed = installedToolchains.first(where: { $0.id == id }),
              installedToolchainReader(developerDirectory).contains(reviewed),
              try AutomationPath.canonical(reviewed.directory) == reviewed.directory else {
            throw AutomationContractError.missingEvidence("This Xcode installation changed or is unavailable. Refresh the installed Xcodes and choose again.")
        }
        guard reviewed.directory != developerDirectory || reviewed.metadataDigest != selectedToolchainMetadataDigest || !hasExplicitToolchainSelection else {
            return
        }
        advanceSelection(); clearEntitySelections()
        if xcodeSettings.runOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            xcodeSettings.setPath(reviewed.directory.path, for: preparationDestination)
        } else {
            xcodeSettings.runOverride = reviewed.directory.path
        }
        reviewedToolchainMetadata[reviewed.directory.path] = reviewed.metadataDigest
        prepared = nil; catalog = nil; siriCapabilities = .init(); report = nil; reportDirectory = nil; searchReport = nil
        actionID = ""; inputs = [:]; effectsConfirmed = false
        message = "Using " + reviewed.label + ". Prepare a fresh private copy with this Xcode."
    }

    func selectAction() { guard !busy else { return }; advanceSelection(); clearEntitySelections(); inputs = [:]; freshNameProperty = ""; freshStateProperty = ""; freshInitialState = ""; freshExpectedState = ""; freshProtectOtherRecord = false; freshContextProperty = ""; freshSelectedContext = ""; freshProtectedContext = ""; effectChoice = ""; effectsConfirmed = false; report = nil; message = nil; applyFreshRecordSetupProposal() }
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
            try beginExecutionAdmission()
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
            defer { progress = nil; task = nil; activeCommand = nil; releaseScopeIfClosing(); finishExecutionAdmission() }
            do {
                reportDirectory = support.appendingPathComponent(attemptID)
                let result: AutomationAttemptReport
                if let runExecutor {
                    result = try await runExecutor(request.subject, request.plan, request.approval, request.capabilities, attemptID, request.installApproved)
                } else {
                    let runner = try AutomationApplicationRunner(supportRoot: support, developerDirectory: developerDirectory(for: request.subject.target))
                    result = try await runNativePreparedRequest(request, runner: runner, attemptID: attemptID)
                }
                finishTelemetry?(.success(result))
                report = result
                if !result.resourcesReleased || result.result.subjectDispatchUncertain {
                    retainedUnresolvedNormalTarget = request.plan.target
                    retainUnresolvedRequest(runID: request.approval.runID, target: request.plan.target)
                }
                if let commandID {
                    commandRequests[commandID]?.state = result.result.summary == .cancelled ? "cancelled" : "completed"
                    commandRequests[commandID]?.result = result.result
                    commandRequests[commandID]?.resourcesReleased = result.resourcesReleased
                }
                await importEvidence(plan: request.plan, report: result)
                await refreshSavedCases()
            } catch {
                finishTelemetry?(.failure(error))
                await retainUnresolvedReservation(runID: request.approval.runID, target: request.plan.target)
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
            guard FileManager.default.fileExists(atPath: caseRoot.path) else {
                hasMigratedEvidenceHistory = true; evidenceImportMessage = nil; return
            }
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
            hasMigratedEvidenceHistory = true; evidenceImportMessage = nil; evidenceImportRevision += 1
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
        var notices: [String] = [], skipped = 0
        do {
            if let savedCasesReader { savedCases = try await savedCasesReader() }
            else {
                let listing = try await AutomationCaseStore(root: support.appendingPathComponent("Cases")).definitionListing()
                savedCases = listing.items; skipped += listing.skippedRetiredRecords
            }
        } catch { notices.append("Saved cases could not be verified.") }
        if FileManager.default.fileExists(atPath: support.appendingPathComponent("Cases/Searches").path) {
            do {
                let listing = try await AutomationUIFailureSearchArchive(caseStoreRoot: support.appendingPathComponent("Cases")).recordListing()
                savedSearches = listing.items; skipped += listing.skippedRetiredRecords
            } catch { notices.append("Saved searches could not be verified.") }
        }
        if FileManager.default.fileExists(atPath: support.appendingPathComponent("Cases/FixComparisons").path) {
            do { savedComparisons = try await AutomationFixComparisonArchive(caseStoreRoot: support.appendingPathComponent("Cases")).records() }
            catch { notices.append("Saved comparisons could not be verified.") }
        }
        if FileManager.default.fileExists(atPath: support.appendingPathComponent("Cases/Reproductions").path) {
            do { savedReproductions = try await AutomationReproductionArchive(caseStoreRoot: support.appendingPathComponent("Cases")).records() }
            catch { notices.append("Saved reproductions could not be verified.") }
        }
        if skipped > 0 {
            notices.append("\(skipped) saved records use the retired controller and are unavailable. Their files have been kept.")
        }
        savedHistoryNotice = notices.isEmpty ? nil : notices.joined(separator: " ")
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
    func cancel() {
        cancelRequestVerification()
        task?.cancel()
        if let pendingCommand { _ = try? cancelCommand(id: pendingCommand) }
    }
    func retainUnresolvedRequest(runID: String, target: TargetIdentity) {
        retainedUnresolvedRequestTargets[runID] = target
    }
    func finishOwnershipReset() {
        retainedUnresolvedNormalReport = nil; retainedUnresolvedNormalTarget = nil
        retainedUnresolvedRequestTargets = [:]
        if report?.resourcesReleased == false || report?.result.subjectDispatchUncertain == true { report = nil }
        unresolvedEntityQueryAttemptID = nil
        if entityQueryReport?.resourcesReleased == false || entityQueryReport?.result.subjectDispatchUncertain == true { entityQueryReport = nil }
        if unresolvedSearch { searchReport = nil }
        if unresolvedReproduction { reproductionReport = nil }
        if unresolvedComparison { comparisonReport = nil }
        publishExecutionOwnership()
    }
    /// Cancels a view-owned preview only; another pending or running operation keeps its ownership.
    func cancelRequestVerification() { requestVerificationCancellationID = UUID() }
    func validateRequestVerificationCancellation(_ id: UUID) throws {
        try Task.checkCancellation()
        guard requestVerificationCancellationID == id else { throw CancellationError() }
    }
    /// Installs one just-verified immutable preview; does not grant execution approval.
    func installVerifiedConfirmation(id: UUID, digest: String, kind: AutomationNativeCommandKind?,
                                     originalAttemptID: String? = nil, caseID: String? = nil,
                                     revision: Int? = nil, caseDigest: String? = nil) throws -> AutomationNativeCommandStatus {
        if kind == nil { return try requestCommand(id: id, digest: digest, nativeConfirmation: true) }
        if let prior = commandRequests[id] {
            guard prior.digest == digest, prior.kind == kind else { throw AutomationContractError.conflictingOperation }
            return prior
        }
        guard !closing, pendingCommand == nil, commandHistory.canAdmit(id, nativeConfirmation: true, requests: commandRequests) else { throw AutomationContractError.targetBusy }
        let status = AutomationNativeCommandStatus(requestID: id, digest: digest, state: "awaitingApproval", kind: kind,
            originalAttemptID: originalAttemptID, caseID: caseID, revision: revision, caseDigest: caseDigest)
        commandRequests[id] = status; pendingCommand = id; commandHistory.admitted(id)
        return status
    }
    func verifiedPreviewCommand() async throws -> AutomationNativeCommandPreview {
        let request = try await verifiedNativeRunRequest(runID: "preview")
        return .init(digest: request.digest, bundleID: request.plan.app.bundleID, targetID: request.plan.target.id,
            environmentID: request.plan.environmentID, action: request.plan.execution.operation,
            effects: request.approval.effects.map(\.rawValue).sorted(), maximumActions: request.approval.maximumActions,
            installApproved: request.installApproved, disposable: request.approval.disposable)
    }

    func verifiedRequestCommand(id: UUID, digest: String) async throws -> AutomationNativeCommandStatus {
        try Task.checkCancellation()
        guard !closing else { throw AutomationContractError.targetBusy }
        guard !commandHistory.isNative(id) else { throw AutomationContractError.conflictingOperation }
        if let existing = commandRequests[id] {
            guard existing.digest == digest, existing.kind == nil else { throw AutomationContractError.conflictingOperation }
            return existing
        }
        guard pendingCommand == nil, !busy,
              commandHistory.canAdmit(id, nativeConfirmation: false, requests: commandRequests) else {
            throw AutomationContractError.targetBusy
        }
        let preview = try await verifiedPreviewCommand()
        try Task.checkCancellation()
        guard preview.digest == digest else { throw AutomationContractError.conflictingOperation }
        // Verification checks the frozen selection; the remote ID still uses
        // remote admission. Only the native dialog mints native request IDs.
        return try requestCommand(id: id, digest: digest)
    }

    func previewCommand() throws -> AutomationNativeCommandPreview {
        let request = try makeNativeRunRequest(runID: "preview")
        return .init(digest: request.digest, bundleID: request.plan.app.bundleID, targetID: request.plan.target.id,
            environmentID: request.plan.environmentID, action: request.plan.execution.operation,
            effects: request.approval.effects.map(\.rawValue).sorted(), maximumActions: request.approval.maximumActions,
            installApproved: request.installApproved, disposable: request.approval.disposable)
    }
    func previewReproductionCommand() async throws -> AutomationNativeReproductionPreview {
        guard canReproduceSavedFailure else { throw AutomationContractError.targetBusy }
        let cancellationID = requestVerificationCancellationID
        let request = try await makeReproductionRequest(runID: "preview")
        try validateRequestVerificationCancellation(cancellationID)
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
        let cancellationID = requestVerificationCancellationID
        let request = try await makeComparisonRequest(runID: "preview")
        try validateRequestVerificationCancellation(cancellationID)
        let proposal = request.proposal
        return .init(digest: request.digest, bundleID: request.before.app.bundleID, targetID: request.before.target.id,
            environmentID: proposal.baseline.plan.environmentID, caseID: proposal.baseline.plan.id, revision: proposal.baseline.plan.revision,
            caseDigest: proposal.baseline.digest, candidateCaseDigest: proposal.candidate.digest,
            beforeProductDigest: request.before.app.productDigest!, afterProductDigest: request.after.app.productDigest!,
            originalAttemptID: request.originalAttemptID, requestedAttemptsPerBuild: proposal.attemptsPerBuild, installApproved: request.before.target.kind == .simulator, disposable: proposal.beforeApproval.disposable)
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
        message = "Review both builds and confirm Check fix to compare the unchanged case three times per build."
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
        retainEffectiveToolchainSelection()
    }
    func selectJavaScriptRecipe(_ url: URL?) throws {
        guard !busy, !closing, candidate?.kind == .sourceTarget, let root = selectedSourceRoot else { throw AutomationContractError.targetBusy }
        let value = try url.map { try AutomationServedJavaScriptProfile.load(source: root, url: $0) }
        clearPrepared(); servedJavaScriptProfile = value; automaticMetroRecipe = nil; message = nil
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
    func releaseScopeIfClosing() {
        if closing { clearFixedSelection(); sourceGrants.clear() }
        if closing, hasSecurityScope { securityScopedURL?.stopAccessingSecurityScopedResource(); securityScopedURL = nil; hasSecurityScope = false }
    }
    func clearSavedView() { if !busy { clearFixedSelection() }; viewedComparison = nil; savedPreparedBaseline = nil; savedViewRequestID = nil; savedViewedReport = nil; savedViewedAttempts = []; savedAttemptLoading = false; canonicalSavedEvidence = nil; savedViewedCase = nil; savedViewedDirectory = nil; viewedSearch = nil; viewedReproduction = nil }
    func advanceSelection() { invalidatePendingCommand(); selectionEpoch += 1; clearSavedView() }
    private func clearPrepared() {
        firstRunInputReviewID = nil; firstRunInputs = [:]; firstRunEntityQueryTexts = [:]
        firstRunEntityChoices = [:]; firstRunSelectedEntityIDs = [:]
        pairedFeatureID = ""; pairedEffectsConfirmed = false; firstRunIncludesActions = false; firstRunEffectsConfirmed = false; firstRunReports = []; firstRunGaps = []; selectedMacTarget = nil; advanceSelection(); clearEntitySelections(); prepared = nil; siriCapabilities = .init(); siriRequest = ""; siriOracle = .init(); catalog = nil; report = nil; workflowRoute = "ui"; actionID = ""; inputs = [:]; effectChoice = ""; effectsConfirmed = false; uiInstruction = ""; uiEndpoint = ""; freshSaveControl = ""; freshCreateControl = ""; freshNameEntryControl = ""; freshContextEntryControl = ""; uiTapControls = ""; uiTextEntryControl = ""; uiSubmitControl = ""; uiApprovedText = ""; uiExpectedText = ""; uiObservationLabel = ""; uiObservationProperty = "text"; freshNamePrefix = ""; freshNameProperty = ""; freshStateProperty = ""; freshInitialState = ""; freshExpectedState = ""; freshProtectOtherRecord = false; freshContextProperty = ""; freshSelectedContext = ""; freshProtectedContext = ""; searchReport = nil }
    func errorText(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled. Any pending dispatch is retained for review." }
        if let contract = error as? AutomationContractError {
            switch contract {
            case .invalidPlan(let reason), .missingEvidence(let reason): return reason
            case .targetBusy: return "The selected target is owned by another or unresolved run. Review its retained evidence before continuing."
            case .conflictingOperation: return "The selected source or prepared product changed. Prepare a fresh copy."
            case .ambiguousDispatch, .terminationUnverified: return "An operation or test runner release is unresolved. Its journal is retained; it will not be retried automatically."
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
struct AutomationNativeRunRequest: Sendable {
    var subject: AutomationApplicationSubject
    var plan: AutomationCase
    var approval: RunApproval
    var capabilities: CapabilityProfile
    var installApproved: Bool
    var digest: String
    var caseDigest: String
}
typealias AutomationNativeRunExecutor = @Sendable (AutomationApplicationSubject, AutomationCase, RunApproval, CapabilityProfile, String, Bool) async throws -> AutomationAttemptReport

#endif
