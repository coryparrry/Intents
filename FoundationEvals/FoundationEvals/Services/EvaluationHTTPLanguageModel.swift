import Foundation
import FoundationModels

/// Saved settings for a developer-owned Foundation Models provider on this Mac.
///
/// The suite keeps this optional and selects it explicitly. Constructing the value does not
/// contact the endpoint; the executor performs one request only when a model response is run.
struct EvaluationCustomProviderConfiguration: Codable, Equatable, Hashable, Sendable {
    static let defaultEndpoint = "http://127.0.0.1:19096/generate"
    static let reservedMCPPort = 17_873

    var endpoint = defaultEndpoint
    /// Optional endpoint that accepts the generation envelope and returns the
    /// provider's exact input-token count before generation.
    var tokenizerEndpoint: String? = nil
    var contextSize = 8_192
    var supportsVision = false
    var supportsGuidedGeneration = false
    var supportsReasoning = false
    var supportsToolCalling = false
    var requestTimeoutSeconds = 30.0

    var capabilities: LanguageModelCapabilities {
        var declared: [LanguageModelCapabilities.Capability] = []
        if supportsVision { declared.append(.vision) }
        if supportsGuidedGeneration { declared.append(.guidedGeneration) }
        if supportsReasoning { declared.append(.reasoning) }
        if supportsToolCalling { declared.append(.toolCalling) }
        return LanguageModelCapabilities(declared)
    }

    var capabilityNames: [String] {
        [
            supportsVision ? "vision" : nil,
            supportsGuidedGeneration ? "guided generation" : nil,
            supportsReasoning ? "reasoning" : nil,
            supportsToolCalling ? "tool calling" : nil
        ].compactMap { $0 }
    }

    var protocolCapabilityNames: [String] {
        [
            supportsVision ? "vision" : nil,
            supportsGuidedGeneration ? "guidedGeneration" : nil,
            supportsReasoning ? "reasoning" : nil,
            supportsToolCalling ? "toolCalling" : nil
        ].compactMap { $0 }
    }

    var validationIssue: String? {
        guard (1...262_144).contains(contextSize) else {
            return "Custom provider context size must be between 1 and 262,144 tokens."
        }
        guard requestTimeoutSeconds.isFinite, (0.1...60).contains(requestTimeoutSeconds) else {
            return "Custom provider timeout must be between 0.1 and 60 seconds."
        }
        guard endpoint.utf8.count <= 2_048 else {
            return "Custom provider endpoint must be 2,048 UTF-8 bytes or fewer."
        }
        guard let components = URLComponents(string: endpoint),
              components.scheme == "http",
              components.host == "127.0.0.1",
              let port = components.port,
              (1...65_535).contains(port),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return "Custom provider endpoint must use literal http://127.0.0.1:<port>/... without credentials, a query, or a fragment."
        }
        guard port != Self.reservedMCPPort else {
            return "Port \(Self.reservedMCPPort) is reserved for the Intents MCP server."
        }
        if let tokenizerEndpoint, !tokenizerEndpoint.isEmpty {
            guard tokenizerEndpoint.utf8.count <= 2_048 else {
                return "Custom provider tokenizer endpoint must be 2,048 UTF-8 bytes or fewer."
            }
            guard let tokenizerComponents = URLComponents(string: tokenizerEndpoint),
                  tokenizerComponents.scheme == "http",
                  tokenizerComponents.host == "127.0.0.1",
                  let tokenizerPort = tokenizerComponents.port,
                  (1...65_535).contains(tokenizerPort),
                  tokenizerComponents.user == nil,
                  tokenizerComponents.password == nil,
                  tokenizerComponents.query == nil,
                  tokenizerComponents.fragment == nil else {
                return "Custom provider tokenizer endpoint must use literal http://127.0.0.1:<port>/... without credentials, a query, or a fragment."
            }
            if tokenizerPort == Self.reservedMCPPort {
                return "Port \(Self.reservedMCPPort) is reserved for the Intents MCP server."
            }
        }
        return nil
    }

    var validatedEndpoint: URL? {
        guard validationIssue == nil else { return nil }
        return URL(string: endpoint)
    }

    var validatedTokenizerEndpoint: URL? {
        guard validationIssue == nil,
              let tokenizerEndpoint,
              !tokenizerEndpoint.isEmpty else { return nil }
        return URL(string: tokenizerEndpoint)
    }
}

/// A Foundation Models `LanguageModel` whose inference is supplied by a local HTTP process.
struct EvaluationHTTPLanguageModel: LanguageModel {
    typealias Executor = EvaluationHTTPLanguageModelExecutor

    let configuration: EvaluationCustomProviderConfiguration
    /// Explicit subject input ceiling; judge requests retain their own context budget.
    let maximumInputTokens: Int?
    let liveResponseObserver: EvaluationHTTPLiveResponseObserver?

