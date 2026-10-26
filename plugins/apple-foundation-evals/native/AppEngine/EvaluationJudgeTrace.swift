import Foundation

@available(macOS 27.0, *)
struct EvaluationJudgeTrace: Codable, Sendable {
    var instructions: String
    var prompt: String
    var rawResponse: String? = nil
    var checks: [EvaluationJudgeCriterionTrace]? = nil
    var validationError: String? = nil
    var attempts: [EvaluationJudgeAttemptTrace]? = nil
    var judgedCriterionIndexes: [Int]? = nil
    var refusal: EvaluationRefusalTrace? = nil
}

@available(macOS 27.0, *)
struct EvaluationJudgeAttemptTrace: Codable, Sendable {
    var prompt: String
    var rawResponse: String? = nil
    var validationError: String? = nil
    /// Older traces remain readable; no policy is invented for historical data.
    var requestConfiguration: EvaluationJudgeRequestConfiguration? = nil
    var usage: EvaluationUsage? = nil
    var cost: EvaluationCost? = nil
}

/// The same immutable value drives the wire request and the saved audit trail.
/// Credentials, headers and image bytes deliberately do not belong here.
@available(macOS 27.0, *)
struct EvaluationJudgeRequestConfiguration: Codable, Equatable, Sendable {
    var promptVersion: String
    var instructions: String
    var modelID: String
    var criteriaCount: Int
    var responseFormat: String
    var maximumResponseTokens: Int
    var timeoutSeconds: Double
    var stream: Bool
    var thinking: Bool
}

/// Exact bounded evidence used by the first judge. An absent capture is legacy
/// data; a present capture with nil text records that no tool evidence was sent.
@available(macOS 27.0, *)
struct EvaluationJudgeToolEvidence: Codable, Equatable, Sendable {
    static let maximumUTF8Bytes = 512 * 1_024
    var formatVersion = 1
    var text: String?
    var unavailableReason: String? = nil

    /// Returns captured judge evidence after checking its format version, availability marker, and UTF-8 size limit; throws when replay is unsafe.
    func validatedText() throws -> String? {
        guard formatVersion == 1 else {
            throw EvidenceError.unavailable("The saved judge tool evidence format is unsupported.")
        }
        if let unavailableReason { throw EvidenceError.unavailable(unavailableReason) }
        guard (text?.utf8.count ?? 0) <= Self.maximumUTF8Bytes else {
            throw EvidenceError.unavailable("The saved judge tool evidence exceeds its capture limit.")
        }
        return text
    }

    /// Joins nonempty evidence sections in reference, custom-tool, and built-in-tool order.
    /// Oversized evidence is marked unavailable rather than truncated or replaced, preserving the audit boundary.
    static func capture(reference: String?, custom: String?, builtin: String?) -> Self {
        let parts = [reference, custom, builtin].compactMap { $0 }.filter { !$0.isEmpty }
        let text = parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        guard (text?.utf8.count ?? 0) <= maximumUTF8Bytes else {
            return Self(text: nil, unavailableReason: "The judge tool evidence exceeds its capture limit; the original evidence was not truncated or replaced with summaries.")
        }
        return Self(text: text)
    }

    enum EvidenceError: Error, LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let message): message }
        }
    }
}
