import Foundation

/// The complete domain boundary required by the MCP transport.
///
/// Integration supplies one handler for every `MCPToolCall` and one handler for
/// `attachment` and `run` resource reads. Mutation handlers return an outcome of
/// `committed`, `duplicate`, `conflicted`, or `failed` in `structuredContent`;
/// the transport owns protocol validation and never reaches into the store.
struct MCPAuthority: Sendable {
    let call: @Sendable (MCPToolCall) async -> MCPToolPayload
    let readResource: @Sendable (MCPResourceRequest) async -> MCPResourcePayload

    init(
        call: @escaping @Sendable (MCPToolCall) async -> MCPToolPayload,
        readResource: @escaping @Sendable (MCPResourceRequest) async -> MCPResourcePayload
    ) {
        self.call = call
        self.readResource = readResource
    }
}

struct MCPToolPayload: Sendable {
    var structuredContent: MCPJSONValue
    var isError: Bool

    init(structuredContent: MCPJSONValue, isError: Bool = false) {
        self.structuredContent = structuredContent
        self.isError = isError
    }

    static func failure(code: String, message: String) -> Self {
        Self(
            structuredContent: .object([
                "outcome": .string("failed"),
                "error": .object(["code": .string(code), "message": .string(message)])
            ]),
            isError: true
        )
    }
}

enum MCPResourceRequest: Equatable, Sendable {
    case attachment(UUID)
    case run(UUID)

    init?(uri: String) {
        let mappings: [(String, (UUID) -> Self)] = [
            ("foundation-evals://attachments/", Self.attachment),
            ("foundation-evals://runs/", Self.run)
        ]
        for (prefix, make) in mappings where uri.hasPrefix(prefix) {
            let suffix = String(uri.dropFirst(prefix.count))
            guard !suffix.contains("/"), !suffix.contains("?"), !suffix.contains("#"), let id = UUID(uuidString: suffix) else {
                return nil
            }
            self = make(id)
            return
        }
        return nil
    }
}

struct MCPResourcePayload: Sendable {
    var uri: String
    var mimeType: String
    var text: String?
    var blob: Data?
    var isError: Bool

    static func text(uri: String, mimeType: String, text: String) -> Self {
        Self(uri: uri, mimeType: mimeType, text: text, blob: nil, isError: false)
    }

    static func blob(uri: String, mimeType: String, data: Data) -> Self {
        Self(uri: uri, mimeType: mimeType, text: nil, blob: data, isError: false)
    }

    static func failure(uri: String, code: String, message: String) -> Self {
        let value = MCPJSONValue.object([
            "outcome": .string("failed"),
            "error": .object(["code": .string(code), "message": .string(message)])
        ])
        return Self(
            uri: uri,
            mimeType: "application/json",
            text: (try? value.jsonText()) ?? #"{"outcome":"failed"}"#,
            blob: nil,
            isError: true
        )
    }
}

enum MCPToolCall: Sendable {
    case getState
    case replaceSuite(MCPReplaceSuiteArguments)
    case uploadAttachment(MCPUploadAttachmentArguments)
    case removeAttachment(MCPRemoveAttachmentArguments)
    case startRun(MCPStartRunArguments)
    case getRun(MCPGetRunArguments)
    case listRuns(MCPListRunsArguments)
    case analyzeRun(MCPAnalyzeRunArguments)
    case cancelRun(MCPCancelRunArguments)
    case deleteRun(MCPDeleteRunArguments)
}

struct MCPReplaceSuiteArguments: Codable, Sendable {
    var expectedRevision: String
    var confirmDeletes: Bool?
    var suite: MCPSuiteDeclaration
}

struct MCPSuiteDeclaration: Codable, Sendable {
    var name: String
    var version: String
    var instructions: String
    var scoringMode: MCPScoringMode
    var repetitions: Int
    var rubricRequirements: [String]
    var modelConfiguration: MCPModelConfiguration
    /// Omitted by legacy clients. The authority preserves the currently stored value in that case.
    var features: EvaluationFeatureConfiguration? = nil
    var cases: [MCPCaseDeclaration]
}

struct MCPCaseDeclaration: Codable, Sendable {
    var id: UUID
    var name: String
    var prompt: String
    var expected: String
    var conversation: EvaluationConversationConfiguration? = nil
    /// Legacy clients omit this; preserve stored assertions for a matching case ID.
    var fieldAssertions: [EvaluationFieldAssertion]? = nil
}

enum MCPScoringMode: String, Codable, CaseIterable, Sendable {
    case review, exactMatch, containsExpected, modelJudge
}

enum MCPSamplingMode: String, Codable, CaseIterable, Sendable {
    case automatic, greedy, topK, probability
}

enum MCPReferenceMode: String, Codable, CaseIterable, Sendable {
    case inline, lookupTool
}

enum MCPContextPolicy: String, Codable, CaseIterable, Sendable {
    case fitReferences, requireFullInput
}