    /// Stores local provider settings, the optional subject input ceiling, and a live-response observer without making a request.
    init(
        configuration: EvaluationCustomProviderConfiguration,
        maximumInputTokens: Int? = nil,
        liveResponseObserver: EvaluationHTTPLiveResponseObserver? = nil
    ) {
        self.configuration = configuration
        self.maximumInputTokens = maximumInputTokens
        self.liveResponseObserver = liveResponseObserver
    }

    var capabilities: LanguageModelCapabilities { configuration.capabilities }
    var executorConfiguration: Executor.Configuration {
        .init(provider: configuration, maximumInputTokens: maximumInputTokens,
              liveResponseObserver: liveResponseObserver)
    }
    var contextSize: Int { configuration.contextSize }
}

struct EvaluationHTTPLiveResponseUpdate: Sendable {
    var caseID: UUID
    var repetition: Int
    var role: String?
    var setupTurn: Int?
    var content: String
}

final class EvaluationHTTPLiveResponseObserver: Hashable, Sendable {
    static let firstContentMetadataKey = "foundationEvalsFirstContentMilliseconds"
    static let generationStartedMetadataKey = "foundationEvalsGenerationStarted"

    private let handler: @Sendable (EvaluationHTTPLiveResponseUpdate) async -> Void

    /// Retains an asynchronous callback for publishing provider response snapshots.
    init(handler: @escaping @Sendable (EvaluationHTTPLiveResponseUpdate) async -> Void) {
        self.handler = handler
    }

    /// Awaits the observer callback with the latest accumulated response content and case metadata.
    func publish(_ update: EvaluationHTTPLiveResponseUpdate) async {
        await handler(update)
    }

    /// Compares observer instances by identity so distinct callbacks remain distinct executor configurations.
    static func == (lhs: EvaluationHTTPLiveResponseObserver, rhs: EvaluationHTTPLiveResponseObserver) -> Bool {
        lhs === rhs
    }

    /// Hashes object identity to match observer equality.
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

struct EvaluationHTTPLanguageModelExecutionConfiguration: Hashable, Sendable {
    var provider: EvaluationCustomProviderConfiguration
    var maximumInputTokens: Int? = nil
    var liveResponseObserver: EvaluationHTTPLiveResponseObserver?
}

struct EvaluationHTTPLanguageModelExecutor: LanguageModelExecutor {
    typealias Model = EvaluationHTTPLanguageModel
    typealias Configuration = EvaluationHTTPLanguageModelExecutionConfiguration

    private static let maximumRequestBytes = 8 * 1_024 * 1_024
    private static let maximumTokenizationResponseBytes = 64 * 1_024
    private static let maximumResponseBytes = 8 * 1_024 * 1_024
    private static let maximumEventBytes = 1 * 1_024 * 1_024

    private let configuration: EvaluationCustomProviderConfiguration
    private let maximumInputTokens: Int?
    private let liveResponseObserver: EvaluationHTTPLiveResponseObserver?

    /// Validates provider settings and a positive optional input ceiling before creating an executor.
    init(configuration: Configuration) throws {
        if let issue = configuration.provider.validationIssue {
            throw EvaluationHTTPProviderError.invalidConfiguration(issue)
        }
        if let limit = configuration.maximumInputTokens, limit < 1 {
            throw EvaluationHTTPProviderError.invalidConfiguration("The input token limit must be positive.")
        }
        self.configuration = configuration.provider
        self.maximumInputTokens = configuration.maximumInputTokens
        self.liveResponseObserver = configuration.liveResponseObserver
    }

    /// Performs no HTTP work because the local-provider protocol defines no prewarm request.
    func prewarm(model: Model, transcript: Transcript) {
        // A local HTTP provider has no common prewarm contract. In particular, this hook must
        // not make unsolicited requests merely because the Foundation Models session prewarms.
    }

    /// Sends a bounded generation envelope and streams validated NDJSON commands into the model channel.
    ///
    /// When configured, the tokenizer endpoint admits the assembled request before generation.
    /// The per-request session is invalidated on every exit. Cancellation, malformed events,
    /// transport failures, byte-limit violations, and streams without response or tool-call output
    /// throw. First visible content records latency; response mutations publish to the optional observer.
    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: Model,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let started = ContinuousClock.now
        try Task.checkCancellation()
        guard let endpoint = configuration.validatedEndpoint else {
            throw EvaluationHTTPProviderError.invalidConfiguration(
                configuration.validationIssue ?? "The custom provider endpoint is invalid."
            )
        }

