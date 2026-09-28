import CryptoKit
import Foundation
import Observation

/// Admission shared by scenario orchestration and ordinary evaluation starts.
/// A child feature run carries its parent's owner ID, so it can use the same
/// destination without opening a competing top-level execution.
@MainActor
final class ScenarioExecutionAdmission {
    static let shared = ScenarioExecutionAdmission()
    private(set) var ownerID: UUID?

    func acquire(_ requestedID: UUID) throws {
        guard ownerID == nil else {
            throw EvaluationStoreError.resourceConflict("Another app or device run is already in progress.")
        }
        ownerID = requestedID
    }

    func allows(_ requestedID: UUID?) -> Bool {
        ownerID == nil || (requestedID != nil && ownerID == requestedID)
    }

    func release(_ requestedID: UUID) {
        if ownerID == requestedID { ownerID = nil }
    }
}

@MainActor
@Observable
final class ScenarioCoordinator {
    private(set) var definitions: [ScenarioDefinition] = []
    private(set) var runs: [ScenarioRun] = []
    private(set) var executionPlans: [ScenarioExecutionPlan] = []
    private(set) var executionRecords: [ScenarioExecutionRecord] = []
    var selectedExecutionID: UUID?
    private(set) var collections: [ScenarioCollection] = []
    private(set) var batchManifests: [ScenarioCollectionBatchManifest] = []
    private(set) var batchResults: [ScenarioCollectionBatchResult] = []
    var selectedCollectionID: UUID?
    var selectedBatchID: UUID?
    var assessmentJudgeConfiguration = EvaluationJudgeConfiguration()
    private(set) var selectedAssessmentOverlay: ScenarioAssessmentSelectionRecord?
    private(set) var assessmentSelectionHistory: [ScenarioAssessmentSelectionRecord] = []
    var draft: ScenarioDefinition
    var parameterArrayDraftTexts: [Int: String] = [:]
    var invalidParameterDraftIndices: Set<Int> = []
    var selectedRunID: UUID?
    var configuration: XcodeTestConfiguration
    var projectTrusted = false
    private(set) var selectedIntegration: ScenarioIntegrationIdentity?
    private(set) var declarationCatalog: ScenarioIntegrationCatalog?
    private(set) var connectionDiscovery: XcodeConnectionDiscovery?
    private(set) var discoveredDevices: [IntentLabDeviceDestination] = []
    private(set) var isDiscoveringConnection = false
    private(set) var isVerifyingIntegration = false
    private(set) var verifiedIntegrationSummary: String?
    var statedChangedDimensions: Set<String> = []
    private(set) var preflight: ScenarioPreflightReport?
    private(set) var isRunning = false
    private(set) var isGeneratingSuggestions = false
    private(set) var suggestions: [ScenarioRequestSuggestion] = []
    private(set) var recoveryJournals: [ScenarioExecutionJournal] = []
    private(set) var journals: [ScenarioExecutionJournal] = []
    private(set) var hasLoaded = false
    var notice: String?

    private let persistence: ScenarioPersistence
    private let collectionStore: ScenarioCollectionStore
    private let assessmentStore: ScenarioAssessmentStore
    private let executor: XcodeTestExecutor
    private let rootDirectory: URL
    private let evaluationStore: EvaluationStore
    @ObservationIgnored private weak var developerRunnerStore: DeveloperRunnerStore?
    private var ledger = ScenarioImportLedger()
    private var preflightRevision = 0
    private var cancellationRequested = false
    private var finalEvidenceCommitStarted = false
    private var executionTask: Task<ScenarioExecutorResult, Error>?
    private var activeFeatureRunID: UUID?
    @ObservationIgnored private var scopedProjectURL: URL?

    init(supportDirectory: URL, evaluationStore: EvaluationStore) {
        let root = supportDirectory.appending(path: "IntentLab", directoryHint: .isDirectory)
        rootDirectory = root
        let persistence = ScenarioPersistence(rootDirectory: root)
        self.persistence = persistence
        collectionStore = ScenarioCollectionStore(rootDirectory: root)
        assessmentStore = ScenarioAssessmentStore(directory: root.appending(path: "Assessments"))
        self.evaluationStore = evaluationStore
        executor = XcodeTestExecutor(
            workDirectory: root.appending(path: "Executor", directoryHint: .isDirectory),
            persistence: persistence
        )
        draft = (try? ScenarioDefinition.starter(projectID: evaluationStore.selectedProjectID).frozen())
            ?? ScenarioDefinition.starter(projectID: evaluationStore.selectedProjectID)
        configuration = .init(
            containerPath: "",
            isWorkspace: false,
            scheme: "IntentLabFixture",
            testTarget: "IntentLabFixtureUITests",
            testBundleIdentifier: "com.coryparry.IntentLabFixtureUITests",
            destinationIdentifier: "",
            generatedResourceDirectory: ""
        )
    }

    var selectedRun: ScenarioRun? {
        selectedRunID.flatMap { id in runs.first { $0.id == id } }
    }

    var selectedExecutionRecord: ScenarioExecutionRecord? {
        selectedExecutionID.flatMap { id in executionRecords.first { $0.id == id } }
    }

    var selectedExecutionPlan: ScenarioExecutionPlan? {
        selectedExecutionID.flatMap { id in executionPlans.first { $0.id == id } }
    }

    var selectedCollection: ScenarioCollection? {
        collections.filter { $0.id == selectedCollectionID }.max { $0.version < $1.version }
    }

    var selectedBatchManifest: ScenarioCollectionBatchManifest? {
        selectedBatchID.flatMap { id in batchManifests.first { $0.id == id } }
    }

    var selectedBatchAssessment: ScenarioCollectionBatchAssessment? {
        guard let manifest = selectedBatchManifest,
              let collection = collections.first(where: {
                  $0.id == manifest.collectionID && $0.version == manifest.collectionVersion
              }) else { return nil }
        return ScenarioCollectionService.assess(
            manifest: manifest, collection: collection,
            result: batchResults.first { $0.manifestID == manifest.id }, runs: runs
        )
    }

    func selectExecution(_ id: UUID) {
        guard executionPlans.contains(where: { $0.id == id }) else { return }
        selectedExecutionID = id
        Task { await reloadSelectedAssessmentOverlay(expectedExecutionID: id) }
    }

    func bindRunnerStore(_ store: DeveloperRunnerStore) {
        developerRunnerStore = store
    }

    /// All checks and the lease write are synchronous on the main actor. An
    /// ordinary run cannot start between them, and its own start checks this
    /// lease before dispatching an app action.
    private func acquireExecutionOwner(_ id: UUID) throws {
        guard !evaluationStore.hasActiveExecution,
              developerRunnerStore?.executingRunID == nil else {
            throw EvaluationStoreError.resourceConflict(
                "Finish the active evaluation or developer runner action before starting an Intent Lab execution."
            )
        }
        try ScenarioExecutionAdmission.shared.acquire(id)
    }

    var currentValidationIssues: [ScenarioValidationIssue] {
        ScenarioValidator.issues(in: draft, requireFrozenDigest: false) + parameterDraftIssues
    }

    private var parameterDraftIssues: [ScenarioValidationIssue] {
        invalidParameterDraftIndices.sorted().map {
            .init(severity: .error, path: "directControl.parameters[\($0)].presence",
                  message: "Finish the array value before saving or running this scenario.")
        }
    }

    func definition(for run: ScenarioRun) -> ScenarioDefinition? {
        definitions.first {
            $0.id == run.scenarioID &&
            $0.version == run.scenarioVersion &&
            $0.definitionDigest == run.scenarioDigest
        } ?? (draft.id == run.scenarioID && draft.version == run.scenarioVersion && draft.definitionDigest == run.scenarioDigest ? draft : nil)
    }

    func load() async {
        guard !hasLoaded else { return }
        do {
            try await persistence.prepare()
            definitions = try await persistence.loadDefinitions()
            runs = try await persistence.loadRuns()
            ledger = try await persistence.loadLedger()
            recoveryJournals = try await executor.reconcileInterruptedJournals()
            journals = try await persistence.loadJournals()
            _ = try await persistence.recoverIncompleteExecutionRecords()
            executionPlans = try await persistence.loadPlans()
            executionRecords = try await persistence.loadExecutionRecords()
            selectedExecutionID = executionPlans.first?.id
            if let selectedExecutionID {
                await reloadSelectedAssessmentOverlay(expectedExecutionID: selectedExecutionID)
            }
            collections = try await collectionStore.loadCollections()
            batchManifests = try await collectionStore.loadManifests()
            batchResults = try await collectionStore.loadResults()
            selectedCollectionID = collections.max(by: { $0.version < $1.version })?.id
            selectedBatchID = batchManifests.first?.id
            let selected = try await persistence.loadSelectedDefinition()
            let latestRunDefinition = runs.first.flatMap { latestRun in
                definitions
                    .filter { $0.id == latestRun.scenarioID }
                    .max { $0.version < $1.version }
            }
            let latestVersion = definitions.map(\.version).max()
            let latestVersionDefinition = latestVersion.flatMap { version in
                definitions.last { $0.version == version }
            }
            let restored = selected.flatMap { saved in
                definitions.first { $0.id == saved.id && $0.version == saved.version }
            } ?? latestRunDefinition ?? latestVersionDefinition
            if let definition = restored {
                draft = definition
                selectedIntegration = definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion
                    ? definition.integration : nil
                parameterArrayDraftTexts = [:]
                invalidParameterDraftIndices = []
                applyTargetToConfiguration(definition.target)
            }
            // The saved connection profile is the most recent operator choice. A frozen
            // scenario can carry older target metadata, so it must not overwrite that profile.
            if let savedConfiguration = try await persistence.loadExecutionConfiguration() {
                configuration = savedConfiguration
            }
            selectedRunID = runs.first?.id
            if !recoveryJournals.isEmpty {
                notice = "A previous device test ended without proven cleanup. Its destination is quarantined until termination and fixture readiness are confirmed."
            }
            hasLoaded = true
            await refreshDevices()
        } catch {
            notice = "Intent Lab storage could not be loaded: \(error.localizedDescription)"
        }
    }

    func selectContainer(_ url: URL) {
        guard ["xcodeproj", "xcworkspace"].contains(url.pathExtension.lowercased()) else {
            notice = XcodeConnectionDiscoveryError.invalidContainer.localizedDescription
            return
        }
        scopedProjectURL?.stopAccessingSecurityScopedResource()
        scopedProjectURL = url.startAccessingSecurityScopedResource() ? url : nil
        configuration.containerPath = url.standardizedFileURL.path
        configuration.isWorkspace = url.pathExtension == "xcworkspace"
        configuration.scheme = ""
        configuration.configuration = "Debug"
        configuration.configurationOverride = nil
        configuration.testTarget = ""
        configuration.selectedTestProductID = nil
        configuration.selectedApplicationProductID = nil
        configuration.testBundleIdentifier = ""
        configuration.harnessVersion = nil
        configuration.harnessCapabilities = nil
        configuration.applicationSigningConfigured = nil
        configuration.testSigningConfigured = nil
        selectedIntegration = nil
        declarationCatalog = nil
        projectTrusted = false
        connectionDiscovery = nil
        verifiedIntegrationSummary = nil
        invalidatePreflight()
    }

    func refreshDevices() async {
        do {
            let service = XcodeConnectionDiscoveryService(
                xcodebuildPath: configuration.xcodebuildPath,
                xcdevicePath: "/usr/bin/xcrun"
            )
            discoveredDevices = try await Task.detached {
                try service.discoverDevices()
            }.value
        } catch {
            discoveredDevices = []
            if recoveryJournals.isEmpty {
                notice = error.localizedDescription
            }
        }
    }

