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

    /// Admission reserves larger reachable profile responses while leaving an unreachable after-tool phase out of the budget.
    @Test func profileResponseLimitsReserveSubjectAndJudgeCapacity() async throws {
        var suite = EvaluationSuite()
        suite.scoringMode = .review
        suite.instructions = ""
        suite.cases = [.init(name: "Profile budget", prompt: "Return ready.", expected: "")]
        suite.modelConfiguration.maximumResponseTokens = 128
        suite.features.profile.enabled = true
        suite.features.profile.afterToolMaximumResponseTokens = 4_096
        #expect(suite.responseTokenReserve() == 128)
        #expect(suite.responseTokenReserve(afterToolProfileIsReachable: true) == 4_096)
        var restored = suite
        let history = Transcript(entries: [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "Synthetic setup"))])),
            .toolOutput(Transcript.ToolOutput(id: "setup-tool", toolName: "fixture",
                segments: [.text(Transcript.TextSegment(content: "Synthetic result"))])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "Ready"))]))
        ])
        restored.cases[0].conversation.restoredTranscriptJSON = String(decoding: try JSONEncoder().encode(history), as: UTF8.self)
        #expect(restored.responseTokenReserve() == 4_096)
        let initial = suite.modelConfiguration.contextAllocation(contextSize: 8_192, includesModelJudge: true)
        let transitioned = suite.modelConfiguration.contextAllocation(contextSize: 8_192, includesModelJudge: true,
            maximumSubjectResponseTokens: suite.responseTokenReserve(afterToolProfileIsReachable: true))
        #expect(transitioned.effectiveInputLimit == initial.effectiveInputLimit - (4_096 - 128))
        #expect(transitioned.judgeOverheadReserve == initial.judgeOverheadReserve + (4_096 - 128))
        let runner = EvaluationRunner()
        let counter = EvaluationPortablePromptInputTokenCounter()
        _ = try await runner.preparedPrompt(for: suite.cases[0], suite: suite, images: [], contextSize: 4_096,
            tools: [], tokenCounter: counter)
        await #expect(throws: (any Error).self) {
            _ = try await runner.preparedPrompt(for: suite.cases[0], suite: suite, images: [], contextSize: 4_096,
                tools: [], profileHasTransitioned: true, tokenCounter: counter)
        }
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
        let tokenCounter = EvaluationPortablePromptInputTokenCounter()
        // Find this counter's admission boundary; don't assume a fixed tokenization.
        var lower = 1_000
        var upper = 65_536
        _ = try await runner.preparedPrompt(for: suite.cases[0], suite: suite, images: [],
                                            contextSize: upper, tools: [], tokenCounter: tokenCounter)
        while lower + 1 < upper {
            let midpoint = (lower + upper) / 2
            do {
                _ = try await runner.preparedPrompt(for: suite.cases[0], suite: suite, images: [],
                                                    contextSize: midpoint, tools: [], tokenCounter: tokenCounter)
                upper = midpoint
            } catch { lower = midpoint }
        }
        // A deterministic rule is never sent to the AI judge, even in a mixed rubric.
        var mixedSuite = suite
        mixedSuite.criteria = "exact: \"\(String(repeating: "LONG_LITERAL ", count: 200))\"\n" + suite.criteria
        _ = try await runner.preparedPrompt(for: mixedSuite.cases[0], suite: mixedSuite, images: [],
                                            contextSize: upper, tools: [], tokenCounter: tokenCounter)
        suite.features.profile.enabled = true
        suite.features.profile.afterToolInstructions = String(repeating: "Use uppercase. ", count: 40)
        let profileTokens = try await tokenCounter.tokenCount(
            for: Instructions(suite.features.profile.afterToolInstructions))
        let inputLimit = suite.modelConfiguration.contextAllocation(contextSize: upper, includesModelJudge: true)
        // The subject still fits. Only the additional judge contract should reject the run.
        #expect(profileTokens + 100 < inputLimit.effectiveInputLimit)
        // No callable tools and no prior activation leave this profile unreachable.
        _ = try await runner.preparedPrompt(for: suite.cases[0], suite: suite, images: [],
                                            contextSize: upper, tools: [], tokenCounter: tokenCounter)
        // A setup or restored tool output can already have activated the profile.
        await #expect(throws: (any Error).self) {
            try await runner.preparedPrompt(for: suite.cases[0], suite: suite, images: [],
                                             contextSize: upper, tools: [], profileHasTransitioned: true,
                                             tokenCounter: tokenCounter)
        }
    }

}
