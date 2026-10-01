import Foundation
import FoundationModels
import CoreAILanguageModels
import Testing
@testable import FoundationEvals

struct CoreAIModelLoaderTests {
    @Test func configurationDefaultsAndPersistsResourcePath() throws {
        var configuration = EvaluationCoreAIConfiguration()
        #expect(!configuration.hasResources)

        configuration.resourcesPath = "/Models/Test Model"
        let restored = try JSONDecoder().decode(
            EvaluationCoreAIConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )

        #expect(restored == configuration)
        #expect(restored.hasResources)
    }

    @Test func editingResourcePathInvalidatesBookmark() {
        var configuration = EvaluationCoreAIConfiguration(
            resourcesPath: "/Models/Old",
            resourcesBookmark: Data([1, 2, 3])
        )

        configuration.resourcesPath = "/Models/New"

        #expect(configuration.resourcesBookmark == nil)
    }

    @Test func loaderRejectsEmptyAndMissingResourcePaths() async {
        let loader = CoreAIModelLoader()

        await #expect(throws: CoreAIModelLoadingError.resourcesPathRequired) {
            try await loader.load(configuration: EvaluationCoreAIConfiguration())
        }

        let missingPath = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .path
        await #expect(
            throws: CoreAIModelLoadingError.resourcesFolderUnavailable(missingPath)
        ) {
            try await loader.load(
                configuration: EvaluationCoreAIConfiguration(resourcesPath: missingPath)
            )
        }
    }

    @Test func loaderRejectsAFileInsteadOfAResourceFolder() async throws {
        let directory = try coreAITemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "metadata.json", directoryHint: .notDirectory)
        try Data("{}".utf8).write(to: file)
        let loader = CoreAIModelLoader()

        await #expect(
            throws: CoreAIModelLoadingError.resourcesPathIsNotFolder(file.path)
        ) {
            try await loader.load(
                configuration: EvaluationCoreAIConfiguration(resourcesPath: file.path)
            )
        }
    }

    @Test func malformedResourceFolderSurfacesTheModelLoadingFailure() async throws {
        let directory = try coreAITemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not valid JSON".utf8).write(
            to: directory.appending(path: "metadata.json", directoryHint: .notDirectory)
        )
        let loader = CoreAIModelLoader()

        do {
            _ = try await loader.load(
                configuration: EvaluationCoreAIConfiguration(resourcesPath: directory.path)
            )
            Issue.record("Expected malformed Core AI resources to fail loading")
        } catch let error as CoreAIModelLoadingError {
            guard case .modelLoadFailed(let path, let message) = error else {
                Issue.record("Expected a modelLoadFailed error, got \(error)")
                return
            }
            #expect(URL(fileURLWithPath: path).standardizedFileURL.path == directory.standardizedFileURL.path)
            #expect(!message.isEmpty)
            #expect(error.localizedDescription.contains(directory.path))
        } catch {
            Issue.record("Expected CoreAIModelLoadingError, got \(error)")
        }
    }

    @Test func cancelledCoreAIRunIsNotRecordedAsAModelLoadFailure() async {
        var suite = EvaluationSuite()
        suite.scoringMode = .review
        suite.modelConfiguration.provider = .coreAI

        let task = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            return await EvaluationRunner().run(
                id: UUID(),
                suiteRevision: "test",
                startedAt: Date(),
                suite: suite,
                images: []
            ) { _, _, _ in }
        }
        let run = await task.value

        #expect(run.cancelled)
        #expect(run.terminationReason == "cancelled")
        #expect(run.results.isEmpty)
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["FOUNDATION_EVALS_COREAI_TEST_RESOURCES"]?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            "Set FOUNDATION_EVALS_COREAI_TEST_RESOURCES to a Core AI LanguageBundle folder."
        ),
        .timeLimit(.minutes(2))
    )
    func configuredResourcesLoadAndGenerate() async throws {
        let resourcesPath = try #require(
            ProcessInfo.processInfo.environment["FOUNDATION_EVALS_COREAI_TEST_RESOURCES"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let loader = CoreAIModelLoader()
        let loaded = try await loader.load(
            configuration: EvaluationCoreAIConfiguration(resourcesPath: resourcesPath)
        )

        #expect(!loaded.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(loaded.contextSize > 0)
        #expect((loaded.estimatedSizeOnDiskBytes ?? 0) > 0)

        let reportedCapabilities = loaded.capabilities
        let runtimeCapabilities = loaded.model.capabilities
        for capability: LanguageModelCapabilities.Capability in [
            .vision, .guidedGeneration, .reasoning, .toolCalling,
        ] {
            #expect(reportedCapabilities.contains(capability) == runtimeCapabilities.contains(capability))
        }

        let session = LanguageModelSession(model: loaded.model)
        let response = try await session.respond(
            to: Prompt { "Respond with one short token." },
            options: GenerationOptions(
                samplingMode: .greedy,
                maximumResponseTokens: 8,
                toolCallingMode: .disallowed
            )
        )

        #expect(response.usage.input.totalTokenCount > 0)
        #expect(response.usage.output.totalTokenCount <= 8)
        #expect(
            response.usage.output.reasoningTokenCount
                <= response.usage.output.totalTokenCount
        )

        let postGenerationCapabilities = loaded.model.capabilities
        for capability: LanguageModelCapabilities.Capability in [
            .vision, .guidedGeneration, .reasoning, .toolCalling,
        ] {
            #expect(
                postGenerationCapabilities.contains(capability)
                    == reportedCapabilities.contains(capability)
            )
        }
    }
}

private func coreAITemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
