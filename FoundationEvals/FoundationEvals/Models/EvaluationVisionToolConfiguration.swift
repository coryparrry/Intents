import FoundationModels
import Vision

struct EvaluationVisionToolConfiguration: Codable, Equatable, Sendable {
    var ocrEnabled: Bool = false
    var barcodeEnabled: Bool = false

    var isEmpty: Bool {
        !ocrEnabled && !barcodeEnabled
    }

    var enabledToolNames: [String] {
        var names: [String] = []
        if ocrEnabled { names.append(OCRTool().name) }
        if barcodeEnabled { names.append(BarcodeReaderTool().name) }
        return names
    }

    func makeTools() -> [any Tool] {
        // Foundation Models binds session history to the registered native tool instance.
        // Wrapping these tools leaves their ImageReference resolver with an empty history.
        var tools: [any Tool] = []
        if ocrEnabled {
            tools.append(OCRTool())
        }
        if barcodeEnabled {
            tools.append(BarcodeReaderTool())
        }
        return tools
    }

    func boundary(limiter: EvaluationToolCallLimiter) -> EvaluationBuiltinToolBoundary? {
        guard !isEmpty else { return nil }
        return EvaluationBuiltinToolBoundary(
            toolNames: Set(enabledToolNames),
            limiter: limiter,
            tokenCounter: EvaluationSystemPromptTokenCounter()
        )
    }

    static var knownToolNames: Set<String> {
        [OCRTool().name, BarcodeReaderTool().name]
    }
}

struct EvaluationBuiltinToolBoundary: LanguageModelSession.DynamicProfileModifier {
    let toolNames: Set<String>
    let limiter: EvaluationToolCallLimiter
    let tokenCounter: any EvaluationToolOutputTokenCounting

    func body(content: Content) -> some LanguageModelSession.DynamicProfile {
        content
            .onToolCall { call in
                try await validateToolCall(call)
            }
            .onToolOutput { call, output in
                try await validateToolOutput(call: call, output: output)
            }
    }

    func validateToolCall(_ call: Transcript.ToolCall) async throws {
        guard toolNames.contains(call.toolName) else { return }
        try await limiter.beginCall()
    }

    func validateToolOutput(
        call: Transcript.ToolCall,
        output: Transcript.ToolOutput
    ) async throws {
        guard toolNames.contains(call.toolName) else { return }
        let promptSegments = try Self.promptSegments(for: output)
        let outputTokenCount = promptSegments.isEmpty
            ? 0
            : try await tokenCounter.tokenCount(for: promptSegments)
        guard outputTokenCount <= EvaluationCustomTool.maximumOutputTokens else {
            throw EvaluationBoundedToolError.outputTokenLimitExceeded(
                actual: outputTokenCount,
                maximum: EvaluationCustomTool.maximumOutputTokens
            )
        }
    }

    static func promptSegments(for output: Transcript.ToolOutput) throws -> [Prompt] {
        try output.segments.map { segment in
            switch segment {
            case .text(let text):
                Prompt(text.content)
            case .structure(let structure):
                Prompt(structure.content)
            case .attachment:
                throw EvaluationBoundedToolError.outputContainsAttachment
            @unknown default:
                throw EvaluationBoundedToolError.unsupportedOutputSegment
            }
        }
    }
}

actor EvaluationToolCallLimiter {
    private let maximumCalls: Int
    private var callCount = 0

    init(maximumCalls: Int) {
        self.maximumCalls = min(
            max(0, maximumCalls),
            EvaluationCustomToolRecorder.maximumCallsPerSample
        )
    }

    func beginCall() throws {
        guard callCount < maximumCalls else {
            throw EvaluationBoundedToolError.callLimitReached(maximum: maximumCalls)
        }
        callCount += 1
    }
}

struct EvaluationBoundedTool<Wrapped: Tool>: Tool {
    typealias Arguments = Wrapped.Arguments
    typealias Output = Wrapped.Output

    let name: String
    let description: String
    let parameters: GenerationSchema
    let includesSchemaInInstructions: Bool

    private let tool: Wrapped
    private let limiter: EvaluationToolCallLimiter
    private let tokenCounter: any EvaluationToolOutputTokenCounting

    init(
        tool: Wrapped,
        limiter: EvaluationToolCallLimiter,
        tokenCounter: any EvaluationToolOutputTokenCounting
    ) {
        self.name = tool.name
        self.description = tool.description
        self.parameters = tool.parameters
        self.includesSchemaInInstructions = tool.includesSchemaInInstructions
        self.tool = tool
        self.limiter = limiter
        self.tokenCounter = tokenCounter
    }

    @concurrent
    func call(arguments: Wrapped.Arguments) async throws -> Wrapped.Output {
        try await limiter.beginCall()
        let output = try await tool.call(arguments: arguments)
        let outputTokenCount = try await tokenCounter.tokenCount(for: output)
        guard outputTokenCount <= EvaluationCustomTool.maximumOutputTokens else {
            throw EvaluationBoundedToolError.outputTokenLimitExceeded(
                actual: outputTokenCount,
                maximum: EvaluationCustomTool.maximumOutputTokens
            )
        }
        return output
    }
}

protocol EvaluationToolOutputTokenCounting: Sendable {
    func tokenCount<Output: PromptRepresentable>(for output: Output) async throws -> Int
}

struct EvaluationSystemPromptTokenCounter: EvaluationToolOutputTokenCounting {
    func tokenCount<Output: PromptRepresentable>(for output: Output) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: output)
    }
}

enum EvaluationBoundedToolError: LocalizedError, Sendable {
    case callLimitReached(maximum: Int)
    case outputTokenLimitExceeded(actual: Int, maximum: Int)
    case outputContainsAttachment
    case unsupportedOutputSegment

    var errorDescription: String? {
        switch self {
        case .callLimitReached(let maximum):
            "The run reached its \(maximum)-call built-in tool limit."
        case .outputTokenLimitExceeded(let actual, let maximum):
            "The built-in tool output used \(actual) tokens, exceeding the \(maximum)-token output limit."
        case .outputContainsAttachment:
            "The built-in tool returned an attachment that cannot be included in its output token limit."
        case .unsupportedOutputSegment:
            "The built-in tool returned an output segment that cannot be included in its output token limit."
        }
    }
}
