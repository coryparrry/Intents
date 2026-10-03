import Foundation

extension ProductionStorage {
    public func createJob(name: String, datasetRevision: String, configuration: ProductionJobConfiguration,
                          id: UUID = UUID()) throws -> ProductionJob {
        let dataset = try loadDataset(datasetRevision, verifyFiles: true)
        try Self.validate(configuration)
        let total = dataset.count * configuration.repetitions * configuration.targets.count
        guard !name.isEmpty, name.count <= 200, total <= 10_000_000 else {
            throw ProductionFailure.invalid("Provide a job name and at most ten million planned responses.")
        }
        if let baselineID = configuration.baselineJobID {
            let baseline = try loadJob(baselineID)
            guard baseline.datasetRevision == datasetRevision,
                  baseline.configuration.scoringRevision == configuration.scoringRevision,
                  baseline.configuration.repetitions == configuration.repetitions,
                  baseline.configuration.targets == configuration.targets else {
                throw ProductionFailure.invalid("Baseline dataset, scoring, repetitions and target matrix must match.")
            }
        }
        var job = ProductionJob(id: id, name: name, datasetRevision: datasetRevision, configuration: configuration,
                                plannedCount: total, createdAt: Date(), revision: "")
        job.revision = ProductionCodec.digest(try ProductionCodec.encode(job))
        return try transaction { try installJob(job) }
    }
    // Caller holds the store lock, including scheduled creation/advancement.
    func installJob(_ job: ProductionJob) throws -> ProductionJob {
            let id = job.id, datasetRevision = job.datasetRevision, configuration = job.configuration
            let directory = jobDirectory(id)
            if FileManager.default.fileExists(atPath: directory.path) {
                let existing = try loadJob(id)
                guard existing.name == job.name, existing.datasetRevision == datasetRevision, existing.configuration == configuration else {
                    throw ProductionFailure.invalid("Job ID already belongs to a different frozen job.")
                }
                return existing
            }
            let staging = root.appendingPathComponent("Jobs/.new-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.createDirectory(at: staging.appendingPathComponent("Chunks"), withIntermediateDirectories: true)
            try ProductionCodec.write(job, to: staging.appendingPathComponent("job.json"))
            try ProductionCodec.write(ProductionControl(), to: staging.appendingPathComponent("control.json"))
            try FileManager.default.moveItem(at: staging, to: directory)
            return job
    }
    public func loadJob(_ id: UUID) throws -> ProductionJob {
        let job = try ProductionCodec.read(ProductionJob.self, from: jobDirectory(id).appendingPathComponent("job.json"))
        var unhashed = job; unhashed.revision = ""
        let dataset = try loadDataset(job.datasetRevision)
        try Self.validate(job.configuration)
        var validRevision = ProductionCodec.digest(try ProductionCodec.encode(unhashed)) == job.revision
        if !validRevision { validRevision = ProductionCodec.digest(try ProductionCodec.legacyEncode(unhashed)) == job.revision }
        guard job.id == id, validRevision,
              job.plannedCount == dataset.count * job.configuration.repetitions * job.configuration.targets.count else {
            throw ProductionFailure.integrity("Frozen job identity changed.")
        }
        return job
    }
    public func jobs() throws -> [ProductionJob] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Jobs"), includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }.map {
                guard let id = UUID(uuidString: $0.lastPathComponent) else { throw ProductionFailure.integrity("Invalid job directory.") }
                return try loadJob(id)
            }.sorted { $0.createdAt > $1.createdAt }
    }
    public func control(_ job: ProductionJob) throws -> ProductionControl {
        try ProductionCodec.read(ProductionControl.self, from: jobDirectory(job.id).appendingPathComponent("control.json"), maximumBytes: 1_000_000)
    }
    public func controlRevision(_ job: ProductionJob) throws -> String {
        let value = try control(job)
        return Self.controlRevision(value)
    }
    public static func controlRevision(_ value: ProductionControl) -> String {
        ProductionCodec.digest(Data("\(value.paused)/\(value.cancelled)".utf8))
    }
    public func setControl(jobID: UUID, paused: Bool? = nil, cancelled: Bool? = nil, expectedControlRevision: String? = nil) throws {
        try transaction {
            let job = try loadJob(jobID); var value = try control(job)
            if let expectedControlRevision, try controlRevision(job) != expectedControlRevision { throw ProductionFailure.invalid("Control state changed. Reread pause/cancel state before changing it.") }
            if let paused { value.paused = paused }
            if let cancelled { value.cancelled = cancelled }
            try ProductionCodec.write(value, to: jobDirectory(jobID).appendingPathComponent("control.json"))
        }
    }
    public func register(_ worker: ProductionWorker) throws {
        guard !worker.id.isEmpty, worker.id.count <= 200, !worker.name.isEmpty,
              [worker.platform, worker.operatingSystem, worker.hardware, worker.locale, worker.model].allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else {
            throw ProductionFailure.invalid("Worker provenance is incomplete.")
        }
        try transaction {
            let key = ProductionCodec.digest(Data(worker.id.utf8))
            try ProductionCodec.write(worker, to: root.appendingPathComponent("Workers/\(key).json"))
        }
    }
    public func workers() throws -> [ProductionWorker] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Workers"), includingPropertiesForKeys: nil)
            .map { try ProductionCodec.read(ProductionWorker.self, from: $0, maximumBytes: 20_000) }.sorted { $0.name < $1.name }
    }
    public func chunkCount(_ job: ProductionJob) -> Int { (job.plannedCount + job.configuration.chunkSize - 1) / job.configuration.chunkSize }
    func chunkURL(_ job: ProductionJob, _ index: Int) -> URL { jobDirectory(job.id).appendingPathComponent("Chunks/\(index).json") }
    public func chunk(_ job: ProductionJob, index: Int) throws -> ProductionChunk {
        guard (0..<chunkCount(job)).contains(index) else { throw ProductionFailure.invalid("Chunk index is out of range.") }
        let url = chunkURL(job, index)
        let value = FileManager.default.fileExists(atPath: url.path)
            ? try ProductionCodec.read(ProductionChunk.self, from: url, maximumBytes: 50_000_000) : ProductionChunk(index: index)
        let range = slots(job, chunk: index)
        guard value.index == index, value.records.count <= job.configuration.chunkSize,
              value.attempts.count <= job.configuration.chunkSize,
              value.records.allSatisfy({ range.contains($0.key) && $0.key == $0.value.slot
                  && $0.value.response.requestID == requestID(job, slot: $0.key) }),
              value.attempts.allSatisfy({ range.contains($0.key) && $0.value.requestID == requestID(job, slot: $0.key)
                  && (1...job.configuration.maximumAttempts).contains($0.value.number) }) else {
            throw ProductionFailure.integrity("Chunk contains foreign or invalid evidence.")
        }
        return value
    }
    public func slots(_ job: ProductionJob, chunk: Int) -> Range<Int> {
        let start = chunk * job.configuration.chunkSize
        return start..<min(job.plannedCount, start + job.configuration.chunkSize)
    }
    public func targetIndex(_ job: ProductionJob, slot: Int) -> Int { slot % job.configuration.targets.count }
    public func requestID(_ job: ProductionJob, slot: Int) -> UUID { ProductionCodec.stableID("\(job.revision)/\(slot)") }
    public func request(_ job: ProductionJob, slot: Int, reader: ProductionDatasetReader, now: Date = Date()) throws -> ProductionRequest {
        guard (0..<job.plannedCount).contains(slot) else { throw ProductionFailure.invalid("Slot is out of range.") }
        let matrixSize = job.configuration.targets.count, repetitions = job.configuration.repetitions
        return ProductionRequest(requestID: requestID(job, slot: slot), jobID: job.id, jobRevision: job.revision,
            datasetRevision: job.datasetRevision, slot: slot, repetition: (slot / matrixSize) % repetitions + 1,
            targetIndex: targetIndex(job, slot: slot), example: try reader.example(at: slot / (matrixSize * repetitions)),
            configuration: job.configuration, deadline: now.addingTimeInterval(job.configuration.timeoutSeconds))
    }
    public func claim(_ job: ProductionJob, worker: ProductionWorker, now: Date = Date()) throws -> ProductionChunk? {
        try transaction {
            var settings = try control(job)
            guard !settings.paused, !settings.cancelled else { return nil }
            for index in 0..<chunkCount(job) {
                var value = try chunk(job, index: index)
                guard value.lease == nil || value.lease!.expiresAt <= now else { continue }
                let available = slots(job, chunk: index).contains { slot in
                    job.configuration.targets[targetIndex(job, slot: slot)].matches(worker)
                    && value.records[slot] == nil
                }
                guard available else { continue }
            if let start = settings.startedAt, now.timeIntervalSince(start) > job.configuration.maximumElapsedSeconds {
                throw ProductionFailure.budget("Job elapsed-time budget was exhausted; evidence was retained.")
            }

                if settings.startedAt == nil {
                    settings.startedAt = now
                    try ProductionCodec.write(settings, to: jobDirectory(job.id).appendingPathComponent("control.json"))
                }
                value.lease = ProductionLease(token: UUID(), workerID: worker.id,
                    expiresAt: now.addingTimeInterval(max(300, job.configuration.timeoutSeconds * 3)))
                try ProductionCodec.write(value, to: chunkURL(job, index)); return value
            }
            return nil
        }
    }
    public func updateChunk(_ job: ProductionJob, index: Int, token: UUID, now: Date = Date(),
                            update: (inout ProductionChunk) throws -> Void) throws {
        try transaction {
            var value = try chunk(job, index: index)
            guard value.lease?.token == token, let expiry = value.lease?.expiresAt, expiry > now else { throw ProductionFailure.staleLease }
            try update(&value)
            if value.lease != nil { value.lease?.expiresAt = now.addingTimeInterval(max(300, job.configuration.timeoutSeconds * 3)) }
            try ProductionCodec.write(value, to: chunkURL(job, index))
        }
    }
    public func validateResponse(_ response: ProductionResponse, requestID: UUID) throws {
        guard response.requestID == requestID, response.output.utf8.count <= 64_000,
              (response.explanation?.utf8.count ?? 0) <= 8_000, (response.artifact?.count ?? 0) <= 262_144,
              response.latencyMilliseconds.isFinite, response.latencyMilliseconds >= 0,
              response.cost == nil || (response.cost!.isFinite && response.cost! >= 0) else {
            throw ProductionFailure.invalid("Worker returned foreign, oversized or non-finite evidence.")
        }
    }
    static func validate(_ config: ProductionJobConfiguration) throws {
        try ProductionCodec.validateDigest(config.scoringRevision)
        guard config.executionRevision == ProductionCodec.digest(config.executionContext), config.executionContext.count <= 64_000_000,
              (1...100).contains(config.chunkSize), (1...20).contains(config.repetitions), (1...5).contains(config.maximumAttempts),
              (1...32).contains(config.targets.count), config.timeoutSeconds.isFinite, (0.1...3600).contains(config.timeoutSeconds),
              config.maximumElapsedSeconds.isFinite, (1...2_592_000).contains(config.maximumElapsedSeconds),
              config.maximumCost == nil || (config.maximumCost!.isFinite && config.maximumCost! > 0
                && config.maximumCostPerAttempt != nil && config.maximumCostPerAttempt!.isFinite && config.maximumCostPerAttempt! >= 0),
              config.gate.minimumPassRate.isFinite, (0...1).contains(config.gate.minimumPassRate), config.gate.maximumErrors >= 0,
              config.gate.maximumAverageMilliseconds == nil || (config.gate.maximumAverageMilliseconds!.isFinite && config.gate.maximumAverageMilliseconds! >= 0),
              config.gate.maximumP95Milliseconds == nil || (config.gate.maximumP95Milliseconds!.isFinite && config.gate.maximumP95Milliseconds! >= 0),
              config.gate.maximumPassRateRegression.isFinite, (0...1).contains(config.gate.maximumPassRateRegression),
              config.gate.cohortMinimumPassRates.count <= 100,
              config.gate.cohortMinimumPassRates.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw ProductionFailure.invalid("Invalid job limits, gate policy or frozen execution context.")
        }
    }
}
