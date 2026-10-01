import CryptoKit
import Foundation
import FoundationModels
#if canImport(FoundationEvalsDeveloper)
import FoundationEvalsDeveloper
#endif
import ImageIO
import Observation
import PDFKit
import Security
import UniformTypeIdentifiers

@MainActor
@Observable
final class EvaluationStore {
    nonisolated static let maximumCases = 100
    nonisolated static let maximumPlannedSamples = 100
    nonisolated static let maximumAttachments = 20
    nonisolated static let maximumImages = 4
    nonisolated static let maximumFieldCharacters = 32_000
    nonisolated static let maximumCombinedSuiteCharacters = 256_000
    nonisolated static let maximumRubricRequirementCharacters = 4_000
    nonisolated static let maximumExtractedTextCharacters = 16_000
    nonisolated static let maximumTextFileBytes = 5_000_000
    nonisolated static let maximumImageBytes = 10_000_000

    private(set) var suite: EvaluationSuite
    var draftSuite: EvaluationSuite
    var runs: [EvaluationRun]
    private(set) var workspace: EvaluationWorkspaceCatalog
    private(set) var selectedProjectID: UUID
    private(set) var selectedSuiteID: UUID
    private(set) var suiteLocalState: EvaluationSuiteLocalState
    private(set) var judgeConnections: [EvaluationJudgeConnection]
    private(set) var latestJudgeCheck: EvaluationJudgeCheckReport?
    private(set) var isReassessing = false
    var selection = SidebarSelection.overview
    var isRunning = false
    var completedSamples = 0
    var totalSamples = 0
    private(set) var liveResponse: EvaluationLiveResponse?
    private var loadedCoreAI: CoreAIModelLoadResult?
    private var loadedCoreAIConfiguration: EvaluationCoreAIConfiguration?
    private var coreAILoadStatus: CoreAIModelControlStatus = .unconfigured
    private var cloudContextSize: Int?
    private(set) var isRefreshingCloud = false
    private var cloudMetadataError: String?
    private(set) var draftSaveFailed = false
    var notice: String?
    private(set) var migrationNotice: String?
    var isImportingFiles = false
    var isProcessingFiles = false
    private(set) var activeRun: EvaluationActiveRun?

    private let runner = EvaluationRunner()
    private let experimentRunner = EvaluationExperimentRunner()
    private let featureAdapterRunner = EvaluationFeatureAdapterRunner()
    private let reassessmentService = EvaluationReassessmentService()
    private let supportDirectory: URL
    private let suiteLocalStateWriter: (Data, URL) throws -> Void
    var overviewStorageDirectory: URL { supportDirectory }
    @ObservationIgnored private var pendingPromptEdits: [UUID: String] = [:]
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private let onDeviceContextSizes = ModelContextSizeCache()
    private(set) var isDraftSavePending = false
    private var runTask: Task<Void, Never>?
    private var activeRunSuite: EvaluationSuite?
    private var activeRunEvidence: EvaluationSubjectEvidenceSnapshot?
    private var activeRunResults: [EvaluationSampleResult] = []
    private var unsavedRun: EvaluationRun?
    private var latestRunHistorySequence: UInt64 = 0
    private var workspacePersistenceBlocker: String?