    func approveBuildAndDiscover() async {
        guard !isDiscoveringConnection else { return }
        guard !configuration.containerPath.isEmpty else {
            notice = XcodeConnectionDiscoveryError.invalidContainer.localizedDescription
            return
        }
        isDiscoveringConnection = true
        defer { isDiscoveringConnection = false }
        let approvedContainerPath = configuration.containerPath
        do {
            let container = URL(filePath: approvedContainerPath)
            let service = XcodeConnectionDiscoveryService(
                xcodebuildPath: configuration.xcodebuildPath,
                xcdevicePath: "/usr/bin/xcrun"
            )
            let buildConfiguration = configuration.configuration
            let selectedScheme = configuration.scheme
            let signingArguments = configuration.signingArguments
            let discovery = try await Task.detached {
                try service.discoverProject(
                    container: container, configuration: buildConfiguration,
                    signingArguments: signingArguments
                )
            }.value
            guard configuration.containerPath == approvedContainerPath,
                  configuration.configuration == buildConfiguration,
                  configuration.scheme == selectedScheme,
                  configuration.signingArguments == signingArguments else { return }
            connectionDiscovery = discovery
            apply(discovery: discovery)
            if configuration.configurationOverride == nil {
                let schemeConfiguration = try testActionConfiguration(for: discovery)
                if schemeConfiguration != configuration.configuration {
                    configuration.configuration = schemeConfiguration
                    let refreshed = try await Task.detached {
                        try service.discoverProject(
                            container: container, configuration: schemeConfiguration,
                            signingArguments: signingArguments
                        )
                    }.value
                    guard configuration.containerPath == approvedContainerPath,
                          configuration.configuration == schemeConfiguration,
                          configuration.configurationOverride == nil,
                          configuration.signingArguments == signingArguments else { return }
                    connectionDiscovery = refreshed
                    apply(discovery: refreshed)
                }
            }
            projectTrusted = true
            try await persistence.saveExecutionConfiguration(configuration)
            await refreshPreflight()
        } catch {
            guard configuration.containerPath == approvedContainerPath else { return }
            projectTrusted = false
            connectionDiscovery = nil
            notice = error.localizedDescription
        }
    }

    func selectScheme(_ scheme: String) {
        guard configuration.scheme != scheme else { return }
        configuration.scheme = scheme
        if configuration.configurationOverride == nil {
            do {
                configuration.configuration = try testActionConfiguration(for: connectionDiscovery)
            } catch {
                projectTrusted = false
                notice = error.localizedDescription
                invalidatePreflight()
                return
            }
        }
        projectTrusted = false
        invalidatePreflight()
    }

    func selectBuildConfiguration(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.configurationOverride = trimmed.isEmpty ? nil : trimmed
        configuration.configuration = trimmed.isEmpty
            ? ((try? testActionConfiguration(for: connectionDiscovery)) ?? "Debug") : trimmed
        projectTrusted = false
        invalidatePreflight()
    }

    func selectDevelopmentTeam(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = trimmed.isEmpty ? nil : trimmed
        guard configuration.developmentTeam != selected else { return }
        configuration.developmentTeam = selected
        configuration.applicationSigningConfigured = nil
        configuration.testSigningConfigured = nil
        projectTrusted = false
        connectionDiscovery = nil
        invalidatePreflight()
    }

    func setAllowsProvisioningUpdates(_ allowed: Bool) {
        guard configuration.allowProvisioningUpdates != allowed else { return }
        configuration.allowProvisioningUpdates = allowed
        projectTrusted = false
        connectionDiscovery = nil
        invalidatePreflight()
    }

    func selectApplication(_ product: XcodeDiscoveredProduct) {
        if draft.target.bundleIdentifier != product.bundleIdentifier {
            selectedIntegration = nil
            if draft.schemaVersion == ScenarioDefinition.reusableSchemaVersion {
                draft.integration = nil
            }
        }
        draft.target.bundleIdentifier = product.bundleIdentifier
        configuration.selectedApplicationProductID = product.id
        configuration.applicationSigningConfigured = product.signingConfigured
        draft.definitionDigest = ""
        if !isDiscoveringConnection, configuration.configurationOverride == nil,
           let discovery = connectionDiscovery {
            do {
                let selectedConfiguration = try testActionConfiguration(for: discovery)
                if selectedConfiguration != configuration.configuration {
                    configuration.configuration = selectedConfiguration
                    let wasTrusted = projectTrusted
                    projectTrusted = false
                    invalidatePreflight()
                    if wasTrusted { Task { await approveBuildAndDiscover() } }
                    return
                }
            } catch {
                projectTrusted = false
                notice = error.localizedDescription
            }
        }
        invalidatePreflight()
    }

    func selectUITestBundle(_ product: XcodeDiscoveredProduct) {
        configuration.testTarget = product.targetName
        configuration.selectedTestProductID = product.id
        configuration.testBundleIdentifier = product.bundleIdentifier
        configuration.harnessVersion = product.harnessVersion
        configuration.harnessCapabilities = product.harnessCapabilities
        configuration.testSigningConfigured = product.signingConfigured
        declarationCatalog = nil
        invalidatePreflight()
    }

    func verifyInstalledIntegration() async {
        guard !isVerifyingIntegration else { return }
        isVerifyingIntegration = true
        defer { isVerifyingIntegration = false }
        applyConfigurationToDraft()
        do {
            let definition = try draft.frozen()
            let verified = try await executor.verifyConnection(
                definition: definition,
                configuration: configuration,
                projectTrusted: projectTrusted
            )
            let data = try Data(contentsOf: verified.testBundleURL.appending(path: "IntentLabIntegration.json"))
            let catalog = try ScenarioIntegrationCatalog.decodeVerified(data, identity: verified.receipt.integration)
            guard catalog.targetBundleIdentifier == verified.receipt.targetBundleIdentifier else {
                throw ScenarioAuthoringError.staleDeclaration
            }
            declarationCatalog = catalog
            verifiedIntegrationSummary = "Compiled \(verified.receipt.integration.id) v\(verified.receipt.integration.version) with \(verified.receipt.capabilities.count) declared capabilities."
            draft = definition
            await refreshPreflight()
        } catch {
            declarationCatalog = nil
            verifiedIntegrationSummary = nil
            notice = "Integration check failed: \(error.localizedDescription)"
            invalidatePreflight()
        }
    }

    func selectDevice(_ identifier: String) async {
        configuration.destinationIdentifier = identifier
        invalidatePreflight()
        try? await persistence.saveExecutionConfiguration(configuration)
        if projectTrusted { await refreshPreflight() }
    }

    func artifactURL(run: ScenarioRun, artifact: ScenarioArtifactReference) -> URL {
        rootDirectory
            .appending(path: "Runs/\(run.scenarioID.uuidString)/\(run.id.uuidString)", directoryHint: .isDirectory)
            .appending(path: artifact.relativePath)
    }

    func comparison(for run: ScenarioRun) -> ScenarioComparisonReport? {
        if run.scenarioSchemaVersion == ScenarioDefinition.stableSchemaVersion {
            let previous = runs.filter {
                $0.id != run.id && $0.scenarioID == run.scenarioID
                    && $0.startedAt < run.startedAt && $0.executionStatus == .completed
                    && $0.scenarioSchemaVersion == ScenarioDefinition.stableSchemaVersion
            }.sorted { $0.startedAt > $1.startedAt }
            let baseline = previous.first { $0.testContractDigest == run.testContractDigest }
                ?? previous.first
            guard let baseline else { return nil }
            return ScenarioComparison.compare(
                baseline: baseline, candidate: run,
                policy: .init(mode: .compareAppChanges, baselineRunID: baseline.id)
            )
        }
        guard let baseline = runs.first(where: {
            $0.id != run.id && $0.scenarioID == run.scenarioID
                && $0.scenarioVersion == run.scenarioVersion
                && $0.scenarioDigest == run.scenarioDigest
                && $0.startedAt < run.startedAt
        }) else { return nil }
        return ScenarioComparison.compare(baseline: baseline, candidate: run)
    }

    @discardableResult
    func freezeAndSave() async throws -> ScenarioDefinition {
        if !invalidParameterDraftIndices.isEmpty {
            throw ScenarioValidationError.invalid(parameterDraftIssues)
        }
        applyConfigurationToDraft()
        draft.version = max(1, draft.version)
        draft = try draft.frozen()
        if definitions.contains(where: {
            $0.id == draft.id && $0.version == draft.version && $0.definitionDigest != draft.definitionDigest
        }) {
            draft.version = max(draft.version, definitions.filter { $0.id == draft.id }.map(\.version).max() ?? 0) + 1
            draft = try draft.frozen()
        }
        try ScenarioValidator.validate(draft)
        let frozen = draft
        let savedConfiguration = configuration
        try await persistence.saveDefinition(frozen)
        try await persistence.saveSelectedDefinition(id: frozen.id, version: frozen.version)
        try await persistence.saveExecutionConfiguration(savedConfiguration)
        if let index = definitions.firstIndex(where: { $0.id == frozen.id && $0.version == frozen.version }) {
            definitions[index] = frozen
        } else {
            definitions.append(frozen)
        }
        return frozen
    }

    func duplicateAsNewVersion() {
        draft.version = max(draft.version, definitions.filter { $0.id == draft.id }.map(\.version).max() ?? 0) + 1
        draft.definitionDigest = ""
        parameterArrayDraftTexts = [:]
        invalidParameterDraftIndices = []
        selectedRunID = nil
        invalidatePreflight()
    }

    /// Starts a separate v2 definition. Existing v1 definitions and their digests
    /// stay untouched so old evidence retains its original interpretation.
    func startReusableCheck() {
        let selectedApp = connectionDiscovery?.applications.first {
            $0.bundleIdentifier == draft.target.bundleIdentifier
        } ?? connectionDiscovery?.applications.first
        draft = .reusable(
            name: "New intent check",
            target: .init(
                bundleIdentifier: selectedApp?.bundleIdentifier ?? draft.target.bundleIdentifier,
                projectPath: configuration.containerPath,
                scheme: configuration.scheme,
                testTarget: configuration.testTarget,
                destinationIdentifier: configuration.destinationIdentifier,
                route: .appIntentDefinition
            ),
            goal: .init(requestText: "", languageCode: "en-GB", expectedBehavior: ""),
            fixture: .init(
                id: "", version: "", digest: "", isSynthetic: false,
                preparationOperation: "none", cleanupOperation: "none"
            ),
            directControl: .init(
                intentIdentifier: "", parameters: [], outputFields: [], linkedFeatureRunID: nil
            ),
            assertions: [],
            coverage: .init(
                appFeature: .notApplicable, intentIntegration: .required,
                siri: .notApplicable, siriAttemptCount: 1
            ),
            safety: .init(
                mutationPolicy: .readOnly, allowedActions: [],
                permittedConfirmationSteps: [], deadlineSeconds: 60
            ),
            purpose: .exploratory,
            checkMode: .basic,
            requiredClaims: [.executionCompleted],
            observationPlan: [],
            integration: selectedIntegration ?? draft.integration
                ?? .init(id: "pending-integration", version: "1", digest: "")
        )
        draft.projectID = evaluationStore.selectedProjectID
        parameterArrayDraftTexts = [:]
        invalidParameterDraftIndices = []
        selectedRunID = nil
        invalidatePreflight()
    }

    func startStableCheck() {
        startReusableCheck()
        draft.schemaVersion = ScenarioDefinition.stableSchemaVersion
        draft.target.projectPath = ""
        draft.target.scheme = ""
        draft.target.testTarget = ""
        draft.target.destinationIdentifier = ""
        draft.definitionDigest = ""
        draft.testContractDigest = nil
    }

    /// Guided authoring changes a complete copy so the UI never exposes
    /// half-written assertion wiring. Advanced legacy checks remain separate.
    func selectDeclaredAction(_ id: String) {
        guard let declarationCatalog else {
            notice = "Rebuild and check support to load the app's declared actions."
            return
        }
        do {
            draft = try ScenarioExpectationAuthoring.selectingAction(id, in: draft, catalog: declarationCatalog)
            invalidatePreflight()
        } catch { notice = error.localizedDescription }
    }

    func addReturnedCheck(projectionID: String, expected: ScenarioValue, lanes: Set<ScenarioLane>) {
        guard let declarationCatalog else {
            notice = "Rebuild and check support to load the app's result projections."
            return
        }
        do {
            draft = try ScenarioExpectationAuthoring.addingReturnedCheck(
                projectionID: projectionID, expected: expected, lanes: lanes,
                to: draft, catalog: declarationCatalog
            )
            invalidatePreflight()
        } catch { notice = error.localizedDescription }
    }

