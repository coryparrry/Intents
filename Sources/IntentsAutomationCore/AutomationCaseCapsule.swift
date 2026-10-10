import Foundation

public struct AutomationCapsuleManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var size: Int
        public var sha256: String
        public init(path: String, size: Int, sha256: String) { self.path = path; self.size = size; self.sha256 = sha256 }
    }
    public var schemaVersion = 1
    public var caseDigest: String
    public var files: [Entry]
    public var artifactsPolicy = "omitted; only reviewed synthetic case data and canonical facts"
    public var evidenceTrust = "historicalUnverified"
}
public struct AutomationCapsuleExportApproval: Sendable {
    public var caseDigest: String
    public var attemptIDs: Set<String>
    public var syntheticDataAndMetadataReviewed: Bool
    public init(caseDigest: String, attemptIDs: Set<String>, syntheticDataAndMetadataReviewed: Bool) {
        self.caseDigest = caseDigest; self.attemptIDs = attemptIDs; self.syntheticDataAndMetadataReviewed = syntheticDataAndMetadataReviewed
    }
}
public struct AutomationImportedCapsule: Sendable {
    public var frozen: AutomationFrozenCase
    public var historicalAttempts: [AutomationAttemptReport]
    public let evidenceTrust = "historicalUnverified"
    public let liveAccepted = false
}