    private var suiteDirectory: URL {
        EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: supportDirectory,
            projectID: selectedProjectID,
            suiteID: selectedSuiteID
        )
    }
    private var attachmentsDirectory: URL { suiteDirectory.appending(path: "Attachments", directoryHint: .isDirectory) }
    private var runsDirectory: URL { suiteDirectory.appending(path: "Runs", directoryHint: .isDirectory) }
    private var activeRunURL: URL { suiteDirectory.appending(path: "active-run.json") }
    private var draftSuiteURL: URL { suiteDirectory.appending(path: "suite-draft.json") }
    private var suiteStateURL: URL { suiteDirectory.appending(path: "state.json") }
    private var judgeConnectionsURL: URL { supportDirectory.appending(path: "judge-connections.json") }

    init(
        supportDirectory customSupportDirectory: URL? = nil,
        suiteLocalStateWriter: @escaping (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) {
        let base = customSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "FoundationEvals", directoryHint: .isDirectory)
        supportDirectory = base
        self.suiteLocalStateWriter = suiteLocalStateWriter

        var startupNotice: String?
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            startupNotice = "Could not create local storage: \(error.localizedDescription)"
        }

        let legacySuite = EvaluationWorkspaceStatePersistence.loadSuite(from: base)
        let bootstrap: EvaluationWorkspaceBootstrap
        var catalogRecoveryAttempted = false
        var catalogRecoveryCanPublish = false
        do {
            bootstrap = try EvaluationWorkspacePersistence.bootstrap(in: base, legacySuite: legacySuite.suite)
        } catch {
            catalogRecoveryAttempted = true
            let catalogURL = base.appending(path: EvaluationWorkspacePersistence.catalogFilename)
            catalogRecoveryCanPublish = !FileManager.default.fileExists(atPath: catalogURL.path)
            if let originalCatalog = try? Data(contentsOf: catalogURL) {
                do {
                    try EvaluationWorkspacePersistence.preserveUnreadableFile(
                        originalCatalog,
                        in: base,
                        prefix: "workspace-v1-unreadable"
                    )
                    catalogRecoveryCanPublish = true
                } catch {
                    catalogRecoveryCanPublish = false
                }
            }
            let seed = legacySuite.suite ?? EvaluationSuite()
            let now = Date()
            let record = EvaluationSuiteRecord(
                id: seed.id, name: seed.name, createdAt: now, updatedAt: now,
                archivedAt: nil, repositoryDefinitionPath: nil, lastRepositoryRevision: nil
            )
            let project = EvaluationProject(
                id: UUID(), name: "Recovery workspace", createdAt: now, updatedAt: now,
                archivedAt: nil, repository: nil, selectedSuiteID: seed.id, suites: [record]
            )
            bootstrap = EvaluationWorkspaceBootstrap(
                catalog: EvaluationWorkspaceCatalog(selectedProjectID: project.id, projects: [project]),
                notice: "The workspace catalog could not be loaded: \(error.localizedDescription)"
            )
        }
        let selectedProject = bootstrap.catalog.projects.first { $0.id == bootstrap.catalog.selectedProjectID }
            ?? bootstrap.catalog.projects.first { !$0.isArchived }
            ?? bootstrap.catalog.projects[0]
        let initialProjectID = selectedProject.id
        let initialSuiteID = selectedProject.suites.first { $0.id == selectedProject.selectedSuiteID }?.id
            ?? selectedProject.suites.first { !$0.isArchived }?.id
            ?? selectedProject.suites[0].id
        let activeDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: base,
            projectID: initialProjectID,
            suiteID: initialSuiteID
        )
        do {
            try EvaluationWorkspacePersistence.createSuiteDirectories(at: activeDirectory)
        } catch {
            startupNotice = [startupNotice, "Could not create suite storage: \(error.localizedDescription)"]
                .compactMap { $0 }.joined(separator: "\n")
        }
        if catalogRecoveryAttempted, catalogRecoveryCanPublish {
            do {
                try EvaluationWorkspacePersistence.save(bootstrap.catalog, in: base)
            } catch {
                catalogRecoveryCanPublish = false
                startupNotice = [startupNotice, "The recovery workspace could not be saved: \(error.localizedDescription)"]
                    .compactMap { $0 }.joined(separator: "\n")
            }
        }

        let loadedSuite = EvaluationWorkspaceStatePersistence.loadSuite(from: activeDirectory)
        var initialSuite = loadedSuite.suite ?? EvaluationSuite()
        let migratedRubric = initialSuite.criteria == EvaluationSuite.legacyDefaultCriteria
        if migratedRubric {
            initialSuite.criteria = EvaluationSuite.defaultRubric
            if initialSuite.cases.count == 1,
               initialSuite.cases[0].prompt == "Explain why the sky appears blue in two sentences.",
               initialSuite.cases[0].expected.isEmpty {
                initialSuite.cases[0].expected = EvaluationSuite().cases[0].expected
            }
        }
        let loadedDraft = Self.loadDraft(from: activeDirectory, canonicalSuite: initialSuite)
        var loadedRuns = Self.loadRuns(
            from: activeDirectory.appending(path: "Runs", directoryHint: .isDirectory),
            projectID: initialProjectID,
            suiteID: initialSuiteID
        )
        let recovery = Self.recoverInterruptedRun(
            from: activeDirectory.appending(path: "active-run.json"),
            runsDirectory: activeDirectory.appending(path: "Runs", directoryHint: .isDirectory),
            existingRuns: loadedRuns.runs
        )
        if let recoveredRun = recovery.run {
            loadedRuns.runs.append(recoveredRun)
            loadedRuns.runs.sort { ($0.historySequence ?? 0, $0.startedAt) > ($1.historySequence ?? 0, $1.startedAt) }
        }
        let loadedJudgeConnections = EvaluationWorkspaceStatePersistence.loadJudgeConnections(
            from: base.appending(path: "judge-connections.json")
        )
        let initialNotice = [startupNotice, legacySuite.notice, loadedSuite.notice,
                             loadedDraft.notice, loadedRuns.notice, recovery.notice,
                             loadedJudgeConnections.notice]
            .compactMap { $0 }
            .joined(separator: "\n")
        workspace = bootstrap.catalog
        selectedProjectID = initialProjectID
        selectedSuiteID = initialSuiteID
        suiteLocalState = EvaluationSuiteLocalState()
        judgeConnections = loadedJudgeConnections.connections
        suite = initialSuite
        draftSuite = loadedDraft.suite ?? initialSuite
        runs = loadedRuns.runs
        activeRun = recovery.pending?.summary
        activeRunSuite = recovery.pending?.suite
        activeRunEvidence = recovery.pending?.subjectEvidence
        activeRunResults = recovery.pending?.results ?? []
        unsavedRun = recovery.pending?.completedRun
        completedSamples = recovery.pending?.summary.completedSamples ?? 0
        totalSamples = recovery.pending?.summary.totalSamples ?? 0
        workspacePersistenceBlocker = catalogRecoveryAttempted && !catalogRecoveryCanPublish
            ? "The unreadable workspace catalog could not be preserved. Resolve the storage conflict and reopen the app before saving workspace changes."
            : nil
        migrationNotice = bootstrap.notice
        notice = initialNotice.isEmpty ? nil : initialNotice
        do {
            try loadSelectedSuite()
            let combinedNotice = [initialNotice.isEmpty ? nil : initialNotice, notice]
                .compactMap { $0 }
                .joined(separator: "\n")
            notice = combinedNotice.isEmpty ? nil : combinedNotice
        } catch {
            notice = [initialNotice.isEmpty ? nil : initialNotice, error.localizedDescription]
                .compactMap { $0 }
                .joined(separator: "\n")
        }
        if migratedRubric || (loadedSuite.suite == nil && loadedSuite.notice == nil) {
            if !catalogRecoveryAttempted || catalogRecoveryCanPublish {
                saveSuite()
            }
        }
    }

    var projects: [EvaluationProject] { workspace.projects }

    var selectedProject: EvaluationProject {
        workspace.projects.first { $0.id == selectedProjectID }
            ?? workspace.projects.first { !$0.isArchived }
            ?? workspace.projects[0]
    }

    var suiteRecords: [EvaluationSuiteRecord] { selectedProject.suites }

    var selectedSuiteRecord: EvaluationSuiteRecord {
        selectedProject.suites.first { $0.id == selectedSuiteID }
            ?? selectedProject.suites.first { !$0.isArchived }
            ?? selectedProject.suites[0]
    }

    var activeBaselineApproval: EvaluationBaselineApproval? {
        suiteLocalState.baselineApprovals.last { $0.isCurrent }
    }

    var projectOverviews: [EvaluationProjectOverview] {
        workspace.projects.filter { !$0.isArchived }.map { project in
            var latest: Date?
            var stale = 0
            for record in project.suites where !record.isArchived {
                let directory = EvaluationWorkspacePersistence.suiteDirectory(
                    supportDirectory: supportDirectory, projectID: project.id, suiteID: record.id
                )
                let suite = EvaluationWorkspaceStatePersistence.loadSuite(from: directory).suite
                let runs = Self.loadRuns(
                    from: directory.appending(path: "Runs", directoryHint: .isDirectory),
                    projectID: project.id,
                    suiteID: record.id
                ).runs
                latest = [latest, runs.first?.startedAt].compactMap { $0 }.max()
                if let suite,
                   runs.first?.suiteRevision != (try? Self.revision(for: suite)) {
                    stale += 1
                } else if runs.isEmpty {
                    stale += 1
                }
            }
            return EvaluationProjectOverview(
                id: project.id, name: project.name,
                suiteCount: project.suites.count { !$0.isArchived },
                suitesNeedingChecks: stale, latestRunAt: latest,
                hasStaleResults: stale > 0
            )
        }
    }

    @discardableResult
    func createProject(name: String, starter: EvaluationStarterPack? = nil) throws -> UUID {
        try requireIdle()
        try preserveCurrentDraftBeforeWorkspaceChange()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EvaluationStoreError.invalidSuite("Project name cannot be empty.") }
        var newSuite = starter?.makeSuite() ?? EvaluationSuite()
        newSuite.id = UUID()
        let now = Date()
        let projectID = UUID()
        let record = EvaluationSuiteRecord(
            id: newSuite.id, name: newSuite.name, createdAt: now, updatedAt: now,
            archivedAt: nil, repositoryDefinitionPath: nil, lastRepositoryRevision: nil
        )
        let project = EvaluationProject(
            id: projectID, name: trimmed, createdAt: now, updatedAt: now,
            archivedAt: nil, repository: nil, selectedSuiteID: newSuite.id, suites: [record]
        )
        let directory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: supportDirectory, projectID: projectID, suiteID: newSuite.id
        )
        try EvaluationWorkspacePersistence.createSuiteDirectories(at: directory)
        try CanonicalJSON.data(for: newSuite).write(to: directory.appending(path: "suite.json"), options: .atomic)
        workspace.projects.append(project)
        try persistWorkspace()
        try switchWorkspace(projectID: projectID, suiteID: newSuite.id)
        return projectID
    }

    @discardableResult
    func duplicateProject(id: UUID) throws -> UUID {
        try requireIdle()
        guard let source = workspace.projects.first(where: { $0.id == id }) else {
            throw EvaluationWorkspaceError.missingProject
        }
        let newProjectID = UUID()
        let now = Date()
        var copiedRecords: [EvaluationSuiteRecord] = []
        let stagedProjectDirectory = supportDirectory
            .appending(path: "Projects", directoryHint: .isDirectory)
            .appending(path: newProjectID.uuidString, directoryHint: .isDirectory)
        do {
            let activeRecords = source.suites.filter { !$0.isArchived }
            guard !activeRecords.isEmpty else { throw EvaluationWorkspaceError.missingSuite }
            for sourceRecord in activeRecords {
                let sourceDirectory = EvaluationWorkspacePersistence.suiteDirectory(
                    supportDirectory: supportDirectory, projectID: source.id, suiteID: sourceRecord.id
                )
                guard var copiedSuite = EvaluationWorkspaceStatePersistence.loadSuite(from: sourceDirectory).suite else {
                    throw EvaluationWorkspaceError.missingSuite
                }
                guard copiedSuite.id == sourceRecord.id else {
                    throw EvaluationWorkspaceError.missingSuite
                }
                copiedSuite.id = UUID()
                copiedSuite.name += " copy"
                let target = EvaluationWorkspacePersistence.suiteDirectory(
                    supportDirectory: supportDirectory, projectID: newProjectID, suiteID: copiedSuite.id
                )
                try EvaluationWorkspacePersistence.createSuiteDirectories(at: target)
                try CanonicalJSON.data(for: copiedSuite).write(to: target.appending(path: "suite.json"), options: .atomic)
                try Self.copyAttachmentFiles(
                    from: sourceDirectory.appending(path: "Attachments", directoryHint: .isDirectory),
                    to: target.appending(path: "Attachments", directoryHint: .isDirectory),
                    suite: copiedSuite
                )
                copiedRecords.append(.init(
                    id: copiedSuite.id, name: copiedSuite.name, createdAt: now, updatedAt: now,
                    archivedAt: nil, repositoryDefinitionPath: nil, lastRepositoryRevision: nil
                ))
            }
            guard let first = copiedRecords.first else { throw EvaluationWorkspaceError.missingSuite }
            let project = EvaluationProject(
                id: newProjectID, name: source.name + " copy", createdAt: now, updatedAt: now,
                archivedAt: nil, repository: nil, selectedSuiteID: first.id, suites: copiedRecords
            )
            let previousWorkspace = workspace
            workspace.projects.append(project)
            do {
                try persistWorkspace()
            } catch {
                workspace = previousWorkspace
                throw error
            }
            return newProjectID
        } catch {
            try? FileManager.default.removeItem(at: stagedProjectDirectory)
            throw error
        }
    }

    func renameProject(id: UUID, name: String) throws {
        try requireIdle()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EvaluationStoreError.invalidSuite("Project name cannot be empty.") }
        guard let index = workspace.projects.firstIndex(where: { $0.id == id }) else {
            throw EvaluationWorkspaceError.missingProject
        }
        workspace.projects[index].name = trimmed
        workspace.projects[index].updatedAt = Date()
        try persistWorkspace()
    }

    func archiveProject(id: UUID) throws {
        try requireIdle()
        guard workspace.projects.contains(where: { $0.id == id }) else {
            throw EvaluationWorkspaceError.missingProject
        }
        guard workspace.projects.count(where: { !$0.isArchived && $0.id != id }) > 0 else {
            throw EvaluationStoreError.resourceConflict("Keep at least one active project.")
        }
        if selectedProjectID == id,
           let replacement = workspace.projects.first(where: { !$0.isArchived && $0.id != id }) {
            try switchWorkspace(
                projectID: replacement.id,
                suiteID: replacement.selectedSuiteID
            ) { workspace in
                guard let index = workspace.projects.firstIndex(where: { $0.id == id }) else { return }
                workspace.projects[index].archivedAt = Date()
                workspace.projects[index].updatedAt = Date()
            }
        } else {
            try updateProject(id) { project in
                project.archivedAt = Date()
                project.updatedAt = Date()
            }
        }
    }

    @discardableResult
    func createSuite(name: String, starter: EvaluationStarterPack? = nil) throws -> UUID {
        try requireIdle()
        try preserveCurrentDraftBeforeWorkspaceChange()
        var newSuite = starter?.makeSuite() ?? EvaluationSuite()
        newSuite.id = UUID()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { newSuite.name = trimmed }
        let now = Date()
        let record = EvaluationSuiteRecord(
            id: newSuite.id, name: newSuite.name, createdAt: now, updatedAt: now,
            archivedAt: nil, repositoryDefinitionPath: nil, lastRepositoryRevision: nil
        )
        let directory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: supportDirectory, projectID: selectedProjectID, suiteID: newSuite.id
        )
        try EvaluationWorkspacePersistence.createSuiteDirectories(at: directory)
        try CanonicalJSON.data(for: newSuite).write(to: directory.appending(path: "suite.json"), options: .atomic)
        try updateProject(selectedProjectID) { project in
            project.suites.append(record)
            project.selectedSuiteID = newSuite.id
            project.updatedAt = now
        }
        try switchWorkspace(projectID: selectedProjectID, suiteID: newSuite.id)
        return newSuite.id
    }

    @discardableResult
    func duplicateSuite(id: UUID) throws -> UUID {
        try requireIdle()
        guard let sourceRecord = selectedProject.suites.first(where: { $0.id == id }) else {
            throw EvaluationWorkspaceError.missingSuite
        }
        let sourceDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: supportDirectory, projectID: selectedProjectID, suiteID: id
        )
        guard var copied = EvaluationWorkspaceStatePersistence.loadSuite(from: sourceDirectory).suite else {
            throw EvaluationWorkspaceError.missingSuite
        }
        guard copied.id == sourceRecord.id else {
            throw EvaluationWorkspaceError.missingSuite
        }
        copied.id = UUID()
        copied.name = sourceRecord.name + " copy"
        let target = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: supportDirectory, projectID: selectedProjectID, suiteID: copied.id
        )
        do {
            try EvaluationWorkspacePersistence.createSuiteDirectories(at: target)
            try CanonicalJSON.data(for: copied).write(to: target.appending(path: "suite.json"), options: .atomic)
            try Self.copyAttachmentFiles(
                from: sourceDirectory.appending(path: "Attachments", directoryHint: .isDirectory),
                to: target.appending(path: "Attachments", directoryHint: .isDirectory),
                suite: copied
            )
            let now = Date()
            try updateProject(selectedProjectID) { project in
                project.suites.append(.init(
                    id: copied.id, name: copied.name, createdAt: now, updatedAt: now,
                    archivedAt: nil, repositoryDefinitionPath: nil, lastRepositoryRevision: nil
                ))
                project.updatedAt = now
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return copied.id
    }

    func renameSuite(id: UUID, name: String) throws {
        try requireIdle()
        guard id == selectedSuiteID else { throw EvaluationStoreError.resourceConflict("Switch to the suite before renaming it.") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EvaluationStoreError.invalidSuite("Suite name cannot be empty.") }
        draftSuite.name = trimmed
        guard saveSuite() else { throw EvaluationStoreError.invalidSuite(notice ?? "The suite could not be saved.") }
    }

    func archiveSuite(id: UUID) throws {
        try requireIdle()
        let project = selectedProject
        guard project.suites.contains(where: { $0.id == id }) else {
            throw EvaluationWorkspaceError.missingSuite
        }
        guard project.suites.count(where: { !$0.isArchived && $0.id != id }) > 0 else {
            throw EvaluationStoreError.resourceConflict("Keep at least one active suite in the project.")
        }
        if id == selectedSuiteID,
           let replacement = project.suites.first(where: { !$0.isArchived && $0.id != id }) {
            try switchWorkspace(
                projectID: selectedProjectID,
                suiteID: replacement.id
            ) { workspace in
                guard let projectIndex = workspace.projects.firstIndex(where: { $0.id == project.id }),
                      let suiteIndex = workspace.projects[projectIndex].suites.firstIndex(where: {
                          $0.id == id
                      }) else { return }
                workspace.projects[projectIndex].suites[suiteIndex].archivedAt = Date()
                workspace.projects[projectIndex].updatedAt = Date()
            }
        } else {
            try updateProject(project.id) { project in
                guard let index = project.suites.firstIndex(where: { $0.id == id }) else { return }
                project.suites[index].archivedAt = Date()
                project.updatedAt = Date()
            }
        }
    }

    func switchWorkspace(projectID: UUID, suiteID: UUID) throws {
        try switchWorkspace(projectID: projectID, suiteID: suiteID) { _ in }
    }

    private func switchWorkspace(
        projectID: UUID,
        suiteID: UUID,
        catalogMutation: (inout EvaluationWorkspaceCatalog) -> Void
    ) throws {
        try requireIdle()
        guard let project = workspace.projects.first(where: { $0.id == projectID }),
              !project.isArchived else { throw EvaluationWorkspaceError.missingProject }
        guard project.suites.contains(where: { $0.id == suiteID && !$0.isArchived }) else {
            throw EvaluationWorkspaceError.missingSuite
        }
        if projectID == selectedProjectID, suiteID == selectedSuiteID { return }
        try preserveCurrentDraftBeforeWorkspaceChange()
        try persistSuiteLocalState()
        let previousWorkspace = workspace
        let previousProjectID = selectedProjectID
        let previousSuiteID = selectedSuiteID
        let previousSuite = suite
        let previousDraft = draftSuite
        let previousRuns = runs
        let previousLocalState = suiteLocalState
        let previousNotice = notice
        let previousSelection = selection
        let previousActiveRun = activeRun
        let previousActiveRunSuite = activeRunSuite
        let previousActiveRunEvidence = activeRunEvidence
        let previousActiveRunResults = activeRunResults
        let previousUnsavedRun = unsavedRun
        let previousCompletedSamples = completedSamples
        let previousTotalSamples = totalSamples
        let previousIsRunning = isRunning
        let previousLiveResponse = liveResponse
        let previousDraftSaveFailed = draftSaveFailed
        do {
            selectedProjectID = projectID
            selectedSuiteID = suiteID
            try EvaluationWorkspacePersistence.createSuiteDirectories(at: suiteDirectory)
            try loadSelectedSuite()
            guard let projectIndex = workspace.projects.firstIndex(where: { $0.id == projectID }) else {
                throw EvaluationWorkspaceError.missingProject
            }
            workspace.projects[projectIndex].selectedSuiteID = suiteID
            workspace.selectedProjectID = projectID
            catalogMutation(&workspace)
            try persistWorkspace()
            selection = .overview
        } catch {
            workspace = previousWorkspace
            selectedProjectID = previousProjectID
            selectedSuiteID = previousSuiteID
            suite = previousSuite
            draftSuite = previousDraft
            runs = previousRuns
            suiteLocalState = previousLocalState
            notice = previousNotice
            selection = previousSelection
            activeRun = previousActiveRun
            activeRunSuite = previousActiveRunSuite
            activeRunEvidence = previousActiveRunEvidence
            activeRunResults = previousActiveRunResults
            unsavedRun = previousUnsavedRun
            completedSamples = previousCompletedSamples
            totalSamples = previousTotalSamples
            isRunning = previousIsRunning
            liveResponse = previousLiveResponse
            draftSaveFailed = previousDraftSaveFailed
            try? persistWorkspace()
            throw error
        }
    }

    private func preserveCurrentDraftBeforeWorkspaceChange() throws {
        _ = saveSuite()
        guard !draftSaveFailed else {
            throw EvaluationStoreError.persistence("The current suite draft could not be saved before switching workspaces.")
        }
    }

    func switchProject(id: UUID) throws {
        guard let project = workspace.projects.first(where: { $0.id == id }) else {
            throw EvaluationWorkspaceError.missingProject
        }
        try switchWorkspace(projectID: id, suiteID: project.selectedSuiteID)
    }

    func switchSuite(id: UUID) throws {
        try switchWorkspace(projectID: selectedProjectID, suiteID: id)
    }

    /// Resolves a stable automation target instead of assuming whichever suite
    /// happens to be visible when the request arrives. The native UI follows the
    /// selected target so progress and terminal evidence remain inspectable.
    func activateAutomationTarget(projectID: UUID, suiteID: UUID) throws {
        if projectID == selectedProjectID, suiteID == selectedSuiteID {
            guard workspace.projects.contains(where: { project in
                project.id == projectID && !project.isArchived
                    && project.suites.contains(where: { $0.id == suiteID && !$0.isArchived })
            }) else {
                throw EvaluationWorkspaceError.missingSuite
            }
            return
        }
        try switchWorkspace(projectID: projectID, suiteID: suiteID)
    }

    private func updateProject(_ id: UUID, mutation: (inout EvaluationProject) -> Void) throws {
        guard let index = workspace.projects.firstIndex(where: { $0.id == id }) else {
            throw EvaluationWorkspaceError.missingProject
        }
        let previousWorkspace = workspace
        mutation(&workspace.projects[index])
        do {
            try persistWorkspace()
        } catch {
            workspace = previousWorkspace
            throw error
        }
    }

    private func persistWorkspace() throws {
        try requireWorkspaceWritable()
        do {
            try EvaluationWorkspacePersistence.save(workspace, in: supportDirectory)
        } catch {
            throw EvaluationStoreError.persistence(error.localizedDescription)
        }
    }

    private func loadSelectedSuite() throws {
        let loaded = EvaluationWorkspaceStatePersistence.loadSuite(from: suiteDirectory)
        guard var canonical = loaded.suite, canonical.id == selectedSuiteID else {
            throw EvaluationWorkspaceError.missingSuite
        }
        let localDraft = Self.loadDraft(from: suiteDirectory, canonicalSuite: canonical)
        let hasChangedLocalDraft = localDraft.suite.map { $0 != canonical } == true
        let repositoryConflict = hasChangedLocalDraft ? try repositoryDefinitionChangedOutsideApp() : false
        if !repositoryConflict {
            canonical = try applyingRepositoryChanges(to: canonical)
        }
        let draft = repositoryConflict
            ? localDraft
            : Self.loadDraft(from: suiteDirectory, canonicalSuite: canonical)
        var loadedRuns = Self.loadRuns(
            from: runsDirectory,
            projectID: selectedProjectID,
            suiteID: selectedSuiteID
        )
        let recovery = Self.recoverInterruptedRun(
            from: activeRunURL,
            runsDirectory: runsDirectory,
            existingRuns: loadedRuns.runs
        )
        if let recoveredRun = recovery.run {
            loadedRuns.runs.append(recoveredRun)
            loadedRuns.runs.sort { ($0.historySequence ?? 0, $0.startedAt) > ($1.historySequence ?? 0, $1.startedAt) }
        }
        suite = canonical
        draftSuite = draft.suite ?? canonical
        runs = loadedRuns.runs
        let loadedLocalState = EvaluationWorkspaceStatePersistence.loadSuiteLocalState(from: suiteStateURL)
        suiteLocalState = loadedLocalState.state
        activeRun = recovery.pending?.summary
        activeRunSuite = recovery.pending?.suite
        activeRunEvidence = recovery.pending?.subjectEvidence
        activeRunResults = recovery.pending?.results ?? []
        unsavedRun = recovery.pending?.completedRun
        completedSamples = recovery.pending?.summary.completedSamples ?? 0
        totalSamples = recovery.pending?.summary.totalSamples ?? 0
        let repositoryNotice = repositoryConflict
            ? "The repository suite changed while this suite has an autosaved local draft. Both versions were preserved; review them before saving."
            : nil
        let messages = [
            loaded.notice,
            draft.notice,
            loadedRuns.notice,
            recovery.notice,
            loadedLocalState.notice,
            repositoryNotice
        ]
            .compactMap { $0 }
            .joined(separator: "\n")
        notice = messages.isEmpty ? nil : messages
    }

    // MARK: Judge connections, reassessment, and human approval

    func saveJudgeConnection(_ connection: EvaluationJudgeConnection, apiKey: String?) throws {
        if let issue = connection.validationIssue { throw EvaluationStoreError.invalidSuite(issue) }
        var storedConnection = connection
        if let existing = judgeConnections.first(where: { $0.id == connection.id }),
           existing.disclosureDigest != connection.disclosureDigest {
            storedConnection.lastCheckedAt = nil
            storedConnection.lastCheckMessage = nil
        }
        let previousSecret: String?
        if apiKey != nil || connection.requiresAPIKey {
            previousSecret = try EvaluationJudgeCredentialStore.load(connectionID: connection.id)
        } else {
            previousSecret = nil
        }
        if connection.requiresAPIKey {
            let effectiveSecret = apiKey ?? previousSecret
            guard effectiveSecret?.isEmpty == false else {
                throw EvaluationStoreError.invalidSuite("Enter an API key for this judge connection.")
            }
        }
        let previousConnections = judgeConnections
        var updatedConnections = judgeConnections
        if let index = updatedConnections.firstIndex(where: { $0.id == connection.id }) {
            updatedConnections[index] = storedConnection
        } else {
            updatedConnections.append(storedConnection)
        }
        try persistJudgeConnections(updatedConnections)
        do {
            if let apiKey {
                try EvaluationJudgeCredentialStore.save(apiKey, connectionID: connection.id)
            }
        } catch {
            try? persistJudgeConnections(previousConnections)
            try? EvaluationJudgeCredentialStore.save(previousSecret, connectionID: connection.id)
            throw error
        }
        judgeConnections = updatedConnections
    }

    func deleteJudgeConnection(id: UUID) throws {
        guard !workspace.projects.contains(where: { project in
            project.suites.contains { record in
                guard let suite = EvaluationWorkspaceStatePersistence.loadSuite(
                    from: EvaluationWorkspacePersistence.suiteDirectory(
                        supportDirectory: supportDirectory,
                        projectID: project.id,
                        suiteID: record.id
                    )
                ).suite else { return false }
                return suite.judgeConfiguration.connectionID == id
            }
        }) else {
            throw EvaluationStoreError.resourceConflict("Choose another judge for every suite before deleting this connection.")
        }
        let previousConnections = judgeConnections
        let previousSecret = try EvaluationJudgeCredentialStore.load(connectionID: id)
        let updatedConnections = judgeConnections.filter { $0.id != id }
        try persistJudgeConnections(updatedConnections)
        do {
            try EvaluationJudgeCredentialStore.save(nil, connectionID: id)
        } catch {
            try? persistJudgeConnections(previousConnections)
            try? EvaluationJudgeCredentialStore.save(previousSecret, connectionID: id)
            throw error
        }
        judgeConnections = updatedConnections
    }

    func checkJudgeConnection(id: UUID) async {
        guard let connection = judgeConnections.first(where: { $0.id == id }) else {
            notice = "Judge connection not found."
            return
        }
        do {
            let resolved = EvaluationResolvedJudgeConnection(
                connection: connection,
                apiKey: try EvaluationJudgeCredentialStore.load(connectionID: id)
            )
            let result = try await EvaluationCompatibleJudgeClient().checkConnection(resolved)
            if let index = judgeConnections.firstIndex(where: { $0.id == id }) {
                var updatedConnections = judgeConnections
                updatedConnections[index].lastCheckedAt = result.checkedAt
                updatedConnections[index].lastCheckMessage = result.message
                try persistJudgeConnections(updatedConnections)
                judgeConnections = updatedConnections
            }
            notice = result.message
        } catch {
            notice = "Judge connection check failed: \(error.localizedDescription)"
        }
    }

    var externalJudgeDisclosure: String? {
        guard draftSuite.judgeConfiguration.usesExternalConnection,
              let id = draftSuite.judgeConfiguration.connectionID,
              let connection = judgeConnections.first(where: { $0.id == id }) else { return nil }
        let images = draftSuite.attachments.count { $0.kind == .image }
        return "Foundation Evals will send each case's instructions, effective input, candidate response, verified reference, bounded tool evidence"
            + (images > 0 ? ", and \(images) image attachment\(images == 1 ? "" : "s")" : "")
            + " to \(connection.name) at \(connection.baseURL). No application tools, other runs, secrets, or telemetry are sent."
    }

    func approveExternalJudgeDisclosure() {
        guard draftSuite.judgeConfiguration.usesExternalConnection,
              let connectionID = draftSuite.judgeConfiguration.connectionID,
              let connection = judgeConnections.first(where: { $0.id == connectionID }) else { return }
        draftSuite.judgeConfiguration.externalEvidenceApprovedAt = Date()
        draftSuite.judgeConfiguration.approvedConnectionID = connectionID
        draftSuite.judgeConfiguration.approvedIncludeReferenceAttachments =
            draftSuite.judgeConfiguration.includeReferenceAttachments
        draftSuite.judgeConfiguration.approvedConnectionDigest = connection.disclosureDigest
        _ = saveSuite()
    }

    func reassessRun(id: UUID, connectionID: UUID) {
        guard !isRunning, !isReassessing, let runIndex = runs.firstIndex(where: { $0.id == id }) else { return }
        let run = runs[runIndex]
        isReassessing = true
        Task { [weak self] in
            guard let self else { return }
            defer { isReassessing = false }
            do {
                let resolved = try resolvedJudge(connectionID: connectionID)
                let scoringSuite = suite
                var judgingSuite = scoringSuite
                judgingSuite.judgeConfiguration.mode = .connection
                judgingSuite.judgeConfiguration.connectionID = connectionID
                if !judgingSuite.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: resolved.connection) {
                    throw EvaluationCompatibleJudgeError.disclosureNotApproved
                }
                let context = try reassessmentContext(for: run, scoringSuite: judgingSuite)
                let assessment = try await reassessmentService.reassess(
                    run: run,
                    suite: context.suite,
                    images: context.images,
                    resolved: resolved,
                    scoringContract: context.scoringContract,
                    subjectEvidenceDigest: context.evidence.digest
                )
                guard let currentIndex = runs.firstIndex(where: { $0.id == id }) else { return }
                var candidate = runs[currentIndex]
                candidate.assessments = (candidate.assessments ?? []) + [assessment]
                candidate.selectedAssessmentID = assessment.id
                try persistRun(candidate)
                runs[currentIndex] = candidate
                selection = .run(id)
            } catch {
                notice = "Could not reassess the saved responses: \(error.localizedDescription)"
            }
        }
    }

    func selectAssessment(runID: UUID, assessmentID: UUID) throws {
        guard let index = runs.firstIndex(where: { $0.id == runID }),
              runs[index].assessments?.contains(where: { $0.id == assessmentID }) == true else {
            throw EvaluationStoreError.resourceNotFound("Assessment")
        }
        let previousSelectedAssessmentID = runs[index].selectedAssessmentID
        runs[index].selectedAssessmentID = assessmentID
        do {
            try persistRun(runs[index])
        } catch {
            runs[index].selectedAssessmentID = previousSelectedAssessmentID
            throw error
        }
    }

    func markJudgmentIncorrect(
        runID: UUID,
        assessmentID: UUID,
        sampleID: UUID,
        correctedStatus: EvaluationResultStatus,
        correctedScore: Int?,
        reason: String,
        reviewer: String? = nil,
        collectAsJudgeCheck: Bool
    ) throws {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EvaluationStoreError.invalidSuite("Explain why the judgment is incorrect.") }
        guard let run = runs.first(where: { $0.id == runID }),
              let assessment = run.assessments?.first(where: { $0.id == assessmentID }),
              let sample = assessment.samples.first(where: { $0.sampleID == sampleID }) else {
            throw EvaluationStoreError.resourceNotFound("Judgment")
        }
        if collectAsJudgeCheck {
            guard let subjectSample = run.results.first(where: { $0.id == sampleID }) else {
                throw EvaluationStoreError.invalidSuite(
                    "Only a complete saved subject response can become a known-good judge check."
                )
            }
            guard subjectSample.hasCompleteSubjectEvidenceForJudging else {
                throw EvaluationStoreError.invalidSuite(
                    "Only a complete saved subject response can become a known-good judge check."
                )
            }
            guard correctedStatus == .passed || correctedStatus == .failed else {
                throw EvaluationStoreError.invalidSuite(
                    "A known-good judge check must use a passed or failed corrected status."
                )
            }
            guard assessment.promptVersion == EvaluationRunner.judgePromptVersion else {
                throw EvaluationStoreError.invalidSuite(
                    "Only an assessment using the current judge prompt can become a known-good judge check."
                )
            }
        }
        let correction = EvaluationHumanCorrection(
            id: UUID(), runID: runID, assessmentID: assessmentID, sampleID: sampleID,
            originalStatus: sample.status, originalScore: sample.score,
            correctedStatus: correctedStatus, correctedScore: correctedScore,
            reason: trimmed, reviewer: reviewer, createdAt: Date()
        )
        var candidateState = suiteLocalState
        candidateState.humanCorrections.append(correction)
        if collectAsJudgeCheck {
            candidateState.reviewedJudgeExamples.append(.init(
                id: UUID(), sourceRunID: runID, sourceAssessmentID: assessmentID,
                sampleID: sampleID, expectedStatus: correctedStatus, reason: trimmed, createdAt: Date(),
                scoringContract: assessment.scoringContract,
                subjectEvidenceDigest: assessment.subjectEvidenceDigest ?? run.subjectEvidence?.digest
            ))
        }
        let previousState = suiteLocalState
        suiteLocalState = candidateState
        do {
            try persistSuiteLocalState()
        } catch {
            suiteLocalState = previousState
            throw error
        }
    }

    func runJudgeChecks(connectionID: UUID) {
        guard !isReassessing else { return }
        isReassessing = true
        Task { [weak self] in
            guard let self else { return }
            defer { isReassessing = false }
            do {
                let resolved = try resolvedJudge(connectionID: connectionID)
                let sources = suiteLocalState.reviewedJudgeExamples.map { example -> EvaluationJudgeCheckSource in
                    do {
                        guard let run = self.runs.first(where: { $0.id == example.sourceRunID }),
                              let assessment = run.assessments?.first(where: { $0.id == example.sourceAssessmentID }) else {
                            throw EvaluationStoreError.resourceNotFound("Reviewed judge example")
                        }
                        let context = try self.reassessmentContext(for: run, scoringSuite: self.suite)
                        guard example.subjectEvidenceDigest == nil
                                || example.subjectEvidenceDigest == context.evidence.digest,
                              example.scoringContract == nil
                                || example.scoringContract == assessment.scoringContract else {
                            throw EvaluationStoreError.resourceConflict(
                                "The reviewed example's saved evidence or scoring contract changed."
                            )
                        }
                        var replaySuite = context.suite
                        replaySuite.criteria = assessment.rubric
                        replaySuite.scoringMode = assessment.scoringContract?.scoringMode ?? run.scoringMode
                        return .init(
                            example: example, run: run, assessment: assessment,
                            suite: replaySuite, images: context.images, errorMessage: nil
                        )
                    } catch {
                        return .init(
                            example: example, run: nil, assessment: nil, suite: nil,
                            images: [], errorMessage: error.localizedDescription
                        )
                    }
                }
                latestJudgeCheck = try await reassessmentService.checkJudge(
                    sources: sources,
                    resolved: resolved
                )
            } catch {
                notice = "Could not run judge checks: \(error.localizedDescription)"
            }
        }
    }

    func approveBaseline(runID: UUID, assessmentID: UUID?, note: String? = nil) throws {
        guard let run = runs.first(where: { $0.id == runID }),
              !run.cancelled, !run.stoppedEarly, run.results.count == run.plannedResultCount,
              run.subjectEvidence?.hasValidDigest != false else {
            throw EvaluationStoreError.resourceConflict("Only a complete saved run can become a baseline.")
        }
        let scoringContract: EvaluationScoringContract
        if run.scoringMode == .modelJudge {
            guard let assessmentID,
                  let assessment = run.assessments?.first(where: { $0.id == assessmentID }),
                  assessment.runID == run.id,
                  assessment.samples.count == run.results.count,
                  Set(assessment.samples.map(\.sampleID)) == Set(run.results.map(\.id)),
                  assessment.samples.allSatisfy({ $0.status == .passed || $0.status == .failed }),
                  (assessment.observedJudgeIdentities ?? [assessment.judge]).count == 1,
                  run.subjectEvidence == nil
                    || assessment.subjectEvidenceDigest == run.subjectEvidence?.digest else {
                throw EvaluationStoreError.resourceConflict("Choose a complete, fully scored assessment before approving the baseline.")
            }
            let derivedContract = try EvaluationScoringContract(
                scoringMode: run.scoringMode,
                rubricCriteria: assessment.rubric
                    .split(whereSeparator: \Character.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                judgePromptVersion: assessment.promptVersion,
                judgePassingScore: assessment.passingScore,
                cases: run.plannedCases ?? run.suiteDefinition?.cases ?? []
            )
            if let captured = assessment.scoringContract {
                guard captured == derivedContract else {
                    throw EvaluationStoreError.resourceConflict(
                        "The assessment's saved scoring contract does not match its rubric or judge policy."
                    )
                }
                scoringContract = captured
            } else {
                scoringContract = derivedContract
            }
        } else {
            scoringContract = try EvaluationScoringContract(run: run)
        }
        let now = Date()
        var candidateState = suiteLocalState
        for index in candidateState.baselineApprovals.indices where candidateState.baselineApprovals[index].isCurrent {
            candidateState.baselineApprovals[index].revokedAt = now
        }
        candidateState.baselineApprovals.append(.init(
            id: UUID(), runID: runID, assessmentID: assessmentID,
            suiteRevision: run.suiteRevision ?? "legacy", approvedAt: now,
            note: note, revokedAt: nil, scoringContract: scoringContract
        ))
        let previousState = suiteLocalState
        suiteLocalState = candidateState
        do {
            try persistSuiteLocalState()
        } catch {
            suiteLocalState = previousState
            throw error
        }
    }

    func createInstructionExperiment(name: String, candidateInstructions: String) throws -> UUID {
        try requireIdle()
        let trimmed = candidateInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != suite.instructions else {
            throw EvaluationStoreError.invalidSuite("Enter candidate instructions that differ from the current instructions.")
        }
        let sourceRevision = try currentSuiteRevision()
        var candidateSuite = suite
        candidateSuite.instructions = trimmed
        let current = EvaluationExperimentVariant(
            id: UUID(), name: "Current", instructions: suite.instructions,
            suiteRevision: sourceRevision
        )
        let candidate = EvaluationExperimentVariant(
            id: UUID(), name: "Candidate", instructions: trimmed,
            suiteRevision: try Self.revision(for: candidateSuite)
        )
        let experiment = EvaluationExperiment(
            id: UUID(), name: name, createdAt: Date(), suiteRevision: sourceRevision,
            casesDigest: Self.sha256(try CanonicalJSON.data(for: suite.cases, prettyPrinted: false)),
            scoringDigest: Self.sha256(try CanonicalJSON.data(for: [suite.scoringMode.rawValue, suite.criteria], prettyPrinted: false)),
            judgeDigest: Self.sha256(try CanonicalJSON.data(for: suite.judgeConfiguration, prettyPrinted: false)),
            current: current, candidate: candidate,
            executionOrder: EvaluationExperimentAnalyzer.balancedOrder(
                currentID: current.id, candidateID: candidate.id,
                caseCount: suite.cases.count, repetitions: suite.repetitions
            ),
            runIDs: [], decision: nil
        )
        let previousState = suiteLocalState
        suiteLocalState.experiments.append(experiment)
        do {
            try persistSuiteLocalState()
        } catch {
            suiteLocalState = previousState
            throw error
        }
        return experiment.id
    }

    func decideExperiment(id: UUID, decision: EvaluationExperimentDecision) throws {
        try requireWorkspaceWritable()
        guard let index = suiteLocalState.experiments.firstIndex(where: { $0.id == id }) else {
            throw EvaluationStoreError.resourceNotFound("Experiment")
        }
        var previousDraft = draftSuite
        var adoptionSnapshot: CandidateAdoptionSnapshot?
        if decision == .adoptCandidate {
            guard suiteLocalState.experiments[index].suiteRevision == suiteRevision else {
                throw EvaluationStoreError.resourceConflict(
                    "The suite changed after this experiment was frozen. Create a new experiment before adopting a candidate."
                )
            }
            applyPendingPromptEdits()
            previousDraft = draftSuite
            let snapshot = try candidateAdoptionSnapshot()
            adoptionSnapshot = snapshot
            draftSuite.instructions = suiteLocalState.experiments[index].candidate.instructions
            guard saveSuite() else {
                let failure = notice ?? "The candidate could not be saved."
                try restoreDraftAfterFailedSave(
                    previousDraft,
                    fileSnapshot: snapshot.draftFile,
                    failureMessage: failure
                )
                if snapshot.hadPendingDraftSave {
                    scheduleSuiteSave()
                }
                throw EvaluationStoreError.invalidSuite(failure)
            }
        }
        let previousState = suiteLocalState
        suiteLocalState.experiments[index].decision = decision
        do {
            try persistSuiteLocalState()
        } catch {
            let decisionError = error
            suiteLocalState = previousState
            if let adoptionSnapshot {
                try restoreCandidateAdoption(
                    adoptionSnapshot,
                    failureMessage: "The experiment decision could not be saved: \(decisionError.localizedDescription)"
                )
            }
            throw decisionError
        }
    }

    func runExperiment(id: UUID) {
        do {
            try requireIdle()
            guard let experiment = suiteLocalState.experiments.first(where: { $0.id == id }) else {
                throw EvaluationStoreError.resourceNotFound("Experiment")
            }
            guard experiment.suiteRevision == suiteRevision else {
                throw EvaluationStoreError.resourceConflict(
                    "The suite changed after this experiment was frozen. Create a new experiment for the current definition."
                )
            }
            let externalJudge = try resolvedJudge(for: suite)
            let suiteSnapshot = suite
            let images = try imageInputs(for: suiteSnapshot)
            let ownerProjectID = selectedProjectID
            let ownerSuiteID = selectedSuiteID
            let repositoryRoot = selectedProject.repository?.rootPath
            isRunning = true
            completedSamples = 0
            totalSamples = experiment.executionOrder.count
            runTask = Task { [weak self] in
                guard let self else { return }
                var createdRunIDs: [UUID] = []
                do {
                    let repositorySnapshot: EvaluationRepositorySnapshot? = if let repositoryRoot {
                        await EvaluationRepositoryInspector.snapshot(rootPath: repositoryRoot)
                    } else {
                        nil
                    }
                    var outcome = try await experimentRunner.run(
                        suite: suiteSnapshot,
                        experiment: experiment,
                        images: images,
                        externalJudge: externalJudge
                    ) { [weak self] _, completed, total in
                        await self?.updateExperimentProgress(completed: completed, total: total)
                    }
                    outcome.current.projectID = ownerProjectID
                    outcome.current.repository = repositorySnapshot
                    outcome.candidate.projectID = ownerProjectID
                    outcome.candidate.repository = repositorySnapshot
                    createdRunIDs = [outcome.current.id, outcome.candidate.id]
                    var currentSuite = suiteSnapshot
                    currentSuite.instructions = experiment.current.instructions
                    let currentEvidence = try snapshotSubjectEvidence(
                        runID: outcome.current.id,
                        suite: currentSuite,
                        projectID: ownerProjectID,
                        suiteID: ownerSuiteID
                    )
                    var candidateSuite = suiteSnapshot
                    candidateSuite.instructions = experiment.candidate.instructions
                    let candidateEvidence = try snapshotSubjectEvidence(
                        runID: outcome.candidate.id,
                        suite: candidateSuite,
                        projectID: ownerProjectID,
                        suiteID: ownerSuiteID
                    )
                    outcome.current.subjectEvidence = currentEvidence
                    outcome.candidate.subjectEvidence = candidateEvidence
                    if let index = outcome.current.assessments?.indices.first {
                        outcome.current.assessments?[index].subjectEvidenceDigest = currentEvidence.digest
                    }
                    if let index = outcome.candidate.assessments?.indices.first {
                        outcome.candidate.assessments?[index].subjectEvidenceDigest = candidateEvidence.digest
                    }
                    outcome.candidate = runPreparedForHistory(outcome.candidate)
                    outcome.current = runPreparedForHistory(outcome.current)
                    try persistRun(outcome.current)
                    try persistRun(outcome.candidate)
                    runs.removeAll { $0.id == outcome.current.id || $0.id == outcome.candidate.id }
                    runs.insert(outcome.candidate, at: 0)
                    runs.insert(outcome.current, at: 0)
                    if let index = suiteLocalState.experiments.firstIndex(where: { $0.id == id }) {
                        let previousRunIDs = suiteLocalState.experiments[index].runIDs
                        suiteLocalState.experiments[index].runIDs = [outcome.current.id, outcome.candidate.id]
                        do {
                            try persistSuiteLocalState()
                        } catch {
                            suiteLocalState.experiments[index].runIDs = previousRunIDs
                            throw error
                        }
                    }
                    createdRunIDs = []
                    selection = .run(outcome.candidate.id)
                } catch is CancellationError {
                    cleanupIncompleteRuns(
                        ids: createdRunIDs, projectID: ownerProjectID, suiteID: ownerSuiteID
                    )
                    notice = "The experiment was cancelled before either variant became evidence."
                } catch {
                    cleanupIncompleteRuns(
                        ids: createdRunIDs, projectID: ownerProjectID, suiteID: ownerSuiteID
                    )
                    notice = "The experiment could not complete: \(error.localizedDescription)"
                }
                isRunning = false
                runTask = nil
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func releaseCheckReport(runID: UUID?) -> EvaluationReleaseCheckReport {
        let run: EvaluationRun?
        if let runID {
            run = runs.first { $0.id == runID }
        } else {
            run = runs.first
        }
        let approval = activeBaselineApproval
        let baseline = approval.flatMap { approval in runs.first { $0.id == approval.runID } }
        return EvaluationReleaseCheckEvaluator.report(
            projectID: selectedProjectID, suite: suite, currentSuiteRevision: suiteRevision, run: run,
            baseline: baseline, approvedBaseline: approval
        )
    }

    func projectReleaseCheckReport(projectID: UUID) throws -> EvaluationProjectReleaseCheckReport {
        guard let project = workspace.projects.first(where: { $0.id == projectID && !$0.isArchived }) else {
            throw EvaluationWorkspaceError.missingProject
        }
        var suiteReports: [EvaluationProjectReleaseSuiteReport] = []
        for record in project.suites where !record.isArchived {
            let directory = EvaluationWorkspacePersistence.suiteDirectory(
                supportDirectory: supportDirectory,
                projectID: project.id,
                suiteID: record.id
            )
            guard let resolved = try? Self.resolveSuiteForProjectReleaseReport(
                project: project,
                record: record,
                directory: directory
            ) else {
                let unavailable = EvaluationReleaseCheckReport(
                    projectID: project.id,
                    suiteID: record.id,
                    runID: nil,
                    assessmentID: nil,
                    outcome: .incompleteOrIncompatibleEvidence,
                    summary: "The suite definition is unavailable or unreadable.",
                    failures: ["Restore the saved suite definition before evaluating project readiness."],
                    generatedAt: Date()
                )
                suiteReports.append(.init(
                    suiteID: record.id,
                    suiteName: record.name,
                    required: true,
                    report: unavailable
                ))
                continue
            }
            let storedSuite = resolved.suite
            let revision = resolved.revision
            guard storedSuite.releasePolicy.required else { continue }
            let loadedRuns = Self.loadRuns(
                from: directory.appending(path: "Runs", directoryHint: .isDirectory),
                projectID: project.id,
                suiteID: record.id
            )
            if loadedRuns.hasUnreadableFiles {
                let unavailable = EvaluationReleaseCheckReport(
                    projectID: project.id,
                    suiteID: record.id,
                    runID: nil,
                    assessmentID: nil,
                    outcome: .incompleteOrIncompatibleEvidence,
                    summary: "The required suite has unreadable run evidence.",
                    failures: ["Restore or remove the unreadable run record before evaluating project readiness."],
                    generatedAt: Date()
                )
                suiteReports.append(.init(
                    suiteID: record.id,
                    suiteName: storedSuite.name,
                    required: true,
                    report: unavailable
                ))
                continue
            }
            let storedRuns = loadedRuns.runs
            let loadedLocalState = EvaluationWorkspaceStatePersistence.loadSuiteLocalState(
                from: directory.appending(path: "state.json"),
                preserveUnreadable: false
            )
            if loadedLocalState.notice != nil {
                let unavailable = EvaluationReleaseCheckReport(
                    projectID: project.id,
                    suiteID: record.id,
                    runID: nil,
                    assessmentID: nil,
                    outcome: .incompleteOrIncompatibleEvidence,
                    summary: "The required suite has unreadable local approval state.",
                    failures: ["Restore the unreadable suite state before evaluating project readiness."],
                    generatedAt: Date()
                )
                suiteReports.append(.init(
                    suiteID: record.id,
                    suiteName: storedSuite.name,
                    required: true,
                    report: unavailable
                ))
                continue
            }
            let approval = loadedLocalState.state.baselineApprovals.last(where: \.isCurrent)
            let baseline = approval.flatMap { approved in storedRuns.first { $0.id == approved.runID } }
            let report = EvaluationReleaseCheckEvaluator.report(
                projectID: project.id,
                suite: storedSuite,
                currentSuiteRevision: revision,
                run: storedRuns.first,
                baseline: baseline,
                approvedBaseline: approval
            )
            suiteReports.append(.init(
                suiteID: record.id,
                suiteName: storedSuite.name,
                required: true,
                report: report
            ))
        }
        return EvaluationReleaseCheckEvaluator.projectReport(
            projectID: project.id,
            suites: suiteReports
        )
    }

    /// Resolves repository-authored changes without persisting them. Project
    /// release reporting is a read-only MCP operation and must still observe
    /// nonselected linked suites or fail closed when either side has diverged.
    private nonisolated static func resolveSuiteForProjectReleaseReport(
        project: EvaluationProject,
        record: EvaluationSuiteRecord,
        directory: URL
    ) throws -> (suite: EvaluationSuite, revision: String) {
        let localURL = directory.appending(path: "suite.json")
        let localSuite = try CanonicalJSON.decode(EvaluationSuite.self, from: Data(contentsOf: localURL))
        guard localSuite.id == record.id else { throw EvaluationWorkspaceError.missingSuite }

        var resolvedSuite = localSuite
        if record.repositoryDefinitionPath != nil {
            guard let repositoryURL = EvaluationWorkspacePersistence.repositoryDefinitionURL(
                project: project,
                suite: record
            ), FileManager.default.fileExists(atPath: repositoryURL.path) else {
                throw EvaluationWorkspaceError.invalidRepositoryPath
            }
            let definition = try CanonicalJSON.decode(
                EvaluationSuiteDefinition.self,
                from: Data(contentsOf: repositoryURL)
            )
            guard definition.formatVersion == EvaluationSuiteDefinition.currentFormatVersion,
                  definition.id == localSuite.id else {
                throw EvaluationStoreError.resourceConflict(
                    "The repository definition has the wrong format or suite ID."
                )
            }
            let repositoryRevision = try EvaluationWorkspacePersistence.definitionRevision(definition)
            if repositoryRevision != record.lastRepositoryRevision {
                let localRevision = try EvaluationWorkspacePersistence.definitionRevision(
                    EvaluationSuiteDefinition(suite: localSuite)
                )
                guard localRevision == record.lastRepositoryRevision else {
                    throw EvaluationWorkspaceError.repositoryConflict
                }
                resolvedSuite = definition.applyingLocalState(from: localSuite)
            }
        }
        return (resolvedSuite, try revision(for: resolvedSuite))
    }

    /// In-process integration point for exercising application feature code.
    /// The resulting run is persisted into the selected suite's normal history,
    /// so reassessment, comparison, baseline approval, and release checks use it.
    func runFeatureAdapter(
        id: UUID = UUID(),
        expectedRevision: String,
        adapter: any EvaluationFeatureAdapter,
        progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> EvaluationRun {
        if let existing = run(with: id) {
            guard existing.projectID == selectedProjectID,
                  existing.suiteID == selectedSuiteID,
                  existing.suiteRevision == expectedRevision else {
                throw EvaluationStoreError.resourceConflict(
                    "Feature run ID already belongs to another project, suite, or revision."
                )
            }
            return existing
        }
        try requireIdle()
        try requireRevision(expectedRevision)
        guard validationIssue(for: suite, includeModelReadiness: false) == nil else {
            throw EvaluationStoreError.invalidSuite(
                validationIssue(for: suite, includeModelReadiness: false)
                    ?? "The suite is not ready for a feature-adapter run."
            )
        }
        let suiteSnapshot = suite
        let ownerProjectID = selectedProjectID
        let ownerSuiteID = selectedSuiteID
        let evidence = try snapshotSubjectEvidence(
            runID: id,
            suite: suiteSnapshot,
            projectID: ownerProjectID,
            suiteID: ownerSuiteID
        )
        isRunning = true
        completedSamples = 0
        totalSamples = suiteSnapshot.cases.count * suiteSnapshot.repetitions
        defer {
            isRunning = false
            completedSamples = 0
            totalSamples = 0
        }
        let repositorySnapshot: EvaluationRepositorySnapshot? = if let root = selectedProject.repository?.rootPath {
            await EvaluationRepositoryInspector.snapshot(rootPath: root)
        } else {
            nil
        }
        var run = await featureAdapterRunner.run(
            id: id,
            projectID: ownerProjectID,
            repository: repositorySnapshot,
            suiteRevision: expectedRevision,
            suite: suiteSnapshot,
            adapter: adapter
        ) { [weak self] _, completed, total in
            await self?.updateFeatureAdapterProgress(completed: completed, total: total)
            await progress(completed, total)
        }
        run.subjectEvidence = evidence
        run = runPreparedForHistory(run)
        do {
            try persistRun(run)
        } catch {
            try? FileManager.default.removeItem(at: runEvidenceDirectory(
                projectID: ownerProjectID,
                suiteID: ownerSuiteID,
                runID: id
            ))
            throw error
        }
        runs.removeAll { $0.id == run.id }
        runs.insert(run, at: 0)
        selection = .run(run.id)
        return run
    }

    func runDeveloperFeature(
        id: UUID = UUID(),
        expectedRevision: String,
        runner: DeveloperRunnerSnapshot,
        feature: DeveloperFeatureDescriptor,
        client: DeveloperRunnerClient,
        timeout: Duration = .seconds(120),
        progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> EvaluationRun {
        let adapter = EvaluationDeveloperFeatureAdapter(
            runID: id,
            runner: runner,
            feature: feature,
            client: client,
            timeout: timeout
        )
        return try await runFeatureAdapter(
            id: id,
            expectedRevision: expectedRevision,
            adapter: adapter,
            progress: progress
        )
    }

    private func updateFeatureAdapterProgress(completed: Int, total: Int) {
        completedSamples = completed
        totalSamples = total
    }

    private func updateExperimentProgress(completed: Int, total: Int) {
        completedSamples = completed
        totalSamples = total
    }

    private func cleanupIncompleteRuns(ids: [UUID], projectID: UUID, suiteID: UUID) {
        let directory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: supportDirectory,
            projectID: projectID,
            suiteID: suiteID
        )
        for id in ids {
            try? FileManager.default.removeItem(
                at: directory.appending(path: "Runs/\(id.uuidString).json")
            )
            try? FileManager.default.removeItem(
                at: runEvidenceDirectory(projectID: projectID, suiteID: suiteID, runID: id)
            )
            runs.removeAll { $0.id == id }
        }
    }

    // MARK: Repository definitions

    func linkSelectedProject(toRepository rootPath: String) throws {
        try requireIdle()
        let root = URL(filePath: rootPath, directoryHint: .isDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.fileExists(atPath: root.appending(path: ".git").path) else {
            throw EvaluationStoreError.resourceConflict("Choose the root of a Git repository.")
        }
        let repository = EvaluationRepositoryLink(rootPath: root.path)
        let filename = "\(Self.repositorySlug(suite.name))-\(suite.id.uuidString.lowercased()).json"
        let relativePath = repository.definitionsDirectory + "/" + filename
        guard EvaluationWorkspacePersistence.safeRelativePath(relativePath) else {
            throw EvaluationWorkspaceError.invalidRepositoryPath
        }
        let definitionURL = root.appending(path: relativePath)
        let definition = EvaluationSuiteDefinition(suite: suite)
        let revision = try EvaluationWorkspacePersistence.definitionRevision(definition)
        var createdDefinition = false
        if FileManager.default.fileExists(atPath: definitionURL.path) {
            let existing = try CanonicalJSON.decode(
                EvaluationSuiteDefinition.self,
                from: Data(contentsOf: definitionURL)
            )
            guard existing == definition else {
                throw EvaluationStoreError.resourceConflict(
                    "A repository definition already exists at \(relativePath). Import or rename it explicitly."
                )
            }
        } else {
            try FileManager.default.createDirectory(
                at: definitionURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try CanonicalJSON.data(for: definition).write(to: definitionURL, options: .atomic)
            createdDefinition = true
        }

        let previousWorkspace = workspace
        do {
            guard let projectIndex = workspace.projects.firstIndex(where: { $0.id == selectedProjectID }),
                  let suiteIndex = workspace.projects[projectIndex].suites.firstIndex(where: {
                      $0.id == selectedSuiteID
                  }) else {
                throw EvaluationWorkspaceError.missingSuite
            }
            let now = Date()
            workspace.projects[projectIndex].repository = repository
            workspace.projects[projectIndex].updatedAt = now
            workspace.projects[projectIndex].suites[suiteIndex].repositoryDefinitionPath = relativePath
            workspace.projects[projectIndex].suites[suiteIndex].lastRepositoryRevision = revision
            workspace.projects[projectIndex].suites[suiteIndex].updatedAt = now
            try persistWorkspace()
        } catch {
            workspace = previousWorkspace
            if createdDefinition {
                try? FileManager.default.removeItem(at: definitionURL)
            }
            throw error
        }
    }

    func linkSelectedSuiteDefinition(filename: String) throws {
        try requireIdle()
        guard let repository = selectedProject.repository else {
            throw EvaluationStoreError.resourceConflict("Link the project to a repository first.")
        }
        let relativePath = repository.definitionsDirectory + "/" + filename
        guard EvaluationWorkspacePersistence.safeRelativePath(relativePath) else {
            throw EvaluationWorkspaceError.invalidRepositoryPath
        }
        let url = URL(filePath: repository.rootPath, directoryHint: .isDirectory).appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let definition = EvaluationSuiteDefinition(suite: suite)
        let revision = try EvaluationWorkspacePersistence.definitionRevision(definition)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try CanonicalJSON.decode(EvaluationSuiteDefinition.self, from: Data(contentsOf: url))
            guard existing == definition else {
                throw EvaluationStoreError.resourceConflict("A repository definition already exists at \(relativePath). Import or rename it explicitly.")
            }
            try updateSelectedSuiteRecord { record in
                record.repositoryDefinitionPath = relativePath
                record.lastRepositoryRevision = revision
                record.updatedAt = Date()
            }
            return
        }
        try CanonicalJSON.data(for: definition).write(to: url, options: .atomic)
        do {
            try updateSelectedSuiteRecord { record in
                record.repositoryDefinitionPath = relativePath
                record.lastRepositoryRevision = revision
                record.updatedAt = Date()
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func applyingRepositoryChanges(to localSuite: EvaluationSuite) throws -> EvaluationSuite {
        guard let url = EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: selectedProject, suite: selectedSuiteRecord
        ), FileManager.default.fileExists(atPath: url.path) else { return localSuite }
        let definition = try CanonicalJSON.decode(EvaluationSuiteDefinition.self, from: Data(contentsOf: url))
        guard definition.formatVersion == EvaluationSuiteDefinition.currentFormatVersion,
              definition.id == localSuite.id else {
            throw EvaluationStoreError.resourceConflict("The repository definition has the wrong format or suite ID.")
        }
        let repoRevision = try EvaluationWorkspacePersistence.definitionRevision(definition)
        guard repoRevision != selectedSuiteRecord.lastRepositoryRevision else { return localSuite }
        let localRevision = try EvaluationWorkspacePersistence.definitionRevision(EvaluationSuiteDefinition(suite: localSuite))
        guard localRevision == selectedSuiteRecord.lastRepositoryRevision else {
            throw EvaluationWorkspaceError.repositoryConflict
        }
        let updated = definition.applyingLocalState(from: localSuite)
        try CanonicalJSON.data(for: updated).write(to: suiteDirectory.appending(path: "suite.json"), options: .atomic)
        try updateSelectedSuiteRecord { record in
            record.lastRepositoryRevision = repoRevision
            record.name = updated.name
            record.updatedAt = Date()
        }
        return updated
    }

    private func repositoryDefinitionChangedOutsideApp() throws -> Bool {
        guard let url = EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: selectedProject, suite: selectedSuiteRecord
        ), FileManager.default.fileExists(atPath: url.path) else { return false }
        let definition = try CanonicalJSON.decode(EvaluationSuiteDefinition.self, from: Data(contentsOf: url))
        let revision = try EvaluationWorkspacePersistence.definitionRevision(definition)
        return revision != selectedSuiteRecord.lastRepositoryRevision
    }

    private func updateSelectedSuiteRecord(_ mutation: (inout EvaluationSuiteRecord) -> Void) throws {
        try updateProject(selectedProjectID) { project in
            guard let index = project.suites.firstIndex(where: { $0.id == selectedSuiteID }) else { return }
            mutation(&project.suites[index])
        }
    }



    var modelStatus: ModelStatus {
        modelStatus(for: draftSuite)
    }

    func modelStatus(for candidate: EvaluationSuite) -> ModelStatus {
        switch candidate.modelConfiguration.provider {
        case .onDevice:
            return switch candidate.modelConfiguration.systemModel.availability {
            case .available:
                ModelStatus(isAvailable: true, label: "On-device model ready", detail: "Prompts and reference-tool lookups stay on this Mac.")
            case .unavailable(.deviceNotEligible):
                ModelStatus(isAvailable: false, label: "Device not eligible", detail: "This Mac does not support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                ModelStatus(isAvailable: false, label: "Apple Intelligence off", detail: "Enable Apple Intelligence in System Settings.")
            case .unavailable(.modelNotReady):
                ModelStatus(isAvailable: false, label: "Model not ready", detail: "The model may still be downloading.")
            case .unavailable:
                ModelStatus(isAvailable: false, label: "Model unavailable", detail: "The model is unavailable for an unknown reason.")
            }
        case .privateCloudCompute:
            guard Self.hasAuthorizedPrivateCloudComputeSignature else {
                return ModelStatus(
                    isAvailable: false,
                    label: "Approved cloud signature required",
                    detail: "Sign a Release build with a non-ad-hoc Apple Development or Distribution identity approved for the managed Private Cloud Compute entitlement."
                )
            }
            let model = PrivateCloudComputeLanguageModel()
            if model.quotaUsage.isLimitReached {
                return ModelStatus(
                    isAvailable: false,
                    label: "Cloud quota reached",
                    detail: model.quotaUsage.resetDate.map { "Quota resets \($0.formatted(date: .abbreviated, time: .shortened))." }
                        ?? "Private Cloud Compute quota is currently exhausted."
                )
            }
            switch model.availability {
            case .available:
                guard cloudContextSize != nil else {
                    return ModelStatus(
                        isAvailable: false,
                        label: isRefreshingCloud ? "Checking cloud model" : "Cloud metadata needed",
                        detail: cloudMetadataError ?? "Refresh cloud status to load the model's context capacity before running."
                    )
                }
                return ModelStatus(
                    isAvailable: true,
                    label: "Cloud model ready",
                    detail: "Requests use Apple's Private Cloud Compute over the network and consume quota."
                )
            case .unavailable(.deviceNotEligible):
                return ModelStatus(isAvailable: false, label: "Device not eligible", detail: "This Mac is not eligible for Private Cloud Compute model requests.")
            case .unavailable(.systemNotReady):
                return ModelStatus(isAvailable: false, label: "Cloud model not ready", detail: "Check the network connection and Private Cloud Compute entitlement.")
            case .unavailable:
                return ModelStatus(isAvailable: false, label: "Cloud model unavailable", detail: "Private Cloud Compute is unavailable for an unknown reason.")
            }
        case .customHTTP:
            let configuration = candidate.modelConfiguration.customProviderSettings
            if let issue = configuration.validationIssue {
                return ModelStatus(isAvailable: false, label: "Custom provider needs setup", detail: issue)
            }
            return ModelStatus(isAvailable: true, label: "Custom provider configured", detail: "The local endpoint will be contacted when a run starts. Availability and declared capabilities have not been verified by this status.")
        case .coreAI:
            if let loaded = coreAIModel(for: candidate) {
                return ModelStatus(isAvailable: true, label: "Core AI model loaded", detail: "\(loaded.modelName) · \(loaded.contextSize.formatted()) token context. Runs locally on this Mac.")
            }
            if candidate.modelConfiguration.coreAISettings == loadedCoreAIConfiguration {
                if case .failed(let message) = coreAILoadStatus {
                    return ModelStatus(isAvailable: false, label: "Core AI model could not load", detail: message)
                }
                if coreAILoadStatus == .loading {
                    return ModelStatus(isAvailable: false, label: "Core AI model loading", detail: "Loading and validating the selected model. Run becomes available after loading succeeds.")
                }
            }
            return ModelStatus(isAvailable: false, label: "Core AI model needs loading", detail: "Choose and load a Core AI language model resource folder before running.")
        }
    }

    var selectedModelCapabilities: LanguageModelCapabilities {
        selectedModelCapabilities(for: draftSuite)
    }

    func selectedModelCapabilities(for candidate: EvaluationSuite) -> LanguageModelCapabilities {
        switch candidate.modelConfiguration.provider {
        case .onDevice: candidate.modelConfiguration.systemModel.capabilities
        case .privateCloudCompute: PrivateCloudComputeLanguageModel().capabilities
        case .customHTTP: candidate.modelConfiguration.customProviderSettings.capabilities
        case .coreAI: coreAIModel(for: candidate)?.capabilities ?? LanguageModelCapabilities([])
        }
    }

    var coreAIControlStatus: CoreAIModelControlStatus {
        guard draftSuite.modelConfiguration.coreAISettings == loadedCoreAIConfiguration else {
            return draftSuite.modelConfiguration.coreAISettings.hasResources ? .readyToLoad : .unconfigured
        }
        return coreAILoadStatus
    }

    func loadCoreAIModel() async {
        guard !isRunning, draftSuite.modelConfiguration.provider == .coreAI else { return }
        let configuration = draftSuite.modelConfiguration.coreAISettings
        loadedCoreAI = nil
        loadedCoreAIConfiguration = configuration
        coreAILoadStatus = .loading
        do {
            let result = try await CoreAIModelLoader.shared.load(configuration: configuration)
            guard loadedCoreAIConfiguration == configuration else { return }
            loadedCoreAI = result
            coreAILoadStatus = .loaded(CoreAIModelDescriptor(result: result))
        } catch {
            guard loadedCoreAIConfiguration == configuration else { return }
            coreAILoadStatus = .failed(error.localizedDescription)
        }
    }

    private func coreAIModel(for candidate: EvaluationSuite) -> CoreAIModelLoadResult? {
        candidate.modelConfiguration.coreAISettings == loadedCoreAIConfiguration ? loadedCoreAI : nil
    }

    func refreshCloudMetadata() async {
        guard !isRunning, !isRefreshingCloud,
              Self.hasAuthorizedPrivateCloudComputeSignature else { return }
        isRefreshingCloud = true
        cloudMetadataError = nil
        defer { isRefreshingCloud = false }
        do {
            let size = try await PrivateCloudComputeLanguageModel().contextSize
            guard size > 0 else {
                cloudContextSize = nil
                cloudMetadataError = "The cloud model reported an invalid context capacity."
                return
            }
            cloudContextSize = size
        } catch {
            cloudContextSize = nil
            cloudMetadataError = "Could not load cloud metadata: \(error.localizedDescription)"
        }
    }

    private func contextSize(for candidate: EvaluationSuite) -> Int {
        switch candidate.modelConfiguration.provider {
        case .onDevice: onDeviceContextSizes.value(for: candidate.modelConfiguration)
        case .customHTTP: candidate.modelConfiguration.customProviderSettings.contextSize
        case .coreAI: coreAIModel(for: candidate)?.contextSize ?? 0
        case .privateCloudCompute: cloudContextSize ?? 0
        }
    }

    var plannedSampleCount: Int {
        draftSuite.cases.count.nonnegativeSaturatedMultiplying(draftSuite.repetitions)
    }

    var plannedRequestCount: Int {
        let requestsPerRepetition = draftSuite.cases.reduce(0) {
            $0.saturatedAdding($1.conversation.setupTurns.count).saturatedAdding(1)
        }
        let subjectRequests = draftSuite.repetitions.nonnegativeSaturatedMultiplying(
            requestsPerRepetition
        )
        let judgeRequests = draftSuite.needsModelJudge
            ? plannedSampleCount.nonnegativeSaturatedMultiplying(2)
            : 0
        return subjectRequests.saturatedAdding(judgeRequests)
    }

    var plannedToolCallLimit: Int {
        draftSuite.hasConfiguredTools
            ? plannedSampleCount.nonnegativeSaturatedMultiplying(
                draftSuite.modelConfiguration.maximumToolCalls
            )
            : 0
    }

    var remainingCaseImportCapacity: Int {
        let remainingCases = Self.maximumCases - draftSuite.cases.count
        let maximumCasesBySamples = Self.maximumPlannedSamples / max(draftSuite.repetitions, 1)
        return max(0, min(remainingCases, maximumCasesBySamples - draftSuite.cases.count))
    }

    func appendImportedCases(_ imported: [EvaluationCase]) throws {
        try requireIdle()
        guard !imported.isEmpty else { return }
        let remaining = remainingCaseImportCapacity
        guard imported.count <= remaining else {
            throw EvaluationCaseImportError.tooManyRows(maximum: remaining)
        }
        applyPendingPromptEdits()
        let previousDraft = draftSuite
        let previousDraftFile = try snapshotFile(at: draftSuiteURL)
        draftSuite.cases.append(contentsOf: imported)
        guard saveSuite() else {
            let failure = notice ?? "The imported cases could not be saved."
            try restoreDraftAfterFailedSave(
                previousDraft,
                fileSnapshot: previousDraftFile,
                failureMessage: failure
            )
            throw EvaluationStoreError.invalidSuite(failure)
        }
    }

    var hasUnsavedCompletedRun: Bool {
        unsavedRun != nil || (activeRun != nil && !isRunning)
    }

    var pendingRunSaveMessage: String? {
        guard hasUnsavedCompletedRun else { return nil }
        return "A finished run still needs to be saved to history. Restore storage access, then retry."
    }

    var runBlocker: String? {
        pendingRunSaveMessage ?? validationIssue(for: draftSuite)
    }

    var suiteRevision: String {
        (try? currentSuiteRevision()) ?? ""
    }

    func currentSuiteRevision() throws -> String {
        try Self.revision(for: suite)
    }

    func addCase() {
        guard allowWorkspaceMutation() else { return }
        guard draftSuite.cases.count < Self.maximumCases,
              draftSuite.cases.count < Self.maximumPlannedSamples / max(draftSuite.repetitions, 1) else {
            notice = "This suite has reached its planned-sample limit."
            return
        }
        draftSuite.cases.append(
            EvaluationCase(
                name: "Case \(draftSuite.cases.count + 1)",
                prompt: "",
                expected: ""
            )
        )
        _ = saveSuite()
    }

    func duplicateCase(id: UUID) {
        guard allowWorkspaceMutation() else { return }
        applyPendingPromptEdits()
        guard draftSuite.cases.count < Self.maximumCases,
              draftSuite.cases.count < Self.maximumPlannedSamples / max(draftSuite.repetitions, 1) else {
            notice = "This suite has reached its planned-sample limit."
            return
        }
        guard let index = draftSuite.cases.firstIndex(where: { $0.id == id }) else { return }
        var copy = draftSuite.cases[index]
        copy.id = UUID()
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Copied case"
            : "\(copy.name) copy"
        draftSuite.cases.insert(copy, at: index + 1)
        _ = saveSuite()
    }

    func removeCase(id: UUID) {
        guard allowWorkspaceMutation() else { return }
        guard draftSuite.cases.count > 1 else {
            notice = "An evaluation suite needs at least one case."
            return
        }
        draftSuite.cases.removeAll { $0.id == id }
        _ = saveSuite()
    }

    func replaceSuite(
        _ replacement: EvaluationSuite,
        expectedRevision: String,
        confirmDeletes: Bool
    ) throws -> String {
        try flushPendingSuiteSave()
        var candidate = replacement
        candidate.id = suite.id
        candidate.attachments = suite.attachments
        let candidateRevision = try Self.revision(for: candidate)
        let currentRevision = try currentSuiteRevision()
        if candidateRevision == currentRevision { return candidateRevision }

        try requireIdle()
        try requireRevision(expectedRevision)
        let removedCases = Set(suite.cases.map(\.id)).subtracting(replacement.cases.map(\.id))
        guard removedCases.isEmpty || confirmDeletes else {
            throw EvaluationStoreError.deletionConfirmationRequired
        }
        if let issue = validationIssue(for: candidate, includeModelReadiness: false) {
            throw EvaluationStoreError.invalidSuite(issue)
        }
        try commitSuite(candidate)
        draftSuite = candidate
        return try currentSuiteRevision()
    }

    func deleteRun(id: UUID) {
        do {
            _ = try deleteRunDurably(id: id)
        } catch {
            notice = "Could not delete the saved run: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func deleteRunDurably(id: UUID) throws -> Bool {
        try requireWorkspaceWritable()
        if activeRun?.id == id { throw EvaluationStoreError.runBusy }
        guard let location = persistedRunLocation(id: id) ?? pendingRunDeletionLocation(id: id) else {
            return false
        }
        let deletionDirectory = location.runURL.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "RunDeletions", directoryHint: .isDirectory)
        let deletionURL = deletionDirectory.appending(path: "\(id.uuidString).json")
        let isPending = location.runURL == deletionURL
        do {
            if !isPending {
                try FileManager.default.createDirectory(at: deletionDirectory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: location.runURL, to: deletionURL)
            }
            let evidenceURL = runEvidenceDirectory(
                projectID: location.projectID,
                suiteID: location.suiteID,
                runID: id
            )
            if FileManager.default.fileExists(atPath: evidenceURL.path) {
                try FileManager.default.removeItem(at: evidenceURL)
            }
            try FileManager.default.removeItem(at: deletionURL)
        } catch {
            // Once deletion starts, keep the run tombstoned. Cleanup can then
            // be retried by ID without re-exposing a run whose evidence may
            // already have been partly or completely removed.
            if FileManager.default.fileExists(atPath: deletionURL.path) {
                if location.projectID == selectedProjectID, location.suiteID == selectedSuiteID {
                    runs.removeAll { $0.id == id }
                }
                if selection == .run(id) { selection = .suite }
            }
            throw EvaluationStoreError.persistence(error.localizedDescription)
        }

        if location.projectID == selectedProjectID, location.suiteID == selectedSuiteID {
            runs.removeAll { $0.id == id }
        }
        if selection == .run(id) { selection = .suite }
        return true
    }

    var canResetWorkspace: Bool {
        !isRunning && !isReassessing && activeRun == nil && !isProcessingFiles && !isImportingFiles
    }

    /// A blank suite is intentionally incomplete; execution still validates it before running.
    func resetSuite() throws {
        try requireIdle()
        guard !isImportingFiles else { throw EvaluationStoreError.fileOperationBusy }
        var blank = EvaluationSuite()
        blank.id = selectedSuiteID
        blank.name = "Untitled Suite"
        blank.instructions = ""
        blank.criteria = ""
        blank.scoringMode = .review
        blank.cases = [EvaluationCase(name: "Case 1", prompt: "", expected: "")]

        let previousSuite = suite
        let previousDraft = draftSuite
        let previousWorkspace = workspace
        let previousSelection = selection
        let previousNotice = notice
        let previousDraftSaveFailed = draftSaveFailed
        let suiteURL = suiteDirectory.appending(path: "suite.json")
        let catalogURL = supportDirectory.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        let repositoryURL = EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: selectedProject,
            suite: selectedSuiteRecord
        )

        // Read every file that may be changed before creating directories or writing
        // the reset candidate. A failed snapshot is a no-op for the transaction.
        let previousSuiteFile = try snapshotFile(at: suiteURL)
        let previousCatalogFile = try snapshotFile(at: catalogURL)
        let previousRepositoryFile = try repositoryURL.map { try snapshotFile(at: $0) }

        let blankDefinition = EvaluationSuiteDefinition(suite: blank)
        let blankDefinitionData = try CanonicalJSON.data(for: blankDefinition)
        let blankDefinitionRevision = try EvaluationWorkspacePersistence.definitionRevision(blankDefinition)
        var repositoryData: Data?
        if repositoryURL != nil {
            if let previousRepositoryFile, previousRepositoryFile.existed {
                guard let previousData = previousRepositoryFile.data else {
                    throw EvaluationStoreError.persistence("The linked repository definition could not be read.")
                }
                let existing = try CanonicalJSON.decode(EvaluationSuiteDefinition.self, from: previousData)
                let existingRevision = try EvaluationWorkspacePersistence.definitionRevision(existing)
                if existingRevision != selectedSuiteRecord.lastRepositoryRevision,
                   existingRevision != blankDefinitionRevision {
                    throw EvaluationWorkspaceError.repositoryConflict
                }
                if existingRevision != blankDefinitionRevision {
                    repositoryData = blankDefinitionData
                }
            } else {
                repositoryData = blankDefinitionData
            }
        }

        let commitDate = Date()
        var committedWorkspace = workspace
        guard let projectIndex = committedWorkspace.projects.firstIndex(where: { $0.id == selectedProjectID }),
              let suiteIndex = committedWorkspace.projects[projectIndex].suites.firstIndex(where: { $0.id == selectedSuiteID }) else {
            throw EvaluationWorkspaceError.missingSuite
        }
        committedWorkspace.projects[projectIndex].suites[suiteIndex].name = blank.name
        committedWorkspace.projects[projectIndex].suites[suiteIndex].updatedAt = commitDate
        if repositoryURL != nil {
            committedWorkspace.projects[projectIndex].suites[suiteIndex].lastRepositoryRevision = blankDefinitionRevision
        }

        let blankSuiteData = try CanonicalJSON.data(for: blank)
        let committedCatalogData = try CanonicalJSON.data(for: committedWorkspace)
        do {
            try FileManager.default.createDirectory(at: suiteDirectory, withIntermediateDirectories: true)
            if let repositoryURL, let repositoryData {
                try FileManager.default.createDirectory(
                    at: repositoryURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try repositoryData.write(to: repositoryURL, options: .atomic)
            }
            try blankSuiteData.write(to: suiteURL, options: .atomic)
            try committedCatalogData.write(to: catalogURL, options: .atomic)

            // Publish in-memory state only after all persistent pieces commit.
            workspace = committedWorkspace
            suite = blank
            draftSuite = blank
        } catch {
            var rollbackErrors: [String] = []
            do { try restoreFile(previousCatalogFile) }
            catch { rollbackErrors.append("workspace catalog: \(error.localizedDescription)") }
            do { try restoreFile(previousSuiteFile) }
            catch { rollbackErrors.append("suite metadata: \(error.localizedDescription)") }
            if let previousRepositoryFile {
                do { try restoreFile(previousRepositoryFile) }
                catch { rollbackErrors.append("repository definition: \(error.localizedDescription)") }
            }

            suite = previousSuite
            draftSuite = previousDraft
            workspace = previousWorkspace
            selection = previousSelection
            notice = previousNotice
            draftSaveFailed = previousDraftSaveFailed
            if !rollbackErrors.isEmpty {
                throw EvaluationStoreError.persistence(
                    "\(error.localizedDescription) Rollback also failed for \(rollbackErrors.joined(separator: "; "))."
                )
            }
            if let storeError = error as? EvaluationStoreError { throw storeError }
            if let workspaceError = error as? EvaluationWorkspaceError { throw workspaceError }
            throw EvaluationStoreError.persistence(error.localizedDescription)
        }

        pendingPromptEdits.removeAll()
        draftSaveTask?.cancel()
        draftSaveTask = nil
        isDraftSavePending = false
        draftSaveFailed = false
        selection = .suite
        // Old drafts must not reappear after relaunch, even when the new suite is incomplete.
        if FileManager.default.fileExists(atPath: draftSuiteURL.path) {
            do {
                try FileManager.default.removeItem(at: draftSuiteURL)
            } catch {
                notice = "The suite was reset, but its older draft could not be removed: \(error.localizedDescription)"
            }
        }
        do {
            let validatedDirectory = try EvaluationAttachmentStorage.validatedStorageDirectory(attachmentsDirectory)
            for url in try FileManager.default.contentsOfDirectory(
                at: validatedDirectory,
                includingPropertiesForKeys: nil
            ) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            let cleanupNotice = "The suite was reset, but some private attachment files could not be removed: \(error.localizedDescription)"
            notice = [notice, cleanupNotice].compactMap { $0 }.joined(separator: "\n")
        }
    }

    func clearRunHistory() throws {
        try requireIdle()
        guard !isImportingFiles else { throw EvaluationStoreError.fileOperationBusy }
        // Include unreadable run files, which are not represented in the in-memory history.
        let files = try FileManager.default.contentsOfDirectory(
            at: runsDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        defer {
            runs = Self.loadRuns(
                from: runsDirectory,
                projectID: selectedProjectID,
                suiteID: selectedSuiteID
            ).runs
            if case .run(let id) = selection, !runs.contains(where: { $0.id == id }) {
                selection = .suite
            }
        }
        // Remove a completed run's recovery marker before its history file to prevent resurrection.
        if FileManager.default.fileExists(atPath: activeRunURL.path) {
            try FileManager.default.removeItem(at: activeRunURL)
        }
        // Keep runs hidden while their copied evidence is being removed. A failed
        // clear can retry these same tombstones without exposing partial evidence.
        let deletions = suiteDirectory.appending(path: "RunDeletions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: deletions, withIntermediateDirectories: true)
        for file in files {
            try FileManager.default.moveItem(at: file, to: deletions.appending(path: file.lastPathComponent))
        }
        let evidence = suiteDirectory.appending(path: "RunEvidence", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: evidence.path) {
            try FileManager.default.removeItem(at: evidence)
        }
        try FileManager.default.removeItem(at: deletions)
        completedSamples = 0
        totalSamples = 0
        liveResponse = nil
    }

    func importFiles(_ urls: [URL]) {
        guard !isRunning, !isProcessingFiles else {
            notice = "Wait for the current operation to finish before changing files."
            return
        }
        _ = saveSuite()
        isProcessingFiles = true
        let expectedRevision = suiteRevision

        Task {
            defer { isProcessingFiles = false }
            do {
                let inputs = try await Task.detached(priority: .userInitiated) {
                    try urls.map { url -> AttachmentInput in
                        guard url.isFileURL else { throw ImportError.notRegularLocalFile }
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        let type = UTType(filenameExtension: url.pathExtension)
                        let isImage = type?.conforms(to: .image) == true
                        let data = try EvaluationAttachmentStorage.readImportFile(
                            at: url,
                            isImage: isImage,
                            maximumBytes: isImage ? Self.maximumImageBytes : Self.maximumTextFileBytes
                        )
                        return AttachmentInput(
                            id: UUID(),
                            name: url.lastPathComponent,
                            mediaType: type?.preferredMIMEType ?? "application/octet-stream",
                            data: data
                        )
                    }
                }.value
                try await importAttachments(inputs, expectedRevision: expectedRevision)
            } catch {
                notice = "Could not import files: \(error.localizedDescription)"
            }
        }
    }

    func importAttachment(
        id: UUID,
        name: String,
        mediaType: String,
        data: Data,
        expectedRevision: String
    ) async throws -> EvaluationAttachmentImportResult {
        // Duplicate fast-path: re-preparing and comparing performs no mutation,
        // so it intentionally skips requireIdle/requireRevision and stays usable
        // with a stale revision or while a run is in progress. This keeps
        // at-least-once callers (notably MCP upload retries) idempotent: a retry
        // of an already-imported attachment reports "duplicate" with the current
        // revision instead of stale_revision (see
        // attachmentToolsAreBoundedAndNaturallyIdempotent). The selection guard
        // and post-prepare re-read still apply: if the suite changes mid-prepare
        // we report a conflict, and if the attachment disappears we report
        // not_found (surfaced to MCP as not_found).
        if suite.attachments.contains(where: { $0.id == id }) {
            let projectID = selectedProjectID
            let suiteID = selectedSuiteID
            let prepared = try await Task.detached(priority: .userInitiated) {
                try Self.prepareAttachment(id: id, name: name, mediaType: mediaType, data: data)
            }.value
            guard selectedProjectID == projectID, selectedSuiteID == suiteID else {
                throw EvaluationStoreError.resourceConflict("The selected workspace changed during attachment import.")
            }
            guard let existing = suite.attachments.first(where: { $0.id == id }) else {
                throw EvaluationStoreError.resourceNotFound("Attachment")
            }
            guard existing == prepared.attachment else {
                throw EvaluationStoreError.resourceConflict("Attachment ID already exists with different content.")
            }
            if existing.kind == .image {
                _ = try attachmentData(id: existing.id)
            }
            return EvaluationAttachmentImportResult(
                attachment: existing,
                truncated: existing.text?.hasSuffix("\n[File truncated during import.]") == true,
                duplicate: true,
                revision: try currentSuiteRevision()
            )
        }
        try requireIdle()
        try requireRevision(expectedRevision)

        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepareAttachment(id: id, name: name, mediaType: mediaType, data: data)
        }.value

        try requireIdle()
        try requireRevision(expectedRevision)
        return try commitPreparedAttachments([prepared]).first!
    }

    func removeAttachment(id: UUID) {
        _ = saveSuite()
        do {
            _ = try removeAttachment(id: id, expectedRevision: suiteRevision)
        } catch {
            notice = "Could not remove the imported file: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func removeAttachment(id: UUID, expectedRevision: String) throws -> Bool {
        try requireIdle()
        guard let attachment = suite.attachments.first(where: { $0.id == id }) else { return false }
        try requireRevision(expectedRevision)
        let storedURL = try attachment.storedFilename.map {
            try EvaluationAttachmentStorage.storedFileURL(
                filename: $0, attachmentID: attachment.id, in: attachmentsDirectory
            )
        }

        var candidate = suite
        candidate.attachments.removeAll { $0.id == id }
        if attachment.kind == .image,
           !suite.modelConfiguration.customizationSettings.visionSettings.isEmpty,
           !candidate.attachments.contains(where: { $0.kind == .image }) {
            throw EvaluationStoreError.invalidSuite(
                "Turn off OCR and barcode tools in Model before removing the last image."
            )
        }
        try commitSuite(candidate)
        draftSuite.attachments.removeAll { $0.id == id }

        if let storedURL {
            do {
                try FileManager.default.removeItem(at: storedURL)
            } catch CocoaError.fileNoSuchFile {
                // Missing content is already unreferenced.
            } catch {
                notice = "The attachment was removed, but its private file could not be cleaned up: \(error.localizedDescription)"
            }
        }
        return true
    }

    func promptText(for caseID: UUID) -> String {
        pendingPromptEdits[caseID] ?? draftSuite.cases.first(where: { $0.id == caseID })?.prompt ?? ""
    }

    func editPrompt(_ text: String, for caseID: UUID) {
        guard allowWorkspaceMutation() else { return }
        guard !isRunning, !isProcessingFiles,
              draftSuite.cases.contains(where: { $0.id == caseID }) else { return }
        guard promptText(for: caseID) != text else { return }
        pendingPromptEdits[caseID] = text
        scheduleSuiteSave()
    }

    private func applyPendingPromptEdits() {
        guard !pendingPromptEdits.isEmpty else { return }
        var updated = draftSuite
        for index in updated.cases.indices {
            if let prompt = pendingPromptEdits[updated.cases[index].id] {
                updated.cases[index].prompt = prompt
            }
        }
        pendingPromptEdits.removeAll()
        if draftSuite != updated { draftSuite = updated }
    }

    func scheduleSuiteSave() {
        draftSaveTask?.cancel()
        if !isDraftSavePending { isDraftSavePending = true }
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            self?.saveSuite()
        }
    }

    func refreshModelMetadata() {
        onDeviceContextSizes.invalidate()
        guard draftSuite.modelConfiguration.provider == .coreAI,
              let loadedCoreAI,
              draftSuite.modelConfiguration.coreAISettings == loadedCoreAIConfiguration else { return }
        do {
            let current = try CoreAIModelLoader.resourceIdentity(
                for: draftSuite.modelConfiguration.coreAISettings
            )
            guard current != loadedCoreAI.resourceIdentity else { return }
            self.loadedCoreAI = nil
            coreAILoadStatus = .failed(
                "The Core AI model resource files changed. Load the model again before running."
            )
        } catch {
            self.loadedCoreAI = nil
            coreAILoadStatus = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func saveSuite() -> Bool {
        if let workspacePersistenceBlocker {
            notice = workspacePersistenceBlocker
            draftSaveFailed = true
            return false
        }
        applyPendingPromptEdits()
        draftSaveTask?.cancel()
        draftSaveTask = nil
        if isDraftSavePending { isDraftSavePending = false }
        do {
            try commitSuite(draftSuite)
            return true
        } catch EvaluationStoreError.invalidSuite {
            persistCurrentDraft(fallbackNotice: nil)
            return false
        } catch {
            persistCurrentDraft(fallbackNotice: "Could not save the suite: \(error.localizedDescription)")
            return false
        }
    }

    private func persistCurrentDraft(fallbackNotice: String?) {
        do {
            try EvaluationWorkspacePersistence.createSuiteDirectories(at: suiteDirectory)
            let record = SuiteDraftRecord(
                canonicalRevision: try currentSuiteRevision(),
                suite: draftSuite
            )
            try CanonicalJSON.data(for: record).write(to: draftSuiteURL, options: .atomic)
            draftSaveFailed = false
            if let fallbackNotice { notice = fallbackNotice }
        } catch {
            draftSaveFailed = true
            notice = "Could not save the draft: \(error.localizedDescription)"
        }
    }

    func startRun() {
        guard saveSuite() else { return }
        do {
            _ = try startRun(id: UUID(), expectedRevision: suiteRevision)
        } catch {
            notice = error.localizedDescription
        }
    }

    func cancelRun() {
        guard let id = activeRun?.id else {
            runTask?.cancel()
            return
        }
        do {
            _ = try cancelRun(id: id)
        } catch {
            notice = error.localizedDescription
        }
    }

    func retryPendingRunSave() {
        do {
            try retryUnsavedRun()
        } catch {
            notice = error.localizedDescription
        }
    }

    func run(with id: UUID) -> EvaluationRun? {
        if let unsavedRun, unsavedRun.id == id { return unsavedRun }
        return runs.first { $0.id == id } ?? persistedRunLocation(id: id)?.run
    }

    @discardableResult
    func startRun(id: UUID, expectedRevision: String) throws -> EvaluationRunOperation {
        try retryUnsavedRun()
        if let existing = runStatus(id: id) {
            guard existing.suiteRevision == expectedRevision else {
                throw EvaluationStoreError.resourceConflict("Run ID already belongs to another suite revision.")
            }
            return existing
        }
        try requireIdle()
        try requireRevision(expectedRevision)
        refreshModelMetadata()
        guard let issue = validationIssue(for: suite) else {
            let suiteSnapshot = suite
            let externalJudge = try resolvedJudge(for: suiteSnapshot)
            let ownerProjectID = selectedProjectID
            let ownerSuiteID = selectedSuiteID
            let repositoryRoot = selectedProject.repository?.rootPath
            let startedAt = Date()
            let total = suiteSnapshot.cases.count * suiteSnapshot.repetitions
            let active = EvaluationActiveRun(
                id: id,
                suiteRevision: expectedRevision,
                startedAt: startedAt,
                completedSamples: 0,
                totalSamples: total,
                cancellationRequested: false,
                projectID: ownerProjectID,
                suiteID: ownerSuiteID
            )
            let evidence = try snapshotSubjectEvidence(
                runID: id,
                suite: suiteSnapshot,
                projectID: ownerProjectID,
                suiteID: ownerSuiteID
            )
            let images: [ImageEvaluationInput]
            let record = ActiveRunRecord(
                summary: active, suite: suiteSnapshot, results: [], subjectEvidence: evidence
            )

            do {
                images = try imageInputs(
                    for: evidence,
                    projectID: ownerProjectID,
                    suiteID: ownerSuiteID,
                    runID: id
                )
                try commitSuite(suiteSnapshot)
                try persistActiveRun(record)
            } catch {
                try? FileManager.default.removeItem(
                    at: runEvidenceDirectory(projectID: ownerProjectID, suiteID: ownerSuiteID, runID: id)
                )
                throw error
            }
            activeRun = active
            activeRunSuite = suiteSnapshot
            activeRunEvidence = evidence
            activeRunResults = []
            liveResponse = nil
            isRunning = true
            completedSamples = 0
            totalSamples = total

            runTask = Task { [weak self] in
                guard let self else { return }
                let repositorySnapshot: EvaluationRepositorySnapshot? = if let repositoryRoot {
                    await EvaluationRepositoryInspector.snapshot(rootPath: repositoryRoot)
                } else {
                    nil
                }
                var run = await runner.run(
                    id: id,
                    suiteRevision: expectedRevision,
                    startedAt: startedAt,
                    suite: suiteSnapshot,
                    images: images,
                    externalJudge: externalJudge,
                    liveResponse: { [weak self] response in
                        await self?.updateLiveResponse(runID: id, response: response)
                    }
                ) { [weak self] result, completed, total in
                    await self?.updateProgress(runID: id, result: result, completed: completed, total: total)
                }
                if self.activeRun?.id == id,
                   self.activeRun?.cancellationRequested == true {
                    run.cancelled = true
                    run.terminationReason = "cancelled"
                }
                run.projectID = ownerProjectID
                run.suiteDefinition = EvaluationSuiteDefinition(suite: suiteSnapshot)
                run.subjectEvidence = evidence
                if let assessmentIndex = run.assessments?.firstIndex(where: { $0.id == run.selectedAssessmentID }) {
                    run.assessments?[assessmentIndex].subjectEvidenceDigest = evidence.digest
                }
                run.repository = repositorySnapshot
                finish(run)
                liveResponse = nil
            }
            return operation(for: active)
        }
        throw EvaluationStoreError.invalidSuite(issue)
    }

    func runStatus(id: UUID) -> EvaluationRunOperation? {
        if let activeRun, activeRun.id == id { return operation(for: activeRun) }
        guard let run = run(with: id) else { return nil }
        let phase: EvaluationRunPhase
        if run.cancelled {
            phase = .cancelled
        } else if run.terminationReason == "interrupted" {
            phase = .interrupted
        } else if run.stoppedEarly {
            phase = .stopped
        } else {
            phase = .completed
        }
        return EvaluationRunOperation(
            id: run.id,
            suiteRevision: run.suiteRevision,
            phase: phase,
            completedSamples: run.results.count,
            totalSamples: run.plannedResultCount,
            startedAt: run.startedAt,
            completedAt: run.completedAt,
            projectID: run.projectID,
            suiteID: run.suiteID
        )
    }

    private func updateLiveResponse(runID: UUID, response: EvaluationLiveResponse) {
        guard activeRun?.id == runID, !Task.isCancelled else { return }
        liveResponse = response
    }

    @discardableResult
    func cancelRun(id: UUID) throws -> EvaluationRunOperation {
        if hasUnsavedCompletedRun {
            throw EvaluationStoreError.resourceConflict(
                "The run has finished and is waiting to be saved. Retry saving instead of cancelling it."
            )
        }
        if let finished = runStatus(id: id), finished.phase != .running, finished.phase != .cancellationRequested {
            return finished
        }
        guard var active = activeRun, active.id == id else {
            throw EvaluationStoreError.resourceNotFound("Run")
        }
        if !active.cancellationRequested {
            active.cancellationRequested = true
            guard let activeRunSuite else {
                throw EvaluationStoreError.persistence("The active run snapshot is unavailable.")
            }
            try persistActiveRun(ActiveRunRecord(
                summary: active, suite: activeRunSuite, results: activeRunResults,
                subjectEvidence: activeRunEvidence
            ))
            activeRun = active
            runTask?.cancel()
        }
        if !isRunning {
            try retryUnsavedRun()
            if let finished = runStatus(id: id), finished.phase != .running, finished.phase != .cancellationRequested {
                return finished
            }
            if unsavedRun != nil {
                throw EvaluationStoreError.persistence("The completed run still needs to be saved.")
            }
        }
        return operation(for: active)
    }

    func canonicalRunData(id: UUID) throws -> Data {
        guard let run = run(with: id) else { throw EvaluationStoreError.resourceNotFound("Run") }
        return try CanonicalJSON.data(for: run)
    }

    func partialResults(runID: UUID) -> [EvaluationSampleResult] {
        activeRun?.id == runID ? activeRunResults : []
    }

    func attachmentData(id: UUID) throws -> (attachment: EvaluationAttachment, data: Data) {
        guard let attachment = suite.attachments.first(where: { $0.id == id }) else {
            throw EvaluationStoreError.resourceNotFound("Attachment")
        }
        if let text = attachment.text { return (attachment, Data(text.utf8)) }
        guard let storedFilename = attachment.storedFilename else {
            throw EvaluationStoreError.persistence("The attachment has no stored content.")
        }
        do {
            let url = try EvaluationAttachmentStorage.storedFileURL(
                filename: storedFilename, attachmentID: attachment.id, in: attachmentsDirectory
            )
            // Read metadata before opening the file, then cap the stream at the
            // image limit plus one byte. This bounds a replacement-file race as
            // well as an honest oversized file.
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw EvaluationStoreError.persistence("The stored attachment is not a regular file.")
            }
            guard let reportedByteCount = values.fileSize else {
                throw EvaluationStoreError.persistence("The stored attachment size could not be determined.")
            }
            guard reportedByteCount <= Self.maximumImageBytes else {
                throw EvaluationStoreError.persistence(
                    "The stored attachment exceeds the maximum allowed image size. Remove it and import it again."
                )
            }
            guard reportedByteCount == attachment.byteCount else {
                throw EvaluationStoreError.persistence(
                    "The stored attachment failed its size or checksum validation. Remove it and import it again."
                )
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try EvaluationAttachmentStorage.readBoundedData(
                reportedByteCount: reportedByteCount,
                maximumBytes: Self.maximumImageBytes,
                tooLargeError: {
                    EvaluationStoreError.persistence(
                        "The stored attachment exceeds the maximum allowed image size. Remove it and import it again."
                    )
                },
                readChunk: { try handle.read(upToCount: $0) }
            )
            guard data.count == attachment.byteCount,
                  Self.sha256(data) == attachment.sha256 else {
                throw EvaluationStoreError.persistence(
                    "The stored attachment failed its size or checksum validation. Remove it and import it again."
                )
            }
            return (attachment, data)
        } catch {
            if let storeError = error as? EvaluationStoreError { throw storeError }
            throw EvaluationStoreError.persistence(error.localizedDescription)
        }
    }

    private func finish(_ run: EvaluationRun) {
        guard activeRun?.id == run.id else { return }
        let run = runPreparedForHistory(run)
        do {
            try persistRun(run)
            runs.removeAll { $0.id == run.id }
            runs.insert(run, at: 0)
            selection = .run(run.id)
            try? FileManager.default.removeItem(at: activeRunURL)
        } catch {
            unsavedRun = run
            if let activeRun, let activeRunSuite {
                try? persistActiveRun(ActiveRunRecord(
                    summary: activeRun, suite: activeRunSuite, results: run.results,
                    completedRun: run, subjectEvidence: activeRunEvidence
                ))
            }
            notice = "The run finished, but its trace could not be saved: \(error.localizedDescription). Restore storage access and try again to save it."
            activeRunResults = run.results
            if var active = activeRun {
                active.completedSamples = run.results.count
                activeRun = active
            }
            isRunning = false
            runTask = nil
            return
        }
        if unsavedRun != nil { notice = nil }
        unsavedRun = nil
        activeRun = nil
        activeRunSuite = nil
        activeRunEvidence = nil
        activeRunResults = []
        isRunning = false
        runTask = nil
    }

    private func updateProgress(
        runID: UUID,
        result: EvaluationSampleResult,
        completed: Int,
        total: Int
    ) {
        guard var active = activeRun, active.id == runID else { return }
        activeRunResults.append(result)
        completedSamples = completed
        totalSamples = total
        active.completedSamples = completed
        active.totalSamples = total
        activeRun = active
        if let activeRunSuite {
            do {
                try persistActiveRun(
                    ActiveRunRecord(
                        summary: active, suite: activeRunSuite, results: activeRunResults,
                        subjectEvidence: activeRunEvidence
                    )
                )
            } catch {
                notice = "Run progress could not be checkpointed: \(error.localizedDescription)"
            }
        }
    }

    func validationIssue(
        for candidate: EvaluationSuite,
        includeModelReadiness: Bool = true
    ) -> String? {
        let configuration = candidate.modelConfiguration
        let capabilities = selectedModelCapabilities(for: candidate)
        let validateCapabilities = configuration.provider != .coreAI || coreAIModel(for: candidate) != nil
        if let issue = configuration.customizationSettings.validationIssue { return issue }
        if configuration.reasoningLevel == .custom,
           configuration.customizationSettings.reasoningName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the reasoning value supported by the selected provider."
        }
        if let issue = candidate.features.validationIssue { return issue }
        if candidate.features.profile.enabled, candidate.features.profile.requireToolFirst,
           !candidate.hasConfiguredTools {
            return "A profile that requires a tool call must enable at least one tool."
        }
        if candidate.hasConfiguredTools, validateCapabilities, !capabilities.contains(.toolCalling) {
            return "The selected model does not support tool calling."
        }
        if candidate.features.tools.contains(where: { $0.name == ReferenceLookupTool.toolName }) {
            return "Custom tools must not use the reserved reference lookup name."
        }
        let vision = configuration.customizationSettings.visionSettings
        if !vision.isEmpty {
            if validateCapabilities && !capabilities.contains(.toolCalling) { return "Image tools require a model that supports tool calling." }
            if !candidate.attachments.contains(where: { $0.kind == .image }) {
                return "Attach an image before enabling OCR or barcode tools."
            }
        }
        if candidate.features.tools.contains(where: { vision.enabledToolNames.contains($0.name) }) {
            return "Custom tool names must differ from the enabled image tool names."
        }
        if candidate.features.tools.contains(where: {
            candidate.features.spotlightSearch.enabledToolNames.contains($0.name)
        }) {
            return "Custom tool names must differ from the enabled Spotlight tool name."
        }
        if !candidate.features.tools.isEmpty, validateCapabilities && !capabilities.contains(.toolCalling) {
            return "The current model does not support custom tool calls."
        }
        if !candidate.features.outputFields.isEmpty, validateCapabilities && !capabilities.contains(.guidedGeneration) {
            return "The current model does not support guided output."
        }
        if configuration.provider == .customHTTP, let issue = configuration.customProviderSettings.validationIssue {
            return issue
        }
        if configuration.customizationSettings.toolCalling == .required,
           !candidate.hasConfiguredTools {
            return "Required tool calling needs at least one enabled tool."
        }
        if candidate.cases.isEmpty {
            return "Add at least one evaluation case."
        }
        if candidate.cases.count > Self.maximumCases {
            return "Keep the suite to \(Self.maximumCases) cases or fewer."
        }
        if !(1...5).contains(candidate.repetitions) {
            return "Choose between one and five repetitions."
        }
        let (plannedSamples, overflowed) = candidate.cases.count.multipliedReportingOverflow(by: candidate.repetitions)
        if overflowed || plannedSamples > Self.maximumPlannedSamples {
            return "Keep the run to \(Self.maximumPlannedSamples) planned samples or fewer."
        }
        let releasePolicy = candidate.releasePolicy
        if !(0...(Self.maximumPlannedSamples * 2)).contains(releasePolicy.maximumErrorCount) {
            return "Keep the release error limit between 0 and \(Self.maximumPlannedSamples * 2)."
        }
        if let latency = releasePolicy.maximumAverageLatencyMilliseconds,
           !latency.isFinite || latency < 0 {
            return "The release latency limit must be a finite nonnegative number."
        }
        if !releasePolicy.maximumPassRateRegression.isFinite
            || !(0...1).contains(releasePolicy.maximumPassRateRegression) {
            return "The allowed pass-rate regression must be between 0 and 1."
        }
        if Set(releasePolicy.criticalCaseIDs).count != releasePolicy.criticalCaseIDs.count
            || !Set(releasePolicy.criticalCaseIDs).isSubset(of: Set(candidate.cases.map(\.id))) {
            return "Every critical release case must uniquely identify a case in this suite."
        }
        if Set(candidate.cases.map(\.id)).count != candidate.cases.count {
            return "Every case needs a unique ID."
        }
        if candidate.cases.contains(where: { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Every case needs a prompt."
        }
        if let issue = candidate.cases.lazy.compactMap(\.conversation.validationIssue).first {
            return issue
        }
        if let issue = candidate.cases.lazy.compactMap({ evaluationCase in
            EvaluationFieldAssertions.validationIssue(
                assertions: evaluationCase.fieldAssertions ?? [],
                scoringMode: candidate.scoringMode
            )
        }).first {
            return issue
        }
        if candidate.instructions.count > Self.maximumFieldCharacters
            || candidate.cases.contains(where: {
                $0.prompt.count > Self.maximumFieldCharacters
                    || $0.expected.count > Self.maximumFieldCharacters
                    || $0.conversation.setupTurns.contains(where: {
                        $0.prompt.count > Self.maximumFieldCharacters
                    })
            }) {
            return "Instructions, prompts, and expected responses must each contain \(Self.maximumFieldCharacters) characters or fewer."
        }
        let suiteCharacterCount = candidate.name.count
            + candidate.version.count
            + candidate.instructions.count
            + candidate.criteria.count
            + candidate.cases.reduce(0) {
                $0 + $1.name.count + $1.prompt.count + $1.expected.count + $1.conversation.textCharacterCount
                    + ($1.fieldAssertions ?? []).reduce(0) { $0 + $1.pointer.count + $1.expectedValue.count }
            }
        if suiteCharacterCount > Self.maximumCombinedSuiteCharacters {
            return "Keep the suite text to \(Self.maximumCombinedSuiteCharacters) characters or fewer."
        }
        if candidate.scoringMode.needsExpected,
           candidate.cases.contains(where: { $0.expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Every case needs expected text for the selected deterministic metric."
        }
        if candidate.scoringMode == .modelJudge {
            if candidate.rubricCriteria.isEmpty {
                return "Add at least one requirement for the AI rubric."
            }
            if candidate.rubricCriteria.count > 4 {
                return "Keep the AI rubric to four requirements or fewer so the judge can evaluate each one reliably."
            }
            if candidate.rubricCriteria.contains(where: { $0.count > Self.maximumRubricRequirementCharacters }) {
                return "Keep each rubric requirement to \(Self.maximumRubricRequirementCharacters) characters or fewer."
            }
            if candidate.judgeConfiguration.usesExternalConnection {
                guard let connectionID = candidate.judgeConfiguration.connectionID,
                      let connection = judgeConnections.first(where: { $0.id == connectionID }) else {
                    return "Choose an independent judge connection."
                }
                if let issue = connection.validationIssue { return issue }
                if !connection.capabilities.structuredOutputs {
                    return "The independent judge must support structured outputs."
                }
                if candidate.attachments.contains(where: { $0.kind == .image }),
                   candidate.judgeConfiguration.includeReferenceAttachments,
                   !connection.capabilities.multimodal {
                    return "The suite sends image evidence, but the selected judge is not configured for multimodal input."
                }
                if includeModelReadiness,
                   !candidate.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: connection) {
                    return "Review and approve the exact external judge evidence disclosure before running."
                }
            } else if validateCapabilities && !capabilities.contains(.guidedGeneration) {
                return "The selected subject model does not support the guided output required for same-model judging. Choose an independent judge or another subject model."
            }
        }
        if !(128...4_096).contains(configuration.maximumResponseTokens) {
            return "Choose a maximum response length between 128 and 4,096 tokens."
        }
        if let maximumInputTokens = configuration.maximumInputTokens,
           !(512...32_768).contains(maximumInputTokens) {
            return "Choose an input ceiling between 512 and 32,768 tokens."
        }
        if configuration.temperatureEnabled,
           !configuration.temperature.isFinite || !(0...1).contains(configuration.temperature) {
            return "Temperature must be between 0 and 1."
        }
        if configuration.samplingMode == .topK, !(1...1_000).contains(configuration.topK) {
            return "Top K must be between 1 and 1,000."
        }
        if configuration.samplingMode == .probability,
           !configuration.probabilityThreshold.isFinite || !(0.01...1).contains(configuration.probabilityThreshold) {
            return "Probability threshold must be between 0.01 and 1."
        }
        if configuration.reasoningLevel != .automatic,
           validateCapabilities && !capabilities.contains(.reasoning) {
            return "The selected model does not support explicit reasoning levels. Choose Automatic."
        }
        if candidate.features.profile.enabled,
           candidate.features.profile.afterToolReasoningLevel != .automatic,
           validateCapabilities && !capabilities.contains(.reasoning) {
            return "The selected model does not support explicit reasoning levels in the active profile. Choose Automatic."
        }
        if candidate.hasConfiguredTools, !(1...4).contains(configuration.maximumToolCalls) {
            return "The tool call limit must be between one and four calls per sample."
        }
        if configuration.referenceMode == .lookupTool {
            if validateCapabilities && !capabilities.contains(.toolCalling) {
                return "The selected model does not support tool calling."
            }
            if !candidate.attachments.contains(where: { $0.kind == .text }) {
                return "Import at least one text reference before enabling reference search."
            }
            if !(1...4).contains(configuration.maximumToolCalls) {
                return "The reference tool limit must be between one and four calls per response."
            }
        }
        let modelContextSize = contextSize(for: candidate)
        let allocation = configuration.contextAllocation(
            contextSize: modelContextSize,
            includesModelJudge: candidate.needsModelJudge,
            sharedToolOutputReserve: candidate.sharedToolOutputReserve
        )
        let contextSizeIsAuthoritative = candidate.modelConfiguration.provider != .onDevice
            || !onDeviceContextSizes.usedFallback(for: configuration)
        if contextSizeIsAuthoritative, modelContextSize > 0, allocation.effectiveInputLimit < 512 {
            return "Reduce the response limit or reference-tool call limit so at least 512 input tokens remain."
        }
        if candidate.attachments.count > Self.maximumAttachments {
            return "A suite can attach up to \(Self.maximumAttachments) files."
        }
        if candidate.attachments.count(where: { $0.kind == .image }) > Self.maximumImages {
            return "A suite can attach up to \(Self.maximumImages) images."
        }
        if Set(candidate.attachments.map(\.id)).count != candidate.attachments.count {
            return "Every attachment needs a unique ID."
        }
        if candidate.attachments.contains(where: { $0.kind == .image }),
           validateCapabilities && !capabilities.contains(.vision) {
            return "The selected model does not support image input."
        }
        let status = modelStatus(for: candidate)
        return includeModelReadiness && !status.isAvailable ? status.detail : nil
    }

    private func imageInputs(for suite: EvaluationSuite) throws -> [ImageEvaluationInput] {
        try suite.attachments
            .filter { $0.kind == .image }
            .enumerated()
            .map { index, attachment in
                guard let storedFilename = attachment.storedFilename else {
                    throw EvaluationStoreError.persistence("Image evidence has no stored filename.")
                }
                return ImageEvaluationInput(
                    label: "file-\(index + 1)",
                    url: try EvaluationAttachmentStorage.storedFileURL(
                        filename: storedFilename, attachmentID: attachment.id, in: attachmentsDirectory
                    )
                )
            }
    }

    private func runEvidenceDirectory(
        projectID: UUID,
        suiteID: UUID,
        runID: UUID
    ) -> URL {
        EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: supportDirectory,
            projectID: projectID,
            suiteID: suiteID
        )
        .appending(path: "RunEvidence", directoryHint: .isDirectory)
        .appending(path: runID.uuidString, directoryHint: .isDirectory)
    }

    private func snapshotSubjectEvidence(
        runID: UUID,
        suite: EvaluationSuite,
        projectID: UUID,
        suiteID: UUID
    ) throws -> EvaluationSubjectEvidenceSnapshot {
        let destination = runEvidenceDirectory(projectID: projectID, suiteID: suiteID, runID: runID)
        let sourceAttachments = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: supportDirectory,
            projectID: projectID,
            suiteID: suiteID
        ).appending(path: "Attachments", directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw EvaluationStoreError.resourceConflict("Run evidence already exists for this run ID.")
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var snapshots: [EvaluationSubjectAttachmentSnapshot] = []
            for attachment in suite.attachments {
                if attachment.kind == .image {
                    guard let storedFilename = attachment.storedFilename else {
                        throw EvaluationStoreError.persistence("Image evidence has no stored filename.")
                    }
                    let source = try EvaluationAttachmentStorage.storedFileURL(
                        filename: storedFilename, attachmentID: attachment.id, in: sourceAttachments
                    )
                    let data = try Data(contentsOf: source, options: .mappedIfSafe)
                    guard data.count == attachment.byteCount, Self.sha256(data) == attachment.sha256 else {
                        throw EvaluationStoreError.persistence("Image evidence does not match its saved digest.")
                    }
                    let evidenceFilename = attachment.id.uuidString
                        + (source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)")
                    try data.write(to: destination.appending(path: evidenceFilename), options: .atomic)
                    snapshots.append(.init(
                        id: attachment.id, name: attachment.name, kind: attachment.kind,
                        byteCount: attachment.byteCount, sha256: attachment.sha256,
                        storedFilename: evidenceFilename, text: nil
                    ))
                } else {
                    snapshots.append(.init(
                        id: attachment.id, name: attachment.name, kind: attachment.kind,
                        byteCount: attachment.byteCount, sha256: attachment.sha256,
                        storedFilename: nil, text: attachment.text
                    ))
                }
            }
            return EvaluationSubjectEvidenceSnapshot(
                instructions: suite.instructions,
                cases: suite.cases,
                attachments: snapshots,
                digest: try EvaluationSubjectEvidenceSnapshot.digest(
                    instructions: suite.instructions,
                    cases: suite.cases,
                    attachments: snapshots
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if let storeError = error as? EvaluationStoreError { throw storeError }
            throw EvaluationStoreError.persistence(error.localizedDescription)
        }
    }

    private func subjectEvidence(for run: EvaluationRun) throws -> EvaluationSubjectEvidenceSnapshot {
        if let evidence = run.subjectEvidence {
            guard evidence.hasValidDigest else {
                throw EvaluationStoreError.persistence("The run's immutable subject evidence failed its integrity check.")
            }
            return evidence
        }

        let cases = run.plannedCases ?? run.suiteDefinition?.cases ?? []
        guard !cases.isEmpty else {
            throw EvaluationStoreError.persistence("The run has no immutable case definitions for reassessment.")
        }
        let legacyAttachments = try run.attachments.map { trace -> EvaluationSubjectAttachmentSnapshot in
            guard let current = suite.attachments.first(where: {
                $0.name == trace.name && $0.kind == trace.kind
                    && $0.byteCount == trace.byteCount && $0.sha256 == trace.sha256
            }) else {
                throw EvaluationStoreError.persistence("The run's historical attachment evidence is unavailable.")
            }
            if current.kind == .image {
                guard let storedFilename = current.storedFilename else {
                    throw EvaluationStoreError.persistence("The run's historical image evidence is unavailable.")
                }
                let storedURL = try EvaluationAttachmentStorage.storedFileURL(
                    filename: storedFilename, attachmentID: current.id, in: attachmentsDirectory
                )
                guard FileManager.default.fileExists(atPath: storedURL.path) else {
                    throw EvaluationStoreError.persistence("The run's historical image evidence is unavailable.")
                }
                return .init(
                    id: current.id, name: current.name, kind: current.kind,
                    byteCount: current.byteCount, sha256: current.sha256,
                    storedFilename: current.storedFilename, text: nil
                )
            }
            return .init(
                id: current.id, name: current.name, kind: current.kind,
                byteCount: current.byteCount, sha256: current.sha256,
                storedFilename: nil, text: current.text
            )
        }
        return EvaluationSubjectEvidenceSnapshot(
            instructions: run.instructions,
            cases: cases,
            attachments: legacyAttachments,
            digest: try EvaluationSubjectEvidenceSnapshot.digest(
                instructions: run.instructions,
                cases: cases,
                attachments: legacyAttachments
            )
        )
    }

    private func imageInputs(
        for evidence: EvaluationSubjectEvidenceSnapshot,
        projectID: UUID,
        suiteID: UUID,
        runID: UUID,
        legacy: Bool = false
    ) throws -> [ImageEvaluationInput] {
        let directory = legacy
            ? attachmentsDirectory
            : runEvidenceDirectory(projectID: projectID, suiteID: suiteID, runID: runID)
        return try evidence.attachments.filter { $0.kind == .image }.enumerated().map { index, attachment in
            guard let storedFilename = attachment.storedFilename else {
                throw EvaluationStoreError.persistence("The run's historical image evidence has no stored content.")
            }
            let url = try EvaluationAttachmentStorage.storedFileURL(
                filename: storedFilename, attachmentID: attachment.id, in: directory
            )
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count == attachment.byteCount, Self.sha256(data) == attachment.sha256 else {
                throw EvaluationStoreError.persistence("The run's historical image evidence failed its integrity check.")
            }
            return ImageEvaluationInput(label: "file-\(index + 1)", url: url)
        }
    }

    private func reassessmentContext(
        for run: EvaluationRun,
        scoringSuite: EvaluationSuite
    ) throws -> (
        suite: EvaluationSuite,
        images: [ImageEvaluationInput],
        evidence: EvaluationSubjectEvidenceSnapshot,
        scoringContract: EvaluationScoringContract
    ) {
        let evidence = try subjectEvidence(for: run)
        var replaySuite = scoringSuite
        replaySuite.instructions = evidence.instructions
        replaySuite.cases = evidence.cases
        replaySuite.attachments = evidence.attachments.map {
            EvaluationAttachment(
                id: $0.id, name: $0.name, kind: $0.kind, text: $0.text,
                storedFilename: $0.storedFilename, byteCount: $0.byteCount, sha256: $0.sha256
            )
        }
        let scoringContract = try EvaluationScoringContract(suite: replaySuite)
        let projectID = run.projectID ?? selectedProjectID
        let images = try imageInputs(
            for: evidence,
            projectID: projectID,
            suiteID: run.suiteID,
            runID: run.id,
            legacy: run.subjectEvidence == nil
        )
        return (replaySuite, images, evidence, scoringContract)
    }

    private func importAttachments(
        _ inputs: [AttachmentInput],
        expectedRevision: String
    ) async throws {
        guard !isRunning else { throw EvaluationStoreError.runBusy }
        try requireRevision(expectedRevision)
        let prepared = try await Task.detached(priority: .userInitiated) {
            try inputs.map {
                try Self.prepareAttachment(id: $0.id, name: $0.name, mediaType: $0.mediaType, data: $0.data)
            }
        }.value
        guard !isRunning else { throw EvaluationStoreError.runBusy }
        try requireRevision(expectedRevision)
        _ = try commitPreparedAttachments(prepared)
    }

    private nonisolated static func prepareAttachment(
        id: UUID,
        name: String,
        mediaType: String,
        data: Data
    ) throws -> PreparedAttachment {
        let basename = (name as NSString).lastPathComponent
        guard !basename.isEmpty, basename == name, !name.contains("\\") else {
            throw ImportError.invalidFilename
        }
        guard let declaredType = UTType(mimeType: mediaType) else {
            throw ImportError.unsupportedType
        }
        let filenameType = UTType(filenameExtension: (name as NSString).pathExtension)
        let isImage = declaredType.conforms(to: .image)
        let isPDF = declaredType.conforms(to: .pdf)
        let isText = declaredType.conforms(to: .text)
            || declaredType.conforms(to: .json)
            || declaredType.conforms(to: .commaSeparatedText)
        guard isImage || isPDF || isText else { throw ImportError.unsupportedType }

        if let filenameType {
            let filenameCategoryMatches = (isImage && filenameType.conforms(to: .image))
                || (isPDF && filenameType.conforms(to: .pdf))
                || (isText && (filenameType.conforms(to: .text)
                    || filenameType.conforms(to: .json)
                    || filenameType.conforms(to: .commaSeparatedText)))
            guard filenameCategoryMatches else { throw ImportError.typeMismatch }
        }

        let digest = sha256(data)
        if isImage {
            guard data.count <= maximumImageBytes else { throw ImportError.imageTooLarge }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw ImportError.unreadableImage
            }
            let fileExtension = declaredType.preferredFilenameExtension
                ?? (name as NSString).pathExtension.lowercased()
            let storedFilename = "\(id.uuidString).\(fileExtension)"
            return PreparedAttachment(
                attachment: EvaluationAttachment(
                    id: id,
                    name: name,
                    kind: .image,
                    text: nil,
                    storedFilename: storedFilename,
                    byteCount: data.count,
                    sha256: digest
                ),
                imageData: data,
                truncated: false
            )
        }

        guard data.count <= maximumTextFileBytes else { throw ImportError.fileTooLarge }
        let text: String
        if isPDF {
            guard let document = PDFDocument(data: data),
                  let extracted = document.string,
                  !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportError.unreadablePDF
            }
            text = extracted
        } else {
            guard let decoded = String(data: data, encoding: .utf8) else { throw ImportError.notUTF8 }
            text = decoded
        }
        let truncated = text.count > maximumExtractedTextCharacters
        return PreparedAttachment(
            attachment: EvaluationAttachment(
                id: id,
                name: name,
                kind: .text,
                text: truncated
                    ? String(text.prefix(maximumExtractedTextCharacters)) + "\n[File truncated during import.]"
                    : text,
                storedFilename: nil,
                byteCount: data.count,
                sha256: digest
            ),
            imageData: nil,
            truncated: truncated
        )
    }

    private func commitPreparedAttachments(
        _ prepared: [PreparedAttachment]
    ) throws -> [EvaluationAttachmentImportResult] {
        guard Set(prepared.map(\.attachment.id)).count == prepared.count else {
            throw EvaluationStoreError.resourceConflict("Attachment IDs must be unique.")
        }
        for item in prepared {
            if let existing = suite.attachments.first(where: { $0.id == item.attachment.id }) {
                guard existing == item.attachment else {
                    throw EvaluationStoreError.resourceConflict("Attachment ID already exists with different content.")
                }
                if existing.kind == .image {
                    // Matching image metadata is not sufficient for a duplicate:
                    // validate the private bytes before accepting batch imports.
                    _ = try attachmentData(id: existing.id)
                }
            }
        }
        let newItems = prepared.filter { item in
            !suite.attachments.contains(where: { $0.id == item.attachment.id })
        }
        guard suite.attachments.count + newItems.count <= Self.maximumAttachments else {
            throw ImportError.tooManyFiles
        }
        let newImageCount = newItems.count(where: { $0.attachment.kind == .image })
        guard suite.attachments.count(where: { $0.kind == .image }) + newImageCount <= Self.maximumImages else {
            throw ImportError.tooManyImages
        }

        var writtenURLs: [URL] = []
        do {
            for item in newItems {
                guard let data = item.imageData,
                      let storedFilename = item.attachment.storedFilename else { continue }
                let url = try EvaluationAttachmentStorage.storedFileURL(
                    filename: storedFilename, attachmentID: item.attachment.id, in: attachmentsDirectory
                )
                try data.write(to: url, options: .atomic)
                writtenURLs.append(url)
            }
            var candidate = suite
            candidate.attachments.append(contentsOf: newItems.map(\.attachment))
            try commitSuite(candidate)
            draftSuite.attachments = candidate.attachments
        } catch {
            let suiteURL = suiteDirectory.appending(path: "suite.json")
            let referencedFilenames = (try? CanonicalJSON.decode(
                EvaluationSuite.self,
                from: Data(contentsOf: suiteURL)
            )).map { Set($0.attachments.compactMap(\.storedFilename)) } ?? []
            for url in writtenURLs where !referencedFilenames.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
            if let storeError = error as? EvaluationStoreError { throw storeError }
            throw EvaluationStoreError.persistence(error.localizedDescription)
        }

        let revision = try currentSuiteRevision()
        return prepared.map { item in
            EvaluationAttachmentImportResult(
                attachment: item.attachment,
                truncated: item.truncated,
                duplicate: !newItems.contains(where: { $0.attachment.id == item.attachment.id }),
                revision: revision
            )
        }
    }

    private func commitSuite(_ candidate: EvaluationSuite) throws {
        if let issue = validationIssue(for: candidate, includeModelReadiness: false) {
            throw EvaluationStoreError.invalidSuite(issue)
        }
        let canonicalChanged = candidate != suite
        let previousSuite = suite
        let previousWorkspace = workspace
        let suiteURL = suiteDirectory.appending(path: "suite.json")
        let repositoryURL = EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: selectedProject,
            suite: selectedSuiteRecord
        )
        // Snapshot existing files with throwing reads before any directory or
        // persistence mutation. An unreadable existing file must abort safely.
        let previousSuiteFile = try snapshotFile(at: suiteURL)
        let previousRepositoryFile = try repositoryURL.map { try snapshotFile(at: $0) }
        let catalogURL = supportDirectory.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        let previousCatalogFile = try snapshotFile(at: catalogURL)
        do {
            try EvaluationWorkspacePersistence.createSuiteDirectories(at: suiteDirectory)
            try persistRepositoryDefinitionIfLinked(candidate)
            let data = try CanonicalJSON.data(for: candidate)
            try data.write(to: suiteURL, options: .atomic)
            try updateSelectedSuiteRecord { record in
                record.name = candidate.name
                record.updatedAt = Date()
            }
            suite = candidate
            draftSaveFailed = false
        } catch {
            suite = previousSuite
            workspace = previousWorkspace
            var rollbackErrors: [String] = []
            do {
                try restoreFile(previousCatalogFile)
            } catch {
                rollbackErrors.append("workspace catalog: \(error.localizedDescription)")
            }
            do {
                try restoreFile(previousSuiteFile)
            } catch {
                rollbackErrors.append("suite metadata: \(error.localizedDescription)")
            }
            if let previousRepositoryFile {
                do { try restoreFile(previousRepositoryFile) }
                catch { rollbackErrors.append("repository definition: \(error.localizedDescription)") }
            }
            draftSaveFailed = true
            if !rollbackErrors.isEmpty {
                throw EvaluationStoreError.persistence(
                    "\(error.localizedDescription) Rollback also failed for \(rollbackErrors.joined(separator: "; "))."
                )
            }
            if let storeError = error as? EvaluationStoreError { throw storeError }
            if let workspaceError = error as? EvaluationWorkspaceError { throw workspaceError }
            throw EvaluationStoreError.persistence(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: draftSuiteURL.path) else { return }
        if candidate == draftSuite {
            do {
                try FileManager.default.removeItem(at: draftSuiteURL)
            } catch {
                notice = "The suite was saved, but its older draft marker could not be removed: \(error.localizedDescription)"
            }
        } else if canonicalChanged {
            let backup = suiteDirectory.appending(path: "suite-draft-stale-\(UUID().uuidString).json")
            do {
                try FileManager.default.moveItem(at: draftSuiteURL, to: backup)
                notice = "The suite changed while a local draft was incomplete. The older draft was ignored and preserved as \(backup.lastPathComponent)."
            } catch {
                notice = "The suite changed while a local draft was incomplete. The older draft will be ignored, but it could not be moved: \(error.localizedDescription)"
            }
        }
    }

    private func persistRun(_ run: EvaluationRun) throws {
        do {
            try CanonicalJSON.data(for: run).write(
                to: runsDirectory.appending(path: "\(run.id.uuidString).json"),
                options: .atomic
            )
        } catch {
            throw EvaluationStoreError.persistence(error.localizedDescription)
        }
    }

    private func runPreparedForHistory(_ run: EvaluationRun) -> EvaluationRun {
        var run = run
        if let sequence = run.historySequence {
            latestRunHistorySequence = max(latestRunHistorySequence, sequence)
            return run
        }
        let persistedMaximum = runs.compactMap(\.historySequence).max() ?? 0
        latestRunHistorySequence = max(latestRunHistorySequence, persistedMaximum)
        let wallClockMicroseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
        latestRunHistorySequence = max(latestRunHistorySequence + 1, wallClockMicroseconds)
        run.historySequence = latestRunHistorySequence
        return run
    }

    private func persistedRunLocation(id: UUID) -> EvaluationPersistedRunLocation? {
        for project in workspace.projects {
            for record in project.suites {
                let directory = EvaluationWorkspacePersistence.suiteDirectory(
                    supportDirectory: supportDirectory,
                    projectID: project.id,
                    suiteID: record.id
                )
                let runURL = directory
                    .appending(path: "Runs", directoryHint: .isDirectory)
                    .appending(path: "\(id.uuidString).json")
                guard FileManager.default.fileExists(atPath: runURL.path),
                      let data = try? Data(contentsOf: runURL),
                      let run = try? CanonicalJSON.decode(EvaluationRun.self, from: data),
                      run.id == id,
                      run.suiteID == record.id,
                      run.projectID == nil || run.projectID == project.id else { continue }
                return EvaluationPersistedRunLocation(
                    projectID: project.id,
                    suiteID: record.id,
                    runURL: runURL,
                    run: run
                )
            }
        }
        return nil
    }

    private func pendingRunDeletionLocation(id: UUID) -> EvaluationPersistedRunLocation? {
        for project in workspace.projects {
            for record in project.suites {
                let directory = EvaluationWorkspacePersistence.suiteDirectory(
                    supportDirectory: supportDirectory,
                    projectID: project.id,
                    suiteID: record.id
                )
                let runURL = directory
                    .appending(path: "RunDeletions", directoryHint: .isDirectory)
                    .appending(path: "\(id.uuidString).json")
                guard FileManager.default.fileExists(atPath: runURL.path),
                      let data = try? Data(contentsOf: runURL),
                      let run = try? CanonicalJSON.decode(EvaluationRun.self, from: data),
                      run.id == id,
                      run.suiteID == record.id,
                      run.projectID == nil || run.projectID == project.id else { continue }
                return EvaluationPersistedRunLocation(
                    projectID: project.id,
                    suiteID: record.id,
                    runURL: runURL,
                    run: run
                )
            }
        }
        return nil
    }

    private func persistActiveRun(_ record: ActiveRunRecord) throws {
        do {
            try CanonicalJSON.data(for: record).write(to: activeRunURL, options: .atomic)
        } catch {
            throw EvaluationStoreError.persistence(error.localizedDescription)
        }
    }

    private func retryUnsavedRun() throws {
        guard let unsavedRun else { return }
        finish(unsavedRun)
        if self.unsavedRun != nil {
            throw EvaluationStoreError.persistence("The completed run still needs to be saved.")
        }
    }

    private func requireIdle() throws {
        try requireWorkspaceWritable()
        try retryUnsavedRun()
        if isRunning || activeRun != nil { throw EvaluationStoreError.runBusy }
        if isReassessing {
            throw EvaluationStoreError.resourceConflict(
                "Wait for the reassessment or judge check to finish before switching or changing this suite."
            )
        }
        if isProcessingFiles || isImportingFiles { throw EvaluationStoreError.fileOperationBusy }
    }

    private func flushPendingSuiteSave() throws {
        guard isDraftSavePending else { return }
        _ = saveSuite()
        if draftSaveFailed {
            throw EvaluationStoreError.persistence("Save the local draft before applying another change.")
        }
    }

    private func requireRevision(_ expectedRevision: String) throws {
        try flushPendingSuiteSave()
        let current = try currentSuiteRevision()
        guard expectedRevision == current else {
            throw EvaluationStoreError.staleRevision(current: current)
        }
    }

    private func operation(for active: EvaluationActiveRun) -> EvaluationRunOperation {
        let phase: EvaluationRunPhase
        if let unsavedRun, unsavedRun.id == active.id, !isRunning {
            if unsavedRun.cancelled {
                phase = .cancelled
            } else if unsavedRun.terminationReason == "interrupted" {
                phase = .interrupted
            } else if unsavedRun.stoppedEarly {
                phase = .stopped
            } else {
                phase = .completed
            }
        } else if active.cancellationRequested {
            phase = .cancellationRequested
        } else if isRunning {
            phase = .running
        } else {
            phase = .stopped
        }
        return EvaluationRunOperation(
            id: active.id,
            suiteRevision: active.suiteRevision,
            phase: phase,
            completedSamples: active.completedSamples,
            totalSamples: active.totalSamples,
            startedAt: active.startedAt,
            completedAt: unsavedRun?.id == active.id ? unsavedRun?.completedAt : nil,
            projectID: active.projectID,
            suiteID: active.suiteID
        )
    }

    nonisolated static func revision(for suite: EvaluationSuite) throws -> String {
        let payload = SuiteRevisionPayload(
            id: suite.id,
            name: suite.name,
            version: suite.version,
            instructions: suite.instructions,
            rubricCriteria: suite.rubricCriteria,
            scoringMode: suite.scoringMode,
            repetitions: suite.repetitions,
            modelConfiguration: suite.modelConfiguration,
            features: suite.features,
            cases: suite.cases,
            attachments: suite.attachments.map {
                RevisionAttachment(
                    id: $0.id,
                    name: $0.name,
                    kind: $0.kind,
                    byteCount: $0.byteCount,
                    sha256: $0.sha256
                )
            },
            judgeConfiguration: suite.judgeConfiguration,
            releasePolicy: suite.releasePolicy
        )
        return sha256(try CanonicalJSON.data(for: payload, prettyPrinted: false))
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func persistSuiteLocalState() throws {
        try requireWorkspaceWritable()
        do {
            try suiteLocalStateWriter(CanonicalJSON.data(for: suiteLocalState), suiteStateURL)
        } catch {
            throw EvaluationStoreError.persistence(error.localizedDescription)
        }
    }

    private func restoreDraftAfterFailedSave(
        _ previousDraft: EvaluationSuite,
        fileSnapshot: PersistedFileSnapshot,
        failureMessage: String
    ) throws {
        draftSuite = previousDraft
        do {
            try restoreFile(fileSnapshot)
        } catch {
            throw EvaluationStoreError.persistence(
                "\(failureMessage) Draft rollback also failed: \(error.localizedDescription)"
            )
        }
    }

    private func requireWorkspaceWritable() throws {
        if let workspacePersistenceBlocker {
            throw EvaluationStoreError.persistence(workspacePersistenceBlocker)
        }
    }

    private func allowWorkspaceMutation() -> Bool {
        do {
            try requireWorkspaceWritable()
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    private func candidateAdoptionSnapshot() throws -> CandidateAdoptionSnapshot {
        let suiteFile = try snapshotFile(at: suiteDirectory.appending(path: "suite.json"))
        let draftFile = try snapshotFile(at: draftSuiteURL)
        let catalogFile = try snapshotFile(
            at: supportDirectory.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        )
        let stateFile = try snapshotFile(at: suiteStateURL)
        let repositoryURL = EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: selectedProject,
            suite: selectedSuiteRecord
        )
        let repositoryFile = try repositoryURL.map { try snapshotFile(at: $0) }
        return CandidateAdoptionSnapshot(
            suite: suite,
            draft: draftSuite,
            workspace: workspace,
            notice: notice,
            draftSaveFailed: draftSaveFailed,
            hadPendingDraftSave: isDraftSavePending,
            suiteFile: suiteFile,
            draftFile: draftFile,
            catalogFile: catalogFile,
            stateFile: stateFile,
            repositoryFile: repositoryFile
        )
    }

    private func restoreCandidateAdoption(
        _ snapshot: CandidateAdoptionSnapshot,
        failureMessage: String
    ) throws {
        var rollbackErrors: [String] = []
        do { try restoreFile(snapshot.suiteFile) }
        catch { rollbackErrors.append("suite metadata: \(error.localizedDescription)") }
        if let repositoryFile = snapshot.repositoryFile {
            do { try restoreFile(repositoryFile) }
            catch { rollbackErrors.append("repository definition: \(error.localizedDescription)") }
        }
        do { try restoreFile(snapshot.draftFile) }
        catch { rollbackErrors.append("suite draft: \(error.localizedDescription)") }
        do { try restoreFile(snapshot.stateFile) }
        catch { rollbackErrors.append("experiment state: \(error.localizedDescription)") }
        if rollbackErrors.isEmpty {
            do { try restoreFile(snapshot.catalogFile) }
            catch { rollbackErrors.append("workspace catalog: \(error.localizedDescription)") }
        }
        if !rollbackErrors.isEmpty {
            let blocker = "\(failureMessage) Rollback also failed for \(rollbackErrors.joined(separator: "; "))."
            workspacePersistenceBlocker = blocker
            notice = blocker
            draftSaveFailed = true
            throw EvaluationStoreError.persistence(blocker)
        }
        suite = snapshot.suite
        draftSuite = snapshot.draft
        workspace = snapshot.workspace
        notice = snapshot.notice
        draftSaveFailed = snapshot.draftSaveFailed
        if snapshot.hadPendingDraftSave {
            scheduleSuiteSave()
        }
    }

    private func snapshotFile(at url: URL) throws -> PersistedFileSnapshot {
        let existed = FileManager.default.fileExists(atPath: url.path)
        guard existed else { return PersistedFileSnapshot(url: url, existed: false, data: nil) }
        do {
            return PersistedFileSnapshot(url: url, existed: true, data: try Data(contentsOf: url))
        } catch {
            throw EvaluationStoreError.persistence(
                "Could not read the existing file before saving: \(error.localizedDescription)"
            )
        }
    }

    private func restoreFile(_ snapshot: PersistedFileSnapshot) throws {
        if snapshot.existed {
            guard let data = snapshot.data else {
                throw EvaluationStoreError.persistence("The saved file snapshot is incomplete.")
            }
            try FileManager.default.createDirectory(
                at: snapshot.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: snapshot.url, options: .atomic)
            return
        }

        guard FileManager.default.fileExists(atPath: snapshot.url.path) else { return }
        let values = try snapshot.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true || values.isSymbolicLink == true else {
            throw EvaluationStoreError.persistence("A newly created path is not a regular file.")
        }
        try FileManager.default.removeItem(at: snapshot.url)
    }

    private func persistJudgeConnections(_ connections: [EvaluationJudgeConnection]) throws {
        do {
            try CanonicalJSON.data(for: connections).write(to: judgeConnectionsURL, options: .atomic)
        } catch {
            throw EvaluationStoreError.persistence(error.localizedDescription)
        }
    }

    private func resolvedJudge(connectionID: UUID) throws -> EvaluationResolvedJudgeConnection {
        guard let connection = judgeConnections.first(where: { $0.id == connectionID }) else {
            throw EvaluationStoreError.resourceNotFound("Judge connection")
        }
        let apiKey = try EvaluationJudgeCredentialStore.load(connectionID: connectionID)
        if connection.requiresAPIKey, apiKey?.isEmpty != false {
            throw EvaluationStoreError.resourceConflict("The selected judge connection has no API key in Keychain.")
        }
        return EvaluationResolvedJudgeConnection(connection: connection, apiKey: apiKey)
    }

    private func resolvedJudge(for suite: EvaluationSuite) throws -> EvaluationResolvedJudgeConnection? {
        guard suite.scoringMode == .modelJudge, suite.needsModelJudge,
              suite.judgeConfiguration.usesExternalConnection else { return nil }
        guard let connectionID = suite.judgeConfiguration.connectionID else {
            throw EvaluationStoreError.invalidSuite("Choose an independent judge connection.")
        }
        let resolved = try resolvedJudge(connectionID: connectionID)
        guard suite.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: resolved.connection) else {
            throw EvaluationCompatibleJudgeError.disclosureNotApproved
        }
        return resolved
    }

    private func persistRepositoryDefinitionIfLinked(_ candidate: EvaluationSuite) throws {
        guard let url = EvaluationWorkspacePersistence.repositoryDefinitionURL(
            project: selectedProject, suite: selectedSuiteRecord
        ) else { return }
        let definition = EvaluationSuiteDefinition(suite: candidate)
        let candidateRevision = try EvaluationWorkspacePersistence.definitionRevision(definition)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try CanonicalJSON.decode(EvaluationSuiteDefinition.self, from: Data(contentsOf: url))
            let existingRevision = try EvaluationWorkspacePersistence.definitionRevision(existing)
            if existingRevision != selectedSuiteRecord.lastRepositoryRevision,
               existingRevision != candidateRevision {
                throw EvaluationWorkspaceError.repositoryConflict
            }
            if existingRevision == candidateRevision {
                if selectedSuiteRecord.lastRepositoryRevision != candidateRevision {
                    try updateSelectedSuiteRecord { record in
                        record.lastRepositoryRevision = candidateRevision
                        record.updatedAt = Date()
                    }
                }
                return
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CanonicalJSON.data(for: definition).write(to: url, options: .atomic)
        try updateSelectedSuiteRecord { record in record.lastRepositoryRevision = candidateRevision }
    }

    private static func copyAttachmentFiles(
        from source: URL,
        to target: URL,
        suite: EvaluationSuite
    ) throws {
        let referencedFilenames = suite.attachments.compactMap(\.storedFilename)
        let sourceExists = FileManager.default.fileExists(atPath: source.path)
        if !sourceExists {
            if !referencedFilenames.isEmpty {
                throw EvaluationStoreError.persistence(
                    "Referenced attachments are missing from the source suite."
                )
            }
            return
        }
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: source, includingPropertiesForKeys: nil
            )
        } catch {
            throw EvaluationStoreError.persistence(
                "Could not copy referenced attachments: \(error.localizedDescription)"
            )
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for child in children {
            let destination = target.appending(path: child.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: child, to: destination)
            }
        }
        for filename in referencedFilenames {
            let destination = target.appending(path: filename)
            guard FileManager.default.fileExists(atPath: destination.path) else {
                throw EvaluationStoreError.persistence(
                    "Duplication is missing referenced attachment \(filename)."
                )
            }
        }
    }

    private static func repositorySlug(_ value: String) -> String {
        let lowered = value.lowercased()
        let mapped = lowered.map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let slug = String(mapped).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
        return slug.isEmpty ? "suite" : slug
    }

    private static func loadDraft(
        from directory: URL,
        canonicalSuite: EvaluationSuite
    ) -> (suite: EvaluationSuite?, notice: String?) {
        let url = directory.appending(path: "suite-draft.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        do {
            let record = try CanonicalJSON.decode(SuiteDraftRecord.self, from: Data(contentsOf: url))
            guard record.suite.id == canonicalSuite.id,
                  record.canonicalRevision == (try revision(for: canonicalSuite)) else {
                let backup = directory.appending(path: "suite-draft-stale-\(UUID().uuidString).json")
                do {
                    try FileManager.default.moveItem(at: url, to: backup)
                    return (nil, "An older draft did not match the current suite. It was ignored and preserved as \(backup.lastPathComponent).")
                } catch {
                    return (nil, "An older draft did not match the current suite and was ignored. It could not be moved: \(error.localizedDescription)")
                }
            }
            return (record.suite, nil)
        } catch {
            let backup = directory.appending(path: "suite-draft-unreadable-\(UUID().uuidString).json")
            do {
                try FileManager.default.moveItem(at: url, to: backup)
                return (nil, "The saved draft could not be read. It was preserved as \(backup.lastPathComponent).")
            } catch {
                return (nil, "The saved draft could not be read and was left unchanged for recovery: \(error.localizedDescription)")
            }
        }
    }

    private static func loadRuns(
        from directory: URL,
        projectID: UUID,
        suiteID: UUID
    ) -> (runs: [EvaluationRun], notice: String?, hasUnreadableFiles: Bool) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return ([], nil, false) }

        var unreadableCount = 0
        var ignoredCount = 0
        let runs = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (run: EvaluationRun, modifiedAt: Date, filename: String)? in
                guard let data = try? Data(contentsOf: url),
                      let run = try? CanonicalJSON.decode(EvaluationRun.self, from: data) else {
                    unreadableCount += 1
                    return nil
                }
                guard url.deletingPathExtension().lastPathComponent == run.id.uuidString,
                      run.suiteID == suiteID,
                      run.projectID == nil || run.projectID == projectID else {
                    ignoredCount += 1
                    return nil
                }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return (run, values?.contentModificationDate ?? .distantPast, url.lastPathComponent)
            }
            .sorted { lhs, rhs in
                let lhsSequence = lhs.run.historySequence ?? 0
                let rhsSequence = rhs.run.historySequence ?? 0
                if lhsSequence != rhsSequence {
                    return lhsSequence > rhsSequence
                }
                if lhs.run.startedAt != rhs.run.startedAt {
                    return lhs.run.startedAt > rhs.run.startedAt
                }
                if lhs.run.completedAt != rhs.run.completedAt {
                    return lhs.run.completedAt > rhs.run.completedAt
                }
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                return lhs.filename > rhs.filename
            }
            .map(\.run)
        let unreadableNotice = unreadableCount == 0
            ? nil
            : "\(unreadableCount) saved run\(unreadableCount == 1 ? "" : "s") could not be read and was left unchanged on disk."
        let ignoredNotice = ignoredCount == 0
            ? nil
            : "\(ignoredCount) run file\(ignoredCount == 1 ? "" : "s") did not belong to this suite and was ignored."
        let messages = [unreadableNotice, ignoredNotice].compactMap { $0 }
        let notice = messages.isEmpty ? nil : messages.joined(separator: "\n")
        return (runs, notice, unreadableCount > 0)
    }

    private static func loadActiveRun(from url: URL) -> ActiveRunRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CanonicalJSON.decode(ActiveRunRecord.self, from: data)
    }

    private static func recoverInterruptedRun(
        from activeRunURL: URL,
        runsDirectory: URL,
        existingRuns: [EvaluationRun]
    ) -> (run: EvaluationRun?, pending: ActiveRunRecord?, notice: String?) {
        guard FileManager.default.fileExists(atPath: activeRunURL.path) else { return (nil, nil, nil) }
        guard let record = loadActiveRun(from: activeRunURL) else {
            return (nil, nil, "An unreadable active-run record was left unchanged for recovery.")
        }
        if existingRuns.contains(where: { $0.id == record.summary.id }) {
            try? FileManager.default.removeItem(at: activeRunURL)
            return (nil, nil, nil)
        }

        let suite = record.suite
        var run = record.completedRun ?? EvaluationRun(
            id: record.summary.id,
            suiteID: suite.id,
            suiteName: suite.name,
            suiteVersion: suite.version,
            instructions: suite.instructions,
            criteria: suite.criteria,
            scoringMode: suite.scoringMode,
            repetitions: suite.repetitions,
            judgePromptVersion: nil,
            judgePassingScore: suite.scoringMode == .modelJudge ? EvaluationSuite.judgePassingScore : nil,
            plannedSampleCount: record.summary.totalSamples,
            suiteRevision: record.summary.suiteRevision,
            plannedCases: suite.cases,
            startedAt: record.summary.startedAt,
            completedAt: Date(),
            cancelled: false,
            terminationReason: "interrupted",
            environment: EvaluationEnvironment(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                locale: Locale.current.identifier,
                model: "\(suite.modelConfiguration.provider.title) (interrupted)",
                modelContextSize: 0
            ),
            attachments: suite.attachments.map {
                EvaluationAttachmentTrace(
                    name: $0.name,
                    kind: $0.kind,
                    byteCount: $0.byteCount,
                    sha256: $0.sha256
                )
            },
            results: record.results ?? [],
            execution: EvaluationExecutionTrace(
                behaviorVersion: EvaluationModelConfiguration.currentBehaviorVersion,
                configuration: suite.modelConfiguration,
                modelDisplayName: suite.modelConfiguration.provider.title,
                capabilities: [],
                toolNames: [],
                features: suite.features
            ),
            projectID: record.summary.projectID,
            suiteDefinition: EvaluationSuiteDefinition(suite: suite),
            subjectEvidence: record.subjectEvidence
        )
        if run.historySequence == nil {
            let existingMaximum = existingRuns.compactMap(\.historySequence).max() ?? 0
            let wallClockMicroseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
            run.historySequence = max(existingMaximum + 1, wallClockMicroseconds)
        }
        do {
            try CanonicalJSON.data(for: run).write(
                to: runsDirectory.appending(path: "\(run.id.uuidString).json"),
                options: .atomic
            )
        } catch {
            var pending = record
            pending.completedRun = run
            pending.results = run.results
            pending.summary.completedSamples = run.results.count
            return (nil, pending, "The previous run could not be saved. Restore storage access and try again: \(error.localizedDescription)")
        }
        do {
            try FileManager.default.removeItem(at: activeRunURL)
            return (run, nil, "A run from the previous app session was preserved in history.")
        } catch {
            return (run, nil, "The interrupted run was preserved, but its recovery marker could not be removed: \(error.localizedDescription)")
        }
    }

    private static var hasAuthorizedPrivateCloudComputeSignature: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let entitlement = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.private-cloud-compute" as CFString,
                nil
              ),
              entitlement as? Bool == true,
              let teamIdentifier = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.team-identifier" as CFString,
                nil
              ) as? String else { return false }
        return !teamIdentifier.isEmpty
    }
}

enum EvaluationStoreError: LocalizedError, Sendable {
    case staleRevision(current: String)
    case runBusy
    case fileOperationBusy
    case invalidSuite(String)
    case deletionConfirmationRequired
    case resourceConflict(String)
    case resourceNotFound(String)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .staleRevision(let current):
            "The suite changed. Read it again and retry with revision \(current)."
        case .runBusy:
            "Cancel or finish the current run before changing the suite."
        case .fileOperationBusy:
            "Wait for the current file operation to finish."
        case .invalidSuite(let issue):
            issue
        case .deletionConfirmationRequired:
            "Confirm case deletion before replacing the suite."
        case .resourceConflict(let message):
            message
        case .resourceNotFound(let resource):
            "\(resource) was not found."
        case .persistence(let message):
            "The change could not be saved: \(message)"
        }
    }
}

