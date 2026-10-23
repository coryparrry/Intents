import Foundation
import Testing
@testable import ProductionEvals

private final class ApprovalBoundsFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("production-approval-\(UUID())")
    let storage: ProductionStorage
    let job: ProductionJob
    let worker = ProductionWorker(id: "approval", name: "Approval", platform: "macOS", operatingSystem: "26",
                                  hardware: "fixture", locale: "en_GB", model: "fixture")

    init() throws {
        storage = try ProductionStorage(root: directory.appendingPathComponent("store"))
        let input = directory.appendingPathComponent("input.jsonl")
        var data = try ProductionCodec.encode(ProductionExample(id: "a", prompt: "input")); data.append(10)
        try data.write(to: input)
        let dataset = try storage.importDataset(from: input, name: "Approval", version: "1", sampling: .random)
        let context = Data("fixture".utf8)
        let config = ProductionJobConfiguration(scoringRevision: ProductionCodec.digest(context),
            executionRevision: ProductionCodec.digest(context), executionContext: context)
        job = try storage.createJob(name: "Approval", datasetRevision: dataset.revision, configuration: config)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
    var history: URL { storage.jobDirectory(job.id).appendingPathComponent("baseline-approvals.jsonl") }

    func completeAndApprove(note: String) async throws -> ProductionBaselineApproval {
        _ = try await ProductionBatchRunner(storage: storage).run(jobID: job.id, worker: worker) {
            .init(requestID: $0.requestID, outcome: .passed, cost: 0)
        }
        let report = try storage.report(jobID: job.id)
        return try storage.approveBaseline(jobID: job.id, expectedJobRevision: job.revision,
            expectedEvidenceRevision: #require(report.evidenceRevision), note: note)
    }

    func append(after approval: ProductionBaselineApproval, note: String) throws -> ProductionBaselineApproval {
        try storage.approveBaseline(jobID: job.id, expectedJobRevision: job.revision,
            expectedEvidenceRevision: approval.evidenceRevision, note: note)
    }

    // Seed a valid, readable prefix at an exact byte boundary without performing
    // hundreds of redundant approval operations. IDs remain distinct, and every
    // note stays under the public 4,000-byte UTF-8 limit.
    func seedHistory(_ approval: ProductionBaselineApproval, bytes: Int) throws {
        let count = 500
        var empty = approval; empty.note = ""
        let overhead = try ProductionCodec.encode(empty).count + 1
        var data = Data()
        for index in 0..<count {
            let target = bytes / count + (index < bytes % count ? 1 : 0)
            let payload = target - overhead
            var row = approval; row.id = UUID()
            row.note = String(repeating: "\u{0001}", count: payload / 6) + String(repeating: "x", count: payload % 6)
            #expect(!row.note.isEmpty && row.note.utf8.count <= 4_000)
            var encoded = try ProductionCodec.encode(row); encoded.append(10)
            #expect(encoded.count == target)
            data.append(encoded)
        }
        #expect(data.count == bytes)
        try data.write(to: history)
    }
}

@Suite(.serialized) struct ProductionBaselineApprovalBoundsTests {
    @Test(arguments: [false, true])
    func escapedAppendRespectsExactHistoryByteLimit(exceedsByOne: Bool) async throws {
        let fixture = try ApprovalBoundsFixture(), note = String(repeating: "\u{0001}", count: 4_000)
        let first = try await fixture.completeAndApprove(note: note)
        let appendBytes = try ProductionCodec.encode(first).count + 1
        #expect(appendBytes > 24_000)
        try fixture.seedHistory(first, bytes: 8_000_000 - appendBytes + (exceedsByOne ? 1 : 0))
        let before = try Data(contentsOf: fixture.history), digest = ProductionCodec.digest(before)
        let beforeReport = try fixture.storage.report(jobID: fixture.job.id)
        let previous = try #require(beforeReport.baselineApproval)

        if exceedsByOne {
            #expect(throws: ProductionFailure.self) { try fixture.append(after: first, note: note) }
            let after = try Data(contentsOf: fixture.history)
            #expect(after == before && ProductionCodec.digest(after) == digest)
            #expect(try fixture.storage.report(jobID: fixture.job.id).baselineApproval?.id == previous.id)
        } else {
            let approval = try fixture.append(after: first, note: note)
            #expect(try ProductionCodec.fileSize(fixture.history) == 8_000_000)
            #expect(try fixture.storage.report(jobID: fixture.job.id).baselineApproval?.id == approval.id)
        }
        let export = fixture.directory.appendingPathComponent("export")
        try fixture.storage.exportJob(fixture.job.id, to: export)
        let exported = try Data(contentsOf: export.appendingPathComponent("Job/baseline-approvals.jsonl"))
        let retained = try Data(contentsOf: fixture.history)
        #expect(exported == retained)
        #expect(try fixture.storage.report(jobID: fixture.job.id).baselineEligible == true)
    }

    @Test func ordinaryApprovalAndExistingNoteLimitRemainIntact() async throws {
        let fixture = try ApprovalBoundsFixture()
        let first = try await fixture.completeAndApprove(note: "Initial review")
        let second = try fixture.append(after: first, note: "Reviewed again")
        #expect(try fixture.storage.report(jobID: fixture.job.id).baselineApproval?.id == second.id)
        let before = try Data(contentsOf: fixture.history)
        for note in ["   ", String(repeating: "x", count: 4_001)] {
            #expect(throws: ProductionFailure.self) { try fixture.append(after: second, note: note) }
            #expect(try Data(contentsOf: fixture.history) == before)
        }
    }

    @Test func existingApprovalCountLimitStillPreservesHistory() async throws {
        let fixture = try ApprovalBoundsFixture()
        let first = try await fixture.completeAndApprove(note: "Reviewed")
        var history = Data()
        for _ in 0..<1_000 {
            var row = first; row.id = UUID()
            history.append(try ProductionCodec.encode(row)); history.append(10)
        }
        try history.write(to: fixture.history)
        #expect(try fixture.storage.report(jobID: fixture.job.id).baselineEligible == true)
        #expect(throws: ProductionFailure.self) { try fixture.append(after: first, note: "Reviewed again") }
        #expect(try Data(contentsOf: fixture.history) == history)
        #expect(try fixture.storage.report(jobID: fixture.job.id).baselineEligible == true)
    }
}
