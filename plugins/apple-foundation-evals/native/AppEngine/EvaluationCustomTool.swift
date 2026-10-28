import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

@available(macOS 27.0, *)
enum EvaluationCustomToolCallOutcome: String, Codable, Equatable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
    case rejected
}

@available(macOS 27.0, *)
struct EvaluationCustomToolCallTrace: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var toolName: String
    var argumentsJSON: String
    var output: String?
    var durationMilliseconds: Double
    var outcome: EvaluationCustomToolCallOutcome
    var errorDescription: String?
}

@available(macOS 27.0, *)
actor EvaluationCustomToolRecorder {
    static let maximumCallsPerSample = 4
    private static let maximumErrorBytes = 1_024
    private static let maximumRecordedRejections = 4

    let maximumCalls: Int
    let workflowRecorder: EvaluationWorkflowRecorder?
    private let callLimiter: EvaluationToolCallLimiter
    private var rejectedCallCount = 0
    private var traces: [EvaluationCustomToolCallTrace] = []

    /// Creates bounded tool-call recording with an optional shared limiter and workflow recorder, clamping the reported call limit to zero through four.
    init(maximumCalls: Int, callLimiter: EvaluationToolCallLimiter? = nil, workflowRecorder: EvaluationWorkflowRecorder? = nil) {
        self.workflowRecorder = workflowRecorder
        self.maximumCalls = min(max(0, maximumCalls), Self.maximumCallsPerSample)
        self.callLimiter = callLimiter ?? EvaluationToolCallLimiter(maximumCalls: maximumCalls)
    }

    /// Reserves shared call capacity and records bounded arguments for an admitted call.
    /// On quota failure, retains at most four rejection traces and throws the custom-tool call-limit error.
    func beginCall(id: UUID, toolName: String, argumentsJSON: String) async throws {
        do {
            try await callLimiter.beginCall()
        } catch {
            if rejectedCallCount < Self.maximumRecordedRejections {
                rejectedCallCount += 1
                traces.append(
                    EvaluationCustomToolCallTrace(
                        id: id,
                        toolName: toolName,
                        argumentsJSON: argumentsJSON.boundedUTF8(
                            to: EvaluationCustomToolDefinition.maximumArgumentBytes
                        ),
                        output: nil,
                        durationMilliseconds: 0,
                        outcome: .rejected,
                        errorDescription: "The run reached its \(maximumCalls)-call custom tool limit."
                    )
                )
            }
            throw EvaluationCustomToolError.callLimitReached(maximum: maximumCalls)
        }

        traces.append(
            EvaluationCustomToolCallTrace(
                id: id,
                toolName: toolName,
                argumentsJSON: argumentsJSON.boundedUTF8(
                    to: EvaluationCustomToolDefinition.maximumArgumentBytes
                ),
                output: nil,
                durationMilliseconds: 0,
                outcome: .running,
                errorDescription: nil
            )
        )
    }

    /// Updates a known call with bounded output and error text, nonnegative duration, and its final outcome.
    func finishCall(
        id: UUID,
        output: String?,
        durationMilliseconds: Double,
        outcome: EvaluationCustomToolCallOutcome,
        errorDescription: String? = nil
    ) {
        guard let index = traces.firstIndex(where: { $0.id == id }) else { return }
        traces[index].output = output?.boundedUTF8(
            to: EvaluationCustomToolDefinition.maximumOutputBytes
        )
        traces[index].durationMilliseconds = max(0, durationMilliseconds)
        traces[index].outcome = outcome
        traces[index].errorDescription = errorDescription?.boundedUTF8(
            to: Self.maximumErrorBytes
        )
    }

    /// Replaces a known call’s recorded arguments with a byte-bounded representation.
    func updateArguments(id: UUID, argumentsJSON: String) {
        guard let index = traces.firstIndex(where: { $0.id == id }) else { return }
        traces[index].argumentsJSON = argumentsJSON.boundedUTF8(
            to: EvaluationCustomToolDefinition.maximumArgumentBytes
        )
    }

    /// Returns the recorded calls in their insertion order, including retained rejections.
    func snapshot() -> [EvaluationCustomToolCallTrace] {
        traces
    }

    /// Formats recorded arguments, outputs, outcomes, and timing as judge evidence, including an explicit no-call message when empty.
    func evidenceText() -> String {
        guard !traces.isEmpty else { return "No custom tools were called." }

        return traces.enumerated().map { index, trace in
            var lines = [
                "Custom tool call \(index + 1): \(trace.toolName)",
                "Outcome: \(trace.outcome.rawValue)",
                "Arguments: \(trace.argumentsJSON)",
                "Duration: \(trace.durationMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
            ]
            if let output = trace.output {
                lines.append("Output: \(output)")
            }
            if let errorDescription = trace.errorDescription {
                lines.append("Error: \(errorDescription)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

@available(macOS 27.0, *)
struct EvaluationCustomTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    static let maximumArgumentTokens = 256
    static let maximumOutputTokens = 512
    static let contextTokenReservePerCall = 1_024

    let name: String
    let description: String
    let parameters: GenerationSchema

    private let definition: EvaluationCustomToolDefinition
    private let recorder: EvaluationCustomToolRecorder
    private let httpClient: any EvaluationCustomToolHTTPClient
    private let tokenCounter: any EvaluationCustomToolTokenCounting

    @SessionProperty(\.history) private var history

    /// Validates a tool definition and builds its argument schema using the default local HTTP client and system tokenizer.
    init(
        definition: EvaluationCustomToolDefinition,
        recorder: EvaluationCustomToolRecorder
    ) throws {
        try self.init(
            definition: definition,
            recorder: recorder,
            httpClient: EvaluationLocalHTTPToolClient(),
            tokenCounter: EvaluationSystemModelTokenCounter()
        )
    }

    /// Validates a tool definition and constructs its argument schema with the supplied HTTP client and token counter, propagating configuration or schema errors.
    init(
        definition: EvaluationCustomToolDefinition,
        recorder: EvaluationCustomToolRecorder,
        httpClient: any EvaluationCustomToolHTTPClient,
        tokenCounter: any EvaluationCustomToolTokenCounting = EvaluationSystemModelTokenCounter()
    ) throws {
        if let issue = definition.validationIssue {
            throw EvaluationFeatureConfigurationError.invalid(issue)
        }
        self.name = definition.name
        self.description = definition.description
        self.parameters = try EvaluationSchemaBuilder.schema(
            fields: definition.parameters,
            name: definition.name,
            definitions: definition.schemaDefinitions,
            representNilExplicitlyInGeneratedContent: definition.representNilExplicitlyInGeneratedContent
        )
        self.definition = definition
        self.recorder = recorder
        self.httpClient = httpClient
        self.tokenCounter = tokenCounter
    }

    /// Builds custom tools sharing a recorder and tokenizer, rejecting invalid tool configuration or an excessive tool count.
    static func makeTools(
        definitions: [EvaluationCustomToolDefinition],
        recorder: EvaluationCustomToolRecorder,
        tokenCounter: any EvaluationCustomToolTokenCounting = EvaluationSystemModelTokenCounter()
    ) throws -> [EvaluationCustomTool] {
        guard definitions.count <= EvaluationFeatureConfiguration.maximumTools else {
            throw EvaluationFeatureConfigurationError.invalid(
                "A suite can define at most \(EvaluationFeatureConfiguration.maximumTools) custom tools."
            )
        }
        let configuration = EvaluationFeatureConfiguration(tools: definitions)
        if let issue = configuration.validationIssue {
            throw EvaluationFeatureConfigurationError.invalid(issue)
        }
        return try definitions.map {
            try EvaluationCustomTool(
                definition: $0,
                recorder: recorder,
                httpClient: EvaluationLocalHTTPToolClient(),
                tokenCounter: tokenCounter
            )
        }
    }

    /// Executes a fixture or configured local HTTP tool after quota, argument-schema, image-reference, byte, and token admission checks.
    /// Returns bounded UTF-8 text and records success, rejection, failure, or cancellation; policy violations and execution errors propagate.
    @concurrent
    func call(arguments: GeneratedContent) async throws -> String {
        let argumentsJSON = arguments.jsonString
        let callID = UUID()
        let workflow = recorder.workflowRecorder
        let spanID = workflow?.begin(kind: .tool, title: name, parentID: workflow?.activeParentID,
            metadata: ["toolName": name, "toolSource": "custom", "callID": callID.uuidString,
                       "argumentBytes": String(argumentsJSON.utf8.count)])
        do {
            try await recorder.beginCall(id: callID, toolName: name, argumentsJSON: argumentsJSON)
        } catch {
            workflow?.finish(spanID, status: EvaluationWorkflowRecorder.status(for: error), errorMessage: error.localizedDescription)
            throw error
        }
        let start = ContinuousClock.now
        var observedOutput: String?

        do {
            guard argumentsJSON.utf8.count <= EvaluationCustomToolDefinition.maximumArgumentBytes else {
                throw EvaluationCustomToolRejectedError.argumentsTooLarge
            }
            try EvaluationSchemaValidator.validate(arguments, fields: definition.parameters,
                definitions: definition.schemaDefinitions,
                representNilExplicitlyInGeneratedContent: definition.representNilExplicitlyInGeneratedContent)
            let requestArgumentsJSON: String
            if Self.containsImageReference(
                fields: definition.parameters,
                definitions: definition.schemaDefinitions
            ) {
                requestArgumentsJSON = try Self.resolvedArgumentsJSON(
                    argumentsJSON: argumentsJSON,
                    fields: definition.parameters,
                    definitions: definition.schemaDefinitions,
                    history: history
                )
                await recorder.updateArguments(id: callID, argumentsJSON: requestArgumentsJSON)
            } else {
                requestArgumentsJSON = argumentsJSON
            }
            let requestBody = try Self.requestBody(
                toolName: name,
                argumentsJSON: requestArgumentsJSON
            )
            let argumentTokenCount = try await tokenCounter.tokenCount(for: argumentsJSON)
            guard argumentTokenCount <= Self.maximumArgumentTokens else {
                throw EvaluationCustomToolError.argumentTokenLimitExceeded(
                    actual: argumentTokenCount,
                    maximum: Self.maximumArgumentTokens
                )
            }
            try Task.checkCancellation()

            let output: String
            switch definition.mode {
            case .fixture:
                output = definition.fixtureResponse
            case .localHTTP:
                let context = workflow.flatMap { workflow in
                    spanID.map { EvaluationWorkflowHTTPContext(recorder: workflow, parentID: $0) }
                }
                output = try await EvaluationWorkflowHTTPContext.$current.withValue(context) {
                    try await httpClient.post(body: requestBody, to: definition.validatedEndpointURL())
                }
            }
            observedOutput = output
            try Task.checkCancellation()
            guard output.utf8.count <= EvaluationCustomToolDefinition.maximumOutputBytes else {
                throw EvaluationCustomToolError.outputTooLarge
            }
            let outputTokenCount = try await tokenCounter.tokenCount(for: output)
            try Task.checkCancellation()
            guard outputTokenCount <= Self.maximumOutputTokens else {
                throw EvaluationCustomToolError.outputTokenLimitExceeded(
                    actual: outputTokenCount,
                    maximum: Self.maximumOutputTokens
                )
            }

            await recorder.finishCall(
                id: callID,
                output: output,
                durationMilliseconds: start.evaluationMilliseconds(to: .now),
                outcome: .succeeded
            )
            workflow?.finish(spanID, metadata: ["outputBytes": String(output.utf8.count)])
            return output
        } catch is CancellationError {
            await recorder.finishCall(
                id: callID,
                output: observedOutput,
                durationMilliseconds: start.evaluationMilliseconds(to: .now),
                outcome: .cancelled,
                errorDescription: "The custom tool call was cancelled."
            )
            workflow?.finish(spanID, status: .cancelled, errorMessage: "The custom tool call was cancelled.")
            throw CancellationError()
        } catch {
            let outcome: EvaluationCustomToolCallOutcome
            if EvaluationWorkflowRecorder.status(for: error) == .cancelled {
                outcome = .cancelled
            } else if error is EvaluationCustomToolRejectedError || error is EvaluationSchemaValidationError {
                outcome = .rejected
            } else if let toolError = error as? EvaluationCustomToolError,
                      toolError.isPolicyRejection {
                outcome = .rejected
            } else {
                outcome = .failed
            }
            await recorder.finishCall(
                id: callID,
                output: observedOutput,
                durationMilliseconds: start.evaluationMilliseconds(to: .now),
                outcome: outcome,
                errorDescription: error.localizedDescription
            )
            workflow?.finish(spanID, status: EvaluationWorkflowRecorder.status(for: error), errorMessage: error.localizedDescription)
            throw error
        }
    }

    /// Encodes a sorted-key tool-name and argument-object envelope, rejecting non-object JSON or argument and envelope byte-limit violations.
    static func requestBody(toolName: String, argumentsJSON: String) throws -> Data {
        let argumentsData = Data(argumentsJSON.utf8)
        guard argumentsData.count <= EvaluationCustomToolDefinition.maximumArgumentBytes else {
            throw EvaluationCustomToolRejectedError.argumentsTooLarge
        }

        let arguments = try JSONSerialization.jsonObject(with: argumentsData)
        guard let object = arguments as? [String: Any] else {
            throw EvaluationCustomToolRejectedError.argumentsMustBeObject
        }
        let body = try JSONSerialization.data(
            withJSONObject: ["toolName": toolName, "arguments": object],
            options: [.sortedKeys]
        )
        guard body.count <= EvaluationCustomToolDefinition.maximumArgumentBytes else {
            throw EvaluationCustomToolRejectedError.argumentsTooLarge
        }
        return body
    }

    /// Replaces schema-declared image references in argument JSON with metadata resolved from session history, propagating malformed JSON or unresolved-reference errors.
    static func resolvedArgumentsJSON<History: Sequence>(
        argumentsJSON: String,
        fields: [EvaluationSchemaField],
        definitions: [EvaluationSchemaField],
        history: History
    ) throws -> String where History.Element == Transcript.Entry {
        let argumentsData = Data(argumentsJSON.utf8)
        guard var object = try JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] else {
            throw EvaluationCustomToolRejectedError.argumentsMustBeObject
        }
        let definitionsByName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })

        for field in fields {
            guard let value = object[field.name] else { continue }
            object[field.name] = try resolveImageReferences(
                in: value,
                field: field,
                definitions: definitionsByName,
                history: history
            )
        }

        let resolvedData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: resolvedData, as: UTF8.self)
    }

    /// Recursively resolves image-reference fields through objects, arrays, named definitions, and a fully validated union alternative, preserving other values.
    private static func resolveImageReferences<History: Sequence>(
        in value: Any,
        field: EvaluationSchemaField,
        definitions: [String: EvaluationSchemaField],
        history: History
    ) throws -> Any where History.Element == Transcript.Entry {
        if field.isOptional, value is NSNull { return value }
        switch field.type {
        case .imageReference:
            return try resolvedImageMetadata(from: value, fieldName: field.name, history: history)
        case .object:
            guard var object = value as? [String: Any] else { return value }
            for child in field.children {
                guard let childValue = object[child.name] else { continue }
                object[child.name] = try resolveImageReferences(
                    in: childValue,
                    field: child,
                    definitions: definitions,
                    history: history
                )
            }
            return object
        case .array:
            guard let itemSchema = field.children.first,
                  let values = value as? [Any] else { return value }
            return try values.map {
                try resolveImageReferences(
                    in: $0,
                    field: itemSchema,
                    definitions: definitions,
                    history: history
                )
            }
        case .reference:
            guard let definition = definitions[field.referenceName] else {
                throw EvaluationFeatureConfigurationError.invalid(
                    "Image argument references undefined schema \(field.referenceName)."
                )
            }
            return try resolveImageReferences(
                in: value,
                field: definition,
                definitions: definitions,
                history: history
            )
        case .union:
            let valueData = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            let content = try GeneratedContent(json: String(decoding: valueData, as: UTF8.self))
            guard let choice = field.children.first(where: {
                containsImageReference(
                    field: $0,
                    definitions: definitions,
                    visitedDefinitions: []
                ) && EvaluationSchemaValidator.matches(content, field: $0, definitions: definitions)
            }) else { return value }
            return try resolveImageReferences(
                in: value,
                field: choice,
                definitions: definitions,
                history: history
            )
        case .string, .integer, .number, .boolean, .enumeration, .null:
            return value
        }
    }

    /// Resolves an image attachment label against session history and returns its label, dimensions, and orientation, throwing for invalid or missing references.
    private static func resolvedImageMetadata<History: Sequence>(
        from value: Any,
        fieldName: String,
        history: History
    ) throws -> [String: Any] where History.Element == Transcript.Entry {
        let valueData = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard let valueJSON = String(data: valueData, encoding: .utf8) else {
            throw EvaluationCustomToolError.invalidImageReference(field: fieldName)
        }

        let reference: ImageReference
        do {
            reference = try ImageReference(GeneratedContent(json: valueJSON))
        } catch {
            throw EvaluationCustomToolError.invalidImageReference(field: fieldName)
        }
        guard let attachment = reference.resolved(in: history) else {
            throw EvaluationCustomToolError.imageReferenceNotFound(label: reference.attachmentLabel)
        }
        let image = attachment.cgImage
        return [
            "kind": "imageReference",
            "attachmentLabel": reference.attachmentLabel,
            "width": image.width,
            "height": image.height,
            "orientation": Int(attachment.orientation.rawValue)
        ]
    }

    /// Reports whether any configured field reaches an image-reference schema through children or named definitions.
    private static func containsImageReference(
        fields: [EvaluationSchemaField],
        definitions: [EvaluationSchemaField]
    ) -> Bool {
        let definitionsByName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
        return fields.contains {
            containsImageReference(
                field: $0,
                definitions: definitionsByName,
                visitedDefinitions: []
            )
        }
    }

    /// Searches a field’s children and named definitions for image references while preventing repeated visits to named definitions.
    private static func containsImageReference(
        field: EvaluationSchemaField,
        definitions: [String: EvaluationSchemaField],
        visitedDefinitions: Set<String>
    ) -> Bool {
        if field.type == .imageReference { return true }
        if field.type == .reference,
           !visitedDefinitions.contains(field.referenceName),
           let definition = definitions[field.referenceName] {
            var visited = visitedDefinitions
            visited.insert(field.referenceName)
            return containsImageReference(
                field: definition,
                definitions: definitions,
                visitedDefinitions: visited
            )
        }
        return field.children.contains {
            containsImageReference(
                field: $0,
                definitions: definitions,
                visitedDefinitions: visitedDefinitions
            )
        }
    }
}

