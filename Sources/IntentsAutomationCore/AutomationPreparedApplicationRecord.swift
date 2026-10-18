#if os(macOS)
import Foundation

/// Resolves one saved preparation from its exact retained product path. It
/// neither searches other projects nor authorises a build or device command.
public enum AutomationPreparedApplicationRecord {
    /// Reassess the original container that issued the candidate identity.
    /// Current records carry structured graph paths; older records retain the
    /// project/workspace candidate ID and need a bounded compatibility decoder.
    public static func intakeURL(for prepared: AutomationPreparedApplication) throws -> URL {
        let source = prepared.source
        let project: String, workspace: String?, targetID: String
        if let graph = prepared.sourceGraph {
            guard graph.workspaceRelativePath == prepared.workspace?.relativePath,
                  AutomationSourceCaptureLayout.relative(graph.projectRelativePath),
                  graph.workspaceRelativePath.map(AutomationSourceCaptureLayout.relative) ?? true else {
                throw AutomationContractError.conflictingOperation
            }
            project = source.layoutRoot + "/" + graph.projectRelativePath
            workspace = graph.workspaceRelativePath.map { source.layoutRoot + "/" + $0 }
            targetID = graph.targetID
        } else {
            let logicalID = prepared.host.app.logicalID
            guard let separator = logicalID.lastIndex(of: "#") else { throw AutomationContractError.invalidIdentity }
            targetID = String(logicalID[logicalID.index(after: separator)...])
            let containers = String(logicalID[..<separator]).components(separatedBy: "::")
            guard (1...2).contains(containers.count) else { throw AutomationContractError.invalidIdentity }
            project = containers.last!
            workspace = containers.count == 2 ? containers[0] : nil
        }
        guard !targetID.isEmpty, project.hasSuffix(".xcodeproj"),
              AutomationSourceCaptureLayout.absolute(project), source.includesOrigin(project),
              workspace.map({ AutomationSourceCaptureLayout.absolute($0) && $0.hasSuffix(".xcworkspace") && source.includesOrigin($0) }) ?? true,
              prepared.host.app.logicalID == (workspace.map { $0 + "::" } ?? "") + project + "#" + targetID else {
            throw AutomationContractError.conflictingOperation
        }
        if let workspace {
            let container = URL(fileURLWithPath: workspace)
            if container.deletingLastPathComponent().path != source.sourceRoot {
                // A repository selection may authorise sibling projects outside
                // a nested workspace's folder. Reuse that exact primary root;
                // the caller still selects only the retained candidate identity.
                guard AutomationSourceCaptureLayout.absolute(source.sourceRoot),
                      workspace.hasPrefix(source.sourceRoot + "/"),
                      project.hasPrefix(source.sourceRoot + "/") else {
                    throw AutomationContractError.conflictingOperation
                }
                return URL(fileURLWithPath: source.sourceRoot)
            }
            return container
        }
        return URL(fileURLWithPath: project)
    }

    // Includes the bounded source manifest plus up to 16 MiB of host/catalog evidence.
    public static let maximumRecordBytes = AutomationSourceSnapshot.maximumManifestBytes + 16 * 1024 * 1024
    /// Reuses the newest completed preparation without rebuilding. Unfinished
    /// directories are ignored; a damaged newest record requires preparation again.
    public static func loadLatest(supportRoot: URL) throws -> AutomationPreparedApplication? {
        guard FileManager.default.fileExists(atPath: supportRoot.path) else { return nil }
        let root = try AutomationPath.canonical(supportRoot)
        guard root.path == supportRoot.path else { throw AutomationContractError.invalidIdentity }
        let sessions = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("prepare-") && UUID(uuidString: String($0.lastPathComponent.dropFirst(8))) != nil }
        let records = sessions.map { $0.appendingPathComponent("prepared-application.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left == right ? $0.path > $1.path : left > right
            }
        guard let record = records.first else { return nil }
        do {
            let relative = record.deletingLastPathComponent().lastPathComponent + "/prepared-application.json"
            let data = try AutomationReadOnlyFile.read(root: root, relativePath: relative,
                maximumBytes: maximumRecordBytes, requirePrivateOwnership: true)
            let expected = try JSONDecoder().decode(AutomationPreparedApplication.self, from: data)
            guard expected.host.subjectProductPath.hasPrefix(record.deletingLastPathComponent().path + "/") else {
                throw AutomationContractError.conflictingOperation
            }
            let prepared = try load(app: expected.host.app, supportRoot: root)
            guard prepared == expected else { throw AutomationContractError.conflictingOperation }
            try AutomationPreparedArtifactIntegrity.verify(prepared)
            return prepared
        } catch {
            throw AutomationContractError.missingEvidence("The latest saved prepared files changed or are missing. Prepare the app again.")
        }
    }

