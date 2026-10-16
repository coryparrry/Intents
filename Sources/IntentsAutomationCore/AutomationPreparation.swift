#if os(macOS)
import Foundation

/// Explicit authorisation to run the selected project's build scripts in an owned snapshot.
/// It grants no installation, activation, model access or device mutation.
public struct AutomationBuildApproval: Codable, Equatable, Sendable {
    public var sourceRoot: String
    public var additionalSourceRoots: [String]? = nil
    public var includesDependencies: Bool? = nil
    public var servedJavaScriptProfile: AutomationServedJavaScriptProfile? = nil
    public var automaticMetroRecipe: AutomationMetroAutomaticRecipe? = nil
    public var candidateID: String
    public var configuration: String
    public var target: TargetIdentity
    public init(sourceRoot: String, candidateID: String, configuration: String, target: TargetIdentity, additionalSourceRoots: [String] = [], includesDependencies: Bool = false,
                servedJavaScriptProfile: AutomationServedJavaScriptProfile? = nil,
                automaticMetroRecipe: AutomationMetroAutomaticRecipe? = nil) {
        self.servedJavaScriptProfile = servedJavaScriptProfile
        self.automaticMetroRecipe = automaticMetroRecipe
        self.includesDependencies = includesDependencies ? true : nil
        self.additionalSourceRoots = additionalSourceRoots.isEmpty ? nil : additionalSourceRoots
        self.sourceRoot = sourceRoot; self.candidateID = candidateID; self.configuration = configuration; self.target = target
    }
    public func validateSourceManifest(_ manifest: AutomationSourceManifest) throws {
        try validateJavaScriptApproval()
        try manifest.validateCaptureLayout()
        let extras = additionalSourceRoots ?? []
        guard sourceRoot == manifest.sourceRoot,
              (includesDependencies == true) == (manifest.includesDependencies == true),
              extras.count <= 8, Set(extras).count == extras.count, extras.sorted() == manifest.additionalRoots.sorted() else {
            throw AutomationContractError.conflictingOperation
        }
        try servedJavaScriptProfile?.validateCapture(manifest)
        try automaticMetroRecipe?.validateCapture(manifest)
    }
    func validateJavaScriptApproval() throws {
        guard servedJavaScriptProfile == nil || automaticMetroRecipe == nil,
              servedJavaScriptProfile?.automaticMetro == nil else {
            throw AutomationContractError.invalidPlan("Review one JavaScript server choice for the selected app before preparation.")
        }
        if servedJavaScriptProfile != nil || automaticMetroRecipe != nil {
            guard target.kind == .simulator else {
                throw AutomationContractError.missingEvidence("Served JavaScript preparation requires an iOS Simulator target.")
            }
        }
    }
}

public struct AutomationPreparedApplication: Codable, Equatable, Sendable {
    public var source: AutomationSourceManifest
    public var generatedHost: AutomationGeneratedHost
    public var host: AutomationPreparedAppleHost
    public var catalog: ApplicationSurfaceCatalog
    public var buildLogPath: String
    public var buildLogTruncated: Bool
    public var workspace: AutomationWorkspaceBuildContext? = nil
    public var sourceGraph: AutomationSourceGraph? = nil
    public var sourceSyntax: AutomationSourceSyntaxIndex? = nil
    public var servedJavaScriptProfile: AutomationServedJavaScriptProfile? = nil
    public var servedJavaScriptIdentity: AutomationServedJavaScriptIdentity? = nil
    public var servedJavaScriptFrozenRootPath: String? = nil
    public var selectedDeveloperDirectoryPath: String? = nil
}