@available(macOS 27.0, *)
protocol EvaluationCustomToolHTTPClient: Sendable {
    /// Posts the supplied JSON body to a configured endpoint and returns response text, propagating transport or response validation errors.
    func post(body: Data, to endpoint: URL) async throws -> String
}

@available(macOS 27.0, *)
protocol EvaluationCustomToolTokenCounting: Sendable {
    /// Counts text tokens for argument and output admission, propagating tokenizer failures.
    func tokenCount(for text: String) async throws -> Int
}

@available(macOS 27.0, *)
struct EvaluationSystemModelTokenCounter: EvaluationCustomToolTokenCounting {
    /// Uses the system model tokenizer to count text represented as a prompt.
    func tokenCount(for text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: Prompt(text))
    }
}

@available(macOS 27.0, *)
final class EvaluationLocalHTTPToolClient: EvaluationCustomToolHTTPClient {
    private let session: URLSession

    /// Creates an ephemeral HTTP session with tool timeouts, disabled caches, cookies, credentials and proxies, and a delegate that refuses redirects.
    init() {
        session = EvaluationHTTPPolicy.isolatedSession(timeout: EvaluationCustomToolDefinition.requestTimeoutSeconds)
    }

    /// Uses the supplied HTTP session for tool requests and takes responsibility for invalidating it when this client is released.
    init(session: URLSession) {
        self.session = session
    }

