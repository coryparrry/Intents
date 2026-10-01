import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

struct FeaturePersistenceTests {
    @Test func legacySuitesKeepFeaturesDisabled() throws {
        let suite = try JSONDecoder().decode(EvaluationSuite.self, from: Data("{}".utf8))
        #expect(suite.features == EvaluationFeatureConfiguration())
    }

    @MainActor
    @Test func featureEditsChangeRevisionAndSurviveRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let previous = store.suiteRevision
        store.draftSuite.features.outputFields = [.init(name: "answer", description: "Answer", type: .string)]
        store.draftSuite.features.streamResponse = true
        #expect(store.saveSuite())
        #expect(store.suiteRevision != previous)
        let reopened = EvaluationStore(supportDirectory: directory)
        #expect(reopened.suite.features == store.suite.features)
        #expect(reopened.suiteRevision == store.suiteRevision)
    }

    @Test func customToolOutputsReduceBothSubjectAndJudgeInputBudgets() {
        let configuration = EvaluationModelConfiguration()
        let baseline = configuration.contextAllocation(contextSize: 8_192, includesModelJudge: true)
        let features = configuration.contextAllocation(contextSize: 8_192, includesModelJudge: true,
                                                       customToolOutputReserve: 1_024)
        #expect(features.effectiveInputLimit == baseline.effectiveInputLimit - 1_024)
        #expect(features.judgeOverheadReserve == baseline.judgeOverheadReserve + 1_024)
        #expect(features.toolOutputReserve == baseline.toolOutputReserve + 1_024)
    }

    @Test func judgeAdmissionReservesPostToolInstructionsBeforeGeneration() async throws {
        var suite = EvaluationSuite()
        suite.cases = [.init(name: "Boundary", prompt: "Summarize the reference.",
                             expected: String(repeating: "reference ", count: 1_500))]
        let runner = EvaluationRunner()
        // Find this tokenizer's actual admission boundary; don't assume a fixed tokenization.
        var lower = 1_000
        var upper = 16_000
        _ = try await runner.preparedPrompt(for: suite.cases[0], suite: suite, images: [],
                                            contextSize: upper, tools: [])
        while lower + 1 < upper {
            let midpoint = (lower + upper) / 2
            do {
                _ = try await runner.preparedPrompt(for: suite.cases[0], suite: suite, images: [],
                                                    contextSize: midpoint, tools: [])
                upper = midpoint
            } catch { lower = midpoint }
        }
        // A deterministic rule is never sent to the AI judge, even in a mixed rubric.
        var mixedSuite = suite
        mixedSuite.criteria = "exact: \"\(String(repeating: "LONG_LITERAL ", count: 200))\"\n" + suite.criteria
        _ = try await runner.preparedPrompt(for: mixedSuite.cases[0], suite: mixedSuite, images: [],
                                            contextSize: upper, tools: [])
        suite.features.profile.enabled = true
        suite.features.profile.afterToolInstructions = String(repeating: "Use uppercase. ", count: 40)
        let profileTokens = try await SystemLanguageModel.default.tokenCount(
            for: Instructions(suite.features.profile.afterToolInstructions))
        let inputLimit = suite.modelConfiguration.contextAllocation(contextSize: upper, includesModelJudge: true)
        // The subject still fits. Only the additional judge contract should reject the run.
        #expect(profileTokens + 100 < inputLimit.effectiveInputLimit)
        await #expect(throws: (any Error).self) {
            try await runner.preparedPrompt(for: suite.cases[0], suite: suite, images: [],
                                             contextSize: upper, tools: [])
        }
    }

}
