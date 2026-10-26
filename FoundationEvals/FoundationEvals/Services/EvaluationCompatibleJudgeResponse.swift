import Foundation

/// A provider/protocol failure is not a malformed model-authored verdict and
/// must not trigger a JSON-repair request. Content is retained only as evidence.
struct EvaluationCompatibleJudgeResponseFailure: LocalizedError, Sendable {
    enum Kind: Sendable { case provider, incomplete, malformed }
    var kind: Kind
    var statusCode: Int? = nil
    var detail: String
    var rawContent: String? = nil

    var errorDescription: String? { "The judge response failed: \(detail)" }

    var category: String {
        switch kind {
        case .incomplete: return "invalidJudgeOutput"
        case .malformed: return "judgeNetworkFailure"
        case .provider:
            switch statusCode {
            case 429: return "rateLimited"
            case 408: return "timeout"
            case .some(let code) where (400...499).contains(code): return "judgeHTTPFailure"
            default: return "serviceUnavailable"
            }
        }
    }
}

struct EvaluationCompatibleJudgeAttemptFailure: LocalizedError, Sendable {
    var failure: EvaluationCompatibleJudgeResponseFailure
    var attempts: [EvaluationJudgeAttemptTrace]
    var errorDescription: String? { failure.errorDescription }
}

struct EvaluationCompatibleJudgeCompletion: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Message: Decodable, Sendable {
            var content: String?
            /// Creates a completion message while preserving absent text as nil.
            init(content: String?) { self.content = content }
            /// Decodes either string content or concatenated text parts; unrecognized content remains absent.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let text = try? container.decode(String.self, forKey: .content) {
                    content = text
                } else if let parts = try? container.decode([TextPart].self, forKey: .content) {
                    content = parts.compactMap(\.text).joined()
                } else { content = nil }
            }
            private struct TextPart: Decodable { var text: String? }
            private enum CodingKeys: String, CodingKey { case content }
        }
        var message: Message
        var finishReason: String? = nil
        private enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
    }

    /// JSON and SSE share this policy. Invalid telemetry never invalidates a
    /// verdict and is never silently converted to zero.
    struct Usage: Decodable, Sendable {
        var promptTokens: Int?
        var completionTokens: Int?
        var cost: Double?
        /// Decodes usage fields independently so malformed accounting stays unavailable without discarding verdict evidence.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            promptTokens = try? container.decodeIfPresent(Int.self, forKey: .promptTokens)
            completionTokens = try? container.decodeIfPresent(Int.self, forKey: .completionTokens)
            cost = try? container.decodeIfPresent(Double.self, forKey: .cost)
        }
        var hasValidTokenCounts: Bool {
            guard let promptTokens, let completionTokens else { return false }
            return promptTokens >= 0 && completionTokens >= 0
                && !promptTokens.addingReportingOverflow(completionTokens).overflow
        }
        var reportedCost: Double? {
            guard hasValidTokenCounts, let cost, cost.isFinite, cost >= 0 else { return nil }
            return cost
        }
        private enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case cost
        }
    }

    var choices: [Choice]
    var model: String?
    var provider: String?
    var usage: Usage?
    /// Creates a completion envelope with the observed choices, provider identity and optional usage.
    init(choices: [Choice], model: String?, provider: String?, usage: Usage?) {
        self.choices = choices
        self.model = model
        self.provider = provider
        self.usage = usage
    }
    /// Rejects explicit provider errors before decoding completion choices and optional identity metadata.
    /// Malformed usage is ignored independently of the verdict payload.
    init(from decoder: Decoder) throws {
        try EvaluationCompatibleJudgeResponseDecoder.rejectProviderError(in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        choices = try container.decode([Choice].self, forKey: .choices)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        usage = try? container.decodeIfPresent(Usage.self, forKey: .usage)
    }
    private enum CodingKeys: String, CodingKey { case choices, model, provider, usage }
}

enum EvaluationCompatibleJudgeResponseDecoder {
    /// Decodes JSON or an SSE stream and rejects explicit abnormal finish reasons before returning content.
    static func decode(_ data: Data) throws -> EvaluationCompatibleJudgeCompletion {
        let trimmed = data.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        if trimmed.first == 0x7B {
            let response = try JSONDecoder().decode(EvaluationCompatibleJudgeCompletion.self, from: data)
            for choice in response.choices {
                try validateFinishReason(choice.finishReason, content: choice.message.content)
            }
            return response
        }
        return try decodeStream(data)
    }

