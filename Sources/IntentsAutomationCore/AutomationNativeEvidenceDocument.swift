import Foundation

/// Versioned native-results extension. Recorded facts retain their original routes and trust boundary.
public struct AutomationNativeEvidenceDocument: Codable, Equatable, Sendable, Identifiable {
    public struct Artifact: Codable, Equatable, Sendable {
        public let handle: String
        public let scope: AutomationScope
        public let relativePath: String
        public let sha256: String
        public let byteCount: Int
    }
    public let schemaVersion: Int
    public let evidenceTrust: String
    public let frozen: AutomationFrozenCase
    public let report: AutomationAttemptReport
    public let sourceCaseSHA256: String
    public let sourceReportSHA256: String
    public let artifacts: [Artifact]
    public var id: String { frozen.digest + ":" + report.attemptID }
    public var displayDate: Date { report.receipts.flatMap(\.observations).map(\.collectedAt).max() ?? frozen.frozenAt }
    // Integrity preserves recorded facts; importing them proves no live acquisition.
    // Derived properties keep legacy documents readable and cannot be promoted
    // by fields supplied in an imported JSON document.
    public var acquisitionTrust: String { "historicalUnverified" }
    public var liveAccepted: Bool { false }

    init(frozen: AutomationFrozenCase, report: AutomationAttemptReport, artifacts: [Artifact]) throws {
        schemaVersion = 3; evidenceTrust = "recordedFacts"
        self.frozen = frozen; self.report = report; self.artifacts = artifacts
        sourceCaseSHA256 = try AutomationFrozenCase.canonicalDigest(frozen)
        sourceReportSHA256 = try AutomationFrozenCase.canonicalDigest(report)
        try validate()
    }
    public func validate() throws {
        guard schemaVersion == 3, evidenceTrust == "recordedFacts", artifacts.count <= 1000,
              sourceCaseSHA256 == (try AutomationFrozenCase.canonicalDigest(frozen)),
              sourceReportSHA256 == (try AutomationFrozenCase.canonicalDigest(report)) else { throw AutomationContractError.conflictingOperation }
        try frozen.validate(); try AutomationRecordedEvidence.validate(report: report, plan: frozen.plan)
        let references = try Self.references(report)
        guard Set(artifacts.map(\.handle)).count == artifacts.count, Set(artifacts.map(\.handle)) == Set(references.keys) else { throw AutomationContractError.conflictingOperation }
        for artifact in artifacts {
            guard artifact.scope == references[artifact.handle], artifact.relativePath == "Artifacts/" + artifact.handle,
                  AutomationHostProgram.identifier(artifact.handle), artifact.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  (0...16_777_216).contains(artifact.byteCount) else { throw AutomationContractError.invalidIdentity }
        }
    }
    static func references(_ report: AutomationAttemptReport) throws -> [String: AutomationScope] {
        var result: [String: AutomationScope] = [:]
        for receipt in report.receipts {
            for handle in [receipt.artifact].compactMap({ $0 }) + receipt.observations.compactMap(\.artifact) {
                guard AutomationHostProgram.identifier(handle), result[handle] == nil || result[handle] == receipt.scope else { throw AutomationContractError.conflictingOperation }
                result[handle] = receipt.scope
            }
        }
        return result
    }
}

/// Ordered evidence events, without invented acquisition, dispatch, or release durations.
public enum AutomationNativeEvidenceTimeline {
    public struct Step: Equatable, Sendable, Identifiable {
        public let id: String
        public let route: AutomationSegment.Kind
        public let phase: AutomationSegment.Phase
        public let operation: String
        public let receipt: AutomationSegmentReceipt?
    }
    public static func steps(_ document: AutomationNativeEvidenceDocument) throws -> [Step] {
        try document.validate()
        let plan = document.frozen.plan
        return (plan.setup + [plan.execution] + plan.observations + plan.cleanup).map { segment in
            .init(id: segment.id, route: segment.kind, phase: segment.phase, operation: segment.operation,
                  receipt: document.report.receipts.first(where: { $0.segmentID == segment.id }))
        }
    }
}
