import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

enum EvaluationCustomToolCallOutcome: String, Codable, Equatable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
    case rejected
}

struct EvaluationCustomToolCallTrace: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var toolName: String
    var argumentsJSON: String
    var output: String?
    var durationMilliseconds: Double
    var outcome: EvaluationCustomToolCallOutcome
    var errorDescription: String?
}

actor EvaluationCustomToolRecorder {
    static let maximumCallsPerSample = 4
    private static let maximumErrorBytes = 1_024
    private static let maximumRecordedRejections = 4

    let maximumCalls: Int
    let workflowRecorder: EvaluationWorkflowRecorder?
    private let callLimiter: EvaluationToolCallLimiter
    private var rejectedCallCount = 0
    private var traces: [EvaluationCustomToolCallTrace] = []

    init(maximumCalls: Int, callLimiter: EvaluationToolCallLimiter? = nil, workflowRecorder: EvaluationWorkflowRecorder? = nil) {
        self.workflowRecorder = workflowRecorder
        self.maximumCalls = min(max(0, maximumCalls), Self.maximumCallsPerSample)
        self.callLimiter = callLimiter ?? EvaluationToolCallLimiter(maximumCalls: maximumCalls)
    }

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

    func updateArguments(id: UUID, argumentsJSON: String) {
        guard let index = traces.firstIndex(where: { $0.id == id }) else { return }
        traces[index].argumentsJSON = argumentsJSON.boundedUTF8(
            to: EvaluationCustomToolDefinition.maximumArgumentBytes
        )
    }

    func snapshot() -> [EvaluationCustomToolCallTrace] {
        traces
    }

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

    static func makeTools(
        definitions: [EvaluationCustomToolDefinition],
        recorder: EvaluationCustomToolRecorder
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
        return try definitions.map { try EvaluationCustomTool(definition: $0, recorder: recorder) }
    }

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
            guard output.utf8.count <= EvaluationCustomToolDefinition.maximumOutputBytes else {
                throw EvaluationCustomToolError.outputTooLarge
            }
            let outputTokenCount = try await tokenCounter.tokenCount(for: output)
            guard outputTokenCount <= Self.maximumOutputTokens else {
                throw EvaluationCustomToolError.outputTokenLimitExceeded(
                    actual: outputTokenCount,
                    maximum: Self.maximumOutputTokens
                )
            }

            await recorder.finishCall(
                id: callID,
                output: output,
                durationMilliseconds: start.milliseconds(to: .now),
                outcome: .succeeded
            )
            workflow?.finish(spanID, metadata: ["outputBytes": String(output.utf8.count)])
            return output
        } catch is CancellationError {
            await recorder.finishCall(
                id: callID,
                output: observedOutput,
                durationMilliseconds: start.milliseconds(to: .now),
                outcome: .cancelled,
                errorDescription: "The custom tool call was cancelled."
            )
            workflow?.finish(spanID, status: .cancelled, errorMessage: "The custom tool call was cancelled.")
            throw CancellationError()
        } catch {
            let outcome: EvaluationCustomToolCallOutcome
            if EvaluationWorkflowRecorder.status(for: error) == .cancelled {
                outcome = .cancelled
            } else if error is EvaluationCustomToolRejectedError {
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
                durationMilliseconds: start.milliseconds(to: .now),
                outcome: outcome,
                errorDescription: error.localizedDescription
            )
            workflow?.finish(spanID, status: EvaluationWorkflowRecorder.status(for: error), errorMessage: error.localizedDescription)
            throw error
        }
    }

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

    private static func resolveImageReferences<History: Sequence>(
        in value: Any,
        field: EvaluationSchemaField,
        definitions: [String: EvaluationSchemaField],
        history: History
    ) throws -> Any where History.Element == Transcript.Entry {
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
            guard let choice = field.children.first(where: {
                containsImageReference(
                    field: $0,
                    definitions: definitions,
                    visitedDefinitions: []
                ) && valueCouldMatch(value, field: $0, definitions: definitions)
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

    private static func valueCouldMatch(
        _ value: Any,
        field: EvaluationSchemaField,
        definitions: [String: EvaluationSchemaField]
    ) -> Bool {
        switch field.type {
        case .object:
            guard let object = value as? [String: Any] else { return false }
            return field.children.filter { !$0.isOptional }.allSatisfy {
                object[$0.name] != nil
            }
        case .array: return value is [Any]
        case .imageReference:
            guard let object = value as? [String: Any] else { return false }
            return object["attachmentLabel"] is String
        case .reference:
            guard let definition = definitions[field.referenceName] else { return false }
            return valueCouldMatch(value, field: definition, definitions: definitions)
        case .string, .enumeration: return value is String
        case .integer: return value is Int
        case .number: return value is NSNumber
        case .boolean: return value is Bool
        case .null: return value is NSNull
        case .union: return true
        }
    }
}

protocol EvaluationCustomToolHTTPClient: Sendable {
    func post(body: Data, to endpoint: URL) async throws -> String
}

protocol EvaluationCustomToolTokenCounting: Sendable {
    func tokenCount(for text: String) async throws -> Int
}

struct EvaluationSystemModelTokenCounter: EvaluationCustomToolTokenCounting {
    func tokenCount(for text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: Prompt(text))
    }
}

final class EvaluationLocalHTTPToolClient: EvaluationCustomToolHTTPClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = EvaluationCustomToolDefinition.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = EvaluationCustomToolDefinition.requestTimeoutSeconds
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        session = URLSession(
            configuration: configuration,
            delegate: EvaluationNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    init(session: URLSession) {
        self.session = session
    }

    deinit {
        session.invalidateAndCancel()
    }

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

final class EvaluationNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

private extension ContinuousClock.Instant {
    func milliseconds(to end: ContinuousClock.Instant) -> Double {
        let components = duration(to: end).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private extension String {
    func boundedUTF8(to maximumBytes: Int) -> String {
        let bytes = utf8
        guard bytes.count > maximumBytes else { return self }
        return String(decoding: bytes.prefix(maximumBytes), as: UTF8.self)
    }
}
