import Foundation

public typealias ProductionExecutor = @Sendable (ProductionRequest) async throws -> ProductionResponse

public struct ProductionBatchRunner: Sendable {
    public let storage: ProductionStorage
    public init(storage: ProductionStorage) { self.storage = storage }
    /// Returns the number of newly committed responses. Another worker may still own remaining chunks.
    public func run(jobID: UUID, worker: ProductionWorker, maximumResponses: Int = .max,
                    execute: @escaping ProductionExecutor) async throws -> Int {
        let job = try storage.loadJob(jobID)
        let reader = try ProductionDatasetReader(storage: storage, revision: job.datasetRevision)
        var worker = worker; worker.lastSeen = Date(); try storage.register(worker)
        var committed = 0
        while committed < maximumResponses, !Task.isCancelled, let claimed = try storage.claim(job, worker: worker) {
            guard let token = claimed.lease?.token else { throw ProductionFailure.staleLease }
            do {
                for slot in storage.slots(job, chunk: claimed.index) where committed < maximumResponses {
                    let control = try storage.control(job)
                    if control.paused || control.cancelled || Task.isCancelled { break }
                    guard job.configuration.targets[storage.targetIndex(job, slot: slot)].matches(worker) else { continue }
                    let current = try storage.chunk(job, index: claimed.index)
                    if current.records[slot] != nil { continue }
                    var request = try storage.request(job, slot: slot, reader: reader)
                    if let started = control.startedAt, Date().timeIntervalSince(started) >= job.configuration.maximumElapsedSeconds {
                        throw ProductionFailure.budget("Job elapsed-time budget was exhausted.")
                    }
                    var attempt = current.attempts[slot]?.number ?? 0
                    var accumulatedCost = current.attempts[slot]?.reportedCost ?? 0
                    var unknownCost = current.attempts[slot].map { $0.hasUnknownCost ?? true } ?? false
                    var response: ProductionResponse
                    if current.attempts[slot] != nil && job.configuration.replaySafety == .sideEffects {
                        response = .init(requestID: request.requestID, outcome: .needsEvidence,
                                         explanation: "The previous action was interrupted. Verify its app state and reconcile this request before retrying.")
                    } else if attempt >= job.configuration.maximumAttempts {
                        response = .init(requestID: request.requestID, outcome: .error, explanation: "Attempt budget exhausted after interruption.")
                    } else {
                        repeat {
                            let latestControl = try storage.control(job)
                            guard !latestControl.paused, !latestControl.cancelled, !Task.isCancelled else { throw CancellationError() }
                            let started = Date()
                            let remaining = latestControl.startedAt.map { job.configuration.maximumElapsedSeconds - started.timeIntervalSince($0) } ?? job.configuration.maximumElapsedSeconds
                            guard remaining > 0 else { throw ProductionFailure.budget("Job elapsed-time budget was exhausted.") }
                            attempt += 1
                            request.deadline = started.addingTimeInterval(min(job.configuration.timeoutSeconds, remaining))
                            try storage.reserveCost(job, requestID: request.requestID, slot: slot, attempt: attempt)
                            try storage.updateChunk(job, index: claimed.index, token: token) { chunk in
                                chunk.attempts[slot] = .init(requestID: request.requestID, number: attempt, startedAt: started, worker: worker)
                                chunk.attempts[slot]?.reportedCost = accumulatedCost
                                chunk.attempts[slot]?.hasUnknownCost = true
                            }
                            do {
                                let frozenRequest = request
                                response = try await withDeadline(seconds: min(job.configuration.timeoutSeconds, remaining)) { try await execute(frozenRequest) }
                                try storage.validateResponse(response, requestID: request.requestID)
                            } catch {
                                if error is CancellationError, job.configuration.replaySafety != .sideEffects { throw error }
                                response = .init(requestID: request.requestID, outcome: job.configuration.replaySafety == .sideEffects ? .needsEvidence : .error,
                                                 explanation: String(describing: error).prefix(8_000).description,
                                                 latencyMilliseconds: Date().timeIntervalSince(started) * 1000, retryable: error is ProductionTransientFailure)
                            }
                            if let cost = response.cost { accumulatedCost += cost } else { unknownCost = true }
                            try storage.checkpointCost(job, index: claimed.index, token: token, slot: slot, attempt: attempt,
                                cost: response.cost, accumulatedCost: accumulatedCost, unknown: unknownCost)
                            if job.configuration.replaySafety == .sideEffects && response.outcome == .error {
                                response.outcome = .needsEvidence; response.retryable = false
                            }
                            if response.outcome == .error, response.retryable, attempt < job.configuration.maximumAttempts,
                               !Task.isCancelled {
                                try await Task.sleep(for: .milliseconds(min(2_000, 100 * attempt)))
                            } else { break }
                        } while true
                    }
                    response.cost = unknownCost ? nil : accumulatedCost
                    let record = ProductionRecord(slot: slot, sourceID: request.example.sourceID, exampleID: request.example.id,
                        partition: request.example.partition, metadata: request.example.metadata, targetIndex: request.targetIndex,
                        repetition: request.repetition, attempt: max(1, attempt), worker: worker, response: response, completedAt: Date())
                    try storage.updateChunk(job, index: claimed.index, token: token) { chunk in
                        guard chunk.records[slot] == nil else { throw ProductionFailure.integrity("Duplicate result commit.") }
                        chunk.records[slot] = record
                    }
                    committed += 1; worker.lastSeen = Date(); try storage.register(worker)
                }
                try storage.updateChunk(job, index: claimed.index, token: token) { $0.lease = nil }
            } catch {
                try? storage.updateChunk(job, index: claimed.index, token: token) { $0.lease = nil }
                throw error
            }
        }
        return committed
    }
    private func withDeadline<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw ProductionTransientFailure("Request deadline exceeded.") }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }; return result
        }
    }
}

public struct ProductionTransientFailure: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
