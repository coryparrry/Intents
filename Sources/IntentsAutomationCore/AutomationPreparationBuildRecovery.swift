#if os(macOS)
import Foundation

/// One transient package retry for the preparation, and at most two generated-support repairs.
/// Baseline app failures never invoke the generated-support repair closure.
actor AutomationPreparationBuildRecovery {
    private var dependencyRetried = false
    private let pinnedDependencies: Bool
    init(pinnedDependencies: Bool) { self.pinnedDependencies = pinnedDependencies }

    func baseline(build: @Sendable () async throws -> AutomationOwnedCommand.Result,
                  retain: @Sendable (AutomationOwnedCommand.Result, Int) async throws -> Void) async throws {
        let result = try await run(build: build, retain: retain)
        guard result.exitStatus == 0, !result.logsTruncated else {
            throw AutomationContractError.missingEvidence("The unmodified app baseline failed. Inspect baseline-build logs; Intents has not repaired app code or changed dependency constraints.")
        }
    }
    func host(build: @Sendable () async throws -> AutomationOwnedCommand.Result,
              recheckBaseline: @Sendable () async throws -> Void,
              repair: @Sendable (Int) async throws -> Bool,
              retain: @Sendable (AutomationOwnedCommand.Result, Int, Int) async throws -> Void) async throws {
        for pass in 0...2 {
            let result = try await run(build: build, retain: { try await retain($0, pass, $1) })
            if result.exitStatus == 0, !result.logsTruncated { return }
            try await recheckBaseline()
            guard pass < 2, try await repair(pass + 1) else {
                throw AutomationContractError.missingEvidence("Intents associated host support failed while the unmodified app baseline passed. Inspect host-build logs. No further qualified generated-support repair is available.")
            }
        }
    }
    private func run(build: @Sendable () async throws -> AutomationOwnedCommand.Result,
                     retain: @Sendable (AutomationOwnedCommand.Result, Int) async throws -> Void) async throws -> AutomationOwnedCommand.Result {
        let result = try await build()
        try await retain(result, 0)
        guard pinnedDependencies, !dependencyRetried, Self.transientPackageFailure(result) else { return result }
        dependencyRetried = true
        try Task.checkCancellation()
        let retry = try await build() // Same frozen inputs, command and versions; no cache deletion or constraint rewrite.
        try await retain(retry, 1)
        return retry
    }
    static func transientPackageFailure(_ result: AutomationOwnedCommand.Result) -> Bool {
        guard result.exitStatus != 0, !result.logsTruncated else { return false }
        let text = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        guard text.contains("Could not resolve package dependencies") else { return false }
        return ["Connection reset by peer", "The request timed out", "NSURLErrorDomain Code=-1001",
                "Could not resolve host:", "Failed to connect to"].contains { text.contains($0) }
    }
    static func retain(_ result: AutomationOwnedCommand.Result, at url: URL) throws {
        let file = try AutomationDurableFile(url: url, maximumBytes: 2_100_000)
        try file.withLock { try file.write(result.stdout + Data("\n--- stderr ---\n".utf8) + result.stderr) }
    }
    static func recheckBaseline(project: URL, baseline: Data, generated: Data,
                                build: @Sendable () async throws -> Void) async throws {
        guard try AutomationReadOnlyFile.read(project, maximumBytes: 16 * 1024 * 1024) == generated else {
            throw AutomationContractError.conflictingOperation
        }
        // Only the private, Intents-rebased project is swapped. Customer source bytes never change.
        try baseline.write(to: project, options: .atomic)
        do {
            try await build()
            guard try AutomationReadOnlyFile.read(project, maximumBytes: 16 * 1024 * 1024) == baseline else {
                throw AutomationContractError.conflictingOperation
            }
        } catch {
            try generated.write(to: project, options: .atomic)
            throw error
        }
        try generated.write(to: project, options: .atomic)
    }
}

/// Re-materializes only the exact support files created by Intents in this private session.
/// Shared project files and customer app files are never repair targets.
struct AutomationGeneratedSupportRecovery: Sendable {
    let root: URL
    let sourceDirectory: String
    let bytes: [String: Data]

    init(sessionRoot: URL, generated: AutomationGeneratedHost, workspaceRelativePath: String?) throws {
        root = try AutomationPath.canonical(sessionRoot)
        let project = try AutomationPath.canonical(URL(fileURLWithPath: generated.projectPath))
        guard project.path.hasPrefix(root.appendingPathComponent("source").path + "/"),
              generated.scheme.hasPrefix("IntentsAutomationHost_"),
              !generated.scheme.contains("/"), !generated.scheme.contains("..") else { throw AutomationContractError.invalidIdentity }
        let capturedSourceDirectory = "generated-host/" + generated.scheme + "/Sources"
        sourceDirectory = capturedSourceDirectory
        let files = generated.includesSiri == true ? AutomationHostGenerator.physicalTemplateFiles : AutomationHostGenerator.templateFiles
        var paths = files.map { capturedSourceDirectory + "/" + $0 }
        paths.append(String(project.path.dropFirst(root.path.count + 1)) + "/xcshareddata/xcschemes/" + generated.scheme + ".xcscheme")
        if let workspaceRelativePath {
            guard !workspaceRelativePath.hasPrefix("/"), !workspaceRelativePath.split(separator: "/").contains(".."),
                  workspaceRelativePath.hasSuffix(".xcworkspace") else { throw AutomationContractError.invalidIdentity }
            paths.append("source/" + workspaceRelativePath + "/xcshareddata/xcschemes/" + generated.scheme + ".xcscheme")
        }
        var captured: [String: Data] = [:]
        for path in paths { captured[path] = try AutomationReadOnlyFile.read(root: root, relativePath: path, maximumBytes: 1_048_576) }
        bytes = captured
        try AutomationHostGenerator.verifyGeneratedSources(generated, sessionRoot: root)
    }
    func restore() throws -> Bool {
        let known = Set(bytes.keys.filter { $0.hasPrefix(sourceDirectory + "/") }.map { URL(fileURLWithPath: $0).lastPathComponent })
        guard Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(sourceDirectory).path)).isSubset(of: known) else {
            throw AutomationContractError.conflictingOperation
        }
        var changed = false
        for path in bytes.keys.sorted() {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(path)
            // Missing files can be re-created, but no path may redirect writes outside the session.
            let parent = try AutomationPath.canonical(url.deletingLastPathComponent())
            guard parent.path == url.deletingLastPathComponent().path, parent.path.hasPrefix(root.path + "/") else {
                throw AutomationContractError.invalidIdentity
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes == nil || attributes?[.type] as? FileAttributeType == .typeRegular else { throw AutomationContractError.invalidIdentity }
            if attributes != nil, try AutomationReadOnlyFile.read(root: root, relativePath: path, maximumBytes: 1_048_576) == bytes[path] { continue }
            try bytes[path]!.write(to: url, options: .atomic)
            changed = true
        }
        return changed
    }
    func isMaterialized() throws -> Bool {
        for path in bytes.keys.sorted() {
            guard let actual = try? AutomationReadOnlyFile.read(root: root, relativePath: path, maximumBytes: 1_048_576),
                  actual == bytes[path] else { return false }
        }
        return true
    }
}
#endif
