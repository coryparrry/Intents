import Foundation
import Observation

@MainActor
@Observable
final class ScenarioCoordinator {
    private(set) var definitions: [ScenarioDefinition] = []
    private(set) var runs: [ScenarioRun] = []
    var draft: ScenarioDefinition
    var parameterArrayDraftTexts: [Int: String] = [:]
    var invalidParameterDraftIndices: Set<Int> = []
    var selectedRunID: UUID?
    var configuration: XcodeTestConfiguration
    var projectTrusted = false
    private(set) var selectedIntegration: ScenarioIntegrationIdentity?
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
    private(set) var hasLoaded = false
    var notice: String?

    private let persistence: ScenarioPersistence
    private let executor: XcodeTestExecutor
    private let rootDirectory: URL
    private let evaluationStore: EvaluationStore
    private var ledger = ScenarioImportLedger()
    private var preflightRevision = 0
    @ObservationIgnored private var scopedProjectURL: URL?

    init(supportDirectory: URL, evaluationStore: EvaluationStore) {
        let root = supportDirectory.appending(path: "IntentLab", directoryHint: .isDirectory)
        rootDirectory = root
        let persistence = ScenarioPersistence(rootDirectory: root)
        self.persistence = persistence
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
            let selected = try await persistence.loadSelectedDefinition()
            let restored = selected.flatMap { saved in
                definitions.first { $0.id == saved.id && $0.version == saved.version }
            } ?? definitions.last
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
            connectionDiscovery = nil
            clearSelectedProductConfiguration()
        }

        draft = definition
        selectedIntegration = definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion
            ? definition.integration : nil
        parameterArrayDraftTexts = [:]
        invalidParameterDraftIndices = []
        selectedRunID = nil
        applyTargetToConfiguration(target)

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
        configuration.testTarget = ""
        configuration.selectedTestProductID = nil
        configuration.selectedApplicationProductID = nil
        configuration.testBundleIdentifier = ""
        configuration.harnessVersion = nil
        configuration.harnessCapabilities = nil
        configuration.applicationSigningConfigured = nil
        configuration.testSigningConfigured = nil
        selectedIntegration = nil
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
            }
        } catch {
            discoveredDevices = []
            if recoveryJournals.isEmpty {
                notice = error.localizedDescription
            }
        }
    }

    func approveBuildAndDiscover() async {
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
            let discovery = try await Task.detached {
                try service.discoverProject(container: container, configuration: buildConfiguration)
            }.value
            guard configuration.containerPath == approvedContainerPath else { return }
            connectionDiscovery = discovery
            projectTrusted = true
            apply(discovery: discovery)
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
        configuration.scheme = scheme
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
        invalidatePreflight()
    }

    func selectUITestBundle(_ product: XcodeDiscoveredProduct) {
        configuration.testTarget = product.targetName
        configuration.selectedTestProductID = product.id
        configuration.testBundleIdentifier = product.bundleIdentifier
        configuration.harnessVersion = product.harnessVersion
        configuration.harnessCapabilities = product.harnessCapabilities
        configuration.testSigningConfigured = product.signingConfigured
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
            verifiedIntegrationSummary = "Compiled \(verified.receipt.integration.id) v\(verified.receipt.integration.version) with \(verified.receipt.capabilities.count) declared capabilities."
            draft = definition
            await refreshPreflight()
        } catch {
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
        selectedIntegration = identity
        configuration.selectedApplicationProductID = applicationProductID
        configuration.selectedTestProductID = testProductID
        configuration.testTarget = testTarget
        configuration.scheme = scheme
        configuration.applicationSigningConfigured = products.application?.signingConfigured
        configuration.testBundleIdentifier = products.tests?.bundleIdentifier ?? ""
        configuration.harnessVersion = products.tests?.harnessVersion
        configuration.harnessCapabilities = products.tests?.harnessCapabilities
        configuration.testSigningConfigured = products.tests?.signingConfigured
        guard draft.schemaVersion == ScenarioDefinition.reusableSchemaVersion else { return }
        draft.integration = identity
        draft.target.bundleIdentifier = appBundleID
        draft.target.projectPath = projectPath
        draft.target.scheme = scheme
        draft.target.testTarget = testTarget
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
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        var pendingJournal: ScenarioExecutionJournal?
        let runConfiguration = configuration
        let runTrusted = projectTrusted
        let changedDimensions = statedChangedDimensions
        let linkedRun = linkedFeatureRun(for: draft)
        do {
            let definition = try await freezeAndSave()
            let result = try await executor.execute(
                definition: definition,
                configuration: runConfiguration,
                projectTrusted: runTrusted,
                linkedFeatureEvidenceAvailable: linkedRun != nil
            )
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
                imported.append(try await persistence.saveRun(run, artifactRoot: result.attachmentDirectory))
            }
            try await persistence.saveLedger(ledger)
            let accepted = ScenarioExecutionRecoveryPolicy.acceptsFinalEvidence(
                attachments: result.evidenceAttachments,
                runs: imported,
                xctestExitCode: result.processExitCode
            )
            try await executor.finishEvidenceValidation(
                journal: result.journal,
                accepted: accepted
            )
            if accepted {
                for index in imported.indices {
                    imported[index] = try await persistence.acceptRun(
                        imported[index], journal: result.journal
                    )
                }
            }
            pendingJournal = nil
            recoveryJournals = try await executor.currentRecoveryJournals()
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
            notice = error.localizedDescription
        }
        await refreshPreflight()
    }

    func cancel() async {
        if let journal = await executor.cancelActiveExecution() {
            recoveryJournals.removeAll { $0.id == journal.id }
            recoveryJournals.append(journal)
        }
        notice = "Cancellation requested. The device is quarantined until test termination and fixture readiness are proven."
        await refreshPreflight()
    }

    func clearDeviceQuarantine(fixtureReadinessProven: Bool) async {
        do {
            try await executor.clearQuarantine(
                destinationIdentifier: configuration.destinationIdentifier,
                fixtureReadinessProven: fixtureReadinessProven
            )
            recoveryJournals.removeAll { $0.invocation.destinationIdentifier == configuration.destinationIdentifier }
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
            comparison: run.flatMap(comparison(for:))
        )
    }

    private func applyConfigurationToDraft() {
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

    private func apply(discovery: XcodeConnectionDiscovery) {
        configuration.scheme = Self.schemeAfterDiscovery(configuration.scheme, in: discovery)
        if discovery.applications.count == 1, let application = discovery.applications.first {
            selectApplication(application)
        } else if !discovery.applications.contains(where: { $0.id == configuration.selectedApplicationProductID }) {
            draft.target.bundleIdentifier = ""
            draft.definitionDigest = ""
            configuration.applicationSigningConfigured = nil
            configuration.selectedApplicationProductID = nil
        }
        if discovery.uiTestBundles.count == 1, let tests = discovery.uiTestBundles.first {
            selectUITestBundle(tests)
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
