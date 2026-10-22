import CryptoKit
import Darwin
import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct EvaluationWorkspaceRepairTests {
    @Test(arguments: [false, true])
    func duplicationFlushesVisiblePromptEdits(duplicatesProject: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let caseID = store.draftSuite.cases[0].id
        store.draftSuite.name = "Visible name"
        store.editPrompt("Visible prompt before the autosave fires", for: caseID)
        #expect(store.isDraftSavePending)

        let copied = try duplicatedSuite(in: store, duplicatesProject: duplicatesProject)

        #expect(copied.name == "Visible name copy")
        #expect(copied.cases.first { $0.id == caseID }?.prompt == "Visible prompt before the autosave fires")
        #expect(!store.isDraftSavePending)
        #expect(store.suite.cases.first { $0.id == caseID }?.prompt == copied.cases.first { $0.id == caseID }?.prompt)
    }

    @Test(arguments: [false, true])
    func duplicationRejectsAnInvalidVisibleDraftAndAllowsCorrection(duplicatesProject: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let caseID = store.draftSuite.cases[0].id
        let originalPrompt = store.suite.cases[0].prompt
        store.editPrompt("", for: caseID)

        #expect(throws: EvaluationStoreError.self) {
            _ = try duplicatedSuite(in: store, duplicatesProject: duplicatesProject)
        }
        #expect(store.projects.count == 1)
        #expect(store.suiteRecords.count == 1)
        #expect(store.suite.cases[0].prompt == originalPrompt)
        #expect(store.promptText(for: caseID).isEmpty)

        store.editPrompt("Corrected visible prompt", for: caseID)
        let copied = try duplicatedSuite(in: store, duplicatesProject: duplicatesProject)
        #expect(copied.cases.first { $0.id == caseID }?.prompt == "Corrected visible prompt")
    }

    @Test(arguments: [false, true])
    func duplicationPreservesTheDraftAfterStorageFailureAndCanRetry(duplicatesProject: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var rejectsWrites = false
        let store = EvaluationStore(supportDirectory: directory, workspaceCatalogWriter: { catalog, root in
            if rejectsWrites { throw CocoaError(.fileWriteNoPermission) }
            try EvaluationWorkspacePersistence.save(catalog, in: root)
        })
        let caseID = store.draftSuite.cases[0].id
        let originalPrompt = store.suite.cases[0].prompt
        store.editPrompt("Retain this draft across a failed save", for: caseID)
        rejectsWrites = true

        #expect(throws: EvaluationStoreError.self) {
            _ = try duplicatedSuite(in: store, duplicatesProject: duplicatesProject)
        }
        #expect(store.projects.count == 1)
        #expect(store.suiteRecords.count == 1)
        #expect(store.suite.cases[0].prompt == originalPrompt)
        #expect(store.promptText(for: caseID) == "Retain this draft across a failed save")

        rejectsWrites = false
        let copied = try duplicatedSuite(in: store, duplicatesProject: duplicatesProject)
        #expect(copied.cases.first { $0.id == caseID }?.prompt == "Retain this draft across a failed save")
    }

    @Test func failedLocalStatePreservationBlocksReplacementAndRetriesAfterConflictRemoval() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalSuiteID = store.selectedSuiteID
        let otherSuiteID = try store.createSuite(name: "Other suite")
        try store.switchSuite(id: originalSuiteID)
        let suiteDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: store.selectedProjectID, suiteID: originalSuiteID)
        let stateURL = suiteDirectory.appending(path: "state.json")
        let original = Data("{ damaged state to preserve".utf8)
        try original.write(to: stateURL, options: .atomic)
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let backupURL = suiteDirectory.appending(path: "state-unreadable-\(digest).json")
        let conflicting = Data("unrelated backup bytes".utf8)
        try conflicting.write(to: backupURL, options: .atomic)

        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.notice?.contains("could not be preserved") == true)
        #expect(throws: EvaluationStoreError.self) {
            try reloaded.commitReviewLocalState(EvaluationSuiteLocalState())
        }
        try reloaded.switchSuite(id: otherSuiteID)
        #expect(reloaded.selectedSuiteID == otherSuiteID)
        #expect(try Data(contentsOf: stateURL) == original)
        #expect(try Data(contentsOf: backupURL) == conflicting)
        try reloaded.switchSuite(id: originalSuiteID)
        #expect(throws: EvaluationStoreError.self) {
            try reloaded.commitReviewLocalState(EvaluationSuiteLocalState())
        }
        #expect(try Data(contentsOf: stateURL) == original)

        try FileManager.default.removeItem(at: backupURL)
        try reloaded.switchSuite(id: originalSuiteID)
        #expect(reloaded.selectedSuiteID == originalSuiteID)
        #expect(try Data(contentsOf: backupURL) == original)
        try reloaded.commitReviewLocalState(EvaluationSuiteLocalState())
        #expect(try CanonicalJSON.decode(EvaluationSuiteLocalState.self, from: Data(contentsOf: stateURL)).baselineApprovals.isEmpty)
    }

    @Test(.enabled(if: geteuid() != 0, "File read permissions require an unprivileged process."))
    func unreadableLocalStateKeepsItsOriginalApprovalsWhenAccessReturns() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalSuiteID = store.selectedSuiteID
        let otherSuiteID = try store.createSuite(name: "Other suite")
        try store.switchSuite(id: originalSuiteID)
        var localState = EvaluationSuiteLocalState()
        let approvalID = UUID()
        localState.baselineApprovals = [.init(id: approvalID, runID: UUID(), assessmentID: nil,
            suiteRevision: store.suiteRevision, approvedAt: Date(), note: "Retain this approval", revokedAt: nil)]
        try store.commitReviewLocalState(localState)
        let stateURL = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: store.selectedProjectID, suiteID: originalSuiteID)
            .appending(path: "state.json")
        let original = try Data(contentsOf: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: stateURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path) }

        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.notice?.contains("could not be preserved") == true)
        #expect(throws: EvaluationStoreError.self) {
            try reloaded.commitReviewLocalState(EvaluationSuiteLocalState())
        }
        try reloaded.switchSuite(id: otherSuiteID)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        #expect(try Data(contentsOf: stateURL) == original)
        try reloaded.switchSuite(id: originalSuiteID)
        #expect(reloaded.suiteLocalState.baselineApprovals.map(\.id) == [approvalID])
        try reloaded.switchSuite(id: otherSuiteID)
        let retained = try CanonicalJSON.decode(EvaluationSuiteLocalState.self, from: Data(contentsOf: stateURL))
        #expect(retained.baselineApprovals.map(\.id) == [approvalID])
    }

    private func duplicatedSuite(in store: EvaluationStore, duplicatesProject: Bool) throws -> EvaluationSuite {
        let projectID: UUID
        let suiteID: UUID
        if duplicatesProject {
            projectID = try store.duplicateProject(id: store.selectedProjectID)
            let project = try #require(store.projects.first { $0.id == projectID })
            suiteID = try #require(project.suites.first?.id)
        } else {
            projectID = store.selectedProjectID
            suiteID = try store.duplicateSuite(id: store.selectedSuiteID)
        }
        let directory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: store.overviewStorageDirectory, projectID: projectID, suiteID: suiteID)
        return try #require(EvaluationWorkspaceStatePersistence.loadSuite(from: directory).suite)
    }

    @Test func corruptDestinationIsPreservedBeforeRecoveringAnUnmarkedWorkspace() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let corrupt = Data("{ damaged current state".utf8)
        try corrupt.write(to: fixture.target.appending(path: "state.json"))
        let first = try EvaluationWorkspacePersistence.bootstrap(in: fixture.directory, legacySuite: fixture.suite)
        #expect(first.notice?.contains("fresh review") == true)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.target, includingPropertiesForKeys: nil)
        let backup = try #require(files.first { $0.lastPathComponent.hasPrefix("state-unreadable-") })
        #expect(try Data(contentsOf: backup) == corrupt)
        #expect(try Data(contentsOf: fixture.directory.appending(path: "state.json")) == fixture.legacyData)
        #expect(EvaluationWorkspacePersistence.hasCompletedLegacyStateMigration(in: fixture.target))
        let recovered = try Data(contentsOf: fixture.target.appending(path: "state.json"))
        let second = try EvaluationWorkspacePersistence.bootstrap(in: fixture.directory, legacySuite: fixture.suite)
        #expect(second.notice == nil)
        #expect(second.catalog == first.catalog)
        #expect(try Data(contentsOf: fixture.target.appending(path: "state.json")) == recovered)
    }

    @Test func corruptDestinationWithoutLegacyIsPreserved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let corrupt = Data("{ damaged".utf8)
        try corrupt.write(to: fixture.target.appending(path: "state.json"))
        try FileManager.default.removeItem(at: fixture.directory.appending(path: "state.json"))
        let result = try EvaluationWorkspacePersistence.bootstrap(in: fixture.directory, legacySuite: fixture.suite)
        #expect(result.notice == nil)
        #expect(try Data(contentsOf: fixture.target.appending(path: "state.json")) == corrupt)
    }

    @Test func corruptDestinationWithCorruptLegacyIsLeftForLoadNotice() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let corrupt = Data("{ current damaged".utf8)
        try corrupt.write(to: fixture.target.appending(path: "state.json"))
        try Data("{ legacy damaged".utf8).write(to: fixture.directory.appending(path: "state.json"))
        let result = try EvaluationWorkspacePersistence.bootstrap(in: fixture.directory, legacySuite: fixture.suite)
        #expect(result.notice == nil)
        #expect(try Data(contentsOf: fixture.target.appending(path: "state.json")) == corrupt)
        let loaded = EvaluationWorkspaceStatePersistence.loadSuiteLocalState(from: fixture.target.appending(path: "state.json"))
        #expect(loaded.notice != nil)
        #expect(loaded.state.baselineApprovals.isEmpty)
    }

    @Test func failedPreservationDoesNotDeleteOrReplaceCurrentState() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let corrupt = Data("{ current damaged".utf8)
        try corrupt.write(to: fixture.target.appending(path: "state.json"))
        let digest = SHA256.hash(data: corrupt).map { String(format: "%02x", $0) }.joined()
        // A deterministic conflicting archive works even when tests run with
        // privileges that bypass chmod-based failure injection.
        let backup = fixture.target.appending(path: "state-unreadable-\(digest).json")
        try Data("unrelated bytes".utf8).write(to: backup)
        let result = try EvaluationWorkspacePersistence.bootstrap(in: fixture.directory, legacySuite: fixture.suite)
        #expect(result.notice?.contains("could not be repaired") == true)
        #expect(try Data(contentsOf: fixture.target.appending(path: "state.json")) == corrupt)
        #expect(try Data(contentsOf: backup) == Data("unrelated bytes".utf8))
        #expect(!EvaluationWorkspacePersistence.hasCompletedLegacyStateMigration(in: fixture.target))
        // Storage recovery permits a safe retry; no active historical state was
        // exposed by the failed attempt.
        try FileManager.default.removeItem(at: backup)
        let retry = try EvaluationWorkspacePersistence.bootstrap(in: fixture.directory, legacySuite: fixture.suite)
        #expect(retry.notice?.contains("fresh review") == true)
    }

    @Test func unreadableDestinationDoesNotTriggerDestructiveCleanup() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let stateURL = fixture.target.appending(path: "state.json")
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
        let evidence = stateURL.appending(path: "evidence")
        try Data("must remain".utf8).write(to: evidence)
        let result = try EvaluationWorkspacePersistence.bootstrap(in: fixture.directory, legacySuite: fixture.suite)
        #expect(result.notice?.contains("could not be repaired") == true)
        #expect(try Data(contentsOf: evidence) == Data("must remain".utf8))
    }

    @Test func initialMigrationWithoutLocalStateCreatesASealedEmptyState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = EvaluationSuite()
        try CanonicalJSON.data(for: suite).write(to: directory.appending(path: "suite.json"))
        let result = try EvaluationWorkspacePersistence.bootstrap(in: directory, legacySuite: suite)
        let target = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: result.catalog.selectedProjectID, suiteID: suite.id)
        let loaded = EvaluationWorkspaceStatePersistence.loadSuiteLocalState(from: target.appending(path: "state.json"))
        #expect(loaded.notice == nil)
        #expect(loaded.state.baselineApprovals.isEmpty)
        #expect(EvaluationWorkspacePersistence.hasCompletedLegacyStateMigration(in: target))
    }

    @Test func duplicateImportWithStaleRevisionStaysIdempotent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let id = UUID()
        let data = Data("duplicate reference".utf8)
        let first = try await store.importAttachment(
            id: id, name: "reference.txt", mediaType: "text/plain", data: data,
            expectedRevision: store.suiteRevision)
        let staleRevision = first.revision
        _ = try await store.importAttachment(
            id: UUID(), name: "other.txt", mediaType: "text/plain", data: Data("other".utf8),
            expectedRevision: store.suiteRevision)
        #expect(store.suiteRevision != staleRevision)
        let duplicate = try await store.importAttachment(
            id: id, name: "reference.txt", mediaType: "text/plain", data: data,
            expectedRevision: staleRevision)
        #expect(duplicate.duplicate)
        #expect(duplicate.attachment == first.attachment)
        #expect(duplicate.revision == store.suiteRevision)
        #expect(store.suite.attachments.count == 2)
    }

    @Test func unreadableCatalogIsPreservedAndDoesNotDestroyExistingProjects() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalProjectID = store.selectedProjectID
        let originalSuiteID = store.selectedSuiteID
        store.draftSuite.name = "Keep this suite"
        #expect(store.saveSuite())
        let catalogURL = directory.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        let corrupt = Data("{ damaged catalog".utf8)
        try corrupt.write(to: catalogURL, options: .atomic)
        let projectDirectory = directory
            .appending(path: "Projects/\(originalProjectID.uuidString)", directoryHint: .isDirectory)

        let recovered = EvaluationStore(supportDirectory: directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backup = try #require(files.first { $0.lastPathComponent.hasPrefix("workspace-v1-unreadable-") })
        #expect(try Data(contentsOf: backup) == corrupt)
        #expect(recovered.projects.contains { $0.name == "Recovery workspace" })
        #expect(FileManager.default.fileExists(atPath: projectDirectory.path))
        #expect(FileManager.default.fileExists(
            atPath: EvaluationWorkspacePersistence.suiteDirectory(
                supportDirectory: directory, projectID: originalProjectID, suiteID: originalSuiteID
            ).appending(path: "suite.json").path
        ))
        #expect(recovered.selectedProjectID == recovered.projects.first { $0.name == "Recovery workspace" }?.id)
    }

    @Test func catalogWithEmptySuitesDoesNotCrashAndPreservesOriginalBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let catalogURL = directory.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        var catalog = try CanonicalJSON.decode(EvaluationWorkspaceCatalog.self, from: Data(contentsOf: catalogURL))
        catalog.projects[0].suites = []
        let original = try CanonicalJSON.data(for: catalog)
        try original.write(to: catalogURL, options: .atomic)

        let recovered = EvaluationStore(supportDirectory: directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backup = try #require(files.first { $0.lastPathComponent.hasPrefix("workspace-v1-unreadable-") })
        #expect(try Data(contentsOf: backup) == original)
        #expect(recovered.projects.contains { !$0.suites.isEmpty })
        #expect(recovered.selectedSuiteRecord.id == recovered.selectedSuiteID)
    }

    @Test func missingSelectedProjectIDIsRepairedWithoutCreatingARecoveryWorkspace() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalProjectID = store.selectedProjectID
        let catalogURL = directory.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        var catalog = try CanonicalJSON.decode(EvaluationWorkspaceCatalog.self, from: Data(contentsOf: catalogURL))
        catalog.selectedProjectID = UUID()
        try CanonicalJSON.data(for: catalog).write(to: catalogURL, options: .atomic)

        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.selectedProjectID == originalProjectID)
        #expect(!reloaded.projects.contains { $0.name == "Recovery workspace" })
        #expect(reloaded.projects.contains { $0.id == originalProjectID })
    }

    @Test func unsavedSelectionRepairKeepsTheOriginalCatalog() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalProjectID = store.selectedProjectID
        let originalSuiteID = store.selectedSuiteID
        let catalogURL = directory.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        var catalog = try CanonicalJSON.decode(
            EvaluationWorkspaceCatalog.self,
            from: Data(contentsOf: catalogURL)
        )
        catalog.selectedProjectID = UUID()
        catalog.projects[0].selectedSuiteID = UUID()
        let staleCatalog = try CanonicalJSON.data(for: catalog)
        try staleCatalog.write(to: catalogURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }

        let reloaded = EvaluationStore(supportDirectory: directory)

        #expect(reloaded.selectedProjectID == originalProjectID)
        #expect(reloaded.selectedSuiteID == originalSuiteID)
        #expect(!reloaded.projects.contains { $0.name == "Recovery workspace" })
        #expect(reloaded.migrationNotice?.contains("repaired in memory but could not be saved") == true)
        #expect(try Data(contentsOf: catalogURL) == staleCatalog)
    }

    @Test func failedCatalogPreservationKeepsRecoveryWorkspaceReadOnly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = EvaluationStore(supportDirectory: directory)
        let catalogURL = directory.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        let corruptCatalog = Data("{ damaged catalog".utf8)
        try corruptCatalog.write(to: catalogURL, options: .atomic)
        let digest = SHA256.hash(data: corruptCatalog).map { String(format: "%02x", $0) }.joined()
        let backupURL = directory.appending(path: "workspace-v1-unreadable-\(digest).json")
        try Data("conflicting backup".utf8).write(to: backupURL, options: .atomic)

        let recovered = EvaluationStore(supportDirectory: directory)
        let workspaceBeforeMutation = recovered.workspace
        let draftBeforeMutation = recovered.draftSuite
        let pathsBeforeMutation = try FileManager.default.subpathsOfDirectory(atPath: directory.path).sorted()

        #expect(throws: EvaluationStoreError.self) {
            _ = try recovered.createProject(name: "Must not be created")
        }
        #expect(throws: EvaluationStoreError.self) {
            try recovered.renameProject(id: recovered.selectedProjectID, name: "Must not be renamed")
        }
        #expect(throws: EvaluationStoreError.self) {
            _ = try recovered.deleteRunDurably(id: UUID())
        }
        recovered.addCase()
        recovered.editPrompt("Must not be buffered", for: recovered.draftSuite.cases[0].id)

        recovered.draftSuite.name = "Must not replace the unreadable catalog"

        #expect(!recovered.saveSuite())
        #expect(recovered.workspace == workspaceBeforeMutation)
        #expect(recovered.draftSuite.cases == draftBeforeMutation.cases)
        #expect(
            recovered.promptText(for: recovered.draftSuite.cases[0].id)
                == draftBeforeMutation.cases[0].prompt
        )
        #expect(try Data(contentsOf: catalogURL) == corruptCatalog)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: directory.path).sorted() == pathsBeforeMutation)
        #expect(recovered.notice?.contains("could not be preserved") == true)
    }

    @Test func archivedCatalogSelectionsAreRepairedToActiveRecords() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let activeProjectID = store.selectedProjectID
        let archivedSuiteID = store.selectedSuiteID
        let activeSuiteID = try store.createSuite(name: "Active suite")
        let archivedProjectID = try store.createProject(name: "Archived project")
        let catalogURL = directory.appending(path: EvaluationWorkspacePersistence.catalogFilename)
        var catalog = try CanonicalJSON.decode(
            EvaluationWorkspaceCatalog.self,
            from: Data(contentsOf: catalogURL)
        )
        let activeProjectIndex = try #require(catalog.projects.firstIndex { $0.id == activeProjectID })
        let archivedSuiteIndex = try #require(
            catalog.projects[activeProjectIndex].suites.firstIndex { $0.id == archivedSuiteID }
        )
        catalog.projects[activeProjectIndex].suites[archivedSuiteIndex].archivedAt = Date()
        catalog.projects[activeProjectIndex].selectedSuiteID = archivedSuiteID
        let archivedProjectIndex = try #require(catalog.projects.firstIndex { $0.id == archivedProjectID })
        catalog.projects[archivedProjectIndex].archivedAt = Date()
        catalog.selectedProjectID = archivedProjectID
        try CanonicalJSON.data(for: catalog).write(to: catalogURL, options: .atomic)

        let reloaded = EvaluationStore(supportDirectory: directory)

        #expect(reloaded.selectedProjectID == activeProjectID)
        #expect(reloaded.selectedSuiteID == activeSuiteID)
        #expect(reloaded.selectedProject.isArchived == false)
        #expect(reloaded.selectedSuiteRecord.isArchived == false)
    }

    private func makeFixture() throws -> (directory: URL, target: URL, suite: EvaluationSuite, legacyData: Data) {
        let directory = try temporaryDirectory()
        let suite = EvaluationSuite()
        let now = Date()
        let project = EvaluationProject(
            id: UUID(), name: "Legacy", createdAt: now, updatedAt: now, archivedAt: nil,
            repository: nil, selectedSuiteID: suite.id,
            suites: [.init(id: suite.id, name: suite.name, createdAt: now, updatedAt: now,
                archivedAt: nil, repositoryDefinitionPath: nil, lastRepositoryRevision: nil)])
        let catalog = EvaluationWorkspaceCatalog(selectedProjectID: project.id, projects: [project], migratedLegacyStorageAt: nil)
        try EvaluationWorkspacePersistence.save(catalog, in: directory)
        let target = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: project.id, suiteID: suite.id)
        try EvaluationWorkspacePersistence.createSuiteDirectories(at: target)
        let data = try CanonicalJSON.data(for: EvaluationSuiteLocalState())
        try data.write(to: directory.appending(path: "state.json"))
        try CanonicalJSON.data(for: suite).write(to: directory.appending(path: "suite.json"))
        try CanonicalJSON.data(for: suite).write(to: target.appending(path: "suite.json"))
        return (directory, target, suite, data)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WorkspaceRepair-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
