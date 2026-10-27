import Foundation

struct EvaluationDocumentSemanticAttempt: Codable, Sendable {
    var batchID: String
    var attempt: Int
    var question: String?
    var answer: String?
    var criteria: [String]?
    var supportingQuotes: [String]? = nil
    var candidateDigest: String?
    var review: EvaluationDocumentSemanticReview?
    var outcome: String
    var issue: String?
}

enum EvaluationDocumentDraftPipeline {
    typealias Generator = @Sendable (EvaluationDocumentSource, EvaluationDocumentPassage, String, [String], String?) async throws -> EvaluationCase?
    typealias Recorder = @MainActor (EvaluationDocumentSemanticAttempt) throws -> Void
    static let maximumAttempts = 3
    struct Result: Sendable {
        var candidate: EvaluationCase?
        var review: EvaluationDocumentSemanticReview?
    }
    struct ReviewUnavailable: LocalizedError {
        var message: String
        var errorDescription: String? { "Semantic review stopped: \(message) No unreviewed draft was accepted." }
    }

    static func generate(source: EvaluationDocumentSource, passage: EvaluationDocumentPassage,
                         questionType: String, existingQuestions: [String], batchID: String,
                         generator: Generator = EvaluationDocumentGenerator.generate,
                         reviewer: EvaluationDocumentSemanticReviewer.Reviewer,
                         record: Recorder) async throws -> Result {
        var feedback: String?
        for attempt in 1...maximumAttempts {
            try Task.checkCancellation()
            let candidate: EvaluationCase?
            do {
                candidate = try await generator(source, passage, questionType, existingQuestions, feedback)
            } catch let failure as EvaluationDocumentGenerator.InvalidDraft {
                try Task.checkCancellation()
                try await record(.init(batchID: batchID, attempt: attempt, question: failure.candidate.question,
                    answer: failure.candidate.answer, criteria: failure.candidate.criteria,
                    supportingQuotes: failure.candidate.quotes, outcome: "validation_rejected", issue: failure.issue))
                struct InvalidFeedback: Encodable { var question: String; var answer: String; var quotes: [String]; var defects: String }
                feedback = String(decoding: try CanonicalJSON.data(for: InvalidFeedback(question: failure.candidate.question,
                    answer: failure.candidate.answer, quotes: failure.candidate.quotes, defects: failure.issue), prettyPrinted: false), as: UTF8.self)
                continue
            }
            try Task.checkCancellation()
            guard let candidate else {
                try await record(.init(batchID: batchID, attempt: attempt, outcome: "unsupported_or_duplicate"))
                return .init(candidate: nil, review: nil)
            }
            var event = EvaluationDocumentSemanticAttempt(batchID: batchID, attempt: attempt,
                question: candidate.prompt, answer: candidate.expected, criteria: candidate.criteriaOverride,
                candidateDigest: candidate.documentReviewDigest, outcome: "review_error")
            let review: EvaluationDocumentSemanticReview
            do {
                review = try await reviewer(candidate, source, existingQuestions)
                try Task.checkCancellation()
                guard review.candidateDigest == candidate.documentReviewDigest,
                      (review.reviewedQuestions ?? []) == EvaluationDocumentSemanticReviewer.questionDigests(existingQuestions) else {
                    throw ReviewUnavailable(message: "The verdict belongs to a different draft or question context.")
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                event.issue = error.localizedDescription
                try await record(event)
                throw ReviewUnavailable(message: error.localizedDescription)
            }
            event.review = review
            event.outcome = review.matches(candidate) ? "accepted" : "rejected"
            event.issue = review.accepted ? nil : review.feedback
            try await record(event)
            try Task.checkCancellation()
            if review.matches(candidate) { return .init(candidate: candidate, review: review) }
            struct Feedback: Encodable { var question: String; var answer: String; var defects: String }
            feedback = String(decoding: try CanonicalJSON.data(for: Feedback(question: candidate.prompt,
                answer: candidate.expected, defects: review.feedback), prettyPrinted: false), as: UTF8.self)
        }
        return .init(candidate: nil, review: nil)
    }
}