    func addStateCheck(observerID: String, kind: ScenarioAssertionKind,
                       expected: ScenarioValue, lanes: Set<ScenarioLane>) {
        guard let declarationCatalog else {
            notice = "Rebuild and check support to load the app's observers."
            return
        }
        do {
            draft = try ScenarioExpectationAuthoring.addingStateCheck(
                observerID: observerID, kind: kind, expected: expected, lanes: lanes,
                to: draft, catalog: declarationCatalog
            )
            invalidatePreflight()
        } catch { notice = error.localizedDescription }
    }

    func updateCheck(_ id: UUID, expected: ScenarioValue) {
        guard let declarationCatalog else {
            notice = "Rebuild and check support before editing this declared check."
            return
        }
        do {
            draft = try ScenarioExpectationAuthoring.updatingCheck(
                id, expected: expected, in: draft, catalog: declarationCatalog
            )
            invalidatePreflight()
        } catch { notice = error.localizedDescription }
    }

    func removeCheck(_ id: UUID) {
        do {
            draft = try ScenarioExpectationAuthoring.removingCheck(id, from: draft)
            invalidatePreflight()
        } catch { notice = error.localizedDescription }
    }

    func recordInstalledIntegration(_ identity: ScenarioIntegrationIdentity, appBundleID: String,
                                    projectPath: String, scheme: String, testTarget: String,
                                    applicationProductID: String?, testProductID: String?) {
        selectedIntegration = identity
        declarationCatalog = nil
        configuration.selectedApplicationProductID = applicationProductID
        configuration.selectedTestProductID = testProductID
        configuration.testTarget = testTarget
        configuration.scheme = scheme
        guard draft.schemaVersion == ScenarioDefinition.reusableSchemaVersion
                || draft.schemaVersion == ScenarioDefinition.stableSchemaVersion else { return }
        draft.integration = identity
        draft.target.bundleIdentifier = appBundleID
        if draft.schemaVersion == ScenarioDefinition.reusableSchemaVersion {
            draft.target.projectPath = projectPath
            draft.target.scheme = scheme
            draft.target.testTarget = testTarget
        }
        draft.definitionDigest = ""
        invalidatePreflight()
    }

    func assignProject(id: UUID) {
        guard evaluationStore.projects.contains(where: { $0.id == id && !$0.isArchived }) else {
            notice = "Choose an active project for this scenario."
            return
        }
        guard draft.projectID != id else { return }
        if definitions.contains(where: { $0.id == draft.id && $0.version == draft.version }) {
            duplicateAsNewVersion()
        }
        draft.projectID = id
        draft.definitionDigest = ""
        invalidatePreflight()
    }

    func invalidatePreflight() {
        preflightRevision += 1
        preflight = nil
        verifiedIntegrationSummary = nil
    }

    func refreshPreflight() async {
        guard invalidParameterDraftIndices.isEmpty else {
            invalidatePreflight()
            return
        }
        applyConfigurationToDraft()
        guard let frozen = try? draft.frozen() else { return }
        draft = frozen
        try? await persistence.saveExecutionConfiguration(configuration)
        let revision = preflightRevision
        let checkedConfiguration = configuration
        let checkedProjectTrusted = projectTrusted
        let report = await executor.preflight(
            definition: frozen,
            configuration: checkedConfiguration,
            projectTrusted: checkedProjectTrusted,
            linkedFeatureEvidenceAvailable: linkedFeatureRun(for: frozen) != nil
        )
        guard revision == preflightRevision,
              configuration == checkedConfiguration,
              projectTrusted == checkedProjectTrusted,
              draft == frozen,
              invalidParameterDraftIndices.isEmpty else { return }
        preflight = report
    }

    func run() async {
        guard hasLoaded else {
            notice = "Intent Lab storage must load successfully before a device scenario can run."
            return
        }
        guard !isRunning else { return }
        let executionOwnerID = UUID()
        do {
            try acquireExecutionOwner(executionOwnerID)
        } catch {
            notice = error.localizedDescription
            return
        }
        isRunning = true
        cancellationRequested = false
        finalEvidenceCommitStarted = false
        defer {
            ScenarioExecutionAdmission.shared.release(executionOwnerID)
            isRunning = false
            finalEvidenceCommitStarted = false
            executionTask = nil
        }
        var pendingJournal: ScenarioExecutionJournal?
        let runConfiguration = configuration
        let runTrusted = projectTrusted
        let changedDimensions = statedChangedDimensions
        let linkedRun = linkedFeatureRun(for: draft)
        if draft.schemaVersion == ScenarioDefinition.stableSchemaVersion {
            await runStableExecution(
                ownerID: executionOwnerID, runConfiguration: runConfiguration,
                runTrusted: runTrusted
            )
            await refreshPreflight()
            return
        }
        do {
            let definition = try await freezeAndSave()
            guard !cancellationRequested else { throw XcodeTestExecutorError.cancelled }
            let task = Task {
                try Task.checkCancellation()
                return try await executor.execute(
                    definition: definition,
                    configuration: runConfiguration,
                    projectTrusted: runTrusted,
                    linkedFeatureEvidenceAvailable: linkedRun != nil
                )
            }
            executionTask = task
            let result = try await task.value
            pendingJournal = result.journal
            guard result.reportedTestCount == 1 else {
                throw ScenarioEvidenceImportError.invalidTestCount
            }
            var imported: [ScenarioRun] = []
            let featureResult = linkedRun.map {
                ScenarioFeatureEvidence.laneResult(from: $0, definition: definition)
            }
            for attachment in result.evidenceAttachments {
                var run = try XCTestEvidenceImporter().importEvidence(
                    data: Data(contentsOf: attachment.url),
                    definition: definition,
                    journal: result.journal,
                    artifactRoot: result.attachmentDirectory,
                    ledger: &ledger,
                    supplementaryResults: featureResult.map { [$0] } ?? [],
                    statedChangedDimensions: changedDimensions
                )
                run.xctestExitCode = result.processExitCode
                if result.processExitCode != 0 {
                    run.executionStatus = .invalidEvidence
                    run.outcome = .needsReview
                }
                if result.processExitCode != 0,
                   attachment.isCheckpoint,
                   let failure = result.testFailureMessages.first,
                   let index = run.laneResults.firstIndex(where: { $0.lane == .siri }) {
                    run.laneResults[index].diagnostic = ScenarioDiagnosticClassifier.checkpointDiagnostic(for: failure)
                }
                if run.outcome == .needsReview && result.processExitCode == 0 {
                    do {
                        run = try await ScenarioResponseAssessmentService.assess(run, definition: definition)
                    } catch {
                        notice = "The run was retained, but semantic assessment needs review: \(error.localizedDescription)"
                    }
                }
                imported.append(run)
            }
            imported = Self.evidenceForCommit(imported, cancelled: cancellationRequested)
            // Cancellation is resolved before immutable evidence is committed.
            finalEvidenceCommitStarted = true
            for index in imported.indices {
                imported[index] = try await persistence.saveRun(
                    imported[index], artifactRoot: result.attachmentDirectory
                )
            }
            try await persistence.saveLedger(ledger)
            let canReleaseDevice = !cancellationRequested && Self.canReleaseDevice(
                processExitCode: result.processExitCode,
                attachments: result.evidenceAttachments,
                importedRuns: imported
            )
            try await executor.finishEvidenceValidation(journal: result.journal, accepted: canReleaseDevice)
            pendingJournal = nil
            recoveryJournals = try await executor.currentRecoveryJournals()
            journals = try await persistence.loadJournals()
            runs.insert(contentsOf: imported, at: 0)
            selectedRunID = imported.first?.id
            if statedChangedDimensions == changedDimensions { statedChangedDimensions.removeAll() }
            notice = imported.first.map {
                result.processExitCode == 0
                    ? "Scenario imported as \($0.outcome.rawValue). Direct intent and Siri evidence remain separately labelled."
                    : "The UI test failed (exit \(result.processExitCode)); its available evidence was retained as \($0.outcome.rawValue)."
            }
        } catch {
            if let pendingJournal {
                try? await executor.finishEvidenceValidation(journal: pendingJournal, accepted: false)
            }
            recoveryJournals = (try? await executor.currentRecoveryJournals()) ?? recoveryJournals
            journals = (try? await persistence.loadJournals()) ?? journals
            notice = error.localizedDescription
        }
        await refreshPreflight()
    }

