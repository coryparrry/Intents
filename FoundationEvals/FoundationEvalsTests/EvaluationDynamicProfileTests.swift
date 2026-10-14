import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

struct EvaluationDynamicProfileTests {
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
