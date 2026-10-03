import Foundation

public enum ProductionPartition: String, Codable, CaseIterable, Sendable { case development, regression, test }
public enum ProductionSampling: String, Codable, CaseIterable, Sendable { case curated, random, targeted }
public enum ProductionOutcome: String, Codable, Sendable { case passed, failed, unscored, error, needsEvidence }
public enum ProductionReplaySafety: String, Codable, CaseIterable, Sendable { case inference, idempotent, sideEffects }

public struct ProductionExample: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var sourceID: String
    public var prompt: String
    public var expected: String?
    public var partition: ProductionPartition
    public var metadata: [String: String]
    public var capturedOutput: String?
    public var feedback: String?
    /// Developer-owned typed input; never mixed with the expected answer.
    public var input: Data?
    public init(id: String, sourceID: String? = nil, prompt: String, expected: String? = nil,
                partition: ProductionPartition = .regression, metadata: [String: String] = [:],
                capturedOutput: String? = nil, feedback: String? = nil, input: Data? = nil) {
        self.id = id; self.sourceID = sourceID ?? id; self.prompt = prompt; self.expected = expected
        self.partition = partition; self.metadata = metadata; self.capturedOutput = capturedOutput
        self.feedback = feedback; self.input = input
    }
    private enum CodingKeys: String, CodingKey { case id, sourceID, prompt, expected, partition, metadata, capturedOutput, feedback, input }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID) ?? id
        prompt = try values.decode(String.self, forKey: .prompt)
        expected = try values.decodeIfPresent(String.self, forKey: .expected)
        partition = try values.decodeIfPresent(ProductionPartition.self, forKey: .partition) ?? .regression
        metadata = try values.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        capturedOutput = try values.decodeIfPresent(String.self, forKey: .capturedOutput)
        feedback = try values.decodeIfPresent(String.self, forKey: .feedback)
        input = try values.decodeIfPresent(Data.self, forKey: .input)
    }

}

public struct ProductionDataset: Codable, Identifiable, Sendable, Equatable {
    public var id: String { revision }
    public var name: String
    public var version: String
    public var revision: String
    public var count: Int
    public var createdAt: Date
    public var sampling: ProductionSampling
    public var productionData: Bool
    public var dataDigest: String
    public var indexDigest: String
    public var partitionCounts: [String: Int]
}

public struct ProductionTarget: Codable, Sendable, Equatable {
    public var workerID: String?
    public var platform: String?
    public var operatingSystem: String?
    public var locale: String?
    public var model: String?
    public init(workerID: String? = nil, platform: String? = nil, operatingSystem: String? = nil,
                locale: String? = nil, model: String? = nil) {
        self.workerID = workerID; self.platform = platform; self.operatingSystem = operatingSystem
        self.locale = locale; self.model = model
    }
    public func matches(_ worker: ProductionWorker) -> Bool {
        (workerID == nil || workerID == worker.id) && (platform == nil || platform == worker.platform)
        && (operatingSystem == nil || operatingSystem == worker.operatingSystem)
        && (locale == nil || locale == worker.locale) && (model == nil || model == worker.model)
    }
}

public struct ProductionWorker: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var platform: String
    public var operatingSystem: String
    public var hardware: String
    public var locale: String
    public var model: String
    public var lastSeen: Date
    public init(id: String, name: String, platform: String, operatingSystem: String, hardware: String,
                locale: String, model: String, lastSeen: Date = Date()) {
        self.id = id; self.name = name; self.platform = platform; self.operatingSystem = operatingSystem
        self.hardware = hardware; self.locale = locale; self.model = model; self.lastSeen = lastSeen
    }
}

public struct ProductionGatePolicy: Codable, Sendable, Equatable {
    public var minimumPassRate: Double = 1
    public var maximumErrors: Int = 0
    public var maximumAverageMilliseconds: Double?
    public var maximumP95Milliseconds: Double?
    public var maximumPassRateRegression: Double = 0
    public var criticalSourceIDs: [String] = []
    public var requiredCohorts: [String: String] = [:]
    /// Keys use metadataKey=metadataValue, for example locale=fr_FR.
    public var cohortMinimumPassRates: [String: Double] = [:]
    public var requireBaseline: Bool = false
    public init() {}
}

