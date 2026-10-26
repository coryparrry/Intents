import Foundation

/// An explicit exact-output rubric grammar, not a natural-language requirement extractor.
///
/// Accepted whole lines (after trimming surrounding whitespace):
/// - `exact: <JSON string>`
/// - `The final response is exactly <JSON string>.`
/// - `The response is exactly <JSON string>.`
///
/// The two sentence forms also accept a conservative unquoted status literal: one to eight
/// space-separated words using only ASCII uppercase letters, digits, spaces, `_`, or `-`,
/// up to 256 characters, with no logical/conjunction tokens. Quote other literal values.
@available(macOS 27.0, *)
enum EvaluationExactCriterion {
    private static let sentencePrefixes = [
        "The final response is exactly ",
        "The response is exactly "
    ]
    private static let forbiddenTokens: Set<String> = [
        "AND", "OR", "IF", "UNLESS", "EXCEPT", "BUT", "THEN"
    ]

    /// Parses only the documented whole-line exact-output grammar; returns nil for unsupported or ambiguous requirements.
    static func expectedText(in criterion: String) -> String? {
        let line = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("exact:") {
            let literal = String(line.dropFirst("exact:".count))
                .trimmingCharacters(in: .whitespaces)
            return decodeJSONString(literal)
        }
        for prefix in sentencePrefixes where line.hasPrefix(prefix) && line.hasSuffix(".") {
            let literal = String(line.dropFirst(prefix.count).dropLast())
            if let decoded = decodeJSONString(literal) { return decoded }
            return unquotedStatus(literal)
        }
        return nil
    }

    /// Produces a deterministic 4-or-1 criterion score for recognized exact-output requirements.
    /// Comparison preserves all response case, punctuation, and whitespace; unrecognized criteria return nil.
    static func check(criterion: String, index: Int, response: String) -> EvaluationJudgeCriterionTrace? {
        guard let expected = expectedText(in: criterion) else { return nil }
        let matches = response == expected
        return EvaluationJudgeCriterionTrace(
            criterionIndex: index,
            criterion: criterion,
            score: matches ? 4 : 1,
            rationale: matches
                ? "The application verified that the whole response exactly matches the required text."
                : "The application verified that the whole response differs from the required text. Equality preserves case, punctuation, and whitespace.",
            exactComparisons: [.init(expectedText: expected, matches: matches)]
        )
    }

    /// Decodes a complete JSON string literal, returning nil for malformed literals or non-string JSON.
    private static func decodeJSONString(_ literal: String) -> String? {
        guard literal.first == "\"" else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(literal.utf8))
    }

    /// Accepts bounded uppercase status literals while rejecting conjunction tokens that could encode compound requirements.
    private static func unquotedStatus(_ literal: String) -> String? {
        guard !literal.isEmpty, literal.count <= 256,
              literal == literal.trimmingCharacters(in: .whitespaces),
              literal.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (48...57).contains(byte)
                      || byte == 32 || byte == 95 || byte == 45
              }) else { return nil }
        let words = literal.split(separator: " ")
        guard (1...8).contains(words.count),
              words.allSatisfy({ !forbiddenTokens.contains(String($0)) }) else { return nil }
        return literal
    }
}
