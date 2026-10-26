import Foundation

extension ProductionStorage {
    // Frozen jobs and clones already contain source IDs; never reinterpret them as case/example IDs.
    /// Checks that all already-frozen critical source IDs occur in the dataset without reinterpreting them as case IDs.
    func validateCriticalSources(_ sources: [String], reader: ProductionDatasetReader) throws {
        guard !sources.isEmpty else { return }
        var missing = Set(sources)
        for position in 0..<reader.dataset.count { missing.remove(try reader.example(at: position).sourceID) }
        guard missing.isEmpty else { throw ProductionFailure.invalid("Dataset has unmapped critical sources: \(missing.sorted().joined(separator: ", ")). Configure source IDs, or map suite cases through example IDs or metadata.suiteCaseID.") }
    }
    /// Native case IDs resolve to exact example IDs or an explicit suiteCaseID metadata link.
    /// Existing source IDs remain accepted for an explicitly configured production policy.
    /// - Returns: Unique sorted source IDs corresponding to all requested identifiers.
    /// - Throws: An invalid-mapping error for missing identifiers, or dataset validation/read errors.
    public func resolveCriticalSources(_ identifiers: [String], datasetRevision: String) throws -> [String] {
        guard !identifiers.isEmpty else { return [] }
        let reader = try ProductionDatasetReader(storage: self, revision: datasetRevision)
        return try resolveCriticalSources(identifiers, reader: reader)
    }
    /// Matches identifiers against example ID, source ID, and `suiteCaseID` metadata, returning unique sorted source IDs.
    /// Throws when any required identifier has no dataset link.
    func resolveCriticalSources(_ identifiers: [String], reader: ProductionDatasetReader) throws -> [String] {
        guard !identifiers.isEmpty else { return [] }
        let required = Set(identifiers)
        var matched = Set<String>(), sources = Set<String>()
        for position in 0..<reader.dataset.count {
            let example = try reader.example(at: position)
            let links = Set([example.id, example.sourceID, example.metadata["suiteCaseID"]].compactMap { $0 })
            let matches = required.intersection(links)
            if !matches.isEmpty { matched.formUnion(matches); sources.insert(example.sourceID) }
        }
        let missing = required.subtracting(matched)
        guard missing.isEmpty else {
            throw ProductionFailure.invalid("Dataset has unmapped critical cases: \(missing.sorted().joined(separator: ", ")). Match example/source IDs or set metadata.suiteCaseID to the suite case UUID before creating this job.")
        }
        return sources.sorted()
    }
}
