import CryptoKit
import Foundation

struct ScenarioSelectedDefinition: Codable, Equatable, Sendable {
    var id: UUID
    var version: Int
}

private struct ScenarioAcceptanceReceipt: Codable {
    var runID: UUID
    var scenarioID: UUID
    var invocationID: UUID
    var runDigest: String
}

struct ScenarioPendingNativeSave: Codable, Sendable {
    var planID: UUID
    var coordinateID: UUID
    var run: ScenarioRun
    var artifactRootPath: String
    var ledger: ScenarioImportLedger
}

enum ScenarioPersistenceError: LocalizedError, Sendable {
    case conflictingDefinition
    case immutableRunExists
    case missingArtifact(String)
    case invalidDefinition(String)
    case invalidRun(String)
    case invalidJournal(String)
    case acceptanceNotReady
    case immutablePlanExists
    case immutableExecutionRecordExists

    var errorDescription: String? {
        switch self {
        case .conflictingDefinition:
            "A different frozen definition already exists for this scenario version."
        case .immutableRunExists:
            "This invocation already has an immutable saved run."
        case .missingArtifact(let name):
            "The evidence artifact \(name) is missing."
        case .invalidDefinition(let name):
            "The frozen scenario definition \(name) is unreadable or has an invalid digest. Repair it before release checks can pass."
        case .invalidRun(let name):
            "The saved scenario run \(name) is unreadable or has inconsistent identity. Repair it before release checks can pass."
        case .invalidJournal(let name):
            "The execution journal \(name) is unreadable or has inconsistent identity. Repair it before device recovery can continue."
        case .acceptanceNotReady:
            "The run cannot be accepted until its execution journal is durably validated."
        case .immutablePlanExists:
            "A different frozen execution plan already exists for this run."
        case .immutableExecutionRecordExists:
            "A different terminal execution record already exists for this run."
        }
    }
}

