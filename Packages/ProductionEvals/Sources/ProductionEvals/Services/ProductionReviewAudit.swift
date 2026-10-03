import Foundation

extension ProductionStorage {
    func reviewURL(jobID: UUID, requestID: UUID) -> URL {
        root.appendingPathComponent("Reviews/\(jobID.uuidString)-\(requestID.uuidString).jsonl")
    }
    public func review(jobID: UUID, requestID: UUID) throws -> ProductionReviewResolution {
        try transaction { try readReview(jobID: jobID, requestID: requestID) }
    }
    func readReview(jobID: UUID, requestID: UUID) throws -> ProductionReviewResolution {
        let url = reviewURL(jobID: jobID, requestID: requestID)
        var events: [ProductionReviewEvent] = []
        if FileManager.default.fileExists(atPath: url.path) {
            try ProductionLineReader.forEach(url) { events.append(try ProductionCodec.decode(ProductionReviewEvent.self, $0)) }
        }
        guard events.count <= 10_000, events.allSatisfy({ $0.requestID == requestID }) else {
            throw ProductionFailure.integrity("Invalid review audit history.")
        }
        let assignee = events.last { $0.action == .assign }?.assignee
        let adjudicatedIndex = events.lastIndex { $0.action == .adjudicate || $0.action == .reconcile }
        let adjudicated = adjudicatedIndex.map { events[$0] }
        let subsequent = events.dropFirst(adjudicatedIndex.map { $0 + 1 } ?? 0).filter { $0.action == .label }
        var latest: [String: ProductionReviewEvent] = [:]
        for item in subsequent { latest[item.reviewer] = item }
        let outcomes = Set(latest.values.compactMap { $0.outcome?.rawValue })
        let conflict = outcomes.count > 1
        let outcome = conflict ? ProductionOutcome.needsEvidence : latest.values.first?.outcome ?? adjudicated?.outcome
        return .init(assignee: assignee, outcome: outcome, disagreement: conflict,
                     response: events.last { $0.action == .reconcile }?.reconciledResponse, events: events)
    }
    public func appendReview(jobID: UUID, slot: Int, event: ProductionReviewEvent) throws {
        try transaction {
            let job = try loadJob(jobID), value = try chunk(job, index: slot / job.configuration.chunkSize)
            guard let record = value.records[slot], event.requestID == record.response.requestID,
                  !event.reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, event.reviewer.count <= 100,
                  !event.note.isEmpty, event.note.utf8.count <= 8_000, event.tags.count <= 6,
                  event.tags.allSatisfy({ !$0.isEmpty && $0.count <= 80 }) else {
                throw ProductionFailure.invalid("Review needs an existing result, reviewer, explanation and bounded tags.")
            }
            let current = try readReview(jobID: jobID, requestID: event.requestID)
            if event.action == .assign {
                guard let assignee = event.assignee, !assignee.isEmpty, assignee.count <= 100 else {
                    throw ProductionFailure.invalid("Assignment needs a reviewer name.")
                }
            } else if event.action == .reconcile {
                guard current.assignee == event.reviewer, record.response.outcome == .needsEvidence, current.response == nil,
                      let response = event.reconciledResponse, ![.needsEvidence, .error, .unscored].contains(response.outcome) else {
                    throw ProductionFailure.invalid("Only the assigned reviewer can reconcile an uncertain action with verified pass/fail evidence.")
                }
                try validateResponse(response, requestID: event.requestID)
            } else {
                guard let outcome = event.outcome, [.passed, .failed, .needsEvidence].contains(outcome),
                      ![.error, .needsEvidence].contains((current.response ?? record.response).outcome) || outcome == .needsEvidence else {
                    throw ProductionFailure.invalid("Execution errors and uncertain actions cannot receive semantic labels before reconciliation.")
                }
                if event.action == .adjudicate && current.assignee != event.reviewer {
                    throw ProductionFailure.invalid("Only the assigned reviewer can adjudicate disagreement.")
                }
            }
            guard current.events.count < 10_000 else { throw ProductionFailure.invalid("Review history limit reached; export it before continuing.") }
            let url = reviewURL(jobID: jobID, requestID: event.requestID)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            var recorded = event; recorded.createdAt = Date()
            guard !current.events.contains(where: { $0.id == recorded.id }) else { throw ProductionFailure.invalid("Duplicate review event ID.") }
            try handle.seekToEnd(); var data = try ProductionCodec.encode(recorded); data.append(10)
            try handle.write(contentsOf: data); try handle.synchronize()
            if event.action == .reconcile, job.configuration.maximumCost != nil {
                // Publish the audit first; a crash before ledger settlement is recovered from this audit.
                try ProductionCodec.write(try auditedCostControl(job), to: jobDirectory(jobID).appendingPathComponent("control.json"))
            }
        }
    }
}
