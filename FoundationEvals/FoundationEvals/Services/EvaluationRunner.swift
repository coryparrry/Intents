import Foundation
import FoundationModels
import OSLog

struct ImageEvaluationInput: Sendable {
    var label: String
    var url: URL
}

actor EvaluationRunner {
    let signposter = OSSignposter(
        subsystem: "com.coryparry.FoundationEvals",
        category: "Evaluation"
    )

    func run(
        id: UUID,
        suiteRevision: String,
        startedAt: Date,
        suite: EvaluationSuite,
        images: [ImageEvaluationInput],
        liveResponse: @escaping @Sendable (EvaluationLiveResponse) async -> Void = { _ in },
        progress: @Sendable (EvaluationSampleResult, Int, Int) async -> Void
    ) async -> EvaluationRun {
        switch suite.modelConfiguration.provider {
        case .onDevice:
            let model = suite.modelConfiguration.systemModel
            return await run(
                id: id,
                suiteRevision: suiteRevision,
                startedAt: startedAt,
                suite: suite,
                images: images,
                model: model,
                contextSize: model.contextSize,
                modelName: "On-device · \(model.variant.displayName)",
                admissionError: Self.unavailableMessage(for: model.availability).map {
                    (category: "modelUnavailable", message: $0)
                },
                liveResponse: liveResponse,
                progress: progress
            )
        case .privateCloudCompute:
            let model = PrivateCloudComputeLanguageModel()
            let availabilityMessage = Self.unavailableMessage(for: model.availability)
            do {
                let contextSize = try await model.contextSize
                return await run(
                    id: id,
                    suiteRevision: suiteRevision,
                    startedAt: startedAt,
                    suite: suite,
                    images: images,
                    model: model,
                    contextSize: contextSize,
                    modelName: "Private Cloud Compute",
                    admissionError: availabilityMessage.map {
                        (category: "modelUnavailable", message: $0)
                    },
                    liveResponse: liveResponse,
                    progress: progress
                )
            } catch {
                let traceError = Self.traceError(error)
                return await run(
                    id: id,
                    suiteRevision: suiteRevision,
                    startedAt: startedAt,
                    suite: suite,
                    images: images,
                    model: model,
                    contextSize: 0,
                    modelName: "Private Cloud Compute",
                    admissionError: availabilityMessage.map {
                        (category: "modelUnavailable", message: $0)
                    } ?? traceError,
                    liveResponse: liveResponse,
                    progress: progress
                )
            }
        case .customHTTP:
            let configuration = suite.modelConfiguration.customProviderSettings
            var caseNames: [UUID: String] = [:]
            for evaluationCase in suite.cases {
                caseNames[evaluationCase.id] = evaluationCase.name
            }
            let liveResponseObserver: EvaluationHTTPLiveResponseObserver?
            if suite.features.streamResponse {
                liveResponseObserver = EvaluationHTTPLiveResponseObserver { [caseNames] update in
                    guard let caseName = caseNames[update.caseID] else { return }
                    let turnName = update.role == "setup"
                        ? update.setupTurn.map { "Setup turn \($0)" } ?? "Setup turn"
                        : "Scored prompt"
                    await liveResponse(EvaluationLiveResponse(
                        caseID: update.caseID,
                        caseName: caseName,
                        repetition: update.repetition,
                        turnName: turnName,
                        content: update.content
                    ))
                }
            } else {
                liveResponseObserver = nil
            }
            let model = EvaluationHTTPLanguageModel(
                configuration: configuration,
                liveResponseObserver: liveResponseObserver
            )
            return await run(
                id: id, suiteRevision: suiteRevision, startedAt: startedAt, suite: suite,
                images: images, model: model, contextSize: model.contextSize,
                modelName: "Custom local HTTP model",
                admissionError: configuration.validationIssue.map { (category: "invalidConfiguration", message: $0) },
                liveResponse: liveResponse, progress: progress
            )
        case .coreAI:
            do {
                let loaded = try await CoreAIModelLoader.shared.load(configuration: suite.modelConfiguration.coreAISettings)
                try Task.checkCancellation()
                return await run(
                    id: id, suiteRevision: suiteRevision, startedAt: startedAt, suite: suite,
                    images: images, model: loaded.model, contextSize: loaded.contextSize,
                    modelName: "Core AI · \(loaded.modelName)", admissionError: nil,
                    liveResponse: liveResponse, progress: progress
                )
            } catch {
                let admissionError: (category: String, message: String)
                if error is CancellationError || Task.isCancelled {
                    admissionError = (category: "cancelled", message: "The evaluation was cancelled.")
                } else {
                    admissionError = (category: "modelAssetsUnavailable", message: error.localizedDescription)
                }
                // Admission failure produces an error sample without invoking this placeholder model.
                return await run(
                    id: id, suiteRevision: suiteRevision, startedAt: startedAt, suite: suite,
                    images: images, model: SystemLanguageModel.default, contextSize: 0,
                    modelName: "Core AI · resources unavailable",
                    admissionError: admissionError,
                    liveResponse: liveResponse, progress: progress
                )
            }
        }
    }

    private func run<Model: LanguageModel>(
        id runID: UUID,
        suiteRevision: String,
        startedAt: Date,
        suite: EvaluationSuite,
        images: [ImageEvaluationInput],
        model: Model,
        contextSize: Int,
        modelName: String,
        admissionError: (category: String, message: String)?,
        liveResponse: @Sendable (EvaluationLiveResponse) async -> Void,
        progress: @Sendable (EvaluationSampleResult, Int, Int) async -> Void
    ) async -> EvaluationRun {
        let total = suite.cases.count * suite.repetitions
        var completed = 0
        var results: [EvaluationSampleResult] = []
        var cancelled = false
        var terminationReason: String?

        let environment = EvaluationEnvironment(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            locale: Locale.current.identifier,
            model: modelName,
            modelContextSize: contextSize
        )

        outer: for repetition in 1...suite.repetitions {
            for evaluationCase in suite.cases {
                if Task.isCancelled {
                    cancelled = true
                    terminationReason = "cancelled"
                    break outer
                }

                let result: EvaluationSampleResult
                if let admissionError {
                    result = Self.errorResult(
                        evaluationCase: evaluationCase,
                        repetition: repetition,
                        category: admissionError.category,
                        message: admissionError.message
                    )
                } else {
                    result = await evaluate(
                        evaluationCase,
                        repetition: repetition,
                        suite: suite,
                        runID: runID,
                        images: images,
                        model: model,
                        contextSize: contextSize,
                        liveResponse: liveResponse
                    )
                }

                results.append(result)
                completed += 1
                await progress(result, completed, total)

                if result.errorCategory == "cancelled" || result.judgeErrorCategory == "cancelled" {
                    cancelled = true
                    terminationReason = "cancelled"
                    break outer
                }

                if admissionError != nil {
                    terminationReason = result.errorCategory
                    break outer
                }
                if Self.stopsBatch(for: result.errorCategory)
                    || Self.stopsBatch(for: result.judgeErrorCategory) {
                    terminationReason = result.errorCategory ?? result.judgeErrorCategory
                    break outer
                }
            }
        }

        let allocation = suite.modelConfiguration.contextAllocation(
            contextSize: contextSize,
            includesModelJudge: suite.needsModelJudge,
            sharedToolOutputReserve: suite.sharedToolOutputReserve
        )
        return EvaluationRun(
            id: runID,
            suiteID: suite.id,
            suiteName: suite.name,
            suiteVersion: suite.version,
            instructions: suite.instructions,
            criteria: suite.criteria,
            scoringMode: suite.scoringMode,
            repetitions: suite.repetitions,
            judgePromptVersion: suite.scoringMode == .modelJudge ? Self.judgePromptVersion : nil,
            judgePassingScore: suite.scoringMode == .modelJudge ? EvaluationSuite.judgePassingScore : nil,
            plannedSampleCount: total,
            suiteRevision: suiteRevision,
            plannedCases: suite.cases,
            startedAt: startedAt,
            completedAt: Date(),
            cancelled: cancelled,
            terminationReason: terminationReason,
            environment: environment,
            attachments: suite.attachments.map {
                EvaluationAttachmentTrace(name: $0.name, kind: $0.kind, byteCount: $0.byteCount, sha256: $0.sha256)
            },
            results: results,
            execution: EvaluationExecutionTrace(
                behaviorVersion: EvaluationModelConfiguration.currentBehaviorVersion,
                configuration: suite.modelConfiguration,
                modelDisplayName: modelName,
                capabilities: model.capabilities.evaluationNames,
                toolNames: (suite.modelConfiguration.referenceMode == .lookupTool
                    ? [ReferenceLookupTool.toolName] : [])
                    + suite.features.tools.map(\.name)
                    + suite.modelConfiguration.customizationSettings.visionSettings.enabledToolNames
                    + suite.features.spotlightSearch.enabledToolNames,
                effectiveInputTokenLimit: allocation.effectiveInputLimit,
                reservedToolOutputTokens: allocation.toolOutputReserve,
                reservedJudgeOverheadTokens: allocation.judgeOverheadReserve,
                inputTokenCountingMethod: suite.modelConfiguration.provider == .onDevice
                    ? "System model tokenizer"
                    : "System model tokenizer estimate",
                imageInputTokenCountAvailable: images.isEmpty && results.allSatisfy {
                    $0.imageInputTokenCountAvailable != false
                },
                features: suite.features
            )
        )
    }

    private func evaluate<Model: LanguageModel>(
        _ evaluationCase: EvaluationCase,
        repetition: Int,
        suite: EvaluationSuite,
        runID: UUID,
        images: [ImageEvaluationInput],
        model: Model,
        contextSize: Int,
        liveResponse: @Sendable (EvaluationLiveResponse) async -> Void
    ) async -> EvaluationSampleResult {
        let started = ContinuousClock.now
        let workflow = EvaluationWorkflowRecorder(origin: started)
        let rootSpanID = workflow.begin(kind: .sample, title: evaluationCase.name, metadata: [
            "caseID": evaluationCase.id.uuidString, "repetition": String(repetition),
            "provider": suite.modelConfiguration.provider.rawValue,
            "scoringMode": suite.scoringMode.rawValue
        ], at: started)
        let preparationSpanID = workflow.begin(kind: .preparation, title: "Prepare input", parentID: rootSpanID)
        var generationSpanID: UUID?
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("Model request", id: signpostID)
        let toolCallLimiter = EvaluationToolCallLimiter(
            maximumCalls: suite.modelConfiguration.maximumToolCalls
        )
        let recorder = ReferenceToolRecorder(
            maximumCalls: suite.modelConfiguration.maximumToolCalls,
            callLimiter: toolCallLimiter,
            workflowRecorder: workflow
        )
        let customRecorder = EvaluationCustomToolRecorder(
            maximumCalls: suite.modelConfiguration.maximumToolCalls,
            callLimiter: toolCallLimiter,
            workflowRecorder: workflow
        )
        let profileRecorder = EvaluationProfileRecorder()
        let builtinToolNames = Set(
            suite.modelConfiguration.customizationSettings.visionSettings.enabledToolNames
                + suite.features.spotlightSearch.enabledToolNames
        )
        var session: LanguageModelSession?
        var featureTrace = EvaluationFeatureTrace()
        var builtinToolCalls: [EvaluationBuiltinToolTrace] = []
        var restoredBuiltinToolCallIDs = Set<String>()
        var refusalTrace: EvaluationRefusalTrace?
        var spotlightRuntime: EvaluationSpotlightSearchRuntime?
        var spotlightRecording: Task<Void, Never>?
        var conversationTrace = EvaluationConversationTrace(
            historyPolicy: evaluationCase.conversation.historyPolicy,
            retainedTurnCount: evaluationCase.conversation.historyPolicy == .retainRecentCompleteTurns
                ? evaluationCase.conversation.retainedTurnCount : nil,
            modelHistoryProjection: evaluationCase.conversation.modelHistoryProjection
        )
        var effectivePrompt: String?
        var generationStarted: ContinuousClock.Instant?
        var finalTurnStarted: ContinuousClock.Instant?
        var activePhase = "preparation"
        var timing = EvaluationSampleTiming(
            preparationMilliseconds: nil,
            generationMilliseconds: nil,
            scoringMilliseconds: nil
        )
        var imageInputTokenCountAvailable = images.isEmpty

        do {
            let sessionPreparationSpanID = workflow.begin(kind: .preparation, title: "Set up session", parentID: preparationSpanID,
                metadata: ["operation": "sessionSetup"])
            var tools: [any Tool] = suite.modelConfiguration.referenceMode == .lookupTool
                ? [ReferenceLookupTool(index: ReferenceSearchIndex(attachments: suite.attachments), recorder: recorder)] : []
            tools += try EvaluationCustomTool.makeTools(definitions: suite.features.tools, recorder: customRecorder)
            let visionConfiguration = suite.modelConfiguration.customizationSettings.visionSettings
            tools += visionConfiguration.makeTools()
            let visionToolBoundary = visionConfiguration.boundary(limiter: toolCallLimiter)
            spotlightRuntime = try EvaluationSpotlightSearchRuntime.make(
                from: suite.features.spotlightSearch,
                limiter: toolCallLimiter
            )
            if let spotlightRuntime {
                tools.append(spotlightRuntime.tool)
                spotlightRecording = spotlightRuntime.startRecording()
            }
            let restoreSpanID = workflow.begin(kind: .preparation, title: "Restore conversation", parentID: sessionPreparationSpanID,
                metadata: ["operation": "restoreHistory"])
            let restoredHistory = try EvaluationConversationRuntime.restoredHistory(from: evaluationCase.conversation)
            workflow.finish(restoreSpanID, metadata: ["historyEntries": String(restoredHistory.count)])
            restoredBuiltinToolCallIDs = Set(
                EvaluationBuiltinToolTrace.tools(from: restoredHistory, names: builtinToolNames).map(\.id)
            )
            conversationTrace.restoredEntryCount = restoredHistory.count
            let activeSession = suite.features.profile.enabled
                ? EvaluationDynamicProfile.makeSession(model: model, instructions: suite.instructions,
                    tools: tools, configuration: suite.features.profile, recorder: profileRecorder,
                    history: restoredHistory,
                    modelHistoryProjection: evaluationCase.conversation.modelHistoryProjection,
                    toolBoundary: visionToolBoundary)
                : EvaluationConversationRuntime.makeSession(
                    model: model,
                    tools: tools,
                    instructions: suite.instructions,
                    history: restoredHistory,
                    modelHistoryProjection: evaluationCase.conversation.modelHistoryProjection,
                    toolBoundary: visionToolBoundary
                )
            session = activeSession
            activeSession.transcriptErrorHandlingPolicy = suite.modelConfiguration.transcriptErrorHandlingPolicy
            workflow.finish(sessionPreparationSpanID, metadata: ["toolCount": String(tools.count)])
            if suite.features.prewarm {
                let prewarmSpanID = workflow.begin(kind: .preparation, title: "Prewarm session", parentID: preparationSpanID,
                    metadata: ["operation": "prewarm", "timingScope": "Prewarm request and configured wait"])

                let prefix = suite.modelConfiguration.customizationSettings.warmupPrefix
                activeSession.prewarm(promptPrefix: prefix.isEmpty ? nil : Prompt { prefix })
                let warmupSeconds = suite.modelConfiguration.customizationSettings.warmupSeconds
                if warmupSeconds > 0 {
                    try await Task.sleep(for: .seconds(warmupSeconds))
                }
                workflow.finish(prewarmSpanID, metadata: ["configuredWaitSeconds": String(warmupSeconds)])
            }

            for (index, setupTurn) in evaluationCase.conversation.setupTurns.enumerated() {
                let turnStarted = ContinuousClock.now
                let setupPreparationSpanID = workflow.begin(kind: .preparation, title: "Prepare setup turn \(index + 1)",
                    parentID: preparationSpanID, metadata: ["operation": "prepareSetupTurn", "turnID": setupTurn.id.uuidString])
                var setupEffectivePrompt: String?
                do {
                    try Task.checkCancellation()
                    var setupSuite = suite
                    setupSuite.scoringMode = .review
                    setupSuite.attachments = []
                    setupSuite.features.outputFields = []
                    let storedHistory = Array(activeSession.transcript.history)
                    let modelFacingHistory = EvaluationConversationRuntime.modelFacingHistory(
                        storedHistory,
                        projection: evaluationCase.conversation.modelHistoryProjection
                    )
                    let historyEstimate = try await EvaluationInputTokenCounter.historyEstimate(
                        modelFacingHistory
                    )
                    imageInputTokenCountAvailable = imageInputTokenCountAvailable
                        && historyEstimate.imageTokenCountAvailable
                    let setupCase = EvaluationCase(
                        id: setupTurn.id,
                        name: "Setup turn \(index + 1)",
                        prompt: setupTurn.prompt,
                        expected: ""
                    )
                    let setupPrepared = try await preparedPrompt(
                        for: setupCase,
                        suite: setupSuite,
                        images: [],
                        contextSize: contextSize,
                        tools: tools,
                        historyTokenCount: historyEstimate.count,
                        historyImageTokenCountAvailable: historyEstimate.imageTokenCountAvailable
                    )
                    setupEffectivePrompt = setupPrepared.text
                    workflow.finish(setupPreparationSpanID, metadata: ["estimatedInputTokens": String(setupPrepared.tokenCount)])
                    activePhase = "generation"
                    let setupSpanID = workflow.begin(
                        kind: .generation, title: "Setup turn \(index + 1)", parentID: preparationSpanID,
                        metadata: ["turnID": setupTurn.id.uuidString, "role": "setup", "setupTurn": String(index + 1)]
                    )
                    workflow.activeParentID = setupSpanID
                    let response = try await EvaluationConversationRuntime.generateSetupTurn(
                        setupPrepared.prompt,
                        session: activeSession,
                        suite: setupSuite,
                        metadata: [
                            "evalRunID": runID.uuidString,
                            "evalCaseID": evaluationCase.id.uuidString,
                            "repetition": repetition,
                            "role": "setup",
                            "setupTurn": index + 1,
                            "estimatedInputTokens": setupPrepared.tokenCount,
                            "imageInputTokenCountAvailable": setupPrepared.imageInputTokenCountAvailable
                        ],
                        onPartial: { content in
                            await liveResponse(EvaluationLiveResponse(
                                caseID: evaluationCase.id,
                                caseName: evaluationCase.name,
                                repetition: repetition,
                                turnName: "Setup turn \(index + 1)",
                                content: content
                            ))
                        }
                    )
                    var setupMetadata = EvaluationWorkflowRecorder.usageMetadata(Self.usage(from: response.usage))
                    if let firstContentMilliseconds = response.firstContentMilliseconds {
                        setupMetadata["firstContentMilliseconds"] = String(firstContentMilliseconds)
                        setupMetadata["firstContentTimingSource"] = "App-observed first visible content"
                    }
                    workflow.finish(setupSpanID, metadata: setupMetadata)
                    workflow.activeParentID = nil
                    activePhase = "preparation"
                    builtinToolCalls = Self.mergingBuiltinToolCalls(
                        builtinToolCalls,
                        with: EvaluationBuiltinToolTrace.tools(
                            from: response.transcriptEntries,
                            names: builtinToolNames
                        )
                    )
                    conversationTrace.turns.append(EvaluationConversationTurnTrace(
                        id: setupTurn.id,
                        kind: .setup,
                        prompt: setupTurn.prompt,
                        effectivePrompt: setupEffectivePrompt,
                        response: response.content,
                        durationMilliseconds: Self.milliseconds(since: turnStarted),
                        usage: Self.usage(from: response.usage),
                        errorCategory: nil,
                        errorMessage: nil
                    ))
                } catch {
                    let failedAt = ContinuousClock.now
                    refusalTrace = await EvaluationRefusalTrace.capture(from: error)
                    builtinToolCalls = Self.mergingBuiltinToolCalls(
                        builtinToolCalls,
                        with: EvaluationBuiltinToolTrace.tools(
                            from: activeSession.transcript,
                            names: builtinToolNames
                        ).filter { !restoredBuiltinToolCallIDs.contains($0.id) }
                    )
                    let traceError = Self.traceError(error)
                    workflow.finish(setupPreparationSpanID, status: EvaluationWorkflowRecorder.status(for: error),
                        errorMessage: traceError.message, at: failedAt)
                    workflow.finish(workflow.activeParentID, status: EvaluationWorkflowRecorder.status(for: error),
                        errorMessage: traceError.message, at: failedAt)
                    conversationTrace.turns.append(EvaluationConversationTurnTrace(
                        id: setupTurn.id,
                        kind: .setup,
                        prompt: setupTurn.prompt,
                        effectivePrompt: setupEffectivePrompt,
                        response: nil,
                        durationMilliseconds: Self.milliseconds(since: turnStarted),
                        usage: nil,
                        errorCategory: traceError.category,
                        errorMessage: traceError.message,
                        refusal: refusalTrace
                    ))
                    throw error
                }
            }

            let historyPolicySpanID = workflow.begin(kind: .preparation, title: "Apply conversation history", parentID: preparationSpanID,
                metadata: ["operation": "applyHistoryPolicy"])
            let historyCounts = EvaluationConversationRuntime.applyHistoryPolicy(
                evaluationCase.conversation,
                to: activeSession
            )
            workflow.finish(historyPolicySpanID, metadata: ["entriesBefore": String(historyCounts.before), "entriesAfter": String(historyCounts.after)])
            let promptPreparationSpanID = workflow.begin(kind: .preparation, title: "Prepare scored prompt", parentID: preparationSpanID,
                metadata: ["operation": "preparePrompt"])
            conversationTrace.historyEntryCountBeforeFinal = historyCounts.before
            conversationTrace.historyEntryCountAfterPolicy = historyCounts.after
            let storedHistory = Array(activeSession.transcript.history)
            let modelFacingHistory = EvaluationConversationRuntime.modelFacingHistory(
                storedHistory,
                projection: evaluationCase.conversation.modelHistoryProjection
            )
            conversationTrace.modelFacingHistoryEntryCountBeforeFinal = modelFacingHistory.count
            let historyEstimate = try await EvaluationInputTokenCounter.historyEstimate(
                modelFacingHistory
            )
            imageInputTokenCountAvailable = imageInputTokenCountAvailable
                && historyEstimate.imageTokenCountAvailable
            finalTurnStarted = ContinuousClock.now
            let prepared = try await preparedPrompt(
                for: evaluationCase,
                suite: suite,
                images: images,
                contextSize: contextSize,
                tools: tools,
                historyTokenCount: historyEstimate.count,
                historyImageTokenCountAvailable: historyEstimate.imageTokenCountAvailable
            )
            imageInputTokenCountAvailable = imageInputTokenCountAvailable
                && prepared.imageInputTokenCountAvailable
            effectivePrompt = prepared.text
            workflow.finish(promptPreparationSpanID, metadata: ["estimatedInputTokens": String(prepared.tokenCount)])
            timing.preparationMilliseconds = Self.milliseconds(since: started)
            generationStarted = ContinuousClock.now
            workflow.finish(preparationSpanID, metadata: ["estimatedInputTokens": String(prepared.tokenCount)])
            generationSpanID = workflow.begin(kind: .generation, title: "Generate response", parentID: rootSpanID,
                metadata: ["role": "evaluation", "streaming": String(suite.features.streamResponse)])
            workflow.activeParentID = generationSpanID
            activePhase = "generation"
            let response = try await EvaluationFeatureResponse.generate(
                session: activeSession, prompt: prepared.prompt, suite: suite,
                metadata: ["evalRunID": runID.uuidString, "evalCaseID": evaluationCase.id.uuidString,
                           "repetition": repetition, "estimatedInputTokens": prepared.tokenCount,
                           "imageInputTokenCountAvailable": prepared.imageInputTokenCountAvailable],
                onPartial: { content in
                    await liveResponse(EvaluationLiveResponse(
                        caseID: evaluationCase.id,
                        caseName: evaluationCase.name,
                        repetition: repetition,
                        turnName: "Scored prompt",
                        content: content
                    ))
                }
            )
            builtinToolCalls = Self.mergingBuiltinToolCalls(
                builtinToolCalls,
                with: EvaluationBuiltinToolTrace.tools(
                    from: response.transcriptEntries,
                    names: builtinToolNames
                )
            )
            var generationMetadata = EvaluationWorkflowRecorder.usageMetadata(Self.usage(from: response.usage))
            if let firstContentMilliseconds = response.firstContentMilliseconds {
                generationMetadata["firstContentMilliseconds"] = String(firstContentMilliseconds)
                generationMetadata["firstContentTimingSource"] = "App-observed first visible content"
            }
            workflow.finish(generationSpanID, metadata: generationMetadata)
            workflow.activeParentID = nil
            featureTrace.firstContentMilliseconds = response.firstContentMilliseconds
            signposter.endInterval("Model request", interval)
            activePhase = "scoring"

            if let generationStarted {
                timing.generationMilliseconds = Self.milliseconds(since: generationStarted)
            }
            let subjectDuration = Self.milliseconds(since: started)
            let usage = Self.usage(from: activeSession.usage)
            let reasoningText = Self.reasoningText(from: response.transcriptEntries)
            conversationTrace.turns.append(EvaluationConversationTurnTrace(
                id: evaluationCase.id,
                kind: .evaluation,
                prompt: evaluationCase.prompt,
                effectivePrompt: prepared.text,
                response: response.content,
                durationMilliseconds: finalTurnStarted.map { Self.milliseconds(since: $0) } ?? 0,
                usage: Self.usage(from: response.usage),
                errorCategory: nil,
                errorMessage: nil
            ))
            let toolCalls = await recorder.snapshot()
            featureTrace.customToolCalls = await customRecorder.snapshot()
            featureTrace.profileEvents = await profileRecorder.snapshot()
            if suite.modelConfiguration.customizationSettings.captureTranscript {
                featureTrace.builtinToolCalls = builtinToolCalls.isEmpty ? nil : builtinToolCalls
            }
            featureTrace.spotlightSearch = await spotlightRuntime?.stopRecording(
                spotlightRecording,
                expectingReplies: builtinToolCalls.contains {
                    EvaluationSpotlightSearchConfiguration.knownToolNames.contains($0.toolName)
                }
            )
            featureTrace.conversation = conversationTrace
            if suite.modelConfiguration.customizationSettings.captureTranscript {
                featureTrace.transcript = EvaluationTranscriptTrace.capture(
                    activeSession.transcript,
                    outcome: .success
                )
            }
            let referenceEvidence = await recorder.evidenceText()
            let customEvidence = suite.features.tools.isEmpty ? nil : await customRecorder.evidenceText()
            let builtinEvidence = EvaluationBuiltinToolTrace.evidenceText(for: builtinToolCalls)
            let evidenceParts = [referenceEvidence, customEvidence, builtinEvidence]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            let toolEvidence = evidenceParts.isEmpty ? nil : evidenceParts.joined(separator: "\n\n")
            var scoringSuite = suite
            if await profileRecorder.transitioned {
                scoringSuite.instructions = [suite.instructions, suite.features.profile.afterToolInstructions]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            let scoringStarted = ContinuousClock.now
            let scoringSpanID = workflow.begin(kind: .scoring, title: "Score response", parentID: rootSpanID,
                metadata: ["scoringMode": suite.scoringMode.rawValue])
            workflow.activeParentID = scoringSpanID
            let scoring = await score(
                response: response.content,
                evaluationCase: evaluationCase,
                effectivePrompt: prepared.text,
                suite: scoringSuite,
                runID: runID,
                images: images,
                model: model,
                contextSize: contextSize,
                toolEvidence: toolEvidence,
                workflowRecorder: workflow
            )
            timing.scoringMilliseconds = Self.milliseconds(since: scoringStarted)
            let assertionResults = EvaluationFieldAssertions.evaluate(
                response: response.content,
                assertions: evaluationCase.fieldAssertions ?? []
            )
            let finalStatus = EvaluationFieldAssertions.gatedStatus(
                baseStatus: scoring.status,
                results: assertionResults
            )

            let workflowStatus: EvaluationWorkflowSpanStatus = scoring.errorCategory == "cancelled"
                ? .cancelled : scoring.errorCategory != nil || finalStatus == .failed ? .failed : .succeeded
            workflow.finish(scoringSpanID, status: workflowStatus, errorMessage: scoring.errorMessage,
                metadata: ["resultStatus": finalStatus.rawValue])
            workflow.finish(rootSpanID, status: workflowStatus, errorMessage: scoring.errorMessage,
                metadata: ["resultStatus": finalStatus.rawValue])
            workflow.activeParentID = nil
            return EvaluationSampleResult(
                caseID: evaluationCase.id,
                caseName: evaluationCase.name,
                repetition: repetition,
                prompt: evaluationCase.prompt,
                effectivePrompt: prepared.text,
                expected: evaluationCase.expected,
                response: response.content,
                reasoningText: reasoningText,
                status: finalStatus,
                score: scoring.score,
                rationale: scoring.rationale,
                durationMilliseconds: subjectDuration,
                usage: usage,
                judgeDurationMilliseconds: scoring.durationMilliseconds,
                judgeUsage: scoring.usage,
                judgeReasoningText: scoring.reasoningText,
                errorCategory: nil,
                errorMessage: nil,
                judgeErrorCategory: scoring.errorCategory,
                judgeErrorMessage: scoring.errorMessage,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                timing: timing,
                featureTrace: featureTrace,
                judgeTrace: scoring.trace,
                fieldAssertionResults: assertionResults.isEmpty ? nil : assertionResults,
                imageInputTokenCountAvailable: imageInputTokenCountAvailable,
                workflowTrace: workflow.snapshot()
            )
        } catch {
            let failedAt = ContinuousClock.now
            signposter.endInterval("Model request", interval)
            if refusalTrace == nil {
                refusalTrace = await EvaluationRefusalTrace.capture(from: error)
            }
            if let generationStarted {
                timing.generationMilliseconds = Self.milliseconds(since: generationStarted)
            } else {
                timing.preparationMilliseconds = Self.milliseconds(since: started)
            }
            var traceError = Self.traceError(error)
            if traceError.category == "generation", activePhase != "generation" {
                traceError.category = activePhase
            }
            workflow.finishOpenSpans(status: EvaluationWorkflowRecorder.status(for: error), errorMessage: traceError.message,
                excluding: rootSpanID, at: failedAt)
            if let finalTurnStarted,
               !conversationTrace.turns.contains(where: { $0.kind == .evaluation }) {
                conversationTrace.turns.append(EvaluationConversationTurnTrace(
                    id: evaluationCase.id,
                    kind: .evaluation,
                    prompt: evaluationCase.prompt,
                    effectivePrompt: effectivePrompt,
                    response: nil,
                    durationMilliseconds: Self.milliseconds(since: finalTurnStarted),
                    usage: nil,
                    errorCategory: traceError.category,
                    errorMessage: traceError.message,
                    refusal: refusalTrace
                ))
            }
            featureTrace.customToolCalls = await customRecorder.snapshot()
            featureTrace.profileEvents = await profileRecorder.snapshot()
            if let session {
                builtinToolCalls = Self.mergingBuiltinToolCalls(
                    builtinToolCalls,
                    with: EvaluationBuiltinToolTrace.tools(
                        from: session.transcript,
                        names: builtinToolNames
                    ).filter { !restoredBuiltinToolCallIDs.contains($0.id) }
                )
            }
            if suite.modelConfiguration.customizationSettings.captureTranscript {
                featureTrace.builtinToolCalls = builtinToolCalls.isEmpty ? nil : builtinToolCalls
            }
            featureTrace.spotlightSearch = await spotlightRuntime?.stopRecording(
                spotlightRecording,
                expectingReplies: builtinToolCalls.contains {
                    EvaluationSpotlightSearchConfiguration.knownToolNames.contains($0.toolName)
                }
            )
            featureTrace.conversation = conversationTrace
            if suite.modelConfiguration.customizationSettings.captureTranscript,
               let session {
                featureTrace.transcript = EvaluationTranscriptTrace.capture(
                    session.transcript,
                    outcome: .failure
                )
            }
            let toolCalls = await recorder.snapshot()
            workflow.finish(rootSpanID, status: EvaluationWorkflowRecorder.status(for: error), errorMessage: traceError.message)
            workflow.activeParentID = nil
            return EvaluationSampleResult(
                caseID: evaluationCase.id,
                caseName: evaluationCase.name,
                repetition: repetition,
                prompt: evaluationCase.prompt,
                effectivePrompt: effectivePrompt,
                expected: evaluationCase.expected,
                response: "",
                status: .error,
                score: nil,
                rationale: nil,
                durationMilliseconds: Self.milliseconds(since: started),
                usage: session.map { Self.usage(from: $0.usage) } ?? EvaluationUsage(),
                judgeDurationMilliseconds: nil,
                judgeUsage: nil,
                errorCategory: traceError.category,
                errorMessage: traceError.message,
                judgeErrorCategory: nil,
                judgeErrorMessage: nil,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                timing: timing,
                featureTrace: featureTrace,
                refusal: refusalTrace,
                imageInputTokenCountAvailable: imageInputTokenCountAvailable,
                workflowTrace: workflow.snapshot()
            )
        }
    }
}
