import CryptoKit
import Foundation
import Darwin

struct EvaluationWorkspaceBootstrap {
    var catalog: EvaluationWorkspaceCatalog
    var notice: String?
}

enum EvaluationWorkspacePersistence {
    static let catalogFilename = "workspace-v1.json"
    /// Presence, including an unreadable marker, closes automatic legacy import.
    /// Keep this outside state.json so losing the state cannot reopen migration.
    static let legacyStateMigrationFilename = "legacy-state-migration-complete-v1"

    static func bootstrap(
        in supportDirectory: URL,
        legacySuite: EvaluationSuite?
    ) throws -> EvaluationWorkspaceBootstrap {
        let catalogURL = supportDirectory.appending(path: catalogFilename)
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            let catalogData = try Data(contentsOf: catalogURL)
            let decoded: EvaluationWorkspaceCatalog
            do {
                decoded = try CanonicalJSON.decode(EvaluationWorkspaceCatalog.self, from: catalogData)
            } catch {
                try preserveUnreadableFile(
                    catalogData,
                    in: supportDirectory,
                    prefix: "workspace-v1-unreadable"
                )
                throw EvaluationWorkspaceError.unsupportedCatalog
            }
            let catalog: EvaluationWorkspaceCatalog
            do {
                catalog = try validatedCatalog(decoded)
            } catch {
                try preserveUnreadableFile(
                    catalogData,
                    in: supportDirectory,
                    prefix: "workspace-v1-unreadable"
                )
                throw error
            }
            if catalog != decoded {
                do {
                    try save(catalog, in: supportDirectory)
                } catch {
                    return EvaluationWorkspaceBootstrap(
                        catalog: catalog,
                        notice: "Workspace selection was repaired in memory but could not be saved: \(error.localizedDescription)"
                    )
                }
            }

            guard let legacySuite,
                  let matchingProject = catalog.projects.first(where: {
                      $0.suites.contains { $0.id == legacySuite.id }
                  }),
                  let matchingSuite = matchingProject.suites.first(where: {
                      $0.id == legacySuite.id
                  }) else {
                return EvaluationWorkspaceBootstrap(catalog: catalog)
            }

            let target = suiteDirectory(
                supportDirectory: supportDirectory,
                projectID: matchingProject.id,
                suiteID: matchingSuite.id
            )
            // Older releases omitted local state from some migrations. An
            // unmarked workspace cannot prove that legacy decisions are current.
            // Recover evidence once, but never reactivate historical authority.
            do {
                try createSuiteDirectories(at: target)
                let recovered = try recoverUnmigratedLegacyState(from: supportDirectory, to: target)
                guard recovered else {
                    return EvaluationWorkspaceBootstrap(catalog: catalog)
                }
                var repairedCatalog = catalog
                repairedCatalog.migratedLegacyStorageAt = Date(
                    timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)
                )
                try save(repairedCatalog, in: supportDirectory)
                return EvaluationWorkspaceBootstrap(
                    catalog: repairedCatalog,
                    notice: "An older legacy state snapshot was recovered. Its exact bytes were preserved beside the suite as state-recovered-legacy-*.json. Historical baseline approvals were revoked; corrections, judge-check examples and experiment decisions require fresh review."
                )
            } catch {
                // All replacements are atomic. Never delete the current state
                // merely because a legacy source exists or a catalog save failed.
                return EvaluationWorkspaceBootstrap(
                    catalog: catalog,
                    notice: "Legacy state could not be repaired: \(error.localizedDescription)"
                )
            }
        }

        let now = Date()
        let seedSuite = legacySuite ?? EvaluationSuite()
        let suiteRecord = EvaluationSuiteRecord(
            id: seedSuite.id,
            name: seedSuite.name,
            createdAt: now,
            updatedAt: now,
            archivedAt: nil,
            repositoryDefinitionPath: nil,
            lastRepositoryRevision: nil
        )
        let project = EvaluationProject(
            id: UUID(),
            name: legacySuite == nil ? "My App" : "Imported workspace",
            createdAt: now,
            updatedAt: now,
            archivedAt: nil,
            repository: nil,
            selectedSuiteID: seedSuite.id,
            suites: [suiteRecord]
        )
        var catalog = EvaluationWorkspaceCatalog(
            selectedProjectID: project.id,
            projects: [project],
            migratedLegacyStorageAt: nil
        )
        let target = suiteDirectory(
            supportDirectory: supportDirectory,
            projectID: project.id,
            suiteID: seedSuite.id
        )
        try createSuiteDirectories(at: target)

        var migrated = false
        if legacySuite != nil {
            migrated = try copyLegacyStorage(from: supportDirectory, to: target)
            let stateURL = target.appending(path: "state.json")
            if !FileManager.default.fileExists(atPath: stateURL.path) {
                try CanonicalJSON.data(for: EvaluationSuiteLocalState()).write(to: stateURL, options: .atomic)
            }
            // Seal before publishing the new workspace. Future missing/corrupt
            // state is recovery, not permission to repeat the initial import.
            try completeLegacyStateMigration(in: target)
        }
        let suiteURL = target.appending(path: "suite.json")
        if !FileManager.default.fileExists(atPath: suiteURL.path) {
            try CanonicalJSON.data(for: seedSuite).write(to: suiteURL, options: .atomic)
        }
        if migrated {
            catalog.migratedLegacyStorageAt = now
        }
        try save(catalog, in: supportDirectory)
        return EvaluationWorkspaceBootstrap(
            catalog: catalog,
            notice: migrated ? legacyMigrationNotice : nil
        )
    }

    private static let legacyMigrationNotice =
        "Existing legacy files were copied into the matching workspace suite where destinations were missing. The legacy files were left unchanged for recovery."

    static func save(_ catalog: EvaluationWorkspaceCatalog, in supportDirectory: URL) throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try CanonicalJSON.data(for: catalog).write(
            to: supportDirectory.appending(path: catalogFilename),
            options: .atomic
        )
    }

    static func preserveUnreadableFile(_ data: Data, in directory: URL, prefix: String) throws {
        try preserveState(data, in: directory, prefix: prefix)
    }

    private static func validatedCatalog(_ catalog: EvaluationWorkspaceCatalog) throws -> EvaluationWorkspaceCatalog {
        guard catalog.formatVersion == EvaluationWorkspaceCatalog.currentFormatVersion,
              !catalog.projects.isEmpty else {
            throw EvaluationWorkspaceError.unsupportedCatalog
        }
        var uniqueProjectIDs = Set<UUID>()
        for project in catalog.projects {
            guard uniqueProjectIDs.insert(project.id).inserted, !project.suites.isEmpty else {
                throw EvaluationWorkspaceError.unsupportedCatalog
            }
            var uniqueSuiteIDs = Set<UUID>()
            for record in project.suites {
                guard uniqueSuiteIDs.insert(record.id).inserted else {
                    throw EvaluationWorkspaceError.unsupportedCatalog
                }
            }
        }
        var repaired = catalog
        if !repaired.projects.contains(where: {
            $0.id == repaired.selectedProjectID && !$0.isArchived
        }) {
            repaired.selectedProjectID = repaired.projects.first { !$0.isArchived }?.id
                ?? repaired.projects[0].id
        }
        for index in repaired.projects.indices {
            let project = repaired.projects[index]
            if !project.suites.contains(where: {
                $0.id == project.selectedSuiteID && !$0.isArchived
            }) {
                repaired.projects[index].selectedSuiteID = project.suites.first { !$0.isArchived }?.id
                    ?? project.suites[0].id
            }
        }
        return repaired
    }

    static func suiteDirectory(
        supportDirectory: URL,
        projectID: UUID,
        suiteID: UUID
    ) -> URL {
        supportDirectory
            .appending(path: "Projects", directoryHint: .isDirectory)
            .appending(path: projectID.uuidString, directoryHint: .isDirectory)
            .appending(path: "Suites", directoryHint: .isDirectory)
            .appending(path: suiteID.uuidString, directoryHint: .isDirectory)
    }

    static func createSuiteDirectories(at suiteDirectory: URL) throws {
        try FileManager.default.createDirectory(at: suiteDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: suiteDirectory.appending(path: "Attachments", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: suiteDirectory.appending(path: "Runs", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    static func repositoryDefinitionURL(
        project: EvaluationProject,
        suite: EvaluationSuiteRecord
    ) -> URL? {
        guard let repository = project.repository,
              let relativePath = suite.repositoryDefinitionPath,
              safeRelativePath(relativePath) else { return nil }
        return URL(filePath: repository.rootPath, directoryHint: .isDirectory)
            .appending(path: relativePath)
    }

    static func definitionRevision(_ definition: EvaluationSuiteDefinition) throws -> String {
        let data = try CanonicalJSON.data(for: definition, prettyPrinted: false)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func safeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    static func copyLegacyStorage(from source: URL, to target: URL) throws -> Bool {
        let mappings = [
            (source.appending(path: "suite.json"), target.appending(path: "suite.json")),
            (source.appending(path: "state.json"), target.appending(path: "state.json")),
            (source.appending(path: "suite-draft.json"), target.appending(path: "suite-draft.json")),
            (source.appending(path: "active-run.json"), target.appending(path: "active-run.json")),
            (source.appending(path: "Attachments", directoryHint: .isDirectory),
             target.appending(path: "Attachments", directoryHint: .isDirectory)),
            (source.appending(path: "Runs", directoryHint: .isDirectory),
             target.appending(path: "Runs", directoryHint: .isDirectory))
        ]
        var copied = false
        for (legacy, destination) in mappings where FileManager.default.fileExists(atPath: legacy.path) {
            if legacy.hasDirectoryPath {
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: legacy,
                    includingPropertiesForKeys: nil
                ) else { continue }
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for child in children {
                    let targetChild = destination.appending(path: child.lastPathComponent)
                    guard !FileManager.default.fileExists(atPath: targetChild.path) else { continue }
                    try FileManager.default.copyItem(at: child, to: targetChild)
                    copied = true
                }
            } else if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: legacy, to: destination)
                copied = true
            }
        }
        return copied
    }

    static func hasCompletedLegacyStateMigration(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: legacyStateMigrationFilename).path)
    }

    private static func completeLegacyStateMigration(in directory: URL) throws {
        let url = directory.appending(path: legacyStateMigrationFilename)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try Data("Completed. Do not automatically restore legacy approval state.\n".utf8)
            .write(to: url, options: .atomic)
    }

    private static func recoverUnmigratedLegacyState(from source: URL, to target: URL) throws -> Bool {
        guard !hasCompletedLegacyStateMigration(in: target) else { return false }
        let destination = target.appending(path: "state.json")
        let destinationData: Data?
        if FileManager.default.fileExists(atPath: destination.path) {
            // A read failure is not permission to overwrite an existing file.
            destinationData = try Data(contentsOf: destination)
            if let destinationData,
               (try? CanonicalJSON.decode(EvaluationSuiteLocalState.self, from: destinationData)) != nil {
                try completeLegacyStateMigration(in: target)
                return false
            }
        } else {
            destinationData = nil
        }
        let legacy = source.appending(path: "state.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return false }
        let legacyData = try Data(contentsOf: legacy)
        guard var recovered = try? CanonicalJSON.decode(EvaluationSuiteLocalState.self, from: legacyData) else {
            return false
        }

        // Preservation is required, not best-effort. Failure leaves current
        // bytes untouched. The archive retains all historical decisions verbatim.
        try preserveState(legacyData, in: target, prefix: "state-recovered-legacy")
        if let destinationData {
            try preserveState(destinationData, in: target, prefix: "state-unreadable")
        }
        let recoveredAt = Date()
        for index in recovered.baselineApprovals.indices where recovered.baselineApprovals[index].isCurrent {
            recovered.baselineApprovals[index].revokedAt = recoveredAt
        }
        recovered.humanCorrections = []
        recovered.reviewedJudgeExamples = []
        for index in recovered.experiments.indices {
            recovered.experiments[index].decision = .inconclusive
        }
        try CanonicalJSON.data(for: recovered).write(to: destination, options: .atomic)
        // If sealing fails, the next launch sees only this sanitized state and
        // adopts it; it cannot copy the old active approvals over it.
        try completeLegacyStateMigration(in: target)
        return true
    }

    private static func preserveState(_ data: Data, in directory: URL, prefix: String) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let backup = directory.appending(path: "\(prefix)-\(digest).json", directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: backup.path) {
            guard try Data(contentsOf: backup) == data else {
                throw CocoaError(.fileWriteFileExists)
            }
            return
        }
        try data.write(to: backup, options: .atomic)
    }
}

