import Foundation

enum EvaluationFieldAssertions {
    static let maximumAssertions = 32

    static func validationIssue(assertions: [EvaluationFieldAssertion], scoringMode: ScoringMode) -> String? {
        guard !assertions.isEmpty else { return nil }
        if scoringMode == .review { return "Field assertions require a scoring mode. Choose Exact text, Contains text, or AI rubric, or remove the assertions." }
        if assertions.count > maximumAssertions { return "Use at most \(maximumAssertions) field assertions per case." }
        if Set(assertions.map(\.id)).count != assertions.count { return "Field assertions must have unique IDs." }
        for (index, assertion) in assertions.enumerated() {
            if let issue = configurationIssue(assertion) { return "Field assertion \(index + 1): \(issue)" }
        }
        return nil
    }

    static func configurationIssue(_ assertion: EvaluationFieldAssertion) -> String? {
        guard pointerTokens(assertion.pointer) != nil else { return "Use a JSON Pointer such as /answer or /items/0. Escape ~ as ~0 and / as ~1." }
        switch assertion.operation {
        case .exists: return nil
        case .containsText:
            return assertion.expectedValue.isEmpty ? "Enter nonempty, case-sensitive text to find." : nil
        case .equals:
            return parse(assertion.expectedValue) == nil ? "Enter one valid JSON value, quoting strings, for example \"Paris\"." : nil
        case .minimum, .maximum:
            guard case .number? = parse(assertion.expectedValue) else { return "Enter a JSON number, without quotes." }
            return nil
        }
    }

    static func evaluate(response: String, assertions: [EvaluationFieldAssertion]) -> [EvaluationFieldAssertionResult] {
        let document = parse(response)
        return assertions.map { assertion in
            func result(_ passed: Bool, _ explanation: String, actual: FieldAssertionJSON? = nil) -> EvaluationFieldAssertionResult {
                .init(assertion: assertion, passed: passed, actualJSON: actual?.jsonString, explanation: explanation)
            }
            if let issue = configurationIssue(assertion) { return result(false, "Invalid assertion: \(issue)") }
            guard let document else { return result(false, "The complete response could not be read as strict JSON. Extra prose, markdown fences, and numbers outside exact decimal precision are not accepted.") }
            guard let tokens = pointerTokens(assertion.pointer), let actual = resolve(tokens, in: document) else {
                return result(false, "No value exists at this JSON Pointer.")
            }
            switch assertion.operation {
            case .exists:
                return result(true, "The value exists, including an explicit null value.", actual: actual)
            case .equals:
                let matches = actual == parse(assertion.expectedValue)
                return result(matches, matches ? "The JSON values are equal." : "The JSON values differ in value or type.", actual: actual)
            case .containsText:
                guard case .string(let text) = actual else { return result(false, "Expected a JSON string; other types are not converted to text.", actual: actual) }
                let matches = text.contains(assertion.expectedValue)
                return result(matches, matches ? "The string contains the required text." : "The string does not contain the required text (case-sensitive).", actual: actual)
            case .minimum, .maximum:
                guard case .number(let number) = actual, case .number(let bound)? = parse(assertion.expectedValue) else {
                    return result(false, "Expected a JSON number; strings and booleans are not numbers.", actual: actual)
                }
                let matches = assertion.operation == .minimum ? number >= bound : number <= bound
                return result(matches, matches ? "The number satisfies the inclusive bound." : "The number is outside the inclusive bound.", actual: actual)
            }
        }
    }

    static func gatedStatus(baseStatus: EvaluationResultStatus, results: [EvaluationFieldAssertionResult]) -> EvaluationResultStatus {
        guard baseStatus == .passed, results.contains(where: { !$0.passed }) else { return baseStatus }
        return .failed
    }

    private static func parse(_ text: String) -> FieldAssertionJSON? {
        guard exactNumbersSupported(in: text) else { return nil }
        return try? JSONDecoder().decode(FieldAssertionJSON.self, from: Data(text.utf8))
    }

    // Reject numeric inputs that Decimal would round, rather than falsely passing equality.
    private static func exactNumbersSupported(in text: String) -> Bool {
        let characters = Array(text)
        var index = 0
        var quoted = false
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\\" { index += 2; continue }
                if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "-" || character.isNumber {
                let start = index
                while index < characters.count, !",]} \t\r\n".contains(characters[index]) { index += 1 }
                let token = String(characters[start..<index])
                let parts = token.lowercased().split(separator: "e", omittingEmptySubsequences: false)
                guard parts.count <= 2 else { return false }
                let exponent: Int
                if parts.count == 2 {
                    guard let parsed = Int(parts[1]) else { return false }
                    exponent = parsed
                } else { exponent = 0 }
                let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
                guard mantissa.count <= 2 else { return false }
                let fractionCount = mantissa.count == 2 ? mantissa[1].count : 0
                var digits = String(parts[0].filter { $0 != "-" && $0 != "." }).drop(while: { $0 == "0" })
                var trailingZeros = 0
                while digits.last == "0" { digits = digits.dropLast(); trailingZeros += 1 }
                if !digits.isEmpty {
                    guard digits.count <= 38, (-1_000...1_000).contains(exponent) else { return false }
                    let effectiveExponent = exponent - fractionCount + trailingZeros
                    guard (-128...127).contains(effectiveExponent) else { return false }
                }
                continue
            }
            index += 1
        }
        return true
    }

    private static func pointerTokens(_ pointer: String) -> [String]? {
        if pointer.isEmpty { return [] }
        guard pointer.first == "/" else { return nil }
        return pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).reduce(into: Optional<[String]>([])) { tokens, raw in
            guard tokens != nil else { return }
            var decoded = ""
            var iterator = raw.makeIterator()
            while let character = iterator.next() {
                if character == "~" {
                    switch iterator.next() {
                    case "0": decoded.append("~")
                    case "1": decoded.append("/")
                    default: tokens = nil; return
                    }
                } else { decoded.append(character) }
            }
            tokens?.append(decoded)
        }
    }

    private static func resolve(_ tokens: [String], in document: FieldAssertionJSON) -> FieldAssertionJSON? {
        var value = document
        for token in tokens {
            switch value {
            case .object(let object):
                guard let next = object[token] else { return nil }
                value = next
            case .array(let array):
                guard !token.isEmpty, token.utf8.allSatisfy({ (48...57).contains($0) }),
                      token == "0" || !token.hasPrefix("0"), let index = Int(token), array.indices.contains(index) else { return nil }
                value = array[index]
            default: return nil
            }
        }
        return value
    }
}

private indirect enum FieldAssertionJSON: Codable, Equatable {
    case null, bool(Bool), string(String), number(Decimal), array([Self]), object([String: Self])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Decimal.self), !value.isNaN { self = .number(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else { self = .object(try container.decode([String: Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var jsonString: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
