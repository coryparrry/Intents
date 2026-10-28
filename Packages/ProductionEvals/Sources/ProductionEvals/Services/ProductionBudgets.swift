import Foundation

extension ProductionStorage {
    // Caller holds the store lock. Reconciled totals settle only the outstanding unknown attempts.
    /// Reconstructs settled costs from attempt checkpoints and reconciled review responses for outstanding reservations.
    /// The caller holds the store lock; the returned control value is not persisted by this read.
    /// Throws if retained charges cannot be represented as a finite nonnegative total.
    func auditedCostControl(_ job: ProductionJob) throws -> ProductionControl {
        var value = try control(job)
        guard value.reportedCost.isFinite, value.reportedCost >= 0 else { throw ProductionFailure.integrity("Stored cost total is invalid.") }
        for (key,_) in value.costReservations {
            guard let slot = value.costReservationSlots?[key], (0..<job.plannedCount).contains(slot),
                  let number = Int(key.split(separator: "/").last ?? "") else { continue }
            let attempt = try chunk(job, index: slot / job.configuration.chunkSize).attempts[slot]
            if attempt?.pendingCostAttempt == number, let cost = attempt?.pendingCost {
                value.reportedCost = try Self.addCost(value.reportedCost, cost)
                value.costReservations.removeValue(forKey: key); value.costReservationSlots?.removeValue(forKey: key)
            }
        }
        let requestIDs = Set(value.costReservations.keys.compactMap { UUID(uuidString: String($0.split(separator: "/")[0])) })
        for id in requestIDs {
            if let cost = try readReview(jobID: job.id, requestID: id).response?.cost {
                value.reportedCost = try Self.addCost(value.reportedCost, cost)
                value.costReservations = value.costReservations.filter { !$0.key.hasPrefix("\(id)/") }
                value.costReservationSlots = value.costReservationSlots?.filter { !$0.key.hasPrefix("\(id)/") }
            }
        }
        return value
    }
    /// Adds known charges without allowing a nonfinite ledger value to reach persistent storage or report hashing.
    private static func addCost(_ total: Double, _ amount: Double) throws -> Double {
        let subtotal = total + amount
        guard amount.isFinite, amount >= 0, subtotal.isFinite else {
            throw ProductionFailure.integrity("Cost evidence total exceeds the supported numeric range.")
        }
        return subtotal
    }
    /// Reserves the configured per-attempt allowance before execution when the job has a cost ceiling.
    /// An existing reservation is retained; admission fails when the ceiling or unknown-cost reservation limit is reached.
    func reserveCost(_ job: ProductionJob, requestID: UUID, slot: Int, attempt: Int) throws {
        guard let ceiling = job.configuration.maximumCost, let allowance = job.configuration.maximumCostPerAttempt else { return }
        try transaction {
            var value = try auditedCostControl(job); let key = "\(requestID)/\(attempt)"
            if value.costReservations[key] != nil { return }
            guard value.costReservations.count < 1_000 else { throw ProductionFailure.budget("Reconcile unknown cost evidence before admitting more attempts.") }
            guard value.reportedCost + value.costReservations.values.reduce(0,+) + allowance <= ceiling else {
                throw ProductionFailure.budget("Cost budget cannot admit another attempt. Existing evidence and uncertain cost reservations were retained.")
            }
            value.costReservations[key] = allowance
            if value.costReservationSlots == nil { value.costReservationSlots = [:] }
            value.costReservationSlots?[key] = slot
            try ProductionCodec.write(value, to: jobDirectory(job.id).appendingPathComponent("control.json"))
        }
    }
    // The attempt journal is published before settlement. Recovery consumes it exactly once via the reservation key.
    /// Publishes attempt cost evidence before settling matching reservations, then clears the checkpoint after ledger persistence.
    /// Requires an unexpired matching chunk lease and attempt number so recovery cannot settle foreign work.
    /// Rejects invalid numeric checkpoints before changing their retained attempt evidence.
    func checkpointCost(_ job: ProductionJob, index: Int, token: UUID, slot: Int, attempt: Int,
                        cost: Double?, accumulatedCost: Double, unknown: Bool) throws {
        guard accumulatedCost.isFinite, accumulatedCost >= 0,
              cost == nil || (cost!.isFinite && cost! >= 0) else { throw ProductionFailure.invalid("Attempt cost checkpoint is invalid.") }
        try transaction {
            var chunk = try chunk(job, index: index)
            guard chunk.lease?.token == token, let expiry = chunk.lease?.expiresAt, expiry > Date(),
                  chunk.attempts[slot]?.number == attempt else { throw ProductionFailure.staleLease }
            chunk.attempts[slot]?.reportedCost = accumulatedCost; chunk.attempts[slot]?.hasUnknownCost = unknown
            chunk.attempts[slot]?.pendingCost = cost; chunk.attempts[slot]?.pendingCostAttempt = attempt
            try writeChunk(chunk, job: job, index: index)
            if job.configuration.maximumCost != nil {
                let value = try auditedCostControl(job)
                try ProductionCodec.write(value, to: jobDirectory(job.id).appendingPathComponent("control.json"))
            }
            chunk.attempts[slot]?.pendingCost = nil; chunk.attempts[slot]?.pendingCostAttempt = nil
            try writeChunk(chunk, job: job, index: index)
        }
    }
}
