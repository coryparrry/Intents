import Foundation

/// The verified imported dataset and whether this operation atomically published its immutable revision.
public struct ProductionDatasetImportResult: Sendable {
    public let dataset: ProductionDataset
    public let didPublish: Bool
}

extension ProductionStorage {
    /// Validates JSONL examples and publishes immutable example bytes, offsets, and a content-addressed manifest.
    /// Duplicate example IDs, sources crossing partitions, oversized data, and unconfirmed production data are rejected.
    /// - Parameters:
    ///   - productionData: Whether the source requires explicit redaction confirmation.
    ///   - redactionConfirmed: Caller confirmation required when `productionData` is true.
    /// - Returns: The published dataset, or a compatible existing revision whose retained bytes are verified for an identical import.
    /// - Throws: Validation, decoding, integrity, or file-system errors before publication completes.
    public func importDataset(from file: URL, name: String, version: String, sampling: ProductionSampling = .curated,
                              productionData: Bool = false, redactionConfirmed: Bool = false) throws -> ProductionDataset {
        try importDatasetWithOutcome(from: file, name: name, version: version, sampling: sampling,
                                     productionData: productionData, redactionConfirmed: redactionConfirmed).dataset
    }

    /// Imports with the same validation and idempotency as `importDataset`, additionally reporting durable publication.
    /// The existing-revision decision and new-revision publication share the storage transaction, including legacy identity reuse.
    /// - Returns: The verified dataset and `didPublish` false when this operation reused an existing immutable revision.
    /// - Throws: Validation, decoding, integrity, or file-system errors before publication completes.
    public func importDatasetWithOutcome(from file: URL, name: String, version: String, sampling: ProductionSampling = .curated,
                                         productionData: Bool = false, redactionConfirmed: Bool = false) throws -> ProductionDatasetImportResult {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
              !version.isEmpty, version.count <= 100,
              !name.utf8.contains(where: { $0 == 13 || $0 == 10 }),
              !version.utf8.contains(where: { $0 == 13 || $0 == 10 }),
              !productionData || redactionConfirmed else {
            throw ProductionFailure.invalid("Provide a dataset name/version and confirm redaction for production data.")
        }
        let directory = root.appendingPathComponent("Datasets/.import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dataURL = directory.appendingPathComponent("examples.jsonl"), indexURL = directory.appendingPathComponent("offsets.bin")
        FileManager.default.createFile(atPath: dataURL.path, contents: nil)
        FileManager.default.createFile(atPath: indexURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: dataURL), index = try FileHandle(forWritingTo: indexURL)
        defer { try? output.close(); try? index.close() }
        var identifiers = Set<String>(), sourcePartitions: [String: ProductionPartition] = [:]
        var partitions: [String: Int] = [:], count = 0, offset: UInt64 = 0
        try ProductionLineReader.forEach(file) { line in
            let example = try ProductionCodec.decode(ProductionExample.self, line)
            try Self.validate(example)
            guard identifiers.insert(example.id).inserted else { throw ProductionFailure.invalid("Duplicate example ID: \(example.id)") }
            if let partition = sourcePartitions[example.sourceID], partition != example.partition {
                throw ProductionFailure.invalid("One source cannot cross development and held-out partitions.")
            }
            sourcePartitions[example.sourceID] = example.partition
            count += 1; guard count <= 1_000_000 else { throw ProductionFailure.invalid("Dataset exceeds one million examples.") }
            partitions[example.partition.rawValue, default: 0] += 1
            var encodedOffset = offset.bigEndian
            try index.write(contentsOf: withUnsafeBytes(of: &encodedOffset) { Data($0) })
            var encoded = try ProductionCodec.encode(example)
            guard encoded.count <= ProductionStorageLimits.encodedExampleBytes else { throw ProductionFailure.invalid("Encoded example exceeds 256 KB.") }
            encoded.append(10)
            try output.write(contentsOf: encoded); offset += UInt64(encoded.count)
            guard offset <= 1_000_000_000 else { throw ProductionFailure.invalid("Dataset exceeds the one GB storage limit.") }
        }
        guard count > 0 else { throw ProductionFailure.invalid("Dataset has no examples.") }
        try output.synchronize(); try index.synchronize()
        let dataDigest = try ProductionCodec.fileDigest(dataURL), indexDigest = try ProductionCodec.fileDigest(indexURL)
        var dataset = ProductionDataset(name: name, version: version, revision: "", count: count, createdAt: Date(),
                                        sampling: sampling, productionData: productionData, dataDigest: dataDigest,
                                        indexDigest: indexDigest, partitionCounts: partitions)
        let revisions = try Self.datasetRevisions(dataset)
        dataset.revision = revisions.current
        try ProductionCodec.write(dataset, to: directory.appendingPathComponent("manifest.json"), maximumBytes: 100_000)
        return try transaction {
            let destination = try datasetDirectory(dataset.revision)
            if FileManager.default.fileExists(atPath: destination.path) {
                return .init(dataset: try loadDataset(dataset.revision, verifyFiles: true), didPublish: false)
            }
            // Preserve existing references and import idempotency, but never reuse a
            // legacy newline-delimited hash for different name/version boundaries.
            if FileManager.default.fileExists(atPath: try datasetDirectory(revisions.legacy).path) {
                let existing = try loadDataset(revisions.legacy, verifyFiles: true)
                if try Self.datasetRevisions(existing).current == revisions.current {
                    return .init(dataset: existing, didPublish: false)
                }
            }
            try FileManager.default.moveItem(at: directory, to: destination)
            return .init(dataset: dataset, didPublish: true)
        }
    }
    /// Loads published dataset manifests in descending creation order, excluding staging directories.
    /// - Throws: File-system errors or invalid dataset identity/index evidence.
    public func datasets() throws -> [ProductionDataset] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Datasets"), includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }.map { try loadDataset($0.lastPathComponent) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    /// Loads a manifest and checks its revision, example count, partition totals, and index length.
    /// - Parameter verifyFiles: Also rehashes example and offset bytes when true.
    /// - Throws: Integrity errors for changed identity or bytes, plus decoding and file errors.
    public func loadDataset(_ revision: String, verifyFiles: Bool = false) throws -> ProductionDataset {
        let folder = try datasetDirectory(revision)
        let value = try ProductionCodec.read(ProductionDataset.self, from: folder.appendingPathComponent("manifest.json"), maximumBytes: 100_000)
        let revisions = try Self.datasetRevisions(value)
        guard value.revision == revision, revision == revisions.current || revision == revisions.legacy,
              (1...1_000_000).contains(value.count), value.partitionCounts.values.reduce(0,+) == value.count,
              (try folder.appendingPathComponent("offsets.bin").resourceValues(forKeys: [.fileSizeKey])).fileSize == value.count * 8 else {
            throw ProductionFailure.integrity("Dataset manifest/index integrity failed.")
        }
        if verifyFiles {
            guard try ProductionCodec.fileDigest(folder.appendingPathComponent("examples.jsonl")) == value.dataDigest,
                  try ProductionCodec.fileDigest(folder.appendingPathComponent("offsets.bin")) == value.indexDigest else {
                throw ProductionFailure.integrity("Dataset bytes changed after publication.")
            }
        }
        return value
    }
    /// Computes the current dataset identity from an encoded field array and the legacy newline-delimited identity for compatibility.
    private static func datasetRevisions(_ value: ProductionDataset) throws -> (current: String, legacy: String) {
        let fields = [value.name, value.version, value.sampling.rawValue, String(value.productionData),
                      value.dataDigest, value.indexDigest, String(value.count),
                      try ProductionCodec.digest(ProductionCodec.encode(value.partitionCounts))]
        return (try ProductionCodec.digest(ProductionCodec.encode(["production-dataset-v2"] + fields)),
                ProductionCodec.digest(Data(fields.joined(separator: "\n").utf8)))
    }
    /// Rejects examples with missing identifiers or prompt, or fields that exceed the persisted record bounds.
    static func validate(_ example: ProductionExample) throws {
        guard !example.id.isEmpty, example.id.utf8.count <= 200, !example.sourceID.isEmpty, example.sourceID.utf8.count <= 200,
              !example.prompt.isEmpty, example.prompt.utf8.count <= 64_000, (example.expected?.utf8.count ?? 0) <= 64_000,
              (example.capturedOutput?.utf8.count ?? 0) <= 64_000, (example.feedback?.utf8.count ?? 0) <= 4_000,
              (example.input?.count ?? 0) <= 64_000, example.metadata.count <= 12,
              example.metadata.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 80 && $0.value.count <= 200 }) else {
            throw ProductionFailure.invalid("An example has missing input or oversized fields.")
        }
    }
}

