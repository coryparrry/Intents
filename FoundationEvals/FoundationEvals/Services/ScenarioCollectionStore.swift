import Foundation

/// Immutable collection revisions and batch manifests live beside scenario
/// evidence, but are kept separate from mutable editor selection.
actor ScenarioCollectionStore {
    let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func saveCollection(_ collection: ScenarioCollection,
                        definitions: [ScenarioDefinition]) throws {
        try collection.validate()
        if collection.version > 1 {
            guard let previous = try loadCollection(id: collection.id, version: collection.version - 1),
                  previous.projectID == collection.projectID,
                  previous.membershipDigest == collection.previousMembershipDigest else {
                throw ScenarioCollectionError.invalidCollection
            }
        }
        guard definitions.count == collection.members.count,
              Set(definitions.map(\.id)) == Set(collection.members.map(\.caseID)) else {
            throw ScenarioCollectionError.invalidCollection
        }
        for member in collection.members {
            guard let definition = definitions.first(where: { $0.id == member.caseID }),
                  definition.projectID == collection.projectID,
                  definition.version == member.version,
                  definition.definitionDigest == member.definitionDigest,
                  definition.testContractDigest == member.testContractDigest,
                  definition.hasValidDigest else {
                throw ScenarioCollectionError.invalidDefinition(member.caseID)
            }
        }
        try save(collection, at: collectionURL(id: collection.id, version: collection.version))
    }

    func loadCollection(id: UUID, version: Int) throws -> ScenarioCollection? {
        guard let collection: ScenarioCollection = try load(at: collectionURL(id: id, version: version)) else {
            return nil
        }
        guard collection.id == id, collection.version == version else {
            throw ScenarioCollectionError.invalidSavedObject
        }
        try collection.validate()
        if version > 1 {
            guard let previous = try loadCollection(id: id, version: version - 1),
                  previous.projectID == collection.projectID,
                  previous.membershipDigest == collection.previousMembershipDigest else {
                throw ScenarioCollectionError.invalidSavedObject
            }
        }
        return collection
    }

    func loadCollections() throws -> [ScenarioCollection] {
        let root = rootDirectory.appending(path: "Collections", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let files = try jsonFiles(in: root)
        return try files.map { url in
            let collection = try decoder.decode(ScenarioCollection.self, from: Data(contentsOf: url))
            guard url.standardizedFileURL.path
                == collectionURL(id: collection.id, version: collection.version).standardizedFileURL.path else {
                throw ScenarioCollectionError.invalidSavedObject
            }
            guard let loaded = try loadCollection(id: collection.id, version: collection.version) else {
                throw ScenarioCollectionError.invalidSavedObject
            }
            return loaded
        }.sorted { ($0.name, $0.version) < ($1.name, $1.version) }
    }

    func saveManifest(_ manifest: ScenarioCollectionBatchManifest,
                      collection: ScenarioCollection) throws {
        try ScenarioCollectionService.validate(manifest: manifest, collection: collection)
        guard try loadCollection(id: collection.id, version: collection.version) == collection else {
            throw ScenarioCollectionError.invalidCollection
        }
        try save(manifest, at: manifestURL(id: manifest.id))
    }

    func loadManifest(id: UUID) throws -> ScenarioCollectionBatchManifest? {
        guard let manifest: ScenarioCollectionBatchManifest = try load(at: manifestURL(id: id)) else {
            return nil
        }
        guard manifest.id == id,
              let collection = try loadCollection(id: manifest.collectionID,
                                                  version: manifest.collectionVersion) else {
            throw ScenarioCollectionError.invalidSavedObject
        }
        try ScenarioCollectionService.validate(manifest: manifest, collection: collection)
        return manifest
    }

    func loadManifests(collectionID: UUID? = nil) throws -> [ScenarioCollectionBatchManifest] {
        let root = rootDirectory.appending(path: "CollectionBatches", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try jsonFiles(in: root)
            .filter { $0.lastPathComponent.hasSuffix("-manifest.json") }
            .compactMap { url -> ScenarioCollectionBatchManifest? in
                let stem = String(url.lastPathComponent.dropLast("-manifest.json".count))
                guard let id = UUID(uuidString: stem) else {
                    throw ScenarioCollectionError.invalidSavedObject
                }
                return try loadManifest(id: id)
            }
            .filter { collectionID == nil || $0.collectionID == collectionID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func saveResult(_ result: ScenarioCollectionBatchResult) throws {
        guard let manifest = try loadManifest(id: result.manifestID) else {
            throw ScenarioCollectionError.invalidSavedObject
        }
        try validate(result: result, manifest: manifest)
        try save(result, at: resultURL(id: result.id))
    }

    func loadResult(id: UUID) throws -> ScenarioCollectionBatchResult? {
        guard let result: ScenarioCollectionBatchResult = try load(at: resultURL(id: id)) else {
            return nil
        }
        guard result.id == id, let manifest = try loadManifest(id: result.manifestID) else {
            throw ScenarioCollectionError.invalidSavedObject
        }
        try validate(result: result, manifest: manifest)
        return result
    }

    func loadResults(collectionID: UUID? = nil) throws -> [ScenarioCollectionBatchResult] {
        let root = rootDirectory.appending(path: "CollectionBatches", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let allowedManifestIDs = Set(try loadManifests(collectionID: collectionID).map(\.id))
        return try jsonFiles(in: root)
            .filter { $0.lastPathComponent.hasSuffix("-result.json") }
            .compactMap { url -> ScenarioCollectionBatchResult? in
                let stem = String(url.lastPathComponent.dropLast("-result.json".count))
                guard let id = UUID(uuidString: stem) else {
                    throw ScenarioCollectionError.invalidSavedObject
                }
                return allowedManifestIDs.contains(id) ? try loadResult(id: id) : nil
            }
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    private func validate(result: ScenarioCollectionBatchResult,
                          manifest: ScenarioCollectionBatchManifest) throws {
        let caseByPlan = Dictionary(uniqueKeysWithValues: manifest.cases.map { ($0.executionPlanID, $0) })
        let coordinates = Dictionary(uniqueKeysWithValues: manifest.coordinates.map { ($0.id, $0) })
        guard result.id == manifest.id,
              result.manifestID == manifest.id,
              result.recordedAt >= manifest.createdAt,
              result.executions.count <= manifest.cases.count,
              Set(result.executions.map(\.planID)).count == result.executions.count,
              result.executions.allSatisfy({ execution in
                  guard let plannedCase = caseByPlan[execution.planID] else { return false }
                  let expected = manifest.coordinates.filter { $0.caseID == plannedCase.id }
                  return execution.id == execution.planID
                      && ScenarioCollectionService.hasValidSeal(execution)
                      && execution.completedAt >= manifest.createdAt
                      && execution.records.count == expected.count
                      && Set(execution.records.map(\.id)) == Set(expected.map(\.id))
                      && execution.records.allSatisfy({ row in coordinates[row.id] == row.coordinate })
              }) else {
            throw ScenarioCollectionError.invalidSavedObject
        }
    }

    private func collectionURL(id: UUID, version: Int) -> URL {
        rootDirectory.appending(path: "Collections", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
            .appending(path: "v\(version).json")
    }

    private func manifestURL(id: UUID) -> URL {
        rootDirectory.appending(path: "CollectionBatches", directoryHint: .isDirectory)
            .appending(path: "\(id.uuidString)-manifest.json")
    }

    private func resultURL(id: UUID) -> URL {
        rootDirectory.appending(path: "CollectionBatches", directoryHint: .isDirectory)
            .appending(path: "\(id.uuidString)-result.json")
    }

    private func save<Value: Encodable>(_ value: Value, at url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        if fileManager.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else {
                throw ScenarioCollectionError.conflictingSavedObject
            }
            return
        }
        let pending = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).pending")
        defer { try? fileManager.removeItem(at: pending) }
        try data.write(to: pending, options: .atomic)
        do {
            try fileManager.moveItem(at: pending, to: url)
        } catch {
            throw ScenarioCollectionError.conflictingSavedObject
        }
    }

    private func load<Value: Decodable>(at url: URL) throws -> Value? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(Value.self, from: Data(contentsOf: url))
        } catch {
            throw ScenarioCollectionError.invalidSavedObject
        }
    }

    private func jsonFiles(in root: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
