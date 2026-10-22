import Foundation
import Testing
@testable import ProductionEvals

@Suite(.serialized)
struct ProductionStorageLimitTests {
    @Test func escapedFullPayloadChunkRemainsReadableAndRejectedReplacementPreservesIt() async throws {
        let fixture = try StorageLimitFixture()
        let job = try fixture.job()
        let storage = fixture.storage
        _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id,
            worker: fixture.worker, maximumResponses: 1) { request in
            .init(requestID: request.requestID, outcome: .passed,
                  output: String(repeating: "\0", count: 64_000),
                  explanation: String(repeating: "\0", count: 8_000),
                  cost: 0, artifact: Data(repeating: 1, count: 262_144))
        }
        let first = try storage.record(jobID: job.id, slot: 0)
        let claim = try #require(try storage.claim(job, worker: fixture.worker))
        let token = try #require(claim.lease?.token)
        // One real execution supplies the evidence shape. Populate the remaining
        // valid slots once to avoid rewriting a growing 80 MB chunk 100 times.
        try storage.updateChunk(job, index: 0, token: token) { chunk in
            for slot in 1..<job.plannedCount {
                var record = first
                record.slot = slot
                record.response.requestID = storage.requestID(job, slot: slot)
                record.targetIndex = storage.targetIndex(job, slot: slot)
                record.repetition = (slot / job.configuration.targets.count) % job.configuration.repetitions + 1
                chunk.records[slot] = record
            }
        }
        let url = storage.chunkURL(job, 0)
        #expect(try ProductionCodec.fileSize(url) > 50_000_000)
        #expect(try storage.chunk(job, index: 0).records.count == 100)
        let before = try ProductionCodec.fileDigest(url)
        #expect(throws: ProductionFailure.self) {
            try storage.updateChunk(job, index: 0, token: token) { chunk in
                // The public mutation API must reject an oversized serialized
                // replacement before it can destroy the readable prior chunk.
                for slot in chunk.records.keys {
                    chunk.records[slot]?.worker.name = String(repeating: "\0", count: 100_000)
                }
            }
        }
        #expect(try ProductionCodec.fileDigest(url) == before)
        try storage.updateChunk(job, index: 0, token: token) { $0.lease = nil }
        let report = try storage.report(jobID: job.id)
        #expect(report.completed == 100 && report.exitCode == 0)
        #expect(try storage.record(jobID: job.id, slot: 99).response.output == first.response.output)
    }

    @Test func oversizedPersistedChunkIsRejectedBeforeDecoding() throws {
        let fixture = try StorageLimitFixture(), job = try fixture.job()
        _ = try fixture.storage.claim(job, worker: fixture.worker)
        let handle = try FileHandle(forWritingTo: fixture.storage.chunkURL(job, 0))
        // A sparse oversized file exercises the actual read bound without
        // allocating an oversized JSON document in the test process.
        try handle.truncate(atOffset: UInt64(ProductionStorageLimits.encodedChunkBytes + 1))
        try handle.close()
        #expect(throws: ProductionFailure.self) { try fixture.storage.chunk(job, index: 0) }
        #expect(throws: ProductionFailure.self) { try fixture.storage.report(jobID: job.id) }
    }

    @Test func workerByteBoundaryRoundTripsAndInvalidReplacementPreservesRegistration() throws {
        let fixture = try StorageLimitFixture()
        var worker = fixture.worker
        worker.name = "a"
        let remaining = ProductionStorageLimits.encodedWorkerBytes - (try ProductionCodec.encode(worker).count)
        // Combining characters keep the display-name length within 200 while
        // exercising the independent serialized-byte boundary exactly.
        worker.name += String(repeating: "\u{301}", count: remaining / 2)
            + (remaining % 2 == 0 ? "" : "x")
        #expect(worker.name.count <= 200)
        #expect(try ProductionCodec.encode(worker).count == ProductionStorageLimits.encodedWorkerBytes)
        try fixture.storage.register(worker)
        #expect(try fixture.storage.workers() == [worker])
        let url = fixture.storage.root.appendingPathComponent("Workers/\(ProductionCodec.digest(Data(worker.id.utf8))).json")
        let original = try Data(contentsOf: url)
        for name in [String(repeating: "x", count: 201),
                     "\0a" + String(repeating: "\u{301}", count: 10_000)] {
            var replacement = worker
            replacement.name = name
            #expect(throws: ProductionFailure.self) { try fixture.storage.register(replacement) }
            #expect(try Data(contentsOf: url) == original)
            #expect(try fixture.storage.workers() == [worker])
        }
    }
}

private final class StorageLimitFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("production-limits-\(UUID())")
    let storage: ProductionStorage
    let worker = ProductionWorker(id: "limits-fixture", name: "Fixture", platform: "macOS",
        operatingSystem: "27", hardware: "fixture", locale: "en_GB", model: "fixture",
        lastSeen: Date(timeIntervalSince1970: 0))
    init() throws { storage = try ProductionStorage(root: root) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func job() throws -> ProductionJob {
        let input = root.appendingPathComponent("input.jsonl")
        var bytes = try ProductionCodec.encode(ProductionExample(id: "one", prompt: "input"))
        bytes.append(10)
        try bytes.write(to: input)
        let dataset = try storage.importDataset(from: input, name: "Limit fixture", version: "1")
        let context = Data("fixture".utf8)
        var config = ProductionJobConfiguration(scoringRevision: ProductionCodec.digest(context),
            executionRevision: ProductionCodec.digest(context), executionContext: context)
        config.repetitions = 20
        config.targets = Array(repeating: .init(), count: 5)
        return try storage.createJob(name: "Limit fixture", datasetRevision: dataset.revision, configuration: config)
    }
}
