import Foundation
#if os(macOS)
import CryptoKit
import Darwin
#endif

public struct AutomationSourceSyntaxIndex: Codable, Equatable, Sendable {
    public struct Tool: Codable, Equatable, Sendable { public var relativePath: String; public var sha256: String }
    public var schemaVersion = 2
    public var sourceManifestDigest: String
    public var sourceGraphDigest: String
    public var helperTemplateDigest: String
    public var helperDigest: String
    public var toolchain: [Tool]
    public var inputs: [AutomationSourceGraph.Input]
    public var declarations: [AutomationSourceDeclaration]
    public var gaps: [String]
    public var coverage = "partial"
    public var compilationConditions: AutomationSourceCompilationConditions? = nil
    public var digest: String {
        get throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return AutomationArtifactRegistry.digest(try encoder.encode(self))
        }
    }
}

/// A scanner compiled from known source through the same retained command owner
/// as preparation. Swift source is parser input; it is never evaluated or imported.
#if os(macOS)
enum AutomationSourceSyntaxDiscovery {
    private struct Input: Codable { let relativePath: String, owner: String, sha256: String, source: String }
    private struct Request: Codable { let graphDigest: String; let inputs: [Input] }
    private struct ParsedInput: Codable { let relativePath: String, owner: String, sha256: String }
    private struct Response: Codable { let graphDigest: String; let inputs: [ParsedInput]; let declarations: [AutomationSourceDeclaration]; let parseRecoveryFiles: [String] }
    private struct InputKey: Hashable { let path: String, owner: String }
    static func analyze(graph: AutomationSourceGraph, frozenRoot: URL, session: URL,
                        developer: URL, command: AutomationOwnedCommand,
                        compilationConditions: AutomationSourceCompilationConditions? = nil,
                        willStart: @escaping @Sendable () async throws -> Void = {}) async throws -> AutomationSourceSyntaxIndex {
        try Task.checkCancellation()
        try compilationConditions?.validate(graph: graph)
        let graphDigest = try graph.digest
        let directory = session.appendingPathComponent("source-syntax")
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw AutomationContractError.conflictingOperation }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var selected: [AutomationSourceGraph.Input] = [], input: [Input] = [], total = 0, excluded = 0
        var gaps = ["SwiftSyntax candidates resolve literal Boolean and observed selected-target custom/OS/environment conditions; architecture, import, compiler, feature predicates, aliases, macros, generated inputs and dependency ownership remain unresolved."]
        if compilationConditions?.activeConditions == nil { gaps.append("Selected-target custom compilation flags are unavailable or contain unsupported forms.") }
        if compilationConditions?.platformPredicates == nil { gaps.append("Selected-target Swift OS and environment predicates remain unresolved.") }
        for file in graph.inputs where graph.admitsSwiftDeclarations(role: file.role) {
            try Task.checkCancellation()
            let data = try AutomationReadOnlyFile.read(root: frozenRoot, relativePath: file.relativePath, maximumBytes: 16 * 1024 * 1024)
            guard AutomationArtifactRegistry.digest(data) == file.sha256 else { throw AutomationContractError.conflictingOperation }
            if data.count > 512 * 1024 || total + data.count > 8 * 1024 * 1024 || input.count >= 1000 {
                excluded += 1
                if excluded <= 50 { gaps.append("Source syntax input budget excludes " + file.relativePath) }
                continue
            }
            guard let source = String(data: data, encoding: .utf8) else { throw AutomationContractError.invalidIdentity }
            total += data.count; selected.append(file)
            input.append(.init(relativePath: file.relativePath, owner: file.owner, sha256: file.sha256, source: source))
        }
        if excluded > 50 { gaps.append("Source syntax input budget excludes " + String(excluded) + " files; only the first 50 paths are listed.") }
        let tools = try fingerprint(developer)
        let host = developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host")
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developer.path,
                           "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TMPDIR": NSTemporaryDirectory(),
                           "CLANG_MODULE_CACHE_PATH": directory.appendingPathComponent("module-cache").path]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let request = try encoder.encode(Request(graphDigest: graphDigest, inputs: input))
        guard request.count <= 24 * 1024 * 1024 else { throw AutomationContractError.missingEvidence("Source syntax request exceeds its input budget") }
        let requestFile = try AutomationDurableFile(url: directory.appendingPathComponent("request.json"), maximumBytes: 24 * 1024 * 1024)
        try requestFile.withLock { try requestFile.write(request) }
        let source = Data(AutomationSourceSyntaxTemplate.source.utf8)
        let sourceFile = try AutomationDurableFile(url: directory.appendingPathComponent("Scanner.swift"), maximumBytes: 64 * 1024)
        try sourceFile.withLock { try sourceFile.write(source) }
        let sdkResult = try await command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--sdk", "macosx", "--show-sdk-path"], directory: directory, environment: environment, timeout: .seconds(30), willStart: willStart)
        try requireComplete(sdkResult)
        let sdk = try AutomationPath.canonical(URL(fileURLWithPath: String(decoding: sdkResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        guard sdk.path.hasPrefix(developer.path + "/") else { throw AutomationContractError.invalidIdentity }
        let helper = directory.appendingPathComponent("source-scanner")
        let built = try await command.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc", "-j", "2", "-sdk", sdk.path, "-I", host.path, "-L", host.path,
                        "-Xlinker", "-rpath", "-Xlinker", host.path, sourceFile.url.path, "-o", helper.path],
            directory: directory, environment: environment, timeout: .seconds(120), willStart: willStart)
        let buildLog = try AutomationDurableFile(url: directory.appendingPathComponent("compiler.log"), maximumBytes: 2_100_000)
        try buildLog.withLock { try buildLog.write(built.stdout + built.stderr) }
        try requireComplete(built)
        let helperDigest = try digestFile(helper)
        guard tools == (try fingerprint(developer)) else { throw AutomationContractError.conflictingOperation }
        let scanned = try await command.run(executable: helper, arguments: [requestFile.url.path],
            directory: directory, environment: environment, timeout: .seconds(30), willStart: willStart)
        try requireComplete(scanned); try Task.checkCancellation()
        guard helperDigest == (try digestFile(helper)), tools == (try fingerprint(developer)),
              source == (try AutomationReadOnlyFile.read(sourceFile.url, maximumBytes: 64 * 1024)),
              request == (try AutomationReadOnlyFile.read(requestFile.url, maximumBytes: 24 * 1024 * 1024)) else { throw AutomationContractError.conflictingOperation }
        let response = try JSONDecoder().decode(Response.self, from: scanned.stdout)
        guard response.graphDigest == graphDigest, response.declarations.count <= 5000,
              response.parseRecoveryFiles.count <= input.count else { throw AutomationContractError.invalidIdentity }
        let expectedParsed = input.map { ParsedInput(relativePath: $0.relativePath, owner: $0.owner, sha256: $0.sha256) }
        guard try encoder.encode(response.inputs) == encoder.encode(expectedParsed) else { throw AutomationContractError.conflictingOperation }
        var lines: [InputKey: Int] = [:]
        for file in input {
            try Task.checkCancellation()
            let key = InputKey(path: file.relativePath, owner: file.owner)
            guard lines[key] == nil else { throw AutomationContractError.invalidIdentity }
            lines[key] = file.source.utf8.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }
        }
        for declaration in response.declarations {
            try Task.checkCancellation()
            guard let count = lines[.init(path: declaration.relativePath, owner: declaration.owner)],
                  declaration.line > 0, declaration.line <= count,
                  declaration.column.map({ $0 > 0 && $0 <= 512 * 1024 }) == true,
                  declaration.qualifiedName?.isEmpty == false, !declaration.protocols.isEmpty else { throw AutomationContractError.invalidIdentity }
        }
        for path in response.parseRecoveryFiles {
            guard input.contains(where: { $0.relativePath == path }) else { throw AutomationContractError.invalidIdentity }
            gaps.append("SwiftSyntax parse recovery occurred in " + path)
        }
        for file in selected {
            guard file.sha256 == AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: frozenRoot, relativePath: file.relativePath, maximumBytes: 512 * 1024)) else { throw AutomationContractError.conflictingOperation }
        }
        for declaration in response.declarations where AutomationSourceCompilationConditions.resolve(declaration, facts: compilationConditions) == nil {
            if gaps.count < 100 { gaps.append("Conditional declaration is unresolved at " + declaration.relativePath + ":" + String(declaration.line)) }
        }
        // Parser recovery cannot establish either a declaration or its branch.
        let declarations = response.declarations.filter { !response.parseRecoveryFiles.contains($0.relativePath) }
        var index = AutomationSourceSyntaxIndex(sourceManifestDigest: graph.sourceManifestDigest, sourceGraphDigest: graphDigest,
                     helperTemplateDigest: AutomationArtifactRegistry.digest(source), helperDigest: helperDigest,
                     toolchain: tools, inputs: selected,
                     declarations: declarations.sorted { ($0.owner, $0.relativePath, $0.line, $0.name) < ($1.owner, $1.relativePath, $1.line, $1.name) }, gaps: Array(Set(gaps)).sorted())
        index.compilationConditions = compilationConditions
        guard try encoder.encode(index).count <= 1_048_576 else { throw AutomationContractError.missingEvidence("Source syntax index exceeds its output budget") }
        return index
    }
    private static func requireComplete(_ result: AutomationOwnedCommand.Result) throws {
        guard result.directChildReaped, result.pipesDrained, result.ownedIdentity != nil, result.callbacksDrained else { throw AutomationContractError.terminationUnverified }
        guard result.exitStatus == 0, !result.logsTruncated else { throw AutomationContractError.missingEvidence("Owned source syntax scanner output is unavailable") }
    }
    private static func fingerprint(_ developer: URL) throws -> [AutomationSourceSyntaxIndex.Tool] {
        try ["usr/bin/swiftc", "usr/lib/swift/host/libSwiftSyntax.dylib", "usr/lib/swift/host/libSwiftParser.dylib", "usr/lib/swift/host/libSwiftParserDiagnostics.dylib"].map { relative in
            let path = "Toolchains/XcodeDefault.xctoolchain/" + relative
            var info = stat()
            if lstat(developer.appendingPathComponent(path).path, &info) != 0 {
                if errno == ENOENT { throw AutomationContractError.missingEvidence("Selected Xcode source syntax component is absent") }
                throw AutomationContractError.invalidIdentity
            }
            let canonical = try AutomationPath.canonical(developer.appendingPathComponent(path))
            guard canonical.path.hasPrefix(developer.path + "/") else { throw AutomationContractError.invalidIdentity }
            return .init(relativePath: path, sha256: try digestFile(canonical))
        }
    }
    /// Streaming avoids retaining the compiler's large executable in the app.
    private static func digestFile(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AutomationContractError.invalidIdentity }; defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0,
              before.st_size <= 256 * 1024 * 1024 else { throw AutomationContractError.invalidIdentity }
        var hash = SHA256(), count = 0, buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let size = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if size == 0 { break }
            guard size > 0 else { throw AutomationContractError.invalidIdentity }
            count += size; guard count <= 256 * 1024 * 1024 else { throw AutomationContractError.invalidIdentity }
            hash.update(data: Data(buffer.prefix(size)))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, count == before.st_size, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw AutomationContractError.conflictingOperation }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