    /// Runs an already frozen batch case through the same admission and executor.
    /// A collection supplies its own plan ID and coordinate IDs; neither the
    /// selected suite nor the selected scenario is used as an execution input.
    @discardableResult
    func runFrozenExecution(
        plan: ScenarioExecutionPlan,
        definition: ScenarioDefinition,
        configuration runConfiguration: XcodeTestConfiguration,
        trusted: Bool
    ) async -> ScenarioExecutionRecord? {
        guard hasLoaded, !isRunning else {
            notice = "Load Intent Lab and finish the current execution before running this batch case."
            return nil
        }
        let ownerID = UUID()
        do { try acquireExecutionOwner(ownerID) }
        catch { notice = error.localizedDescription; return nil }
        isRunning = true
        cancellationRequested = false
        finalEvidenceCommitStarted = false
        defer {
            ScenarioExecutionAdmission.shared.release(ownerID)
            isRunning = false
            finalEvidenceCommitStarted = false
            executionTask = nil
            activeFeatureRunID = nil
        }
        do {
            let connection = try await executor.verifyConnection(
                definition: definition, configuration: runConfiguration, projectTrusted: trusted
            )
            try verify(plan: plan, definition: definition, connection: connection,
                       configuration: runConfiguration)
            return await executeStable(plan: plan, definition: definition,
                                       configuration: runConfiguration, trusted: trusted,
                                       connection: connection, ownerID: ownerID)
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    /// Repeats the selected record's saved requirements with a fresh plan and
    /// current checked build. Edits to the visible draft are never read here.
    @discardableResult
    func rerunSelectedExecution() async -> ScenarioExecutionRecord? {
        guard let previous = selectedExecutionPlan,
              let definition = definitions.first(where: {
                  $0.id == previous.definitionID && $0.version == previous.definitionVersion
                    && $0.definitionDigest == previous.definitionDigest
              }), hasLoaded, !isRunning else {
            notice = "Select a saved execution with its frozen definition before rerunning."
            return nil
        }
        let ownerID = UUID()
        do { try acquireExecutionOwner(ownerID) }
        catch { notice = error.localizedDescription; return nil }
        isRunning = true
        cancellationRequested = false
        finalEvidenceCommitStarted = false
        defer {
            ScenarioExecutionAdmission.shared.release(ownerID)
            isRunning = false
            finalEvidenceCommitStarted = false
            executionTask = nil
            activeFeatureRunID = nil
        }
        do {
            let runConfiguration = configuration
            let connection = try await executor.verifyConnection(
                definition: definition, configuration: runConfiguration,
                projectTrusted: projectTrusted
            )
            let selected = try selectedSubjectRunner(for: definition,
                                                     appDigest: connection.appProduct.sha256)
            let profile = ScenarioExecutionProfile(
                id: UUID(), projectPath: runConfiguration.containerPath,
                scheme: runConfiguration.scheme, testTarget: runConfiguration.testTarget,
                destinationIdentifier: runConfiguration.destinationIdentifier,
                signingSelection: runConfiguration.signingArguments.joined(separator: " "),
                trustedConnectionID: nil,
                buildConfiguration: runConfiguration.configuration
            )
            let plan = try ScenarioExecutionPlan.make(
                definition: definition, profile: profile,
                appProductDigest: connection.appProduct.sha256,
                testProductDigest: connection.testProduct.sha256,
                sourceInputsDigest: connection.buildInputsDigest,
                sourceRevision: connection.sourceRevision,
                runnerBuildID: selected?.runner.identity.buildProvenance?.buildID,
                runnerID: selected?.runner.id,
                comparisonPolicy: .init(mode: .compareAppChanges, baselineRunID: previous.id)
            )
            return await executeStable(plan: plan, definition: definition,
                                       configuration: runConfiguration, trusted: projectTrusted,
                                       connection: connection, ownerID: ownerID)
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    /// Recovers only a completed feature run's history write and coordinate.
    /// No adapter or app request is created on this path.
    @discardableResult
    func retryPendingFeatureSave(planID: UUID) async -> ScenarioExecutionRecord? {
        guard hasLoaded, !isRunning,
              let plan = executionPlans.first(where: { $0.id == planID }),
              !executionRecords.contains(where: { $0.planID == planID }),
              let definition = definitions.first(where: {
                  $0.id == plan.definitionID && $0.version == plan.definitionVersion
                    && $0.definitionDigest == plan.definitionDigest
              }),
              let projectID = definition.projectID else {
            notice = "Select an unfinished feature execution with saved requirements."
            return nil
        }
        let ownerID = UUID()
        do { try acquireExecutionOwner(ownerID) }
        catch { notice = error.localizedDescription; return nil }
        isRunning = true
        defer {
            ScenarioExecutionAdmission.shared.release(ownerID)
            isRunning = false
        }
        do {
            guard var progress = try await persistence.loadProgress(planID: planID),
                  let index = progress.records.firstIndex(where: {
                      $0.coordinate.lane == .appFeature && $0.state == .recoveryRequired
                        && $0.evidenceRunID != nil
                  }),
                  let runID = progress.records[index].evidenceRunID else {
                throw ScenarioPersistenceError.invalidRun("No feature save is pending for this execution.")
            }
            let suiteID = ScenarioFeatureSuiteIdentity(definition: definition).id
            let saved = try evaluationStore.retrySnapshotRunSave(
                id: runID, projectID: projectID, suiteID: suiteID
            ) ?? evaluationStore.run(with: runID)
            guard let saved else {
                throw ScenarioPersistenceError.invalidRun("The completed feature run has no recoverable snapshot or saved history.")
            }
            progress.records[index] = try await runFeatureChild(
                coordinate: progress.records[index].coordinate,
                plan: plan, definition: definition, ownerID: ownerID,
                runID: runID, resumeRun: saved
            )
            try await checkpoint(plan: plan, records: progress.records)
            let record = try ScenarioExecutionRecord.make(plan: plan, records: progress.records)
            try await persistence.saveExecutionRecord(record)
            executionRecords.insert(record, at: 0)
            selectedExecutionID = record.id
            notice = "The completed feature result was saved without rerunning the app. Unstarted routes remain visible."
            return record
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    /// Commits an already imported native child from its durable stage. The
    /// destination remains quarantined after a relaunch until readiness is
    /// independently proven; this method never starts XCTest again.
    @discardableResult
    func retryPendingNativeSave(planID: UUID, coordinateID: UUID) async -> ScenarioExecutionRecord? {
        guard hasLoaded, !isRunning,
              let plan = executionPlans.first(where: { $0.id == planID }),
              !executionRecords.contains(where: { $0.planID == planID }) else {
            notice = "Select an unfinished native execution before retrying its evidence save."
            return nil
        }
        let ownerID = UUID()
        do { try acquireExecutionOwner(ownerID) }
        catch { notice = error.localizedDescription; return nil }
        isRunning = true
        defer {
            ScenarioExecutionAdmission.shared.release(ownerID)
            isRunning = false
        }
        do {
            guard let pending = try await persistence.loadPendingNativeSave(
                planID: planID, coordinateID: coordinateID
            ), var progress = try await persistence.loadProgress(planID: planID),
                  let index = progress.records.firstIndex(where: { $0.id == coordinateID }),
                  progress.records[index].state == .recoveryRequired,
                  pending.run.scenarioID == plan.definitionID,
                  pending.run.scenarioVersion == plan.definitionVersion,
                  pending.run.scenarioDigest == plan.definitionDigest,
                  pending.run.invocation.appProduct?.sha256 == plan.appProductDigest,
                  pending.run.invocation.testProduct?.sha256 == plan.testProductDigest,
                  pending.run.laneResults.count == 1,
                  let lane = pending.run.laneResults.first,
                  lane.caseID == progress.records[index].coordinate.caseID,
                  lane.lane == progress.records[index].coordinate.lane,
                  lane.attempt == progress.records[index].coordinate.repetition else {
                throw ScenarioPersistenceError.invalidRun("The pending native child does not match its frozen coordinate.")
            }
            let existing = try await persistence.loadRuns(scenarioID: pending.run.scenarioID)
                .first(where: { $0.id == pending.run.id })
            let saved: ScenarioRun
            if let existing {
                saved = existing
            } else {
                saved = try await persistence.saveRun(
                    pending.run, artifactRoot: URL(filePath: pending.artifactRootPath)
                )
            }
            guard saved.id == pending.run.id,
                  saved.scenarioID == pending.run.scenarioID,
                  saved.scenarioVersion == pending.run.scenarioVersion,
                  saved.scenarioDigest == pending.run.scenarioDigest,
                  saved.invocation == pending.run.invocation,
                  saved.laneResults.count == 1,
                  saved.laneResults[0].id == lane.id,
                  saved.laneResults[0].observations == lane.observations,
                  saved.laneResults[0].assertionResults == lane.assertionResults else {
                throw ScenarioPersistenceError.invalidRun("Saved native evidence differs from its staged child.")
            }
            var merged = try await persistence.loadLedger()
            merged.importedInvocationIDs.formUnion(pending.ledger.importedInvocationIDs)
            merged.importedNonces.formUnion(pending.ledger.importedNonces)
            merged.importedArtifactIDs.formUnion(pending.ledger.importedArtifactIDs)
            try await persistence.saveLedger(merged)
            ledger = merged
            if let journal = try await persistence.loadJournals().first(where: { $0.id == saved.id }) {
                try await executor.finishEvidenceValidation(journal: journal, accepted: false)
            }
            try await persistence.clearPendingNativeSave(planID: planID, coordinateID: coordinateID)
            progress.records[index] = .init(
                coordinate: progress.records[index].coordinate,
                state: saved.laneResults[0].executionStatus == .completed
                    ? .completed : .failedToExecute,
                evidenceRunID: saved.id,
                evidenceLaneResultID: saved.laneResults[0].id,
                detail: saved.laneResults[0].diagnostic,
                laneResult: saved.laneResults[0],
                evidenceDigest: try Self.evidenceDigest(saved)
            )
            try await checkpoint(plan: plan, records: progress.records)
            let record = try ScenarioExecutionRecord.make(plan: plan, records: progress.records)
            try await persistence.saveExecutionRecord(record)
            executionRecords.insert(record, at: 0)
            selectedExecutionID = record.id
            runs.insert(saved, at: 0)
            recoveryJournals = try await executor.currentRecoveryJournals()
            notice = "Saved the native evidence without rerunning the app. Confirm device readiness before another route."
            return record
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    func exportSelectedExecution(to destination: URL) async throws {
        guard let plan = selectedExecutionPlan,
              let record = selectedExecutionRecord,
              record.planID == plan.id,
              let definition = definitions.first(where: {
                  $0.id == plan.definitionID && $0.version == plan.definitionVersion
                    && $0.definitionDigest == plan.definitionDigest
              }),
              let inputs = plan.sourceInputsDigest, !inputs.isEmpty else {
            throw ScenarioPersistenceError.invalidRun("Select a complete saved execution with checked source identity before exporting.")
        }
        var artifacts: [UUID: Data] = [:]
        let item = try await durableBundleCase(definition: definition, plan: plan,
                                               record: record, artifacts: &artifacts)
        let requirements = IntentEvidenceRequirements(
            collectionID: "single:\(definition.id.uuidString)",
            cases: [.init(required: true, definition: definition)]
        )
        let snapshot = IntentEvidenceBundleSnapshot(
            requirements: requirements,
            cases: [item],
            sourceRevision: plan.sourceRevision ?? "inputs-sha256:\(inputs)", artifactBytes: artifacts
        )
        try IntentEvidenceBundle.export(snapshot, to: destination)
    }

    func qualificationForSelectedExecution() async throws -> IntentEvidenceCaseDecision? {
        guard let plan = selectedExecutionPlan,
              let record = selectedExecutionRecord,
              let definition = definitions.first(where: {
                  $0.id == plan.definitionID && $0.version == plan.definitionVersion
                    && $0.definitionDigest == plan.definitionDigest
              }) else { return nil }
        var artifacts: [UUID: Data] = [:]
        let item = try await durableBundleCase(
            definition: definition, plan: plan, record: record, artifacts: &artifacts
        )
        return IntentEvidenceQualification.qualify(
            item, requirement: .init(required: true, definition: definition),
            referenceTime: Date()
        )
    }

    /// Exports the entire trusted collection membership with only the fresh
    /// terminal children belonging to this batch. Missing cases stay missing.
    func exportSelectedBatch(to destination: URL) async throws {
        guard let manifest = selectedBatchManifest,
              let collection = collections.first(where: {
                  $0.id == manifest.collectionID && $0.version == manifest.collectionVersion
              }),
              let result = batchResults.first(where: { $0.manifestID == manifest.id }),
              manifest.hasValidDigest, !result.executions.isEmpty else {
            throw ScenarioPersistenceError.invalidRun("Select a saved batch with fresh terminal case evidence before exporting.")
        }
        guard let persistedManifest = try await collectionStore.loadManifest(id: manifest.id),
              persistedManifest == manifest,
              let persistedResult = try await collectionStore.loadResult(id: result.id),
              persistedResult == result,
              let persistedCollection = try await collectionStore.loadCollection(
                  id: collection.id, version: collection.version
              ), persistedCollection == collection else {
            throw ScenarioPersistenceError.invalidRun("Batch manifest, result, or collection is missing from durable history.")
        }
        let trusted = try collection.members.map { member -> ScenarioDefinition in
            guard let definition = definitions.first(where: {
                $0.id == member.caseID && $0.version == member.version
                    && $0.definitionDigest == member.definitionDigest
                    && $0.testContractDigest == member.testContractDigest
            }) else { throw ScenarioPersistenceError.invalidRun("A trusted collection requirement is missing.") }
            return definition
        }
        var artifacts: [UUID: Data] = [:]
        var items: [IntentEvidenceBundleCase] = []
        var sourceRevisions: Set<String> = []
        for execution in result.executions {
            guard let batchCase = manifest.cases.first(where: { $0.executionPlanID == execution.planID }),
                  let definition = trusted.first(where: { $0.id == batchCase.id }),
                  let plan = executionPlans.first(where: { $0.id == execution.planID }),
                  plan.definitionID == definition.id,
                  plan.appProductDigest == manifest.appProductDigest,
                  let inputs = plan.sourceInputsDigest, !inputs.isEmpty else {
                throw ScenarioPersistenceError.invalidRun("A batch child lacks its frozen plan or checked source identity.")
            }
            sourceRevisions.insert(plan.sourceRevision ?? "inputs-sha256:\(inputs)")
            items.append(try await durableBundleCase(
                definition: definition, plan: plan, record: execution, artifacts: &artifacts
            ))
        }
        guard sourceRevisions.count == 1, let source = sourceRevisions.first else {
            throw ScenarioPersistenceError.invalidRun("Batch children came from different checked source inputs.")
        }
        let requirements = IntentEvidenceRequirements(
            collectionID: collection.id.uuidString,
            cases: trusted.map { .init(required: true, definition: $0) }
        )
        try IntentEvidenceBundle.export(
            .init(requirements: requirements, cases: items, sourceRevision: source,
                  artifactBytes: artifacts, collection: collection,
                  batchManifest: manifest, batchResult: result),
            to: destination
        )
    }

    private func durableBundleCase(
        definition: ScenarioDefinition, plan: ScenarioExecutionPlan,
        record: ScenarioExecutionRecord, artifacts: inout [UUID: Data]
    ) async throws -> IntentEvidenceBundleCase {
        guard record.planID == plan.id,
              let savedPlan = try await persistence.loadPlans().first(where: { $0.id == plan.id }),
              try Self.matchesPersistedEncoding(savedPlan, plan),
              let savedRecord = try await persistence.loadExecutionRecords().first(where: { $0.id == record.id }),
              try Self.matchesPersistedEncoding(savedRecord, record) else {
            throw ScenarioPersistenceError.invalidRun("Execution plan or terminal record is missing from durable history.")
        }
        let childIDs = Set(record.records.filter { $0.coordinate.lane != .appFeature }
            .compactMap(\.evidenceRunID))
        let nativeRuns = try await persistence.loadRuns(scenarioID: definition.id)
            .filter { childIDs.contains($0.id) }
        guard nativeRuns.count == childIDs.count else {
            throw ScenarioPersistenceError.invalidRun("A native child run is missing from durable history.")
        }
        let allJournals = try await persistence.loadJournals()
        let childJournals = allJournals.filter { childIDs.contains($0.id) }
        guard childJournals.count == childIDs.count else {
            throw ScenarioPersistenceError.invalidRun("A native child journal is missing from durable history.")
        }
        for run in nativeRuns {
            for artifact in run.laneResults.flatMap(\.artifacts) {
                artifacts[artifact.id] = try Data(contentsOf: artifactURL(run: run, artifact: artifact))
            }
        }
        let selection = try await assessmentStore.latestSelectionRecord(executionRecord: savedRecord)
        let retained: [ScenarioRetainedAssessmentArtifact]
        if let selection {
            retained = try await assessmentStore.retainedArtifacts(
                for: selection, executionRecord: savedRecord,
                runs: nativeRuns, definition: definition
            )
        } else if savedRecord.selectedAssessments != nil {
            retained = try await assessmentStore.retainedArtifacts(
                for: savedRecord, runs: nativeRuns, definition: definition
            )
        } else {
            retained = []
        }
        return .init(definition: definition, plan: savedPlan, record: savedRecord,
                     runs: nativeRuns, journals: childJournals,
                     selectedAssessment: selection, retainedAssessments: retained)
    }

    private static func matchesPersistedEncoding<T: Encodable>(_ lhs: T, _ rhs: T) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(lhs) == encoder.encode(rhs)
    }

    func reloadSelectedAssessmentOverlay(expectedExecutionID: UUID? = nil) async {
        guard let record = selectedExecutionRecord,
              expectedExecutionID == nil || expectedExecutionID == record.id else {
            selectedAssessmentOverlay = nil
            assessmentSelectionHistory = []
            return
        }
        do {
            let latest = try await assessmentStore.latestSelectionRecord(executionRecord: record)
            let history = try await assessmentStore.selectionRecords(executionRecord: record)
            guard selectedExecutionID == record.id else { return }
            selectedAssessmentOverlay = latest
            assessmentSelectionHistory = history
        } catch {
            guard selectedExecutionID == record.id else { return }
            selectedAssessmentOverlay = nil
            assessmentSelectionHistory = []
            notice = "Saved assessment selections need review: \(error.localizedDescription)"
        }
    }

    func assessmentOverlay(for executionID: UUID) async throws -> ScenarioAssessmentSelectionRecord? {
        guard let record = executionRecords.first(where: { $0.id == executionID }) else {
            throw ScenarioPersistenceError.invalidRun("The selected execution record is unavailable.")
        }
        return try await assessmentStore.latestSelectionRecord(executionRecord: record)
    }

    func assessmentHistory(coordinateID: UUID) async throws -> ScenarioAssessmentHistory {
        guard let record = selectedExecutionRecord,
              let plan = selectedExecutionPlan,
              let coordinate = record.records.first(where: { $0.id == coordinateID }),
              let laneResultID = coordinate.evidenceLaneResultID,
              let definition = definitions.first(where: {
                  $0.id == plan.definitionID && $0.version == plan.definitionVersion
                    && $0.definitionDigest == plan.definitionDigest
              }) else {
            throw ScenarioPersistenceError.invalidRun("Select a saved route before reviewing assessments.")
        }
        if coordinate.coordinate.lane == .appFeature {
            return try await assessmentStore.featureHistory(
                for: record, laneResultID: laneResultID, definition: definition
            )
        }
        guard let runID = coordinate.evidenceRunID,
              let run = runs.first(where: { $0.id == runID }) else {
            throw ScenarioPersistenceError.invalidRun("The native child run is missing from history.")
        }
        return try await assessmentStore.history(
            for: run, laneResultID: laneResultID, definition: definition
        )
    }

    /// A judge reads only saved raw output and host-held requirements. The
    /// selected suite and app execution remain untouched.
    @discardableResult
    func reassessSelectedCoordinate(
        coordinateID: UUID, assertionID: UUID,
        judgeConfiguration: EvaluationJudgeConfiguration
    ) async -> ScenarioIndependentAssessment? {
        do {
            let context = try selectedAssessmentContext(coordinateID: coordinateID,
                                                        assertionID: assertionID)
            let judge = try resolvedAssessmentJudge(configuration: judgeConfiguration)
            let assessment: ScenarioIndependentAssessment
            if context.coordinate.coordinate.lane == .appFeature {
                assessment = try await assessmentStore.reassessSavedFeatureOutput(
                    coordinateID: coordinateID, assertionID: assertionID,
                    executionRecord: context.record, definition: context.definition,
                    judgeConfiguration: judgeConfiguration,
                    resolvedJudge: judge
                )
            } else {
                guard let runID = context.coordinate.evidenceRunID,
                      let run = runs.first(where: { $0.id == runID }),
                      let lane = context.coordinate.laneResult else {
                    throw ScenarioPersistenceError.invalidRun("The native child output is unavailable.")
                }
                let reference: String
                switch context.assertion.expectedValue {
                case .string(let value): reference = value
                case nil: reference = ""
                default: throw ScenarioPersistenceError.invalidRun("The semantic reference must be text.")
                }
                let request = ScenarioAssessmentRequest(
                    scenarioRunID: run.id, laneResult: lane,
                    assertion: context.assertion,
                    effectiveInput: context.definition.goal.requestText,
                    verifiedReference: reference,
                    judgeConfiguration: judgeConfiguration
                )
                assessment = try await assessmentStore.reassessSavedOutput(
                    request: request, run: run, definition: context.definition,
                    resolvedJudge: judge
                )
            }
            _ = try await sealSelectedAssessments(
                record: context.record, definition: context.definition
            )
            await reloadSelectedAssessmentOverlay(expectedExecutionID: context.record.id)
            notice = "Saved output was assessed again without running the app."
            return assessment
        } catch {
            notice = "Assessment needs review: \(error.localizedDescription). The captured app result is unchanged; retry selection saving without rerunning it."
            return nil
        }
    }

    func selectAssessment(_ assessmentID: UUID, coordinateID: UUID,
                          assertionID: UUID) async {
        do {
            let context = try selectedAssessmentContext(coordinateID: coordinateID,
                                                        assertionID: assertionID)
            guard let laneResultID = context.coordinate.evidenceLaneResultID else {
                throw ScenarioPersistenceError.invalidRun("Route evidence is missing.")
            }
            if context.coordinate.coordinate.lane == .appFeature {
                try await assessmentStore.selectFeature(
                    assessmentID, for: laneResultID, assertionID: assertionID,
                    executionRecord: context.record, definition: context.definition
                )
            } else {
                guard let runID = context.coordinate.evidenceRunID,
                      let run = runs.first(where: { $0.id == runID }) else {
                    throw ScenarioPersistenceError.invalidRun("The native child run is unavailable.")
                }
                try await assessmentStore.select(
                    assessmentID, for: laneResultID, assertionID: assertionID,
                    run: run, definition: context.definition
                )
            }
            _ = try await sealSelectedAssessments(record: context.record,
                                                  definition: context.definition)
            await reloadSelectedAssessmentOverlay(expectedExecutionID: context.record.id)
        } catch { notice = error.localizedDescription }
    }

    func retryAssessmentSelectionSave() async {
        guard let record = selectedExecutionRecord,
              let plan = selectedExecutionPlan,
              let definition = definitions.first(where: {
                  $0.id == plan.definitionID && $0.version == plan.definitionVersion
                    && $0.definitionDigest == plan.definitionDigest
              }) else {
            notice = "Select a saved execution before retrying assessment selection."
            return
        }
        do {
            _ = try await sealSelectedAssessments(record: record, definition: definition)
            await reloadSelectedAssessmentOverlay(expectedExecutionID: record.id)
            notice = "Assessment selection was saved without running the app."
        } catch { notice = error.localizedDescription }
    }

    private func selectedAssessmentContext(
        coordinateID: UUID, assertionID: UUID
    ) throws -> (record: ScenarioExecutionRecord, coordinate: ScenarioExecutionCoordinateRecord,
                 definition: ScenarioDefinition, assertion: ScenarioAssertion) {
        guard let record = selectedExecutionRecord,
              let plan = selectedExecutionPlan,
              let coordinate = record.records.first(where: { $0.id == coordinateID }),
              let definition = definitions.first(where: {
                  $0.id == plan.definitionID && $0.version == plan.definitionVersion
                    && $0.definitionDigest == plan.definitionDigest
              }),
              let assertion = definition.assertions.first(where: {
                  $0.id == assertionID && $0.kind == .semanticRubric
                    && $0.applies(to: coordinate.coordinate.lane)
              }) else {
            throw ScenarioPersistenceError.invalidRun("Choose a semantic check on a saved route.")
        }
        return (record, coordinate, definition, assertion)
    }

    private func resolvedAssessmentJudge(
        configuration: EvaluationJudgeConfiguration
    ) throws -> EvaluationResolvedJudgeConnection? {
        guard configuration.mode == .connection else { return nil }
        guard let connectionID = configuration.connectionID else {
            throw ScenarioPersistenceError.invalidRun("Choose an approved independent judge connection.")
        }
        return try evaluationStore.resolvedScenarioJudge(
            connectionID: connectionID, configuration: configuration
        )
    }

    private func sealSelectedAssessments(
        record: ScenarioExecutionRecord, definition: ScenarioDefinition
    ) async throws -> ScenarioAssessmentSelectionRecord {
        let previous = try await assessmentStore.latestSelectionRecord(executionRecord: record)
        return try await assessmentStore.sealSelection(
            executionRecord: record, runs: runs, definition: definition,
            previousSelectionID: previous?.id
        )
    }

    @discardableResult
    func createCollection(name: String, caseIDs: [UUID]) async throws -> ScenarioCollection {
        guard hasLoaded, !isRunning, !caseIDs.isEmpty,
              Set(caseIDs).count == caseIDs.count else {
            throw ScenarioCollectionError.invalidSelection
        }
        let cases = try caseIDs.map { id -> ScenarioDefinition in
            guard let definition = definitions.filter({ $0.id == id }).max(by: { $0.version < $1.version }),
                  definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
                  definition.hasValidDigest else {
                throw ScenarioCollectionError.invalidDefinition(id)
            }
            return definition
        }
        guard let projectID = cases.first?.projectID,
              cases.allSatisfy({ $0.projectID == projectID }) else {
            throw ScenarioCollectionError.invalidSelection
        }
        let collection = try ScenarioCollection(
            projectID: projectID, name: name,
            members: cases.map { try ScenarioCollectionService.member($0) }
        )
        try await collectionStore.saveCollection(collection, definitions: cases)
        collections.append(collection)
        selectedCollectionID = collection.id
        return collection
    }

    @discardableResult
    func reviseSelectedCollection(caseIDs: [UUID]) async throws -> ScenarioCollection {
        guard hasLoaded, !isRunning, let collection = selectedCollection,
              !caseIDs.isEmpty, Set(caseIDs).count == caseIDs.count else {
            throw ScenarioCollectionError.invalidSelection
        }
        let saved = try await persistence.loadDefinitions()
        let retained = collection.members.map(\.caseID).filter { caseIDs.contains($0) }
        let additions = caseIDs.filter { !retained.contains($0) }
        let orderedIDs = retained + additions
        let selected = try orderedIDs.map { id -> ScenarioDefinition in
            guard let definition = saved.filter({
                $0.id == id && $0.projectID == collection.projectID
                    && $0.schemaVersion == ScenarioDefinition.stableSchemaVersion
                    && $0.hasValidDigest
            }).max(by: { $0.version < $1.version }) else {
                throw ScenarioCollectionError.invalidDefinition(id)
            }
            return definition
        }
        let members = try selected.map(ScenarioCollectionService.member)
        guard members != collection.members else { return collection }
        let revised = try collection.revised(members: members)
        try await collectionStore.saveCollection(revised, definitions: selected)
        for definition in selected where !definitions.contains(where: {
            $0.id == definition.id && $0.version == definition.version
                && $0.definitionDigest == definition.definitionDigest
        }) {
            definitions.append(definition)
        }
        collections.append(revised)
        selectedCollectionID = revised.id
        return revised
    }

    @discardableResult
    func addApprovedVariation(_ approval: ScenarioApprovedVariation) async throws -> ScenarioCollection {
        guard let collection = selectedCollection,
              let sourceMember = collection.members.first(where: {
                  $0.caseID == approval.draft.sourceCaseID
              }),
              let source = definitions.first(where: {
                  $0.id == sourceMember.caseID && $0.version == sourceMember.version
                    && $0.definitionDigest == sourceMember.definitionDigest
              }) else {
            throw ScenarioCollectionError.invalidSelection
        }
        let addition = try ScenarioCollectionService.addingApprovedVariations(
            [approval], source: source, to: collection
        )
        let allCases = try addition.collection.members.map { member -> ScenarioDefinition in
            if let newCase = addition.cases.first(where: { $0.id == member.caseID }) { return newCase }
            guard let saved = definitions.first(where: {
                $0.id == member.caseID && $0.version == member.version
                    && $0.definitionDigest == member.definitionDigest
            }) else { throw ScenarioCollectionError.invalidDefinition(member.caseID) }
            return saved
        }
        for definition in addition.cases { try await persistence.saveDefinition(definition) }
        try await collectionStore.saveCollection(addition.collection, definitions: allCases)
        definitions.append(contentsOf: addition.cases)
        collections.append(addition.collection)
        selectedCollectionID = addition.collection.id
        return addition.collection
    }

    @discardableResult
    func runSelectedCollection(
        scope: ScenarioCollectionScope = .full,
        selectedCaseIDs: Set<UUID>? = nil,
        priorBatchID: UUID? = nil
    ) async -> ScenarioCollectionBatchResult? {
        guard hasLoaded, !isRunning, let collection = selectedCollection else {
            notice = "Select a saved collection and finish the current run first."
            return nil
        }
        let ownerID = UUID()
        do { try acquireExecutionOwner(ownerID) }
        catch { notice = error.localizedDescription; return nil }
        isRunning = true
        cancellationRequested = false
        finalEvidenceCommitStarted = false
        defer {
            ScenarioExecutionAdmission.shared.release(ownerID)
            isRunning = false
            finalEvidenceCommitStarted = false
            executionTask = nil
            activeFeatureRunID = nil
        }
        do {
            let definitionsForCollection = try collection.members.map { member -> ScenarioDefinition in
                guard let definition = definitions.first(where: {
                    $0.id == member.caseID && $0.version == member.version
                        && $0.definitionDigest == member.definitionDigest
                }) else { throw ScenarioCollectionError.invalidDefinition(member.caseID) }
                return definition
            }
            let runConfiguration = configuration
            let selectedIDs: Set<UUID>
            if scope == .rerunFailed {
                guard selectedCaseIDs == nil, let priorBatchID,
                      let prior = batchManifests.first(where: { $0.id == priorBatchID }) else {
                    throw ScenarioCollectionError.invalidSelection
                }
                let assessment = ScenarioCollectionService.assess(
                    manifest: prior, collection: collection,
                    result: batchResults.first { $0.manifestID == priorBatchID }, runs: runs
                )
                guard assessment.qualification != .incompatible else {
                    throw ScenarioCollectionError.invalidManifest
                }
                selectedIDs = ScenarioCollectionService.failedCaseIDs(in: assessment)
            } else {
                selectedIDs = selectedCaseIDs ?? Set(collection.members.map(\.caseID))
            }
            guard let first = definitionsForCollection.first(where: { selectedIDs.contains($0.id) }) else {
                throw ScenarioCollectionError.invalidSelection
            }
            let checked = try await executor.verifyConnection(
                definition: first, configuration: runConfiguration,
                projectTrusted: projectTrusted
            )
            var inputDigests: [UUID: String] = [:]
            for definition in definitionsForCollection
                where selectedIDs.contains(definition.id) && definition.coverage.appFeature != .notApplicable {
                guard let binding = definition.featureBinding else {
                    throw ScenarioCollectionError.invalidDefinition(definition.id)
                }
                inputDigests[definition.id] = try ScenarioSubjectFeatureAdapter.subjectInputDigest(
                    binding: binding, fixture: definition.fixture
                )
            }
            let manifest: ScenarioCollectionBatchManifest
            if scope == .rerunFailed {
                guard selectedCaseIDs == nil,
                      let priorBatchID,
                      let prior = batchManifests.first(where: { $0.id == priorBatchID }) else {
                    throw ScenarioCollectionError.invalidSelection
                }
                manifest = try ScenarioCollectionService.freezeFailedRerun(
                    collection: collection, definitions: definitionsForCollection,
                    priorManifest: prior,
                    priorResult: batchResults.first { $0.manifestID == priorBatchID },
                    priorRuns: runs, appProductDigest: checked.appProduct.sha256,
                    subjectInputDigests: inputDigests
                )
            } else {
                manifest = try ScenarioCollectionService.freezeManifest(
                    collection: collection, definitions: definitionsForCollection,
                    scope: scope, appProductDigest: checked.appProduct.sha256,
                    subjectInputDigests: inputDigests,
                    selectedCaseIDs: selectedCaseIDs, priorBatchID: priorBatchID
                )
            }
            try await collectionStore.saveManifest(manifest, collection: collection)
            batchManifests.insert(manifest, at: 0)
            selectedBatchID = manifest.id
            var completed: [ScenarioExecutionRecord] = []
            var stopReason: String?
            for batchCase in manifest.cases {
                if cancellationRequested { break }
                do {
                    guard let definition = definitionsForCollection.first(where: { $0.id == batchCase.id }) else {
                        throw ScenarioCollectionError.invalidSelection
                    }
                    let connection = try await executor.verifyConnection(
                        definition: definition, configuration: runConfiguration,
                        projectTrusted: projectTrusted
                    )
                    guard connection.appProduct.sha256 == manifest.appProductDigest else {
                        throw ScenarioCollectionError.invalidManifest
                    }
                    let selected = try selectedSubjectRunner(
                        for: definition, appDigest: connection.appProduct.sha256
                    )
                    let profile = ScenarioExecutionProfile(
                        id: UUID(), projectPath: runConfiguration.containerPath,
                        scheme: runConfiguration.scheme, testTarget: runConfiguration.testTarget,
                        destinationIdentifier: runConfiguration.destinationIdentifier,
                        signingSelection: runConfiguration.signingArguments.joined(separator: " "),
                        trustedConnectionID: nil,
                        buildConfiguration: runConfiguration.configuration
                    )
                    let plan = try ScenarioExecutionPlan.make(
                        definition: definition, profile: profile,
                        appProductDigest: connection.appProduct.sha256,
                        testProductDigest: connection.testProduct.sha256,
                        sourceInputsDigest: connection.buildInputsDigest,
                        sourceRevision: connection.sourceRevision,
                        runnerBuildID: selected?.runner.identity.buildProvenance?.buildID,
                        runnerID: selected?.runner.id,
                        plannedCoordinates: manifest.coordinates.filter { $0.caseID == definition.id },
                        id: batchCase.executionPlanID, createdAt: manifest.createdAt
                    )
                    guard let record = await executeStable(
                        plan: plan, definition: definition,
                        configuration: runConfiguration, trusted: projectTrusted,
                        connection: connection, ownerID: ownerID
                    ) else { break }
                    completed.append(record)
                    finalEvidenceCommitStarted = false
                    if record.records.contains(where: {
                        $0.state == .failedToExecute || $0.state == .recoveryRequired
                    }) { break }
                } catch {
                    stopReason = "Stopped at \(batchCase.id): \(error.localizedDescription)"
                    break
                }
            }
            let result = ScenarioCollectionBatchResult(
                id: manifest.id, manifestID: manifest.id,
                executions: completed, recordedAt: Date()
            )
            try await collectionStore.saveResult(result)
            batchResults.insert(result, at: 0)
            notice = "Collection batch recorded: \(completed.count)/\(manifest.cases.count) cases executed."
                + (stopReason.map { " \($0)" } ?? "")
            return result
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func rerunFailedSelectedBatch() async -> ScenarioCollectionBatchResult? {
        guard let manifest = selectedBatchManifest,
              let assessment = selectedBatchAssessment,
              manifest.collectionID == selectedCollectionID else {
            notice = "Select a saved batch to rerun its failed cases."
            return nil
        }
        let selected = Set(assessment.coordinates.filter {
            $0.outcome != .passed || $0.terminalState != .completed
        }.map { $0.coordinate.caseID })
        guard !selected.isEmpty else {
            notice = "This batch has no failed or missing cases to rerun."
            return nil
        }
        return await runSelectedCollection(scope: .rerunFailed,
                                           priorBatchID: manifest.id)
    }

    private func runStableExecution(ownerID: UUID, runConfiguration: XcodeTestConfiguration,
                                    runTrusted: Bool) async {
        do {
            let definition = try await freezeAndSave()
            guard !cancellationRequested else { throw XcodeTestExecutorError.cancelled }
            let connection = try await executor.verifyConnection(
                definition: definition, configuration: runConfiguration, projectTrusted: runTrusted
            )
            let selected = try selectedSubjectRunner(for: definition, appDigest: connection.appProduct.sha256)
            let profile = ScenarioExecutionProfile(
                id: UUID(), projectPath: runConfiguration.containerPath,
                scheme: runConfiguration.scheme, testTarget: runConfiguration.testTarget,
                destinationIdentifier: runConfiguration.destinationIdentifier,
                signingSelection: runConfiguration.signingArguments.joined(separator: " "),
                trustedConnectionID: nil,
                buildConfiguration: runConfiguration.configuration
            )
            let plan = try ScenarioExecutionPlan.make(
                definition: definition, profile: profile,
                appProductDigest: connection.appProduct.sha256,
                testProductDigest: connection.testProduct.sha256,
                sourceInputsDigest: connection.buildInputsDigest,
                sourceRevision: connection.sourceRevision,
                runnerBuildID: selected?.runner.identity.buildProvenance?.buildID,
                runnerID: selected?.runner.id
            )
            _ = await executeStable(plan: plan, definition: definition,
                                    configuration: runConfiguration, trusted: runTrusted,
                                    connection: connection, ownerID: ownerID)
        } catch {
            notice = error.localizedDescription
        }
    }

    private func verify(plan: ScenarioExecutionPlan, definition: ScenarioDefinition,
                        connection: ScenarioVerifiedConnection,
                        configuration: XcodeTestConfiguration) throws {
        guard definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
              definition.hasValidDigest,
              plan.definitionID == definition.id,
              plan.definitionVersion == definition.version,
              plan.definitionDigest == definition.definitionDigest,
              plan.testContractDigest == definition.testContractDigest,
              plan.fixtureContractDigest == definition.fixture.digest,
              plan.profile.projectPath == configuration.containerPath,
              plan.profile.scheme == configuration.scheme,
              plan.profile.testTarget == configuration.testTarget,
              plan.profile.destinationIdentifier == configuration.destinationIdentifier,
              plan.profile.buildConfiguration == configuration.configuration,
              plan.profile.signingSelection == configuration.signingArguments.joined(separator: " "),
              plan.appProductDigest == connection.appProduct.sha256,
              plan.testProductDigest == connection.testProduct.sha256,
              plan.sourceInputsDigest == connection.buildInputsDigest,
              (plan.sourceRevision == nil || plan.sourceRevision == connection.sourceRevision) else {
            throw ScenarioPersistenceError.invalidRun("The frozen plan, source, build, or execution profile changed. Create a new plan.")
        }
        let expected = try ScenarioExecutionPlan.make(
            definition: definition, profile: plan.profile,
            appProductDigest: plan.appProductDigest, testProductDigest: plan.testProductDigest,
            sourceInputsDigest: plan.sourceInputsDigest ?? "",
            sourceRevision: plan.sourceRevision,
            runnerBuildID: plan.runnerBuildID, runnerID: plan.runnerID,
            plannedCoordinates: plan.coordinates, comparisonPolicy: plan.comparisonPolicy,
            id: plan.id, createdAt: plan.createdAt
        )
        guard expected == plan else { throw ScenarioPersistenceError.invalidRun("execution plan") }
    }

    private func selectedSubjectRunner(
        for definition: ScenarioDefinition, appDigest: String,
        frozenRunnerID: UUID? = nil
    ) throws -> (runner: DeveloperRunnerSnapshot, feature: DeveloperFeatureDescriptor)? {
        guard definition.coverage.appFeature != .notApplicable else { return nil }
        guard let binding = definition.featureBinding, let developerRunnerStore else {
            throw ScenarioPersistenceError.invalidRun("Connect a declared App Feature runner before running this check.")
        }
        func matches(_ feature: DeveloperFeatureDescriptor) -> Bool {
            guard feature.id == binding.featureID else { return false }
            return (try? ScenarioSubjectFeatureAdapter.interfaceDigest(feature)) == binding.interfaceDigest
        }
        let candidates = developerRunnerStore.runners.filter { runner in
            guard runner.state == .connected,
                  runner.identity.appBundleIdentifier == definition.target.bundleIdentifier,
                  runner.identity.buildProvenance?.buildID == appDigest else { return false }
            return runner.features.contains(where: matches)
        }
        let selectedID = frozenRunnerID ?? ScenarioRunnerSelection.chosenID(
            candidateIDs: candidates.map(\.id), selectedID: developerRunnerStore.selectedRunnerID
        )
        let matchingRunners = candidates.filter { $0.id == selectedID }
        guard matchingRunners.count == 1,
              let runner = matchingRunners.first,
              let feature = runner.features.first(where: matches) else {
            throw ScenarioPersistenceError.invalidRun(
                candidates.isEmpty
                    ? "No connected runner matches this feature, checked app build, and interface. Rebuild, reconnect, then check support."
                    : "Select one connected runner for this checked app and feature."
            )
        }
        return (runner, feature)
    }

    private func executeStable(
        plan: ScenarioExecutionPlan, definition: ScenarioDefinition,
        configuration runConfiguration: XcodeTestConfiguration, trusted: Bool,
        connection: ScenarioVerifiedConnection, ownerID: UUID
    ) async -> ScenarioExecutionRecord? {
        var records = plan.coordinates.map(ScenarioExecutionCoordinateRecord.unstarted)
        do {
            try verify(plan: plan, definition: definition, connection: connection,
                       configuration: runConfiguration)
            try await persistence.saveDefinition(definition)
            try await persistence.savePlan(plan)
            if !definitions.contains(where: { $0.id == definition.id && $0.version == definition.version }) {
                definitions.append(definition)
            }
            executionPlans.removeAll { $0.id == plan.id }
            executionPlans.insert(plan, at: 0)
            selectedExecutionID = plan.id
            try await checkpoint(plan: plan, records: records)
            for coordinate in plan.coordinates {
                guard !cancellationRequested else { break }
                guard let index = records.firstIndex(where: { $0.id == coordinate.id }) else { continue }
                records[index].state = .recoveryRequired
                records[index].detail = "Execution started; evidence has not been committed."
                let featureRunID = coordinate.lane == .appFeature ? UUID() : nil
                if let featureRunID { records[index].evidenceRunID = featureRunID }
                try await checkpoint(plan: plan, records: records)
                do {
                    if coordinate.lane == .appFeature {
                        records[index] = try await runFeatureChild(
                            coordinate: coordinate, plan: plan, definition: definition,
                            ownerID: ownerID, runID: featureRunID!
                        )
                    } else {
                        records[index] = try await runNativeChild(
                            coordinate: coordinate, plan: plan, definition: definition,
                            configuration: runConfiguration, trusted: trusted
                        )
                    }
                    try await checkpoint(plan: plan, records: records)
                    if records[index].state == .failedToExecute { break }
                } catch {
                    records[index].state = cancellationRequested ? .cancelled : .recoveryRequired
                    records[index].detail = error.localizedDescription
                    try? await checkpoint(plan: plan, records: records)
                    notice = "The \(coordinate.lane.rawValue) attempt needs review: \(error.localizedDescription)"
                    // A failed or uncertain action must not be repeated in this plan.
                    break
                }
            }
            if cancellationRequested {
                for index in records.indices where records[index].state == .notRun {
                    records[index].state = .cancelled
                    records[index].detail = "Cancelled before dispatch."
                }
            }
            let record = try ScenarioExecutionRecord.make(plan: plan, records: records)
            finalEvidenceCommitStarted = true
            try await persistence.saveExecutionRecord(record)
            executionRecords.removeAll { $0.id == record.id }
            executionRecords.insert(record, at: 0)
            selectedExecutionID = record.id
            notice = "Execution recorded: \(record.passingCount)/\(record.plannedCount) attempts passed; \(record.aggregateOutcome.rawValue)."
            return record
        } catch {
            notice = "The execution could not be completed: \(error.localizedDescription)"
            return nil
        }
    }

    private func checkpoint(plan: ScenarioExecutionPlan,
                            records: [ScenarioExecutionCoordinateRecord]) async throws {
        try await persistence.saveProgress(.init(planID: plan.id, records: records, updatedAt: Date()))
    }

    private func runFeatureChild(
        coordinate: ScenarioPlannedCoordinate, plan: ScenarioExecutionPlan,
        definition: ScenarioDefinition, ownerID: UUID, runID: UUID,
        resumeRun: EvaluationRun? = nil
    ) async throws -> ScenarioExecutionCoordinateRecord {
        guard let projectID = definition.projectID,
              let binding = definition.featureBinding else {
            throw ScenarioPersistenceError.invalidRun("The planned feature project or binding is unavailable.")
        }
        var suite = EvaluationSuite()
        let identity = ScenarioFeatureSuiteIdentity(definition: definition)
        suite.id = identity.id
        suite.name = identity.suiteName
        suite.version = "contract:\(plan.testContractDigest)"
        suite.instructions = "Execute the declared App Feature subject input."
        suite.criteria = "Observed App Feature output is assessed by the frozen Intent Lab assertions."
        suite.scoringMode = .review
        suite.repetitions = 1
        suite.cases = [.init(id: definition.id, name: identity.caseName,
                             prompt: definition.goal.requestText, expected: "")]
        let run: EvaluationRun
        if let resumeRun {
            run = resumeRun
        } else {
            guard let selected = try selectedSubjectRunner(
                for: definition, appDigest: plan.appProductDigest,
                frozenRunnerID: plan.runnerID
            ), selected.runner.id == plan.runnerID,
               selected.runner.identity.buildProvenance?.buildID == plan.runnerBuildID,
               let developerRunnerStore else {
                throw ScenarioPersistenceError.invalidRun("The planned feature runner changed. Reconnect and start a new run.")
            }
            let revision = try evaluationStore.ensureScenarioFeatureSuite(
                projectID: projectID, suite: suite, executionOwnerID: ownerID
            )
            activeFeatureRunID = runID
            defer { activeFeatureRunID = nil }
            let adapter = ScenarioSubjectFeatureAdapter(
                runID: runID, caseID: definition.id, runner: selected.runner,
                feature: selected.feature, binding: binding, fixture: definition.fixture,
                attemptIDs: [coordinate.repetition: coordinate.id],
                client: developerRunnerStore.client,
                timeout: .seconds(definition.safety.deadlineSeconds)
            )
            do {
                run = try await developerRunnerStore.runFeatureSnapshot(
                    id: runID, projectID: projectID, suite: suite, expectedRevision: revision,
                    runnerID: selected.runner.id, featureID: selected.feature.id,
                    executionOwnerID: ownerID, adapter: adapter
                )
            } catch {
                // Retry only the history write for an already completed action.
                guard let saved = try? evaluationStore.retrySnapshotRunSave(
                    id: runID, projectID: projectID, suiteID: suite.id
                ) else { throw error }
                run = saved
            }
        }
        guard run.id == runID, run.projectID == projectID, run.results.count == 1,
              let sample = run.results.first, sample.caseID == coordinate.caseID,
              sample.repetition == coordinate.repetition,
              run.developerExecution?.runnerID == plan.runnerID,
              run.developerExecution?.appBundleIdentifier == definition.target.bundleIdentifier,
              run.developerExecution?.featureID == binding.featureID else {
            throw ScenarioPersistenceError.invalidRun("The feature sample did not match its planned case and attempt.")
        }
        let metadata = sample.structuredFeatureEvidence?.metadata ?? [:]
        let expectedSubjectDigest = try ScenarioSubjectFeatureAdapter.subjectInputDigest(
            binding: binding, fixture: definition.fixture
        )
        let subjectMatched = metadata["intentlab.subjectInputDigest"] == expectedSubjectDigest
        let observedFixture = metadata["intentlab.fixtureDigest"] ?? metadata["sourceContentDigest"]
        let fixtureReceipt = ScenarioFixtureReceipt(
            observed: observedFixture, expected: plan.fixtureContractDigest
        )
        var observations: [String: ScenarioValue] = [
            "feature.response": .string(sample.response),
            "feature.runID": .string(run.id.uuidString),
            "feature.sampleID": .string(sample.id.uuidString),
            "feature.resultCount": .integer(1)
        ]
        for (key, value) in metadata {
            observations["feature.metadata.\(key)"] = .string(value)
        }
        observations.merge(ScenarioObservedFeatureOutput.project(
            sample.structuredFeatureEvidence?.encodedValue,
            fields: binding.outputProjections
        )) { _, observed in observed }
        let status: ScenarioExecutionStatus = run.cancelled ? .cancelled
            : (run.terminationReason == nil && sample.status != .error
               && sample.errorCategory == nil && sample.errorMessage == nil
               && fixtureReceipt != .missing && subjectMatched ? .completed : .invalidEvidence)
        let assessment = ScenarioResultEvaluator.evaluate(
            definition: definition, lane: .appFeature,
            observations: observations, executionStatus: status
        )
        let lane = ScenarioLaneResult(
            caseID: coordinate.caseID, attempt: coordinate.repetition,
            lane: .appFeature, executionStatus: status,
            outcome: status == .completed
                ? fixtureReceipt.outcome(after: assessment.0) : .notObserved,
            startedAt: run.startedAt, completedAt: run.completedAt,
            observations: observations, assertionResults: assessment.1,
            diagnostic: !subjectMatched
                ? "The feature result did not bind to the planned typed subject input."
                : (observedFixture == nil
                ? "The app did not report an observed fixture content digest."
                : (fixtureReceipt == .wrongSource ? "The app used different source content than the planned fixture."
                : (sample.errorMessage ?? run.terminationReason))),
            artifacts: [], observationSources: ["feature.response": .applicationInstrumentation]
        )
        let child = try ScenarioFeatureChildEvidence(
            runID: run.id, sampleID: sample.id, startedAt: run.startedAt,
            completedAt: run.completedAt, caseID: sample.caseID,
            attempt: sample.repetition, response: sample.response,
            encodedOutput: sample.structuredFeatureEvidence?.encodedValue,
            encodedOutputTypeName: sample.structuredFeatureEvidence?.encodedValueTypeName,
            outputMetadata: metadata, errorCategory: sample.errorCategory,
            errorMessage: sample.errorMessage,
            appBundleIdentifier: run.developerExecution?.appBundleIdentifier ?? "",
            featureID: run.developerExecution?.featureID ?? "",
            featureVersion: run.developerExecution?.featureVersion ?? "",
            checkedAppProductDigest: plan.appProductDigest,
            runnerBuildID: plan.runnerBuildID ?? "",
            fixtureContractDigest: plan.fixtureContractDigest,
            subjectInputDigest: expectedSubjectDigest, digest: "",
            measurementImplementation: resumeRun == nil
                ? Self.featureMeasurementImplementation() : nil
        ).sealed()
        return .init(coordinate: coordinate,
                     state: status == .completed ? .completed : .failedToExecute,
                     evidenceRunID: run.id, evidenceLaneResultID: lane.id,
                     detail: lane.diagnostic, laneResult: lane,
                     evidenceDigest: child.digest, featureChild: child)
    }

    private static func featureMeasurementImplementation(
        hostBundle: Bundle = .main
    ) -> ScenarioMeasurementImplementation? {
        guard hostBundle.bundleIdentifier == "com.coryparry.FoundationEvals",
              let executable = hostBundle.executableURL,
              let bytes = try? Data(contentsOf: executable, options: [.mappedIfSafe]),
              !bytes.isEmpty else { return nil }
        let hostDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(
            observerID: "feature-host-projection:com.coryparry.FoundationEvals",
            observerDigest: hostDigest,
            evaluatorID: "host-executable:com.coryparry.FoundationEvals:\(executable.lastPathComponent)",
            evaluatorDigest: hostDigest
        )
    }

    private func runNativeChild(
        coordinate: ScenarioPlannedCoordinate, plan: ScenarioExecutionPlan,
        definition: ScenarioDefinition, configuration runConfiguration: XcodeTestConfiguration,
        trusted: Bool
    ) async throws -> ScenarioExecutionCoordinateRecord {
        let scope = ScenarioNativeExecutionScope(lane: coordinate.lane,
                                                 attempt: coordinate.repetition)
        guard scope.isValid(for: definition) else {
            throw ScenarioPersistenceError.invalidRun("The planned native route is unsupported.")
        }
        let task = Task {
            try Task.checkCancellation()
            return try await executor.execute(
                definition: definition, configuration: runConfiguration,
                projectTrusted: trusted, linkedFeatureEvidenceAvailable: true,
                scope: scope
            )
        }
        executionTask = task
        let result = try await task.value
        defer { executionTask = nil }
        guard result.reportedTestCount == 1 else {
            try? await executor.finishEvidenceValidation(journal: result.journal, accepted: false)
            throw ScenarioEvidenceImportError.invalidTestCount
        }
        let finals = result.evidenceAttachments.filter { !$0.isCheckpoint }
        let selectedAttachments = finals.isEmpty
            ? result.evidenceAttachments.filter(\.isCheckpoint) : finals
        guard selectedAttachments.count == 1, let attachment = selectedAttachments.first else {
            try? await executor.finishEvidenceValidation(journal: result.journal, accepted: false)
            throw ScenarioPersistenceError.invalidRun("The route did not produce one final evidence envelope.")
        }
        var stagedLedger = ledger
        var run: ScenarioRun
        do {
            run = try XCTestEvidenceImporter().importEvidence(
                data: Data(contentsOf: attachment.url), definition: definition,
                journal: result.journal, artifactRoot: result.attachmentDirectory,
                ledger: &stagedLedger, statedChangedDimensions: statedChangedDimensions,
                scope: scope, measurementImplementation: result.measurementImplementation
            )
        } catch {
            try? await executor.finishEvidenceValidation(journal: result.journal, accepted: false)
            throw error
        }
        guard run.laneResults.count == 1,
              let lane = run.laneResults.first,
              lane.caseID == coordinate.caseID,
              lane.lane == coordinate.lane,
              lane.attempt == coordinate.repetition else {
            try? await executor.finishEvidenceValidation(journal: result.journal, accepted: false)
            throw ScenarioPersistenceError.invalidRun("The imported lane did not match its planned attempt.")
        }
        run.xctestExitCode = result.processExitCode
        run.comparisonEnvironmentIdentity = try ScenarioExecutionEnvironmentIdentity.derive(
            environment: run.environment,
            destinationIdentifier: plan.profile.destinationIdentifier,
            lane: coordinate.lane
        )
        if result.processExitCode != 0 {
            run.executionStatus = .invalidEvidence
            run.outcome = .needsReview
            run.laneResults[0].executionStatus = .invalidEvidence
            run.laneResults[0].outcome = .notObserved
            if attachment.isCheckpoint, let failure = result.testFailureMessages.first {
                run.laneResults[0].diagnostic = ScenarioDiagnosticClassifier.checkpointDiagnostic(for: failure)
            }
        }
        let observedFixture = run.laneResults[0].observations["intentlab.fixtureDigest"]
            ?? run.laneResults[0].observations["summarySourceContentDigest"]
        let receipt = ScenarioFixtureReceipt(
            observed: observedFixture.flatMap { value in
                guard case .string(let text) = value else { return nil }
                return text
            }, expected: plan.fixtureContractDigest
        )
        if receipt == .missing {
            run.executionStatus = .invalidEvidence
            run.outcome = .needsReview
            run.laneResults[0].executionStatus = .invalidEvidence
            run.laneResults[0].outcome = .notObserved
            run.laneResults[0].diagnostic = "The app did not expose an observed fixture content digest for this route."
        } else if receipt == .wrongSource {
            // A wrong source is a failed business observation, not a corrupt
            // envelope. Preserve the actual summary and route evidence.
            run.laneResults[0].outcome = .failed
            run.laneResults[0].diagnostic = "The app used different source content than the planned fixture."
        }
        do {
            try await persistence.savePendingNativeSave(.init(
                planID: plan.id, coordinateID: coordinate.id, run: run,
                artifactRootPath: result.attachmentDirectory.path, ledger: stagedLedger
            ))
        } catch {
            try? await executor.finishEvidenceValidation(journal: result.journal, accepted: false)
            throw error
        }
        // The raw route result and its artifacts are committed before the
        // coordinate can move out of recoveryRequired.
        let saved: ScenarioRun
        do {
            saved = try await persistence.saveRun(run, artifactRoot: result.attachmentDirectory)
            try await persistence.saveLedger(stagedLedger)
            ledger = stagedLedger
        } catch {
            try? await executor.finishEvidenceValidation(journal: result.journal, accepted: false)
            throw error
        }
        let accepted = !cancellationRequested && Self.canReleaseDevice(
            processExitCode: result.processExitCode,
            attachments: [attachment], importedRuns: [saved]
        )
        try await executor.finishEvidenceValidation(journal: result.journal, accepted: accepted)
        try await persistence.clearPendingNativeSave(planID: plan.id, coordinateID: coordinate.id)
        recoveryJournals = try await executor.currentRecoveryJournals()
        journals = try await persistence.loadJournals()
        runs.insert(saved, at: 0)
        let child = saved.laneResults[0]
        return .init(
            coordinate: coordinate,
            state: child.executionStatus == .completed ? .completed : .failedToExecute,
            evidenceRunID: saved.id, evidenceLaneResultID: child.id,
            detail: child.diagnostic, laneResult: child,
            evidenceDigest: try Self.evidenceDigest(saved)
        )
    }

    private static func evidenceDigest(_ run: ScenarioRun) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return SHA256.hash(data: try encoder.encode(run))
            .map { String(format: "%02x", $0) }.joined()
    }

    func cancel() async {
        if finalEvidenceCommitStarted {
            notice = "The device test has finished and its evidence is being saved; cancellation can no longer stop this run."
            return
        }
        if isRunning { cancellationRequested = true }
        if let activeFeatureRunID { developerRunnerStore?.cancelRun(activeFeatureRunID) }
        executionTask?.cancel()
        if let journal = await executor.cancelActiveExecution() {
            recoveryJournals.removeAll { $0.id == journal.id }
            recoveryJournals.append(journal)
            journals.removeAll { $0.id == journal.id }
            journals.append(journal)
            notice = "Cancellation requested. The device is quarantined until test termination and fixture readiness are proven."
        } else {
            notice = "Cancellation requested before the device test started."
        }
        await refreshPreflight()
    }

    static func canReleaseDevice(
        processExitCode: Int32,
        attachments: [ScenarioEvidenceAttachment],
        importedRuns: [ScenarioRun]
    ) -> Bool {
        processExitCode == 0 &&
        !attachments.isEmpty && attachments.allSatisfy { !$0.isCheckpoint } &&
        !importedRuns.isEmpty && importedRuns.allSatisfy { run in
            run.executionStatus == .completed &&
            run.laneResults.allSatisfy { lane in
                lane.executionStatus == .completed &&
                (lane.lane != .siri || (lane.outcome != .notObserved && lane.outcome != .needsReview))
            }
        }
    }

    static func evidenceForCommit(_ runs: [ScenarioRun], cancelled: Bool) -> [ScenarioRun] {
        guard cancelled else { return runs }
        return runs.map { run in
            var invalid = run
            invalid.executionStatus = .invalidEvidence
            invalid.outcome = .needsReview
            return invalid
        }
    }

    func clearDeviceQuarantine(fixtureReadinessProven: Bool) async {
        do {
            try await executor.clearQuarantine(
                destinationIdentifier: configuration.destinationIdentifier,
                fixtureReadinessProven: fixtureReadinessProven
            )
            recoveryJournals.removeAll { $0.invocation.destinationIdentifier == configuration.destinationIdentifier }
            journals = try await persistence.loadJournals()
            await refreshPreflight()
        } catch {
            notice = error.localizedDescription
        }
    }

    func generateSuggestions() async {
        guard !isGeneratingSuggestions else { return }
        isGeneratingSuggestions = true
        defer { isGeneratingSuggestions = false }
        do {
            let frozen = try draft.frozen()
            suggestions = try await ScenarioSuggestionService.generate(for: frozen)
        } catch {
            notice = error.localizedDescription
        }
    }

    func approveSuggestion(id: UUID) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        suggestions[index].approved = true
        approveSuggestion(suggestions[index])
    }

    func approveSuggestion(_ suggestion: ScenarioRequestSuggestion) {
        if definitions.contains(where: { $0.id == draft.id && $0.version == draft.version }) {
            duplicateAsNewVersion()
        } else {
            draft.definitionDigest = ""
        }
        draft.goal.requestText = suggestion.requestText
    }

    func releaseReport(for run: ScenarioRun?) -> ScenarioReleaseCheckReport {
        let definition = run.flatMap { definition(for: $0) } ?? draft
        return ScenarioReleaseCheckEvaluator.report(
            definition: definition,
            run: run,
            comparison: run.flatMap(comparison(for:)),
            journalAccepted: run.map { ScenarioReleaseCheckEvaluator.acceptedJournal(for: $0, in: journals) }
        )
    }

    private func applyConfigurationToDraft() {
        if draft.schemaVersion == ScenarioDefinition.stableSchemaVersion { return }
        draft.target.projectPath = configuration.containerPath
        draft.target.scheme = configuration.scheme
        draft.target.testTarget = configuration.testTarget
        draft.target.destinationIdentifier = configuration.destinationIdentifier
        draft.definitionDigest = ""
    }

    private func applyTargetToConfiguration(_ target: ScenarioTarget) {
        configuration.containerPath = target.projectPath
        configuration.isWorkspace = target.projectPath.hasSuffix(".xcworkspace")
        configuration.scheme = target.scheme
        configuration.testTarget = target.testTarget
        configuration.destinationIdentifier = target.destinationIdentifier
    }

    private func testActionConfiguration(for discovery: XcodeConnectionDiscovery?) throws -> String {
        guard let discovery, !configuration.scheme.isEmpty else { return "Debug" }
        let selectedProjectPath = discovery.applications.first {
            $0.id == configuration.selectedApplicationProductID
        }?.projectPath
        return try XcodeConnectionDiscoveryService.testActionBuildConfiguration(
            container: URL(filePath: configuration.containerPath),
            scheme: configuration.scheme,
            preferredProjectPath: selectedProjectPath
        ) ?? "Debug"
    }

    private func apply(discovery: XcodeConnectionDiscovery) {
        if !discovery.schemes.contains(configuration.scheme) {
            configuration.scheme = discovery.automaticallySelectedScheme ?? ""
        }
        if discovery.applications.count == 1, let application = discovery.applications.first {
            selectApplication(application)
        } else if let application = discovery.applications.first(where: {
            $0.id == configuration.selectedApplicationProductID
        }) {
            configuration.applicationSigningConfigured = application.signingConfigured
        } else if !discovery.applications.contains(where: { $0.id == configuration.selectedApplicationProductID }) {
            draft.target.bundleIdentifier = ""
            draft.definitionDigest = ""
            configuration.applicationSigningConfigured = nil
            configuration.selectedApplicationProductID = nil
        }
        if discovery.uiTestBundles.count == 1, let tests = discovery.uiTestBundles.first {
            selectUITestBundle(tests)
        } else if let tests = discovery.uiTestBundles.first(where: {
            $0.id == configuration.selectedTestProductID
        }) {
            configuration.testSigningConfigured = tests.signingConfigured
        } else if !discovery.uiTestBundles.contains(where: { $0.id == configuration.selectedTestProductID }) {
            configuration.testTarget = ""
            configuration.selectedTestProductID = nil
            configuration.testBundleIdentifier = ""
            configuration.harnessVersion = nil
            configuration.harnessCapabilities = nil
            configuration.testSigningConfigured = nil
        }
    }

    private func linkedFeatureRun(for definition: ScenarioDefinition) -> EvaluationRun? {
        guard let run = definition.directControl.linkedFeatureRunID.flatMap(evaluationStore.run(with:)),
              ScenarioFeatureEvidence.isEligible(run, for: definition) else { return nil }
        return run
    }
}
