import Foundation

/// One repeat's local transcript, emitted by the generated UI test.
public struct SiriStudioReport: Codable, Sendable, Equatable {
    static let schemaID = "dev.intents.siri-studio.report"
    public let schema: String
    public let version: Int
    public let scenarioID: UUID
    public let revision: Int
    /// Absent on older exports, which cannot establish the authored content that was evaluated.
    public var authoredDigest: String? = nil
    public let repeatIndex: Int
    public let status: Status
    public let blocked: Blocked?
    public let turnsAuthored: Int
    public let turnsReached: Int
    public let turns: [Turn]

    /// Describes whether Siri started; completion is represented by the reached turns.
    public enum Status: String, Codable, Sendable { case ran, blocked }

    /// A local-only explanation of a failed setup or Siri start.
    public struct Blocked: Codable, Sendable, Equatable {
        /// Identifies which stage prevented the conversation from starting.
        public enum Phase: String, Codable, Sendable { case setup, siri }
        public let phase: Phase
        public let errorType: String
        public let message: String
    }

    /// A reached turn with timestamped observations.
    public struct Turn: Codable, Sendable, Equatable, Identifiable {
        public let turnID: UUID
        public var id: UUID { turnID }
        public let utterance: String
        public let invocations: [Invocation]
        public let foundEntities: [Observation]
        public let onScreenEntities: [Observation]
        public let loadedSkills: [Observation]
        public let response: Observation?
    }

    /// Observed display values; these strings cannot be replayed as typed arguments.
    public struct Invocation: Codable, Sendable, Equatable {
        public let intent: String
        public let bundleIdentifier: String?
        public let arguments: [String: String]
        public let outcome: String
        public let ran: Bool
        public let committed: Bool
        public let result: String?
        public let timestamp: String
    }

    /// A display value and the time at which Siri observed it.
    public struct Observation: Codable, Sendable, Equatable {
        public let text: String
        public let timestamp: String
    }

    /// Rejects malformed transcript counts and IDs before they can influence a verdict.
    var consistent: Bool {
        schema == Self.schemaID && version == 1 && revision > 0 && (0..<10).contains(repeatIndex)
            && (1...12).contains(turnsAuthored) && turnsReached == turns.count && turnsReached <= turnsAuthored
            && Set(turns.map(\.id)).count == turns.count
            && (status == .blocked ? blocked != nil && turns.isEmpty : blocked == nil)
    }
}

/// Apple's summary metrics as recorded by the generated test body.
public struct SiriStudioSummary: Codable, Sendable, Equatable {
    static let schemaID = "dev.intents.siri-studio.summary"
    public let schema: String
    public let version: Int
    public let scenarioID: UUID
    public let revision: Int
    /// Absent on older exports, which cannot establish the authored content that was evaluated.
    public var authoredDigest: String? = nil
    public let metrics: [String: Double]
    public let perRepeat: [RepeatMetrics]?
    public let inferenceFailureCount: Int
    public let metricsNotFound: [String]
    public var evaluatorFailureCount: Int? = nil

    /// Apple's metrics for a repeat identified through the sample's turn ID.
    public struct RepeatMetrics: Codable, Sendable, Equatable {
        public let repeatIndex: Int
        public let metrics: [String: Double]
    }
}

/// The verdict shown in Studio and returned by the CLI.
public enum SiriStudioState: String, Codable, Sendable { case passed, failed, incomplete, blocked, cancelled }

