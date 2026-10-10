import Foundation

public struct AutomationFrozenCase: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let digest: String
    public let contractDigest: String
    public let oracleDigest: String
    public let plan: AutomationCase
    public let frozenAt: Date
    public init(plan: AutomationCase) throws {
        guard plan.schemaVersion == 3, plan.revision > 0 else { throw AutomationContractError.invalidIdentity }
        schemaVersion = 1; self.plan = plan; frozenAt = Date()
        digest = try Self.planDigest(plan)
        contractDigest = try Self.comparisonContractDigest(plan)
        oracleDigest = try Self.canonicalDigest(plan.requirements)
    }
    public func validate() throws {
        guard schemaVersion == 1, digest == (try Self.planDigest(plan)),
              contractDigest == (try Self.comparisonContractDigest(plan)), oracleDigest == (try Self.canonicalDigest(plan.requirements)) else {
            throw AutomationContractError.conflictingOperation
        }
    }
    public static func planDigest(_ plan: AutomationCase) throws -> String { try canonicalDigest(plan) }
    /// Exact setup, inputs, route, observer, oracle and harness provenance stay
    /// frozen. Typed prepared cases also vary their associated-host/catalog build
    /// fingerprints while retaining the host template and declared schema.
    /// Cases without typed artifacts keep the original strict projection.
    public static func comparisonContractDigest(_ plan: AutomationCase) throws -> String {
        var contract = plan
        contract.revision = 1
        contract.app.canonicalBundlePath = nil; contract.app.productDigest = nil; contract.app.productDigestVersion = nil
        contract.app.codeDirectoryIdentity = nil; contract.app.sourceManifestDigest = nil
        contract.app.provenanceStrength = "comparisonContract"
        if let artifacts = plan.preparedMacBuildArtifacts {
            try artifacts.validate(plan: plan)
            contract.app.sourceSyntaxIndexDigest = nil
            contract.preparedMacBuildArtifacts = artifacts.comparisonProjection
        }
        if let artifacts = plan.preparedSimulatorBuildArtifacts {
            try artifacts.validate(plan: plan)
            contract.app.sourceSyntaxIndexDigest = nil
            contract.preparedSimulatorBuildArtifacts = artifacts.comparisonProjection
            if contract.provenance["catalog"] != nil { contract.provenance["catalog"] = artifacts.catalogSurfaceDigest }
        }
        return try canonicalDigest(contract)
    }
    /// Retain actual subject operation/type/codec/locator identity while permitting explicitly approved input values.
    public static func subjectContractDigest(_ plan: AutomationCase) throws -> String {
        var subject = plan.execution; subject.inputs = [:]
        if var host = subject.hostProgram {
            for index in host.operations.indices { host.operations[index].parameters = [:] }
            subject.hostProgram = host
        }
        if var ui = subject.uiProgram {
            ui.bindings = ui.bindings.mapValues { _ in "approved-input-slot" }; subject.uiProgram = ui
        }
        return try canonicalDigest(subject)
    }
    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 2_097_152 else { throw AutomationContractError.invalidIdentity }
        return data
    }
    static func canonicalDigest<T: Encodable>(_ value: T) throws -> String { AutomationArtifactRegistry.digest(try canonicalData(value)) }
}

