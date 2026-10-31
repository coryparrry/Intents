import Foundation
import FoundationModels
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import FoundationEvals

@MainActor
struct EvaluationObservedContextTests {
    @Test func freezesObservedRetainedResponsesAndProjectionWithoutTranscriptTracing() throws {
        let history = turn("Discarded customer", "Discarded response") + turn("Retained customer", "Observed response 483")
        let retained = EvaluationConversationRuntime.retainedHistory(history, policy: .retainRecentCompleteTurns, recentTurnCount: 1)
        let facing = EvaluationConversationRuntime.modelFacingHistory(retained, projection: .init(policy: .keepAll))
        let snapshot = EvaluationJudgeSubjectContext.capture(facing, instructions: "Summarize the customer request.")
        #expect(snapshot.unavailableReason == nil)
        #expect(snapshot.entries.map(\.role) == ["user", "assistant"])
        #expect(snapshot.evidenceText.contains("Observed response 483"))
        #expect(!snapshot.evidenceText.contains("Discarded"))
        let reset = EvaluationConversationRuntime.modelFacingHistory(retained, projection: .init(policy: .reset))
        #expect(EvaluationJudgeSubjectContext.capture(reset, instructions: "").entries.isEmpty)
        let unfinished = Transcript.Entry.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "Obsolete unfinished prompt"))]))
        let beforeNextPrompt = EvaluationConversationRuntime.modelFacingHistory(retained + [unfinished], projection: .init(policy: .reset))
        #expect(beforeNextPrompt.isEmpty)
        let retainedBeforeNextPrompt = EvaluationConversationRuntime.modelFacingHistory(retained + [unfinished], projection: .init(policy: .retainRecentCompleteTurns, retainedTurnCount: 1))
        #expect(retainedBeforeNextPrompt == retained)
        var suite = EvaluationSuite()
        suite.modelConfiguration.customizationSettings.captureTranscript = false
        let item = sample(suite: suite, context: snapshot)
        #expect(item.featureTrace?.transcript == nil)
        let restored = try CanonicalJSON.decode(EvaluationSampleResult.self, from: CanonicalJSON.data(for: item))
        #expect(restored.judgeSubjectContext == snapshot)
    }

    @Test func observedHistoryUsesStableKeyOrderAcrossReloads() throws {
        let snapshot = EvaluationJudgeSubjectContext.capture(
            turn("Remember order 483", "Confirmed 483"), instructions: "Retain this request"
        )
        let expected = #"[{"content":"Remember order 483","role":"user"},{"content":"Confirmed 483","role":"assistant"}]"#
        for _ in 0..<32 {
            let restored = try CanonicalJSON.decode(EvaluationJudgeSubjectContext.self,
                from: CanonicalJSON.data(for: snapshot))
            #expect(snapshot.evidenceText == expected)
            #expect(restored.evidenceText == expected)
            #expect(restored.entries == snapshot.entries)
        }
    }

    @Test func realSessionRunnerCapturesGeneratedSetupHistoryWithTracingDisabled() async throws {
        var suite = fixture().0
        suite.judgeConfiguration.mode = .sameModel
        suite.modelConfiguration.provider = .customHTTP
        suite.modelConfiguration.customizationSettings.captureTranscript = false
        suite.features.prewarm = false
        suite.cases[0].conversation.setupTurns = [.init(prompt: "Cancel order 483 and keep 484")]
        let run = await EvaluationRunner().run(id: UUID(), suiteRevision: "fixture", startedAt: Date(), suite: suite,
            images: [], model: ObservedContextModel(), contextSize: 131_072, modelName: "Fixture executor", admissionError: nil,
            externalJudge: nil, liveResponse: { _ in }, progress: { _, _, _ in })
        let result = try #require(run.results.first)
        #expect(result.errorMessage == nil)
        #expect(result.judgeErrorMessage == nil)
        #expect(result.status == .passed)
        #expect(result.featureTrace?.transcript == nil)
        #expect(result.judgeSubjectContext?.evidenceText.contains("Generated acknowledgement: cancel 483") == true)
        #expect(result.judgeTrace?.prompt.contains("Generated acknowledgement: cancel 483") == true)
        #expect(result.judgeSubjectContext?.entries.map(\.role) == ["user", "assistant"])
    }

    @Test func restoredHistoryAndSetupGeneratedResponsesReachJudgePrompt() throws {
        let history = turn("Remember order 483", "I will retain 483")
        let transcript = Transcript(entries: history)
        let json = String(decoding: try JSONEncoder().encode(transcript), as: UTF8.self)
        let restored = try EvaluationConversationRuntime.restoredHistory(from: .init(restoredTranscriptJSON: json))
        let context = EvaluationJudgeSubjectContext.capture(restored, instructions: "Observed instructions")
        let (suite, _) = fixture()
        let prompt = EvaluationRunner.judgePrompt(response: "483", evaluationCase: suite.cases[0], effectivePrompt: "Which order?",
            suite: suite, toolEvidence: nil, subjectContext: context)
        #expect(prompt.contains("observedModelFacingHistory:"))
        #expect(prompt.contains("I will retain 483"))
        #expect(prompt.contains("Observed instructions"))
    }

    @Test func missingLegacyMultiTurnEvidenceCannotBeInvented() throws {
        let single = EvaluationCase(name: "Single", prompt: "Hello", expected: "")
        #expect(try EvaluationJudgeSubjectContext.resolved(nil, evaluationCase: single).entries.isEmpty)
        var multi = single
        multi.conversation.setupTurns = [.init(prompt: "Remember 483")]
        #expect(throws: EvaluationJudgeSubjectContext.ContextError.self) {
            try EvaluationJudgeSubjectContext.resolved(nil, evaluationCase: multi)
        }
        // An observed empty projection is evidence; configured setup prompts alone are not.
        #expect(try EvaluationJudgeSubjectContext.resolved(.init(), evaluationCase: multi).entries.isEmpty)
        var failed = EvaluationJudgeSubjectContext()
        failed.unavailableReason = "Unsupported history"
        #expect(throws: EvaluationJudgeSubjectContext.ContextError.self) {
            try EvaluationJudgeSubjectContext.resolved(failed, evaluationCase: single)
        }
        var future = EvaluationJudgeSubjectContext()
        future.formatVersion = 99
        #expect(throws: EvaluationJudgeSubjectContext.ContextError.self) {
            try EvaluationJudgeSubjectContext.resolved(future, evaluationCase: single)
        }
    }

    /// Binary transcript entries cannot silently disappear from the evidence used to judge a response.
    @available(macOS 27.2, *)
    @Test func dataEntriesMakeJudgeContextUnavailable() throws {
        // Serialized on SDK 27.2; avoids referring to a case absent from the 27.1 SDK interface.
        let fixture = #"{"transcript":{"entries":[{"data":{"content":"YnVzaW5lc3MgaW5wdXQ=","contentType":"public.plain-text"},"id":"unsupported-data-fixture","role":"data"}]},"version":"1.1","type":"FoundationModels.Transcript"}"#
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(fixture.utf8))
        #expect(transcript.count == 1)
        let context = EvaluationJudgeSubjectContext.capture(Array(transcript), instructions: "Summarize")
        #expect(context.unavailableReason != nil)
        #expect(context.entries.isEmpty)
        #expect(throws: EvaluationJudgeSubjectContext.ContextError.self) {
            try EvaluationJudgeSubjectContext.resolved(context,
                evaluationCase: EvaluationCase(name: "Data", prompt: "Summarize", expected: ""))
        }
    }

    @Test func contextCaptureRejectsOversizeInsteadOfTruncating() {
        let context = EvaluationJudgeSubjectContext.capture(turn(String(repeating: "x", count: EvaluationJudgeSubjectContext.maximumBytes), "answer"), instructions: "")
        #expect(context.unavailableReason != nil)
        #expect(context.entries.isEmpty)
    }

    @Test func sameModelAdmissionAccountsForObservedHistory() async throws {
        var suite = fixture().0
        suite.judgeConfiguration.mode = .sameModel
        suite.instructions = ""
        suite.modelConfiguration.maximumResponseTokens = 128
        let runner = EvaluationRunner()
        let counter = ObservedContextTokenCounter()
        _ = try await runner.preparedPrompt(for: suite.cases[0], suite: suite, images: [], contextSize: 8_192,
            tools: [], judgeSubjectContext: .init(), tokenCounter: counter)
        let large = EvaluationJudgeSubjectContext(entries: [.init(role: "assistant", content: String(repeating: "x", count: 12_000))])
        await #expect(throws: (any Error).self) {
            _ = try await runner.preparedPrompt(for: suite.cases[0], suite: suite, images: [], contextSize: 8_192,
                tools: [], judgeSubjectContext: large, tokenCounter: counter)
        }
    }

    @Test func profileInstructionAdmissionUsesEncodedBytesAndAcceptsExactLimit() throws {
        let context = EvaluationJudgeSubjectContext(entries: [.init(role: "assistant", content: "Observed history")], subjectInstructions: "")
        let selected = try context.admittingInstructionVariants(["AAAA", "\n\n\n"])
        #expect(selected.subjectInstructions == "\n\n\n")
        #expect(selected.entries == context.entries)
        // The active profile may already be the expanded one after a setup tool.
        let active = try selected.admittingInstructionVariants(["AAAA", "\n\n\n"])
        #expect(active == selected)

        var boundary = EvaluationJudgeSubjectContext(entries: [.init(role: "assistant", content: "")], subjectInstructions: "")
        let overhead = try JSONEncoder().encode(boundary).count
        boundary.entries[0].content = String(repeating: "x", count: EvaluationJudgeSubjectContext.maximumBytes - overhead)
        #expect(try JSONEncoder().encode(boundary).count == EvaluationJudgeSubjectContext.maximumBytes)
        #expect(try boundary.admittingInstructionVariants([""]) == boundary)
        #expect(throws: EvaluationJudgeSubjectContext.ContextError.self) {
            try boundary.admittingInstructionVariants(["", "\n"])
        }
    }

    @Test(arguments: [EvaluationJudgeMode.sameModel, .connection])
    func profileGrowthOverEvidenceLimitStopsBeforeSubjectExecutor(mode: EvaluationJudgeMode) async throws {
        var suite = fixture().0
        suite.judgeConfiguration.mode = mode
        suite.instructions = "Base instructions"
        suite.modelConfiguration.provider = .customHTTP
        suite.modelConfiguration.customProviderSettings.contextSize = 262_144
        suite.modelConfiguration.customProviderSettings.tokenizerEndpoint = "http://127.0.0.1:19096/tokenize"
        suite.modelConfiguration.customProviderSettings.supportsToolCalling = true
        suite.modelConfiguration.customProviderSettings.supportsGuidedGeneration = true
        suite.features.profile.enabled = true
        suite.features.profile.afterToolInstructions = String(repeating: "p", count: EvaluationProfileConfiguration.maximumInstructionsBytes)
        suite.features.tools = [.init(name: "context_fixture", description: "Profile transition fixture", fixtureResponse: "ok")]
        let history = turn(String(repeating: "🧪", count: 130_200), "Observed acknowledgement")
        suite.cases[0].conversation.restoredTranscriptJSON = String(decoding: try JSONEncoder().encode(Transcript(entries: history)), as: UTF8.self)
        #expect(suite.cases[0].conversation.validationIssue == nil)
        #expect(suite.features.validationIssue == nil)
        #expect(suite.modelConfiguration.customProviderSettings.validationIssue == nil)
        let context = EvaluationJudgeSubjectContext.capture(history, instructions: suite.instructions)
        #expect(context.unavailableReason == nil)
        #expect(try JSONEncoder().encode(context).count <= EvaluationJudgeSubjectContext.maximumBytes)
        var expanded = context
        expanded.subjectInstructions = [suite.instructions, suite.features.profile.afterToolInstructions].joined(separator: "\n\n")
        #expect(try JSONEncoder().encode(expanded).count > EvaluationJudgeSubjectContext.maximumBytes)

        // Exact provider token counting can admit large Unicode inputs. Evidence
        // byte admission must therefore work independently of token estimates.
        let counter = EvaluationDeferredPromptInputTokenCounter()
        let tools: [any Tool] = try EvaluationCustomTool.makeTools(definitions: suite.features.tools,
            recorder: EvaluationCustomToolRecorder(maximumCalls: 1), tokenCounter: EvaluationPortablePromptInputTokenCounter())
        var withoutTransition = suite
        withoutTransition.features.profile.afterToolInstructions = ""
        _ = try await EvaluationRunner().preparedPrompt(for: suite.cases[0], suite: withoutTransition, images: [],
            contextSize: 262_144, tools: tools, judgeSubjectContext: context, tokenCounter: counter)
        await #expect(throws: EvaluationJudgeSubjectContext.ContextError.self) {
            _ = try await EvaluationRunner().preparedPrompt(for: suite.cases[0], suite: suite, images: [],
                contextSize: 262_144, tools: tools, judgeSubjectContext: context, tokenCounter: counter)
        }
        // Merely enabling a profile cannot make its after-tool state reachable.
        // This valid no-tool profile must admit the same near-limit base history.
        var noTools = suite
        noTools.features.tools = []
        noTools.features.profile.requireToolFirst = false
        #expect(noTools.features.validationIssue == nil)
        _ = try await EvaluationRunner().preparedPrompt(for: noTools.cases[0], suite: noTools, images: [],
            contextSize: 262_144, tools: [], judgeSubjectContext: context, tokenCounter: counter)
        // An already activated setup profile still requires expanded admission,
        // even when its current tool set has become empty.
        await #expect(throws: EvaluationJudgeSubjectContext.ContextError.self) {
            _ = try await EvaluationRunner().preparedPrompt(for: noTools.cases[0], suite: noTools, images: [],
                contextSize: 262_144, tools: [], judgeSubjectContext: context,
                profileHasTransitioned: true, tokenCounter: counter)
        }
        // Restored tool output activates the second profile before any new tool
        // can run. Its admission must not depend on lazy onActivate scheduling.
        let restoredToolHistory = [history[0],
            .toolCalls(Transcript.ToolCalls([Transcript.ToolCall(id: "restored-call", toolName: "context_fixture",
                arguments: GeneratedContent(properties: [:]))])),
            .toolOutput(Transcript.ToolOutput(id: "restored-call", toolName: "context_fixture",
                segments: [.text(Transcript.TextSegment(content: "ok"))])),
            history[1]]
        noTools.cases[0].conversation.restoredTranscriptJSON = String(
            decoding: try JSONEncoder().encode(Transcript(entries: restoredToolHistory)), as: UTF8.self)
        #expect(noTools.cases[0].conversation.validationIssue == nil)
        let restoredRun = await EvaluationRunner().run(id: UUID(), suiteRevision: "restored-profile-byte-limit", startedAt: Date(), suite: noTools,
            images: [], model: AdmissionMustNotExecuteModel(), contextSize: 262_144, modelName: "Must not execute", admissionError: nil,
            externalJudge: nil, liveResponse: { _ in }, progress: { _, _, _ in })
        let restoredResult = try #require(restoredRun.results.first)
        #expect(restoredResult.status == .error)
        #expect(restoredResult.response.isEmpty)
        #expect(restoredResult.errorMessage?.contains("capture limit") == true)
        let run = await EvaluationRunner().run(id: UUID(), suiteRevision: "profile-byte-limit", startedAt: Date(), suite: suite,
            images: [], model: AdmissionMustNotExecuteModel(), contextSize: 262_144, modelName: "Must not execute", admissionError: nil,
            externalJudge: nil, liveResponse: { _ in }, progress: { _, _, _ in })
        let result = try #require(run.results.first)
        #expect(result.status == .error)
        #expect(result.response.isEmpty)
        #expect(result.errorMessage?.contains("capture limit") == true)
        #expect(result.judgeDurationMilliseconds == nil)

        // A byte bound for unused semantic evidence must not block collection or
        // an entirely deterministic rubric.
        for criteria in ["", "exact: \"483\""] {
            var deterministic = suite
            deterministic.criteria = criteria
            deterministic.scoringMode = criteria.isEmpty ? .review : .modelJudge
            _ = try await EvaluationRunner().preparedPrompt(for: suite.cases[0], suite: deterministic, images: [],
                contextSize: 262_144, tools: tools, judgeSubjectContext: context, tokenCounter: counter)
        }
    }

    @Test func initialScoringAndReloadedReassessmentUseIdenticalObservedContext() async throws {
        var (suite, connection) = fixture()
        suite.cases[0].conversation.setupTurns = [.init(prompt: "Remember the request")]
        let context = EvaluationJudgeSubjectContext.capture(turn("Cancel 483, keep 484", "Confirmed: cancel 483 only"), instructions: "Observed instructions")
        let transport = ObservedContextTransport(responses: [try completion(), try completion()])
        let client = EvaluationCompatibleJudgeClient(transport: { try await transport.send($0) })
        let resolved = EvaluationResolvedJudgeConnection(connection: connection, apiKey: nil)
        let outcome = await EvaluationRunner(compatibleJudgeClient: client).score(response: "483", evaluationCase: suite.cases[0],
            effectivePrompt: "Which order?", suite: suite, runID: UUID(), images: [], model: SystemLanguageModel.default,
            contextSize: 8_192, modelName: "No subject generation", externalJudge: resolved, toolEvidence: nil,
            subjectContext: context, tokenCounter: ObservedContextTokenCounter())
        #expect(outcome.status == .passed)
        var run = EvaluationRun(id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version, instructions: suite.instructions,
            criteria: suite.criteria, scoringMode: suite.scoringMode, repetitions: 1,
            startedAt: Date(), completedAt: Date(), cancelled: false,
            environment: .init(operatingSystem: "Fixture", locale: "en", model: "Fixture", modelContextSize: 8_192),
            attachments: [], results: [sample(suite: suite, context: context)])
        run.plannedCases = suite.cases
        let restored = try CanonicalJSON.decode(EvaluationRun.self, from: CanonicalJSON.data(for: run))
        suite.instructions = "Edited instructions must not replace observed input"
        let assessment = try await EvaluationReassessmentService(client: client).reassess(run: restored, suite: suite, images: [], resolved: resolved)
        #expect(assessment.samples.first?.status == .passed)
        let bodies = await transport.bodies()
        #expect(bodies.count == 2)
        let prompts = try bodies.map(userPrompt)
        #expect(prompts[0] == prompts[1])
        #expect(prompts[0].contains("Confirmed: cancel 483 only"))
        #expect(!prompts[0].contains("Edited instructions"))
    }

    @Test func realToolGenerationFreezesEvidenceWithTranscriptTracingDisabled() async throws {
        var (suite, connection) = fixture()
        suite.modelConfiguration.provider = .customHTTP
        suite.modelConfiguration.customizationSettings.captureTranscript = false
        suite.features.prewarm = false
        suite.features.tools = [.init(name: "lookup_order", description: "Look up an order",
            parameters: [.init(name: "order")], fixtureResponse: "Order 483 is ready; keep 484 unchanged.")]
        let transport = ObservedContextTransport(responses: [try completion(), try completion(), try completion()])
        let client = EvaluationCompatibleJudgeClient(transport: { try await transport.send($0) })
        let resolved = EvaluationResolvedJudgeConnection(connection: connection, apiKey: nil)
        let run = await EvaluationRunner(compatibleJudgeClient: client).run(
            id: UUID(), suiteRevision: "fixture", startedAt: Date(), suite: suite, images: [],
            model: ObservedToolModel(), contextSize: 131_072, modelName: "Tool fixture executor", admissionError: nil,
            externalJudge: resolved, liveResponse: { _ in }, progress: { _, _, _ in })
        let result = try #require(run.results.first)
        #expect(result.status == .passed)
        #expect(result.errorMessage == nil)
        #expect(result.judgeErrorMessage == nil)
        #expect(result.featureTrace?.transcript == nil)
        #expect(result.judgeSubjectContext?.entries.isEmpty == true, "The tool runs during the final generation, after history capture")
        let capture = try #require(result.judgeToolEvidence)
        #expect(capture.text?.contains("Arguments:") == true)
        #expect(capture.text?.contains("order") == true)
        #expect(capture.text?.contains("Order 483 is ready; keep 484 unchanged.") == true)
        try await verifyToolReplay(run: run, suite: suite, resolved: resolved, client: client, transport: transport)
    }

    @Test func allToolEvidenceSerializersSurviveReloadWithoutOptionalTraceCapture() async throws {
        let (suite, connection) = fixture()
        let reference = ReferenceToolRecorder(maximumCalls: 1)
        try await reference.record(callIndex: 1, results: [], output: "Reference passage: cancel 483 only")
        let custom = EvaluationCustomToolRecorder(maximumCalls: 1)
        let toolID = UUID()
        try await custom.beginCall(id: toolID, toolName: "lookup_order", argumentsJSON: "{\"order\":\"483\"}")
        await custom.finishCall(id: toolID, output: "Custom output: keep 484", durationMilliseconds: 7, outcome: .succeeded)
        let builtin = EvaluationBuiltinToolTrace.evidenceText(for: [
            .init(id: "builtin-1", toolName: "search", argumentsJSON: "{\"query\":\"orders\"}", output: "Builtin output: 483")
        ])
        let capture = EvaluationJudgeToolEvidence.capture(reference: await reference.evidenceText(),
            custom: await custom.evidenceText(), builtin: builtin)
        let context = EvaluationJudgeSubjectContext.capture([], instructions: suite.instructions)
        let transport = ObservedContextTransport(responses: [try completion(), try completion(), try completion()])
        let client = EvaluationCompatibleJudgeClient(transport: { try await transport.send($0) })
        let resolved = EvaluationResolvedJudgeConnection(connection: connection, apiKey: nil)
        let outcome = await EvaluationRunner(compatibleJudgeClient: client).score(response: "483", evaluationCase: suite.cases[0],
            effectivePrompt: "Which order?", suite: suite, runID: UUID(), images: [], model: SystemLanguageModel.default,
            contextSize: 131_072, modelName: "No subject generation", externalJudge: resolved,
            toolEvidence: try capture.validatedText(), subjectContext: context, tokenCounter: ObservedContextTokenCounter())
        #expect(outcome.status == .passed)
        var item = sample(suite: suite, context: context)
        item.judgeToolEvidence = capture
        var run = EvaluationRun(id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version,
            instructions: suite.instructions, criteria: suite.criteria, scoringMode: suite.scoringMode, repetitions: 1,
            startedAt: Date(), completedAt: Date(), cancelled: false,
            environment: .init(operatingSystem: "Fixture", locale: "en", model: "Fixture", modelContextSize: 131_072),
            attachments: [], results: [item])
        run.plannedCases = suite.cases
        #expect(run.results[0].featureTrace == nil)
        try await verifyToolReplay(run: run, suite: suite, resolved: resolved, client: client, transport: transport)
        let prompt = try userPrompt(try #require(await transport.bodies().first))
        for expected in ["Reference passage: cancel 483 only", "Custom output: keep 484", "Builtin output: 483"] {
            #expect(prompt.contains(expected))
        }
    }

    @Test func missingHistoricalToolEvidenceFailsClosedButCapturedAbsenceAndToolFreeLegacyReplay() async throws {
        for kind in ["legacy-tools", "captured-empty", "legacy-no-tools", "future-format", "oversize"] {
            var (suite, connection) = fixture()
            if kind != "legacy-no-tools" { suite.features.tools = [.init(name: "lookup", description: "Lookup", fixtureResponse: "483")] }
            var item = sample(suite: suite, context: .init())
            if kind == "captured-empty" { item.judgeToolEvidence = .init(text: nil) }
            if kind == "future-format" { item.judgeToolEvidence = .init(formatVersion: 99, text: "untrusted") }
            if kind == "oversize" { item.judgeToolEvidence = .init(text: String(repeating: "é", count: EvaluationJudgeToolEvidence.maximumUTF8Bytes)) }
            var run = EvaluationRun(id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version,
                instructions: suite.instructions, criteria: suite.criteria, scoringMode: suite.scoringMode, repetitions: 1,
                startedAt: Date(), completedAt: Date(), cancelled: false,
                environment: .init(operatingSystem: "Fixture", locale: "en", model: "Fixture", modelContextSize: 131_072),
                attachments: [], results: [item])
            run.plannedCases = suite.cases
            let transport = ObservedContextTransport(responses: [try completion()])
            let service = EvaluationReassessmentService(client: .init(transport: { try await transport.send($0) }))
            let assessment = try await service.reassess(run: run, suite: suite, images: [], resolved: .init(connection: connection, apiKey: nil))
            let supported = kind == "captured-empty" || kind == "legacy-no-tools"
            #expect(assessment.samples.first?.status == (supported ? .passed : .unscored))
            #expect(assessment.samples.first?.errorCategory == (supported ? nil : "incompleteSavedEvidence"))
            #expect(await transport.bodies().count == (supported ? 1 : 0))
        }
    }

    @Test func toolEvidenceBoundCountsUTF8BytesWithoutTruncation() throws {
        var capture = EvaluationJudgeToolEvidence.capture(reference: nil, custom: nil, builtin: nil)
        #expect(try capture.validatedText() == nil)
        let item = sample(suite: fixture().0, context: .init())
        var captured = item
        captured.judgeToolEvidence = capture
        let restored = try CanonicalJSON.decode(EvaluationSampleResult.self, from: CanonicalJSON.data(for: captured))
        #expect(restored.judgeToolEvidence != nil)
        #expect(restored.judgeToolEvidence?.text == nil)
        capture.text = String(repeating: "é", count: EvaluationJudgeToolEvidence.maximumUTF8Bytes / 2)
        #expect(try capture.validatedText() == capture.text)
        capture.text?.append("é")
        #expect(throws: EvaluationJudgeToolEvidence.EvidenceError.self) { try capture.validatedText() }
        let refused = EvaluationJudgeToolEvidence.capture(reference: capture.text, custom: nil, builtin: nil)
        #expect(refused.text == nil)
        #expect(refused.unavailableReason != nil)
        #expect(throws: EvaluationJudgeToolEvidence.EvidenceError.self) { try refused.validatedText() }
    }

    private func verifyToolReplay(run: EvaluationRun, suite: EvaluationSuite, resolved: EvaluationResolvedJudgeConnection,
                                  client: EvaluationCompatibleJudgeClient, transport: ObservedContextTransport) async throws {
        let restored = try CanonicalJSON.decode(EvaluationRun.self, from: CanonicalJSON.data(for: run))
        let service = EvaluationReassessmentService(client: client)
        let assessment = try await service.reassess(run: restored, suite: suite, images: [], resolved: resolved)
        let item = try #require(restored.results.first)
        let example = EvaluationReviewedJudgeExample(id: UUID(), sourceRunID: run.id, sourceAssessmentID: assessment.id,
            sampleID: item.id, expectedStatus: .passed, reason: "Matches tool evidence", createdAt: Date())
        let checked = try await service.checkJudge(sources: [
            .init(example: example, run: restored, assessment: assessment, suite: suite, images: [], errorMessage: nil)
        ], resolved: resolved)
        #expect(assessment.samples.first?.status == .passed)
        #expect(checked.passed)
        let bodies = await transport.bodies()
        #expect(bodies.count == 3)
        let prompts = try bodies.map(userPrompt)
        #expect(prompts[0] == prompts[1])
        #expect(prompts[0] == prompts[2])
    }

    @Test func unsupportedLegacyReassessmentRemainsReadableAndMakesNoRequest() async throws {
        var (suite, connection) = fixture()
        suite.cases[0].conversation.setupTurns = [.init(prompt: "Remember the order")]
        let item = sample(suite: suite, context: nil)
        var run = EvaluationRun(id: UUID(), suiteID: suite.id, suiteName: suite.name, suiteVersion: suite.version, instructions: suite.instructions,
            criteria: suite.criteria, scoringMode: suite.scoringMode, repetitions: 1,
            startedAt: Date(), completedAt: Date(), cancelled: false,
            environment: .init(operatingSystem: "Fixture", locale: "en", model: "Fixture", modelContextSize: 8_192),
            attachments: [], results: [item])
        run.plannedCases = suite.cases
        let restored = try CanonicalJSON.decode(EvaluationRun.self, from: CanonicalJSON.data(for: run))
        let transport = ObservedContextTransport(responses: [])
        let client = EvaluationCompatibleJudgeClient(transport: { try await transport.send($0) })
        let assessment = try await EvaluationReassessmentService(client: client).reassess(run: restored, suite: suite, images: [],
            resolved: .init(connection: connection, apiKey: nil))
        #expect(assessment.samples.first?.status == .unscored)
        #expect(assessment.samples.first?.errorCategory == "incompleteSavedEvidence")
        #expect(await transport.bodies().isEmpty)
    }

    @Test func oldDisclosureApprovalRequiresExplicitRenewalAndDefinitionPreservesLocalVersion() throws {
        var (suite, connection) = fixture()
        #expect(suite.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: connection))
        let definition = EvaluationSuiteDefinition(suite: suite)
        #expect(definition.judgeConfiguration.approvedEvidencePolicyVersion == nil)
        #expect(definition.applyingLocalState(from: suite).judgeConfiguration.approvedEvidencePolicyVersion == EvaluationJudgeConfiguration.currentEvidencePolicyVersion)
        var object = try #require(JSONSerialization.jsonObject(with: CanonicalJSON.data(for: suite.judgeConfiguration)) as? [String: Any])
        object.removeValue(forKey: "approvedEvidencePolicyVersion")
        suite.judgeConfiguration = try CanonicalJSON.decode(EvaluationJudgeConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!suite.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: connection))
        suite.judgeConfiguration.approvedEvidencePolicyVersion = EvaluationJudgeConfiguration.currentEvidencePolicyVersion
        #expect(suite.judgeConfiguration.hasCurrentExternalEvidenceApproval(for: connection))
    }

    @Test func mcpCannotMintTheExpandedEvidenceApproval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        try MCPWorkspaceControl.requireServerApproval(store.suite.judgeConfiguration, store: store)
        var forged = store.suite.judgeConfiguration
        forged.approvedEvidencePolicyVersion = EvaluationJudgeConfiguration.currentEvidencePolicyVersion
        #expect(throws: EvaluationStoreError.self) {
            try MCPWorkspaceControl.requireServerApproval(forged, store: store)
        }
    }

    @Test(arguments: [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier])
    func mediaTypeUsesBytesDespiteMissingOrMisleadingExtension(identifier: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reference.image")
        let bytes = try image(identifier: identifier)
        try bytes.write(to: url)
        var (suite, connection) = fixture()
        suite.judgeConfiguration.includeReferenceAttachments = true
        suite.judgeConfiguration.approvedIncludeReferenceAttachments = true
        connection.capabilities.multimodal = true
        suite.judgeConfiguration.approvedConnectionDigest = connection.disclosureDigest
        let transport = ObservedContextTransport(responses: [try completion()])
        let client = EvaluationCompatibleJudgeClient(transport: { try await transport.send($0) })
        _ = try await client.judge(response: "483", evaluationCase: suite.cases[0], effectivePrompt: "Which order?", suite: suite,
            images: [.init(label: "Reference", url: url)], toolEvidence: nil, resolved: .init(connection: connection, apiKey: nil))
        let body = try #require(await transport.bodies().first)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        let imagePart = try #require(parts.last?["image_url"] as? [String: String])
        let mime = try #require(UTType(identifier)?.preferredMIMEType)
        #expect(imagePart["url"] == "data:\(mime);base64,\(bytes.base64EncodedString())")
    }

    @Test func malformedImageBytesNeverReachTransport() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var (suite, connection) = fixture()
        connection.capabilities.multimodal = true
        suite.judgeConfiguration.includeReferenceAttachments = true
        suite.judgeConfiguration.approvedIncludeReferenceAttachments = true
        suite.judgeConfiguration.approvedConnectionDigest = connection.disclosureDigest
        let transport = ObservedContextTransport(responses: [])
        let client = EvaluationCompatibleJudgeClient(transport: { try await transport.send($0) })
        await #expect(throws: (any Error).self) {
            _ = try await client.judge(response: "483", evaluationCase: suite.cases[0], effectivePrompt: "Which order?", suite: suite,
                images: [.init(label: "Reference", url: url)], toolEvidence: nil, resolved: .init(connection: connection, apiKey: nil))
        }
        #expect(await transport.bodies().isEmpty)
    }

    private func fixture() -> (EvaluationSuite, EvaluationJudgeConnection) {
        let connection = EvaluationJudgeConnection(id: UUID(), name: "Fixture", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1/v1", modelID: "fixture")
        var suite = EvaluationSuite()
        suite.scoringMode = .modelJudge
        suite.criteria = "Correctly summarizes the observed customer request."
        suite.cases = [.init(name: "Order", prompt: "Which order?", expected: "")]
        suite.judgeConfiguration = .init(mode: .connection, connectionID: connection.id, externalEvidenceApprovedAt: Date(),
            includeReferenceAttachments: false, approvedConnectionID: connection.id, approvedIncludeReferenceAttachments: false,
            approvedConnectionDigest: connection.disclosureDigest,
            approvedEvidencePolicyVersion: EvaluationJudgeConfiguration.currentEvidencePolicyVersion)
        return (suite, connection)
    }

    private func sample(suite: EvaluationSuite, context: EvaluationJudgeSubjectContext?) -> EvaluationSampleResult {
        .init(caseID: suite.cases[0].id, caseName: "Order", repetition: 1, prompt: suite.cases[0].prompt,
            effectivePrompt: "Which order?", expected: "", response: "483", status: .unscored, score: nil, rationale: nil,
            durationMilliseconds: 1, usage: .init(), judgeDurationMilliseconds: nil, judgeUsage: nil,
            errorCategory: nil, errorMessage: nil, judgeErrorCategory: nil, judgeErrorMessage: nil, judgeSubjectContext: context)
    }

    private func turn(_ prompt: String, _ response: String) -> [Transcript.Entry] {
        [.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])),
         .response(Transcript.Response(metadata: [:], segments: [.text(Transcript.TextSegment(content: response))]))]
    }

    private func completion() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "{\"requirements\":[{\"criterionIndex\":1,\"score\":4,\"rationale\":\"Correct order.\"}]}"], "finish_reason": "stop"]]])
    }

    private func userPrompt(_ body: Data) throws -> String {
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        return try #require(messages[1]["content"] as? String)
    }

    private func image(identifier: String) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
}

