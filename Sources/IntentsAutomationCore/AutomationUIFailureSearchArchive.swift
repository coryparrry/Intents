import Foundation

/// Historical campaign data. Decoding never grants execution or fresh-fixture authority.
public struct AutomationUIFailureSearchRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let runID: String
    public let baseline: AutomationFrozenCase
    public let mutations: [AutomationMutationCase]
    public let report: AutomationFailureSearchReport
    public var verificationScope: String { "historicalValidatedFacts" }
    public init(id: String, runID: String, baseline: AutomationFrozenCase, mutations: [AutomationMutationCase], report: AutomationFailureSearchReport) {
        schemaVersion = 1; self.id = id; self.runID = runID; self.baseline = baseline; self.mutations = mutations; self.report = report
    }
    func validate() throws {
        guard schemaVersion == 1, Self.identifier(id), Self.identifier(runID), mutations.count <= 2,
              report.schemaVersion == 1, report.baselineDigest == baseline.digest,
              report.attempts.count <= 20, report.interruptions.count <= 1, report.confirmations.count <= 2,
              report.stopReason.map({ $0.utf16.count <= 4096 }) ?? true,
              report.capabilityGaps.count <= 20, report.capabilityGaps.allSatisfy({ $0.utf16.count <= 4096 }) else { throw AutomationContractError.invalidIdentity }
        try baseline.validate(); try AutomationGoalPhraseVariation.validateBaseline(baseline.plan)
        let definitions = [baseline] + mutations.map(\.frozen)
        guard Set(definitions.map(\.digest)).count == definitions.count else { throw AutomationContractError.conflictingOperation }
        for mutation in mutations { try mutation.frozen.validate(); try AutomationGoalPhraseVariation.validate(mutation, baseline: baseline) }
        let byDigest = Dictionary(uniqueKeysWithValues: definitions.map { ($0.digest, $0) })
        let ids = report.attempts.map { $0.report.attemptID } + report.interruptions.map(\.attemptID)
        guard ids.allSatisfy(Self.identifier), Set(ids).count == ids.count else { throw AutomationContractError.invalidIdentity }
        let mutationDigests = Set(mutations.map { $0.frozen.digest })
        let baselineAttempts = report.attempts.filter { $0.stage == .baseline }
        let discoveries = report.attempts.filter { $0.stage == .discovery }
        guard baselineAttempts.count <= 3, baselineAttempts.allSatisfy({ $0.caseDigest == baseline.digest }),
              discoveries.allSatisfy({ mutationDigests.contains($0.caseDigest) }),
              Set(discoveries.map(\.caseDigest)).count == discoveries.count,
              Set(report.confirmations.map(\.caseDigest)).count == report.confirmations.count else { throw AutomationContractError.conflictingOperation }
        guard discoveries.map(\.caseDigest) == Array(mutationDigests.sorted().prefix(discoveries.count)),
              report.attempts.allSatisfy({ $0.stage == .baseline }) || baselineAttempts.count == 3 else { throw AutomationContractError.conflictingOperation }
        var candidates: [(String, [String])] = []
        for attempt in report.attempts where attempt.stage == .baseline || attempt.stage == .discovery {
            let result = attempt.report.result
            if result.summary == .assertionFailed && result.assessed && result.evidenceComplete && !candidates.contains(where: { $0.0 == attempt.caseDigest }) {
                candidates.append((attempt.caseDigest, result.failedObservations.sorted()))
            }
        }
        let eligible = Array(candidates.prefix(2))
        guard report.confirmations.count == eligible.count else { throw AutomationContractError.conflictingOperation }
        for (confirmation, candidate) in zip(report.confirmations, eligible) {
            guard confirmation.caseDigest == candidate.0, confirmation.signature == candidate.1,
                  confirmation.complete || report.stopReason != nil else { throw AutomationContractError.conflictingOperation }
        }
        guard report.bestConfirmedCaseDigest == report.confirmations.first(where: \.confirmed)?.caseDigest else { throw AutomationContractError.conflictingOperation }
        let stages: [AutomationSearchAttempt.Stage: Int] = [.baseline: 0, .discovery: 1, .confirmation: 2, .finalConfirmation: 3]
        var lastStage = 0
        for attempt in report.attempts {
            guard let stage = stages[attempt.stage], stage >= lastStage else { throw AutomationContractError.conflictingOperation }
            lastStage = stage
        }
        var counters = ScopeCounters()
        for (index, attempt) in report.attempts.enumerated() {
            guard let frozen = byDigest[attempt.caseDigest], attempt.stage != .reduction else { throw AutomationContractError.conflictingOperation }
            try AutomationRecordedEvidence.validate(report: attempt.report, plan: frozen.plan, expectedRunID: runID)
            counters.record(attempt.report.result)
            if !attempt.report.resourcesReleased || attempt.report.result.subjectDispatchUncertain {
                guard index == report.attempts.count - 1, report.stopReason != nil else { throw AutomationContractError.conflictingOperation }
            }
        }
        for interrupted in report.interruptions {
            guard byDigest[interrupted.caseDigest] != nil, !interrupted.reason.isEmpty, interrupted.reason.utf16.count <= 4096,
                  report.stopReason != nil else { throw AutomationContractError.conflictingOperation }
            counters.planned += 1
            if interrupted.dispatchMayHaveOccurred { counters.unresolved += 1 } else { counters.notRun += 1 }
        }
        guard counters == report.counters else { throw AutomationContractError.conflictingOperation }
        for confirmation in report.confirmations { try validate(confirmation, stage: .confirmation, byDigest: byDigest) }
        let confirmationIDs = report.confirmations.flatMap(\.attempts)
        guard Set(confirmationIDs).count == confirmationIDs.count,
              confirmationIDs == report.attempts.filter { $0.stage == .confirmation }.map({ $0.report.attemptID }) else { throw AutomationContractError.conflictingOperation }
        let finalIDs = report.finalReproduction?.attempts ?? []
        guard finalIDs == report.attempts.filter { $0.stage == .finalConfirmation }.map({ $0.report.attemptID }) else { throw AutomationContractError.conflictingOperation }
        if let best = report.bestConfirmedCaseDigest {
            guard byDigest[best] != nil, let selected = report.confirmations.first(where: { $0.caseDigest == best && $0.confirmed }),
                  let final = report.finalReproduction, final.caseDigest == best, final.signature == selected.signature,
                  final.complete || report.stopReason != nil else { throw AutomationContractError.conflictingOperation }
            try validate(final, stage: .finalConfirmation, byDigest: byDigest)
        } else if report.finalReproduction != nil { throw AutomationContractError.conflictingOperation }
        let usage = report.usage
        let values = [usage.attempts, usage.reservedSubjectOperations, usage.reservedSetupOperations, usage.reservedObserverOperations,
            usage.reservedCleanupOperations, usage.reservedUIActions, usage.controllerCalls, usage.reservedResourceReleaseOperations]
        guard values.allSatisfy({ (0...100_000).contains($0) }), usage.attempts == report.attempts.count + report.interruptions.count,
              usage.appModelRequests == nil else { throw AutomationContractError.invalidIdentity }
    }
    private func validate(_ confirmation: AutomationFailureConfirmation, stage: AutomationSearchAttempt.Stage,
                          byDigest: [String: AutomationFrozenCase]) throws {
        guard let frozen = byDigest[confirmation.caseDigest], confirmation.attempts.count <= 5,
              Set(confirmation.attempts).count == confirmation.attempts.count, !confirmation.signature.isEmpty,
              confirmation.signature == Array(Set(confirmation.signature)).sorted(),
              confirmation.signature.allSatisfy({ failed in frozen.plan.requirements.contains { ($0.checkID ?? $0.observationID) == failed } }) else {
            throw AutomationContractError.conflictingOperation
        }
        var matching = 0, passes = 0, other = 0, unassessed = 0
        for id in confirmation.attempts {
            guard let attempt = report.attempts.first(where: { $0.report.attemptID == id }), attempt.caseDigest == confirmation.caseDigest,
                  attempt.stage == stage else { throw AutomationContractError.conflictingOperation }
            let result = attempt.report.result
            if result.assessed && result.evidenceComplete && result.summary == .assertionFailed {
                if result.failedObservations.sorted() == confirmation.signature { matching += 1 } else { other += 1 }
            } else if result.assessed && result.summary == .passed { passes += 1 }
            else { unassessed += 1 }
        }
        guard confirmation.matchingFailures == matching, confirmation.assessedPasses == passes,
              confirmation.otherFailures == other, confirmation.unassessed == unassessed else { throw AutomationContractError.conflictingOperation }
    }
    static func identifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil
    }
}