        let body = try EvaluationHTTPGenerationRequest.makeBody(
            from: request,
            configuration: configuration
        )
        guard body.count <= Self.maximumRequestBytes else {
            throw EvaluationHTTPProviderError.requestTooLarge(maximum: Self.maximumRequestBytes)
        }
        if let tokenizerEndpoint = configuration.validatedTokenizerEndpoint {
            let requestRole = request.metadata["role"].flatMap {
                try? JSONDecoder().decode(String.self, from: Data($0.jsonString.utf8))
            }
            try await Self.validateTokenBudget(
                body: body,
                endpoint: tokenizerEndpoint,
                request: request,
                maximumInputTokens: requestRole == "judge" ? nil : maximumInputTokens,
                contextSize: configuration.contextSize,
                timeout: configuration.requestTimeoutSeconds
            )
        }

        let session = EvaluationHTTPPolicy.isolatedSession(timeout: configuration.requestTimeoutSeconds)
        defer { session.invalidateAndCancel() }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = configuration.requestTimeoutSeconds
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let response = response as? HTTPURLResponse else {
            throw EvaluationHTTPProviderError.invalidHTTPResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw EvaluationHTTPProviderError.httpStatus(response.statusCode)
        }

        var responseEventCount = 0
        var firstContentMilliseconds: Double?
        var liveResponse = EvaluationHTTPResponseAccumulator()

        /// Validates and sends one event, then accumulates response content and publishes first-content timing and live updates.
        func consume(_ line: Data) async throws {
            guard let command = try Self.command(
                fromLine: line,
                expectsGuidedResponse: request.schema != nil
            ) else { return }
            if command.producesResponseOrToolCall { responseEventCount += 1 }
            try await command.send(into: channel)
            guard let mutation = command.responseMutation else { return }
            let content = liveResponse.apply(mutation)
            if firstContentMilliseconds == nil, Self.isVisibleContent(content) {
                let measurement = Self.firstContentMilliseconds(
                    started: started,
                    metadata: request.metadata
                )
                firstContentMilliseconds = measurement
                await channel.send(.response(
                    entryID: mutation.entryID,
                    action: .updateMetadata([
                        EvaluationHTTPLiveResponseObserver.firstContentMetadataKey: measurement
                    ])
                ))
            }
            if let update = Self.liveResponseUpdate(content: content, metadata: request.metadata) {
                await liveResponseObserver?.publish(update)
            }
        }

        var buffer = EvaluationHTTPNDJSONBuffer(
            maximumEventBytes: Self.maximumEventBytes,
            maximumResponseBytes: Self.maximumResponseBytes
        )
        for try await byte in bytes {
            try Task.checkCancellation()
            if let line = try buffer.append(byte) {
                try await consume(line)
            }
        }
        if let finalLine = buffer.finish() {
            try await consume(finalLine)
        }
        try Task.checkCancellation()

        guard responseEventCount > 0 else {
            throw EvaluationHTTPProviderError.missingOutputEvent
        }
    }

    /// Asks the provider tokenizer to count the complete envelope and validates its usage fields.
    ///
    /// Enforces the optional subject input ceiling and reserves requested response tokens within
    /// `contextSize`. Invalid counts, HTTP failures, oversized replies, cancellation, or insufficient
    /// headroom throw before generation. The tokenizer session is invalidated on exit.
    private static func validateTokenBudget(
        body: Data,
        endpoint: URL,
        request: LanguageModelExecutorGenerationRequest,
        maximumInputTokens: Int?,
        contextSize: Int,
        timeout: TimeInterval
    ) async throws {
        let session = EvaluationHTTPPolicy.isolatedSession(timeout: timeout)
        defer { session.invalidateAndCancel() }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = timeout
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let response = response as? HTTPURLResponse else {
            throw EvaluationHTTPProviderError.invalidHTTPResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw EvaluationHTTPProviderError.httpStatus(response.statusCode)
        }
        let data = try await boundedData(
            from: bytes,
            maximumBytes: maximumTokenizationResponseBytes
        )
        let tokenization: EvaluationHTTPTokenizationResponse
        do {
            tokenization = try JSONDecoder().decode(EvaluationHTTPTokenizationResponse.self, from: data)
        } catch {
            throw EvaluationHTTPProviderError.invalidTokenizationResponse(error.localizedDescription)
        }
        guard tokenization.inputTokens >= 0 else {
            throw EvaluationHTTPProviderError.invalidTokenizationResponse(
                "inputTokens must not be negative."
            )
        }
        guard tokenization.cachedInputTokens >= 0,
              tokenization.cachedInputTokens <= tokenization.inputTokens else {
            throw EvaluationHTTPProviderError.invalidTokenizationResponse(
                "cachedInputTokens must be between zero and inputTokens."
            )
        }
        if let maximumInputTokens, tokenization.inputTokens > maximumInputTokens {
            throw EvaluationHTTPProviderError.backend(
                code: "contextSizeExceeded",
                message: "The provider tokenizer measured \(tokenization.inputTokens) input tokens, exceeding the configured input limit of \(maximumInputTokens) tokens."
            )
        }
        let responseReserve = request.generationOptions.maximumResponseTokens ?? 0
        let totalTokens = tokenization.inputTokens.saturatedAdding(responseReserve)
        guard totalTokens <= contextSize else {
            throw EvaluationHTTPProviderError.backend(
                code: "contextSizeExceeded",
                message: "The provider tokenizer measured \(tokenization.inputTokens) input tokens, leaving insufficient context for the requested response."
            )
        }
    }