enum EvaluationWorkspaceError: LocalizedError, Sendable {
    case unsupportedCatalog
    case missingProject
    case missingSuite
    case invalidRepositoryPath
    case repositoryConflict

    var errorDescription: String? {
        switch self {
        case .unsupportedCatalog: "The workspace catalog is empty or uses a newer unsupported format."
        case .missingProject: "The selected project no longer exists."
        case .missingSuite: "The selected suite no longer exists."
        case .invalidRepositoryPath: "The repository suite path must be a safe relative path."
        case .repositoryConflict: "The repository suite changed outside Intents. Review or reload it before saving."
        }
    }
}

enum EvaluationRepositoryInspector {
    static func snapshot(
        rootPath: String,
        gitExecutable: URL = URL(filePath: "/usr/bin/git"),
        timeout: Duration = .seconds(10)
    ) async -> EvaluationRepositorySnapshot {
        let capturedAt = Date()
        do {
            let commit = try await runGit(.revision, rootPath: rootPath,
                                          executable: gitExecutable, timeout: timeout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status = try await runGit(.status, rootPath: rootPath,
                                          executable: gitExecutable, timeout: timeout)
            return EvaluationRepositorySnapshot(rootPath: rootPath, commit: commit.isEmpty ? nil : commit,
                                                isDirty: !status.isEmpty, capturedAt: capturedAt, error: nil)
        } catch {
            return EvaluationRepositorySnapshot(rootPath: rootPath, commit: nil, isDirty: nil,
                                                capturedAt: capturedAt, error: error.localizedDescription)
        }
    }

    private enum GitOperation: String, Sendable {
        case revision = "rev-parse", status
        var arguments: [String] {
            self == .revision ? ["rev-parse", "HEAD"] : ["status", "--porcelain=v1", "--untracked-files=normal"]
        }
    }

    private static func runGit(
        _ operation: GitOperation, rootPath: String, executable: URL, timeout: Duration
    ) async throws -> String {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appending(path: "EvaluationGit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appending(path: "stdout")
        let stderrURL = directory.appending(path: "stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: stdoutURL)
        let errors = try FileHandle(forWritingTo: stderrURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = executable.resolvingSymlinksInPath()
        process.arguments = ["--no-pager", "-c", "core.fsmonitor=false", "-C", rootPath] + operation.arguments
        process.currentDirectoryURL = URL(filePath: rootPath)
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                               "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let outputLimit = 1_048_576
        func checkOutputBounds() throws {
            for url in [stdoutURL, stderrURL] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(outputLimit) else {
                    throw EvaluationRepositoryInspectionError.git("Git inspection exceeded its output limit.")
                }
            }
        }
        func readBounded(_ url: URL) throws -> Data {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: outputLimit + 1) ?? Data()
            guard data.count <= outputLimit else {
                throw EvaluationRepositoryInspectionError.git("Git inspection exceeded its output limit.")
            }
            return data
        }
        do {
            while process.isRunning {
                try Task.checkCancellation()
                try checkOutputBounds()
                guard ContinuousClock.now < deadline else {
                    throw EvaluationRepositoryInspectionError.git("Git \(operation.rawValue) timedOut during execution.")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            try checkOutputBounds()
            guard process.terminationStatus == 0 else {
                let data = try readBounded(stderrURL)
                let message = String(decoding: data.prefix(8_192), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw EvaluationRepositoryInspectionError.git(message.isEmpty ? "Git inspection failed." : message)
            }
            return String(decoding: try readBounded(stdoutURL), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
        } catch {
            await stopOwnedProcess(process)
            throw error
        }
    }

    private static func stopOwnedProcess(_ process: Process) async {
        guard process.isRunning else { return }
        // Process observes and reaps its child itself. waitUntilExit can strand a
        // resumed async task in a thread's run loop after the child already exited.
        // A detached cleanup task also lets cancellation retain its original error
        // without cancelling the bounded wait for the owned child to stop.
        await Task.detached {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning && ContinuousClock.now < cleanupDeadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }.value
    }
}

private enum EvaluationRepositoryInspectionError: LocalizedError {
    case git(String)

    var errorDescription: String? {
        switch self { case .git(let message): message }
    }
}
