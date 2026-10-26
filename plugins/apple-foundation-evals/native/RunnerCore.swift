import Foundation

let nativeModelName = "Apple Foundation Models"

enum RunnerLimits {
    static let inputBytes = 1_048_576
    static let cases = 100
    static let generations = 100
    static let instructionsBytes = 16_384
    static let caseTextBytes = 32_768
    static let expandedPromptBytes = 524_288
    static let outputTokenBudget = 65_536
}

struct RunnerFailure: Error, Codable {
    let kind: String
    let message: String

    /// Creates an invalid-input failure containing the supplied validation message.
    static func validation(_ message: String) -> RunnerFailure {
        RunnerFailure(kind: "invalidInput", message: message)
    }

    /// Classifies cancellation separately from other generation failures while preserving the localized error message.
    static func unclassifiedGenerationError(_ error: Error) -> RunnerFailure {
        RunnerFailure(kind: error is CancellationError ? "cancelled" : "generationError", message: error.localizedDescription)
    }
}

enum Scoring: String, Codable, Sendable {
    case exact, contains, none

    /// Returns strict whole-string equality or case-sensitive substring scoring, leaving pass and score nil when scoring is disabled or expected text is absent.
    func assess(response: String, expected: String?) -> (passed: Bool?, score: Double?) {
        guard self != .none, let expected else { return (nil, nil) }
        let passed = self == .exact ? response == expected : response.contains(expected)
        return (passed, passed ? 1 : 0)
    }
}

struct LegacyEvaluationCase: Codable {
    let id: String
    let prompt: String
    let expected: String?
    let scoring: Scoring
}

struct EvaluationRequest: Decodable {
    let operation: String
    let instructions: String
    let cases: [LegacyEvaluationCase]
    let repetitions: Int
    let temperature: Double
    let maxTokens: Int

    /// Validates legacy evaluation settings, unique case IDs, scoring requirements, byte limits, generation count, and total token and prompt budgets.
    /// Throws an invalid-input failure describing the first violated admission rule.
    func validate() throws {
        guard operation == "evaluate" else { throw RunnerFailure.validation("Unsupported operation.") }
        guard (1...10).contains(repetitions) else { throw RunnerFailure.validation("repetitions must be an integer from 1 to 10.") }
        guard temperature.isFinite, (0...2).contains(temperature) else { throw RunnerFailure.validation("temperature must be from 0 to 2.") }
        guard (1...4096).contains(maxTokens) else { throw RunnerFailure.validation("maxTokens must be an integer from 1 to 4096.") }
        guard (1...RunnerLimits.cases).contains(cases.count), cases.count * repetitions <= RunnerLimits.generations else {
            throw RunnerFailure.validation("A run requires 1...100 cases and at most 100 generations.")
        }
        guard cases.count * repetitions * maxTokens <= RunnerLimits.outputTokenBudget else {
            throw RunnerFailure.validation("The total requested output budget exceeds 65536 tokens.")
        }
        guard instructions.utf8.count <= RunnerLimits.instructionsBytes else {
            throw RunnerFailure.validation("instructions exceeds 16384 UTF-8 bytes.")
        }
        var ids = Set<String>()
        var promptBytes = 0
        for item in cases {
            guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.id.utf8.count <= 256, ids.insert(item.id).inserted else {
                throw RunnerFailure.validation("Case IDs must be nonempty, unique, and at most 256 UTF-8 bytes.")
            }
            guard !item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.prompt.utf8.count <= RunnerLimits.caseTextBytes else {
                throw RunnerFailure.validation("Each prompt must be nonempty and at most 32768 UTF-8 bytes.")
            }
            guard (item.expected?.utf8.count ?? 0) <= RunnerLimits.caseTextBytes else {
                throw RunnerFailure.validation("Each expected response must be at most 32768 UTF-8 bytes.")
            }
            if item.scoring != .none, item.expected == nil || item.expected?.isEmpty == true {
                throw RunnerFailure.validation("exact and contains scoring require a nonempty expected response.")
            }
            promptBytes += instructions.utf8.count + item.prompt.utf8.count
        }
        guard promptBytes * repetitions <= RunnerLimits.expandedPromptBytes else {
            throw RunnerFailure.validation("Expanded instructions and prompts exceed 524288 UTF-8 bytes per run.")
        }
    }
}