    /// Invalidates the owned HTTP session and cancels its outstanding tasks.
    deinit {
        session.invalidateAndCancel()
    }

    /// Posts JSON and streams a successful HTTP response within the configured output byte limit.
    /// Throws for transport failures, non-2xx status, invalid UTF-8, oversized output, or cancellation, while recording available HTTP measurements.
    func post(body: Data, to endpoint: URL) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = EvaluationCustomToolDefinition.requestTimeoutSeconds
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")

        let context = EvaluationWorkflowHTTPContext.current
        var measurement = EvaluationWorkflowHTTPRequest(recorder: context?.recorder, parentID: context?.parentID,
            endpoint: endpoint, requestBytes: body.count)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw EvaluationCustomToolError.invalidHTTPResponse
            }
            measurement?.statusCode = response.statusCode
            guard (200...299).contains(response.statusCode) else {
                throw EvaluationCustomToolError.httpStatus(response.statusCode)
            }

            var data = Data()
            data.reserveCapacity(EvaluationCustomToolDefinition.maximumOutputBytes)
            for try await byte in bytes {
                measurement?.responseBytes += 1
                try Task.checkCancellation()
                guard data.count < EvaluationCustomToolDefinition.maximumOutputBytes else {
                    throw EvaluationCustomToolError.outputTooLarge
                }
                data.append(byte)
            }
            guard let output = String(data: data, encoding: .utf8) else {
                throw EvaluationCustomToolError.invalidOutputEncoding
            }
            measurement?.finish()
            return output
        } catch {
            measurement?.finish(error: error)
            throw error
        }
    }
}

