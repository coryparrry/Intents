import Foundation
import CryptoKit
import IntentsAutomationDateCodec

public struct AutomationScope: Codable, Equatable, Sendable {
    public var protocolVersion = 1
    public var runId: String, attemptId: String, segmentId: String
    public var leaseGeneration: Int
    public init(runID: String, attemptID: String, segmentID: String, leaseGeneration: Int) {
        runId = runID; attemptId = attemptID; segmentId = segmentID; self.leaseGeneration = leaseGeneration
    }
    public func validate() throws {
        guard protocolVersion == 1, leaseGeneration > 0,
              [runId, attemptId, segmentId].allSatisfy({ $0.utf8.count <= 256 && $0.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil }) else {
            throw AutomationContractError.invalidIdentity
        }
    }
}

struct AutomationFileProvenance: Codable, Equatable, Sendable {
    let planDigest: String, operationID: String, receiptDigest: String
}

public actor AutomationArtifactRegistry {
    public struct Artifact: Codable, Equatable, Sendable {
        public var handle: String
        public var scope: AutomationScope
        public var relativePath: String
        public var sha256: String
        public var byteCount: Int
        public var fileMetadata: AutomationIntentFileMetadata? = nil
        var nativeOnly: Bool? = nil
        var fileProvenance: AutomationFileProvenance? = nil
    }
    private let root: URL
    private let secretEvidence: AutomationSecretEvidenceFence
    private var artifacts: [String: Artifact] = [:]
    public init(root: URL, secretEvidenceRoot: URL? = nil) throws {
        guard root.isFileURL else { throw AutomationContractError.invalidIdentity }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let canonicalRoot = try AutomationPath.canonical(root)
        self.root = canonicalRoot
        self.secretEvidence = try AutomationSecretEvidenceFence(root: secretEvidenceRoot ?? canonicalRoot)
        let index = self.root.appendingPathComponent("artifact-index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            let data = try Data(contentsOf: index)
            guard data.count <= 4_194_304 else { throw AutomationContractError.invalidIdentity }
            artifacts = try JSONDecoder().decode([String: Artifact].self, from: data)
        }
    }
    /// A campaign-shared fence also covers separate per-attempt registries.
    func secretEvidenceRoot() -> URL { secretEvidence.root }
    func restrictSecretEvidence(scope: AutomationScope) throws { try secretEvidence.restrict(scope) }
    func canExposeEvidence(scope: AutomationScope) -> Bool { secretEvidence.permits(scope) }
    func reserveModelEvidence(scope: AutomationScope) throws -> AutomationSecretEvidencePermit { try secretEvidence.reserve(scope) }
    public func register(relativePath: String, scope: AutomationScope) throws -> Artifact {
        try scope.validate()
        guard canExposeEvidence(scope: scope) else { throw AutomationContractError.missingEvidence("Secret-tainted evidence is withheld") }
        guard artifacts.count < 10_000 else { throw AutomationContractError.invalidIdentity }
        guard !Self.nativePath(relativePath), !artifacts.values.contains(where: { $0.relativePath == relativePath && $0.nativeOnly == true }) else { throw AutomationContractError.invalidIdentity }
        let url = try ownedURL(relativePath)
        let data = try boundedData(url)
        let artifact = Artifact(handle: UUID().uuidString, scope: scope, relativePath: relativePath,
                                sha256: Self.digest(data), byteCount: data.count)
        var next = artifacts; next[artifact.handle] = artifact
        let encoded = try JSONEncoder().encode(next)
        guard encoded.count <= 4_194_304 else { throw AutomationContractError.invalidIdentity }
        try encoded.write(to: root.appendingPathComponent("artifact-index.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("artifact-index.json").path)
        artifacts = next; return artifact
    }
    public func resolve(handle: String, scope: AutomationScope) throws -> URL {
        guard canExposeEvidence(scope: scope), let artifact = artifacts[handle], artifact.scope == scope, artifact.nativeOnly != true, artifact.fileMetadata == nil, !Self.nativePath(artifact.relativePath) else { throw AutomationContractError.invalidIdentity }
        let url = try ownedURL(artifact.relativePath), data = try boundedData(url)
        guard data.count == artifact.byteCount, Self.digest(data) == artifact.sha256 else { throw AutomationContractError.conflictingOperation }
        return url
    }
    /// File bytes and file-bearing runner logs are never ordinary model/capsule evidence.
    func storeNativeEvidence(data: Data, scope: AutomationScope, metadata: AutomationIntentFileMetadata? = nil, provenance: AutomationFileProvenance? = nil) throws -> Artifact {
        try scope.validate()
        guard canExposeEvidence(scope: scope), artifacts.count < 10_000, data.count <= 16_777_216 else { throw AutomationContractError.invalidIdentity }
        guard (metadata == nil) == (provenance == nil) else { throw AutomationContractError.invalidIdentity }
        if let provenance {
            guard [provenance.planDigest, provenance.receiptDigest].allSatisfy({ $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }),
                  AutomationHostProgram.identifier(provenance.operationID) else { throw AutomationContractError.invalidIdentity }
        }
        try metadata?.verify(data)
        let name = "native-" + UUID().uuidString + ".bin", file = try AutomationDurableFile(url: root.appendingPathComponent(name), maximumBytes: 16_777_216)
        try file.withLock { try file.write(data, stagingName: name + ".staging") }
        let artifact = Artifact(handle: UUID().uuidString, scope: scope, relativePath: name, sha256: Self.digest(data), byteCount: data.count,
            fileMetadata: metadata, nativeOnly: true, fileProvenance: provenance)
        var next = artifacts; next[artifact.handle] = artifact
        let encoded = try JSONEncoder().encode(next)
        guard encoded.count <= 4_194_304 else { throw AutomationContractError.invalidIdentity }
        try encoded.write(to: root.appendingPathComponent("artifact-index.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("artifact-index.json").path)
        artifacts = next; return artifact
    }
    func fileInput(_ permit: AutomationFileTransferPermit) throws -> AutomationJSON {
        guard canExposeEvidence(scope: permit.producerScope), let artifact = artifacts[permit.handle],
              artifact.scope == permit.producerScope, artifact.sha256 == permit.sha256, artifact.nativeOnly == true,
              artifact.fileProvenance?.planDigest == permit.planDigest, artifact.fileProvenance?.operationID == permit.outputID, artifact.fileProvenance?.receiptDigest == permit.receiptDigest,
              let metadata = artifact.fileMetadata else { throw AutomationInputBindingError.inputUnavailable }
        let bytes = try AutomationReadOnlyFile.read(root: root, relativePath: artifact.relativePath, maximumBytes: 8192, requirePrivateOwnership: true)
        guard bytes.count == artifact.byteCount, Self.digest(bytes) == artifact.sha256 else { throw AutomationContractError.conflictingOperation }
        try metadata.verify(bytes)
        let fields = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(metadata))
        return .object(["kind": .string("intentFile"), "value": .string(bytes.base64EncodedString()), "file": fields])
    }
    private static func nativePath(_ relativePath: String) -> Bool { relativePath.hasPrefix("native-") || relativePath.hasPrefix(".native-") }
    private func ownedURL(_ relative: String) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, relative.utf8.count <= 1024, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !relative.contains("\\"), !relative.contains("\0") else { throw AutomationContractError.invalidIdentity }
        let path = root.appendingPathComponent(relative), canonical = try AutomationPath.canonical(path)
        guard canonical.path == path.path, canonical.path.hasPrefix(root.path + "/"),
              try canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw AutomationContractError.invalidIdentity }
        return canonical
    }
    private func boundedData(_ url: URL) throws -> Data {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_777_216 else { throw AutomationContractError.invalidIdentity }
        let data = try Data(contentsOf: url); guard data.count <= 16_777_216 else { throw AutomationContractError.invalidIdentity }; return data
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public func store(data: Data, name: String, scope: AutomationScope) throws -> Artifact {
        try scope.validate()
        guard canExposeEvidence(scope: scope) else { throw AutomationContractError.missingEvidence("Secret-tainted evidence is withheld") }
        guard !Self.nativePath(name), name.range(of: #"^[A-Za-z0-9_.-]{1,128}$"#, options: .regularExpression) != nil,
              name != ".", name != "..", data.count <= 16_777_216 else { throw AutomationContractError.invalidIdentity }
        let url = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw AutomationContractError.conflictingOperation }
        let file = try AutomationDurableFile(url: url, maximumBytes: 16_777_216)
        try file.withLock { try file.write(data) }
        return try register(relativePath: name, scope: scope)
    }
}
