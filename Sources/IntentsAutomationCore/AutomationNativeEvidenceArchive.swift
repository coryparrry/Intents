import Foundation

/// Storage helper used by the existing native ScenarioPersistence results store.
/// Imports data only; it never creates an XCTest invocation or acceptance receipt.
public actor AutomationNativeEvidenceArchive {
    private let root: URL
    public init(root: URL) throws {
        guard root.isFileURL else { throw AutomationContractError.invalidIdentity }
        try Self.createOwnedDirectory(root)
        self.root = try AutomationPath.canonical(root)
        guard self.root.path == root.path else { throw AutomationContractError.invalidIdentity }
        _ = try AutomationDurableFile(url: self.root.appendingPathComponent("trust-check"), maximumBytes: 1)
    }
    public func importAttempt(frozen: AutomationFrozenCase, report: AutomationAttemptReport, sourceRoot: URL, exposure: AutomationEvidenceExposure? = nil) async throws -> AutomationNativeEvidenceDocument {
        try AutomationEvidenceExposure.require(exposure, frozen: frozen, attempts: [report])
        try exposure?.validateSourceRoot(sourceRoot)
        defer { withExtendedLifetime(exposure) {} }
        let cases = try AutomationCaseStore(readOnlyRoot: sourceRoot.appendingPathComponent("Cases"))
        let original = try await cases.load(id: frozen.plan.id, revision: frozen.plan.revision, digest: frozen.digest)
        let saved = try await cases.loadAttempt(id: report.attemptID, frozen: original)
        guard original == frozen, saved == report else { throw AutomationContractError.conflictingOperation }
        let references = try AutomationNativeEvidenceDocument.references(saved)
        var artifacts: [AutomationNativeEvidenceDocument.Artifact] = [], bytes: [String: Data] = [:], total = 0
        if !references.isEmpty {
            let prefix = report.attemptID + "/artifacts/"
            let indexData = try AutomationReadOnlyFile.read(root: sourceRoot, relativePath: prefix + "artifact-index.json", maximumBytes: 4_194_304, requirePrivateOwnership: true)
            let index = try JSONDecoder().decode([String: AutomationArtifactRegistry.Artifact].self, from: indexData)
            guard index.count <= 10_000 else { throw AutomationContractError.invalidIdentity }
            for (handle, scope) in references.sorted(by: { $0.key < $1.key }) {
                guard let artifact = index[handle], artifact.handle == handle, artifact.scope == scope else { throw AutomationContractError.conflictingOperation }
                let data = try AutomationReadOnlyFile.read(root: sourceRoot, relativePath: prefix + artifact.relativePath, maximumBytes: 16_777_216, requirePrivateOwnership: true)
                total += data.count
                guard total <= 134_217_728, artifact.byteCount == data.count, artifact.sha256 == AutomationArtifactRegistry.digest(data) else { throw AutomationContractError.conflictingOperation }
                artifacts.append(.init(handle: handle, scope: scope, relativePath: "Artifacts/" + handle, sha256: artifact.sha256, byteCount: artifact.byteCount))
                bytes[handle] = data
            }
        }
        let document = try AutomationNativeEvidenceDocument(frozen: original, report: saved, artifacts: artifacts)
        try pinCampaignRoot(sourceRoot)
        let directory = try ownedDirectory(document)
        let file = try AutomationDurableFile(url: directory.appendingPathComponent("evidence.json"), maximumBytes: 8_388_608)
        let encoded = try encode(document)
        try file.withLock {
            if let existing = try file.read() {
                guard existing == encoded else { throw AutomationContractError.conflictingOperation }
                return
            }
            if !artifacts.isEmpty { try Self.createOwnedDirectory(directory.appendingPathComponent("Artifacts")) }
            for artifact in artifacts {
                let output = try AutomationDurableFile(url: directory.appendingPathComponent(artifact.relativePath), maximumBytes: 16_777_216)
                let data = bytes[artifact.handle]!
                if let prior = try output.read() { guard prior == data else { throw AutomationContractError.conflictingOperation } }
                else { try output.write(data) }
            }
            try file.write(encoded)
        }
        try verifyArtifacts(document, directory: directory)
        return document
    }
    public func snapshot(authority: AutomationEvidenceExposureAuthority) throws -> AutomationNativeEvidenceSnapshot {
        try readSnapshot(authority: authority)
    }
    public func documents() throws -> [AutomationNativeEvidenceDocument] {
        try readSnapshot(authority: nil).documents
    }
    private func readSnapshot(authority: AutomationEvidenceExposureAuthority?) throws -> AutomationNativeEvidenceSnapshot {
        var presentations: [AutomationNativeEvidencePresentation] = []
        var documents: [AutomationNativeEvidenceDocument] = [], total = 0, visited = 0
        let caseIDs = try boundedNames(root, limit: 1000)
        for caseID in caseIDs where !caseID.hasPrefix(".") && !["campaign-root.json", "campaign-root.json.lock"].contains(caseID) {
            guard Self.digest(caseID) else { throw AutomationContractError.invalidIdentity }
            let caseRoot = root.appendingPathComponent(caseID)
            guard try AutomationPath.canonical(caseRoot).path == caseRoot.path else { throw AutomationContractError.invalidIdentity }
            let attempts = try boundedNames(caseRoot, limit: 1000 - visited)
            for attempt in attempts {
                visited += 1
                guard Self.digest(attempt), documents.count < 1000 else { throw AutomationContractError.invalidIdentity }
                let relative = caseID + "/" + attempt + "/evidence.json"
                // Interrupted imports leave no published document and are safe to retry.
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) else { continue }
                let data = try AutomationReadOnlyFile.read(root: root, relativePath: relative, maximumBytes: 8_388_608, requirePrivateOwnership: true)
                total += data.count; guard total <= 67_108_864 else { throw AutomationContractError.invalidIdentity }
                let document = try JSONDecoder().decode(AutomationNativeEvidenceDocument.self, from: data)
                try document.validate()
                guard let authority else { throw AutomationContractError.missingEvidence("Native evidence exposure permission is required") }
                try validateCampaignRoot(authority.supportRoot)
                let exposure = try authority.reserve(frozen: document.frozen, attempts: [document.report])
                presentations.append(try exposure.presentation(document))
                guard document.frozen.digest == caseID, Self.attemptKey(document.report.attemptID) == attempt else { throw AutomationContractError.conflictingOperation }
                try verifyArtifacts(document, directory: root.appendingPathComponent(caseID + "/" + attempt))
                documents.append(document)
            }
        }
        return .init(presentations: presentations.sorted { $0.document.displayDate == $1.document.displayDate ? $0.id < $1.id : $0.document.displayDate > $1.document.displayDate })
    }
    private func pinCampaignRoot(_ source: URL) throws {
        let file = try AutomationDurableFile(url: root.appendingPathComponent("campaign-root.json"), maximumBytes: 4096)
        let bytes = try AutomationFrozenCase.canonicalData(["supportRoot": source.path])
        try file.withLock {
            if let prior = try file.read() { guard prior == bytes else { throw AutomationContractError.conflictingOperation } }
            else {
                let allowed = Set(["campaign-root.json.lock", "trust-check", "trust-check.lock"])
                guard try boundedNames(root, limit: 1000).allSatisfy(allowed.contains) else {
                    throw AutomationContractError.missingEvidence("An existing archive without campaign provenance cannot be exposed")
                }
                try file.write(bytes)
            }
        }
    }
    private func validateCampaignRoot(_ source: URL) throws {
        guard try AutomationPath.canonical(source).path == source.path else { throw AutomationContractError.invalidIdentity }
        let bytes = try AutomationReadOnlyFile.read(root: root, relativePath: "campaign-root.json", maximumBytes: 4096, requirePrivateOwnership: true)
        guard bytes == (try AutomationFrozenCase.canonicalData(["supportRoot": source.path])) else { throw AutomationContractError.conflictingOperation }
    }
    private func boundedNames(_ directory: URL, limit: Int) throws -> [String] {
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) else { throw AutomationContractError.invalidIdentity }
        var result: [String] = []
        for case let entry as URL in entries {
            guard result.count < limit else { throw AutomationContractError.invalidIdentity }
            result.append(entry.lastPathComponent)
        }
        return result.sorted()
    }
    private func ownedDirectory(_ document: AutomationNativeEvidenceDocument) throws -> URL {
        guard try AutomationPath.canonical(root).path == root.path else { throw AutomationContractError.invalidIdentity }
        let directory = root.appendingPathComponent(document.frozen.digest + "/" + Self.attemptKey(document.report.attemptID))
        try Self.createOwnedDirectory(directory)
        guard try AutomationPath.canonical(directory).path == directory.path else { throw AutomationContractError.invalidIdentity }
        return directory
    }
    private static func createOwnedDirectory(_ directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try createOwnedDirectory(directory.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard try AutomationPath.canonical(directory).path == directory.path,
              try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw AutomationContractError.invalidIdentity }
    }
    private func verifyArtifacts(_ document: AutomationNativeEvidenceDocument, directory: URL) throws {
        var total = 0
        for artifact in document.artifacts {
            let data = try AutomationReadOnlyFile.read(root: directory, relativePath: artifact.relativePath, maximumBytes: 16_777_216, requirePrivateOwnership: true)
            total += data.count
            guard total <= 134_217_728, data.count == artifact.byteCount, AutomationArtifactRegistry.digest(data) == artifact.sha256 else { throw AutomationContractError.conflictingOperation }
        }
    }
    private func encode(_ document: AutomationNativeEvidenceDocument) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= 8_388_608 else { throw AutomationContractError.invalidIdentity }; return data
    }
    private static func attemptKey(_ id: String) -> String { AutomationArtifactRegistry.digest(Data(id.utf8)) }
    private static func digest(_ value: String) -> Bool { value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }
}