public actor AutomationUIFailureSearchArchive {
    private let root: URL
    private let cases: AutomationCaseStore
    public init(caseStoreRoot: URL) throws {
        cases = try AutomationCaseStore(root: caseStoreRoot)
        let parent = try AutomationPath.canonical(caseStoreRoot)
        root = parent.appendingPathComponent("Searches")
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard try AutomationPath.canonical(root).path == root.path else { throw AutomationContractError.invalidIdentity }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw AutomationContractError.invalidIdentity
        }
    }
    public func save(_ record: AutomationUIFailureSearchRecord) async throws {
        try await validateStoredFacts(record)
        let data = try AutomationFrozenCase.canonicalData(record)
        let store = try AutomationDurableFile(url: root.appendingPathComponent(record.id + ".json"), maximumBytes: 2_097_152)
        try store.withLock {
            guard try store.read() == nil else { throw AutomationContractError.conflictingOperation }
            try store.write(data)
        }
    }
    public func load(id: String) async throws -> AutomationUIFailureSearchRecord {
        guard AutomationUIFailureSearchRecord.identifier(id) else { throw AutomationContractError.invalidIdentity }
        return try await read(id: id, maximumBytes: 2_097_152).0
    }
    private func read(id: String, maximumBytes: Int) async throws -> (AutomationUIFailureSearchRecord, Int) {
        guard AutomationUIFailureSearchRecord.identifier(id) else { throw AutomationContractError.invalidIdentity }
        let data = try AutomationReadOnlyFile.read(root: root, relativePath: id + ".json", maximumBytes: maximumBytes, requirePrivateOwnership: true)
        let record = try JSONDecoder().decode(AutomationUIFailureSearchRecord.self, from: data)
        guard record.id == id else { throw AutomationContractError.conflictingOperation }
        try await validateStoredFacts(record); return (record, data.count)
    }
    public func records() async throws -> [AutomationUIFailureSearchRecord] {
        guard try AutomationPath.canonical(root).path == root.path else { throw AutomationContractError.invalidIdentity }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard names.count <= 200 else { throw AutomationContractError.invalidIdentity }
        var records: [AutomationUIFailureSearchRecord] = []
        var totalBytes = 0
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let (record, bytes) = try await read(id: String(name.dropLast(5)), maximumBytes: min(2_097_152, 16_777_216 - totalBytes))
            totalBytes += bytes
            guard totalBytes <= 16_777_216 else { throw AutomationContractError.invalidIdentity }
            records.append(record)
        }
        return records
    }
    private func validateStoredFacts(_ record: AutomationUIFailureSearchRecord) async throws {
        try record.validate()
        for frozen in [record.baseline] + record.mutations.map(\.frozen) {
            let stored = try await cases.load(id: frozen.plan.id, revision: frozen.plan.revision, digest: frozen.digest)
            guard stored.plan == frozen.plan else { throw AutomationContractError.conflictingOperation }
        }
        let definitions = Dictionary(uniqueKeysWithValues: ([record.baseline] + record.mutations.map(\.frozen)).map { ($0.digest, $0) })
        for attempt in record.report.attempts {
            guard let frozen = definitions[attempt.caseDigest] else { throw AutomationContractError.conflictingOperation }
            guard try await cases.loadAttempt(id: attempt.report.attemptID, frozen: frozen) == attempt.report else { throw AutomationContractError.conflictingOperation }
        }
    }
}
