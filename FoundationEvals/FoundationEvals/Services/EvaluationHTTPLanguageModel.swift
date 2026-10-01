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
            return "Port \(Self.reservedMCPPort) is reserved for the Foundation Evals MCP server."
        }
        return nil
    }

    var validatedEndpoint: URL? {
        guard validationIssue == nil else { return nil }
        return URL(string: endpoint)
    }
}

/// A Foundation Models `LanguageModel` whose inference is supplied by a local HTTP process.
struct EvaluationHTTPLanguageModel: LanguageModel {
    typealias Executor = EvaluationHTTPLanguageModelExecutor

    let configuration: EvaluationCustomProviderConfiguration
    let liveResponseObserver: EvaluationHTTPLiveResponseObserver?

    init(
        configuration: EvaluationCustomProviderConfiguration,
        liveResponseObserver: EvaluationHTTPLiveResponseObserver? = nil
    ) {
        self.configuration = configuration
        self.liveResponseObserver = liveResponseObserver
    }

    var capabilities: LanguageModelCapabilities { configuration.capabilities }
    var executorConfiguration: Executor.Configuration {
        .init(provider: configuration, liveResponseObserver: liveResponseObserver)
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

    init(handler: @escaping @Sendable (EvaluationHTTPLiveResponseUpdate) async -> Void) {
        self.handler = handler
    }

    func publish(_ update: EvaluationHTTPLiveResponseUpdate) async {
        await handler(update)
    }

    static func == (lhs: EvaluationHTTPLiveResponseObserver, rhs: EvaluationHTTPLiveResponseObserver) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

struct EvaluationHTTPLanguageModelExecutionConfiguration: Hashable, Sendable {
    var provider: EvaluationCustomProviderConfiguration
    var liveResponseObserver: EvaluationHTTPLiveResponseObserver?
}

struct EvaluationHTTPLanguageModelExecutor: LanguageModelExecutor {
    typealias Model = EvaluationHTTPLanguageModel
    typealias Configuration = EvaluationHTTPLanguageModelExecutionConfiguration

    private static let maximumRequestBytes = 8 * 1_024 * 1_024
    private static let maximumResponseBytes = 8 * 1_024 * 1_024
    private static let maximumEventBytes = 1 * 1_024 * 1_024

    private let configuration: EvaluationCustomProviderConfiguration
    private let liveResponseObserver: EvaluationHTTPLiveResponseObserver?

    init(configuration: Configuration) throws {
        if let issue = configuration.provider.validationIssue {
            throw EvaluationHTTPProviderError.invalidConfiguration(issue)
        }
        self.configuration = configuration.provider
        self.liveResponseObserver = configuration.liveResponseObserver
    }

    func prewarm(model: Model, transcript: Transcript) {
        // A local HTTP provider has no common prewarm contract. In particular, this hook must
        // not make unsolicited requests merely because the Foundation Models session prewarms.
    }

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

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = configuration.requestTimeoutSeconds
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.connectionProxyDictionary = [:]
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: EvaluationHTTPNoRedirectDelegate(),
            delegateQueue: nil
        )
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
        var buffer = EvaluationHTTPNDJSONBuffer(
            maximumEventBytes: Self.maximumEventBytes,
            maximumResponseBytes: Self.maximumResponseBytes
        )
        for try await byte in bytes {
            try Task.checkCancellation()
            if let line = try buffer.append(byte) {
                if let command = try Self.command(
                    fromLine: line,
                    expectsGuidedResponse: request.schema != nil
                ) {
                    if command.producesResponseOrToolCall { responseEventCount += 1 }
                    try await command.send(into: channel)
                    if let mutation = command.responseMutation {
                        let content = liveResponse.apply(mutation)
                        if firstContentMilliseconds == nil,
                           Self.isVisibleContent(content) {
                            let measurement = Self.firstContentMilliseconds(
                                started: started,
                                metadata: request.metadata
                            )
                            firstContentMilliseconds = measurement
                            await channel.send(.response(
                                entryID: mutation.entryID,
                                action: .updateMetadata([
                                    EvaluationHTTPLiveResponseObserver.firstContentMetadataKey:
                                        measurement
                                ])
                            ))
                        }
                        if let update = Self.liveResponseUpdate(
                            content: content,
                            metadata: request.metadata
                        ) {
                            await liveResponseObserver?.publish(update)
                        }
                    }
                }
            }
        }
        if let finalLine = buffer.finish() {
            if let command = try Self.command(
                fromLine: finalLine,
                expectsGuidedResponse: request.schema != nil
            ) {
                if command.producesResponseOrToolCall { responseEventCount += 1 }
                try await command.send(into: channel)
                if let mutation = command.responseMutation {
                    let content = liveResponse.apply(mutation)
                    if firstContentMilliseconds == nil,
                       Self.isVisibleContent(content) {
                        let measurement = Self.firstContentMilliseconds(
                            started: started,
                            metadata: request.metadata
                        )
                        firstContentMilliseconds = measurement
                        await channel.send(.response(
                            entryID: mutation.entryID,
                            action: .updateMetadata([
                                EvaluationHTTPLiveResponseObserver.firstContentMetadataKey:
                                    measurement
                            ])
                        ))
                    }
                    if let update = Self.liveResponseUpdate(
                        content: content,
                        metadata: request.metadata
                    ) {
                        await liveResponseObserver?.publish(update)
                    }
                }
            }
        }

        guard responseEventCount > 0 else {
            throw EvaluationHTTPProviderError.missingOutputEvent
        }
    }

