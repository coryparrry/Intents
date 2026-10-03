import Foundation

extension ProductionStorage {
    // Caller holds the store lock. Reconciled totals settle only the outstanding unknown attempts.
    func auditedCostControl(_ job: ProductionJob) throws -> ProductionControl {
        var value = try control(job)
        for (key,_) in value.costReservations {
            guard let slot = value.costReservationSlots?[key], (0..<job.plannedCount).contains(slot),
                  let number = Int(key.split(separator: "/").last ?? "") else { continue }
            let attempt = try chunk(job, index: slot / job.configuration.chunkSize).attempts[slot]
            if attempt?.pendingCostAttempt == number, let cost = attempt?.pendingCost {
                value.reportedCost += cost; value.costReservations.removeValue(forKey: key); value.costReservationSlots?.removeValue(forKey: key)
            }
        }
        let requestIDs = Set(value.costReservations.keys.compactMap { UUID(uuidString: String($0.split(separator: "/")[0])) })
        for id in requestIDs {
            if let cost = try readReview(jobID: job.id, requestID: id).response?.cost {
                value.reportedCost += cost
                value.costReservations = value.costReservations.filter { !$0.key.hasPrefix("\(id)/") }
                value.costReservationSlots = value.costReservationSlots?.filter { !$0.key.hasPrefix("\(id)/") }
            }
        }
        return value
    }
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
    func checkpointCost(_ job: ProductionJob, index: Int, token: UUID, slot: Int, attempt: Int,
                        cost: Double?, accumulatedCost: Double, unknown: Bool) throws {
        try transaction {
            var chunk = try chunk(job, index: index)
            guard chunk.lease?.token == token, let expiry = chunk.lease?.expiresAt, expiry > Date(),
                  chunk.attempts[slot]?.number == attempt else { throw ProductionFailure.staleLease }
            chunk.attempts[slot]?.reportedCost = accumulatedCost; chunk.attempts[slot]?.hasUnknownCost = unknown
            chunk.attempts[slot]?.pendingCost = cost; chunk.attempts[slot]?.pendingCostAttempt = attempt
            try ProductionCodec.write(chunk, to: chunkURL(job, index))
            if job.configuration.maximumCost != nil {
                let value = try auditedCostControl(job)
                try ProductionCodec.write(value, to: jobDirectory(job.id).appendingPathComponent("control.json"))
            }
            chunk.attempts[slot]?.pendingCost = nil; chunk.attempts[slot]?.pendingCostAttempt = nil
            try ProductionCodec.write(chunk, to: chunkURL(job, index))
        }
    }
}
