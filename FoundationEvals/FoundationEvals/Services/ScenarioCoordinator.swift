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
    /// Explicit route choice for new stable plans. The plan freezes its value;
    /// selecting or rerunning older evidence reads that plan, not this control.
    var featureBackend: ScenarioFeatureBackend = .projectLocalTestControl {
        didSet {
            if oldValue != featureBackend { invalidatePreflight() }
        }
    }
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
    private(set) var routeReadiness: [ScenarioLane: ScenarioRouteReadiness] = [:]
    private(set) var isRunning = false
    private(set) var executionStage: String?
    private(set) var isGeneratingSuggestions = false
    private(set) var suggestions: [ScenarioRequestSuggestion] = []
    private(set) var recoveryJournals: [ScenarioExecutionJournal] = []
    private(set) var journals: [ScenarioExecutionJournal] = []
    private(set) var pendingOrdinarySaves: [ScenarioPendingOrdinarySave] = []
    private(set) var hasLoaded = false
    var notice: String?

    private let persistence: ScenarioPersistence
    private let collectionStore: ScenarioCollectionStore
    private let assessmentStore: ScenarioAssessmentStore
    private let executor: XcodeTestExecutor
    private let rootDirectory: URL
    private let evaluationStore: EvaluationStore
    private let executionAdmission: ScenarioExecutionAdmission
    @ObservationIgnored private weak var developerRunnerStore: DeveloperRunnerStore?
    private var ledger = ScenarioImportLedger()
    private var preflightRevision = 0
    private var cancellationRequested = false
    private var finalEvidenceCommitStarted = false
    private var executionTask: Task<ScenarioExecutorResult, Error>?
    private var activeFeatureRunID: UUID?
    @ObservationIgnored private var scopedProjectURL: URL?

    init(supportDirectory: URL, evaluationStore: EvaluationStore,
         initialConnectionDiscovery: XcodeConnectionDiscovery? = nil,
         executionAdmission: ScenarioExecutionAdmission = .shared) {
        let root = supportDirectory.appending(path: "IntentLab", directoryHint: .isDirectory)
        rootDirectory = root
        let persistence = ScenarioPersistence(rootDirectory: root)
        self.persistence = persistence
        collectionStore = ScenarioCollectionStore(rootDirectory: root)
        assessmentStore = ScenarioAssessmentStore(directory: root.appending(path: "Assessments"))
        self.evaluationStore = evaluationStore
        self.executionAdmission = executionAdmission
        connectionDiscovery = initialConnectionDiscovery
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
            result: batchResults.first { $0.manifestID == manifest.id },
            runs: runs, journals: journals
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
        try executionAdmission.acquire(id)
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
            pendingOrdinarySaves = try await persistence.loadPendingOrdinarySaves()
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
                selectedIntegration = definition.schemaVersion >= ScenarioDefinition.reusableSchemaVersion
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
            if !pendingOrdinarySaves.isEmpty {
                notice = "A completed device run has evidence waiting for a save-only retry."
            } else if !recoveryJournals.isEmpty {
                notice = "A previous device test ended without proven cleanup. Its destination is quarantined until termination and fixture readiness are confirmed."
            }
            hasLoaded = true
            await refreshDevices()
        } catch {
            notice = "Intent Lab storage could not be loaded: \(error.localizedDescription)"
        }
    }

    func selectSavedDefinition(id: UUID, version: Int) async {
        guard !isRunning else {
            notice = "Wait for the current test to finish before switching saved tests."
            return
        }
        guard let definition = definitions.first(where: { $0.id == id && $0.version == version }) else {
            notice = "The saved test could not be found."
            return
        }

        let target = definition.target
        let currentContainer = URL(filePath: configuration.containerPath).standardizedFileURL.path
        let targetContainer = URL(filePath: target.projectPath).standardizedFileURL.path
        let projectChanged = currentContainer != targetContainer
        let targetChanged = projectChanged
            || draft.target.bundleIdentifier != target.bundleIdentifier
            || draft.target.scheme != target.scheme
            || draft.target.testTarget != target.testTarget
            || configuration.scheme != target.scheme
            || configuration.testTarget != target.testTarget

        if projectChanged {
            selectContainer(URL(filePath: target.projectPath))
        } else if targetChanged {
            clearSelectedProductConfiguration()
            declarationCatalog = nil
        }

        draft = definition
        selectedIntegration = definition.schemaVersion >= ScenarioDefinition.reusableSchemaVersion
            ? definition.integration : nil
        parameterArrayDraftTexts = [:]
        invalidParameterDraftIndices = []
        selectedRunID = nil
        applyTargetToConfiguration(target)

        if targetChanged && !projectChanged {
            let applications = connectionDiscovery?.applications.filter {
                $0.bundleIdentifier == target.bundleIdentifier
            } ?? []
            let testBundles = connectionDiscovery?.uiTestBundles.filter {
                $0.targetName == target.testTarget
            } ?? []
            if let discovery = connectionDiscovery,
               discovery.schemes.contains(target.scheme),
               applications.count == 1, testBundles.count == 1,
               let application = applications.first, let tests = testBundles.first {
                configuration.selectedApplicationProductID = application.id
                configuration.applicationSigningConfigured = application.signingConfigured
                configuration.selectedTestProductID = tests.id
                configuration.testBundleIdentifier = tests.bundleIdentifier
                configuration.harnessVersion = tests.harnessVersion
                configuration.harnessCapabilities = tests.harnessCapabilities
                configuration.testSigningConfigured = tests.signingConfigured
            } else {
                projectTrusted = false
                notice = "The saved test uses a different app or test target. Connect this project again to check its build."
            }
        }

        let selectedProductsMatch = connectionDiscovery.map { discovery in
            discovery.applications.contains {
                $0.id == configuration.selectedApplicationProductID
                    && $0.bundleIdentifier == target.bundleIdentifier
            } && discovery.uiTestBundles.contains {
                $0.id == configuration.selectedTestProductID
                    && $0.targetName == target.testTarget
                    && $0.bundleIdentifier == configuration.testBundleIdentifier
            }
        } ?? false
        if !selectedProductsMatch {
            clearSelectedProductConfiguration()
            if !projectChanged && targetChanged { projectTrusted = false }
        }
        invalidatePreflight()

        do {
            try await persistence.saveSelectedDefinition(id: id, version: version)
            try await persistence.saveExecutionConfiguration(configuration)
        } catch {
            notice = "The saved test is open, but its selection could not be saved: \(error.localizedDescription)"
        }
        if projectTrusted { await refreshPreflight() }
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

    private func clearSelectedProductConfiguration() {
        configuration.selectedApplicationProductID = nil
        configuration.selectedTestProductID = nil
        configuration.testBundleIdentifier = ""
        configuration.harnessVersion = nil
        configuration.harnessCapabilities = nil
        configuration.applicationSigningConfigured = nil
        configuration.testSigningConfigured = nil
    }

    func refreshDevices() async {
        do {
            let service = XcodeConnectionDiscoveryService(
                xcodebuildPath: configuration.xcodebuildPath,
                xcdevicePath: "/usr/bin/xcrun"
            )
            let devices = try await Task.detached {
                try service.discoverDevices()
            }.value
            discoveredDevices = devices
            if let destinationIdentifier = Self.soleAvailableDestinationIdentifier(
                in: devices,
                savedDestinationIdentifier: configuration.destinationIdentifier
            ) {
                await selectDevice(destinationIdentifier)
            } else {
                await selectDevice(configuration.destinationIdentifier)
            }
        } catch {
            discoveredDevices = []
            configuration.destinationPlatform = nil
            invalidatePreflight()
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
            declarationCatalog = nil
            if draft.schemaVersion >= ScenarioDefinition.reusableSchemaVersion {
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
        let checkedDraft = draft
        let checkedConfiguration = configuration
        do {
            let definition = try draft.frozen()
            let verified = try await executor.verifyConnection(
                definition: definition,
                configuration: configuration,
                projectTrusted: projectTrusted
            )
            guard draft == checkedDraft, configuration == checkedConfiguration else {
                declarationCatalog = nil
                verifiedIntegrationSummary = nil
                notice = "The test or connection changed while support was being checked. Check support again."
                invalidatePreflight()
                return
            }
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
            await refreshPreflight()
        }
    }

    func selectDevice(_ identifier: String) async {
        let platform = Self.availablePlatform(for: identifier, in: discoveredDevices)
        guard configuration.destinationIdentifier != identifier
                || configuration.destinationPlatform != platform else { return }
        configuration.destinationIdentifier = identifier
        configuration.destinationPlatform = platform
        invalidatePreflight()
        try? await persistence.saveExecutionConfiguration(configuration)
        if projectTrusted { await refreshPreflight() }
    }

    static func availablePlatform(
        for identifier: String, in devices: [IntentLabDeviceDestination]
    ) -> IntentLabDestinationPlatform? {
        devices.first { $0.identifier == identifier && $0.available }?.platform
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
        let selectedApp = Self.selectedReusableApplication(
            in: connectionDiscovery,
            selectedProductID: configuration.selectedApplicationProductID
        )
        let targetBundleIdentifier: String
        if let selectedApp {
            configuration.selectedApplicationProductID = selectedApp.id
            configuration.applicationSigningConfigured = selectedApp.signingConfigured
            targetBundleIdentifier = selectedApp.bundleIdentifier
        } else if connectionDiscovery != nil {
            // Discovery exists, so an old bundle ID is not enough to identify one
            // product when this project has multiple app targets.
            configuration.selectedApplicationProductID = nil
            configuration.applicationSigningConfigured = nil
            targetBundleIdentifier = ""
        } else {
            // Keep a saved target while discovery is not available yet. A newly
            // selected project clears its product identity in selectContainer.
            targetBundleIdentifier = draft.target.bundleIdentifier
        }
        draft = .reusable(
            name: "New intent check",
            target: .init(
                bundleIdentifier: targetBundleIdentifier,
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

    static func selectedReusableApplication(
        in discovery: XcodeConnectionDiscovery?,
        selectedProductID: String?
    ) -> XcodeDiscoveredProduct? {
        guard let discovery else { return nil }
        if let selectedProductID,
           let selected = discovery.applications.first(where: { $0.id == selectedProductID }) {
            return selected
        }
        guard discovery.applications.count == 1 else { return nil }
        return discovery.applications.first
    }

    static func soleAvailableDestinationIdentifier(
        in devices: [IntentLabDeviceDestination],
        savedDestinationIdentifier: String
    ) -> String? {
        guard savedDestinationIdentifier.isEmpty else { return nil }
        let available = devices.filter(\.available)
        guard available.count == 1 else { return nil }
        return available[0].identifier
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
            if draft.schemaVersion == ScenarioDefinition.stableSchemaVersion {
                draft = try ScenarioExpectationAuthoring.withDeclaredIntentActionRequirements(
                    draft, catalog: declarationCatalog
                )
            }
            invalidatePreflight()
        } catch { notice = error.localizedDescription }
    }

    /// Call after a typed parameter edit. This is an authoring operation; saved
    /// plans and reruns continue to use their previously frozen requirements.
    func synchronizeDeclaredActionRequirements() {
        guard draft.schemaVersion == ScenarioDefinition.stableSchemaVersion,
              let declarationCatalog else { return }
        do {
            draft = try ScenarioExpectationAuthoring.withDeclaredIntentActionRequirements(
                draft, catalog: declarationCatalog
            )
            invalidatePreflight()
        } catch { notice = error.localizedDescription }
    }

    func selectLocalFeatureControl(
        featureID: String,
        operationID: String,
        inputMapping: [ScenarioFeatureInputMapping]
    ) {
        guard let declarationCatalog else {
            notice = "Rebuild and check support to load the app's local Feature controls."
            return
        }
        do {
            draft = try ScenarioExpectationAuthoring.selectingLocalFeatureControl(
                featureID: featureID, operationID: operationID,
                inputMapping: inputMapping, in: draft, catalog: declarationCatalog
            )
            featureBackend = .projectLocalTestControl
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
        let products = Self.installedProducts(
            in: connectionDiscovery,
            appBundleID: appBundleID,
            applicationProductID: applicationProductID,
            testTarget: testTarget,
            testProductID: testProductID
        )
        if configuration.scheme != scheme || configuration.testTarget != testTarget
            || configuration.selectedApplicationProductID != applicationProductID
            || configuration.selectedTestProductID != testProductID
            || draft.target.projectPath != projectPath || draft.target.bundleIdentifier != appBundleID {
            projectTrusted = false
        }
        selectedIntegration = identity
        declarationCatalog = nil
        configuration.selectedApplicationProductID = applicationProductID
        configuration.selectedTestProductID = testProductID
        configuration.testTarget = testTarget
        configuration.scheme = scheme
        configuration.applicationSigningConfigured = products.application?.signingConfigured
        configuration.testBundleIdentifier = products.tests?.bundleIdentifier ?? ""
        configuration.harnessVersion = products.tests?.harnessVersion
        configuration.harnessCapabilities = products.tests?.harnessCapabilities
        configuration.testSigningConfigured = products.tests?.signingConfigured
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

    static func installedProducts(
        in discovery: XcodeConnectionDiscovery?, appBundleID: String,
        applicationProductID: String?, testTarget: String, testProductID: String?
    ) -> (application: XcodeDiscoveredProduct?, tests: XcodeDiscoveredProduct?) {
        guard let discovery else { return (nil, nil) }
        let application = discovery.applications.first {
            $0.id == applicationProductID && $0.bundleIdentifier == appBundleID
        }
        let tests = discovery.uiTestBundles.first {
            $0.id == testProductID && $0.targetName == testTarget
        }
        return (application, tests)
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
        routeReadiness = [:]
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
        let checkedFeatureBackend = featureBackend
        let report = await executor.preflight(
            definition: frozen,
            configuration: checkedConfiguration,
            projectTrusted: checkedProjectTrusted,
            linkedFeatureEvidenceAvailable: checkedFeatureBackend == .projectLocalTestControl
                || linkedFeatureRun(for: frozen) != nil,
            featureBackend: checkedFeatureBackend
        )
        var routes = await executor.routeReadiness(
            definition: frozen, configuration: checkedConfiguration,
            projectTrusted: checkedProjectTrusted, featureBackend: checkedFeatureBackend
        )
        if checkedFeatureBackend == .connectedRunner {
            let connection = await executor.currentConnection(
                definition: frozen, configuration: checkedConfiguration
            )
            Self.applyConnectedFeatureReadiness(
                to: &routes, definition: frozen, appDigest: connection?.appProduct.sha256,
                runnerCheck: { _ = try selectedSubjectRunner(for: frozen, appDigest: $0) }
            )
        }
        guard revision == preflightRevision,
              configuration == checkedConfiguration,
              projectTrusted == checkedProjectTrusted,
              featureBackend == checkedFeatureBackend,
              draft == frozen,
              invalidParameterDraftIndices.isEmpty else { return }
        preflight = report
        routeReadiness = routes
    }

    /// Runs selected routes as a new, explicitly partial diagnostic. It keeps
    /// the frozen requirement unchanged and cannot qualify complete coverage.
    func checkThisFix(on selectedLanes: Set<ScenarioLane>) async {
        guard hasLoaded, !isRunning else {
            notice = "Load Intent Lab and finish the current run before checking a fix."
            return
        }
        guard draft.schemaVersion == ScenarioDefinition.stableSchemaVersion,
              !selectedLanes.isEmpty,
              selectedLanes.allSatisfy({ draft.coverage[$0] != .notApplicable }) else {
            notice = "Select at least one requested route for this diagnostic check."
            return
        }
        let ownerID = UUID()
        do { try acquireExecutionOwner(ownerID) }
        catch { notice = error.localizedDescription; return }
        isRunning = true
        executionStage = "Checking environment"
        cancellationRequested = false
        finalEvidenceCommitStarted = false
        defer {
            executionAdmission.release(ownerID)
            isRunning = false
            executionStage = nil
            finalEvidenceCommitStarted = false
            executionTask = nil
        }
        await runStableExecution(
            ownerID: ownerID, runConfiguration: configuration,
            runTrusted: projectTrusted, backend: featureBackend,
            purpose: .partialDiagnostic, selectedLanes: selectedLanes
        )
        await refreshPreflight()
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
        executionStage = "Checking environment"
        cancellationRequested = false
        finalEvidenceCommitStarted = false
        defer {
            executionAdmission.release(executionOwnerID)
            isRunning = false
            executionStage = nil
            finalEvidenceCommitStarted = false
            executionTask = nil
        }
        var pendingJournal: ScenarioExecutionJournal?
        var pendingOrdinaryStaged = false
        let runConfiguration = configuration
        let runTrusted = projectTrusted
        let runFeatureBackend = featureBackend
        let changedDimensions = statedChangedDimensions
        let linkedRun = linkedFeatureRun(for: draft)
        if draft.schemaVersion == ScenarioDefinition.stableSchemaVersion {
            await runStableExecution(
                ownerID: executionOwnerID, runConfiguration: runConfiguration,
                runTrusted: runTrusted, backend: runFeatureBackend
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
            var stagedLedger = ledger
            let featureResult = linkedRun.map {
                ScenarioFeatureEvidence.laneResult(from: $0, definition: definition)
            }
            for attachment in result.evidenceAttachments {
                var run = try XCTestEvidenceImporter().importEvidence(
                    data: Data(contentsOf: attachment.url),
                    definition: definition,
                    journal: result.journal,
                    artifactRoot: result.attachmentDirectory,
                    ledger: &stagedLedger,
                    supplementaryResults: featureResult.map { [$0] } ?? [],
                    statedChangedDimensions: changedDimensions
                )
                run.xctestExitCode = result.processExitCode
                if result.processExitCode != 0, !ScenarioExecutionRecoveryPolicy.shouldPreserveTerminalBusinessFailure(run, attachment: attachment, definition: definition) {
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
            let accepted = !cancellationRequested
                && ScenarioExecutionRecoveryPolicy.acceptsFinalEvidence(
                attachments: result.evidenceAttachments,
                runs: imported, xctestExitCode: result.processExitCode, definition: definition
            )
            let deviceReady = !cancellationRequested && Self.canReleaseDevice(
                processExitCode: result.processExitCode,
                attachments: result.evidenceAttachments,
                importedRuns: imported,
                requiresCleanupProof: definition.actionRequirements != nil
            )
            // Stage the captured run before any history write. A later save-only
            // retry uses these bytes and never starts another device action.
            finalEvidenceCommitStarted = true
            let pending = ScenarioPendingOrdinarySave(
                invocationID: result.journal.id, runs: imported,
                artifactRootPath: result.attachmentDirectory.path,
                ledger: stagedLedger, evidenceValidationPassed: accepted,
                deviceReadinessProven: deviceReady
            )
            try await persistence.savePendingOrdinarySave(pending)
            pendingOrdinaryStaged = true
            pendingOrdinarySaves.append(pending)
            imported = try await persistence.commitPendingOrdinarySave(pending)
            ledger = try await persistence.loadLedger()
            try await executor.finishEvidenceValidation(
                journal: result.journal,
                accepted: accepted, deviceReady: deviceReady
            )
            if accepted {
                guard let validated = try await persistence.loadJournals()
                    .first(where: { $0.id == result.journal.id }) else {
                    throw ScenarioPersistenceError.acceptanceNotReady
                }
                for index in imported.indices {
                    imported[index] = try await persistence.acceptRun(
                        imported[index], journal: validated
                    )
                }
            }
            try await persistence.clearPendingOrdinarySave(invocationID: pending.invocationID)
            pendingOrdinarySaves.removeAll { $0.invocationID == pending.invocationID }
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
            if let pendingJournal, !pendingOrdinaryStaged {
                try? await executor.finishEvidenceValidation(journal: pendingJournal, accepted: false)
            }
            recoveryJournals = (try? await executor.currentRecoveryJournals()) ?? recoveryJournals
            journals = (try? await persistence.loadJournals()) ?? journals
            notice = error.localizedDescription
        }
        await refreshPreflight()
    }

    /// Completes a staged ordinary import from captured evidence. XCTest is not
    /// called here, so a save fault cannot execute a mutating action twice.
    @discardableResult
    func retryPendingOrdinarySave(invocationID: UUID) async -> [ScenarioRun]? {
        guard hasLoaded, !isRunning else {
            notice = "Wait for the current device execution before retrying its evidence save."
            return nil
        }
        let ownerID = UUID()
        do { try acquireExecutionOwner(ownerID) }
        catch { notice = error.localizedDescription; return nil }
        isRunning = true
        defer {
            executionAdmission.release(ownerID)
            isRunning = false
        }
        do {
            guard let pending = try await persistence.loadPendingOrdinarySave(invocationID: invocationID) else {
                throw ScenarioPersistenceError.invalidRun("No ordinary evidence save is pending.")
            }
            var saved = try await persistence.commitPendingOrdinarySave(pending)
            ledger = try await persistence.loadLedger()
            guard let journal = try await persistence.loadJournals().first(where: { $0.id == invocationID }) else {
                throw ScenarioPersistenceError.acceptanceNotReady
            }
            if pending.evidenceValidationPassed {
                if journal.evidenceAccepted != true {
                    let interruptedBeforeValidation = journal.phase == .running
                        || (journal.phase == .recoveryRequired
                            && journal.recoveryReason == "The desktop stopped before device-side termination and fixture readiness were established.")
                    guard interruptedBeforeValidation else {
                        throw ScenarioPersistenceError.acceptanceNotReady
                    }
                    try await executor.finishEvidenceValidation(
                        journal: journal, accepted: true,
                        deviceReady: pending.deviceReadinessProven
                    )
                }
                guard let validated = try await persistence.loadJournals()
                    .first(where: { $0.id == invocationID }) else {
                    throw ScenarioPersistenceError.acceptanceNotReady
                }
                for index in saved.indices {
                    saved[index] = try await persistence.acceptRun(saved[index], journal: validated)
                }
            } else {
                let interruptedBeforeValidation = journal.phase == .running
                    || (journal.phase == .recoveryRequired
                        && journal.recoveryReason == "The desktop stopped before device-side termination and fixture readiness were established.")
                if interruptedBeforeValidation {
                    try await executor.finishEvidenceValidation(
                        journal: journal, accepted: false,
                        deviceReady: pending.deviceReadinessProven
                    )
                }
            }
            try await persistence.clearPendingOrdinarySave(invocationID: invocationID)
            pendingOrdinarySaves.removeAll { $0.invocationID == invocationID }
            runs.removeAll { $0.id == invocationID }
            runs.insert(contentsOf: saved, at: 0)
            selectedRunID = saved.first?.id
            recoveryJournals = try await executor.currentRecoveryJournals()
            journals = try await persistence.loadJournals()
            notice = "Captured device evidence was saved without rerunning the app."
            return saved
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
            executionAdmission.release(ownerID)
            isRunning = false
            finalEvidenceCommitStarted = false
            executionTask = nil
            activeFeatureRunID = nil
        }
        do {
            let runConfiguration = configuration
            let connection = try await executor.connectionForExecution(
                definition: definition, configuration: runConfiguration,
                projectTrusted: projectTrusted
            )
            let backend = previous.profile.featureBackend
            try validateFeatureBackend(backend, definition: definition, connection: connection)
            let selected = backend == .connectedRunner
                ? try selectedSubjectRunner(for: definition, appDigest: connection.appProduct.sha256)
                : nil
            let profile = ScenarioExecutionProfile(
                id: UUID(), projectPath: runConfiguration.containerPath,
                scheme: runConfiguration.scheme, testTarget: runConfiguration.testTarget,
                destinationIdentifier: runConfiguration.destinationIdentifier,
                signingSelection: runConfiguration.signingArguments.joined(separator: " "),
                trustedConnectionID: nil,
                buildConfiguration: runConfiguration.configuration,
                featureBackend: backend
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
              plan.profile.featureBackend == .connectedRunner,
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
            executionAdmission.release(ownerID)
            isRunning = false
        }
        do {
            guard var progress = try await persistence.loadProgress(planID: planID),
                  let index = progress.records.firstIndex(where: {
                      $0.coordinate.lane == .appFeature && [.recoveryRequired, .completed, .failedToExecute].contains($0.state)
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
            if progress.records[index].state == .recoveryRequired {
            progress.records[index] = try await runFeatureChild(
                coordinate: progress.records[index].coordinate,
                plan: plan, definition: definition, ownerID: ownerID,
                runID: runID, resumeRun: saved,
                capturedMeasurement: progress.records[index].featureMeasurementImplementation
            )
            }
            try await checkpoint(plan: plan, records: progress.records)
            let record = try await persistence.finalizeExecutionRecord(plan: plan, records: progress.records)
            executionRecords.removeAll { $0.id == record.id }
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
              let plan = executionPlans.first(where: { $0.id == planID }) else {
            notice = "Select an unfinished native execution before retrying its evidence save."
            return nil
        }
        let ownerID = UUID()
        do { try acquireExecutionOwner(ownerID) }
        catch { notice = error.localizedDescription; return nil }
        isRunning = true
        defer {
            executionAdmission.release(ownerID)
            isRunning = false
        }
        do {
            guard let pending = try await persistence.loadPendingNativeSave(
                planID: planID, coordinateID: coordinateID
            ), var progress = try await persistence.loadProgress(planID: planID),
                  let index = progress.records.firstIndex(where: { $0.id == coordinateID }),
                  [.recoveryRequired, .completed, .failedToExecute].contains(progress.records[index].state),
                  pending.run.scenarioID == plan.definitionID,
                  pending.run.scenarioVersion == plan.definitionVersion,
                  pending.run.scenarioDigest == plan.definitionDigest,
                  pending.run.invocation.appProduct?.sha256 == plan.appProductDigest,
                  pending.run.invocation.testProduct?.sha256 == plan.testProductDigest,
                  pending.run.laneResults.count == 1,
                  let lane = pending.run.laneResults.first,
                  lane.caseID == progress.records[index].coordinate.caseID,
                  lane.lane == progress.records[index].coordinate.lane,
                  lane.attempt == progress.records[index].coordinate.repetition,
                  pending.run.invocation.featureBackend == (lane.lane == .appFeature
                      ? .projectLocalTestControl : nil),
                  lane.lane != .appFeature
                    || plan.profile.featureBackend == .projectLocalTestControl else {
                throw ScenarioPersistenceError.invalidRun("The pending native child does not match its frozen coordinate.")
            }
            let saved = try await persistence.commitPendingNativeSave(pending)
            var merged = try await persistence.loadLedger()
            merged.importedInvocationIDs.formUnion(pending.ledger.importedInvocationIDs)
            merged.importedNonces.formUnion(pending.ledger.importedNonces)
            merged.importedArtifactIDs.formUnion(pending.ledger.importedArtifactIDs)
            try await persistence.saveLedger(merged)
            ledger = merged
            guard pending.evidenceValidationPassed == true,
                  let journal = try await persistence.loadJournals().first(where: { $0.id == saved.id }),
                  ScenarioExecutionRecoveryPolicy.hasBoundJournal(run: saved, journals: [journal]) else {
                throw ScenarioPersistenceError.acceptanceNotReady
            }
            // A rejected journal becomes stopped after explicit device recovery.
            // Preserve that confirmation when the immutable stage still says unready.
            let readinessConfirmed = journal.phase == .stopped
                && journal.evidenceAccepted != nil && journal.recoveryReason == nil
            if journal.evidenceAccepted != true {
                guard ScenarioExecutionRecoveryPolicy.canPromoteCapturedNativeEvidence(run: saved, journal: journal, validationPassed: pending.evidenceValidationPassed) else {
                    throw ScenarioPersistenceError.acceptanceNotReady
                }
                try await executor.finishEvidenceValidation(
                    journal: journal, accepted: true,
                    deviceReady: pending.deviceReadinessProven == true || readinessConfirmed
                )
            }
            guard let validated = try await persistence.loadJournals()
                .first(where: { $0.id == saved.id }) else {
                throw ScenarioPersistenceError.acceptanceNotReady
            }
            let acceptedRun = try await persistence.acceptRun(saved, journal: validated)
            progress.records[index] = .init(
                coordinate: progress.records[index].coordinate,
                state: acceptedRun.laneResults[0].executionStatus == .completed
                    ? .completed : .failedToExecute,
                evidenceRunID: acceptedRun.id,
                evidenceLaneResultID: acceptedRun.laneResults[0].id,
                detail: acceptedRun.laneResults[0].diagnostic,
                laneResult: acceptedRun.laneResults[0],
                evidenceDigest: try ScenarioNativeRunEvidence.digest(acceptedRun)
            )
            try await checkpoint(plan: plan, records: progress.records)
            let record = try await persistence.finalizeExecutionRecord(plan: plan, records: progress.records)
            try await persistence.clearPendingNativeSave(planID: planID, coordinateID: coordinateID)
            executionRecords.removeAll { $0.id == record.id }
            executionRecords.insert(record, at: 0)
            selectedExecutionID = record.id
            runs.insert(acceptedRun, at: 0)
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
            cases: [try await evidenceRequirement(definition: definition)]
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
            item, requirement: try await evidenceRequirement(definition: definition),
            referenceTime: Date()
        )
    }

    private func evidenceRequirement(
        definition: ScenarioDefinition
    ) async throws -> IntentEvidenceRequirements.CaseRequirement {
        try await ScenarioSavedExecutionReportService(rootDirectory: rootDirectory)
            .evidenceRequirement(definition: definition)
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
        var caseRequirements: [IntentEvidenceRequirements.CaseRequirement] = []
        for definition in trusted {
            caseRequirements.append(try await evidenceRequirement(definition: definition))
        }
        let requirements = IntentEvidenceRequirements(
            collectionID: collection.id.uuidString, cases: caseRequirements
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
        try await ScenarioSavedExecutionReportService(rootDirectory: rootDirectory).bundleCase(
            definition: definition, plan: plan, record: record, artifacts: &artifacts
        )
    }

    func reloadSelectedAssessmentOverlay(expectedExecutionID: UUID? = nil) async {
        guard let record = selectedExecutionRecord else {
            selectedAssessmentOverlay = nil
            assessmentSelectionHistory = []
            return
        }
        guard expectedExecutionID == nil || expectedExecutionID == record.id else { return }
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
                for: record, laneResultID: laneResultID, definition: definition,
                nativeEvidence: try featureAssessmentEvidence(
                    for: coordinate, record: record, plan: plan
                )
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

    func frozenSemanticPolicyForSelectedCoordinate(
        coordinateID: UUID, assertionID: UUID
    ) async throws -> ScenarioFrozenSemanticPolicy? {
        let context = try selectedAssessmentContext(coordinateID: coordinateID,
                                                    assertionID: assertionID)
        return try await assessmentStore.frozenSemanticPolicy(definition: context.definition)
    }

    @discardableResult
    func freezeSelectedSemanticPolicy(
        coordinateID: UUID, assertionID: UUID,
        judgeConfiguration: EvaluationJudgeConfiguration
    ) async -> Bool {
        do {
            let context = try selectedAssessmentContext(coordinateID: coordinateID,
                                                        assertionID: assertionID)
            guard let judge = try resolvedAssessmentJudge(configuration: judgeConfiguration) else {
                throw ScenarioPersistenceError.invalidRun("Choose an approved independent judge connection.")
            }
            let policy = try ScenarioFrozenSemanticPolicy.make(
                definition: context.definition, assertionID: assertionID,
                configuration: judgeConfiguration, resolvedJudge: judge
            )
            try await assessmentStore.freezeSemanticPolicy(policy, definition: context.definition)
            notice = "Judge and scoring policy frozen for this requirement. The response has not been assessed."
            return true
        } catch {
            notice = "Judge policy needs review: \(error.localizedDescription)"
            return false
        }
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
            if let frozen = try await assessmentStore.frozenSemanticPolicy(definition: context.definition) {
                try frozen.validateAssessmentJudge(
                    definition: context.definition, assertionID: assertionID,
                    configuration: judgeConfiguration, resolvedJudge: judge
                )
            }
            let assessment: ScenarioIndependentAssessment
            if context.coordinate.coordinate.lane == .appFeature {
                assessment = try await assessmentStore.reassessSavedFeatureOutput(
                    coordinateID: coordinateID, assertionID: assertionID,
                    executionRecord: context.record, definition: context.definition,
                    judgeConfiguration: judgeConfiguration,
                    resolvedJudge: judge,
                    nativeEvidence: try featureAssessmentEvidence(
                        for: context.coordinate, record: context.record
                    )
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
                    executionRecord: context.record, definition: context.definition,
                    nativeEvidence: try featureAssessmentEvidence(
                        for: context.coordinate, record: context.record
                    )
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
        guard let plan = executionPlans.first(where: { $0.id == record.planID }) else {
            throw ScenarioPersistenceError.invalidRun("The frozen execution plan is unavailable.")
        }
        let previous = try await assessmentStore.latestSelectionRecord(executionRecord: record)
        return try await assessmentStore.sealSelection(
            executionRecord: record, runs: runs, definition: definition,
            plan: plan, journals: journals,
            previousSelectionID: previous?.id
        )
    }

    private func featureAssessmentEvidence(
        for coordinate: ScenarioExecutionCoordinateRecord,
        record: ScenarioExecutionRecord,
        plan suppliedPlan: ScenarioExecutionPlan? = nil
    ) throws -> ScenarioFeatureAssessmentEvidence? {
        guard coordinate.coordinate.lane == .appFeature else {
            throw ScenarioPersistenceError.invalidRun("Choose an App Feature coordinate.")
        }
        guard let plan = suppliedPlan ?? executionPlans.first(where: { $0.id == record.planID }),
              plan.id == record.planID else {
            throw ScenarioPersistenceError.invalidRun("The frozen Feature execution plan is unavailable.")
        }
        if coordinate.featureChild != nil {
            guard plan.profile.featureBackend == .connectedRunner else {
                throw ScenarioPersistenceError.invalidRun("The Feature child uses the wrong frozen backend.")
            }
            return nil
        }
        guard plan.profile.featureBackend == .projectLocalTestControl,
              plan.id == record.planID,
              let runID = coordinate.evidenceRunID,
              runs.filter({ $0.id == runID }).count == 1,
              journals.filter({ $0.id == runID }).count == 1,
              let run = runs.first(where: { $0.id == runID }),
              let journal = journals.first(where: { $0.id == runID }) else {
            throw ScenarioPersistenceError.invalidRun("The accepted local Feature run and journal are unavailable.")
        }
        return .init(plan: plan, run: run, journal: journal)
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
            executionAdmission.release(ownerID)
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
            var selectedFeatureBackend = featureBackend
            let selectedIDs: Set<UUID>
            if scope == .rerunFailed {
                guard selectedCaseIDs == nil, let priorBatchID,
                      let prior = batchManifests.first(where: { $0.id == priorBatchID }) else {
                    throw ScenarioCollectionError.invalidSelection
                }
                selectedFeatureBackend = prior.selectedFeatureBackend
                let assessment = ScenarioCollectionService.assess(
                    manifest: prior, collection: collection,
                    result: batchResults.first { $0.manifestID == priorBatchID },
                    runs: runs, journals: journals
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
                    priorRuns: runs, priorJournals: journals,
                    appProductDigest: checked.appProduct.sha256,
                    subjectInputDigests: inputDigests
                )
            } else {
                manifest = try ScenarioCollectionService.freezeManifest(
                    collection: collection, definitions: definitionsForCollection,
                    scope: scope, appProductDigest: checked.appProduct.sha256,
                    subjectInputDigests: inputDigests,
                    featureBackend: selectedFeatureBackend,
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
                    let connection = try await executor.connectionForExecution(
                        definition: definition, configuration: runConfiguration,
                        projectTrusted: projectTrusted
                    )
                    guard connection.appProduct.sha256 == manifest.appProductDigest else {
                        throw ScenarioCollectionError.invalidManifest
                    }
                    let backend = selectedFeatureBackend
                    try validateFeatureBackend(backend, definition: definition, connection: connection)
                    let selected = backend == .connectedRunner
                        ? try selectedSubjectRunner(for: definition, appDigest: connection.appProduct.sha256)
                        : nil
                    let profile = ScenarioExecutionProfile(
                        id: UUID(), projectPath: runConfiguration.containerPath,
                        scheme: runConfiguration.scheme, testTarget: runConfiguration.testTarget,
                        destinationIdentifier: runConfiguration.destinationIdentifier,
                        signingSelection: runConfiguration.signingArguments.joined(separator: " "),
                        trustedConnectionID: nil,
                        buildConfiguration: runConfiguration.configuration,
                        featureBackend: backend
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
                                    runTrusted: Bool, backend: ScenarioFeatureBackend,
                                    purpose: ScenarioExecutionPlanPurpose = .fullRequirement,
                                    selectedLanes: Set<ScenarioLane>? = nil) async {
        do {
            let definition = try await freezeAndSave()
            guard !cancellationRequested else { throw XcodeTestExecutorError.cancelled }
            executionStage = "Checking app and test build"
            let connection = try await executor.connectionForExecution(
                definition: definition, configuration: runConfiguration, projectTrusted: runTrusted
            )
            guard !cancellationRequested else { throw XcodeTestExecutorError.cancelled }
            let requestedLanes = selectedLanes ?? Set(ScenarioLane.allCases.filter {
                definition.coverage[$0] != .notApplicable
            })
            var readiness = await executor.routeReadiness(
                definition: definition, configuration: runConfiguration,
                projectTrusted: runTrusted, featureBackend: backend
            )
            if backend == .connectedRunner {
                Self.applyConnectedFeatureReadiness(
                    to: &readiness, definition: definition, appDigest: connection.appProduct.sha256,
                    runnerCheck: { _ = try selectedSubjectRunner(for: definition, appDigest: $0) }
                )
            }
            routeReadiness = readiness
            guard !cancellationRequested else { throw XcodeTestExecutorError.cancelled }
            let dependencyLanes = purpose == .fullRequirement
                ? Set(requestedLanes.filter { definition.coverage[$0] == .required })
                : requestedLanes
            let blocked = dependencyLanes.filter { readiness[$0]?.state != .ready }
            guard blocked.isEmpty else {
                let reasons = blocked.sorted { $0.rawValue < $1.rawValue }.map { lane in
                    "\(lane.rawValue): \(readiness[lane]?.detail ?? "Readiness has not been checked.")"
                }
                throw ScenarioPersistenceError.invalidRun(
                    "The selected routes are not ready. \(reasons.joined(separator: " "))"
                )
            }
            if requestedLanes.contains(.appFeature) {
                try validateFeatureBackend(backend, definition: definition, connection: connection)
            }
            let selected = backend == .connectedRunner && requestedLanes.contains(.appFeature)
                ? try selectedSubjectRunner(for: definition, appDigest: connection.appProduct.sha256)
                : nil
            let profile = ScenarioExecutionProfile(
                id: UUID(), projectPath: runConfiguration.containerPath,
                scheme: runConfiguration.scheme, testTarget: runConfiguration.testTarget,
                destinationIdentifier: runConfiguration.destinationIdentifier,
                signingSelection: runConfiguration.signingArguments.joined(separator: " "),
                trustedConnectionID: nil,
                buildConfiguration: runConfiguration.configuration,
                featureBackend: backend
            )
            let coordinates: [ScenarioPlannedCoordinate]? = purpose == .partialDiagnostic
                ? ScenarioLane.allCases.filter { requestedLanes.contains($0) }.flatMap { lane in
                    let count = lane == .siri ? max(1, definition.coverage.siriAttemptCount ?? 3) : 1
                    return (1...count).map { attempt in
                        ScenarioPlannedCoordinate(
                            id: UUID(), caseID: definition.id, lane: lane,
                            repetition: attempt, required: definition.coverage[lane] == .required
                        )
                    }
                } : nil
            let plan = try ScenarioExecutionPlan.make(
                definition: definition, profile: profile,
                appProductDigest: connection.appProduct.sha256,
                testProductDigest: connection.testProduct.sha256,
                sourceInputsDigest: connection.buildInputsDigest,
                sourceRevision: connection.sourceRevision,
                runnerBuildID: selected?.runner.identity.buildProvenance?.buildID,
                runnerID: selected?.runner.id,
                plannedCoordinates: coordinates, purpose: purpose
            )
            executionStage = purpose == .partialDiagnostic
                ? "Running partial diagnostic" : "Verifying complete requirement"
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
            plannedCoordinates: plan.coordinates, purpose: plan.purpose,
            comparisonPolicy: plan.comparisonPolicy,
            id: plan.id, createdAt: plan.createdAt
        )
        guard expected == plan else { throw ScenarioPersistenceError.invalidRun("execution plan") }
    }

    static func applyConnectedFeatureReadiness(
        to routes: inout [ScenarioLane: ScenarioRouteReadiness],
        definition: ScenarioDefinition,
        appDigest: String?,
        runnerCheck: (String) throws -> Void
    ) {
        guard definition.coverage.appFeature != .notApplicable,
              var route = routes[.appFeature] else { return }
        route.backendName = ScenarioFeatureBackend.connectedRunner.rawValue
        let independentChecks = route.checks.filter {
            $0.id != "nativeScope" && $0.id != "featureLane"
                && $0.id != "localFeatureControl" && !$0.id.hasPrefix("capability.")
        }
        if let blocker = independentChecks.first(where: { $0.state != .ready }) {
            route.state = ["trust", "container", "scheme", "testTarget", "definition"].contains(blocker.id)
                ? .setupRequired : .environmentBlocked
            route.detail = blocker.detail
        } else if let actionBlocker = connectedFeatureActionBlocker(definition) {
            route.state = .setupRequired
            route.detail = actionBlocker
        } else if let appDigest {
            do {
                try runnerCheck(appDigest)
                route.state = .ready
                route.detail = "A connected runner matches the checked app build and frozen Feature interface."
            } catch {
                route.state = .setupRequired
                route.detail = error.localizedDescription
            }
        } else {
            route.state = .notYetVerified
            route.detail = "Build and check the selected app and test products before matching a connected Feature runner."
        }
        route.checks = independentChecks
        routes[.appFeature] = route
    }

    /// A connected runner returns a feature sample but no invocation-bound,
    /// typed action receipt. Explicit action requirements therefore cannot be
    /// verified through this backend, even when the runner and build match.
    static func connectedFeatureActionBlocker(_ definition: ScenarioDefinition) -> String? {
        guard definition.coverage.appFeature != .notApplicable,
              definition.actionRequirements != nil else { return nil }
        return "This check requires a typed App Feature action receipt. The connected runner does not provide one. Select a declared project-local Feature control and check support."
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

    private func validateFeatureBackend(
        _ backend: ScenarioFeatureBackend,
        definition: ScenarioDefinition,
        connection: ScenarioVerifiedConnection
    ) throws {
        if backend == .connectedRunner {
            if let blocker = Self.connectedFeatureActionBlocker(definition) {
                throw ScenarioPersistenceError.invalidRun(blocker)
            }
            return
        }
        guard definition.coverage.appFeature != .notApplicable,
              backend == .projectLocalTestControl else { return }
        guard connection.receipt.capabilities.contains("local-feature-controls"),
              connection.receipt.capabilities.contains("test-only-intent"),
              let declaration = try? Data(contentsOf: connection.testBundleURL.appending(path: "IntentLabIntegration.json")),
              let catalog = try? ScenarioIntegrationCatalog.decodeVerified(
                  declaration, identity: connection.receipt.integration
              ),
              catalog.localFeatureControl(for: definition) != nil else {
            throw ScenarioPersistenceError.invalidRun(
                "This checked app build has no matching project-local Feature control or test-only intent transport. Add the declared control and check support, or explicitly choose the connected runner backend."
            )
        }
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
            // Complete required coverage before attempting optional routes.
            let dispatchCoordinates = plan.coordinates.filter(\.required)
                + plan.coordinates.filter { !$0.required }
            for coordinate in dispatchCoordinates {
                guard !cancellationRequested else { break }
                executionStage = "Running \(coordinate.lane.rawValue) attempt \(coordinate.repetition) of \(plan.coordinates.count)"
                guard let index = records.firstIndex(where: { $0.id == coordinate.id }) else { continue }
                if plan.purpose == .fullRequirement, !coordinate.required,
                   routeReadiness[coordinate.lane]?.state != .ready {
                    records[index].state = .blocked
                    records[index].detail = routeReadiness[coordinate.lane]?.detail
                        ?? "Optional route readiness has not been verified."
                    try await checkpoint(plan: plan, records: records)
                    continue
                }
                records[index].state = .recoveryRequired
                records[index].detail = "Execution started; evidence has not been committed."
                let featureRunID = coordinate.lane == .appFeature
                    && plan.profile.featureBackend == .connectedRunner ? UUID() : nil
                                if let featureRunID {
                    records[index].evidenceRunID = featureRunID
                    records[index].featureMeasurementImplementation = Self.featureMeasurementImplementation()
                }

                try await checkpoint(plan: plan, records: records)
                do {
                    if coordinate.lane == .appFeature
                        && plan.profile.featureBackend == .connectedRunner {
                        records[index] = try await runFeatureChild(
                            coordinate: coordinate, plan: plan, definition: definition,
                            ownerID: ownerID, runID: featureRunID!,
                            capturedMeasurement: records[index].featureMeasurementImplementation
                        )
                    } else {
                        records[index] = try await runNativeChild(
                            coordinate: coordinate, plan: plan, definition: definition,
                            configuration: runConfiguration, trusted: trusted
                        )
                    }
                    executionStage = "Saving captured evidence"
                    try await checkpoint(plan: plan, records: records)
                    if coordinate.lane != .appFeature
                        || plan.profile.featureBackend == .projectLocalTestControl {
                        try await persistence.clearPendingNativeSave(
                            planID: plan.id, coordinateID: coordinate.id
                        )
                    }
                    if records[index].state == .failedToExecute { break }
                } catch {
                    executionStage = "Recovery required"
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
            guard !records.contains(where: { $0.state == .recoveryRequired }) else { return nil }
            let record = try ScenarioExecutionRecord.make(plan: plan, records: records)
            executionStage = "Finalizing results"
            finalEvidenceCommitStarted = true
            try await persistence.saveExecutionRecord(record)
            executionRecords.removeAll { $0.id == record.id }
            executionRecords.insert(record, at: 0)
            selectedExecutionID = record.id
            recoveryJournals = (try? await executor.currentRecoveryJournals()) ?? recoveryJournals
            journals = (try? await persistence.loadJournals()) ?? journals
            notice = "Execution recorded: \(record.passingCount)/\(record.plannedCount) attempts passed; \(record.aggregateOutcome.rawValue)."
            return record
        } catch {
            recoveryJournals = (try? await executor.currentRecoveryJournals()) ?? recoveryJournals
            journals = (try? await persistence.loadJournals()) ?? journals
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
        resumeRun: EvaluationRun? = nil,
        capturedMeasurement: ScenarioMeasurementImplementation? = nil
    ) async throws -> ScenarioExecutionCoordinateRecord {
        if resumeRun == nil,
           let blocker = Self.connectedFeatureActionBlocker(definition) {
            throw ScenarioPersistenceError.invalidRun(blocker)
        }
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
            guard ScenarioExecutionRecoveryPolicy.canReevaluateFeature(captured: capturedMeasurement, current: Self.featureMeasurementImplementation()) else {
                throw ScenarioPersistenceError.invalidRun("The Feature measurement code changed after dispatch. Preserve the saved raw run and recover with the captured runner build.")
            }
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
            artifacts: [], observationSources: Dictionary(uniqueKeysWithValues: observations.keys.map { ($0, .applicationInstrumentation) })
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
            measurementImplementation: capturedMeasurement
        ).sealed()
        return .init(coordinate: coordinate,
                     state: status == .completed ? .completed : .failedToExecute,
                     evidenceRunID: run.id, evidenceLaneResultID: lane.id,
                     detail: lane.diagnostic, laneResult: lane,
                     evidenceDigest: child.digest, featureChild: child,
                     featureMeasurementImplementation: capturedMeasurement)
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
        guard scope.isValid(for: definition, featureBackend: plan.profile.featureBackend) else {
            throw ScenarioPersistenceError.invalidRun("The planned native route is unsupported.")
        }
        let task = Task {
            try Task.checkCancellation()
            return try await executor.execute(
                definition: definition, configuration: runConfiguration,
                projectTrusted: trusted, linkedFeatureEvidenceAvailable: true,
                scope: scope,
                featureBackend: plan.profile.featureBackend
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
              lane.attempt == coordinate.repetition,
              run.invocation.appProduct?.sha256 == plan.appProductDigest,
              run.invocation.testProduct?.sha256 == plan.testProductDigest,
              run.invocation.featureBackend == (coordinate.lane == .appFeature
                  ? .projectLocalTestControl : nil) else {
            try? await executor.finishEvidenceValidation(journal: result.journal, accepted: false)
            throw ScenarioPersistenceError.invalidRun(
                "The imported lane, backend, or app/test build did not match its frozen plan."
            )
        }
        run.xctestExitCode = result.processExitCode
        run.comparisonEnvironmentIdentity = try ScenarioExecutionEnvironmentIdentity.derive(
            environment: run.environment,
            destinationIdentifier: plan.profile.destinationIdentifier,
            lane: coordinate.lane
        )
        if result.processExitCode != 0, !ScenarioExecutionRecoveryPolicy.shouldPreserveTerminalBusinessFailure(run, attachment: attachment, definition: definition) {
            run.executionStatus = .invalidEvidence
            run.outcome = .needsReview
            run.laneResults[0].executionStatus = .invalidEvidence
            run.laneResults[0].outcome = .notObserved
            if attachment.isCheckpoint, let failure = result.testFailureMessages.first {
                run.laneResults[0].diagnostic = ScenarioDiagnosticClassifier.checkpointDiagnostic(for: failure)
            }
        }
        if [.blockedByEnvironment, .timedOut, .crashed, .failedToBuild].contains(
            run.laneResults[0].executionStatus
        ) {
            await executor.invalidateRuntimeReadiness(
                lane: coordinate.lane,
                reason: run.laneResults[0].diagnostic
                    ?? "The route driver failed after its readiness probe. Check the environment before another attempt."
            )
        }
        let receipt = ScenarioFixtureReceipt(
            observations: run.laneResults[0].observations,
            expected: plan.fixtureContractDigest
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
        let evidenceValidationPassed = !cancellationRequested
            && ScenarioExecutionRecoveryPolicy.acceptsFinalEvidence(
                attachments: [attachment], runs: [run], xctestExitCode: result.processExitCode
            )
        let deviceReadinessProven = !cancellationRequested && Self.canReleaseDevice(
            processExitCode: result.processExitCode,
            attachments: [attachment], importedRuns: [run],
            requiresCleanupProof: definition.actionRequirements != nil
        )
        do {
            try await persistence.savePendingNativeSave(.init(
                planID: plan.id, coordinateID: coordinate.id, run: run,
                artifactRootPath: result.attachmentDirectory.path, ledger: stagedLedger,
                evidenceValidationPassed: evidenceValidationPassed,
                deviceReadinessProven: deviceReadinessProven
            ))
        } catch {
            try? await executor.finishEvidenceValidation(
                journal: result.journal, accepted: false,
                deviceReady: deviceReadinessProven
            )
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
            // Preserve the staged child and unvalidated journal for save-only retry.
            throw error
        }
        try await executor.finishEvidenceValidation(
            journal: result.journal, accepted: evidenceValidationPassed,
            deviceReady: deviceReadinessProven
        )
        let finalized: ScenarioRun
        if evidenceValidationPassed {
            guard let validated = try await persistence.loadJournals()
                .first(where: { $0.id == saved.id }) else {
                throw ScenarioPersistenceError.acceptanceNotReady
            }
            finalized = try await persistence.acceptRun(saved, journal: validated)
        } else {
            finalized = saved
        }
        recoveryJournals = try await executor.currentRecoveryJournals()
        journals = try await persistence.loadJournals()
        runs.insert(finalized, at: 0)
        let child = finalized.laneResults[0]
        return .init(
            coordinate: coordinate,
            state: child.executionStatus == .completed ? .completed : .failedToExecute,
            evidenceRunID: finalized.id, evidenceLaneResultID: child.id,
            detail: child.diagnostic, laneResult: child,
            evidenceDigest: try ScenarioNativeRunEvidence.digest(finalized)
        )
    }

    func cancel() async {
        if finalEvidenceCommitStarted {
            notice = "The device test has finished and its evidence is being saved; cancellation can no longer stop this run."
            return
        }
        if isRunning { cancellationRequested = true }
        if let activeFeatureRunID { developerRunnerStore?.cancelRun(activeFeatureRunID) }
        executionTask?.cancel()
        let connectionCancellation = await executor.cancelConnectionCheck()
        let connectionRecoveryJournal: ScenarioExecutionJournal?
        switch connectionCancellation {
        case .recoveryRequired(let journal): connectionRecoveryJournal = journal
        case .notRunning, .beforeDeviceTest: connectionRecoveryJournal = nil
        }
        if let journal = await executor.cancelActiveExecution() ?? connectionRecoveryJournal {
            recoveryJournals.removeAll { $0.id == journal.id }
            recoveryJournals.append(journal)
            journals.removeAll { $0.id == journal.id }
            journals.append(journal)
            notice = "Cancellation requested. The device is quarantined until test termination and fixture readiness are proven."
        } else {
            notice = connectionCancellation == .beforeDeviceTest
                ? "Cancellation requested. Stopping the connection check before a device test starts."
                : "Cancellation requested before the device test started."
        }
        await refreshPreflight()
    }

    static func canReleaseDevice(
        processExitCode: Int32,
        attachments: [ScenarioEvidenceAttachment],
        importedRuns: [ScenarioRun],
        requiresCleanupProof: Bool = false
    ) -> Bool {
        ScenarioExecutionRecoveryPolicy.acceptsFinalEvidence(
            attachments: attachments, runs: importedRuns, xctestExitCode: processExitCode
        ) && (!requiresCleanupProof || importedRuns.allSatisfy { run in
            run.laneResults.allSatisfy { $0.cleanupVerified == true }
        })
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
        configuration.destinationPlatform = Self.availablePlatform(
            for: target.destinationIdentifier, in: discoveredDevices
        )
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
        configuration.scheme = Self.schemeAfterDiscovery(configuration.scheme, in: discovery)
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

    static func schemeAfterDiscovery(_ selectedScheme: String, in discovery: XcodeConnectionDiscovery) -> String {
        if !selectedScheme.isEmpty && discovery.schemes.contains(selectedScheme) {
            return selectedScheme
        }
        return discovery.automaticallySelectedScheme ?? ""
    }

    private func linkedFeatureRun(for definition: ScenarioDefinition) -> EvaluationRun? {
        guard let run = definition.directControl.linkedFeatureRunID.flatMap(evaluationStore.run(with:)),
              ScenarioFeatureEvidence.isEligible(run, for: definition) else { return nil }
        return run
    }
}
