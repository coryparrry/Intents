import Foundation
import Testing
@testable import ProductionEvals

struct ProductionDatasetIdentityTests {
    /// Publication evidence reports the transaction's actual mutation, including reuse of a compatible legacy dataset.
    @Test(arguments: [false, true])
    func importOutcomeDistinguishesPublicationFromIdempotentReuse(legacy: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("production-import-outcome-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try ProductionStorage(root: root)
        let source = root.appendingPathComponent("source.jsonl")
        var bytes = try ProductionCodec.encode(ProductionExample(id: "saved", prompt: "Input"))
        bytes.append(10)
        try bytes.write(to: source)
        let first = try storage.importDatasetWithOutcome(from: source, name: "Fixture", version: "1")
        #expect(first.didPublish)
        var expected = try storage.loadDataset(first.dataset.revision, verifyFiles: true)
        if legacy {
            let currentFolder = try storage.datasetDirectory(expected.revision)
            let fields = [expected.name, expected.version, expected.sampling.rawValue, String(expected.productionData),
                          expected.dataDigest, expected.indexDigest, String(expected.count),
                          try ProductionCodec.digest(ProductionCodec.encode(expected.partitionCounts))]
            expected.revision = ProductionCodec.digest(Data(fields.joined(separator: "\n").utf8))
            try ProductionCodec.write(expected, to: currentFolder.appendingPathComponent("manifest.json"))
            try FileManager.default.moveItem(at: currentFolder, to: storage.datasetDirectory(expected.revision))
        }
        let duplicate = try storage.importDatasetWithOutcome(from: source, name: "Fixture", version: "1")
        #expect(!duplicate.didPublish)
        #expect(duplicate.dataset.revision == expected.revision)
        #expect(duplicate.dataset.createdAt == expected.createdAt)
        #expect(try storage.datasets().count == 1)
        #expect(try storage.importDataset(from: source, name: "Fixture", version: "1").revision == expected.revision)
    }

    /// Rejects metadata separators that alias legacy identities while preserving identical valid imports.
    @Test func recordSeparatorsCannotAliasDatasetMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("production-dataset-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try ProductionStorage(root: root)
        let source = root.appendingPathComponent("source.jsonl")
        var bytes = try ProductionCodec.encode(ProductionExample(id: "saved", prompt: "Input"))
        bytes.append(10)
        try bytes.write(to: source)

        // Newlines shift the boundary between name/version in the frozen legacy identity.
        for (name, version) in [("Alpha\nBeta", "1"), ("Alpha", "Beta\n1"),
                                ("Alpha\rBeta", "1"), ("Alpha", "Beta\r1"),
                                ("Alpha\r\nBeta", "1"), ("Alpha", "Beta\r\n1")] {
            #expect(throws: ProductionFailure.self) {
                try storage.importDataset(from: source, name: name, version: version)
            }
        }
        #expect(try storage.datasets().isEmpty)

        let original = try storage.importDataset(from: source, name: "Alpha Beta", version: "1")
        let duplicate = try storage.importDataset(from: source, name: "Alpha Beta", version: "1")
        #expect(duplicate.revision == original.revision)
        #expect(duplicate.name == "Alpha Beta" && duplicate.version == "1")
        #expect(try storage.datasets().count == 1)
        #expect(try storage.loadDataset(original.revision, verifyFiles: true).revision == original.revision)
    }
}