public struct ProductionJobConfiguration: Codable, Sendable, Equatable {
    public var repetitions: Int = 1
    public var chunkSize: Int = 100
    public var maximumAttempts: Int = 2
    public var timeoutSeconds: Double = 120
    public var maximumElapsedSeconds: Double = 86_400
    public var maximumCost: Double?
    public var maximumCostPerAttempt: Double?
    public var replaySafety: ProductionReplaySafety = .inference
    public var targets: [ProductionTarget] = [.init()]
    public var gate: ProductionGatePolicy = .init()
    public var baselineJobID: UUID?
    /// Hash of the scoring contract, independent of the subject variant.
    public var scoringRevision: String
    public var executionRevision: String
    /// Frozen developer/native setup. Never contains authentication credentials.
    public var executionContext: Data
    public init(scoringRevision: String, executionRevision: String, executionContext: Data = Data()) {
        self.scoringRevision = scoringRevision; self.executionRevision = executionRevision
        self.executionContext = executionContext
    }
}

public struct ProductionJob: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var datasetRevision: String
    public var configuration: ProductionJobConfiguration
    public var plannedCount: Int
    public var createdAt: Date
    public var revision: String
}

public struct ProductionRequest: Codable, Sendable {
    public var requestID: UUID
    public var jobID: UUID
    public var jobRevision: String
    public var datasetRevision: String
    public var slot: Int
    public var repetition: Int
    public var targetIndex: Int
    public var example: ProductionExample
    public var configuration: ProductionJobConfiguration
    public var deadline: Date
}

public struct ProductionResponse: Codable, Sendable, Equatable {
    public var requestID: UUID
    public var outcome: ProductionOutcome
    public var output: String
    public var explanation: String?
    public var latencyMilliseconds: Double
    public var latencyAvailable: Bool? = nil
    public var cost: Double?
    public var retryable: Bool
    public var artifact: Data?
    public init(requestID: UUID, outcome: ProductionOutcome, output: String = "", explanation: String? = nil,
                latencyMilliseconds: Double = 0, latencyAvailable: Bool? = nil, cost: Double? = nil, retryable: Bool = false, artifact: Data? = nil) {
        self.requestID = requestID; self.outcome = outcome; self.output = output; self.explanation = explanation
        self.latencyMilliseconds = latencyMilliseconds; self.latencyAvailable = latencyAvailable; self.cost = cost; self.retryable = retryable; self.artifact = artifact
    }
}

public struct ProductionRecord: Codable, Sendable, Equatable {
    public var slot: Int
    public var sourceID: String
    public var exampleID: String
    public var partition: ProductionPartition
    public var metadata: [String: String]
    public var targetIndex: Int
    public var repetition: Int
    public var attempt: Int
    public var worker: ProductionWorker
    public var response: ProductionResponse
    public var completedAt: Date
}

public struct ProductionAttempt: Codable, Sendable {
    public var pendingCost: Double? = nil
    public var pendingCostAttempt: Int? = nil
    public var reportedCost: Double? = nil
    public var hasUnknownCost: Bool? = nil
    public var requestID: UUID
    public var number: Int
    public var startedAt: Date
    public var worker: ProductionWorker
}
public struct ProductionLease: Codable, Sendable { public var token: UUID; public var workerID: String; public var expiresAt: Date }
public struct ProductionChunk: Codable, Sendable {
    public var index: Int
    public var lease: ProductionLease?
    public var attempts: [Int: ProductionAttempt] = [:]
    public var records: [Int: ProductionRecord] = [:]
}
public struct ProductionControl: Codable, Sendable {
    public var paused: Bool = false
    /// Control changes invalidate prior baseline approval even after restoring the prior values.
    public var evidenceMutationID: UUID? = nil
    public var cancelled: Bool = false
    public var startedAt: Date?
    public var reportedCost: Double = 0
    public var costReservations: [String: Double] = [:]
    public var costReservationSlots: [String: Int]? = nil
    public init() {}
}

public enum ProductionFailure: Error, LocalizedError, Sendable {
    case invalid(String), integrity(String), staleLease, unavailable(String), budget(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let value), .integrity(let value), .unavailable(let value), .budget(let value): value
        case .staleLease: "This worker no longer owns the chunk. Its late result was rejected."
        }
    }
}