struct MCPModelConfiguration: Codable, Sendable {
    /// Omitted by legacy clients. The authority preserves the currently stored provider in that case.
    var provider: EvaluationModelProvider? = nil
    /// Omitted by legacy clients. The authority preserves the currently stored custom-provider settings.
    var customProvider: MCPCustomProviderConfiguration? = nil
    /// Omitted by legacy clients. The authority preserves the currently stored Core AI settings.
    var coreAI: MCPCoreAIConfiguration? = nil
    var customization: EvaluationModelCustomization? = nil
    var reasoningLevel: EvaluationReasoningLevel? = nil
    var samplingMode: MCPSamplingMode
    var temperatureEnabled: Bool
    var temperature: Double
    var seedEnabled: Bool
    var seed: UInt64
    var topK: Int
    var probabilityThreshold: Double
    var maximumResponseTokens: Int
    var maximumInputTokens: Int?
    var referenceMode: MCPReferenceMode
    var contextPolicy: MCPContextPolicy
    var maximumToolCalls: Int
}

enum MCPModelCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case vision, guidedGeneration, reasoning, toolCalling
}

struct MCPCustomProviderConfiguration: Codable, Sendable {
    var endpoint: String
    var contextSize: Int
    var capabilities: [MCPModelCapability]
    var requestTimeoutSeconds: Double

    init(_ configuration: EvaluationCustomProviderConfiguration) {
        endpoint = configuration.endpoint
        contextSize = configuration.contextSize
        capabilities = [
            configuration.supportsVision ? .vision : nil,
            configuration.supportsGuidedGeneration ? .guidedGeneration : nil,
            configuration.supportsReasoning ? .reasoning : nil,
            configuration.supportsToolCalling ? .toolCalling : nil
        ].compactMap { $0 }
        requestTimeoutSeconds = configuration.requestTimeoutSeconds
    }

    var evaluationConfiguration: EvaluationCustomProviderConfiguration {
        let declared = Set(capabilities)
        return EvaluationCustomProviderConfiguration(
            endpoint: endpoint,
            contextSize: contextSize,
            supportsVision: declared.contains(.vision),
            supportsGuidedGeneration: declared.contains(.guidedGeneration),
            supportsReasoning: declared.contains(.reasoning),
            supportsToolCalling: declared.contains(.toolCalling),
            requestTimeoutSeconds: requestTimeoutSeconds
        )
    }

    var validationIssue: String? {
        guard Set(capabilities).count == capabilities.count else {
            return "Custom provider capabilities must be unique."
        }
        return evaluationConfiguration.validationIssue
    }
}

struct MCPCoreAIConfiguration: Codable, Sendable {
    var resourcesPath: String
    var resourcesBookmark: Data?

    init(_ configuration: EvaluationCoreAIConfiguration) {
        resourcesPath = configuration.resourcesPath
        resourcesBookmark = configuration.resourcesBookmark
    }

    var evaluationConfiguration: EvaluationCoreAIConfiguration {
        EvaluationCoreAIConfiguration(
            resourcesPath: resourcesPath,
            resourcesBookmark: resourcesBookmark
        )
    }
}

struct MCPUploadAttachmentArguments: Codable, Sendable {
    var id: UUID
    var name: String
    var mediaType: String
    var dataBase64: Data
    var expectedRevision: String
}

struct MCPRemoveAttachmentArguments: Codable, Sendable {
    var id: UUID
    var expectedRevision: String
    var confirm: Bool
}

struct MCPStartRunArguments: Codable, Sendable {
    var runID: UUID
    var expectedRevision: String
}

struct MCPGetRunArguments: Codable, Sendable {
    var runID: UUID
    var cursor: String?
    var limit: Int?
}

struct MCPAnalyzeRunArguments: Codable, Sendable {
    var runID: UUID
    var baselineRunID: UUID?
}

struct MCPListRunsArguments: Codable, Sendable {
    var cursor: String?
    var limit: Int?
    var query: String?
    var status: String?
}

struct MCPCancelRunArguments: Codable, Sendable {
    var runID: UUID
}

struct MCPDeleteRunArguments: Codable, Sendable {
    var runID: UUID
    var confirm: Bool
}

struct MCPToolDefinition: Codable, Sendable {
    struct Annotations: Codable, Sendable {
        var readOnlyHint: Bool
        var destructiveHint: Bool
        var idempotentHint: Bool
        var openWorldHint = false
    }

    var name: String
    var title: String
    var description: String
    var inputSchema: MCPJSONValue
    var annotations: Annotations
}

