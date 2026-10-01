import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

struct EvaluationConversationTests {
    @Test func legacyCaseDecodingUsesSingleTurnDefaults() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","prompt":"Hello","expected":"Hi"}"#
        let evaluationCase = try JSONDecoder().decode(EvaluationCase.self, from: Data(json.utf8))

        #expect(evaluationCase.conversation == EvaluationConversationConfiguration())
        #expect(evaluationCase.conversation.modelHistoryProjection == nil)
    }

    @Test func conversationConfigurationRoundTrips() throws {
        let configuration = EvaluationConversationConfiguration(
            setupTurns: [EvaluationSetupTurn(prompt: "Remember the code word: amber.")],
            restoredTranscriptJSON: #"{"entries":[]}"#,
            historyPolicy: .retainRecentCompleteTurns,
            retainedTurnCount: 1,
            modelHistoryProjection: EvaluationModelHistoryProjection(
                policy: .reset,
                retainedTurnCount: 2
            )
        )
        let evaluationCase = EvaluationCase(
            name: "Recall",
            prompt: "What is the code word?",
            expected: "amber",
            conversation: configuration
        )

        let data = try JSONEncoder().encode(evaluationCase)
        #expect(try JSONDecoder().decode(EvaluationCase.self, from: data) == evaluationCase)
    }

    @Test func retainedHistoryKeepsOnlyRecentCompleteTurns() {
        let first = Self.turn(prompt: "one", response: "first")
        let second = Self.turn(prompt: "two", response: "second")
        let incomplete = Self.prompt("unfinished")
        let history = first + second + [incomplete]

        let retained = EvaluationConversationRuntime.retainedHistory(
            history,
            policy: .retainRecentCompleteTurns,
            recentTurnCount: 1
        )

        #expect(retained == second)
        #expect(EvaluationConversationRuntime.retainedHistory(
            history,
            policy: .keepAll,
            recentTurnCount: 1
        ) == history)
        #expect(EvaluationConversationRuntime.retainedHistory(
            history,
            policy: .resetBeforeFinal,
            recentTurnCount: 1
        ).isEmpty)
    }

    @Test func historyPolicyMutatesTheFoundationModelsSessionTranscript() {
        let first = Self.turn(prompt: "one", response: "first")
        let second = Self.turn(prompt: "two", response: "second")
        let session = LanguageModelSession(transcript: Transcript(entries: first + second))
        let configuration = EvaluationConversationConfiguration(
            historyPolicy: .retainRecentCompleteTurns,
            retainedTurnCount: 1
        )

        let counts = EvaluationConversationRuntime.applyHistoryPolicy(configuration, to: session)

        #expect(counts.before == 4)
        #expect(counts.after == 2)
        #expect(Array(session.transcript.history) == second)
    }

    @Test func modelHistoryProjectionKeepsStoredTranscriptIntact() {
        let first = Self.turn(prompt: "one", response: "first")
        let second = Self.turn(prompt: "two", response: "second")
        let history = first + second
        let activePrompt = [Self.prompt("current request")]
        let projection = EvaluationModelHistoryProjection(
            policy: .retainRecentCompleteTurns,
            retainedTurnCount: 1
        )

        #expect(EvaluationConversationRuntime.projectedHistory(history, using: projection) == second)
        #expect(EvaluationConversationRuntime.projectedHistory(
            history + activePrompt,
            using: projection
        ) == second + activePrompt)
        #expect(EvaluationConversationRuntime.projectedHistory(
            history,
            using: EvaluationModelHistoryProjection(policy: .reset)
        ).isEmpty)
        #expect(EvaluationConversationRuntime.projectedHistory(
            history + activePrompt,
            using: EvaluationModelHistoryProjection(policy: .reset)
        ) == activePrompt)

        let session = EvaluationConversationRuntime.makeSession(
            model: SystemLanguageModel.default,
            tools: [],
            instructions: "",
            history: history,
            modelHistoryProjection: projection
        )
        #expect(Array(session.transcript.history) == history)
    }

    @Test func profileSessionReceivesRestoredHistory() {
        let history = Self.turn(prompt: "Remember amber", response: "I will remember amber")
        let session = EvaluationDynamicProfile.makeSession(
            model: SystemLanguageModel.default,
            instructions: "Answer briefly.",
            tools: [],
            configuration: EvaluationProfileConfiguration(enabled: true),
            recorder: EvaluationProfileRecorder(),
            history: history
        )

        #expect(Array(session.transcript.history) == history)
    }

    @Test func transcriptCodecAcceptsRawAndCapturedExports() throws {
        let transcript = Transcript(entries: Self.turn(prompt: "hello", response: "hi"))
        let raw = try #require(String(data: JSONEncoder().encode(transcript), encoding: .utf8))
        #expect(try EvaluationConversationTranscriptCodec.decode(raw) == transcript)

        let trace = EvaluationTranscriptTrace.capture(transcript, outcome: .success)
        let wrapped = try #require(String(data: JSONEncoder().encode(trace), encoding: .utf8))
        #expect(try EvaluationConversationTranscriptCodec.decode(wrapped) == transcript)
    }

    @MainActor
    @Test func storeRejectsInvalidConversationConfiguration() {
        let store = EvaluationStore(
            supportDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        store.draftSuite.cases[0].conversation.restoredTranscriptJSON = "not json"
        #expect(store.runBlocker == "Restored transcript JSON must be a Foundation Models transcript export.")

        store.draftSuite.cases[0].conversation = EvaluationConversationConfiguration(
            setupTurns: [EvaluationSetupTurn(prompt: "")]
        )
        #expect(store.runBlocker == "Every setup turn needs a prompt.")
    }

    @Test func mcpReplaceSuiteParsesConversationAndKeepsLegacyCasesCompatible() throws {
        var declaration = Self.mcpSuite()
        declaration.cases[0].conversation = EvaluationConversationConfiguration(
            setupTurns: [EvaluationSetupTurn(prompt: "Remember amber.")],
            historyPolicy: .resetBeforeFinal,
            modelHistoryProjection: EvaluationModelHistoryProjection(
                policy: .retainRecentCompleteTurns,
                retainedTurnCount: 1
            )
        )
        let call = try MCPToolCatalog.parse(
            name: "eval_replace_suite",
            arguments: try Self.json(MCPReplaceSuiteArguments(
                expectedRevision: "revision",
                confirmDeletes: false,
                suite: declaration
            ))
        )
        guard case .replaceSuite(let parsed) = call else {
            Issue.record("Expected replace suite call")
            return
        }
        #expect(parsed.suite.cases[0].conversation == declaration.cases[0].conversation)

        declaration.cases[0].conversation = nil
        let legacyCall = try MCPToolCatalog.parse(
            name: "eval_replace_suite",
            arguments: try Self.json(MCPReplaceSuiteArguments(
                expectedRevision: "revision",
                confirmDeletes: false,
                suite: declaration
            ))
        )
        guard case .replaceSuite(let legacy) = legacyCall else {
            Issue.record("Expected legacy replace suite call")
            return
        }
        #expect(legacy.suite.cases[0].conversation == nil)
    }

    @MainActor
    @Test func mcpStateReportsModelHistoryProjection() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var declaration = Self.mcpSuite()
        declaration.cases[0].conversation = EvaluationConversationConfiguration(
            modelHistoryProjection: EvaluationModelHistoryProjection(
                policy: .retainRecentCompleteTurns,
                retainedTurnCount: 1
            )
        )
        let authority = MCPStoreAuthority.make(store: store)

        let replacement = await authority.call(.replaceSuite(MCPReplaceSuiteArguments(
            expectedRevision: store.suiteRevision,
            confirmDeletes: true,
            suite: declaration
        )))
        #expect(!replacement.isError)

        let state = await authority.call(.getState).structuredContent.objectValue
        let casesValue = try #require(state?["suite"]?.objectValue?["cases"])
        guard case .array(let cases) = casesValue else {
            Issue.record("Expected a canonical case array")
            return
        }
        let projection = cases.first?.objectValue?["conversation"]?.objectValue?["modelHistoryProjection"]?.objectValue
        #expect(projection?["policy"] == .string(EvaluationModelHistoryProjectionPolicy.retainRecentCompleteTurns.rawValue))
        #expect(projection?["retainedTurnCount"] == .integer(1))
    }

    private static func turn(prompt: String, response: String) -> [Transcript.Entry] {
        [Self.prompt(prompt), Self.response(response)]
    }

    private static func prompt(_ text: String) -> Transcript.Entry {
        .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))]))
    }

    private static func response(_ text: String) -> Transcript.Entry {
        .response(Transcript.Response(metadata: [:], segments: [.text(Transcript.TextSegment(content: text))]))
    }

    private static func mcpSuite() -> MCPSuiteDeclaration {
        MCPSuiteDeclaration(
            name: "Conversation",
            version: "v1",
            instructions: "Answer briefly.",
            scoringMode: .review,
            repetitions: 1,
            rubricRequirements: ["Answer the prompt."],
            modelConfiguration: MCPModelConfiguration(
                samplingMode: .automatic,
                temperatureEnabled: false,
                temperature: 0.7,
                seedEnabled: false,
                seed: 42,
                topK: 40,
                probabilityThreshold: 0.9,
                maximumResponseTokens: 1_024,
                maximumInputTokens: nil,
                referenceMode: .inline,
                contextPolicy: .fitReferences,
                maximumToolCalls: 2
            ),
            cases: [MCPCaseDeclaration(
                id: UUID(),
                name: "Recall",
                prompt: "What is the code word?",
                expected: ""
            )]
        )
    }

    private static func json<T: Encodable>(_ value: T) throws -> MCPJSONValue {
        try JSONDecoder().decode(MCPJSONValue.self, from: JSONEncoder().encode(value))
    }
}
