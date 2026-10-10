import Foundation

/// Immutable historical results. Reopening validates facts, never authorizes execution.
public actor AutomationReproductionArchive {
    private let root: URL
    private let cases: AutomationCaseStore
    public init(caseStoreRoot: URL) throws {
        cases = try AutomationCaseStore(root: caseStoreRoot)
        let parent = try AutomationPath.canonical(caseStoreRoot)
        root = parent.appendingPathComponent("Reproductions")
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var directory: ObjCBool = false
        guard try AutomationPath.canonical(root).path == root.path,
              FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw AutomationContractError.invalidIdentity
        }
    }
    public func save(_ report: AutomationReproductionReport) async throws {
        try await validateStoredFacts(report)
        let data = try AutomationFrozenCase.canonicalData(report)
        let file = try AutomationDurableFile(url: root.appendingPathComponent(report.runID + ".json"), maximumBytes: 2_097_152)
        try file.withLock {
            guard try file.read() == nil else { throw AutomationContractError.conflictingOperation }
            try file.write(data)
        }
    }
    public func load(runID: String) async throws -> AutomationReproductionReport {
        try await read(runID: runID, maximumBytes: 2_097_152).0
    }
    public func records() async throws -> [AutomationReproductionReport] {
        guard try AutomationPath.canonical(root).path == root.path else { throw AutomationContractError.invalidIdentity }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard names.count <= 200 else { throw AutomationContractError.invalidIdentity }
        var reports: [AutomationReproductionReport] = [], total = 0
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let (report, bytes) = try await read(runID: String(name.dropLast(5)), maximumBytes: min(2_097_152, 16_777_216 - total))
            total += bytes; guard total <= 16_777_216 else { throw AutomationContractError.invalidIdentity }
            reports.append(report)
        }
        return reports
    }
    private func read(runID: String, maximumBytes: Int) async throws -> (AutomationReproductionReport, Int) {
        guard AutomationUIFailureSearchRecord.identifier(runID) else { throw AutomationContractError.invalidIdentity }
        let data = try AutomationReadOnlyFile.read(root: root, relativePath: runID + ".json", maximumBytes: maximumBytes, requirePrivateOwnership: true)
        let report = try JSONDecoder().decode(AutomationReproductionReport.self, from: data)
        guard report.runID == runID else { throw AutomationContractError.conflictingOperation }
        try await validateStoredFacts(report); return (report, data.count)
    }
    private func validateStoredFacts(_ report: AutomationReproductionReport) async throws {
        try report.validate()
        let frozen = report.frozen
        let stored = try await cases.load(id: frozen.plan.id, revision: frozen.plan.revision, digest: frozen.digest)
        guard stored.plan == frozen.plan,
              try await cases.loadAttempt(id: report.originalFailure.attemptID, frozen: frozen) == report.originalFailure else {
            throw AutomationContractError.conflictingOperation
        }
        for attempt in report.attempts {
            guard try await cases.loadAttempt(id: attempt.attemptID, frozen: frozen) == attempt else {
                throw AutomationContractError.conflictingOperation
            }
        }
    }
}
