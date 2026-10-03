import Foundation

public struct ProductionBaselineApproval: Codable, Sendable {
    public var id: UUID
    public var jobID: UUID
    public var jobRevision: String
    public var evidenceRevision: String
    public var approvedAt: Date
    public var note: String
}

extension ProductionStorage {
    // Caller holds the store transaction. Approval history is retained with exported job evidence.
    func readBaselineApproval(_ job: ProductionJob) throws -> ProductionBaselineApproval? {
        let file = jobDirectory(job.id).appendingPathComponent("baseline-approvals.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard try ProductionCodec.fileSize(file) <= 8_000_000 else {
            throw ProductionFailure.integrity("Baseline approval history exceeds its bound.")
        }
        var last: ProductionBaselineApproval?, count = 0
        try ProductionLineReader.forEach(file) { bytes in
            let value = try ProductionCodec.decode(ProductionBaselineApproval.self, bytes)
            count += 1
            guard count <= 1_000, value.jobID == job.id, value.jobRevision == job.revision,
                  !value.note.isEmpty, value.note.utf8.count <= 4_000 else {
                throw ProductionFailure.integrity("Baseline approval does not match this frozen job.")
            }
            try ProductionCodec.validateDigest(value.evidenceRevision)
            last = value
        }
        return last
    }
    public func approveBaseline(jobID: UUID, expectedJobRevision: String,
                                expectedEvidenceRevision: String, note: String) throws -> ProductionBaselineApproval {
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.utf8.count <= 4_000 else {
            throw ProductionFailure.invalid("Baseline approval needs a review note of at most 4,000 bytes.")
        }
        return try transaction {
            let report = try makeReport(jobID: jobID, includeBaseline: false)
            guard report.job.revision == expectedJobRevision, report.evidenceRevision == expectedEvidenceRevision,
                  report.phase == "completed", report.baselineEligible == true else {
                throw ProductionFailure.invalid("Only complete, eligible, unchanged evidence can be approved as a baseline.")
            }
            let approval = ProductionBaselineApproval(id: UUID(), jobID: jobID, jobRevision: expectedJobRevision,
                evidenceRevision: expectedEvidenceRevision, approvedAt: Date(), note: note)
            let file = jobDirectory(jobID).appendingPathComponent("baseline-approvals.jsonl")
            if FileManager.default.fileExists(atPath: file.path) {
                var count = 0
                try ProductionLineReader.forEach(file) { _ in count += 1 }
                guard count < 1_000 else { throw ProductionFailure.invalid("Baseline approval history is full; export it before continuing.") }
            } else { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd()
            var bytes = try ProductionCodec.encode(approval); bytes.append(10)
            try handle.write(contentsOf: bytes); try handle.synchronize()
            return approval
        }
    }
}