/// One cancellable, owned preparation at a time. The original project is never edited.
public actor AutomationPreparation {
    private let command = AutomationOwnedCommand()
    private let javaScriptSupervisor = AutomationServedJavaScriptSupervisor()
    private var preparing = false
    private var cancellationRequested = false
    private var reviewedToolchain: AutomationReviewedToolchain?
    public init() {}
    public func cancel() async -> Bool {
        cancellationRequested = true
        let buildStopped = await command.stopOwned()
        let serverStopped = await javaScriptSupervisor.cancelOwned()
        return buildStopped && serverStopped
    }
    private func requireActive() throws {
        try Task.checkCancellation()
        guard preparing, !cancellationRequested else { throw CancellationError() }
        try reviewedToolchain?.validate()
    }
    public func prepare(candidate: AutomationApplicationCandidate, approval: AutomationBuildApproval,
                        sessionRoot: URL, templates: URL, developerDirectory: URL, requireConfiguredDeveloperDirectory: Bool = false, reviewedToolchainMetadataDigest: String? = nil) async throws -> AutomationPreparedApplication {
        guard !preparing, candidate.kind == .sourceTarget, candidate.id == approval.candidateID,
              let targetID = candidate.targetID, candidate.configurations.contains(approval.configuration) else {
            throw AutomationContractError.invalidPlan("Build approval does not match the selected app and configuration")
        }
        var approval = approval
        let profile = try AutomationAssociatedHostPlatform(target: approval.target)
        try approval.validateJavaScriptApproval()
        if profile == .macOS { try AutomationMacGUIIdentity.validate(approval.target) }
        let source = try AutomationPath.canonical(URL(fileURLWithPath: approval.sourceRoot))
        let project = try AutomationPath.canonical(URL(fileURLWithPath: candidate.containerPath))
        guard project.path.hasPrefix(source.path + "/") else { throw AutomationContractError.invalidIdentity }
        let refreshed = try AutomationApplicationIntake.assess(project)
        let expectedCandidates = candidate.workspacePath.map { path in refreshed.candidates.map { AutomationApplicationIntake.inWorkspace($0, URL(fileURLWithPath: path)) } } ?? refreshed.candidates
        guard expectedCandidates.contains(candidate) else { throw AutomationContractError.conflictingOperation }
        if approval.configuration.caseInsensitiveCompare("Debug") == .orderedSame,
           approval.servedJavaScriptProfile == nil, approval.automaticMetroRecipe == nil,
           try AutomationMetroAutomaticRecipe.discover(source: source, candidate: candidate) != nil {
            throw AutomationContractError.missingEvidence("This development build requires its local JavaScript server. Review the app's build and server approval before preparing it.")
        }
        if let path = candidate.workspacePath {
            let workspace = try AutomationPath.canonical(URL(fileURLWithPath: path))
            guard workspace.path == path, path.hasPrefix(source.path + "/"),
                  try AutomationWorkspaceProjects.resolve(workspace, authorizedRoot: source).projects.contains(project) else { throw AutomationContractError.conflictingOperation }
        }
        preparing = true; cancellationRequested = false; defer { preparing = false; reviewedToolchain = nil }
        if let digest = reviewedToolchainMetadataDigest {
            reviewedToolchain = .init(directory: try AutomationPath.canonical(AutomationInstalledToolchain.developerURL(developerDirectory)), metadataDigest: digest)
        }
        try requireActive()
        if approval.target.kind == .physical {
            approval.target = try await AutomationPreparationTargetResolution.resolve(approval.target,
                sessionRoot: sessionRoot, developerDirectory: developerDirectory)
            try requireActive()
        }
        let manifest = try AutomationSourceSnapshot.capture(source: source, sessionRoot: sessionRoot, additionalRoots: (approval.additionalSourceRoots ?? []).map { URL(fileURLWithPath: $0) }, includesDependencies: approval.includesDependencies == true)
        do {
            try approval.validateSourceManifest(manifest)
            let projectRelativePath = String(project.path.dropFirst(manifest.layoutRoot.count + 1))
            let workspaceRelativePath = candidate.workspacePath.map { String($0.dropFirst(manifest.layoutRoot.count + 1)) }
            let resolutionPath = workspaceRelativePath.map(AutomationWorkspaceBuildContext.packageResolutionPath) ?? projectRelativePath + "/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            let projectData = try AutomationReadOnlyFile.read(root: sessionRoot.appendingPathComponent("source"),
                relativePath: projectRelativePath + "/project.pbxproj", maximumBytes: 16 * 1024 * 1024)
            var sourceGraph = try AutomationSourceGraphReader.read(manifest: manifest,
                frozenRoot: sessionRoot.appendingPathComponent("source"),
                projectRelativePath: projectRelativePath,
                targetID: targetID, configuration: approval.configuration, projectData: projectData, workspaceRelativePath: workspaceRelativePath)
            let originalProject = try AutomationDurableFile(url: sessionRoot.appendingPathComponent("source-graph-project.pbxproj"), maximumBytes: 16 * 1024 * 1024)
            try originalProject.withLock { try originalProject.write(projectData) }
            var sourceResolutionData: Data?
            let resolutions = sourceGraph.inputs.filter { $0.role == "packageResolution" }
            if let resolution = resolutions.first {
                guard Set(resolutions.map(\.relativePath)) == [resolutionPath] else { throw AutomationContractError.conflictingOperation }
                let bytes = try AutomationReadOnlyFile.read(root: sessionRoot.appendingPathComponent("source"), relativePath: resolution.relativePath, maximumBytes: 16 * 1024 * 1024)
                guard let expected = manifest.files.first(where: { $0.relativePath == resolution.relativePath }), expected.bytes == bytes.count,
                      AutomationArtifactRegistry.digest(bytes) == expected.sha256,
                      resolutions.allSatisfy({ $0.sha256 == expected.sha256 }) else { throw AutomationContractError.conflictingOperation }
                sourceResolutionData = bytes
                let archive = try AutomationDurableFile(url: sessionRoot.appendingPathComponent("source-graph-resolution.json"), maximumBytes: 16 * 1024 * 1024)
                try archive.withLock { try archive.write(bytes) }
            }
            let developer = try await AutomationInstalledToolchain.resolve(configured: developerDirectory, sdk: profile.sdkName,
                command: command, workspace: sessionRoot, requireConfiguredDirectory: requireConfiguredDeveloperDirectory || reviewedToolchainMetadataDigest != nil, willStart: { try await self.requireActive() })
            let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developer.path,
                               "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TMPDIR": NSTemporaryDirectory()]
            try await AutomationXcodeSDKCompatibility.check(target: approval.target, developerDirectory: developer,
                workspace: sessionRoot, command: command, willStart: { try await self.requireActive() })
            try requireActive()
            var sourceSyntax: AutomationSourceSyntaxIndex?
            var syntaxUnavailable = false
            try requireActive()
            let rebased = try AutomationHostGenerator.isolateProject(sessionRoot: sessionRoot,
                projectRelativePath: projectRelativePath)
            let nativeContext = try AutomationNativeDependencyBuildContext.prepare(project: rebased, manifest: manifest, sdk: profile.sdkName, configuration: approval.configuration)
            let targetName = try AutomationHostGenerator.selectedTargetName(rebased: rebased, targetID: targetID, configuration: approval.configuration)
            guard targetName == candidate.name else { throw AutomationContractError.conflictingOperation }
            let pinnedArguments = sourceResolutionData == nil ? [] : ["-onlyUsePackageVersionsFromResolvedFile"]
            var workspace = try workspaceRelativePath.map { try AutomationWorkspaceBuildContext.prepare(workspaceRelativePath: $0,
                selectedProject: rebased, targetID: targetID, name: targetName, manifest: manifest) }
            let containerArguments = workspace?.containerArguments(session: sessionRoot) ?? ["-project", rebased.project.path]
            let subjectArguments = workspace.map { ["-scheme", $0.subjectScheme] } ?? ["-target", targetName]
            let settings = try await command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["xcodebuild", "-quiet"] + containerArguments + subjectArguments + nativeContext.arguments + pinnedArguments + ["-configuration", approval.configuration, "-sdk", profile.sdkName, "-showBuildSettings", "-json"],
                directory: sessionRoot, environment: environment, timeout: .seconds(120), willStart: { try await self.requireActive() })
            try requireActive()
            let settingsLog = try AutomationDurableFile(url: sessionRoot.appendingPathComponent("platform-settings.log"), maximumBytes: 2_100_000)
            try settingsLog.withLock { try settingsLog.write(settings.stdout + Data("\n--- stderr ---\n".utf8) + settings.stderr) }
            guard settings.exitStatus == 0, !settings.logsTruncated else {
                throw AutomationContractError.missingEvidence("Xcode could not resolve complete settings for the isolated target")
            }
            let platform = try AutomationBuildPlatform.read(settings.stdout, project: rebased.project,
                targetName: candidate.name, configuration: approval.configuration, developer: developer)
            let platformStore = try AutomationDurableFile(url: sessionRoot.appendingPathComponent("platform.json"), maximumBytes: 16384)
            try platformStore.withLock { try platformStore.write(try JSONEncoder().encode(platform)) }
            guard profile.accepts(platform) else {
                throw AutomationContractError.missingEvidence("Selected app resolves to \(platform.platformFamily); its associated host profile is not qualified")
            }
            if profile == .macOS { try AutomationMacGUIIdentity.validate(approval.target) }
            let derived = sessionRoot.appendingPathComponent("DerivedData")
            let baselineProject = try AutomationReadOnlyFile.read(rebased.project.appendingPathComponent("project.pbxproj"), maximumBytes: 16 * 1024 * 1024)
            let recovery = AutomationPreparationBuildRecovery(pinnedDependencies: sourceResolutionData != nil)
            let baselineDerivedArguments = workspace == nil ? [] : ["-derivedDataPath", derived.path]
            let baselineArguments = ["xcodebuild", "build"] + containerArguments + subjectArguments + nativeContext.arguments + pinnedArguments +
                baselineDerivedArguments +
                ["-configuration", approval.configuration, "-destination", profile.destination, "-sdk", profile.sdkName,
                 "-jobs", "2", "BUILD_DIR=" + derived.appendingPathComponent("Build/Products").path,
                 "OBJROOT=" + derived.appendingPathComponent("Build/Intermediates.noindex").path,
                 "SHARED_PRECOMPS_DIR=" + derived.appendingPathComponent("Build/PrecompiledHeaders").path, "CODE_SIGNING_ALLOWED=YES"]
            let baselineGraph = sourceGraph
            try await recovery.baseline(build: {
                try await self.requireActive()
                try AutomationSourceSnapshot.verifyOriginal(manifest)
                try AutomationPreparedSourceIntegrity.verify(graph: baselineGraph, manifest: manifest, frozenRoot: sessionRoot.appendingPathComponent("source"))
                try nativeContext.verify()
                let result = try await self.command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: baselineArguments,
                    directory: sessionRoot, environment: environment, timeout: .seconds(600), willStart: { try await self.requireActive() })
                try await self.requireActive()
                try AutomationPreparedSourceIntegrity.verify(graph: baselineGraph, manifest: manifest, frozenRoot: sessionRoot.appendingPathComponent("source"))
                return result
            }, retain: { result, retry in
                try AutomationPreparationBuildRecovery.retain(result, at: sessionRoot.appendingPathComponent("baseline-build-\(retry).log"))
            })
            guard try AutomationReadOnlyFile.read(rebased.project.appendingPathComponent("project.pbxproj"), maximumBytes: 16 * 1024 * 1024) == baselineProject else {
                throw AutomationContractError.conflictingOperation
            }
            var generated = try AutomationHostGenerator.associate(rebased: rebased, subjectTargetID: targetID,
                configuration: approval.configuration, platform: platform, templates: templates)
            try workspace?.includeHost(generated, session: sessionRoot)
            let supportRecovery = try AutomationGeneratedSupportRecovery(sessionRoot: sessionRoot, generated: generated, workspaceRelativePath: workspaceRelativePath)
            let generatedProject = URL(fileURLWithPath: generated.projectPath).appendingPathComponent("project.pbxproj")
            let generatedProjectBytes = try AutomationReadOnlyFile.read(generatedProject, maximumBytes: 16 * 1024 * 1024)
            let generatedProjectDigest = AutomationArtifactRegistry.digest(generatedProjectBytes)
            let productSettings = try await command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["xcodebuild", "-quiet"] + containerArguments + subjectArguments + nativeContext.arguments + pinnedArguments + ["-configuration", approval.configuration, "-sdk", profile.sdkName,
                            "-showBuildSettings", "-json", "BUILD_DIR=" + derived.appendingPathComponent("Build/Products").path,
                            "CODE_SIGNING_ALLOWED=YES"],
                directory: sessionRoot, environment: environment, timeout: .seconds(120), willStart: { try await self.requireActive() })
            try requireActive()
            let productLog = try AutomationDurableFile(url: sessionRoot.appendingPathComponent("product-settings.log"), maximumBytes: 2_100_000)
            try productLog.withLock { try productLog.write(productSettings.stdout + Data("\n--- stderr ---\n".utf8) + productSettings.stderr) }
            guard productSettings.exitStatus == 0, !productSettings.logsTruncated else {
                throw AutomationContractError.missingEvidence("Xcode could not resolve complete selected product settings")
            }
            let resolvedProductPlatform = try AutomationBuildPlatform.read(productSettings.stdout, project: rebased.project,
                targetName: candidate.name, configuration: approval.configuration, developer: developer)
            guard profile.accepts(resolvedProductPlatform) else { throw AutomationContractError.conflictingOperation }
            sourceGraph = try AutomationSourceGraphReader.read(manifest: manifest,
                frozenRoot: sessionRoot.appendingPathComponent("source"), projectRelativePath: projectRelativePath,
                targetID: targetID, configuration: approval.configuration, projectData: projectData, workspaceRelativePath: workspaceRelativePath,
                resolutionData: sourceResolutionData, platformSettings: productSettings.stdout, developerDirectory: developer)
            let compilationConditions = try AutomationSourceCompilationConditions.read(productSettings.stdout, graph: sourceGraph, platform: resolvedProductPlatform)
            let compilationSettings = try AutomationDurableFile(url: sessionRoot.appendingPathComponent("source-compilation-settings.json"), maximumBytes: 1_048_576)
            try compilationSettings.withLock { try compilationSettings.write(productSettings.stdout) }
            do {
                let parsed = try await AutomationSourceSyntaxDiscovery.analyze(graph: sourceGraph,
                    frozenRoot: sessionRoot.appendingPathComponent("source"), session: sessionRoot, developer: developer, command: command,
                    compilationConditions: compilationConditions, willStart: { try await self.requireActive() })
                try requireActive()
                sourceSyntax = parsed
                let syntaxFile = try AutomationDurableFile(url: sessionRoot.appendingPathComponent("source-syntax-index.json"), maximumBytes: 1_048_576)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                try syntaxFile.withLock { try syntaxFile.write(try encoder.encode(parsed)) }
            } catch AutomationContractError.missingEvidence(_) {
                try requireActive(); syntaxUnavailable = true
            }
            let selectedProduct = try AutomationAssociatedHostPlatform.subjectProduct(productSettings.stdout,
                platform: resolvedProductPlatform, products: derived.appendingPathComponent("Build/Products"))
            generated.subjectProductPath = selectedProduct.path; generated.subjectBundleID = selectedProduct.bundleID
            if profile == .macOS { try AutomationMacGUIIdentity.validate(approval.target) }
            try AutomationPreparedSourceIntegrity.verify(graph: sourceGraph, manifest: manifest, frozenRoot: sessionRoot.appendingPathComponent("source"))
            try nativeContext.verify()
            let frozenGraph = sourceGraph, frozenWorkspace = workspace, frozenGenerated = generated
            let hostArguments = ["xcodebuild", "build-for-testing"] + containerArguments + nativeContext.arguments + pinnedArguments + ["-scheme", generated.scheme,
                            "-configuration", approval.configuration, "-destination", profile.destination,
                            "-sdk", profile.sdkName, "-derivedDataPath", derived.path, "-jobs", "2",
                            "BUILD_DIR=" + derived.appendingPathComponent("Build/Products").path, "CODE_SIGNING_ALLOWED=YES"]
            try await recovery.host(build: {
                try await self.requireActive()
                try AutomationPreparedSourceIntegrity.verify(graph: frozenGraph, manifest: manifest, frozenRoot: sessionRoot.appendingPathComponent("source"))
                guard try supportRecovery.isMaterialized() else {
                    return AutomationOwnedCommand.Result(exitStatus: 65, stdout: Data(),
                        stderr: Data("Captured Intents generated support is missing or changed before host build.".utf8), logsTruncated: false)
                }
                try nativeContext.verify(); try frozenWorkspace?.verify(session: sessionRoot, manifest: manifest)
                try AutomationHostGenerator.verifyGeneratedSources(frozenGenerated, sessionRoot: sessionRoot)
                guard try AutomationReadOnlyFile.read(generatedProject, maximumBytes: 16 * 1024 * 1024) == generatedProjectBytes else { throw AutomationContractError.conflictingOperation }
                return try await self.command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: hostArguments,
                    directory: sessionRoot, environment: environment, timeout: .seconds(600), willStart: { try await self.requireActive() })
            }, recheckBaseline: {
                try await self.requireActive()
                try AutomationPreparedSourceIntegrity.verify(graph: frozenGraph, manifest: manifest, frozenRoot: sessionRoot.appendingPathComponent("source"))
                try await AutomationPreparationBuildRecovery.recheckBaseline(project: generatedProject, baseline: baselineProject, generated: generatedProjectBytes) {
                    try await recovery.baseline(build: {
                        try await self.requireActive()
                        return try await self.command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: baselineArguments,
                            directory: sessionRoot, environment: environment, timeout: .seconds(600), willStart: { try await self.requireActive() })
                    }, retain: { result, retry in
                        try AutomationPreparationBuildRecovery.retain(result, at: sessionRoot.appendingPathComponent("baseline-recheck-\(UUID().uuidString)-\(retry).log"))
                    })
                }
                try AutomationPreparedSourceIntegrity.verify(graph: frozenGraph, manifest: manifest, frozenRoot: sessionRoot.appendingPathComponent("source"))
            }, repair: { _ in
                try await self.requireActive()
                let changed = try supportRecovery.restore()
                try AutomationHostGenerator.verifyGeneratedSources(frozenGenerated, sessionRoot: sessionRoot)
                return changed
            }, retain: { result, pass, retry in
                try AutomationPreparationBuildRecovery.retain(result, at: sessionRoot.appendingPathComponent("host-build-\(pass)-\(retry).log"))
                try AutomationPreparationBuildRecovery.retain(result, at: sessionRoot.appendingPathComponent("build.log"))
            })
            try requireActive()
            try Task.checkCancellation()
            try nativeContext.verify()
            try workspace?.verify(session: sessionRoot, manifest: manifest)
            try AutomationHostGenerator.verifyGeneratedSources(generated, sessionRoot: sessionRoot)
            guard generatedProjectDigest == AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(generatedProject, maximumBytes: 16 * 1024 * 1024)) else {
                throw AutomationContractError.conflictingOperation
            }
            try AutomationSourceSnapshot.verifyOriginal(manifest)
            try AutomationPreparedSourceIntegrity.verify(graph: sourceGraph, manifest: manifest, frozenRoot: sessionRoot.appendingPathComponent("source"))
            if profile == .macOS { try AutomationMacGUIIdentity.validate(approval.target) }
            var prepared = try Self.resolve(products: derived.appendingPathComponent("Build/Products"), generated: generated, target: approval.target)
            prepared.app.logicalID = candidate.id; prepared.app.configuration = approval.configuration
            prepared.app.owningModule = resolvedProductPlatform.swiftModuleName; prepared.app.sourceManifestDigest = try manifest.digest
            prepared.app.sourceSyntaxIndexDigest = try sourceSyntax?.digest
            var boundJavaScriptProfile = approval.servedJavaScriptProfile
            if let recipe = approval.automaticMetroRecipe {
                boundJavaScriptProfile = try recipe.profile(manifest: manifest, graph: sourceGraph, app: prepared.app,
                    compilationConditions: compilationConditions)
            }
            var servedJavaScriptIdentity: AutomationServedJavaScriptIdentity?
            if var servedProfile = boundJavaScriptProfile {
                try requireActive()
                servedJavaScriptIdentity = try await javaScriptSupervisor.withSession(profile: servedProfile,
                    manifest: manifest, app: prepared.app, target: approval.target, frozenRoot: sessionRoot.appendingPathComponent("source"),
                    developerDirectory: developer, supportRoot: sessionRoot, operation: { identity in
                        try await self.requireActive(); return identity
                    })
                guard let identity = servedJavaScriptIdentity else { throw AutomationContractError.missingEvidence("The local JavaScript server did not retain its bundle identity.") }
                servedProfile.bundleSHA256 = identity.bundleSHA256
                guard identity.profileDigest == (try servedProfile.digest) else { throw AutomationContractError.conflictingOperation }
                boundJavaScriptProfile = servedProfile
                prepared.app.servedJavaScriptDigest = try servedJavaScriptIdentity?.digest
            }
            var catalog = try AutomationSourceCatalogReconciliation.apply(sourceGraph,
                to: AutomationSurfaceCatalogReader.read(app: prepared.app, product: URL(fileURLWithPath: prepared.subjectProductPath)))
            if let sourceSyntax { catalog = try AutomationSourceSyntaxReconciliation.apply(sourceSyntax, graph: sourceGraph, to: catalog) }
            if syntaxUnavailable { catalog.gaps.append("Selected Xcode source syntax scanning is unavailable; retained lexical candidates remain partial.") }
            if prepared.app.owningModule == nil { catalog.gaps.append("The selected target's compiled Swift module name is unresolved.") }
            let value = AutomationPreparedApplication(source: manifest, generatedHost: generated, host: prepared,
                catalog: catalog, buildLogPath: sessionRoot.appendingPathComponent("build.log").path, buildLogTruncated: false,
                workspace: workspace, sourceGraph: sourceGraph, sourceSyntax: sourceSyntax,
                servedJavaScriptProfile: boundJavaScriptProfile, servedJavaScriptIdentity: servedJavaScriptIdentity,
                servedJavaScriptFrozenRootPath: boundJavaScriptProfile == nil ? nil : sessionRoot.appendingPathComponent("source").path,
                selectedDeveloperDirectoryPath: developer.path)
            try requireActive()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let state = try AutomationDurableFile(url: sessionRoot.appendingPathComponent("prepared-application.json"), maximumBytes: AutomationPreparedApplicationRecord.maximumRecordBytes)
            try state.withLock { try state.write(try encoder.encode(value)) }
            try requireActive()
            return value
        } catch {
            try AutomationSourceSnapshot.verifyOriginal(manifest)
            throw error
        }
    }
    static func resolve(products: URL, generated: AutomationGeneratedHost, target: TargetIdentity) throws -> AutomationPreparedAppleHost {
        let profile = try AutomationAssociatedHostPlatform(target: target)
        let files = try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xctestrun" && $0.lastPathComponent.hasPrefix(generated.scheme + "_") }
        guard files.count == 1 else { throw AutomationContractError.missingEvidence("One associated host test product was not resolved") }
        let file = files[0], data = try AutomationReadOnlyFile.read(file, maximumBytes: 4 * 1024 * 1024)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw AutomationContractError.invalidIdentity }
        let entry: [String: Any]
        if let configs = plist["TestConfigurations"] as? [[String: Any]], configs.count == 1,
           let targets = configs[0]["TestTargets"] as? [[String: Any]], targets.count == 1 { entry = targets[0] }
        else if let flat = plist[generated.scheme] as? [String: Any] { entry = flat }
        else { throw AutomationContractError.invalidIdentity }
        func product(_ key: String) throws -> URL {
            guard let path = entry[key] as? String else { throw AutomationContractError.invalidIdentity }
            let resolved = path.replacingOccurrences(of: "__TESTROOT__", with: products.path)
            let url = try AutomationPath.canonical(URL(fileURLWithPath: resolved))
            guard url.path.hasPrefix(products.path + "/"), url.pathExtension == "app" else { throw AutomationContractError.invalidIdentity }
            return url
        }
        let host = try product("TestHostPath"), subject = try product("UITargetAppPath")
        guard generated.subjectProductPath == subject.path, generated.subjectBundleID != nil else {
            throw AutomationContractError.invalidPlan("Test subject is not the selected target's resolved product")
        }
        _ = try AutomationAppleHostFile.freeze(plist, testRoot: products, expectedHost: host, expectedSubject: subject, testTarget: generated.scheme, payload: Data(), platform: profile)
        guard let info = try PropertyListSerialization.propertyList(from: AutomationReadOnlyFile.read(root: host, relativePath: profile.infoPath, maximumBytes: 1_048_576), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == generated.bundleID,
              profile != .macOS || (info["CFBundlePackageType"] as? String == "APPL" && info["CFBundleSupportedPlatforms"] as? [String] == ["MacOSX"]) else { throw AutomationContractError.invalidIdentity }
        let intake = try AutomationApplicationIntake.assess(subject)
        guard intake.candidates.count == 1, let app = intake.candidates[0].app,
              app.bundleID == generated.subjectBundleID,
              app.platform == profile.appPlatform, app.productDigestVersion == profile.digestVersion else { throw AutomationContractError.invalidIdentity }
        try AutomationBuiltProductAdmission.validateEmbeddedExtensions(bundle: subject, macOS: profile == .macOS)
        if profile == .macOS {
            guard let subjectInfo = try PropertyListSerialization.propertyList(from: AutomationProductDigest.readFile(bundle: subject,
                relativePath: profile.infoPath, maximumBytes: 1_048_576, version: 2, expectedDigest: app.productDigest), format: nil) as? [String: Any],
                  subjectInfo["CFBundleSupportedPlatforms"] as? [String] == ["MacOSX"] else { throw AutomationContractError.invalidIdentity }
        }
        let hostProductDigest = try AutomationProductDigest.compute(bundle: host, version: profile.digestVersion)
        if profile == .physicalIOS {
            // Admission of local device products is separate from installed-byte or runtime proof.
            _ = try AutomationInstalledUIApplication(bundleURL: subject, target: target)
            _ = try AutomationInstalledUIApplication(bundleURL: host, target: target)
            let testDirectory = profile.plugInsPath + generated.scheme + ".xctest/"
            guard let testInfo = try PropertyListSerialization.propertyList(from: AutomationProductDigest.readFile(bundle: host,
                relativePath: testDirectory + "Info.plist", maximumBytes: 1_048_576, version: profile.digestVersion,
                expectedDigest: hostProductDigest), format: nil) as? [String: Any],
                  let executable = testInfo["CFBundleExecutable"] as? String,
                  executable.range(of: #"^[A-Za-z0-9_.-]{1,256}$"#, options: .regularExpression) != nil,
                  executable != ".", executable != ".." else { throw AutomationContractError.invalidIdentity }
            try AutomationPhysicalExecutable.validate(AutomationProductDigest.readFile(bundle: host,
                relativePath: testDirectory + executable, maximumBytes: 512 * 1024 * 1024,
                version: profile.digestVersion, expectedDigest: hostProductDigest), fileType: 8)
        }
        return .init(app: app, target: target, xctestrunPath: file.path, xctestrunDigest: AutomationArtifactRegistry.digest(data),
                     subjectProductPath: subject.path, hostBundlePath: host.path, hostProductDigest: hostProductDigest,
                     hostBundleID: generated.bundleID, testTarget: generated.scheme, hostProductDigestVersion: profile.digestVersion)
    }
}
#endif
