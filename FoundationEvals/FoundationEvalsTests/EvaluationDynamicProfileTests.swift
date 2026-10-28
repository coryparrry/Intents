import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

struct EvaluationDynamicProfileTests {
    /// Observes fresh and restored profile phases for streamed and ordinary generation, including inherited global defaults.
    @Test(arguments: [(false, false, false), (false, false, true), (false, true, false), (false, true, true),
                      (true, false, false), (true, false, true), (true, true, false), (true, true, true)])
    func profileOwnsGenerationOptionsAndInheritsGlobalDefaults(streaming: Bool, inheritDefaults: Bool,
                                                             restoredToolHistory: Bool) async throws {
        var suite = EvaluationSuite()
        suite.features.streamResponse = streaming
        suite.features.profile.enabled = true
        suite.features.profile.requireToolFirst = true
        suite.modelConfiguration.maximumResponseTokens = 512
        suite.modelConfiguration.samplingMode = .greedy
        suite.modelConfiguration.temperatureEnabled = true
        suite.modelConfiguration.temperature = 0.2
        suite.modelConfiguration.reasoningLevel = .moderate
        if !inheritDefaults {
            suite.features.profile.afterToolSamplingMode = .topK
            suite.features.profile.afterToolTopK = 7
            suite.features.profile.afterToolSeedEnabled = true
            suite.features.profile.afterToolSeed = 8
            suite.features.profile.afterToolTemperatureEnabled = true
            suite.features.profile.afterToolTemperature = 0.7
            suite.features.profile.afterToolMaximumResponseTokens = 1_024
            suite.features.profile.afterToolReasoningLevel = .deep
        }
        let recorder = ProfileOptionsFixtureRecorder()
        let history: [Transcript.Entry] = restoredToolHistory ? [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "Synthetic setup"))])),
            .toolCalls(Transcript.ToolCalls([Transcript.ToolCall(id: "restored-profile-call", toolName: "profile_fixture",
                arguments: GeneratedContent(properties: [:]))])),
            .toolOutput(Transcript.ToolOutput(id: "restored-profile-call", toolName: "profile_fixture",
                segments: [.text(Transcript.TextSegment(content: "Synthetic restored result"))])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "Ready"))]))
        ] : []
        let session = EvaluationDynamicProfile.makeSession(model: ProfileOptionsFixtureModel(recorder: recorder),
            instructions: "Synthetic instructions", tools: [try ProfileOptionsFixtureTool()],
            configuration: suite.features.profile, recorder: EvaluationProfileRecorder(),
            modelConfiguration: suite.modelConfiguration, history: history)
        _ = try await EvaluationFeatureResponse.generate(session: session, prompt: Prompt("Synthetic input"),
            suite: suite, metadata: [:])

        let requests = await recorder.snapshot()
        #expect(requests.count == (restoredToolHistory ? 1 : 2))
        let initial = try #require(requests.first)
        let afterTool = try #require(requests.last)
        #expect(initial.afterTool == restoredToolHistory && afterTool.afterTool)
        if !restoredToolHistory {
            #expect(initial.options.maximumResponseTokens == 512)
            #expect(initial.options.temperature == 0.2)
            #expect(initial.options.samplingMode == .greedy)
            #expect(initial.context.reasoningLevel == .moderate)
        }
        #expect(afterTool.options.maximumResponseTokens == (inheritDefaults ? 512 : 1_024))
        #expect(afterTool.options.temperature == (inheritDefaults ? 0.2 : 0.7))
        #expect(afterTool.options.samplingMode == (inheritDefaults ? .greedy : .random(top: 7, seed: 8)))
        #expect(afterTool.context.reasoningLevel == (inheritDefaults ? .moderate : .deep))
    }

    @Test func afterToolOverridesMapToFoundationModelsModifiers() {
        let configuration = EvaluationProfileConfiguration(
            afterToolSamplingMode: .topK,
            afterToolTemperatureEnabled: true,
            afterToolTemperature: 0.35,
            afterToolSeedEnabled: true,
            afterToolSeed: 17,
            afterToolTopK: 25,
            afterToolMaximumResponseTokens: 512,
            afterToolReasoningLevel: .deep,
            afterToolTranscriptErrorPolicy: .preserve
        )

        #expect(configuration.resolvedAfterToolSamplingMode == .random(top: 25, seed: 17))
        #expect(configuration.resolvedAfterToolTemperature == 0.35)
        #expect(configuration.afterToolMaximumResponseTokens == 512)
        #expect(configuration.resolvedAfterToolReasoningLevel == .deep)
        #expect(configuration.afterToolTranscriptErrorPolicy == .preserve)
    }

    @Test func legacyProfileDecodingUsesOverrideDefaults() throws {
        let json = #"""
        {
            "enabled": true,
            "name": "Lookup first",
            "afterToolInstructions": "Summarize the result.",
            "requireToolFirst": true
        }
        """#

        let decoded = try JSONDecoder().decode(
            EvaluationProfileConfiguration.self,
            from: Data(json.utf8)
        )

        #expect(decoded.enabled)
        #expect(decoded.name == "Lookup first")
        #expect(decoded.afterToolInstructions == "Summarize the result.")
        #expect(decoded.requireToolFirst)
        #expect(decoded.afterToolSamplingMode == .automatic)
        #expect(!decoded.afterToolTemperatureEnabled)
        #expect(decoded.afterToolMaximumResponseTokens == nil)
        #expect(decoded.afterToolReasoningLevel == .automatic)
        #expect(decoded.afterToolTranscriptErrorPolicy == .automatic)
    }

    @Test func profileOverridesRoundTrip() throws {
        let configuration = EvaluationProfileConfiguration(
            enabled: true,
            name: "Lookup first",
            afterToolInstructions: "Use the tool evidence.",
            requireToolFirst: true,
            afterToolSamplingMode: .probability,
            afterToolTemperatureEnabled: true,
            afterToolTemperature: 0.2,
            afterToolSeedEnabled: true,
            afterToolSeed: 99,
            afterToolProbabilityThreshold: 0.75,
            afterToolMaximumResponseTokens: 1_024,
            afterToolReasoningLevel: .custom,
            afterToolCustomReasoning: "analysis-heavy",
            afterToolTranscriptErrorPolicy: .revert
        )

        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(EvaluationProfileConfiguration.self, from: data) == configuration)
    }

    @Test func invalidAfterToolOverridesAreRejected() {
        var configuration = EvaluationProfileConfiguration(enabled: true)
        configuration.afterToolTemperatureEnabled = true
        configuration.afterToolTemperature = 1.1
        #expect(configuration.validationIssue == "After-tool temperature must be between 0 and 1.")

        configuration.afterToolTemperature = 0.5
        configuration.afterToolMaximumResponseTokens = 64
        #expect(configuration.validationIssue == "After-tool response length must be between 128 and 4,096 tokens.")

        configuration.afterToolMaximumResponseTokens = nil
        configuration.afterToolReasoningLevel = .custom
        #expect(configuration.validationIssue == "Add a custom after-tool reasoning value.")
    }

    @MainActor
    @Test func inactiveProfileOverridesDoNotBlockSavingAnUnloadedProvider() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var suite = EvaluationSuite()
        suite.scoringMode = .review
        suite.modelConfiguration.provider = .coreAI
        suite.features.profile.requireToolFirst = true
        suite.features.profile.afterToolReasoningLevel = .custom
        suite.features.profile.afterToolTemperatureEnabled = true
        suite.features.profile.afterToolTemperature = -1
        suite.features.profile.afterToolMaximumResponseTokens = 64

        #expect(store.validationIssue(for: suite, includeModelReadiness: false) == nil)
        store.draftSuite = suite
        #expect(store.saveSuite())
    }

    @MainActor
    @Test func activeProfileReasoningRequiresDeclaredModelSupport() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var suite = EvaluationSuite()
        suite.scoringMode = .review
        suite.modelConfiguration.provider = .customHTTP
        suite.features.profile.enabled = true
        suite.features.profile.afterToolReasoningLevel = .deep

        #expect(
            store.validationIssue(for: suite, includeModelReadiness: false)
                == "The selected model does not support explicit reasoning levels in the active profile. Choose Automatic."
        )

        suite.modelConfiguration.customProviderSettings.supportsReasoning = true
        #expect(store.validationIssue(for: suite, includeModelReadiness: false) == nil)
    }
}

private actor ProfileOptionsFixtureRecorder {
    struct Request: Sendable {
        var afterTool: Bool
        var options: GenerationOptions
        var context: ContextOptions
    }
    private var requests: [Request] = []
    /// Retains only synthetic generation settings observed by the injected executor.
    func record(_ request: Request) { requests.append(request) }
    /// Returns every observed request in generation order.
    func snapshot() -> [Request] { requests }
}

private struct ProfileOptionsFixtureModel: LanguageModel {
    typealias Executor = ProfileOptionsFixtureExecutor
    let recorder: ProfileOptionsFixtureRecorder
    var capabilities: LanguageModelCapabilities { .init([.toolCalling, .guidedGeneration, .reasoning]) }
    var executorConfiguration: Bool { false }
}

private struct ProfileOptionsFixtureExecutor: LanguageModelExecutor {
    typealias Model = ProfileOptionsFixtureModel
    typealias Configuration = Bool
    /// Creates an asset-free executor that exercises the real session and profile machinery.
    init(configuration: Bool) throws {}
    /// Performs no work because the fixture has no model assets.
    func prewarm(model: Model, transcript: Transcript) {}
    /// Requests one synthetic tool, then returns text after recording the effective options for each phase.
    func respond(to request: LanguageModelExecutorGenerationRequest, model: Model,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let afterTool = request.transcript.history.contains { entry in
            if case .toolOutput = entry { true } else { false }
        }
        await model.recorder.record(.init(afterTool: afterTool, options: request.generationOptions,
            context: request.contextOptions))
        if afterTool {
            await channel.send(.response(action: .appendText("Synthetic output", tokenCount: 2)))
        } else {
            await channel.send(.toolCalls(action: .toolCall(id: "profile-fixture-call", name: "profile_fixture",
                action: .appendArguments("{}", tokenCount: 1))))
        }
    }
}

private struct ProfileOptionsFixtureTool: Tool {
    let name = "profile_fixture"
    let description = "Return synthetic data"
    let parameters: GenerationSchema
    /// Builds the empty argument object without invoking generation macros or model resources.
    init() throws {
        parameters = try GenerationSchema(root: DynamicGenerationSchema(name: "ProfileFixtureArguments", properties: []), dependencies: [])
    }
    /// Supplies a fixed tool response so the dynamic profile transitions before the second request.
    func call(arguments: GeneratedContent) async throws -> String { "Synthetic tool output" }
}