enum MCPToolCatalog {
    static let definitions: [MCPToolDefinition] = [
        tool(
            "eval_get_state", "Get evaluation state",
            "Read the shared suite, Foundation Models feature configuration, revision, readiness, limits, capabilities, attachments, and active run.",
            properties: [:], required: [], readOnly: true
        ),
        tool(
            "eval_replace_suite", "Replace evaluation suite",
            "Atomically replace editable suite fields and ordered cases while preserving suite identity and attachments. Include suite.features to replace the Foundation Models feature configuration; omit it to preserve the current configuration.",
            properties: [
                "expectedRevision": string("Revision returned by eval_get_state."),
                "confirmDeletes": boolean("Must be true when existing cases are omitted."),
                "suite": suiteSchema
            ], required: ["expectedRevision", "suite"], idempotent: true
        ),
        tool(
            "eval_upload_attachment", "Upload attachment",
            "Upload one bounded text, PDF, or image attachment. Filesystem paths are never accepted.",
            properties: [
                "id": uuid("Stable caller-supplied attachment UUID."),
                "name": string("Display filename."),
                "mediaType": string("Declared MIME type."),
                "dataBase64": string("Base64-encoded file bytes.", contentEncoding: "base64"),
                "expectedRevision": string("Revision returned by eval_get_state.")
            ], required: ["id", "name", "mediaType", "dataBase64", "expectedRevision"], idempotent: true
        ),
        tool(
            "eval_remove_attachment", "Remove attachment",
            "Remove a suite attachment by its opaque UUID.",
            properties: [
                "id": uuid("Attachment UUID."),
                "expectedRevision": string("Revision returned by eval_get_state."),
                "confirm": boolean("Must be true.")
            ], required: ["id", "expectedRevision", "confirm"], destructive: true, idempotent: true
        ),
        tool(
            "eval_start_run", "Start evaluation run",
            "Validate the shared suite and start one durable asynchronous run. Reuse the same run UUID after an uncertain response.",
            properties: [
                "runID": uuid("Stable caller-supplied run UUID."),
                "expectedRevision": string("Exact suite revision to execute.")
            ], required: ["runID", "expectedRevision"], idempotent: true
        ),
        tool(
            "eval_get_run", "Get evaluation run",
            "Read active progress or paginated terminal results, traces, and errors.",
            properties: [
                "runID": uuid("Run UUID."),
                "cursor": string("Opaque cursor returned by this tool."),
                "limit": integer("Maximum results to return.", minimum: 1, maximum: 50)
            ], required: ["runID"], readOnly: true
        ),
        tool(
            "eval_list_runs", "List evaluation runs",
            "List cursor-paginated run summaries with optional text and status filters.",
            properties: [
                "cursor": string("Opaque cursor returned by this tool."),
                "limit": integer("Maximum summaries to return.", minimum: 1, maximum: 50),
                "query": string("Optional suite-name or version search."),
                "status": string("Optional run status filter.")
            ], required: [], readOnly: true
        ),
        tool(
            "eval_analyze_run", "Analyze evaluation run",
            "Summarize a saved run's coverage, per-case repeatability, latency and subject/judge token usage. Optionally compare a saved baseline, reporting incompatible cases and incomplete evidence explicitly. Does not run the model.",
            properties: [
                "runID": uuid("Saved candidate run UUID."),
                "baselineRunID": uuid("Optional saved baseline run UUID.")
            ], required: ["runID"], readOnly: true
        ),
        tool(
            "eval_cancel_run", "Cancel evaluation run",
            "Request cooperative cancellation of the identified active run; poll eval_get_run for its terminal state.",
            properties: ["runID": uuid("Run UUID.")], required: ["runID"], idempotent: true
        ),
        tool(
            "eval_delete_run", "Delete evaluation run",
            "Permanently delete a terminal run and its persisted trace.",
            properties: [
                "runID": uuid("Run UUID."),
                "confirm": boolean("Must be true.")
            ], required: ["runID", "confirm"], destructive: true, idempotent: true
        )
    ]

    static let resourceTemplates: [MCPJSONValue] = [
        .object([
            "name": .string("evaluation_attachment"),
            "title": .string("Evaluation attachment"),
            "uriTemplate": .string("foundation-evals://attachments/{attachmentID}"),
            "description": .string("Bounded extracted text or image bytes for a suite attachment.")
        ]),
        .object([
            "name": .string("evaluation_run"),
            "title": .string("Evaluation run export"),
            "uriTemplate": .string("foundation-evals://runs/{runID}"),
            "description": .string("Canonical complete JSON export for a persisted evaluation run."),
            "mimeType": .string("application/json")
        ])
    ]

    static func parse(name: String, arguments: MCPJSONValue) throws -> MCPToolCall {
        guard let definition = definitions.first(where: { $0.name == name }) else {
            throw MCPToolInputError.unknownTool
        }
        do {
            try rejectUndeclaredProperties(in: arguments, schema: definition.inputSchema)
            switch name {
            case "eval_get_state":
                let object = try requireObject(arguments)
                guard object.isEmpty else { throw MCPToolInputError.invalidArguments }
                return .getState
            case "eval_replace_suite":
                if arguments.objectValue?["suite"]?.objectValue?["features"] == .null {
                    throw MCPToolInputError.invalidArguments
                }
                let value = try arguments.decode(MCPReplaceSuiteArguments.self)
                try validate(value)
                return .replaceSuite(value)
            case "eval_upload_attachment":
                let value = try arguments.decode(MCPUploadAttachmentArguments.self)
                guard !value.name.isEmpty, !value.mediaType.isEmpty, !value.expectedRevision.isEmpty else {
                    throw MCPToolInputError.invalidArguments
                }
                return .uploadAttachment(value)
            case "eval_remove_attachment":
                let value = try arguments.decode(MCPRemoveAttachmentArguments.self)
                guard value.confirm, !value.expectedRevision.isEmpty else { throw MCPToolInputError.confirmationRequired }
                return .removeAttachment(value)
            case "eval_start_run":
                let value = try arguments.decode(MCPStartRunArguments.self)
                guard !value.expectedRevision.isEmpty else { throw MCPToolInputError.invalidArguments }
                return .startRun(value)
            case "eval_get_run":
                let value = try arguments.decode(MCPGetRunArguments.self)
                try validatePage(cursor: value.cursor, limit: value.limit)
                return .getRun(value)
            case "eval_list_runs":
                let value = try arguments.decode(MCPListRunsArguments.self)
                try validatePage(cursor: value.cursor, limit: value.limit)
                guard (value.query?.count ?? 0) <= 1_024, (value.status?.count ?? 0) <= 64 else {
                    throw MCPToolInputError.invalidArguments
                }
                return .listRuns(value)
            case "eval_analyze_run":
                return .analyzeRun(try arguments.decode(MCPAnalyzeRunArguments.self))
            case "eval_cancel_run":
                return .cancelRun(try arguments.decode(MCPCancelRunArguments.self))
            case "eval_delete_run":
                let value = try arguments.decode(MCPDeleteRunArguments.self)
                guard value.confirm else { throw MCPToolInputError.confirmationRequired }
                return .deleteRun(value)
            default:
                throw MCPToolInputError.unknownTool
            }
        } catch let error as MCPToolInputError {
            throw error
        } catch {
            throw MCPToolInputError.invalidArguments
        }
    }

