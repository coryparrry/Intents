import Foundation

/// Immutable historical results. Reopening validates facts, never authorizes execution.
public actor AutomationFixComparisonArchive {
    private let root: URL
    private let cases: AutomationCaseStore
    public init(caseStoreRoot: URL) throws {
        cases = try AutomationCaseStore(root: caseStoreRoot)
        let parent = try AutomationPath.canonical(caseStoreRoot)
        root = parent.appendingPathComponent("FixComparisons")
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var directory: ObjCBool = false
        guard try AutomationPath.canonical(root).path == root.path,
              FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw AutomationContractError.invalidIdentity
        }
    }
    public func save(_ report: AutomationFixComparisonReport) async throws {
        try await validateStoredFacts(report)
        let data = try AutomationFrozenCase.canonicalData(report)
        let file = try AutomationDurableFile(url: root.appendingPathComponent(report.beforeRunID + ".json"), maximumBytes: 8_388_608)
        try file.withLock {
            guard try file.read() == nil else { throw AutomationContractError.conflictingOperation }
            try file.write(data)
        }
    }
    public func load(runID: String) async throws -> AutomationFixComparisonReport {
        try await read(runID: runID, maximumBytes: 8_388_608).0
    }
    public func records() async throws -> [AutomationFixComparisonReport] {
        guard try AutomationPath.canonical(root).path == root.path else { throw AutomationContractError.invalidIdentity }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard names.count <= 200 else { throw AutomationContractError.invalidIdentity }
        var reports: [AutomationFixComparisonReport] = [], total = 0
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let (report, bytes) = try await read(runID: String(name.dropLast(5)), maximumBytes: min(8_388_608, 33_554_432 - total))
            total += bytes; guard total <= 33_554_432 else { throw AutomationContractError.invalidIdentity }
            reports.append(report)
        }
        return reports
    }
    private func read(runID: String, maximumBytes: Int) async throws -> (AutomationFixComparisonReport, Int) {
        guard AutomationUIFailureSearchRecord.identifier(runID) else { throw AutomationContractError.invalidIdentity }
        let data = try AutomationReadOnlyFile.read(root: root, relativePath: runID + ".json", maximumBytes: maximumBytes, requirePrivateOwnership: true)
        let report = try JSONDecoder().decode(AutomationFixComparisonReport.self, from: data)
        guard report.beforeRunID == runID else { throw AutomationContractError.conflictingOperation }
        try await validateStoredFacts(report); return (report, data.count)
    }
    private func validateStoredFacts(_ report: AutomationFixComparisonReport) async throws {
        try report.validate()
        for (frozen, attempts) in [(report.baseline, report.before), (report.candidate, report.after)] {
            let stored = try await cases.load(id: frozen.plan.id, revision: frozen.plan.revision, digest: frozen.digest)
            guard stored.plan == frozen.plan else { throw AutomationContractError.conflictingOperation }
            for attempt in attempts {
                guard try await cases.loadAttempt(id: attempt.attemptID, frozen: frozen) == attempt else { throw AutomationContractError.conflictingOperation }
            }
        }
    }
}