private struct AttachmentInput: Sendable {
    var id: UUID
    var name: String
    var mediaType: String
    var data: Data
}

private struct PreparedAttachment: Sendable {
    var attachment: EvaluationAttachment
    var imageData: Data?
    var truncated: Bool
}

private struct PersistedFileSnapshot {
    let url: URL
    let existed: Bool
    let data: Data?
}

private struct CandidateAdoptionSnapshot {
    let suite: EvaluationSuite
    let draft: EvaluationSuite
    let workspace: EvaluationWorkspaceCatalog
    let notice: String?
    let draftSaveFailed: Bool
    let hadPendingDraftSave: Bool
    let suiteFile: PersistedFileSnapshot
    let draftFile: PersistedFileSnapshot
    let catalogFile: PersistedFileSnapshot
    let stateFile: PersistedFileSnapshot
    let repositoryFile: PersistedFileSnapshot?
}

private struct ActiveRunRecord: Codable, Sendable {
    var summary: EvaluationActiveRun
    var suite: EvaluationSuite
    var results: [EvaluationSampleResult]?
    var completedRun: EvaluationRun? = nil
    var subjectEvidence: EvaluationSubjectEvidenceSnapshot? = nil
}

private struct EvaluationPersistedRunLocation {
    var projectID: UUID
    var suiteID: UUID
    var runURL: URL
    var run: EvaluationRun
}

private struct SuiteDraftRecord: Codable {
    var canonicalRevision: String
    var suite: EvaluationSuite
}

private struct SuiteRevisionPayload: Codable {
    var id: UUID
    var name: String
    var version: String
    var instructions: String
    var rubricCriteria: [String]
    var scoringMode: ScoringMode
    var repetitions: Int
    var modelConfiguration: EvaluationModelConfiguration
    var features: EvaluationFeatureConfiguration
    var cases: [EvaluationCase]
    var attachments: [RevisionAttachment]
    var judgeConfiguration: EvaluationJudgeConfiguration
    var releasePolicy: EvaluationReleasePolicy
}

private struct RevisionAttachment: Codable {
    var id: UUID
    var name: String
    var kind: EvaluationAttachmentKind
    var byteCount: Int
    var sha256: String
}