actor ScenarioPersistence {
    let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func prepare() throws {
        try fileManager.createDirectory(at: definitionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: journalsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: plansDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: progressDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: pendingNativeDirectory, withIntermediateDirectories: true)
    }

    func savePlan(_ plan: ScenarioExecutionPlan) throws {
        try prepare()
        guard !plan.coordinates.isEmpty,
              Set(plan.coordinates.map(\.id)).count == plan.coordinates.count,
              !plan.testContractDigest.isEmpty,
              !plan.definitionDigest.isEmpty,
              !plan.appProductDigest.isEmpty,
              !plan.testProductDigest.isEmpty,
              plan.sourceInputsDigest?.isEmpty == false,
              Set(plan.coordinates.map { "\($0.caseID):\($0.lane.rawValue):\($0.repetition)" }).count
                == plan.coordinates.count else {
            throw ScenarioPersistenceError.invalidRun("execution plan")
        }
        let url = plansDirectory.appending(path: "\(plan.id.uuidString).json")
        let data = try Self.encoder.encode(plan)
        if fileManager.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else { throw ScenarioPersistenceError.immutablePlanExists }
            return
        }
        try data.write(to: url, options: .withoutOverwriting)
    }

    func loadPlan(id: UUID) throws -> ScenarioExecutionPlan? {
        let url = plansDirectory.appending(path: "\(id.uuidString).json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let plan = try Self.decoder.decode(ScenarioExecutionPlan.self, from: Data(contentsOf: url))
        guard plan.id == id else { throw ScenarioPersistenceError.invalidRun("execution plan") }
        return plan
    }

    func loadPlans() throws -> [ScenarioExecutionPlan] {
        guard fileManager.fileExists(atPath: plansDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: plansDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let plan = try loadPlan(id: id) else {
                    throw ScenarioPersistenceError.invalidRun("execution plan")
                }
                return plan
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func saveProgress(_ progress: ScenarioExecutionProgress) throws {
        try prepare()
        guard let plan = try loadPlan(id: progress.planID),
              progress.records.count == plan.coordinates.count,
              Set(progress.records.map(\.id)) == Set(plan.coordinates.map(\.id)),
              progress.records.allSatisfy({ plan.coordinates.contains($0.coordinate) }) else {
            throw ScenarioPersistenceError.invalidRun("execution progress")
        }
        try Self.encoder.encode(progress).write(
            to: progressDirectory.appending(path: "\(progress.planID.uuidString).json"),
            options: .atomic
        )
    }

    func loadProgress(planID: UUID) throws -> ScenarioExecutionProgress? {
        let url = progressDirectory.appending(path: "\(planID.uuidString).json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let progress = try Self.decoder.decode(ScenarioExecutionProgress.self, from: Data(contentsOf: url))
        guard progress.planID == planID else {
            throw ScenarioPersistenceError.invalidRun("execution progress")
        }
        return progress
    }

    /// A plan is durable before dispatch. After a crash, preserve the last
    /// checkpoint and mark an in-flight coordinate recoveryRequired; never
    /// silently borrow an older run to fill the missing population.
    func recoverIncompleteExecutionRecords() throws -> [ScenarioExecutionRecord] {
        let plans = try loadPlans()
        let completed = Set(try loadExecutionRecords().map(\.planID))
        var recovered: [ScenarioExecutionRecord] = []
        for plan in plans where !completed.contains(plan.id) {
            let records = try loadProgress(planID: plan.id)?.records
                ?? plan.coordinates.map(ScenarioExecutionCoordinateRecord.unstarted)
            // A feature action may be complete but waiting for its history
            // write. Keep that coordinate editable by the save-only recovery
            // path; sealing a terminal record here would force a redispatch.
            if records.contains(where: {
                $0.coordinate.lane == .appFeature
                    && $0.state == .recoveryRequired
                    && $0.evidenceRunID != nil
            }) || records.contains(where: {
                $0.coordinate.lane != .appFeature
                    && $0.state == .recoveryRequired
                    && (try? loadPendingNativeSave(planID: plan.id, coordinateID: $0.id)) != nil
            }) { continue }
            let record = try ScenarioExecutionRecord.make(plan: plan, records: records)
            try saveExecutionRecord(record)
            recovered.append(record)
        }
        return recovered
    }

    func saveExecutionRecord(_ record: ScenarioExecutionRecord) throws {
        try prepare()
        guard let plan = try loadPlan(id: record.planID),
              record.id == plan.id,
              Set(plan.coordinates.map(\.id)) == Set(record.records.map(\.id)),
              record.records.count == plan.coordinates.count,
              !record.evidenceDigest.isEmpty,
              try ScenarioExecutionRecord.make(
                plan: plan, records: record.records,
                selectedAssessments: record.selectedAssessments ?? [],
                completedAt: record.completedAt
              ).evidenceDigest == record.evidenceDigest else {
            throw ScenarioPersistenceError.invalidRun("terminal execution record")
        }
        let url = recordsDirectory.appending(path: "\(record.id.uuidString).json")
        let data = try Self.encoder.encode(record)
        if fileManager.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else {
                throw ScenarioPersistenceError.immutableExecutionRecordExists
            }
            return
        }
        try data.write(to: url, options: .withoutOverwriting)
    }

    func loadExecutionRecords() throws -> [ScenarioExecutionRecord] {
        guard fileManager.fileExists(atPath: recordsDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: recordsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try Self.decoder.decode(ScenarioExecutionRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.completedAt > $1.completedAt }
    }

    func savePendingNativeSave(_ pending: ScenarioPendingNativeSave) throws {
        try prepare()
        guard let plan = try loadPlan(id: pending.planID),
              plan.coordinates.contains(where: { $0.id == pending.coordinateID
                  && $0.caseID == pending.run.scenarioID }),
              pending.run.laneResults.count == 1,
              pending.run.id == pending.run.invocation.id,
              !pending.artifactRootPath.isEmpty else {
            throw ScenarioPersistenceError.invalidRun("pending native child")
        }
        try Self.encoder.encode(pending).write(
            to: pendingNativeURL(planID: pending.planID, coordinateID: pending.coordinateID),
            options: .atomic
        )
    }

    func loadPendingNativeSave(planID: UUID, coordinateID: UUID) throws -> ScenarioPendingNativeSave? {
        let url = pendingNativeURL(planID: planID, coordinateID: coordinateID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let pending = try Self.decoder.decode(ScenarioPendingNativeSave.self, from: Data(contentsOf: url))
        guard pending.planID == planID, pending.coordinateID == coordinateID else {
            throw ScenarioPersistenceError.invalidRun("pending native child")
        }
        return pending
    }

    func clearPendingNativeSave(planID: UUID, coordinateID: UUID) throws {
        let url = pendingNativeURL(planID: planID, coordinateID: coordinateID)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func pendingNativeURL(planID: UUID, coordinateID: UUID) -> URL {
        pendingNativeDirectory.appending(path: "\(planID.uuidString)-\(coordinateID.uuidString).json")
    }

    func saveDefinition(_ definition: ScenarioDefinition) throws {
        try ScenarioValidator.validate(definition)
        try prepare()
        let directory = definitionsDirectory.appending(path: definition.id.uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = definitionURL(definition)
        let data = try Self.encoder.encode(definition)
        let existingVersions = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.map(loadDefinition)
        if let existing = existingVersions.first(where: { $0.version == definition.version }) {
            guard existing.definitionDigest == definition.definitionDigest else {
                throw ScenarioPersistenceError.conflictingDefinition
            }
            return
        }
        if fileManager.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else { throw ScenarioPersistenceError.conflictingDefinition }
            return
        }
        try data.write(to: url, options: .withoutOverwriting)
    }

    func loadDefinitions() throws -> [ScenarioDefinition] {
        guard fileManager.fileExists(atPath: definitionsDirectory.path) else { return [] }
        let files = try recursiveJSONFiles(in: definitionsDirectory)
        return try files.map(loadDefinition)
            .sorted { ($0.name, $0.version) < ($1.name, $1.version) }
    }

    func saveRun(_ run: ScenarioRun, artifactRoot: URL?) throws -> ScenarioRun {
        try prepare()
        let runDirectory = runsDirectory
            .appending(path: run.scenarioID.uuidString, directoryHint: .isDirectory)
            .appending(path: run.id.uuidString, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: runDirectory.path) {
            guard !fileManager.fileExists(atPath: runDirectory.appending(path: "run.json").path) else {
                throw ScenarioPersistenceError.immutableRunExists
            }
            // Earlier versions wrote directly into the final directory. Keep
            // an interrupted copy for diagnosis, then allow the pending native
            // child to be saved without executing the app action again.
            let interrupted = rootDirectory.appending(path: "InterruptedRunWrites", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: interrupted, withIntermediateDirectories: true)
            try fileManager.moveItem(
                at: runDirectory,
                to: interrupted.appending(path: "\(run.id.uuidString)-\(UUID().uuidString)")
            )
        }
        let stagingRoot = rootDirectory.appending(path: ".RunStaging", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staging = stagingRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            var stored = run
            stored.acceptanceStatus = .pending
            if let artifactRoot {
                let artifactDirectory = staging.appending(path: "Artifacts", directoryHint: .isDirectory)
                try fileManager.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
                for resultIndex in stored.laneResults.indices {
                    for artifactIndex in stored.laneResults[resultIndex].artifacts.indices {
                        var artifact = stored.laneResults[resultIndex].artifacts[artifactIndex]
                        let source = artifactRoot.appending(path: artifact.relativePath).standardizedFileURL
                        guard fileManager.fileExists(atPath: source.path) else {
                            throw ScenarioPersistenceError.missingArtifact(artifact.filename)
                        }
                        let storedName = "\(artifact.id.uuidString)-\(source.lastPathComponent)"
                        let destination = artifactDirectory.appending(path: storedName)
                        try fileManager.copyItem(at: source, to: destination)
                        artifact.relativePath = "Artifacts/\(storedName)"
                        stored.laneResults[resultIndex].artifacts[artifactIndex] = artifact
                    }
                }
            }
            try Self.encoder.encode(stored).write(
                to: staging.appending(path: "run.json"),
                options: .atomic
            )
            try fileManager.createDirectory(at: runDirectory.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try fileManager.moveItem(at: staging, to: runDirectory)
            return stored
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// Publish acceptance only after the ledger and successful journal validation are durable.
    /// The receipt binds the immutable run bytes to that exact invocation and journal.
    func acceptRun(_ run: ScenarioRun, journal: ScenarioExecutionJournal) throws -> ScenarioRun {
        let persistedJournal = try loadJournal(at: journalURL(journal.id))
        let runURL = runFileURL(run)
        let persisted = try loadRun(at: runURL)
        // ISO-8601 storage rounds Date to whole seconds. Compare the same durable
        // representation while still checking every invocation identity field.
        let storedInvocation = try Self.decoder.decode(
            ScenarioInvocationIdentity.self, from: Self.encoder.encode(run.invocation)
        )
        guard journal.phase == .stopped,
              journal.id == run.invocation.id,
              journal.scenarioID == run.scenarioID,
              journal.scenarioVersion == run.scenarioVersion,
              journal.invocation == run.invocation,
              persisted.id == run.id,
              persisted.scenarioVersion == run.scenarioVersion,
              persisted.scenarioDigest == run.scenarioDigest,
              persisted.invocation == storedInvocation,
              persistedJournal.phase == .stopped,
              persistedJournal.scenarioID == persisted.scenarioID,
              persistedJournal.scenarioVersion == persisted.scenarioVersion,
              persistedJournal.invocation == persisted.invocation else {
            throw ScenarioPersistenceError.acceptanceNotReady
        }
        let receipt = ScenarioAcceptanceReceipt(
            runID: run.id,
            scenarioID: run.scenarioID,
            invocationID: journal.id,
            runDigest: Self.digest(try Data(contentsOf: runURL))
        )
        // Foundation rejects .atomic combined with .withoutOverwriting. Stage an
        // atomic file in this directory, then create the final name with a hard
        // link. The link fails if an immutable receipt already exists; a crash
        // before the link leaves only an ignored temporary file.
        let temporaryReceipt = receiptURL(run).deletingLastPathComponent()
            .appending(path: ".acceptance-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryReceipt) }
        try Self.encoder.encode(receipt).write(to: temporaryReceipt, options: .atomic)
        try fileManager.linkItem(at: temporaryReceipt, to: receiptURL(run))
        var accepted = persisted
        accepted.acceptanceStatus = .accepted
        return accepted
    }

    func loadRuns(scenarioID: UUID? = nil) throws -> [ScenarioRun] {
        guard fileManager.fileExists(atPath: runsDirectory.path) else { return [] }
        let directory = scenarioID.map { runsDirectory.appending(path: $0.uuidString) } ?? runsDirectory
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try recursiveJSONFiles(in: directory)
            .filter { $0.lastPathComponent == "run.json" }
            .map(loadRun)
            .sorted { $0.startedAt > $1.startedAt }
    }

    func loadRunPage(
        scenarioID: UUID?,
        offset: Int,
        limit: Int
    ) throws -> (runs: [ScenarioRun], hasMore: Bool, totalCount: Int) {
        let searchRoot = scenarioID.map {
            runsDirectory.appending(path: $0.uuidString, directoryHint: .isDirectory)
        } ?? runsDirectory
        guard fileManager.fileExists(atPath: searchRoot.path),
              let enumerator = fileManager.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return ([], false, 0) }
        let files = enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "run.json" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
        let window = files.dropFirst(max(0, offset)).prefix(limit + 1)
        let decoded = try window.map(loadRun)
        return (Array(decoded.prefix(limit)), decoded.count > limit || window.count > limit, files.count)
    }

    func loadLedger() throws -> ScenarioImportLedger {
        let url = rootDirectory.appending(path: "import-ledger.json")
        guard fileManager.fileExists(atPath: url.path) else { return .init() }
        return try Self.decoder.decode(ScenarioImportLedger.self, from: Data(contentsOf: url))
    }

    func saveLedger(_ ledger: ScenarioImportLedger) throws {
        try prepare()
        try Self.encoder.encode(ledger).write(
            to: rootDirectory.appending(path: "import-ledger.json"),
            options: .atomic
        )
    }

    func saveJournal(_ journal: ScenarioExecutionJournal) throws {
        try prepare()
        try Self.encoder.encode(journal).write(
            to: journalURL(journal.id),
            options: .atomic
        )
    }

    func loadJournals() throws -> [ScenarioExecutionJournal] {
        guard fileManager.fileExists(atPath: journalsDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: journalsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        .filter { $0.pathExtension == "json" }
        .map(loadJournal)
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveExecutionConfiguration(_ configuration: XcodeTestConfiguration) throws {
        try prepare()
        try Self.encoder.encode(configuration).write(
            to: rootDirectory.appending(path: "execution-configuration.json"),
            options: .atomic
        )
    }

    func loadExecutionConfiguration() throws -> XcodeTestConfiguration? {
        let url = rootDirectory.appending(path: "execution-configuration.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(XcodeTestConfiguration.self, from: Data(contentsOf: url))
    }

    func saveSelectedDefinition(id: UUID, version: Int) throws {
        guard try loadDefinitions().contains(where: { $0.id == id && $0.version == version }) else {
            throw ScenarioPersistenceError.invalidDefinition("selected scenario \(id.uuidString) v\(version)")
        }
        try prepare()
        try Self.encoder.encode(ScenarioSelectedDefinition(id: id, version: version)).write(
            to: rootDirectory.appending(path: "selected-definition.json"), options: .atomic
        )
    }

    func loadSelectedDefinition() throws -> ScenarioSelectedDefinition? {
        let url = rootDirectory.appending(path: "selected-definition.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(ScenarioSelectedDefinition.self, from: Data(contentsOf: url))
    }

    func redactedSharingCopy(of run: ScenarioRun) -> ScenarioRun {
        var copy = run
        let sensitiveKeys = ["response", "account", "token", "path", "email"]
        for laneIndex in copy.laneResults.indices {
            copy.laneResults[laneIndex].observations = copy.laneResults[laneIndex].observations.filter { key, _ in
                !sensitiveKeys.contains { key.localizedCaseInsensitiveContains($0) }
                    && !key.hasPrefix("feature.encodedValue")
                    && !key.hasPrefix("feature.metadata.")
            }
            copy.laneResults[laneIndex].observationSources = copy.laneResults[laneIndex]
                .observationSources?.filter { copy.laneResults[laneIndex].observations[$0.key] != nil }
            for assertionIndex in copy.laneResults[laneIndex].assertionResults.indices {
                copy.laneResults[laneIndex].assertionResults[assertionIndex].observedValue = nil
                copy.laneResults[laneIndex].assertionResults[assertionIndex].message =
                    copy.laneResults[laneIndex].assertionResults[assertionIndex].passed
                        ? "Assertion passed."
                        : "Assertion did not pass."
            }
            copy.laneResults[laneIndex].diagnostic = nil
            copy.laneResults[laneIndex].proposedCause = nil
            copy.laneResults[laneIndex].artifacts.removeAll { $0.kind == .screenshot }
        }
        copy.responseAssessments = nil
        return copy
    }

    private var definitionsDirectory: URL {
        rootDirectory.appending(path: "Definitions", directoryHint: .isDirectory)
    }

    private var runsDirectory: URL {
        rootDirectory.appending(path: "Runs", directoryHint: .isDirectory)
    }

    private var journalsDirectory: URL {
        rootDirectory.appending(path: "Journals", directoryHint: .isDirectory)
    }

    private var plansDirectory: URL {
        rootDirectory.appending(path: "Plans", directoryHint: .isDirectory)
    }

    private var recordsDirectory: URL {
        rootDirectory.appending(path: "ExecutionRecords", directoryHint: .isDirectory)
    }

    private var progressDirectory: URL {
        rootDirectory.appending(path: "ExecutionProgress", directoryHint: .isDirectory)
    }

    private var pendingNativeDirectory: URL {
        rootDirectory.appending(path: "PendingNativeSaves", directoryHint: .isDirectory)
    }

    private func definitionURL(_ definition: ScenarioDefinition) -> URL {
        definitionsDirectory
            .appending(path: definition.id.uuidString, directoryHint: .isDirectory)
            .appending(path: "v\(definition.version)-\(definition.definitionDigest).json")
    }

    private func loadDefinition(at url: URL) throws -> ScenarioDefinition {
        do {
            let definition = try Self.decoder.decode(ScenarioDefinition.self, from: Data(contentsOf: url))
            guard definition.hasValidDigest,
                  url.deletingLastPathComponent().lastPathComponent == definition.id.uuidString,
                  url.lastPathComponent == "v\(definition.version)-\(definition.definitionDigest).json" else {
                throw ScenarioPersistenceError.invalidDefinition(url.lastPathComponent)
            }
            return definition
        } catch {
            throw ScenarioPersistenceError.invalidDefinition(url.lastPathComponent)
        }
    }

    private func loadRun(at url: URL) throws -> ScenarioRun {
        do {
            let bytes = try Data(contentsOf: url)
            var run = try Self.decoder.decode(ScenarioRun.self, from: bytes)
            guard url.deletingLastPathComponent().lastPathComponent == run.id.uuidString,
                  url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == run.scenarioID.uuidString else {
                throw ScenarioPersistenceError.invalidRun(run.id.uuidString)
            }
            // Never trust a status encoded in run.json. Only this receipt can accept a run.
            run.acceptanceStatus = .pending
            let receiptPath = receiptURL(run)
            if fileManager.fileExists(atPath: receiptPath.path),
               let receipt = try? Self.decoder.decode(
                    ScenarioAcceptanceReceipt.self, from: Data(contentsOf: receiptPath)
               ),
               receipt.runID == run.id,
               receipt.scenarioID == run.scenarioID,
               receipt.invocationID == run.invocation.id,
               receipt.runDigest == Self.digest(bytes),
               let journal = try? loadJournal(at: journalURL(receipt.invocationID)),
               journal.phase == .stopped,
               journal.scenarioID == run.scenarioID,
               journal.scenarioVersion == run.scenarioVersion,
               journal.invocation == run.invocation {
                run.acceptanceStatus = .accepted
            }
            return run
        } catch {
            throw ScenarioPersistenceError.invalidRun(url.deletingLastPathComponent().lastPathComponent)
        }
    }

    private func runFileURL(_ run: ScenarioRun) -> URL {
        runsDirectory.appending(path: run.scenarioID.uuidString)
            .appending(path: run.id.uuidString).appending(path: "run.json")
    }

    private func receiptURL(_ run: ScenarioRun) -> URL {
        runFileURL(run).deletingLastPathComponent().appending(path: "acceptance.json")
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func journalURL(_ id: UUID) -> URL {
        journalsDirectory.appending(path: "\(id.uuidString).json")
    }

    private func loadJournal(at url: URL) throws -> ScenarioExecutionJournal {
        do {
            let journal = try Self.decoder.decode(
                ScenarioExecutionJournal.self, from: Data(contentsOf: url)
            )
            guard url.lastPathComponent == "\(journal.id.uuidString).json" else {
                throw ScenarioPersistenceError.invalidJournal(url.lastPathComponent)
            }
            return journal
        } catch {
            throw ScenarioPersistenceError.invalidJournal(url.lastPathComponent)
        }
    }

    private func recursiveJSONFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