/// Validated evidence and verdict for one selected scenario.
public struct SiriStudioScenarioResult: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let revision: Int
    public let name: String
    public let state: SiriStudioState
    public let attempted: Int
    /// nil means the aggregate metrics cannot establish an exact repeat count.
    public let passed: Int?
    public let reports: [SiriStudioReport]
    public let summary: SiriStudioSummary?
    public let failingMetrics: [String]
    public let reason: String?

    /// Applies verdict precedence to the exact scenario snapshot and Apple metrics.
    static func assess(_ scenario: SiriStudioScenario, bundleIdentifier: String, reports input: [SiriStudioReport], summary: SiriStudioSummary?,
                       blocked: String? = nil, cancelled: String? = nil) -> Self {
        let digest = try? scenario.contentDigest(bundleIdentifier: bundleIdentifier)
        let identityMatches = digest != nil && summary?.authoredDigest == digest
            && input.allSatisfy { $0.authoredDigest == digest }
        let reports = input.filter {
            $0.authoredDigest == digest && digest != nil && $0.consistent && $0.scenarioID == scenario.id && $0.revision == scenario.revision
                && $0.repeatIndex < scenario.repeatCount && $0.turnsAuthored == scenario.turns.count
                && $0.turns.map(\.id) == Array(scenario.turns.prefix($0.turnsReached).map(\.id))
        }.sorted { $0.repeatIndex < $1.repeatIndex }
        let summary = summary.flatMap { evidence in
            evidence.schema == SiriStudioSummary.schemaID && evidence.version == 1
                && evidence.scenarioID == scenario.id && evidence.revision == scenario.revision
                && evidence.authoredDigest == digest && digest != nil ? evidence : nil
        }
        return classify(id: scenario.id, revision: scenario.revision, name: scenario.name, attempted: scenario.repeatCount,
                        asserted: scenario.metrics, reports: reports, summary: summary,
                        blocked: blocked ?? (identityMatches ? nil : "The result does not match this authored scenario. Export and run the current document again."),
                        cancelled: cancelled)
    }

    /// Shows the observations of an older revision without applying the current document's expectations to them.
    static func stale(_ scenario: SiriStudioScenario, reports: [SiriStudioReport], summary: SiriStudioSummary,
                      blocked: String?) -> Self {
        // An exported file does not contain the old document. Do not infer its authored repeat count.
        .init(id: scenario.id, revision: summary.revision, name: scenario.name, state: .blocked,
              attempted: 0, passed: nil, reports: reports.sorted { $0.repeatIndex < $1.repeatIndex },
              summary: summary, failingMetrics: [],
              reason: blocked ?? "Stale result. Open the exported scenario revision to verify its verdict.")
    }

    /// Derives the verdict only from evidence tied to the selected scenario and complete repeats.
    private static func classify(id: UUID, revision: Int, name: String, attempted: Int, asserted: [String],
                                 reports: [SiriStudioReport], summary: SiriStudioSummary?,
                                 blocked: String?, cancelled: String?) -> Self {
        /// Constructs the result while keeping diagnostic paths separate from the state rules.
        func result(_ state: SiriStudioState, _ reason: String? = nil, passed: Int? = nil,
                    failing: [String] = []) -> Self {
            .init(id: id, revision: revision, name: name, state: state, attempted: attempted,
                  passed: passed, reports: reports, summary: summary, failingMetrics: failing, reason: reason)
        }
        if let cancelled { return result(.cancelled, cancelled) }
        if let blocked { return result(.blocked, blocked) }
        guard let summary, Set(reports.map(\.repeatIndex)).count == reports.count,
              reports.contains(where: { $0.status == .ran }) else {
            return result(.blocked, "No verifiable Siri evaluation summary or repeat reports were recorded.")
        }
        let complete = reports.filter { $0.status == .ran && $0.turnsReached == $0.turnsAuthored }
        let allComplete = complete.count == attempted
        /// A missing metric or Apple's -1 sentinel supplies no evidence.
        func value(_ metric: String, in metrics: [String: Double]) -> Double? {
            guard let value = metrics[metric], (0...1).contains(value) else { return nil }
            return value
        }
        let rows = Dictionary(grouping: summary.perRepeat ?? [], by: \.repeatIndex)
        let usableRows = rows.values.allSatisfy { $0.count == 1 } ? rows : [:]
        let repeatGrades = complete.map { usableRows[$0.repeatIndex]?.first?.metrics ?? [:] }
        let perRepeatFailing = asserted.filter { metric in
            repeatGrades.contains { (value(metric, in: $0) ?? 1) < 1 }
        }
        let evaluationSucceeded = (summary.evaluatorFailureCount ?? 0) == 0
        let allRowsKnown = repeatGrades.allSatisfy { row in asserted.allSatisfy { value($0, in: row) != nil } }
        let aggregateKnown = !asserted.isEmpty && asserted.allSatisfy { value($0, in: summary.metrics) != nil }
        let aggregateFailing = asserted.filter { (value($0, in: summary.metrics) ?? 1) < 1 }
        let passed: Int? = if allRowsKnown {
            repeatGrades.filter { row in asserted.allSatisfy { value($0, in: row) == 1 } }.count
        } else if evaluationSucceeded && aggregateKnown && aggregateFailing.isEmpty {
            complete.count
        } else if allComplete && attempted == 1 && !aggregateFailing.isEmpty {
            0
        } else { nil }
        if !perRepeatFailing.isEmpty { return result(.failed, passed: passed, failing: perRepeatFailing) }
        if allComplete && !aggregateFailing.isEmpty {
            return result(.failed, passed: passed, failing: aggregateFailing)
        }
        if !allComplete {
            let partial = reports.first { $0.status == .ran && $0.turnsReached < $0.turnsAuthored }
            let reason = partial.map { "\($0.turnsReached) of \($0.turnsAuthored) turns reached." }
                ?? "At least one repeat was blocked or did not record a report."
            return result(.incomplete, reason, passed: passed)
        }
        guard aggregateKnown, summary.inferenceFailureCount == 0, evaluationSucceeded else {
            return result(.blocked, "Apple did not produce all expected metrics.")
        }
        return result(.passed, passed: passed)
    }
}