    public static func load(app: AppIdentity, supportRoot: URL) throws -> AutomationPreparedApplication {
        let root = try AutomationPath.canonical(supportRoot)
        guard root.path == supportRoot.path, let path = app.canonicalBundlePath, path.hasPrefix(root.path + "/") else {
            throw AutomationContractError.missingEvidence("The original prepared build is not retained in this workspace")
        }
        let relative = String(path.dropFirst(root.path.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0].hasPrefix("prepare-"), UUID(uuidString: String(parts[0].dropFirst(8))) != nil else {
            throw AutomationContractError.invalidIdentity
        }
        let session = root.appendingPathComponent(parts[0], isDirectory: true)
        let product = try AutomationPath.canonical(URL(fileURLWithPath: path))
        guard try AutomationPath.canonical(session).path == session.path, product.path == path,
              product.path.hasPrefix(session.path + "/") else { throw AutomationContractError.invalidIdentity }
        let bytes = try AutomationReadOnlyFile.read(root: root, relativePath: parts[0] + "/prepared-application.json", maximumBytes: maximumRecordBytes, requirePrivateOwnership: true)
        let prepared = try JSONDecoder().decode(AutomationPreparedApplication.self, from: bytes)
        guard prepared.host.app == app, prepared.catalog.app == app,
              prepared.host.subjectProductPath == path,
              app.sourceManifestDigest == (try prepared.source.digest) else {
            throw AutomationContractError.conflictingOperation
        }
        try prepared.source.validateCaptureLayout()
        try prepared.workspace?.verify(session: session, manifest: prepared.source)
        if let graph = prepared.sourceGraph {
            guard graph.workspaceRelativePath == prepared.workspace?.relativePath else { throw AutomationContractError.conflictingOperation }
            guard graph.schemaVersion >= 2, prepared.sourceSyntax.map({ $0.schemaVersion == 2 }) ?? true else {
                throw AutomationContractError.missingEvidence("Retained source evidence predates conditional-compilation tracking; prepare this source target again")
            }
            guard graph.schemaVersion == AutomationSourceGraph.currentSchemaVersion else {
                throw AutomationContractError.missingEvidence("Retained source evidence lacks current local-package dependency tracking; prepare this source target again")
            }
            guard graph.configuration == app.configuration,
                  app.logicalID == (graph.workspaceRelativePath.map { prepared.source.layoutRoot + "/" + $0 + "::" } ?? "") + prepared.source.layoutRoot + "/" + graph.projectRelativePath + "#" + graph.targetID,
                  prepared.catalog.sourceGraphDigest == (try graph.digest) else { throw AutomationContractError.conflictingOperation }
            guard graph.packagePlatformConditionVersion == nil || graph.packagePlatformConditionVersion == 1 else { throw AutomationContractError.conflictingOperation }
            guard graph.synchronizedMembershipVersion == nil || graph.synchronizedMembershipVersion == 1 else { throw AutomationContractError.conflictingOperation }
            let platformSettings: Data?
            if let context = graph.platformContext {
                let bytes = try AutomationReadOnlyFile.read(root: session, relativePath: "source-compilation-settings.json",
                    maximumBytes: 1_048_576, requirePrivateOwnership: true)
                guard context.settingsSHA256 == AutomationArtifactRegistry.digest(bytes) else { throw AutomationContractError.conflictingOperation }
                platformSettings = bytes
            } else { platformSettings = nil }
            let observed = try AutomationSourceGraphReader.read(manifest: prepared.source,
                frozenRoot: session.appendingPathComponent("source"), projectRelativePath: graph.projectRelativePath,
                targetID: graph.targetID, configuration: graph.configuration,
                projectData: AutomationReadOnlyFile.read(root: session, relativePath: "source-graph-project.pbxproj", maximumBytes: 16 * 1024 * 1024, requirePrivateOwnership: true),
                workspaceRelativePath: graph.workspaceRelativePath,
                resolutionData: graph.inputs.contains(where: { $0.role == "packageResolution" })
                    ? AutomationReadOnlyFile.read(root: session, relativePath: "source-graph-resolution.json", maximumBytes: 16 * 1024 * 1024, requirePrivateOwnership: true) : nil,
                platformSettings: platformSettings, developerDirectory: graph.platformContext.map { URL(fileURLWithPath: $0.developerDirectory) },
                resolvePackagePlatformConditions: graph.packagePlatformConditionVersion == 1,
                resolveSynchronizedMembership: graph.synchronizedMembershipVersion == 1)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var reconciled = try AutomationSourceCatalogReconciliation.apply(observed, to: prepared.catalog)
            if let syntax = prepared.sourceSyntax {
                let retained = try JSONDecoder().decode(AutomationSourceSyntaxIndex.self,
                    from: AutomationReadOnlyFile.read(root: session, relativePath: "source-syntax-index.json", maximumBytes: 1_048_576, requirePrivateOwnership: true))
                let savedDigest = try syntax.digest, retainedDigest = try retained.digest
                if let conditions = retained.compilationConditions {
                    let settings = try AutomationReadOnlyFile.read(root: session, relativePath: "source-compilation-settings.json", maximumBytes: 1_048_576, requirePrivateOwnership: true)
                    try conditions.validateDerived(settings: settings, graph: observed)
                }
                guard savedDigest == retainedDigest, savedDigest == app.sourceSyntaxIndexDigest,
                      savedDigest == prepared.catalog.sourceSyntaxIndexDigest else { throw AutomationContractError.conflictingOperation }
                reconciled = try AutomationSourceSyntaxReconciliation.apply(retained, graph: observed, to: reconciled)
            } else if app.sourceSyntaxIndexDigest != nil || prepared.catalog.sourceSyntaxIndexDigest != nil {
                throw AutomationContractError.conflictingOperation
            }
            let expectedActions = try encoder.encode(reconciled.systemActions)
            let savedActions = try encoder.encode(prepared.catalog.systemActions)
            guard try observed.digest == graph.digest, expectedActions == savedActions else {
                throw AutomationContractError.conflictingOperation
            }
        } else if prepared.sourceSyntax != nil || app.sourceSyntaxIndexDigest != nil || prepared.catalog.sourceSyntaxIndexDigest != nil || prepared.catalog.sourceGraphDigest != nil || prepared.catalog.systemActions.contains(where: { $0.sourceCandidates != nil || $0.sourceReconciliation != nil }) {
            throw AutomationContractError.conflictingOperation
        }
        return prepared
    }
}
#endif
