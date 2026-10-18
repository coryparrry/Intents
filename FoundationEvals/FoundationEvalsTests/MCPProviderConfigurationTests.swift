import Foundation
import Testing
@testable import FoundationEvals

struct MCPProviderConfigurationTests {
    @MainActor
    @Test(arguments: EvaluationModelProvider.allCases)
    func everyProviderSelectionRoundTrips(_ provider: EvaluationModelProvider) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let authority = MCPStoreAuthority.make(store: store)
        var replacement = suiteDeclaration(from: store.suite)
        replacement.name = "Provider \(provider.rawValue)"
        replacement.scoringMode = .review
        replacement.modelConfiguration.provider = provider

        let result = await authority.call(.replaceSuite(.init(
            expectedRevision: store.suiteRevision,
            confirmDeletes: false,
            suite: replacement
        )))

        #expect(!result.isError)
        #expect(store.suite.modelConfiguration.provider == provider)
        let state = try #require(
            (await authority.call(.getState)).structuredContent.objectValue?["suite"]
        )
        #expect(
            state.objectValue?["modelConfiguration"]?.objectValue?["provider"]
                == .string(provider.rawValue)
        )
    }

    @MainActor
    @Test func customHTTPConfigurationRoundTripsAndLegacyInputPreservesIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let authority = MCPStoreAuthority.make(store: store)
        let customProvider = EvaluationCustomProviderConfiguration(
            endpoint: "http://127.0.0.1:19097/v1/generate",
            tokenizerEndpoint: "http://127.0.0.1:19097/v1/tokenize",
            contextSize: 32_768,
            supportsVision: true,
            supportsGuidedGeneration: true,
            supportsReasoning: true,
            supportsToolCalling: true,
            requestTimeoutSeconds: 12.5
        )
        var replacement = suiteDeclaration(from: store.suite)
        replacement.modelConfiguration.provider = .customHTTP
        replacement.modelConfiguration.customProvider = MCPCustomProviderConfiguration(customProvider)
        var customization = EvaluationModelCustomization()
        customization.useCase = .contentTagging
        replacement.modelConfiguration.customization = customization

        let committed = await authority.call(.replaceSuite(.init(
            expectedRevision: store.suiteRevision,
            confirmDeletes: false,
            suite: replacement
        )))

        #expect(!committed.isError)
        #expect(store.suite.modelConfiguration.provider == .customHTTP)
        #expect(store.suite.modelConfiguration.customProvider == customProvider)

        let state = try #require(
            (await authority.call(.getState)).structuredContent.objectValue?["suite"]
        )
        let model = try #require(state.objectValue?["modelConfiguration"]?.objectValue)
        let custom = try #require(model["customProvider"]?.objectValue)
        let reportedCustomization = try #require(model["customization"]?.objectValue)
        #expect(model["provider"] == .string("customHTTP"))
        #expect(custom["endpoint"] == .string(customProvider.endpoint))
        #expect(custom["tokenizerEndpoint"] == .string(customProvider.tokenizerEndpoint!))
        #expect(custom["contextSize"] == .integer(32_768))
        #expect(custom["capabilities"] == .array([
            .string("vision"),
            .string("guidedGeneration"),
            .string("reasoning"),
            .string("toolCalling")
        ]))
        #expect(custom["requestTimeoutSeconds"] == .number(12.5))
        #expect(reportedCustomization["useCase"] == .string("contentTagging"))
        #expect(reportedCustomization["customReasoning"] == nil)
        #expect(reportedCustomization["visionTools"] == nil)

        let reportedSuite = try state.decode(MCPSuiteDeclaration.self)
        let replayed = await authority.call(.replaceSuite(.init(
            expectedRevision: store.suiteRevision,
            confirmDeletes: false,
            suite: reportedSuite
        )))
        #expect(outcome(replayed) == "duplicate")

        var legacy = suiteDeclaration(from: store.suite)
        legacy.name = "Legacy client update"
        legacy.modelConfiguration.provider = nil
        legacy.modelConfiguration.customProvider = nil
        legacy.modelConfiguration.coreAI = nil
        let legacyResult = await authority.call(.replaceSuite(.init(
            expectedRevision: store.suiteRevision,
            confirmDeletes: false,
            suite: legacy
        )))
        #expect(outcome(legacyResult) == "committed")
        #expect(store.suite.modelConfiguration.provider == .customHTTP)
        #expect(store.suite.modelConfiguration.customProvider == customProvider)
    }

    @MainActor
    @Test func coreAIPathAndBookmarkRoundTripThroughState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let authority = MCPStoreAuthority.make(store: store)
        let coreAI = EvaluationCoreAIConfiguration(
            resourcesPath: "/Models/Fixture.coreai",
            resourcesBookmark: Data([0, 1, 2, 253, 254, 255])
        )
        var replacement = suiteDeclaration(from: store.suite)
        replacement.modelConfiguration.provider = .coreAI
        replacement.modelConfiguration.coreAI = MCPCoreAIConfiguration(coreAI)

        let committed = await authority.call(.replaceSuite(.init(
            expectedRevision: store.suiteRevision,
            confirmDeletes: false,
            suite: replacement
        )))

        #expect(!committed.isError)
        #expect(store.suite.modelConfiguration.provider == .coreAI)
        #expect(store.suite.modelConfiguration.coreAI == coreAI)

        let state = try #require(
            (await authority.call(.getState)).structuredContent.objectValue?["suite"]
        )
        let model = try #require(state.objectValue?["modelConfiguration"]?.objectValue)
        let reportedCoreAI = try #require(model["coreAI"]?.objectValue)
        let bookmark = try #require(coreAI.resourcesBookmark)
        #expect(model["provider"] == .string("coreAI"))
        #expect(reportedCoreAI["resourcesPath"] == .string(coreAI.resourcesPath))
        #expect(reportedCoreAI["resourcesBookmark"] == .string(bookmark.base64EncodedString()))

        let reportedSuite = try state.decode(MCPSuiteDeclaration.self)
        let replayed = await authority.call(.replaceSuite(.init(
            expectedRevision: store.suiteRevision,
            confirmDeletes: false,
            suite: reportedSuite
        )))
        #expect(outcome(replayed) == "duplicate")
    }

    @MainActor
    @Test func partialCustomProviderJSONPreservesTokenizerEndpoint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let tokenizerEndpoint = "http://127.0.0.1:19097/v1/tokenize"
        store.draftSuite.modelConfiguration.provider = .customHTTP
        store.draftSuite.modelConfiguration.customProvider = EvaluationCustomProviderConfiguration(
            endpoint: "http://127.0.0.1:19097/v1/generate",
            tokenizerEndpoint: tokenizerEndpoint,
            contextSize: 32_768,
            supportsGuidedGeneration: true
        )
        #expect(store.saveSuite())

        var declaration = suiteDeclaration(from: store.suite)
        declaration.name = "Partial custom provider update"
        declaration.modelConfiguration.customProvider?.endpoint = "http://127.0.0.1:19098/v1/generate"
        var arguments = try MCPJSONValue.encode(MCPReplaceSuiteArguments(
            expectedRevision: store.suiteRevision,
            confirmDeletes: false,
            suite: declaration
        ))
        var root = try #require(arguments.objectValue)
        var suite = try #require(root["suite"]?.objectValue)
        var model = try #require(suite["modelConfiguration"]?.objectValue)
        var customProvider = try #require(model["customProvider"]?.objectValue)
        customProvider.removeValue(forKey: "tokenizerEndpoint")
        model["customProvider"] = .object(customProvider)
        suite["modelConfiguration"] = .object(model)
        root["suite"] = .object(suite)
        arguments = .object(root)

        #expect(
            arguments.objectValue?["suite"]?.objectValue?["modelConfiguration"]?
                .objectValue?["customProvider"]?.objectValue?["tokenizerEndpoint"] == nil
        )
        let result = await MCPStoreAuthority.make(store: store).call(
            try MCPToolCatalog.parse(name: "eval_replace_suite", arguments: arguments)
        )

        #expect(outcome(result) == "committed")
        #expect(
            store.suite.modelConfiguration.customProvider?.endpoint
                == "http://127.0.0.1:19098/v1/generate"
        )
        #expect(store.suite.modelConfiguration.customProvider?.tokenizerEndpoint == tokenizerEndpoint)
    }

    private func suiteDeclaration(from suite: EvaluationSuite) -> MCPSuiteDeclaration {
        let configuration = suite.modelConfiguration
        return MCPSuiteDeclaration(
            name: suite.name,
            version: suite.version,
            instructions: suite.instructions,
            scoringMode: MCPScoringMode(rawValue: suite.scoringMode.rawValue)!,
            repetitions: suite.repetitions,
            rubricRequirements: suite.rubricCriteria,
            modelConfiguration: MCPModelConfiguration(
                provider: configuration.provider,
                customProvider: configuration.customProvider.map(MCPCustomProviderConfiguration.init),
                coreAI: configuration.coreAI.map(MCPCoreAIConfiguration.init),
                customization: configuration.customization,
                reasoningLevel: configuration.reasoningLevel,
                samplingMode: MCPSamplingMode(rawValue: configuration.samplingMode.rawValue)!,
                temperatureEnabled: configuration.temperatureEnabled,
                temperature: configuration.temperature,
                seedEnabled: configuration.seedEnabled,
                seed: configuration.seed,
                topK: configuration.topK,
                probabilityThreshold: configuration.probabilityThreshold,
                maximumResponseTokens: configuration.maximumResponseTokens,
                maximumInputTokens: configuration.maximumInputTokens,
                referenceMode: MCPReferenceMode(rawValue: configuration.referenceMode.rawValue)!,
                contextPolicy: MCPContextPolicy(rawValue: configuration.contextPolicy.rawValue)!,
                maximumToolCalls: configuration.maximumToolCalls
            ),
            features: suite.features,
            cases: suite.cases.map {
                MCPCaseDeclaration(
                    id: $0.id,
                    name: $0.name,
                    prompt: $0.prompt,
                    expected: $0.expected,
                    conversation: $0.conversation
                )
            }
        )
    }

    private func outcome(_ payload: MCPToolPayload) -> String? {
        payload.structuredContent.objectValue?["outcome"]?.stringValue
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MCPProviderConfigurationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