public final class ProductionDatasetReader {
    private let data: FileHandle
    private let index: FileHandle
    public let dataset: ProductionDataset
    /// Opens indexed example data after verifying the published dataset and both file digests.
    /// - Throws: Dataset integrity, decoding, or file-opening errors.
    public init(storage: ProductionStorage, revision: String) throws {
        dataset = try storage.loadDataset(revision, verifyFiles: true)
        let folder = try storage.datasetDirectory(revision)
        data = try FileHandle(forReadingFrom: folder.appendingPathComponent("examples.jsonl"))
        index = try FileHandle(forReadingFrom: folder.appendingPathComponent("offsets.bin"))
    }
    /// Closes both example and offset handles when the reader is released.
    deinit { try? data.close(); try? index.close() }
    /// Reads and validates the example at a zero-based position using its eight-byte offset entry.
    /// - Throws: An invalid-position error or an integrity error for missing or oversized indexed data, plus I/O and decoding errors.
    public func example(at position: Int) throws -> ProductionExample {
        guard (0..<dataset.count).contains(position) else { throw ProductionFailure.invalid("Example index is out of range.") }
        try index.seek(toOffset: UInt64(position * 8))
        guard let bytes = try index.read(upToCount: 8), bytes.count == 8 else { throw ProductionFailure.integrity("Missing dataset index entry.") }
        let offset = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        try data.seek(toOffset: offset)
        var line = Data()
        while let next = try data.read(upToCount: 4_096), !next.isEmpty {
            if let newline = next.firstIndex(of: 10) { line.append(next.prefix(upTo: newline)); break }
            line.append(next)
            guard line.count <= ProductionStorageLimits.encodedExampleBytes else { throw ProductionFailure.integrity("Oversized indexed record.") }
        }
        guard !line.isEmpty, line.count <= ProductionStorageLimits.encodedExampleBytes else { throw ProductionFailure.integrity("Missing/oversized indexed record.") }
        let value = try ProductionCodec.decode(ProductionExample.self, line); try ProductionStorage.validate(value); return value
    }
}

enum ProductionLineReader {
    /// Streams JSONL data one bounded record at a time to `consume`.
    /// Propagates file errors, record-size errors, and errors thrown by the consumer.
    static func forEach(_ url: URL, maximumLineBytes: Int = 262_144, consume: (Data) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var pending = Data()
        while let data = try input.read(upToCount: 65_536), !data.isEmpty {
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending.prefix(upTo: newline)); pending.removeSubrange(...newline)
                guard line.count <= maximumLineBytes else { throw ProductionFailure.invalid("JSONL record exceeds its byte limit.") }
                if !line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { try consume(line) }
            }
            guard pending.count <= maximumLineBytes else { throw ProductionFailure.invalid("JSONL record exceeds its byte limit.") }
        }
        if !pending.isEmpty { try consume(pending) }
    }
}