    /// Collects SSE data events across LF, CRLF or CR separators and returns one assembled completion.
    /// Throws on malformed or provider-failed events, retaining partial content as evidence; a DONE marker is optional.
    private static func decodeStream(_ data: Data) throws -> EvaluationCompatibleJudgeCompletion {
        guard let text = String(data: data, encoding: .utf8) else {
            throw EvaluationCompatibleJudgeResponseFailure(kind: .malformed, detail: "The stream was not valid UTF-8.")
        }
        var content = ""
        var model: String?
        var provider: String?
        var usage: EvaluationCompatibleJudgeCompletion.Usage?
        var sawEvent = false
        var payloadLines: [String] = []

        /// Consumes one buffered SSE event, accumulating content and final metadata while rejecting unexpected choices.
        /// A present malformed usage value invalidates earlier accounting, and failures retain assembled content.
        func consumeEvent() throws {
            guard !payloadLines.isEmpty else { return }
            let payload = payloadLines.joined(separator: "\n")
            payloadLines.removeAll(keepingCapacity: true)
            guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            sawEvent = true
            guard payload.trimmingCharacters(in: .whitespacesAndNewlines) != "[DONE]" else { return }
            do {
                let chunk = try JSONDecoder().decode(StreamChunk.self, from: Data(payload.utf8))
                guard chunk.choices.count <= 1,
                      chunk.choices.allSatisfy({ $0.index == nil || $0.index == 0 }) else {
                    throw EvaluationCompatibleJudgeResponseFailure(kind: .malformed, detail: "The judge stream returned multiple or unexpected choices.")
                }
                if let piece = chunk.choices.first?.delta?.content { content += piece }
                for choice in chunk.choices {
                    try validateFinishReason(choice.finishReason, content: content.isEmpty ? nil : content)
                }
                model = chunk.model ?? model
                provider = chunk.provider ?? provider
                // A malformed present value invalidates earlier partial counts.
                // An absent/null placeholder does not erase final accounting.
                if chunk.hasUsage { usage = chunk.usage }
            } catch var failure as EvaluationCompatibleJudgeResponseFailure {
                if failure.rawContent == nil, !content.isEmpty { failure.rawContent = content }
                throw failure
            } catch {
                throw EvaluationCompatibleJudgeResponseFailure(
                    kind: .malformed, detail: "The stream contained an invalid completion event.",
                    rawContent: content.isEmpty ? nil : content)
            }
        }

        // SSE accepts LF, CRLF, and bare CR. Swift represents CRLF as a
        // single Character, so splitting on LF alone misses those records.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: {
            $0 == "\n" || $0 == "\r\n" || $0 == "\r"
        }) {
            if line.isEmpty {
                try consumeEvent()
            } else if line.hasPrefix("data:") {
                let field = line.dropFirst(5)
                payloadLines.append(String(field.first == " " ? field.dropFirst() : field))
            }
        }
        try consumeEvent()
        guard sawEvent else {
            throw EvaluationCompatibleJudgeResponseFailure(kind: .malformed, detail: "The response did not contain a completion event.")
        }
        // Compatible endpoints may close without [DONE]. Do not require one
        // provider's marker, but inspect every explicit failure before success.
        return EvaluationCompatibleJudgeCompletion(
            choices: [.init(message: .init(content: content.isEmpty ? nil : content))],
            model: model, provider: provider, usage: usage)
    }

    /// Accepts absent finish reasons and known success reasons; throws provider or incomplete-output failures for other reasons.
    private static func validateFinishReason(_ reason: String?, content: String?) throws {
        guard let reason, !reason.isEmpty else { return }
        switch reason {
        case "stop", "end_turn", "completed": return
        case "error":
            throw EvaluationCompatibleJudgeResponseFailure(kind: .provider,
                detail: "The provider terminated generation with an error.", rawContent: content)
        default:
            throw EvaluationCompatibleJudgeResponseFailure(kind: .incomplete,
                detail: "Generation did not complete normally (finish_reason: \(String(reason.prefix(80)))).", rawContent: content)
        }
    }

    /// Throws a bounded provider failure when a non-null error field is present, accepting object or string error messages.
    fileprivate static func rejectProviderError(in decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProviderKeys.self)
        guard container.contains(.error), try !container.decodeNil(forKey: .error) else { return }
        let failure = try? container.decode(ProviderError.self, forKey: .error)
        let rawMessage = failure?.message
            ?? (try? container.decode(String.self, forKey: .error))
            ?? "The provider reported an error."
        let detail = rawMessage.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        throw EvaluationCompatibleJudgeResponseFailure(kind: .provider,
            statusCode: failure?.code, detail: String(detail.prefix(512)))
    }

    private enum ProviderKeys: String, CodingKey { case error }
    private struct ProviderError: Decodable {
        var code: Int?
        var message: String?
        /// Decodes provider error codes from integers or numeric strings and retains an optional message.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = (try? container.decode(Int.self, forKey: .code))
                ?? (try? container.decode(String.self, forKey: .code)).flatMap(Int.init)
            message = try? container.decode(String.self, forKey: .message)
        }
        private enum CodingKeys: String, CodingKey { case code, message }
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: String? }
            var delta: Delta?
            var index: Int?
            var finishReason: String?
            private enum CodingKeys: String, CodingKey {
                case delta, index
                case finishReason = "finish_reason"
            }
        }
        var choices: [Choice]
        var model: String?
        var provider: String?
        var usage: EvaluationCompatibleJudgeCompletion.Usage?
        var hasUsage: Bool
        /// Decodes one SSE chunk after rejecting provider errors, distinguishing absent usage from a malformed present value.
        init(from decoder: Decoder) throws {
            try EvaluationCompatibleJudgeResponseDecoder.rejectProviderError(in: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
            model = try container.decodeIfPresent(String.self, forKey: .model)
            provider = try container.decodeIfPresent(String.self, forKey: .provider)
            hasUsage = try container.contains(.usage) && !container.decodeNil(forKey: .usage)
            usage = try? container.decodeIfPresent(EvaluationCompatibleJudgeCompletion.Usage.self, forKey: .usage)
        }
        private enum CodingKeys: String, CodingKey { case choices, model, provider, usage }
    }
}
