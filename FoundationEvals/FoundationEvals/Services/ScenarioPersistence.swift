import Foundation

enum ScenarioPersistenceError: LocalizedError, Sendable {
    case conflictingDefinition
    case immutableRunExists
    case missingArtifact(String)
    case invalidDefinition(String)
    case invalidRun(String)
    case invalidJournal(String)

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
        guard !fileManager.fileExists(atPath: runDirectory.path) else {
            throw ScenarioPersistenceError.immutableRunExists
        }
        try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        do {
            var stored = run
            if let artifactRoot {
                let artifactDirectory = runDirectory.appending(path: "Artifacts", directoryHint: .isDirectory)
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
                to: runDirectory.appending(path: "run.json"),
                options: .atomic
            )
            return stored
        } catch {
            try? fileManager.removeItem(at: runDirectory)
            throw error
        }
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
    ) throws -> (runs: [ScenarioRun], hasMore: Bool) {
        let searchRoot = scenarioID.map {
            runsDirectory.appending(path: $0.uuidString, directoryHint: .isDirectory)
        } ?? runsDirectory
        guard fileManager.fileExists(atPath: searchRoot.path),
              let enumerator = fileManager.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return ([], false) }
        let files = enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "run.json" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
        let window = files.dropFirst(max(0, offset)).prefix(limit + 1)
        let decoded = try window.map(loadRun)
        return (Array(decoded.prefix(limit)), decoded.count > limit || window.count > limit)
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
            let run = try Self.decoder.decode(ScenarioRun.self, from: Data(contentsOf: url))
            guard url.deletingLastPathComponent().lastPathComponent == run.id.uuidString,
                  url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == run.scenarioID.uuidString else {
                throw ScenarioPersistenceError.invalidRun(run.id.uuidString)
            }
            return run
        } catch {
            throw ScenarioPersistenceError.invalidRun(url.deletingLastPathComponent().lastPathComponent)
        }
    }

    private func loadJournal(at url: URL) throws -> ScenarioExecutionJournal {
        do {
            let journal = try Self.decoder.decode(ScenarioExecutionJournal.self, from: Data(contentsOf: url))
            guard url.lastPathComponent == "\(journal.id.uuidString).json" else {
                throw ScenarioPersistenceError.invalidJournal(url.lastPathComponent)
            }
            return journal
        } catch {
            throw ScenarioPersistenceError.invalidJournal(url.lastPathComponent)
        }
    }

    private func journalURL(_ id: UUID) -> URL {
        journalsDirectory.appending(path: "\(id.uuidString).json")
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