    /// Collects asynchronous bytes up to the inclusive byte limit, throwing on overflow or cancellation.
    static func boundedData<Bytes: AsyncSequence>(
        from bytes: Bytes,
        maximumBytes: Int
    ) async throws -> Data where Bytes.Element == UInt8 {
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 4_096))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else {
                throw EvaluationHTTPProviderError.responseTooLarge(maximum: maximumBytes)
            }
            data.append(byte)
        }
        return data
    }

    /// Treats trimmed nonempty content other than `{}` and `null` as visible for latency measurement.
    private static func isVisibleContent(_ content: String) -> Bool {
        let visible = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !visible.isEmpty && visible != "{}" && visible != "null"
    }

    /// Measures from supplied generation-start wall time when present, clamped to zero, otherwise from executor monotonic start.
    private static func firstContentMilliseconds(
        started: ContinuousClock.Instant,
        metadata: [String: any ConvertibleToGeneratedContent]
    ) -> Double {
        if let generationStarted = metadata.doubleValue(
            forKey: EvaluationHTTPLiveResponseObserver.generationStartedMetadataKey
        ) {
            return max(0, (Date().timeIntervalSinceReferenceDate - generationStarted) * 1_000)
        }
        return started.evaluationMilliseconds(to: .now)
    }

    /// Builds a live response update only when case UUID and repetition metadata decode successfully.
    private static func liveResponseUpdate(
        content: String,
        metadata: [String: any ConvertibleToGeneratedContent]
    ) -> EvaluationHTTPLiveResponseUpdate? {
        guard let caseID = metadata.uuidValue(forKey: "evalCaseID"),
              let repetition = metadata.intValue(forKey: "repetition") else {
            return nil
        }
        return EvaluationHTTPLiveResponseUpdate(
            caseID: caseID,
            repetition: repetition,
            role: metadata.stringValue(forKey: "role"),
            setupTurn: metadata.intValue(forKey: "setupTurn"),
            content: content
        )
    }

    /// Ignores blank NDJSON lines, removes a trailing carriage return, and decodes and validates an event command.
    private static func command(
        fromLine encodedLine: Data,
        expectsGuidedResponse: Bool
    ) throws -> EvaluationHTTPChannelCommand? {
        var encodedLine = encodedLine
        if encodedLine.last == 0x0D { encodedLine.removeLast() }
        guard encodedLine.contains(where: { $0 != 0x09 && $0 != 0x20 }) else { return nil }
        let event: EvaluationHTTPGenerationEvent
        do {
            event = try JSONDecoder().decode(EvaluationHTTPGenerationEvent.self, from: encodedLine)
        } catch {
            throw EvaluationHTTPProviderError.invalidEvent(error.localizedDescription)
        }
        return try event.command(expectsGuidedResponse: expectsGuidedResponse)
    }
}

private extension Dictionary where Key == String, Value == any ConvertibleToGeneratedContent {
    /// Decodes a generated-content metadata value as a string, returning nil for missing or incompatible values.
    func stringValue(forKey key: String) -> String? {
        guard let json = self[key]?.generatedContent.jsonString else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(json.utf8))
    }

    /// Decodes a generated-content metadata value as an integer, returning nil for missing or incompatible values.
    func intValue(forKey key: String) -> Int? {
        guard let json = self[key]?.generatedContent.jsonString else { return nil }
        return try? JSONDecoder().decode(Int.self, from: Data(json.utf8))
    }

    /// Decodes a generated-content metadata value as a double, returning nil for missing or incompatible values.
    func doubleValue(forKey key: String) -> Double? {
        guard let json = self[key]?.generatedContent.jsonString else { return nil }
        return try? JSONDecoder().decode(Double.self, from: Data(json.utf8))
    }

    /// Decodes string metadata and parses a UUID, returning nil when either step fails.
    func uuidValue(forKey key: String) -> UUID? {
        stringValue(forKey: key).flatMap(UUID.init(uuidString:))
    }
}