/// Shared HTTP isolation for evaluation requests; each caller owns its session lifetime.
enum EvaluationHTTPPolicy {
    /// Creates an ephemeral configuration with matching timeouts and no cache, cookies, stored credentials or configured proxies.
    static func isolatedConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        return configuration
    }

    /// Creates an isolated session that refuses every redirect; the caller must invalidate it when its work ends.
    static func isolatedSession(timeout: TimeInterval) -> URLSession {
        URLSession(
            configuration: isolatedConfiguration(timeout: timeout),
            delegate: EvaluationNoRedirectDelegate(),
            delegateQueue: nil
        )
    }
}

final class EvaluationNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Refuses HTTP redirects by completing the redirect decision with no replacement request.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@available(macOS 27.0, *)
enum EvaluationCustomToolError: LocalizedError, Sendable {
    case callLimitReached(maximum: Int)
    case outputTooLarge
    case argumentTokenLimitExceeded(actual: Int, maximum: Int)
    case outputTokenLimitExceeded(actual: Int, maximum: Int)
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidOutputEncoding
    case invalidImageReference(field: String)
    case imageReferenceNotFound(label: String)

    var errorDescription: String? {
        switch self {
        case .callLimitReached(let maximum):
            "The run reached its \(maximum)-call custom tool limit."
        case .outputTooLarge:
            "The custom tool output exceeded \(EvaluationCustomToolDefinition.maximumOutputBytes) bytes."
        case .argumentTokenLimitExceeded(let actual, let maximum):
            "The custom tool arguments used \(actual) tokens, exceeding the \(maximum)-token argument limit."
        case .outputTokenLimitExceeded(let actual, let maximum):
            "The custom tool output used \(actual) tokens, exceeding the \(maximum)-token output limit."
        case .invalidHTTPResponse:
            "The custom tool endpoint did not return an HTTP response."
        case .httpStatus(let status):
            "The custom tool endpoint returned HTTP \(status)."
        case .invalidOutputEncoding:
            "The custom tool endpoint returned output that is not UTF-8."
        case .invalidImageReference(let field):
            "The custom tool received an invalid image reference for field \(field)."
        case .imageReferenceNotFound(let label):
            "The custom tool could not resolve image attachment \(label) in this session."
        }
    }

    fileprivate var isPolicyRejection: Bool {
        switch self {
        case .outputTooLarge, .argumentTokenLimitExceeded, .outputTokenLimitExceeded,
             .invalidImageReference, .imageReferenceNotFound:
            true
        case .callLimitReached, .invalidHTTPResponse, .httpStatus, .invalidOutputEncoding:
            false
        }
    }
}

@available(macOS 27.0, *)
private enum EvaluationCustomToolRejectedError: LocalizedError, Sendable {
    case argumentsTooLarge
    case argumentsMustBeObject

    var errorDescription: String? {
        switch self {
        case .argumentsTooLarge:
            "The custom tool request exceeded \(EvaluationCustomToolDefinition.maximumArgumentBytes) bytes."
        case .argumentsMustBeObject:
            "Custom tool arguments must be a JSON object."
        }
    }
}

@available(macOS 27.0, *)
private extension String {
    /// Returns a UTF-8 byte-prefix decoded with replacement characters if truncation splits an encoded scalar.
    func boundedUTF8(to maximumBytes: Int) -> String {
        let bytes = utf8
        guard bytes.count > maximumBytes else { return self }
        return String(decoding: bytes.prefix(maximumBytes), as: UTF8.self)
    }
}