private actor ObservedContextTransport {
    var responses: [Data]
    var requests: [Data] = []
    init(responses: [Data]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request.httpBody ?? Data())
        guard !responses.isEmpty, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (responses.removeFirst(), response)
    }
    func bodies() -> [Data] { requests }
}

private struct ObservedContextTokenCounter: EvaluationPromptInputTokenCounting {
    func tokenCount(for prompt: Prompt) async throws -> Int { String(describing: prompt).utf8.count }
    func tokenCount(for instructions: Instructions) async throws -> Int { 0 }
    func tokenCount(for schema: GenerationSchema) async throws -> Int { 0 }
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int { 0 }
    func tokenCount(for tools: [any Tool]) async throws -> Int { 0 }
    func tokenCount(forText text: String) async throws -> Int { text.utf8.count }
}


private struct ObservedContextModel: LanguageModel {
    typealias Executor = ObservedContextExecutor
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration]) }
    var executorConfiguration: Bool { false }
    var contextSize: Int { 131_072 }
}

private struct ObservedContextExecutor: LanguageModelExecutor {
    typealias Model = ObservedContextModel
    typealias Configuration = Bool
    init(configuration: Bool) throws {}
    func prewarm(model: Model, transcript: Transcript) {}
    func respond(to request: LanguageModelExecutorGenerationRequest, model: Model,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let role = request.metadata["role"].flatMap {
            try? JSONDecoder().decode(String.self, from: Data($0.jsonString.utf8))
        }
        let content: String
        if request.schema != nil {
            content = "{\"requirement1\":{\"score\":4,\"rationale\":\"Correctly cancels order 483.\"}}"
        } else {
            content = role == "setup" ? "Generated acknowledgement: cancel 483" : "483"
        }
        await channel.send(.response(action: .appendText(content, tokenCount: 8)))
    }
}


