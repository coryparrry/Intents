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

    @Test(arguments: ["profileAllows", "profileInactive", "profileRequires", "profileRequiresWithTool"])
    @MainActor
    func activeProfileOverridesLegacyRequiredToolPolicy(mode: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let originalCanonical = store.suite
        store.draftSuite.scoringMode = .review
        store.draftSuite.modelConfiguration.provider = .customHTTP
        store.draftSuite.modelConfiguration.referenceMode = .inline
        store.draftSuite.modelConfiguration.customProviderSettings.supportsToolCalling = true
        store.draftSuite.modelConfiguration.customizationSettings.toolCalling = .required
        store.draftSuite.features.profile.enabled = mode != "profileInactive"
        store.draftSuite.features.profile.requireToolFirst = mode == "profileRequires" || mode == "profileRequiresWithTool"
        if mode == "profileRequiresWithTool" {
            store.draftSuite.modelConfiguration.referenceMode = .lookupTool
            store.draftSuite.attachments = [.init(
                id: UUID(), name: "Reference.txt", kind: .text, text: "Fixture reference",
                storedFilename: nil, byteCount: 17, sha256: "fixture"
            )]
        }
        let expectedIssue: String?
        switch mode {
        case "profileInactive": expectedIssue = "Required tool calling needs at least one enabled tool."
        case "profileRequires": expectedIssue = "A profile that requires a tool call must enable at least one tool."
        default: expectedIssue = nil
        }
        #expect(store.draftSuite.hasConfiguredTools == (mode == "profileRequiresWithTool"))
        #expect(store.validationIssue(for: store.draftSuite, includeModelReadiness: false) == expectedIssue)
        let candidate = store.draftSuite
        #expect(store.saveSuite() == (expectedIssue == nil))
        if expectedIssue == nil { #expect(store.suite == candidate) }
        else { #expect(store.suite == originalCanonical) }
        #expect(!store.draftSaveFailed)
        await store.closeAndWait()

        let restored = EvaluationStore(supportDirectory: directory)
        #expect(restored.draftSuite == candidate)
        #expect(restored.validationIssue(for: restored.draftSuite, includeModelReadiness: false) == expectedIssue)
        if expectedIssue == nil { #expect(restored.suite == candidate) }
        else { #expect(restored.suite == originalCanonical) }
        await restored.closeAndWait()
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
        suite.features.spotlightSearch.fileSource.folderPath = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents/FoundationEvalsSpotlightFixture").path
        #expect(store.validationIssue(for: suite, includeModelReadiness: false) == "The selected model does not support tool calling.")
        suite.modelConfiguration.customProviderSettings.supportsToolCalling = true
        #expect(store.validationIssue(for: suite, includeModelReadiness: false) == nil)
    }
}