struct EvaluationHTTPResponseMutation: Sendable {
    enum Action: Sendable {
        case append
        case replace
    }

    var action: Action
    var entryID: String?
    var segmentID: String?
    var content: String
}

struct EvaluationHTTPResponseAccumulator: Sendable {
    private struct Segment: Sendable {
        var id: String?
        var content: String
    }

    private struct Entry: Sendable {
        var id: String?
        var segments: [Segment] = []
    }

    private var entries: [Entry] = []

    /// Applies a response mutation and returns all entry segments concatenated in encounter order.
    ///
    /// Missing entry IDs target the latest entry; missing segment IDs append to or replace the
    /// last applicable segment, while explicit IDs identify the segment to mutate.
    mutating func apply(_ mutation: EvaluationHTTPResponseMutation) -> String {
        let existingEntry = mutation.entryID.flatMap { id in entries.firstIndex { $0.id == id } }
            ?? (mutation.entryID == nil ? entries.indices.last : nil)
        if existingEntry == nil { entries.append(.init(id: mutation.entryID)) }
        let entryIndex = existingEntry ?? (entries.count - 1)
        var segments = entries[entryIndex].segments
        let matchingIndex = mutation.segmentID.flatMap { id in
            segments.firstIndex { $0.id == id }
        }
        switch mutation.action {
        case .append:
            if let matchingIndex {
                segments[matchingIndex].content += mutation.content
            } else if mutation.segmentID == nil,
                      let lastIndex = segments.indices.last,
                      segments[lastIndex].id == nil {
                segments[lastIndex].content += mutation.content
            } else {
                segments.append(.init(id: mutation.segmentID, content: mutation.content))
            }
        case .replace:
            if let matchingIndex {
                segments[matchingIndex].content = mutation.content
            } else if mutation.segmentID == nil, let lastIndex = segments.indices.last {
                segments[lastIndex].content = mutation.content
            } else {
                segments.append(.init(id: mutation.segmentID, content: mutation.content))
            }
        }
        entries[entryIndex].segments = segments
        return entries.flatMap { $0.segments.map(\.content) }.joined()
    }
}

struct EvaluationHTTPNDJSONBuffer: Sendable {
    private let maximumEventBytes: Int
    private let maximumResponseBytes: Int
    private var receivedBytes = 0
    private var line = Data()

    /// Creates an empty NDJSON buffer with independent per-event and total-response byte ceilings.
    init(maximumEventBytes: Int, maximumResponseBytes: Int) {
        self.maximumEventBytes = maximumEventBytes
        self.maximumResponseBytes = maximumResponseBytes
        line.reserveCapacity(min(4_096, maximumEventBytes))
    }

    /// Counts each received byte and returns a completed line at newline boundaries, throwing when either byte ceiling is exceeded.
    mutating func append(_ byte: UInt8) throws -> Data? {
        receivedBytes += 1
        guard receivedBytes <= maximumResponseBytes else {
            throw EvaluationHTTPProviderError.responseTooLarge(maximum: maximumResponseBytes)
        }
        guard byte != 0x0A else {
            defer { line.removeAll(keepingCapacity: true) }
            return line
        }

        line.append(byte)
        guard line.count <= maximumEventBytes else {
            throw EvaluationHTTPProviderError.eventTooLarge(maximum: maximumEventBytes)
        }
        return nil
    }

    /// Returns and clears a nonempty final unterminated line, or nil when no bytes remain.
    mutating func finish() -> Data? {
        guard !line.isEmpty else { return nil }
        defer { line.removeAll(keepingCapacity: true) }
        return line
    }
}

struct EvaluationHTTPGenerationRequest: Encodable {
    static let protocolVersion = 1

    enum Mode: String, Encodable {
        case text
        case guided
    }

    struct ToolDefinition: Encodable {
        var name: String
        var description: String
        var parameters: GenerationSchema
    }

    struct Options: Encodable {
        struct Sampling: Encodable {
            var kind: String
            var topK: Int? = nil
            var probabilityThreshold: Double? = nil
            var seed: UInt64? = nil
        }

        var sampling: Sampling?
        var temperature: Double?
        var maximumResponseTokens: Int?
        var toolCallingMode: String?
    }

    struct Context: Encodable {
        var includeSchemaInPrompt: Bool?
        var reasoningLevel: String?
    }

    struct Provider: Encodable {
        var contextSize: Int
        var capabilities: [String]
    }

    var protocolVersion: Int
    var requestID: UUID
    var mode: Mode
    var transcript: Transcript
    var enabledTools: [ToolDefinition]
    var schema: GenerationSchema?
    var options: Options
    var context: Context
    var provider: Provider
    var metadata: [String: EvaluationHTTPJSONValue]