    private static func validate(_ arguments: MCPReplaceSuiteArguments) throws {
        let suite = arguments.suite
        guard !arguments.expectedRevision.isEmpty,
              (1...5).contains(suite.repetitions),
              (1...100).contains(suite.cases.count),
              suite.cases.count * suite.repetitions <= 100,
              (1...4).contains(suite.rubricRequirements.count),
              suite.instructions.count <= 32_000,
              suite.rubricRequirements.allSatisfy({ !$0.isEmpty && $0.count <= 4_000 }),
              suite.cases.allSatisfy({
                  !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.prompt.count <= 32_000
                      && $0.expected.count <= 32_000
                      && $0.conversation?.validationIssue == nil
                      && EvaluationFieldAssertions.validationIssue(
                          assertions: $0.fieldAssertions ?? [],
                          scoringMode: ScoringMode(rawValue: suite.scoringMode.rawValue)!
                      ) == nil
              }),
              !suite.scoringMode.requiresExpected
                  || suite.cases.allSatisfy({ !$0.expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(suite.cases.map(\MCPCaseDeclaration.id)).count == suite.cases.count,
              suite.name.count + suite.version.count + suite.instructions.count
                + suite.rubricRequirements.reduce(0, { $0 + $1.count })
                + suite.cases.reduce(0, {
                        $0 + $1.name.count + $1.prompt.count + $1.expected.count
                        + ($1.conversation?.textCharacterCount ?? 0)
                        + ($1.fieldAssertions ?? []).reduce(0) {
                            $0 + $1.pointer.count + $1.expectedValue.count
                        }
                }) <= 256_000,
              suite.modelConfiguration.temperature.isFinite,
              (0...1).contains(suite.modelConfiguration.temperature),
              (1...1_000).contains(suite.modelConfiguration.topK),
              (0.01...1).contains(suite.modelConfiguration.probabilityThreshold),
              (128...4_096).contains(suite.modelConfiguration.maximumResponseTokens),
              suite.modelConfiguration.maximumInputTokens.map({ (512...32_768).contains($0) }) ?? true,
              (1...4).contains(suite.modelConfiguration.maximumToolCalls),
              suite.modelConfiguration.customProvider?.validationIssue == nil,
              suite.modelConfiguration.coreAI.map({
                  $0.resourcesPath.utf8.count <= 32_000
              }) ?? true,
              suite.features?.validationIssue == nil
        else { throw MCPToolInputError.invalidArguments }
    }

    private static func validatePage(cursor: String?, limit: Int?) throws {
        guard (cursor?.count ?? 0) <= 512, (1...50).contains(limit ?? 50) else {
            throw MCPToolInputError.invalidArguments
        }
    }

    private static func requireObject(_ value: MCPJSONValue) throws -> [String: MCPJSONValue] {
        guard let object = value.objectValue else { throw MCPToolInputError.invalidArguments }
        return object
    }

    private static func rejectUndeclaredProperties(
        in value: MCPJSONValue,
        schema: MCPJSONValue
    ) throws {
        guard let schema = schema.objectValue else { return }

        if schema["type"]?.stringValue == "object",
           let object = value.objectValue,
           let properties = schema["properties"]?.objectValue {
            guard object.keys.allSatisfy({ properties[$0] != nil }) else {
                throw MCPToolInputError.invalidArguments
            }
            for (name, propertyValue) in object {
                if let propertySchema = properties[name] {
                    try rejectUndeclaredProperties(in: propertyValue, schema: propertySchema)
                }
            }
        } else if schema["type"]?.stringValue == "array",
                  case .array(let values) = value,
                  let itemSchema = schema["items"] {
            for item in values {
                try rejectUndeclaredProperties(in: item, schema: itemSchema)
            }
        }
    }

    private static func tool(
        _ name: String,
        _ title: String,
        _ description: String,
        properties: [String: MCPJSONValue],
        required: [String],
        readOnly: Bool = false,
        destructive: Bool = false,
        idempotent: Bool = false
    ) -> MCPToolDefinition {
        MCPToolDefinition(
            name: name,
            title: title,
            description: description,
            inputSchema: object(properties: properties, required: required),
            annotations: .init(
                readOnlyHint: readOnly,
                destructiveHint: destructive,
                idempotentHint: idempotent
            )
        )
    }

    private static let suiteSchema = object(
        properties: [
            "name": string("Suite name."),
            "version": string("User-visible suite version."),
            "instructions": string("Instructions shared by every case.", maximumLength: 32_000),
            "scoringMode": string(enum: MCPScoringMode.allRawValues),
            "repetitions": integer("Samples per case.", minimum: 1, maximum: 5),
            "rubricRequirements": array(items: string(maximumLength: 4_000), minimum: 1, maximum: 4),
            "modelConfiguration": object(
                properties: [
                    "provider": string(enum: EvaluationModelProvider.allCases.map(\.rawValue)),
                    "customProvider": object(
                        properties: [
                            "endpoint": string(
                                "Explicit http://127.0.0.1:<port> generation endpoint.",
                                maximumLength: 2_048
                            ),
                            "contextSize": integer(minimum: 1, maximum: 262_144),
                            "capabilities": uniqueStringArray(
                                enum: MCPModelCapability.allRawValues,
                                maximum: MCPModelCapability.allCases.count
                            ),
                            "requestTimeoutSeconds": number(minimum: 0.1, maximum: 60)
                        ],
                        required: ["endpoint", "contextSize", "capabilities", "requestTimeoutSeconds"]
                    ),
                    "coreAI": object(
                        properties: [
                            "resourcesPath": string(
                                "Path to the exported Core AI model resource folder.",
                                maximumLength: 32_000
                            ),
                            "resourcesBookmark": string(
                                "Optional base64-encoded security-scoped bookmark for the resource folder.",
                                contentEncoding: "base64"
                            )
                        ],
                        required: ["resourcesPath"]
                    ),
                    "customization": object(properties: [
                        "useCase": string(enum: EvaluationSystemUseCase.allCases.map(\.rawValue)),
                        "guardrails": string(enum: EvaluationGuardrails.allCases.map(\.rawValue)),
                        "schemaPrompt": string(enum: EvaluationSchemaPromptPolicy.allCases.map(\.rawValue)),
                        "toolCalling": string(enum: EvaluationToolCallingPolicy.allCases.map(\.rawValue)),
                        "customReasoning": string(maximumLength: 128),
                        "transcriptErrorPolicy": string(enum: EvaluationTranscriptErrorPolicy.allCases.map(\.rawValue)),
                        "saveFullTranscript": boolean(),
                        "prewarmPrefix": string(maximumLength: 4_096),
                        "prewarmLeadSeconds": number(minimum: 0, maximum: 10),
                        "visionTools": object(properties: [
                            "ocrEnabled": boolean(), "barcodeEnabled": boolean()
                        ], required: ["ocrEnabled", "barcodeEnabled"])
                    ], required: ["useCase", "guardrails", "schemaPrompt", "toolCalling"]),
                    "reasoningLevel": string(enum: EvaluationReasoningLevel.allCases.map(\.rawValue)),
                    "samplingMode": string(enum: MCPSamplingMode.allRawValues),
                    "temperatureEnabled": boolean(),
                    "temperature": number(minimum: 0, maximum: 1),
                    "seedEnabled": boolean(),
                    "seed": integer("Unsigned sampling seed.", minimum: 0),
                    "topK": integer(minimum: 1, maximum: 1_000),
                    "probabilityThreshold": number(minimum: 0.01, maximum: 1),
                    "maximumResponseTokens": integer(minimum: 128, maximum: 4_096),
                    "maximumInputTokens": nullableInteger(minimum: 512, maximum: 32_768),
                    "referenceMode": string(enum: MCPReferenceMode.allRawValues),
                    "contextPolicy": string(enum: MCPContextPolicy.allRawValues),
                    "maximumToolCalls": integer(minimum: 1, maximum: 4)
                ],
                required: [
                    "samplingMode", "temperatureEnabled", "temperature", "seedEnabled", "seed", "topK",
                    "probabilityThreshold", "maximumResponseTokens", "maximumInputTokens", "referenceMode",
                    "contextPolicy", "maximumToolCalls"
                ]
            ),
            "features": object(
                properties: [
                    "tools": array(
                        items: object(
                            properties: [
                                "id": uuid("Stable custom tool UUID."),
                                "name": string(
                                    "Foundation Models tool identifier.",
                                    maximumLength: EvaluationCustomToolDefinition.maximumNameCharacters
                                ),
                                "description": string(
                                    "Description provided to the model.",
                                    maximumLength: EvaluationCustomToolDefinition.maximumDescriptionCharacters
                                ),
                                "parameters": array(
                                    items: schemaFieldSchema(
                                        remainingDepth: EvaluationFeatureConfiguration.maximumSchemaDepth
                                    ),
                                    minimum: 0,
                                    maximum: EvaluationCustomToolDefinition.maximumParameters
                                ),
                                "schemaDefinitions": array(
                                    items: schemaFieldSchema(
                                        remainingDepth: EvaluationFeatureConfiguration.maximumSchemaDepth
                                    ),
                                    minimum: 0,
                                    maximum: EvaluationCustomToolDefinition.maximumParameters
                                ),
                                "representNilExplicitlyInGeneratedContent": boolean(
                                    "Include null for missing optional properties in the tool argument object."
                                ),
                                "mode": string(
                                    "Fixture returns a canned result. Local HTTP executes developer-configured code on an explicit loopback endpoint.",
                                    enum: EvaluationCustomToolMode.allRawValues
                                ),
                                "fixtureResponse": string(
                                    "Canned result returned in fixture mode.",
                                    maximumLength: EvaluationCustomToolDefinition.maximumOutputBytes
                                ),
                                "endpoint": string(
                                    "Explicit http://127.0.0.1:<port> endpoint used in localHTTP mode. Remote and implicit endpoints are rejected.",
                                    maximumLength: EvaluationCustomToolDefinition.maximumEndpointCharacters
                                )
                            ],
                            required: [
                                "id", "name", "description", "parameters", "mode", "fixtureResponse", "endpoint"
                            ]
                        ),
                        minimum: 0,
                        maximum: EvaluationFeatureConfiguration.maximumTools
                    ),
                    "profile": object(
                        properties: [
                            "enabled": boolean(),
                            "name": string(
                                "Profile name.",
                                maximumLength: EvaluationProfileConfiguration.maximumNameCharacters
                            ),
                            "afterToolInstructions": string(
                                "Instructions applied after a tool response.",
                                maximumLength: EvaluationProfileConfiguration.maximumInstructionsBytes
                            ),
                            "requireToolFirst": boolean(),
                            "afterToolSamplingMode": string(
                                enum: EvaluationSamplingMode.allCases.map(\.rawValue)
                            ),
                            "afterToolTemperatureEnabled": boolean(),
                            "afterToolTemperature": number(minimum: 0, maximum: 1),
                            "afterToolSeedEnabled": boolean(),
                            "afterToolSeed": integer("Unsigned after-tool sampling seed.", minimum: 0),
                            "afterToolTopK": integer(minimum: 1, maximum: 1_000),
                            "afterToolProbabilityThreshold": number(minimum: 0.01, maximum: 1),
                            "afterToolMaximumResponseTokens": nullableInteger(minimum: 128, maximum: 4_096),
                            "afterToolReasoningLevel": string(
                                enum: EvaluationReasoningLevel.allCases.map(\.rawValue)
                            ),
                            "afterToolCustomReasoning": string(
                                maximumLength: EvaluationProfileConfiguration.maximumCustomReasoningBytes
                            ),
                            "afterToolTranscriptErrorPolicy": string(
                                enum: EvaluationTranscriptErrorPolicy.allCases.map(\.rawValue)
                            )
                        ],
                        required: ["enabled", "name", "afterToolInstructions", "requireToolFirst"]
                    ),
                    "spotlightSearch": spotlightSearchSchema,
                    "outputFields": array(
                        items: schemaFieldSchema(
                            remainingDepth: EvaluationFeatureConfiguration.maximumSchemaDepth
                        ),
                        minimum: 0,
                        maximum: EvaluationFeatureConfiguration.maximumOutputFields
                    ),
                    "outputSchemaDefinitions": array(
                        items: schemaFieldSchema(
                            remainingDepth: EvaluationFeatureConfiguration.maximumSchemaDepth
                        ),
                        minimum: 0,
                        maximum: EvaluationCustomToolDefinition.maximumParameters
                    ),
                    "outputRepresentNilExplicitlyInGeneratedContent": boolean(
                        "Include null for missing optional properties in the response object."
                    ),
                    "prewarm": boolean("Prewarm the on-device Foundation Models session before timed generation."),
                    "streamResponse": boolean("Stream response snapshots while retaining the final generated response.")
                ],
                required: ["tools", "profile", "outputFields", "prewarm", "streamResponse"]
            ),
            "cases": array(
                items: object(
                    properties: [
                        "id": uuid("Stable case UUID."),
                        "name": string("Case name."),
                        "prompt": string("Evaluation prompt.", maximumLength: 32_000),
                        "expected": string("Expected or reference answer.", maximumLength: 32_000),
                        "fieldAssertions": array(
                            items: object(
                                properties: [
                                    "id": uuid("Stable field assertion UUID."),
                                    "pointer": string(
                                        "JSON Pointer into the complete serialized response.",
                                        maximumLength: EvaluationStore.maximumFieldCharacters
                                    ),
                                    "operation": string(
                                        "Assertion operation.",
                                        enum: EvaluationFieldAssertionOperation.allCases.map(\.rawValue)
                                    ),
                                    "expectedValue": string(
                                        "JSON value or text used by the assertion operation.",
                                        maximumLength: EvaluationStore.maximumFieldCharacters
                                    )
                                ],
                                required: ["id", "pointer", "operation", "expectedValue"]
                            ),
                            minimum: 0,
                            maximum: EvaluationFieldAssertions.maximumAssertions
                        ),
                        "conversation": object(
                            properties: [
                                "setupTurns": array(
                                    items: object(
                                        properties: [
                                            "id": uuid("Stable setup-turn UUID."),
                                            "prompt": string(
                                                "Prompt generated before the scored prompt.",
                                                maximumLength: EvaluationConversationConfiguration.maximumPromptCharacters
                                            )
                                        ],
                                        required: ["id", "prompt"]
                                    ),
                                    minimum: 0,
                                    maximum: EvaluationConversationConfiguration.maximumSetupTurns
                                ),
                                "restoredTranscriptJSON": string(
                                    "Optional raw Foundation Models Transcript JSON used to seed history.",
                                    maximumLength: EvaluationConversationConfiguration.maximumRestoredTranscriptCharacters
                                ),
                                "historyPolicy": string(enum: EvaluationHistoryPolicy.allCases.map(\.rawValue)),
                                "retainedTurnCount": integer(
                                    "Complete prompt-to-response turns retained before the scored prompt.",
                                    minimum: 1,
                                    maximum: EvaluationConversationConfiguration.maximumRetainedTurns
                                ),
                                "modelHistoryProjection": object(
                                    properties: [
                                        "policy": string(
                                            enum: EvaluationModelHistoryProjectionPolicy.allCases.map(\.rawValue)
                                        ),
                                        "retainedTurnCount": integer(
                                            "Complete turns exposed to the model on each request.",
                                            minimum: 1,
                                            maximum: EvaluationConversationConfiguration.maximumRetainedTurns
                                        )
                                    ],
                                    required: ["policy", "retainedTurnCount"]
                                )
                            ],
                            required: ["setupTurns", "historyPolicy", "retainedTurnCount"]
                        )
                    ], required: ["id", "name", "prompt", "expected"]
                ),
                minimum: 1,
                maximum: 100
            )
        ],
        required: [
            "name", "version", "instructions", "scoringMode", "repetitions", "rubricRequirements",
            "modelConfiguration", "cases"
        ]
    )

    private static let spotlightSearchSchema = object(
        properties: [
            "enabled": boolean(),
            "fileSource": object(
                properties: [
                    "enabled": boolean(),
                    "folderPath": string("Absolute local folder used by the Spotlight file source."),
                    "maximumResults": integer(
                        minimum: 1,
                        maximum: EvaluationSpotlightSearchConfiguration.maximumResultCount
                    ),
                    "fetchedAttributes": spotlightAttributeSelectionSchema
                ],
                required: ["enabled", "folderPath", "maximumResults", "fetchedAttributes"]
            ),
            "coreSpotlightSource": object(
                properties: [
                    "enabled": boolean(),
                    "maximumResults": integer(
                        minimum: 1,
                        maximum: EvaluationSpotlightSearchConfiguration.maximumResultCount
                    ),
                    "fetchedAttributes": spotlightAttributeSelectionSchema,
                    "allowMail": boolean()
                ],
                required: ["enabled", "maximumResults", "fetchedAttributes", "allowMail"]
            ),
            "guidance": object(
                properties: [
                    "mode": string(enum: EvaluationSpotlightGuidanceMode.allRawValues),
                    "focusedDomain": string(enum: EvaluationSpotlightContentDomain.allRawValues),
                    "dynamicProfile": object(
                        properties: [
                            "textMatch": string(enum: EvaluationSpotlightGuidanceOption.allRawValues),
                            "similarityMatch": string(enum: EvaluationSpotlightGuidanceOption.allRawValues),
                            "numericMatch": string(enum: EvaluationSpotlightGuidanceOption.allRawValues),
                            "dates": string(enum: EvaluationSpotlightGuidanceOption.allRawValues),
                            "people": string(enum: EvaluationSpotlightGuidanceOption.allRawValues),
                            "contentType": string(enum: EvaluationSpotlightGuidanceOption.allRawValues),
                            "attributes": spotlightAttributeSelectionSchema
                        ],
                        required: [
                            "textMatch", "similarityMatch", "numericMatch", "dates", "people",
                            "contentType", "attributes"
                        ]
                    ),
                    "outputFormat": string(enum: EvaluationSpotlightOutputFormat.allRawValues)
                ],
                required: ["mode", "focusedDomain", "dynamicProfile", "outputFormat"]
            ),
            "contactIdentity": object(
                properties: [
                    "enabled": boolean(),
                    "displayName": string(
                        maximumLength: EvaluationSpotlightSearchConfiguration.maximumIdentityValueCharacters
                    ),
                    "alternateNames": spotlightIdentityValuesSchema,
                    "emailAddresses": spotlightIdentityValuesSchema,
                    "phoneNumbers": spotlightIdentityValuesSchema
                ],
                required: [
                    "enabled", "displayName", "alternateNames", "emailAddresses", "phoneNumbers"
                ]
            ),
            "pipeline": object(
                properties: ["deduplicateItems": boolean()],
                required: ["deduplicateItems"]
            ),
            "maximumResponseSize": integer(
                minimum: EvaluationSpotlightSearchConfiguration.minimumResponseSize,
                maximum: EvaluationSpotlightSearchConfiguration.maximumAllowedResponseSize
            )
        ],
        required: [
            "enabled", "fileSource", "coreSpotlightSource", "guidance", "contactIdentity",
            "pipeline", "maximumResponseSize"
        ]
    )

    private static let spotlightAttributeSelectionSchema = object(
        properties: [
            "presets": uniqueStringArray(
                enum: EvaluationSpotlightAttributePreset.allRawValues,
                maximum: EvaluationSpotlightSearchConfiguration.maximumFetchAttributes
            ),
            "customAttributeNames": uniqueStringArray(
                maximumLength: EvaluationSpotlightSearchConfiguration.maximumAttributeNameCharacters,
                maximum: EvaluationSpotlightSearchConfiguration.maximumFetchAttributes
            )
        ],
        required: ["presets", "customAttributeNames"]
    )

    private static let spotlightIdentityValuesSchema: MCPJSONValue = .object([
        "type": .string("array"),
        "items": string(
            minimumLength: 1,
            maximumLength: EvaluationSpotlightSearchConfiguration.maximumIdentityValueCharacters
        ),
        "minItems": .integer(0),
        "maxItems": .integer(Int64(EvaluationSpotlightSearchConfiguration.maximumIdentityValuesPerKind))
    ])

    private static func schemaFieldSchema(remainingDepth: Int) -> MCPJSONValue {
        var properties: [String: MCPJSONValue] = [
            "id": uuid("Stable schema field UUID."),
            "name": string(
                "Schema field identifier.",
                maximumLength: EvaluationSchemaField.maximumNameCharacters
            ),
            "description": string(
                "Schema field description.",
                maximumLength: EvaluationSchemaField.maximumDescriptionCharacters
            ),
            "type": string(enum: EvaluationSchemaFieldType.allRawValues),
            "isOptional": boolean(),
            "enumValues": array(
                items: object(
                    properties: [
                        "id": uuid("Stable choice UUID."),
                        "value": string(maximumLength: EvaluationSchemaField.maximumEnumValueCharacters)
                    ],
                    required: ["id", "value"]
                ),
                minimum: 0,
                maximum: EvaluationSchemaField.maximumEnumValues
            ),
            "constraints": object(
                properties: [
                    "stringPattern": string(maximumLength: EvaluationSchemaField.maximumPatternCharacters),
                    "integerMinimum": integer(),
                    "integerMaximum": integer(),
                    "numberMinimum": number(),
                    "numberMaximum": number(),
                    "arrayMinimumCount": integer(
                        minimum: 0,
                        maximum: EvaluationSchemaField.maximumArrayElements
                    ),
                    "arrayMaximumCount": integer(
                        minimum: 0,
                        maximum: EvaluationSchemaField.maximumArrayElements
                    )
                ],
                required: []
            ),
            "referenceName": string(maximumLength: EvaluationSchemaField.maximumNameCharacters),
            "representNilExplicitlyInGeneratedContent": boolean(
                "For object fields, include null for missing optional properties."
            )
        ]
        properties["children"] = array(
            items: remainingDepth > 1
                ? schemaFieldSchema(remainingDepth: remainingDepth - 1)
                : .object([:]),
            minimum: 0,
            maximum: remainingDepth > 1 ? EvaluationCustomToolDefinition.maximumParameters : 0
        )
        return object(
            properties: properties,
            required: ["id", "name", "description", "type", "isOptional"]
        )
    }

    private static func object(properties: [String: MCPJSONValue], required: [String]) -> MCPJSONValue {
        .object([
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(MCPJSONValue.string)),
            "additionalProperties": .bool(false)
        ])
    }

    private static func string(
        _ description: String? = nil,
        enum values: [String]? = nil,
        minimumLength: Int? = nil,
        maximumLength: Int? = nil,
        contentEncoding: String? = nil
    ) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = ["type": .string("string")]
        if let description { schema["description"] = .string(description) }
        if let values { schema["enum"] = .array(values.map(MCPJSONValue.string)) }
        if let minimumLength { schema["minLength"] = .integer(Int64(minimumLength)) }
        if let maximumLength { schema["maxLength"] = .integer(Int64(maximumLength)) }
        if let contentEncoding { schema["contentEncoding"] = .string(contentEncoding) }
        return .object(schema)
    }