/// Uses the existing versioned-definition/immutable-run persistence pattern.
/// Saving or loading facts never executes the app or accepts imported verdicts.
public actor AutomationCaseStore {
    private let root: URL
    private let readOnly: Bool
    public init(root: URL) throws {
        readOnly = false
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.root = try AutomationPath.canonical(root)
        _ = try AutomationDurableFile(url: self.root.appendingPathComponent("trust-check"), maximumBytes: 1)
    }
    public init(readOnlyRoot root: URL) throws {
        guard root.isFileURL, FileManager.default.fileExists(atPath: root.path),
              try AutomationPath.canonical(root).path == root.path,
              try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw AutomationContractError.invalidIdentity }
        self.root = root; readOnly = true
        _ = try AutomationDurableFile(url: root.appendingPathComponent("trust-check"), maximumBytes: 1)
    }
    public func freeze(_ plan: AutomationCase) throws -> AutomationFrozenCase {
        guard !readOnly else { throw AutomationContractError.invalidIdentity }
        try Self.identifier(plan.id); guard plan.revision > 0 else { throw AutomationContractError.invalidIdentity }
        let frozen = try AutomationFrozenCase(plan: plan)
        let directory = try directory(["Definitions", plan.id])
        let store = try AutomationDurableFile(url: directory.appendingPathComponent("v\(plan.revision)-\(frozen.digest).json"), maximumBytes: 2_097_152)
        let revisionLock = try AutomationDurableFile(url: directory.appendingPathComponent("revision-\(plan.revision).guard"), maximumBytes: 1)
        return try revisionLock.withLock {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard names.count <= 2000, !names.contains(where: { $0.hasPrefix("v\(plan.revision)-") && $0.hasSuffix(".json") && $0 != store.url.lastPathComponent }) else { throw AutomationContractError.conflictingOperation }
            if let data = try store.read() {
                let existing = try JSONDecoder().decode(AutomationFrozenCase.self, from: data); try existing.validate()
                guard existing.plan == plan else { throw AutomationContractError.conflictingOperation }; return existing
            }
            try store.write(AutomationFrozenCase.canonicalData(frozen)); return frozen
        }
    }
    public func load(id: String, revision: Int, digest: String) throws -> AutomationFrozenCase {
        try Self.identifier(id); try Self.digest(digest); guard revision > 0 else { throw AutomationContractError.invalidIdentity }
        return try readDefinition(id: id, revision: revision, digest: digest, maximumBytes: 2_097_152).0
    }
    private func readDefinition(id: String, revision: Int, digest: String, maximumBytes: Int) throws -> (AutomationFrozenCase, Int) {
        let data = try AutomationReadOnlyFile.read(root: root, relativePath: "Definitions/\(id)/v\(revision)-\(digest).json", maximumBytes: maximumBytes, requirePrivateOwnership: true)
        let frozen = try JSONDecoder().decode(AutomationFrozenCase.self, from: data); try frozen.validate()
        guard frozen.plan.id == id, frozen.plan.revision == revision, frozen.digest == digest else { throw AutomationContractError.conflictingOperation }
        return (frozen, data.count)
    }
    public func saveAttempt(_ report: AutomationAttemptReport, for frozen: AutomationFrozenCase) throws {
        guard !readOnly else { throw AutomationContractError.invalidIdentity }
        try frozen.validate(); try Self.identifier(report.attemptID)
        _ = try load(id: frozen.plan.id, revision: frozen.plan.revision, digest: frozen.digest)
        try AutomationRecordedEvidence.validate(report: report, plan: frozen.plan)
        let file = try directory(["Attempts", frozen.digest]).appendingPathComponent(report.attemptID + ".json")
        let store = try AutomationDurableFile(url: file, maximumBytes: 2_097_152)
        try store.withLock {
            guard try store.read() == nil else { throw AutomationContractError.conflictingOperation }
            try store.write(AutomationFrozenCase.canonicalData(report))
        }
    }
    public func loadAttempt(id: String, frozen: AutomationFrozenCase) throws -> AutomationAttemptReport {
        try Self.identifier(id); try frozen.validate()
        _ = try load(id: frozen.plan.id, revision: frozen.plan.revision, digest: frozen.digest)
        return try readAttempt(id: id, frozen: frozen, maximumBytes: 2_097_152).0
    }
    private func readAttempt(id: String, frozen: AutomationFrozenCase, maximumBytes: Int) throws -> (AutomationAttemptReport, Int) {
        try Self.identifier(id)
        let data = try AutomationReadOnlyFile.read(root: root, relativePath: "Attempts/\(frozen.digest)/\(id).json", maximumBytes: maximumBytes, requirePrivateOwnership: true)
        let report = try JSONDecoder().decode(AutomationAttemptReport.self, from: data)
        guard report.attemptID == id else { throw AutomationContractError.conflictingOperation }
        try AutomationRecordedEvidence.validate(report: report, plan: frozen.plan); return (report, data.count)
    }
    public func definitions() throws -> [AutomationFrozenCase] {
        let definitions = try directory(["Definitions"])
        let ids = try FileManager.default.contentsOfDirectory(atPath: definitions.path).sorted()
        guard ids.count <= 1000 else { throw AutomationContractError.invalidIdentity }
        var result: [AutomationFrozenCase] = []; var totalBytes = 0
        for id in ids {
            try Self.identifier(id)
            let folder = try directory(["Definitions", id])
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            guard names.count <= 2000 else { throw AutomationContractError.invalidIdentity }
            for name in names where name.hasSuffix(".json") {
                guard name.range(of: #"^v[1-9][0-9]*-[a-f0-9]{64}\.json$"#, options: .regularExpression) != nil,
                      let separator = name.firstIndex(of: "-"), let revision = Int(name[name.index(after: name.startIndex)..<separator]) else {
                    throw AutomationContractError.invalidIdentity
                }
                let digest = String(name[name.index(after: separator)...].dropLast(5))
                let (frozen, size) = try readDefinition(id: id, revision: revision, digest: digest, maximumBytes: min(2_097_152, 16 * 1024 * 1024 - totalBytes))
                totalBytes += size
                guard totalBytes <= 16 * 1024 * 1024 else { throw AutomationContractError.invalidIdentity }
                result.append(frozen)
                guard result.count <= 1000 else { throw AutomationContractError.invalidIdentity }
            }
        }
        return result.sorted { $0.plan.id == $1.plan.id ? $0.plan.revision < $1.plan.revision : $0.plan.id < $1.plan.id }
    }
    public func attempts(for frozen: AutomationFrozenCase) throws -> [AutomationAttemptReport] {
        try frozen.validate()
        _ = try load(id: frozen.plan.id, revision: frozen.plan.revision, digest: frozen.digest)
        let folder = try directory(["Attempts", frozen.digest])
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }.sorted()
        guard names.count <= 1000 else { throw AutomationContractError.invalidIdentity }
        var result: [AutomationAttemptReport] = []; var totalBytes = 0
        for name in names {
            let (report, size) = try readAttempt(id: String(name.dropLast(5)), frozen: frozen, maximumBytes: min(2_097_152, 16 * 1024 * 1024 - totalBytes))
            totalBytes += size
            guard totalBytes <= 16 * 1024 * 1024 else { throw AutomationContractError.invalidIdentity }
            result.append(report)
        }
        return result
    }
    private func directory(_ components: [String]) throws -> URL {
        guard try AutomationPath.canonical(root).path == root.path else { throw AutomationContractError.invalidIdentity }
        var directory = root
        for component in components {
            directory.appendPathComponent(component)
            if FileManager.default.fileExists(atPath: directory.path) {
                guard try AutomationPath.canonical(directory).path == directory.path else { throw AutomationContractError.invalidIdentity }
            } else {
                guard !readOnly else { throw AutomationContractError.invalidIdentity }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            guard try AutomationPath.canonical(directory).path == directory.path else { throw AutomationContractError.invalidIdentity }
        }
        return directory
    }
    private static func identifier(_ value: String) throws {
        guard value.utf8.count <= 128, value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
    }
    private static func digest(_ value: String) throws {
        guard value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
    }
}