    /// Encodes the versioned generation envelope with transcript, enabled tools, schema, options, provider declarations, and JSON metadata.
    static func makeBody(
        from request: LanguageModelExecutorGenerationRequest,
        configuration: EvaluationCustomProviderConfiguration
    ) throws -> Data {
        let envelope = try Self(
            protocolVersion: protocolVersion,
            requestID: request.id,
            mode: request.schema == nil ? .text : .guided,
            transcript: request.transcript,
            enabledTools: request.enabledToolDefinitions.map {
                ToolDefinition(name: $0.name, description: $0.description, parameters: $0.parameters)
            },
            schema: request.schema,
            options: try Options(request.generationOptions),
            context: try Context(request.contextOptions),
            provider: Provider(
                contextSize: configuration.contextSize,
                capabilities: configuration.protocolCapabilityNames
            ),
            metadata: request.metadata.mapValues { try EvaluationHTTPJSONValue(json: $0.jsonString) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }
}

/// Response from the optional custom-provider tokenizer endpoint.
struct EvaluationHTTPTokenizationResponse: Decodable, Equatable, Sendable {
    var inputTokens: Int
    var cachedInputTokens: Int = 0

    private enum CodingKeys: String, CodingKey {
        case inputTokens, cachedInputTokens
    }

    /// Decodes required input tokens and defaults omitted cached-input tokens to zero; validation occurs at admission.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
    }
}

private extension EvaluationHTTPGenerationRequest.Options {
    /// Translates supported sampling and tool-calling options to wire values, throwing for unknown option kinds.
    init(_ options: GenerationOptions) throws {
        if let sampling = options.samplingMode {
            switch sampling.kind {
            case .greedy:
                self.sampling = .init(kind: "greedy")
            case .randomTopK(let topK, let seed):
                self.sampling = .init(kind: "randomTopK", topK: topK, seed: seed)
            case .randomProbabilityThreshold(let threshold, let seed):
                self.sampling = .init(
                    kind: "randomProbabilityThreshold",
                    probabilityThreshold: threshold,
                    seed: seed
                )
            @unknown default:
                throw EvaluationHTTPProviderError.unsupportedRequestOption(
                    "sampling mode \(String(describing: sampling.kind))"
                )
            }
        } else {
            sampling = nil
        }
        temperature = options.temperature
        maximumResponseTokens = options.maximumResponseTokens
        if let kind = options.toolCallingMode?.kind {
            switch kind {
            case .allowed: toolCallingMode = "allowed"
            case .required: toolCallingMode = "required"
            case .disallowed: toolCallingMode = "disallowed"
            @unknown default:
                throw EvaluationHTTPProviderError.unsupportedRequestOption(
                    "tool-calling mode \(String(describing: kind))"
                )
            }
        } else {
            toolCallingMode = nil
        }
    }
}

private extension EvaluationHTTPGenerationRequest.Context {
    /// Translates schema-prompt and reasoning settings to wire values, throwing for unknown reasoning levels.
    init(_ context: ContextOptions) throws {
        includeSchemaInPrompt = context.includeSchemaInPrompt
        if let level = context.reasoningLevel {
            switch level {
            case .light: reasoningLevel = "light"
            case .moderate: reasoningLevel = "moderate"
            case .deep: reasoningLevel = "deep"
            case .custom(let name): reasoningLevel = "custom:\(name)"
            @unknown default:
                throw EvaluationHTTPProviderError.unsupportedRequestOption(
                    "reasoning level \(String(describing: level))"
                )
            }
        } else {
            reasoningLevel = nil
        }
    }
}

struct EvaluationHTTPGenerationEvent: Decodable, Equatable, Sendable {
    enum Kind: String, Decodable, Equatable, Sendable {
        case response
        case guidedResponse
        case reasoning
        case reasoningSignature
        case toolCall
        case usage
        case error
    }

    enum Action: String, Decodable, Equatable, Sendable {
        case append
        case replace
    }

    enum UsageTarget: String, Decodable, Equatable, Sendable {
        case response
        case reasoning
        case toolCalls
    }

    struct Usage: Decodable, Equatable, Sendable {
        var inputTokens: Int
        var cachedInputTokens: Int
        var outputTokens: Int
        var reasoningTokens: Int
    }

    var kind: Kind
    var action: Action?
    var entryID: String?
    var segmentID: String?
    var callID: String?
    var toolName: String?
    var content: String?
    var signatureBase64: String?
    var tokenCount: Int?
    var usageTarget: UsageTarget?
    var usage: Usage?
    var code: String?
    var message: String?