/// The frozen input, verdicts and local evidence paths for a Studio run.
public struct SiriStudioRunRecord: Codable, Sendable {
    public let document: SiriStudioDocument
    public let productIdentity: MacIntentProductIdentity?
    public let xcodeBuild: String?
    public let osBuild: String
    public let startedAt: Date
    public let endedAt: Date
    public let sourceURL: URL?
    public let resultBundleURL: URL?
    public let logURL: URL
    public let scenarios: [SiriStudioScenarioResult]

    /// Summarizes the selected scenario verdicts with cancellation and evidence failures preserved.
    public var state: SiriStudioState {
        let states = scenarios.map(\.state)
        return [SiriStudioState.cancelled, .blocked, .failed, .incomplete].first { states.contains($0) }
            ?? (states.isEmpty ? .blocked : .passed)
    }

    /// Reopens a saved run while preventing legacy or mismatched evidence from retaining a current verdict.
    public static func read(from directory: URL) throws -> Self {
        let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("run.json")))
        let scenarios = record.scenarios.map { result in
            guard result.state != .blocked && result.state != .cancelled else { return result }
            let authored = record.document.scenarios.first { $0.id == result.id }
            let digest = try? authored?.contentDigest(bundleIdentifier: record.document.bundleIdentifier)
            guard let digest, authored?.revision == result.revision,
                  result.summary?.authoredDigest == digest,
                  result.reports.allSatisfy({ $0.authoredDigest == digest }) else {
                return SiriStudioScenarioResult(id: result.id, revision: result.revision, name: result.name,
                    state: .blocked, attempted: result.attempted, passed: nil, reports: result.reports,
                    summary: result.summary, failingMetrics: [],
                    reason: "This saved result lacks matching authored-content evidence. Export and run the current document again.")
            }
            return result
        }
        return Self(document: record.document, productIdentity: record.productIdentity, xcodeBuild: record.xcodeBuild,
            osBuild: record.osBuild, startedAt: record.startedAt, endedAt: record.endedAt, sourceURL: record.sourceURL,
            resultBundleURL: record.resultBundleURL, logURL: record.logURL, scenarios: scenarios)
    }

    /// Persists the immutable run snapshot and evidence in a single atomic write.
    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: directory.appendingPathComponent("run.json"), options: .atomic)
    }
}

/// Content-free progress posted by the generated test while it owns a repeat.
public struct SiriStudioProgress: Decodable, Sendable, Equatable {
    public let scenarioID: UUID
    public let repeatIndex: Int

    /// Reads the latest atomic progress file, if a test has started.
    public static func read(from directory: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("progress.json")))
    }
}

extension SiriStudioRunRecord {
    /// Exports either the full transcript record or a projection with only verdicts and Apple metrics.
    public func exportEvidence(to url: URL, includeTranscripts: Bool) throws {
        struct Verdict: Encodable {
            let scenarioID: UUID
            let revision: Int
            let state: SiriStudioState
            let attempted: Int
            let passed: Int?
            let failingMetrics: [String]
            let summary: SiriStudioSummary?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let bytes: Data
        if includeTranscripts {
            bytes = try encoder.encode(self)
        } else {
            bytes = try encoder.encode(scenarios.map {
                Verdict(scenarioID: $0.id, revision: $0.revision, state: $0.state, attempted: $0.attempted,
                        passed: $0.passed, failingMetrics: $0.failingMetrics, summary: $0.summary)
            })
        }
        try bytes.write(to: url, options: .atomic)
    }
}