    private static func isVisibleContent(_ content: String) -> Bool {
        let visible = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !visible.isEmpty && visible != "{}" && visible != "null"
    }

    private static func firstContentMilliseconds(
        started: ContinuousClock.Instant,
        metadata: [String: any ConvertibleToGeneratedContent]
    ) -> Double {
        if let generationStarted = metadata.doubleValue(
            forKey: EvaluationHTTPLiveResponseObserver.generationStartedMetadataKey
        ) {
            return max(0, (Date().timeIntervalSinceReferenceDate - generationStarted) * 1_000)
        }
        return started.milliseconds(to: .now)
    }

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

private extension ContinuousClock.Instant {
    func milliseconds(to other: Self) -> Double {
        let elapsed = duration(to: other).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }
}

private extension Dictionary where Key == String, Value == any ConvertibleToGeneratedContent {
    func stringValue(forKey key: String) -> String? {
        guard let json = self[key]?.generatedContent.jsonString else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(json.utf8))
    }

    func intValue(forKey key: String) -> Int? {
        guard let json = self[key]?.generatedContent.jsonString else { return nil }
        return try? JSONDecoder().decode(Int.self, from: Data(json.utf8))
    }

    func doubleValue(forKey key: String) -> Double? {
        guard let json = self[key]?.generatedContent.jsonString else { return nil }
        return try? JSONDecoder().decode(Double.self, from: Data(json.utf8))
    }

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

    private var segments: [Segment] = []

    mutating func apply(_ mutation: EvaluationHTTPResponseMutation) -> String {
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
        return segments.map(\.content).joined()
    }
}

struct EvaluationHTTPNDJSONBuffer: Sendable {
    private let maximumEventBytes: Int
    private let maximumResponseBytes: Int
    private var receivedBytes = 0
    private var line = Data()

    init(maximumEventBytes: Int, maximumResponseBytes: Int) {
        self.maximumEventBytes = maximumEventBytes
        self.maximumResponseBytes = maximumResponseBytes
        line.reserveCapacity(min(4_096, maximumEventBytes))
    }

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

private extension EvaluationHTTPGenerationRequest.Options {
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

    private func validTokenCount() throws -> Int {
        let count = try required(tokenCount, named: "tokenCount")
        guard count >= 0 else {
            throw EvaluationHTTPProviderError.invalidEvent("tokenCount must not be negative.")
        }
        return count
    }

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

    init(json: String) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else { self = .object(try container.decode([String: Self].self)) }
    }

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

final class EvaluationHTTPNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum EvaluationHTTPProviderError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case requestTooLarge(maximum: Int)
    case responseTooLarge(maximum: Int)
    case eventTooLarge(maximum: Int)
    case invalidHTTPResponse
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
        case .httpStatus(let status): "The custom provider returned HTTP status \(status)."
        case .unsupportedRequestOption(let option):
            "The custom provider adapter cannot encode the requested \(option)."
        case .invalidEvent(let issue): "The custom provider returned an invalid event: \(issue)"
        case .missingOutputEvent: "The custom provider response ended without a response or tool-call event."
        case .backend(let code, let message): "The custom provider reported \(code): \(message)"
        }
    }
}