    /// Validates event fields and translates a provider event into a channel command.
    ///
    /// Checks text versus guided response mode, required fields, token-count bounds, tool-call
    /// action, and usage consistency. Provider error events throw the reported backend failure.
    func command(expectsGuidedResponse: Bool) throws -> EvaluationHTTPChannelCommand {
        switch kind {
        case .response:
            guard !expectsGuidedResponse else {
                throw EvaluationHTTPProviderError.invalidEvent(
                    "A guided request requires guidedResponse events."
                )
            }
            return try textCommand(guided: false)
        case .guidedResponse:
            guard expectsGuidedResponse else {
                throw EvaluationHTTPProviderError.invalidEvent(
                    "A text request cannot accept guidedResponse events."
                )
            }
            return try textCommand(guided: true)
        case .reasoning:
            let content = try required(content, named: "content")
            let tokenCount = try validTokenCount()
            switch action ?? .append {
            case .append:
                return .reasoningAppend(entryID: entryID, segmentID: segmentID, content: content, tokenCount: tokenCount)
            case .replace:
                return .reasoningReplace(entryID: entryID, segmentID: segmentID, content: content, tokenCount: tokenCount)
            }
        case .reasoningSignature:
            let encoded = try required(signatureBase64, named: "signatureBase64")
            guard let signature = Data(base64Encoded: encoded) else {
                throw EvaluationHTTPProviderError.invalidEvent("signatureBase64 is not valid base64.")
            }
            return .reasoningSignature(entryID: entryID, signature: signature, tokenCount: try validTokenCount())
        case .toolCall:
            guard (action ?? .append) == .append else {
                throw EvaluationHTTPProviderError.invalidEvent("toolCall only supports the append action.")
            }
            return .toolCallArguments(
                entryID: entryID,
                callID: try required(callID, named: "callID"),
                toolName: try required(toolName, named: "toolName"),
                content: try required(content, named: "content"),
                tokenCount: try validTokenCount()
            )
        case .usage:
            let usage = try required(usage, named: "usage")
            guard usage.inputTokens >= 0,
                  usage.cachedInputTokens >= 0,
                  usage.cachedInputTokens <= usage.inputTokens,
                  usage.outputTokens >= 0,
                  usage.reasoningTokens >= 0,
                  usage.reasoningTokens <= usage.outputTokens else {
                throw EvaluationHTTPProviderError.invalidEvent(
                    "usage counts must be nonnegative, cached input cannot exceed input, and reasoning cannot exceed output."
                )
            }
            return .usage(
                target: try required(usageTarget, named: "usageTarget"),
                value: usage
            )
        case .error:
            throw EvaluationHTTPProviderError.backend(
                code: code ?? "backendError",
                message: message ?? "The custom provider reported an error."
            )
        }
    }

    /// Builds an append or replace response command with required content and a nonnegative token count.
    private func textCommand(guided: Bool) throws -> EvaluationHTTPChannelCommand {
        let content = try required(content, named: "content")
        let tokenCount = try validTokenCount()
        switch action ?? .append {
        case .append:
            return .responseAppend(
                entryID: entryID,
                segmentID: segmentID,
                content: content,
                tokenCount: tokenCount,
                guided: guided
            )
        case .replace:
            return .responseReplace(
                entryID: entryID,
                segmentID: segmentID,
                content: content,
                tokenCount: tokenCount,
                guided: guided
            )
        }
    }

    /// Requires a nonnegative event token count, throwing an invalid-event error for missing or negative values.
    private func validTokenCount() throws -> Int {
        let count = try required(tokenCount, named: "tokenCount")
        guard count >= 0 else {
            throw EvaluationHTTPProviderError.invalidEvent("tokenCount must not be negative.")
        }
        return count
    }

    /// Unwraps an event field or throws an invalid-event error naming the missing field and event kind.
    private func required<Value>(_ value: Value?, named name: String) throws -> Value {
        guard let value else {
            throw EvaluationHTTPProviderError.invalidEvent("\(name) is required for a \(kind.rawValue) event.")
        }
        return value
    }
}

enum EvaluationHTTPChannelCommand: Equatable, Sendable {
    case responseAppend(entryID: String?, segmentID: String?, content: String, tokenCount: Int, guided: Bool)
    case responseReplace(entryID: String?, segmentID: String?, content: String, tokenCount: Int, guided: Bool)
    case reasoningAppend(entryID: String?, segmentID: String?, content: String, tokenCount: Int)
    case reasoningReplace(entryID: String?, segmentID: String?, content: String, tokenCount: Int)
    case reasoningSignature(entryID: String?, signature: Data, tokenCount: Int)
    case toolCallArguments(entryID: String?, callID: String, toolName: String, content: String, tokenCount: Int)
    case usage(target: EvaluationHTTPGenerationEvent.UsageTarget, value: EvaluationHTTPGenerationEvent.Usage)

