import Foundation
import UniformTypeIdentifiers

@MainActor
enum MCPStoreAuthority {
    static func make(store: EvaluationStore) -> MCPAuthority {
        MCPAuthority(
            call: { call in await handle(call, store: store) },
            readResource: { request in await read(request, store: store) }
        )
    }

    private static func handle(_ call: MCPToolCall, store: EvaluationStore) async -> MCPToolPayload {
        do {
            switch call {
            case .getState:
                return try state(store)
            case .replaceSuite(let arguments):
                let before = store.suiteRevision
                let revision = try store.replaceSuite(
                    suite(from: arguments.suite, current: store.suite),
                    expectedRevision: arguments.expectedRevision,
                    confirmDeletes: arguments.confirmDeletes == true
                )
                switch store.suite.modelConfiguration.provider {
                case .privateCloudCompute:
                    await store.refreshCloudMetadata()
                case .coreAI where store.suite.modelConfiguration.coreAISettings.hasResources:
                    switch store.coreAIControlStatus {
                    case .readyToLoad, .failed:
                        Task { @MainActor [weak store] in
                            await store?.loadCoreAIModel()
                        }
                    case .unconfigured, .loading, .loaded:
                        break
                    }
                case .onDevice, .customHTTP, .coreAI:
                    break
                }
                return mutation(revision == before ? "duplicate" : "committed", ["revision": .string(revision)])
            case .uploadAttachment(let arguments):
                let result = try await store.importAttachment(
                    id: arguments.id,
                    name: arguments.name,
                    mediaType: arguments.mediaType,
                    data: arguments.dataBase64,
                    expectedRevision: arguments.expectedRevision
                )
                return mutation(result.duplicate ? "duplicate" : "committed", [
                    "attachment": attachmentMetadata(result.attachment),
                    "revision": .string(result.revision),
                    "textTruncated": .bool(result.truncated)
                ])
            case .removeAttachment(let arguments):
                let removed = try store.removeAttachment(id: arguments.id, expectedRevision: arguments.expectedRevision)
                return mutation(removed ? "committed" : "duplicate", ["attachmentID": .string(arguments.id.uuidString)])
            case .startRun(let arguments):
                let duplicate = store.runStatus(id: arguments.runID) != nil
                let operation = try store.startRun(id: arguments.runID, expectedRevision: arguments.expectedRevision)
                return mutation(duplicate ? "duplicate" : "committed", ["run": try operationJSON(operation)])
            case .getRun(let arguments):
                return try getRun(arguments, store: store)
            case .analyzeRun(let arguments):
                return try analyzeRun(arguments, store: store)
            case .listRuns(let arguments):
                return try listRuns(arguments, store: store)
            case .cancelRun(let arguments):
                let previous = store.runStatus(id: arguments.runID)
                let operation = try store.cancelRun(id: arguments.runID)
                return try cancellationPayload(previousPhase: previous?.phase, operation: operation)
            case .deleteRun(let arguments):
                let deleted = try store.deleteRunDurably(id: arguments.runID)
                return mutation(deleted ? "committed" : "duplicate", ["runID": .string(arguments.runID.uuidString)])
            }
        } catch {
            return failure(error)
        }
    }

