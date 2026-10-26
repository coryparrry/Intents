import Foundation

/// Human discovery is independent of the run's automated scoring contract.
enum EvaluationReviewVerdict: String, Codable, CaseIterable, Identifiable, Sendable {
    case passed, failed, needsEvidence
    var id: Self { self }
    var title: String {
        switch self { case .passed: "Passed"; case .failed: "Failed"; case .needsEvidence: "Needs more evidence" }
    }
    var resultStatus: EvaluationResultStatus? {
        switch self { case .passed: .passed; case .failed: .failed; case .needsEvidence: nil }
    }
}

/// Human label bound to run/sample identity and a versioned source digest, allowing callers to detect stale evidence.
struct EvaluationReviewAnnotation: Identifiable, Codable, Sendable {
    var id: UUID
    var runID: UUID
    var sampleID: UUID
    var sourceDigest: String
    var verdict: EvaluationReviewVerdict
    var note: String
    var tags: [String]
    var updatedAt: Date
    static let currentSourceDigestVersion = 2
    // Missing on old labels; each verified label is migrated independently.
    var sourceDigestVersion: Int? = EvaluationReviewAnnotation.currentSourceDigestVersion
}

enum EvaluationReviewProposalStatus: String, Codable, Sendable { case pending, accepted, rejected }
struct EvaluationReviewProposal: Identifiable, Codable, Sendable {
    var id: UUID
    var annotation: EvaluationReviewAnnotation
    var status: EvaluationReviewProposalStatus = .pending
}

struct EvaluationReviewState: Codable, Sendable {
    var annotations: [EvaluationReviewAnnotation] = []
    var proposals: [EvaluationReviewProposal] = []
    /// Returns the latest annotation for the exact run/sample identity pair without validating its source digest.
    func annotation(runID: UUID, sampleID: UUID) -> EvaluationReviewAnnotation? {
        annotations.last { $0.runID == runID && $0.sampleID == sampleID }
    }
}

/// Provenance linking a promoted regression case to its human review and source evidence digest.
struct EvaluationRegressionSource: Codable, Hashable, Sendable {
    var reviewID: UUID
    var runID: UUID
    var sampleID: UUID
    var sourceDigest: String
}

enum EvaluationJudgeCheckPartition: String, Codable, CaseIterable, Identifiable, Sendable {
    case development, test
    var id: Self { self }
    var title: String { self == .test ? "Held-out test" : "Development" }
}

struct EvaluationReviewSample: Identifiable, Sendable {
    var run: EvaluationRun
    var sample: EvaluationSampleResult
    var sourceDigest: String
    var id: String { "\(run.id)/\(sample.id)" }
}

struct EvaluationFailurePattern: Identifiable, Sendable {
    var tag: String
    var samples: [EvaluationReviewSample]
    var id: String { tag }
    var caseCount: Int { Set(samples.map { $0.sample.caseID }).count }
}