enum RunnerRequest {
    case availability
    case evaluate(EvaluationRequest)

    /// Parses a bounded JSON object into availability or a validated legacy evaluation request.
    /// Rejects unknown operations, unsupported fields, missing or invalid types, and legacy admission-limit violations.
    static func parse(_ data: Data) throws -> RunnerRequest {
        guard data.count <= RunnerLimits.inputBytes else { throw RunnerFailure.validation("Input exceeds 1048576 bytes.") }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RunnerFailure.validation("Input must be one JSON object.")
            }
            object = decoded
        } catch let failure as RunnerFailure { throw failure }
        catch { throw RunnerFailure.validation("Input must be one valid JSON object.") }
        switch object["operation"] as? String {
        case "availability":
            guard Set(object.keys) == ["operation"] else { throw RunnerFailure.validation("availability accepts only operation.") }
            return .availability
        case "evaluate":
            let fields: Set<String> = ["operation", "instructions", "cases", "repetitions", "temperature", "maxTokens"]
            guard Set(object.keys) == fields else { throw RunnerFailure.validation("evaluate requires operation, instructions, cases, repetitions, temperature, and maxTokens only.") }
            if let items = object["cases"] as? [[String: Any]] {
                let allowed: Set<String> = ["id", "prompt", "expected", "scoring"]
                guard items.allSatisfy({ Set($0.keys).isSubset(of: allowed) }) else { throw RunnerFailure.validation("Case contains unsupported fields.") }
            }
            do {
                let request = try JSONDecoder().decode(EvaluationRequest.self, from: data)
                try request.validate()
                return .evaluate(request)
            } catch let failure as RunnerFailure { throw failure }
            catch { throw RunnerFailure.validation("evaluate fields have invalid or missing types.") }
        default:
            throw RunnerFailure.validation("operation must be availability or evaluate.")
        }
    }
}

/// Preserves Apple's Codable transcript representation without inventing a schema.
indirect enum JSONValue: Codable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), unsigned(UInt64), number(Double), bool(Bool), null

    /// Decodes arbitrary JSON values, preferring booleans and integer representations before floating-point numbers and recursively decoding containers.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(UInt64.self) { self = .unsigned(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    /// Encodes the stored JSON kind without adding wrapper fields.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct EvaluationTrace: Encodable, Sendable {
    let transcript: [JSONValue]
    let error: RunnerFailure?
    var appSample: JSONValue? = nil
}

struct EvaluationResult: Encodable, Sendable {
    let caseId: String
    let repetition: Int
    let prompt: String
    let expected: String?
    let response: String
    let passed: Bool?
    let score: Double?
    let durationMs: Double
    let trace: EvaluationTrace

    enum CodingKeys: String, CodingKey { case caseId, repetition, prompt, expected, response, passed, score, durationMs, trace }

    /// Encodes a compatibility sample, omitting absent expected text while preserving explicit null pass and score values.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(caseId, forKey: .caseId)
        try container.encode(repetition, forKey: .repetition)
        try container.encode(prompt, forKey: .prompt)
        try container.encodeIfPresent(expected, forKey: .expected)
        try container.encode(response, forKey: .response)
        try container.encode(passed, forKey: .passed)
        try container.encode(score, forKey: .score)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(trace, forKey: .trace)
    }
}

struct EvaluationOutput: Encodable, Sendable {
    let status: String
    let model = nativeModelName
    let startedAt: String
    let finishedAt: String
    let durationMs: Double
    let results: [EvaluationResult]
    let error: RunnerFailure?

    /// Creates a failed run output with no results, wall-clock timestamps, and monotonic elapsed duration.
    static func failed(_ failure: RunnerFailure, started: Date, uptime: TimeInterval) -> EvaluationOutput {
        EvaluationOutput(status: "failed", startedAt: timestamp(started), finishedAt: timestamp(Date()),
                         durationMs: elapsedMilliseconds(since: uptime), results: [], error: failure)
    }
}

/// Formats a date as an ISO 8601 timestamp including fractional seconds.
func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// Returns nonnegative elapsed milliseconds from a system-uptime reading.
func elapsedMilliseconds(since start: TimeInterval) -> Double {
    max(0, (ProcessInfo.processInfo.systemUptime - start) * 1000)
}
