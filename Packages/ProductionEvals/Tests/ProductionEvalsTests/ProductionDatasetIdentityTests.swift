import Foundation
import Testing
@testable import ProductionEvals

struct ProductionDatasetIdentityTests {
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
