import Foundation

public struct ProductionRate: Codable, Sendable {
    public var samples: Int = 0
    public var passed: Int = 0
    public var failed: Int = 0
    public var errors: Int = 0
    public var unscored: Int = 0
    public var uncertain: Int = 0
    public var distinctSources: Int = 0
    public var passingSources: Int = 0
    public var lower95: Double?
    public var upper95: Double?
    public var passRate: Double? { passed + failed > 0 ? Double(passed) / Double(passed + failed) : nil }
    public var sourcePassRate: Double? { distinctSources > 0 ? Double(passingSources) / Double(distinctSources) : nil }
}
public struct ProductionReport: Codable, Sendable {
    public var job: ProductionJob
    public var dataset: ProductionDataset
    public var completed: Int
    public var planned: Int
    public var counts: ProductionRate
    public var cohorts: [String: ProductionRate]
    /// Conservative upper edge of a logarithmic histogram bucket (~2.2% precision).
    public var averageMilliseconds: Double?
    public var baselineCohortPassRates: [String: Double]?
    public var p95UpperMilliseconds: Double?
    public var reportedCost: Double
    public var missingCostCount: Int
    public var phase: String
    public var exitCode: Int
    public var issues: [String]
    public var baselinePassRate: Double?
    public var reviewedCount: Int
    public var samplingNotice: String
}

public enum ProductionReviewAction: String, Codable, Sendable { case assign, label, adjudicate, reconcile }
public struct ProductionReviewEvent: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var requestID: UUID
    public var reviewer: String
    public var action: ProductionReviewAction
    public var assignee: String?
    public var outcome: ProductionOutcome?
    public var note: String
    public var tags: [String]
    public var reconciledResponse: ProductionResponse?
    public var createdAt: Date = Date()
    public init(requestID: UUID, reviewer: String, action: ProductionReviewAction = .label, assignee: String? = nil,
                outcome: ProductionOutcome? = nil, note: String, tags: [String] = [], reconciledResponse: ProductionResponse? = nil) {
        self.requestID = requestID; self.reviewer = reviewer; self.action = action; self.assignee = assignee
        self.outcome = outcome; self.note = note; self.tags = tags; self.reconciledResponse = reconciledResponse
    }
}
public struct ProductionReviewResolution: Codable, Sendable {
    public var assignee: String?
    public var outcome: ProductionOutcome?
    public var disagreement: Bool
    public var response: ProductionResponse?
    public var events: [ProductionReviewEvent]
}
