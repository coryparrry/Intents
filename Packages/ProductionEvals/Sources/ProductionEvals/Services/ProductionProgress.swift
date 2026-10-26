import Foundation

/// Persisted slot counts for polling, without scores, qualification or evidence hashes.
/// Use report(jobID:) for a fully validated result and release-gate decision.
public struct ProductionProgress: Codable, Sendable {
    public let completed: Int
    public let planned: Int
    public let phase: String
}

private struct ProgressRecord: Decodable { let slot: Int }
private struct ProgressChunk: Decodable {
    let index: Int
    let records: [Int: ProgressRecord]
    let lease: ProductionLease?
}

extension ProductionStorage {
    /// Reads bounded persisted slot counts under the storage transaction without scoring or qualifying evidence.
    /// Throws for malformed slot identities; cancellation and pause take precedence over completion.
    public func progress(jobID: UUID) throws -> ProductionProgress {
        try transaction {
            let job = try loadJob(jobID), control = try control(job)
            var completed = 0, activeLease = false
            for index in 0..<chunkCount(job) {
                let url = chunkURL(job, index)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let chunk = try ProductionCodec.read(ProgressChunk.self, from: url, maximumBytes: ProductionStorageLimits.encodedChunkBytes)
                let range = slots(job, chunk: index)
                guard chunk.index == index, chunk.records.count <= range.count,
                      chunk.records.allSatisfy({ range.contains($0.key) && $0.key == $0.value.slot }) else {
                    throw ProductionFailure.integrity("Progress contains invalid result slots.")
                }
                completed += chunk.records.count
                activeLease = activeLease || (chunk.lease.map { $0.expiresAt > Date() } ?? false)
            }
            let phase = control.cancelled ? "cancelled" : control.paused ? "paused"
                : completed == job.plannedCount ? "completed" : activeLease ? "running" : "pending"
            return ProductionProgress(completed: completed, planned: job.plannedCount, phase: phase)
        }
    }
}
