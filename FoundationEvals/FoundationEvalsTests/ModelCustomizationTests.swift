import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

struct ModelCustomizationTests {
    @Test func legacyModelConfigurationPreservesExistingBehavior() throws {
        let data = try JSONEncoder().encode(EvaluationModelConfiguration())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "customization")
        let restored = try JSONDecoder().decode(
            EvaluationModelConfiguration.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(restored.customizationSettings == EvaluationModelCustomization())
        #expect(restored.contextOptions.includeSchemaInPrompt == true)
        #expect(restored.toolCallingMode(hasTools: false) == .disallowed)
        #expect(restored.toolCallingMode(hasTools: true) == .allowed)
    }

    @Test func customizedModelOptionsSurvivePersistence() throws {
        var configuration = EvaluationModelConfiguration()
        configuration.customizationSettings.useCase = .contentTagging
        configuration.customizationSettings.guardrails = .permissiveContentTransformations
        configuration.customizationSettings.schemaPrompt = .omitted
        configuration.customizationSettings.toolCalling = .required
        let decoded = try JSONDecoder().decode(
            EvaluationModelConfiguration.self, from: JSONEncoder().encode(configuration)
        )
        #expect(decoded == configuration)
        #expect(decoded.contextOptions.includeSchemaInPrompt == false)
        #expect(decoded.toolCallingMode(hasTools: true) == .required)
    }

    @Test func explicitToolPoliciesDoNotDependOnAvailableDefinitions() {
        var configuration = EvaluationModelConfiguration()
        configuration.customizationSettings.toolCalling = .disallowed
        #expect(configuration.toolCallingMode(hasTools: true) == .disallowed)
        configuration.customizationSettings.toolCalling = .allowed
        #expect(configuration.toolCallingMode(hasTools: false) == .allowed)
        configuration.customizationSettings.schemaPrompt = .automatic
        #expect(configuration.contextOptions.includeSchemaInPrompt == nil)
    }

    @Test @MainActor func requiredToolPolicyRejectsSuiteWithNoTool() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var suite = EvaluationSuite()
        suite.modelConfiguration.customizationSettings.toolCalling = .required
        #expect(store.validationIssue(for: suite, includeModelReadiness: false)?.contains("needs at least one") == true)
    }

    @Test @MainActor func unloadedCoreAICanBeSavedButCannotRun() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.modelConfiguration.provider = .coreAI
        #expect(store.saveSuite())
        let restored = EvaluationStore(supportDirectory: directory)
        #expect(restored.suite.modelConfiguration.provider == .coreAI)
        #expect(restored.validationIssue(for: restored.suite)?.contains("load") == true)
    }

    @Test @MainActor func spotlightRequiresDeclaredToolCapability() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var suite = EvaluationSuite()
        suite.scoringMode = .review
        suite.modelConfiguration.provider = .customHTTP
        suite.features.spotlightSearch.enabled = true
        suite.features.spotlightSearch.fileSource.enabled = true
        suite.features.spotlightSearch.fileSource.folderPath = directory.path
        #expect(store.validationIssue(for: suite, includeModelReadiness: false) == "The selected model does not support tool calling.")
        suite.modelConfiguration.customProviderSettings.supportsToolCalling = true
        #expect(store.validationIssue(for: suite, includeModelReadiness: false) == nil)
    }
}