private struct AdmissionMustNotExecuteModel: LanguageModel {
    typealias Executor = AdmissionMustNotExecuteExecutor
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration, .toolCalling]) }
    var executorConfiguration: Bool { false }
}

private struct AdmissionMustNotExecuteExecutor: LanguageModelExecutor {
    typealias Model = AdmissionMustNotExecuteModel
    typealias Configuration = Bool
    init(configuration: Bool) throws {}
    func prewarm(model: Model, transcript: Transcript) {}
    func respond(to request: LanguageModelExecutorGenerationRequest, model: Model,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        Issue.record("Profile evidence byte admission invoked the subject executor")
        throw UnexpectedExecution()
    }
    private struct UnexpectedExecution: Error {}
}


private struct ObservedToolModel: LanguageModel {
    typealias Executor = ObservedToolExecutor
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration, .toolCalling]) }
    var executorConfiguration: Bool { false }
}
private struct ObservedToolExecutor: LanguageModelExecutor {
    typealias Model = ObservedToolModel
    typealias Configuration = Bool
    init(configuration: Bool) throws {}
    func prewarm(model: Model, transcript: Transcript) {}
    func respond(to request: LanguageModelExecutorGenerationRequest, model: Model,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let hasOutput = request.transcript.history.contains { entry in
            if case .toolOutput = entry { true } else { false }
        }
        if hasOutput {
            await channel.send(.response(action: .appendText("483", tokenCount: 1)))
        } else {
            await channel.send(.toolCalls(action: .toolCall(id: "order-call", name: "lookup_order",
                action: .appendArguments("{\"order\":\"483\"}", tokenCount: 5))))
        }
    }
}
