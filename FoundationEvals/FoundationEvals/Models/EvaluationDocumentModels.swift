import CryptoKit
import Foundation

/// Immutable extracted text. Locations and IDs are assigned by the importer, never the model.
struct EvaluationDocumentPassage: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var location: String
    var text: String
}

struct EvaluationDocumentSource: Codable, Hashable, Sendable {
    static let extractionVersion = 1
    var name: String
    var fileDigest: String
    var passages: [EvaluationDocumentPassage]
    var warnings: [String] = []

    var validationIssue: String? {
        guard !name.isEmpty, name.count <= 255, fileDigest.count == 64,
              !passages.isEmpty, passages.count <= 512,
              Set(passages.map(\.id)).count == passages.count,
              passages.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 80 && $0.location.count <= 255 && !$0.text.isEmpty }),
              passages.reduce(0, { $0 + $1.text.count }) <= 128_000 else {
            return "The saved document source is incomplete, has duplicate passage IDs, or exceeds its limits."
        }
        return nil
    }
}

struct EvaluationDocumentCitation: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var passageID: String
    var quote: String
}

/// Each case owns the small context snapshot it needs. Copies and saved runs cannot lose it to cleanup.
struct EvaluationDocumentEvidence: Codable, Hashable, Sendable {
    var formatVersion = 1
    var sourceName: String
    var sourceDigest: String
    var extractionVersion = EvaluationDocumentSource.extractionVersion
    var passages: [EvaluationDocumentPassage]
    var citations: [EvaluationDocumentCitation]
    var questionType: String
    var generator = "Foundation Models · on-device"
    var generatorVersion = "document-draft-v2"
    var reviewedDigest: String?
    var requestedQuestionType: String? = nil

    var contextText: String {
        passages.map { "[\($0.id) · \($0.location)]\n\($0.text)" }.joined(separator: "\n\n")
    }

    var validationIssue: String? {
        guard formatVersion == 1, extractionVersion == EvaluationDocumentSource.extractionVersion else {
            return "This document case requires a newer version of Intents."
        }
        guard !sourceName.isEmpty, sourceName.count <= 255, sourceDigest.count == 64,
              !passages.isEmpty, passages.count <= 512,
              Set(passages.map(\.id)).count == passages.count,
              passages.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !$0.id.isEmpty && $0.id.count <= 80 && $0.location.count <= 255 }),
              passages.reduce(0, { $0 + $1.text.count }) <= 128_000 else { return "The retained document context is missing or exceeds its limits." }
        guard !citations.isEmpty, citations.count <= 8,
              citations.allSatisfy({ citation in
                  !citation.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && passages.contains { $0.id == citation.passageID && $0.text.contains(citation.quote) }
              }) else { return "Each supporting quote must match a retained source passage." }
        return nil
    }

    /// Return the lowercase SHA-256 fingerprint used to bind retained source and review content.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension EvaluationCase {
    var documentReviewDigest: String? {
        guard var evidence = documentEvidence else { return nil }
        evidence.reviewedDigest = nil
        struct Review: Encodable {
            var prompt: String
            var expected: String
            var criteria: [String]?
            var evidence: EvaluationDocumentEvidence
        }
        guard let data = try? CanonicalJSON.data(for: Review(
            prompt: prompt, expected: expected, criteria: criteriaOverride, evidence: evidence
        ), prettyPrinted: false) else { return nil }
        return EvaluationDocumentEvidence.digest(data)
    }

    var hasReviewedDocument: Bool {
        documentEvidence != nil && documentEvidence?.reviewedDigest != nil
            && documentEvidence?.reviewedDigest == documentReviewDigest
    }

    /// Record the current scoring-content digest so later substantive edits invalidate acceptance.
    mutating func acceptDocumentReview() {
        let digest = documentReviewDigest
        documentEvidence?.reviewedDigest = digest
    }

    var documentValidationIssue: String? {
        guard let evidence = documentEvidence else { return nil }
        if let issue = evidence.validationIssue { return issue }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Document cases need a question and a reviewed reference answer."
        }
        guard let criteriaOverride, (1...4).contains(criteriaOverride.count),
              criteriaOverride.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 4_000 && !$0.contains(where: \.isNewline) }) else {
            return "Document cases need one to four nonempty scoring requirements, each at most 4,000 characters."
        }
        guard conversation.setupTurns.isEmpty, conversation.restoredTranscriptJSON == nil,
              (fieldAssertions ?? []).isEmpty else { return "Document cases support single-turn text questions without field checks." }
        return nil
    }
}

extension EvaluationSuite {
    /// Reject suites whose retained source and case rubrics exceed the aggregate storage budget.
    static func documentContextBudgetIssue(for cases: [EvaluationCase]) -> String? {
        let retainedCharacters = cases.reduce(0) { $0 + ($1.documentEvidence?.contextText.count ?? 0)
            + ($1.criteriaOverride?.joined().count ?? 0) }
        return retainedCharacters > 256_000
            ? "Retained document context and case criteria must total at most 256,000 characters." : nil
    }

    var hasDocumentCases: Bool { cases.contains { $0.documentEvidence != nil } }

    /// Use a case-specific rubric when present, otherwise fall back to the suite rubric.
    func effectiveCriteria(for evaluationCase: EvaluationCase) -> [String] {
        evaluationCase.criteriaOverride ?? rubricCriteria
    }

    /// A transient request configuration, never persisted in place of the original suite.
    func effectiveSuite(for evaluationCase: EvaluationCase) -> Self {
        var result = self
        result.cases = [evaluationCase]
        result.criteria = effectiveCriteria(for: evaluationCase).joined(separator: "\n")
        if let evidence = evaluationCase.documentEvidence {
            result.attachments = [.init(id: evaluationCase.id, name: evidence.sourceName, kind: .text,
                text: evidence.contextText, storedFilename: nil, byteCount: evidence.contextText.utf8.count,
                sha256: EvaluationDocumentEvidence.digest(Data(evidence.contextText.utf8)))]
        }
        return result
    }

    /// Validate case rubrics, evidence, review requirements, and the aggregate retained-context budget.
    func documentValidationIssue(requireReview: Bool = true) -> String? {
        for evaluationCase in cases {
            if let criteria = evaluationCase.criteriaOverride,
               !(1...4).contains(criteria.count) || criteria.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.count > 4_000 || $0.contains(where: \.isNewline) }) {
                return "Case scoring overrides need one to four nonempty requirements of at most 4,000 characters."
            }
        }
        guard hasDocumentCases else { return nil }
        guard scoringMode == .modelJudge, modelConfiguration.referenceMode == .inline,
              modelConfiguration.contextPolicy != .fitReferences, !hasConfiguredTools,
              attachments.isEmpty, features.outputFields.isEmpty, !features.profile.enabled else {
            return "Document cases require AI rubric scoring, strict inline context, and no tools, attachments, profiles, or output schemas."
        }
        if let issue = Self.documentContextBudgetIssue(for: cases) { return issue }
        for evaluationCase in cases where evaluationCase.documentEvidence != nil {
            if let issue = evaluationCase.documentValidationIssue { return issue }
            if requireReview && !evaluationCase.hasReviewedDocument { return "Review the changed source evidence for “\(evaluationCase.name)” before running." }
        }
        return nil
    }
}