    var producesResponseOrToolCall: Bool {
        switch self {
        case .responseAppend, .responseReplace, .toolCallArguments: true
        case .reasoningAppend, .reasoningReplace, .reasoningSignature, .usage: false
        }
    }

    var responseMutation: EvaluationHTTPResponseMutation? {
        switch self {
        case .responseAppend(let entryID, let segmentID, let content, _, _):
            .init(action: .append, entryID: entryID, segmentID: segmentID, content: content)
        case .responseReplace(let entryID, let segmentID, let content, _, _):
            .init(action: .replace, entryID: entryID, segmentID: segmentID, content: content)
        case .reasoningAppend, .reasoningReplace, .reasoningSignature, .toolCallArguments, .usage:
            nil
        }
    }

    /// Sends the corresponding response, reasoning, signature, tool-call argument, or usage mutation to the model channel.
    func send(into channel: LanguageModelExecutorGenerationChannel) async throws {
        switch self {
        case .responseAppend(let entryID, let segmentID, let content, let tokenCount, _):
            await channel.send(.response(
                entryID: entryID,
                action: .appendText(content, segmentID: segmentID, tokenCount: tokenCount)
            ))
        case .responseReplace(let entryID, let segmentID, let content, let tokenCount, _):
            await channel.send(.response(
                entryID: entryID,
                action: .replaceTextSegment(content, segmentID: segmentID, tokenCount: tokenCount)
            ))
        case .reasoningAppend(let entryID, let segmentID, let content, let tokenCount):
            await channel.send(.reasoning(
                entryID: entryID,
                action: .appendText(content, segmentID: segmentID, tokenCount: tokenCount)
            ))
        case .reasoningReplace(let entryID, let segmentID, let content, let tokenCount):
            await channel.send(.reasoning(
                entryID: entryID,
                action: .replaceTextSegment(content, segmentID: segmentID, tokenCount: tokenCount)
            ))
        case .reasoningSignature(let entryID, let signature, let tokenCount):
            await channel.send(.reasoning(
                entryID: entryID,
                action: .updateSignature(signature, tokenCount: tokenCount)
            ))
        case .toolCallArguments(let entryID, let callID, let toolName, let content, let tokenCount):
            await channel.send(.toolCalls(
                entryID: entryID,
                action: .toolCall(
                    id: callID,
                    name: toolName,
                    action: .appendArguments(content, tokenCount: tokenCount)
                )
            ))
        case .usage(let target, let value):
            let input = LanguageModelExecutorGenerationChannel.Usage.Input(
                totalTokenCount: value.inputTokens,
                cachedTokenCount: value.cachedInputTokens
            )
            let output = LanguageModelExecutorGenerationChannel.Usage.Output(
                totalTokenCount: value.outputTokens,
                reasoningTokenCount: value.reasoningTokens
            )
            switch target {
            case .response:
                await channel.send(.response(action: .updateUsage(input: input, output: output)))
            case .reasoning:
                await channel.send(.reasoning(action: .updateUsage(input: input, output: output)))
            case .toolCalls:
                await channel.send(.toolCalls(action: .updateUsage(input: input, output: output)))
            }
        }
    }
}

enum EvaluationHTTPJSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    /// Decodes one JSON fragment into the recursive wire metadata representation.
    init(json: String) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }

    /// Decodes null, Boolean, number, string, array, or object values from a single JSON container.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else { self = .object(try container.decode([String: Self].self)) }
    }

    /// Encodes the stored recursive JSON value through a single-value container.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

enum EvaluationHTTPProviderError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case requestTooLarge(maximum: Int)
    case responseTooLarge(maximum: Int)
    case eventTooLarge(maximum: Int)
    case invalidHTTPResponse
    case invalidTokenizationResponse(String)
    case httpStatus(Int)
    case unsupportedRequestOption(String)
    case invalidEvent(String)
    case missingOutputEvent
    case backend(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let issue): issue
        case .requestTooLarge(let maximum): "The custom provider request exceeded \(maximum) bytes."
        case .responseTooLarge(let maximum): "The custom provider response exceeded \(maximum) bytes."
        case .eventTooLarge(let maximum): "A custom provider event exceeded \(maximum) bytes."
        case .invalidHTTPResponse: "The custom provider did not return an HTTP response."
        case .invalidTokenizationResponse(let detail):
            "The custom provider tokenizer returned an invalid response: \(detail)"
        case .httpStatus(let status): "The custom provider returned HTTP status \(status)."
        case .unsupportedRequestOption(let option):
            "The custom provider adapter cannot encode the requested \(option)."
        case .invalidEvent(let issue): "The custom provider returned an invalid event: \(issue)"
        case .missingOutputEvent: "The custom provider response ended without a response or tool-call event."
        case .backend(let code, let message): "The custom provider reported \(code): \(message)"
        }
    }
}