/// Data-only directory or bounded compressed capsules. Import validates integrity, never executes, grants approval, or promotes historical verdicts.
public enum AutomationCaseCapsule {
    public static func validateEntries(_ entries: [AutomationCapsuleManifest.Entry]) throws {
        guard !entries.isEmpty, entries.count <= 128 else { throw AutomationContractError.invalidIdentity }
        var paths: Set<String> = [], total = 0
        for entry in entries {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count <= 6, !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  entry.path.utf8.count <= 512, !entry.path.contains("\\"), !entry.path.contains(":"),
                  entry.path.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil,
                  entry.path.hasSuffix(".json"), entry.path != "manifest.json",
                  entry.size >= 0, entry.size <= 2_097_152,
                  entry.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  paths.insert(entry.path.lowercased()).inserted else { throw AutomationContractError.invalidIdentity }
            total += entry.size
            guard total <= 32 * 1024 * 1024 else { throw AutomationContractError.invalidIdentity }
        }
    }
    public static func export(frozen: AutomationFrozenCase, attempts: [AutomationAttemptReport], approval: AutomationCapsuleExportApproval, exposure: AutomationEvidenceExposure? = nil, to destination: URL) throws {
        try AutomationEvidenceExposure.require(exposure, frozen: frozen, attempts: attempts)
        defer { withExtendedLifetime(exposure) {} }
        let (manifest, records) = try exportRecords(frozen: frozen, attempts: attempts, approval: approval, destination: destination)
        let entries = manifest.files
        let parent = try AutomationPath.canonical(destination.deletingLastPathComponent())
        let output = parent.appendingPathComponent(destination.lastPathComponent)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for entry in entries {
                let file = try AutomationDurableFile(url: output.appendingPathComponent(entry.path), maximumBytes: 2_097_152)
                try file.write(records[entry.path]!)
            }
            try AutomationDurableFile(url: output.appendingPathComponent("manifest.json"), maximumBytes: 128 * 1024).write(AutomationFrozenCase.canonicalData(manifest))
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
    public static func exportCompressed(frozen: AutomationFrozenCase, attempts: [AutomationAttemptReport], approval: AutomationCapsuleExportApproval, exposure: AutomationEvidenceExposure? = nil, to destination: URL) throws {
        try AutomationEvidenceExposure.require(exposure, frozen: frozen, attempts: attempts)
        defer { withExtendedLifetime(exposure) {} }
        let (manifest, records) = try exportRecords(frozen: frozen, attempts: attempts, approval: approval, destination: destination)
        let bytes = try AutomationCompressedCaseCapsule.encode(manifest: manifest, records: records)
        let parent = try AutomationPath.canonical(destination.deletingLastPathComponent())
        let output = parent.appendingPathComponent(destination.lastPathComponent)
        let staging = parent.appendingPathComponent(".intentscase-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let file = staging.appendingPathComponent("capsule")
        try AutomationDurableFile(url: file, maximumBytes: AutomationCompressedCaseCapsule.maximumBytes).write(bytes)
        // Exclusive publication: an existing destination, including a symlink, cannot be replaced.
        try FileManager.default.linkItem(at: file, to: output)
    }
    private static func exportRecords(frozen: AutomationFrozenCase, attempts: [AutomationAttemptReport], approval: AutomationCapsuleExportApproval, destination: URL) throws -> (AutomationCapsuleManifest, [String: Data]) {
        try frozen.validate()
        guard approval.syntheticDataAndMetadataReviewed, approval.caseDigest == frozen.digest,
              Set(attempts.map(\.attemptID)).count == attempts.count, Set(attempts.map(\.attemptID)) == approval.attemptIDs,
              attempts.count <= 100, destination.isFileURL, destination.pathExtension == "intentscase",
              !FileManager.default.fileExists(atPath: destination.path) else { throw AutomationContractError.invalidPlan("Review the exact synthetic case and attempt selection before export") }
        var records: [String: Data] = ["plan.json": try AutomationFrozenCase.canonicalData(frozen)]
        for attempt in attempts {
            guard attempt.attemptID.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
            try AutomationRecordedEvidence.validate(report: attempt, plan: frozen.plan)
            records["attempts/" + attempt.attemptID + "/report.json"] = try AutomationFrozenCase.canonicalData(attempt)
        }
        let entries = records.keys.sorted().map { AutomationCapsuleManifest.Entry(path: $0, size: records[$0]!.count, sha256: AutomationArtifactRegistry.digest(records[$0]!)) }
        try validateEntries(entries)
        return (AutomationCapsuleManifest(caseDigest: frozen.digest, files: entries), records)
    }
    public static func read(_ directory: URL) throws -> AutomationImportedCapsule {
        guard directory.isFileURL, directory.pathExtension == "intentscase" else { throw AutomationContractError.invalidIdentity }
        let info = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard info.isSymbolicLink == false else { throw AutomationContractError.invalidIdentity }
        if info.isRegularFile == true {
            let bytes = try AutomationReadOnlyFile.read(directory, maximumBytes: AutomationCompressedCaseCapsule.maximumBytes)
            let (manifest, records) = try AutomationCompressedCaseCapsule.decode(bytes)
            return try importRecords(manifest: manifest, records: records)
        }
        guard info.isDirectory == true else { throw AutomationContractError.invalidIdentity }
        let root = try AutomationPath.canonical(directory)
        let manifestData = try AutomationReadOnlyFile.read(root: root, relativePath: "manifest.json", maximumBytes: 128 * 1024)
        let manifest = try JSONDecoder().decode(AutomationCapsuleManifest.self, from: manifestData)
        try validateManifest(manifest)
        let expectedPaths = Set(manifest.files.map(\.path)).union(["manifest.json"])
        guard try files(in: root) == expectedPaths else { throw AutomationContractError.invalidIdentity }
        var data: [String: Data] = [:]
        for entry in manifest.files {
            let bytes = try AutomationReadOnlyFile.read(root: root, relativePath: entry.path, maximumBytes: 2_097_152)
            guard bytes.count == entry.size, AutomationArtifactRegistry.digest(bytes) == entry.sha256 else { throw AutomationContractError.conflictingOperation }
            data[entry.path] = bytes
        }
        return try importRecords(manifest: manifest, records: data)
    }
    static func validateManifest(_ manifest: AutomationCapsuleManifest) throws {
        guard manifest.schemaVersion == 1, manifest.evidenceTrust == "historicalUnverified",
              manifest.artifactsPolicy == "omitted; only reviewed synthetic case data and canonical facts" else { throw AutomationContractError.invalidIdentity }
        try validateEntries(manifest.files)
    }
    static func importRecords(manifest: AutomationCapsuleManifest, records: [String: Data]) throws -> AutomationImportedCapsule {
        try validateManifest(manifest)
        guard Set(records.keys) == Set(manifest.files.map(\.path)) else { throw AutomationContractError.invalidIdentity }
        for entry in manifest.files {
            guard let bytes = records[entry.path], bytes.count == entry.size,
                  AutomationArtifactRegistry.digest(bytes) == entry.sha256 else { throw AutomationContractError.conflictingOperation }
        }
        var data = records
        guard let planData = data.removeValue(forKey: "plan.json") else { throw AutomationContractError.invalidIdentity }
        let frozen = try JSONDecoder().decode(AutomationFrozenCase.self, from: planData); try frozen.validate()
        guard frozen.digest == manifest.caseDigest else { throw AutomationContractError.conflictingOperation }
        var attempts: [AutomationAttemptReport] = []
        for path in data.keys.sorted() {
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "attempts", parts[2] == "report.json" else { throw AutomationContractError.invalidIdentity }
            let report = try JSONDecoder().decode(AutomationAttemptReport.self, from: data[path]!)
            guard report.attemptID == parts[1] else { throw AutomationContractError.conflictingOperation }
            try AutomationRecordedEvidence.validate(report: report, plan: frozen.plan); attempts.append(report)
        }
        return .init(frozen: frozen, historicalAttempts: attempts)
    }
    private static func files(in root: URL) throws -> Set<String> {
        var entriesSeen = 0
        var result: Set<String> = [], stack: [(URL, Int)] = [(root, 0)]
        while let (directory, depth) = stack.popLast() {
            guard depth <= 6 else { throw AutomationContractError.invalidIdentity }
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            entriesSeen += children.count
            guard entriesSeen <= 256, children.count <= 128 else { throw AutomationContractError.invalidIdentity }
            for child in children {
                let info = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                guard info.isSymbolicLink == false else { throw AutomationContractError.invalidIdentity }
                if info.isDirectory == true { stack.append((child, depth + 1)) }
                else {
                    guard info.isRegularFile == true, child.path.hasPrefix(root.path + "/") else { throw AutomationContractError.invalidIdentity }
                    result.insert(String(child.path.dropFirst(root.path.count + 1)))
                    guard result.count <= 129 else { throw AutomationContractError.invalidIdentity }
                }
            }
        }
        return result
    }
}