    private static func uuid(_ description: String) -> MCPJSONValue {
        .object(["type": .string("string"), "format": .string("uuid"), "description": .string(description)])
    }

    private static func boolean(_ description: String? = nil) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = ["type": .string("boolean")]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    private static func integer(
        _ description: String? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = ["type": .string("integer")]
        if let description { schema["description"] = .string(description) }
        if let minimum { schema["minimum"] = .integer(Int64(minimum)) }
        if let maximum { schema["maximum"] = .integer(Int64(maximum)) }
        return .object(schema)
    }

    private static func nullableInteger(minimum: Int, maximum: Int) -> MCPJSONValue {
        .object([
            "anyOf": .array([
                integer(minimum: minimum, maximum: maximum),
                .object(["type": .string("null")])
            ])
        ])
    }

    private static func number(minimum: Double? = nil, maximum: Double? = nil) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = ["type": .string("number")]
        if let minimum { schema["minimum"] = .number(minimum) }
        if let maximum { schema["maximum"] = .number(maximum) }
        return .object(schema)
    }

    private static func array(items: MCPJSONValue, minimum: Int, maximum: Int) -> MCPJSONValue {
        .object([
            "type": .string("array"),
            "items": items,
            "minItems": .integer(Int64(minimum)),
            "maxItems": .integer(Int64(maximum))
        ])
    }

    private static func uniqueStringArray(
        enum values: [String]? = nil,
        maximumLength: Int? = nil,
        maximum: Int
    ) -> MCPJSONValue {
        .object([
            "type": .string("array"),
            "items": string(enum: values, maximumLength: maximumLength),
            "minItems": .integer(0),
            "maxItems": .integer(Int64(maximum)),
            "uniqueItems": .bool(true)
        ])
    }
}

private extension RawRepresentable where RawValue == String, Self: CaseIterable {
    static var allRawValues: [String] { allCases.map(\Self.rawValue) }
}

private extension MCPScoringMode {
    var requiresExpected: Bool {
        self == .exactMatch || self == .containsExpected
    }
}

enum MCPToolInputError: Error {
    case unknownTool
    case invalidArguments
    case confirmationRequired
}