    private static func read(_ request: MCPResourceRequest, store: EvaluationStore) async -> MCPResourcePayload {
        do {
            switch request {
            case .attachment(let id):
                let value = try store.attachmentData(id: id)
                let uri = "foundation-evals://attachments/\(id.uuidString)"
                if value.attachment.kind == .text {
                    guard let text = String(data: value.data, encoding: .utf8) else {
                        throw EvaluationStoreError.persistence("The extracted attachment text is not valid UTF-8.")
                    }
                    return .text(uri: uri, mimeType: "text/plain; charset=utf-8", text: text)
                }
                let mediaType = value.attachment.storedFilename
                    .flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension)?.preferredMIMEType }
                    ?? "application/octet-stream"
                return .blob(uri: uri, mimeType: mediaType, data: value.data)
            case .run(let id):
                let data = try store.canonicalRunData(id: id)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw EvaluationStoreError.persistence("The canonical run export is not valid UTF-8.")
                }
                return .text(
                    uri: "foundation-evals://runs/\(id.uuidString)",
                    mimeType: "application/json",
                    text: text
                )
            }
        } catch {
            return .failure(uri: resourceURI(request), code: errorCode(error), message: error.localizedDescription)
        }
    }

    private static func state(_ store: EvaluationStore) throws -> MCPToolPayload {
        let suite = store.suite
        let modelStatus = store.modelStatus(for: suite)
        let capabilities = store.selectedModelCapabilities(for: suite)
        let plannedSamples = saturatedProduct(suite.cases.count, suite.repetitions)
        let plannedSubjectRequests = saturatedProduct(
            suite.cases.reduce(0) { $0 + $1.conversation.setupTurns.count + 1 },
            suite.repetitions
        )
        let toolCallFamilies = suite.hasConfiguredTools ? 1 : 0
        let active = try store.activeRun.map { try operationJSON(store.runStatus(id: $0.id)!) } ?? .null
        return readPayload([
            "revision": .string(try store.currentSuiteRevision()),
            "suite": suiteJSON(suite),
            "attachments": .array(suite.attachments.map(attachmentMetadata)),
            "readinessBlocker": store.validationIssue(for: suite).map(MCPJSONValue.string) ?? .null,
            "model": .object([
                "available": .bool(modelStatus.isAvailable),
                "label": .string(modelStatus.label),
                "detail": .string(modelStatus.detail),
                "capabilities": .array(capabilities.evaluationNames.map(MCPJSONValue.string))
            ]),
            "workload": .object([
                "plannedSamples": .integer(Int64(plannedSamples)),
                "plannedModelRequests": .integer(Int64(
                    plannedSubjectRequests + (suite.needsModelJudge ? saturatedProduct(plannedSamples, 2) : 0)
                )),
                "plannedToolCalls": .integer(Int64(
                    saturatedProduct(
                        saturatedProduct(plannedSamples, suite.modelConfiguration.maximumToolCalls),
                        toolCallFamilies
                    )
                ))
            ]),
            "limits": .object([
                "maximumCases": .integer(Int64(EvaluationStore.maximumCases)),
                "maximumPlannedSamples": .integer(Int64(EvaluationStore.maximumPlannedSamples)),
                "maximumSetupTurnsPerCase": .integer(Int64(EvaluationConversationConfiguration.maximumSetupTurns)),
                "maximumRetainedConversationTurns": .integer(Int64(EvaluationConversationConfiguration.maximumRetainedTurns)),
                "maximumRestoredTranscriptCharacters": .integer(Int64(
                    EvaluationConversationConfiguration.maximumRestoredTranscriptCharacters
                )),
                "maximumAttachments": .integer(Int64(EvaluationStore.maximumAttachments)),
                "maximumImages": .integer(Int64(EvaluationStore.maximumImages)),
                "maximumFieldCharacters": .integer(Int64(EvaluationStore.maximumFieldCharacters)),
                "maximumCombinedSuiteCharacters": .integer(Int64(EvaluationStore.maximumCombinedSuiteCharacters)),
                "maximumRubricRequirements": .integer(4),
                "maximumRubricRequirementCharacters": .integer(Int64(EvaluationStore.maximumRubricRequirementCharacters)),
                "maximumExtractedTextCharacters": .integer(Int64(EvaluationStore.maximumExtractedTextCharacters)),
                "maximumTextOrPDFBytes": .integer(Int64(EvaluationStore.maximumTextFileBytes)),
                "maximumImageBytes": .integer(Int64(EvaluationStore.maximumImageBytes)),
                "maximumHTTPRequestBytes": .integer(16 * 1_024 * 1_024),
                "maximumCustomTools": .integer(Int64(EvaluationFeatureConfiguration.maximumTools)),
                "maximumToolParameters": .integer(Int64(EvaluationCustomToolDefinition.maximumParameters)),
                "maximumOutputFields": .integer(Int64(EvaluationFeatureConfiguration.maximumOutputFields)),
                "maximumSchemaDepth": .integer(Int64(EvaluationFeatureConfiguration.maximumSchemaDepth)),
                "maximumSchemaNodes": .integer(Int64(EvaluationFeatureConfiguration.maximumSchemaNodes)),
                "maximumSchemaArrayElements": .integer(Int64(EvaluationSchemaField.maximumArrayElements)),
                "maximumSchemaEnumValues": .integer(Int64(EvaluationSchemaField.maximumEnumValues)),
                "maximumFeatureIdentifierCharacters": .integer(Int64(EvaluationSchemaField.maximumNameCharacters)),
                "maximumToolDescriptionCharacters": .integer(Int64(
                    EvaluationCustomToolDefinition.maximumDescriptionCharacters
                )),
                "maximumSchemaFieldDescriptionCharacters": .integer(Int64(
                    EvaluationSchemaField.maximumDescriptionCharacters
                )),
                "maximumProfileNameCharacters": .integer(Int64(
                    EvaluationProfileConfiguration.maximumNameCharacters
                )),
                "maximumAfterToolInstructionsBytes": .integer(Int64(
                    EvaluationProfileConfiguration.maximumInstructionsBytes
                )),
                "maximumToolEndpointCharacters": .integer(Int64(
                    EvaluationCustomToolDefinition.maximumEndpointCharacters
                )),
                "maximumToolOutputBytes": .integer(Int64(EvaluationCustomToolDefinition.maximumOutputBytes)),
                "maximumCustomToolOutputTokens": .integer(Int64(EvaluationCustomTool.maximumOutputTokens)),
                "maximumCustomToolArgumentTokens": .integer(Int64(EvaluationCustomTool.maximumArgumentTokens)),
                "maximumToolArgumentsBytes": .integer(Int64(EvaluationCustomToolDefinition.maximumArgumentBytes))
            ]),
            "activeRun": active
        ])
    }

    private static func getRun(_ arguments: MCPGetRunArguments, store: EvaluationStore) throws -> MCPToolPayload {
        guard let operation = store.runStatus(id: arguments.runID) else {
            throw EvaluationStoreError.resourceNotFound("Run")
        }
        if let run = store.run(with: arguments.runID) {
            let page = try resultPage(run.results, arguments: arguments)
            var object = try json(run).objectValue!
            object["phase"] = .string(phaseName(operation.phase))
            object["results"] = page.results
            object["skipped"] = try json(skippedSamples(in: run))
            object["nextCursor"] = page.nextCursor
            return readPayload(["run": .object(object)])
        }

        let active = store.activeRun!
        let page = try resultPage(store.partialResults(runID: active.id), arguments: arguments)
        return readPayload(["run": .object([
            "id": .string(active.id.uuidString),
            "suiteRevision": .string(active.suiteRevision),
            "phase": .string(phaseName(operation.phase)),
            "startedAt": .string(active.startedAt.ISO8601Format()),
            "completedAt": .null,
            "completedSamples": .integer(Int64(active.completedSamples)),
            "plannedSampleCount": .integer(Int64(active.totalSamples)),
            "plannedCases": try json(store.suite.cases),
            "results": page.results,
            "skipped": .array([]),
            "nextCursor": page.nextCursor
        ])])
    }

    private static func analyzeRun(_ arguments: MCPAnalyzeRunArguments, store: EvaluationStore) throws -> MCPToolPayload {
        guard let run = store.run(with: arguments.runID) else {
            if store.activeRun?.id == arguments.runID {
                return .failure(code: "run_not_finished", message: "Poll eval_get_run until the run finishes before analyzing it.")
            }
            throw EvaluationStoreError.resourceNotFound("Run")
        }
        var output: [String: MCPJSONValue] = ["analysis": try json(EvaluationRunAnalysis(run: run))]
        if let baselineID = arguments.baselineRunID {
            guard let baseline = store.run(with: baselineID) else {
                throw EvaluationStoreError.resourceNotFound("Saved baseline run")
            }
            output["comparison"] = try json(EvaluationRunComparison(current: run, baseline: baseline))
        }
        return readPayload(output)
    }

    private static func listRuns(_ arguments: MCPListRunsArguments, store: EvaluationStore) throws -> MCPToolPayload {
        var summaries: [MCPJSONValue] = []
        if let active = store.activeRun, let operation = store.runStatus(id: active.id) {
            summaries.append(.object([
                "id": .string(active.id.uuidString),
                "suiteName": .string(store.suite.name),
                "suiteVersion": .string(store.suite.version),
                "phase": .string(phaseName(operation.phase)),
                "startedAt": .string(active.startedAt.ISO8601Format()),
                "completedAt": .null,
                "completedSamples": .integer(Int64(active.completedSamples)),
                "plannedSamples": .integer(Int64(active.totalSamples))
            ]))
        }
        summaries.append(contentsOf: store.runs.map { run in
            let phase = store.runStatus(id: run.id)!.phase
            return .object([
                "id": .string(run.id.uuidString),
                "suiteName": .string(run.suiteName),
                "suiteVersion": .string(run.suiteVersion),
                "phase": .string(phaseName(phase)),
                "startedAt": .string(run.startedAt.ISO8601Format()),
                "completedAt": .string(run.completedAt.ISO8601Format()),
                "completedSamples": .integer(Int64(run.results.count)),
                "plannedSamples": .integer(Int64(run.plannedResultCount)),
                "passed": .integer(Int64(run.passedCount)),
                "failed": .integer(Int64(run.failedCount)),
                "errors": .integer(Int64(run.errorCount))
            ])
        })

        if let query = arguments.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            summaries = summaries.filter { summary in
                let object = summary.objectValue!
                return object["suiteName"]!.stringValue!.localizedCaseInsensitiveContains(query)
                    || object["suiteVersion"]!.stringValue!.localizedCaseInsensitiveContains(query)
            }
        }
        if let status = arguments.status, !status.isEmpty {
            guard status == "cancellation_requested" || EvaluationRunPhase(rawValue: status) != nil else {
                return .failure(code: "invalid_status", message: "Status must be a run phase returned by this tool.")
            }
            summaries = summaries.filter { $0.objectValue?["phase"]?.stringValue == status }
        }

        let limit = arguments.limit ?? 50
        let offset = try pageOffset(arguments.cursor, count: summaries.count)
        let end = min(offset + limit, summaries.count)
        return readPayload([
            "runs": .array(Array(summaries[offset..<end])),
            "nextCursor": end < summaries.count ? .string(cursor(end)) : .null
        ])
    }

    private static func suite(
        from declaration: MCPSuiteDeclaration,
        current: EvaluationSuite
    ) -> EvaluationSuite {
        var suite = EvaluationSuite()
        suite.name = declaration.name
        suite.version = declaration.version
        suite.instructions = declaration.instructions
        suite.criteria = declaration.rubricRequirements.joined(separator: "\n")
        suite.scoringMode = ScoringMode(rawValue: declaration.scoringMode.rawValue)!
        suite.repetitions = declaration.repetitions
        suite.cases = declaration.cases.map { declaredCase in
            let currentCase = current.cases.first { $0.id == declaredCase.id }
            return EvaluationCase(
                id: declaredCase.id,
                name: declaredCase.name,
                prompt: declaredCase.prompt,
                expected: declaredCase.expected,
                conversation: declaredCase.conversation ?? EvaluationConversationConfiguration(),
                fieldAssertions: declaredCase.fieldAssertions ?? currentCase?.fieldAssertions
            )
        }
        var configuration = EvaluationModelConfiguration()
        configuration.customization = declaration.modelConfiguration.customization ?? current.modelConfiguration.customization
        configuration.provider = declaration.modelConfiguration.provider ?? current.modelConfiguration.provider
        configuration.customProvider = declaration.modelConfiguration.customProvider?.evaluationConfiguration
            ?? current.modelConfiguration.customProvider
        configuration.coreAI = declaration.modelConfiguration.coreAI?.evaluationConfiguration
            ?? current.modelConfiguration.coreAI
        configuration.reasoningLevel = declaration.modelConfiguration.reasoningLevel ?? current.modelConfiguration.reasoningLevel
        configuration.samplingMode = EvaluationSamplingMode(rawValue: declaration.modelConfiguration.samplingMode.rawValue)!
        configuration.temperatureEnabled = declaration.modelConfiguration.temperatureEnabled
        configuration.temperature = declaration.modelConfiguration.temperature
        configuration.seedEnabled = declaration.modelConfiguration.seedEnabled
        configuration.seed = declaration.modelConfiguration.seed
        configuration.topK = declaration.modelConfiguration.topK
        configuration.probabilityThreshold = declaration.modelConfiguration.probabilityThreshold
        configuration.maximumResponseTokens = declaration.modelConfiguration.maximumResponseTokens
        configuration.maximumInputTokens = declaration.modelConfiguration.maximumInputTokens
        configuration.referenceMode = EvaluationReferenceMode(rawValue: declaration.modelConfiguration.referenceMode.rawValue)!
        configuration.contextPolicy = EvaluationContextPolicy(rawValue: declaration.modelConfiguration.contextPolicy.rawValue)!
        configuration.maximumToolCalls = declaration.modelConfiguration.maximumToolCalls
        suite.modelConfiguration = configuration
        suite.features = declaration.features ?? current.features
        return suite
    }

    private static func suiteJSON(_ suite: EvaluationSuite) -> MCPJSONValue {
        let configuration = suite.modelConfiguration
        return .object([
            "name": .string(suite.name),
            "version": .string(suite.version),
            "instructions": .string(suite.instructions),
            "scoringMode": .string(suite.scoringMode.rawValue),
            "repetitions": .integer(Int64(suite.repetitions)),
            "rubricRequirements": .array(suite.rubricCriteria.map(MCPJSONValue.string)),
            "modelConfiguration": modelConfigurationJSON(configuration),
            "features": featureJSON(suite.features),
            "cases": .array(suite.cases.map { item in
                var conversation: [String: MCPJSONValue] = [
                    "setupTurns": .array(item.conversation.setupTurns.map { turn in
                        .object([
                            "id": .string(turn.id.uuidString),
                            "prompt": .string(turn.prompt)
                        ])
                    }),
                    "historyPolicy": .string(item.conversation.historyPolicy.rawValue),
                    "retainedTurnCount": .integer(Int64(item.conversation.retainedTurnCount))
                ]
                if let restoredTranscriptJSON = item.conversation.restoredTranscriptJSON {
                    conversation["restoredTranscriptJSON"] = .string(restoredTranscriptJSON)
                }
                if let projection = item.conversation.modelHistoryProjection {
                    conversation["modelHistoryProjection"] = .object([
                        "policy": .string(projection.policy.rawValue),
                        "retainedTurnCount": .integer(Int64(projection.retainedTurnCount))
                    ])
                }
                var value: [String: MCPJSONValue] = [
                    "id": .string(item.id.uuidString),
                    "name": .string(item.name),
                    "prompt": .string(item.prompt),
                    "expected": .string(item.expected),
                    "conversation": .object(conversation)
                ]
                if let fieldAssertions = item.fieldAssertions {
                    value["fieldAssertions"] = .array(fieldAssertions.map { assertion in
                        .object([
                            "id": .string(assertion.id.uuidString),
                            "pointer": .string(assertion.pointer),
                            "operation": .string(assertion.operation.rawValue),
                            "expectedValue": .string(assertion.expectedValue)
                        ])
                    })
                }
                return .object(value)
            })
        ])
    }

    private static func modelConfigurationJSON(
        _ configuration: EvaluationModelConfiguration
    ) -> MCPJSONValue {
        var value: [String: MCPJSONValue] = [
            "provider": .string(configuration.provider.rawValue),
            "reasoningLevel": .string(configuration.reasoningLevel.rawValue),
            "samplingMode": .string(configuration.samplingMode.rawValue),
            "temperatureEnabled": .bool(configuration.temperatureEnabled),
            "temperature": .number(configuration.temperature),
            "seedEnabled": .bool(configuration.seedEnabled),
            "seed": .unsigned(configuration.seed),
            "topK": .integer(Int64(configuration.topK)),
            "probabilityThreshold": .number(configuration.probabilityThreshold),
            "maximumResponseTokens": .integer(Int64(configuration.maximumResponseTokens)),
            "maximumInputTokens": configuration.maximumInputTokens.map { .integer(Int64($0)) } ?? .null,
            "referenceMode": .string(configuration.referenceMode.rawValue),
            "contextPolicy": .string(configuration.contextPolicy.rawValue),
            "maximumToolCalls": .integer(Int64(configuration.maximumToolCalls))
        ]
        if let customization = configuration.customization {
            var customizationJSON: [String: MCPJSONValue] = [
                "useCase": .string(customization.useCase.rawValue),
                "guardrails": .string(customization.guardrails.rawValue),
                "schemaPrompt": .string(customization.schemaPrompt.rawValue),
                "toolCalling": .string(customization.toolCalling.rawValue)
            ]
            if let customReasoning = customization.customReasoning {
                customizationJSON["customReasoning"] = .string(customReasoning)
            }
            if let transcriptErrorPolicy = customization.transcriptErrorPolicy {
                customizationJSON["transcriptErrorPolicy"] = .string(transcriptErrorPolicy.rawValue)
            }
            if let saveFullTranscript = customization.saveFullTranscript {
                customizationJSON["saveFullTranscript"] = .bool(saveFullTranscript)
            }
            if let prewarmPrefix = customization.prewarmPrefix {
                customizationJSON["prewarmPrefix"] = .string(prewarmPrefix)
            }
            if let prewarmLeadSeconds = customization.prewarmLeadSeconds {
                customizationJSON["prewarmLeadSeconds"] = .number(prewarmLeadSeconds)
            }
            if let visionTools = customization.visionTools {
                customizationJSON["visionTools"] = .object([
                    "ocrEnabled": .bool(visionTools.ocrEnabled),
                    "barcodeEnabled": .bool(visionTools.barcodeEnabled)
                ])
            }
            value["customization"] = .object(customizationJSON)
        }
        if let customProvider = configuration.customProvider {
            let provider = MCPCustomProviderConfiguration(customProvider)
            value["customProvider"] = .object([
                "endpoint": .string(provider.endpoint),
                "contextSize": .integer(Int64(provider.contextSize)),
                "capabilities": .array(provider.capabilities.map { .string($0.rawValue) }),
                "requestTimeoutSeconds": .number(provider.requestTimeoutSeconds)
            ])
        }
        if let coreAI = configuration.coreAI {
            var coreAIJSON: [String: MCPJSONValue] = [
                "resourcesPath": .string(coreAI.resourcesPath)
            ]
            if let bookmark = coreAI.resourcesBookmark {
                coreAIJSON["resourcesBookmark"] = .string(bookmark.base64EncodedString())
            }
            value["coreAI"] = .object(coreAIJSON)
        }
        return .object(value)
    }

    private static func featureJSON(_ features: EvaluationFeatureConfiguration) -> MCPJSONValue {
        .object([
            "tools": .array(features.tools.map { tool in
                .object([
                    "id": .string(tool.id.uuidString),
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": .array(tool.parameters.map(schemaFieldJSON)),
                    "schemaDefinitions": .array(tool.schemaDefinitions.map(schemaFieldJSON)),
                    "representNilExplicitlyInGeneratedContent": .bool(
                        tool.representNilExplicitlyInGeneratedContent
                    ),
                    "mode": .string(tool.mode.rawValue),
                    "fixtureResponse": .string(tool.fixtureResponse),
                    "endpoint": .string(tool.endpoint)
                ])
            }),
            "profile": .object([
                "enabled": .bool(features.profile.enabled),
                "name": .string(features.profile.name),
                "afterToolInstructions": .string(features.profile.afterToolInstructions),
                "requireToolFirst": .bool(features.profile.requireToolFirst),
                "afterToolSamplingMode": .string(features.profile.afterToolSamplingMode.rawValue),
                "afterToolTemperatureEnabled": .bool(features.profile.afterToolTemperatureEnabled),
                "afterToolTemperature": .number(features.profile.afterToolTemperature),
                "afterToolSeedEnabled": .bool(features.profile.afterToolSeedEnabled),
                "afterToolSeed": .unsigned(features.profile.afterToolSeed),
                "afterToolTopK": .integer(Int64(features.profile.afterToolTopK)),
                "afterToolProbabilityThreshold": .number(features.profile.afterToolProbabilityThreshold),
                "afterToolMaximumResponseTokens": features.profile.afterToolMaximumResponseTokens.map {
                    .integer(Int64($0))
                } ?? .null,
                "afterToolReasoningLevel": .string(features.profile.afterToolReasoningLevel.rawValue),
                "afterToolCustomReasoning": .string(features.profile.afterToolCustomReasoning),
                "afterToolTranscriptErrorPolicy": .string(features.profile.afterToolTranscriptErrorPolicy.rawValue)
            ]),
            "spotlightSearch": spotlightSearchJSON(features.spotlightSearch),
            "outputFields": .array(features.outputFields.map(schemaFieldJSON)),
            "outputSchemaDefinitions": .array(features.outputSchemaDefinitions.map(schemaFieldJSON)),
            "outputRepresentNilExplicitlyInGeneratedContent": .bool(
                features.outputRepresentNilExplicitlyInGeneratedContent
            ),
            "prewarm": .bool(features.prewarm),
            "streamResponse": .bool(features.streamResponse)
        ])
    }

    private static func spotlightSearchJSON(
        _ configuration: EvaluationSpotlightSearchConfiguration
    ) -> MCPJSONValue {
        .object([
            "enabled": .bool(configuration.enabled),
            "fileSource": .object([
                "enabled": .bool(configuration.fileSource.enabled),
                "folderPath": .string(configuration.fileSource.folderPath),
                "maximumResults": .integer(Int64(configuration.fileSource.maximumResults)),
                "fetchedAttributes": spotlightAttributeSelectionJSON(
                    configuration.fileSource.fetchedAttributes
                )
            ]),
            "coreSpotlightSource": .object([
                "enabled": .bool(configuration.coreSpotlightSource.enabled),
                "maximumResults": .integer(Int64(configuration.coreSpotlightSource.maximumResults)),
                "fetchedAttributes": spotlightAttributeSelectionJSON(
                    configuration.coreSpotlightSource.fetchedAttributes
                ),
                "allowMail": .bool(configuration.coreSpotlightSource.allowMail)
            ]),
            "guidance": .object([
                "mode": .string(configuration.guidance.mode.rawValue),
                "focusedDomain": .string(configuration.guidance.focusedDomain.rawValue),
                "dynamicProfile": .object([
                    "textMatch": .string(configuration.guidance.dynamicProfile.textMatch.rawValue),
                    "similarityMatch": .string(configuration.guidance.dynamicProfile.similarityMatch.rawValue),
                    "numericMatch": .string(configuration.guidance.dynamicProfile.numericMatch.rawValue),
                    "dates": .string(configuration.guidance.dynamicProfile.dates.rawValue),
                    "people": .string(configuration.guidance.dynamicProfile.people.rawValue),
                    "contentType": .string(configuration.guidance.dynamicProfile.contentType.rawValue),
                    "attributes": spotlightAttributeSelectionJSON(
                        configuration.guidance.dynamicProfile.attributes
                    )
                ]),
                "outputFormat": .string(configuration.guidance.outputFormat.rawValue)
            ]),
            "contactIdentity": .object([
                "enabled": .bool(configuration.contactIdentity.enabled),
                "displayName": .string(configuration.contactIdentity.displayName),
                "alternateNames": .array(
                    configuration.contactIdentity.alternateNames.map(MCPJSONValue.string)
                ),
                "emailAddresses": .array(
                    configuration.contactIdentity.emailAddresses.map(MCPJSONValue.string)
                ),
                "phoneNumbers": .array(
                    configuration.contactIdentity.phoneNumbers.map(MCPJSONValue.string)
                )
            ]),
            "pipeline": .object([
                "deduplicateItems": .bool(configuration.pipeline.deduplicateItems)
            ]),
            "maximumResponseSize": .integer(Int64(configuration.maximumResponseSize))
        ])
    }

    private static func spotlightAttributeSelectionJSON(
        _ selection: EvaluationSpotlightAttributeSelection
    ) -> MCPJSONValue {
        .object([
            "presets": .array(selection.presets.map { .string($0.rawValue) }),
            "customAttributeNames": .array(selection.customAttributeNames.map(MCPJSONValue.string))
        ])
    }

    private static func schemaFieldJSON(_ field: EvaluationSchemaField) -> MCPJSONValue {
        var constraints: [String: MCPJSONValue] = [
            "stringPattern": .string(field.constraints.stringPattern)
        ]
        if let value = field.constraints.integerMinimum {
            constraints["integerMinimum"] = .integer(Int64(value))
        }
        if let value = field.constraints.integerMaximum {
            constraints["integerMaximum"] = .integer(Int64(value))
        }
        if let value = field.constraints.numberMinimum {
            constraints["numberMinimum"] = .number(value)
        }
        if let value = field.constraints.numberMaximum {
            constraints["numberMaximum"] = .number(value)
        }
        if let value = field.constraints.arrayMinimumCount {
            constraints["arrayMinimumCount"] = .integer(Int64(value))
        }
        if let value = field.constraints.arrayMaximumCount {
            constraints["arrayMaximumCount"] = .integer(Int64(value))
        }
        return .object([
            "id": .string(field.id.uuidString),
            "name": .string(field.name),
            "description": .string(field.description),
            "type": .string(field.type.rawValue),
            "isOptional": .bool(field.isOptional),
            "children": .array(field.children.map(schemaFieldJSON)),
            "enumValues": .array(field.enumValues.map { value in
                .object([
                    "id": .string(value.id.uuidString),
                    "value": .string(value.value)
                ])
            }),
            "constraints": .object(constraints),
            "referenceName": .string(field.referenceName),
            "representNilExplicitlyInGeneratedContent": .bool(
                field.representNilExplicitlyInGeneratedContent
            )
        ])
    }

    private static func attachmentMetadata(_ attachment: EvaluationAttachment) -> MCPJSONValue {
        .object([
            "id": .string(attachment.id.uuidString),
            "name": .string(attachment.name),
            "kind": .string(attachment.kind.rawValue),
            "byteCount": .integer(Int64(attachment.byteCount)),
            "sha256": .string(attachment.sha256),
            "textTruncated": .bool(attachment.text?.hasSuffix("\n[File truncated during import.]") == true)
        ])
    }

    private struct SkippedSample: Encodable {
        var caseID: UUID
        var caseName: String
        var repetition: Int
    }

    private static func skippedSamples(in run: EvaluationRun) -> [SkippedSample] {
        guard let cases = run.plannedCases else { return [] }
        let completed = Set(run.results.map { "\($0.caseID.uuidString):\($0.repetition)" })
        return (1...run.repetitions).flatMap { repetition in
            cases.compactMap { item in
                completed.contains("\(item.id.uuidString):\(repetition)")
                    ? nil
                    : SkippedSample(caseID: item.id, caseName: item.name, repetition: repetition)
            }
        }
    }

    private static func mutation(_ outcome: String, _ fields: [String: MCPJSONValue]) -> MCPToolPayload {
        MCPToolPayload(structuredContent: .object(fields.merging(["outcome": .string(outcome)]) { current, _ in current }))
    }

    private static func readPayload(_ fields: [String: MCPJSONValue]) -> MCPToolPayload {
        MCPToolPayload(structuredContent: .object(fields.merging(["outcome": .string("read")]) { current, _ in current }))
    }

    private static func failure(_ error: Error) -> MCPToolPayload {
        let outcome: String
        var fields: [String: MCPJSONValue] = [
            "error": .object(["code": .string(errorCode(error)), "message": .string(error.localizedDescription)])
        ]
        switch error {
        case EvaluationStoreError.staleRevision(let current):
            outcome = "conflicted"
            fields["currentRevision"] = .string(current)
        case EvaluationStoreError.resourceConflict:
            outcome = "conflicted"
        default:
            outcome = "failed"
        }
        fields["outcome"] = .string(outcome)
        return MCPToolPayload(structuredContent: .object(fields), isError: true)
    }

    private static func errorCode(_ error: Error) -> String {
        switch error {
        case EvaluationStoreError.staleRevision: "stale_revision"
        case EvaluationStoreError.runBusy: "run_busy"
        case EvaluationStoreError.fileOperationBusy: "file_operation_busy"
        case EvaluationStoreError.invalidSuite: "invalid_suite"
        case EvaluationStoreError.deletionConfirmationRequired: "confirmation_required"
        case EvaluationStoreError.resourceConflict: "resource_conflict"
        case EvaluationStoreError.resourceNotFound: "not_found"
        case EvaluationStoreError.persistence: "persistence_failed"
        case MCPStoreAuthorityError.invalidCursor: "invalid_cursor"
        default: "invalid_request"
        }
    }

    private static func resourceURI(_ request: MCPResourceRequest) -> String {
        switch request {
        case .attachment(let id): "foundation-evals://attachments/\(id.uuidString)"
        case .run(let id): "foundation-evals://runs/\(id.uuidString)"
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> MCPJSONValue {
        try JSONDecoder().decode(MCPJSONValue.self, from: CanonicalJSON.data(for: value, prettyPrinted: false))
    }

    static func operationJSON(_ operation: EvaluationRunOperation) throws -> MCPJSONValue {
        var object = try json(operation).objectValue!
        object["phase"] = .string(phaseName(operation.phase))
        return .object(object)
    }

    static func cancellationPayload(
        previousPhase: EvaluationRunPhase?,
        operation: EvaluationRunOperation
    ) throws -> MCPToolPayload {
        mutation(previousPhase == .running ? "committed" : "duplicate", [
            "status": .string(phaseName(operation.phase)),
            "run": try operationJSON(operation)
        ])
    }

    private static func phaseName(_ phase: EvaluationRunPhase) -> String {
        phase == .cancellationRequested ? "cancellation_requested" : phase.rawValue
    }

    private static func resultPage(
        _ results: [EvaluationSampleResult],
        arguments: MCPGetRunArguments
    ) throws -> (results: MCPJSONValue, nextCursor: MCPJSONValue) {
        let offset = try pageOffset(arguments.cursor, count: results.count)
        let end = min(offset + (arguments.limit ?? 50), results.count)
        return (
            try json(Array(results[offset..<end])),
            end < results.count ? .string(cursor(end)) : .null
        )
    }

    private static func saturatedProduct(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs >= 0, rhs >= 0 else { return 0 }
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : value
    }

    private static func cursor(_ offset: Int) -> String {
        Data("offset:\(offset)".utf8).base64EncodedString()
    }

    private static func pageOffset(_ cursor: String?, count: Int) throws -> Int {
        guard let cursor else { return 0 }
        guard let data = Data(base64Encoded: cursor),
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("offset:"),
              let offset = Int(text.dropFirst("offset:".count)),
              (0...count).contains(offset)
        else { throw MCPStoreAuthorityError.invalidCursor }
        return offset
    }
}

private enum MCPStoreAuthorityError: LocalizedError {
    case invalidCursor

    var errorDescription: String? { "The pagination cursor is invalid or stale." }
}
