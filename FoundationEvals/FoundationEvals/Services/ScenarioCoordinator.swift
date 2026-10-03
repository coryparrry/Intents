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
    private(set) var connectionDiscovery: XcodeConnectionDiscovery?
    private(set) var discoveredDevices: [IntentLabDeviceDestination] = []
    private(set) var isDiscoveringConnection = false
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
    private let executor: XcodeTestExecutor
    private let rootDirectory: URL
    private let evaluationStore: EvaluationStore
    private var ledger = ScenarioImportLedger()
    private var preflightRevision = 0
    private var cancellationRequested = false
    private var finalEvidenceCommitStarted = false
    private var executionTask: Task<ScenarioExecutorResult, Error>?

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
            journals = try await persistence.loadJournals()
            // Resume the last-run scenario at its latest version, even if it was renamed.
            let latestDefinitions = ScenarioDefinition.latestVersions(in: definitions)
            let lastRunDefinition = runs.lazy.compactMap { run in
                latestDefinitions.first { $0.id == run.scenarioID }
            }.first
            let fallbackDefinition = latestDefinitions.max {
                ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString)
            }
            if let definition = lastRunDefinition ?? fallbackDefinition {
                draft = definition
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
        configuration.containerPath = url.standardizedFileURL.path
        configuration.isWorkspace = url.pathExtension == "xcworkspace"
        configuration.scheme = ""
        configuration.testTarget = ""
        configuration.testBundleIdentifier = ""
        configuration.harnessVersion = nil
        configuration.harnessCapabilities = nil
        configuration.applicationSigningConfigured = nil
        configuration.testSigningConfigured = nil
        projectTrusted = false
        connectionDiscovery = nil
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
        draft.target.bundleIdentifier = product.bundleIdentifier
        configuration.applicationSigningConfigured = product.signingConfigured
        draft.definitionDigest = ""
        invalidatePreflight()
    }

    func selectUITestBundle(_ product: XcodeDiscoveredProduct) {
        configuration.testTarget = product.targetName
        configuration.testBundleIdentifier = product.bundleIdentifier
        configuration.harnessVersion = product.harnessVersion
        configuration.harnessCapabilities = product.harnessCapabilities
        configuration.testSigningConfigured = product.signingConfigured
        invalidatePreflight()
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
        isRunning = true
        cancellationRequested = false
        finalEvidenceCommitStarted = false
        defer {
            isRunning = false
            finalEvidenceCommitStarted = false
            executionTask = nil
        }
        var pendingJournal: ScenarioExecutionJournal?
        let runConfiguration = configuration
        let runTrusted = projectTrusted
        let changedDimensions = statedChangedDimensions
        let linkedRun = linkedFeatureRun(for: draft)
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

    func cancel() async {
        if finalEvidenceCommitStarted {
            notice = "The device test has finished and its evidence is being saved; cancellation can no longer stop this run."
            return
        }
        if isRunning { cancellationRequested = true }
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
        if let scheme = discovery.automaticallySelectedScheme {
            configuration.scheme = scheme
        } else if !discovery.schemes.contains(configuration.scheme) {
            configuration.scheme = ""
        }
        if discovery.applications.count == 1, let application = discovery.applications.first {
            selectApplication(application)
        } else if !discovery.applications.contains(where: { $0.bundleIdentifier == draft.target.bundleIdentifier }) {
            draft.target.bundleIdentifier = ""
            draft.definitionDigest = ""
            configuration.applicationSigningConfigured = nil
        }
        if discovery.uiTestBundles.count == 1, let tests = discovery.uiTestBundles.first {
            selectUITestBundle(tests)
        } else if !discovery.uiTestBundles.contains(where: { $0.targetName == configuration.testTarget }) {
            configuration.testTarget = ""
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
