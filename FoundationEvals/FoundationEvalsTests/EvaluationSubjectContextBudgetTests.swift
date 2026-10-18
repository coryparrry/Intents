import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

struct EvaluationSubjectContextBudgetTests {
    @Test func independentJudgeLeavesSubjectAdmissionUnchanged() async throws {
        var suite = EvaluationSuite()
        suite.instructions = ""
        suite.criteria = "The response answers the question."
        suite.cases = [.init(name: "Fits subject", prompt: "Question", expected: "Answer")]
        suite.modelConfiguration.maximumResponseTokens = 1_024
        suite.scoringMode = .review
        let runner = EvaluationRunner()
        let tokenCounter = SubjectBudgetTokenCounter(promptTokens: 2_000)
        let withoutJudge = try await runner.preparedPrompt(
            for: suite.cases[0], suite: suite, images: [], contextSize: 4_096,
            tools: [], tokenCounter: tokenCounter
        )
        suite.scoringMode = .modelJudge
        suite.judgeConfiguration.mode = .connection
        #expect(suite.needsModelJudge)
        #expect(!suite.usesSubjectModelForJudging)
        let withExternalJudge = try await runner.preparedPrompt(
            for: suite.cases[0], suite: suite, images: [], contextSize: 4_096,
            tools: [], tokenCounter: tokenCounter
        )
        #expect(withExternalJudge.tokenCount == withoutJudge.tokenCount)
        #expect(withExternalJudge.text == withoutJudge.text)

        suite.judgeConfiguration.mode = .sameModel
        #expect(suite.usesSubjectModelForJudging)
        await #expect(throws: (any Error).self) {
            try await runner.preparedPrompt(
                for: suite.cases[0], suite: suite, images: [], contextSize: 4_096,
                tools: [], tokenCounter: tokenCounter
            )
        }
    }

    @Test func independentJudgeIsNotTokenizedWithTheSubjectTokenizer() async throws {
        var suite = EvaluationSuite()
        suite.instructions = ""
        suite.criteria = "The response answers the question."
        suite.cases = [.init(name: "Small subject", prompt: "Question", expected: "Answer")]
        suite.scoringMode = .modelJudge
        suite.judgeConfiguration.mode = .connection
        _ = try await EvaluationRunner().preparedPrompt(
            for: suite.cases[0], suite: suite, images: [], contextSize: 4_096,
            tools: [], tokenCounter: SubjectBudgetTokenCounter(promptTokens: 10, rejectJudgeSchema: true)
        )
    }

    @Test func deterministicCriteriaNeverReserveSubjectJudgeContext() {
        var suite = EvaluationSuite()
        suite.scoringMode = .modelJudge
        suite.criteria = "exact: \"Answer\""
        #expect(!suite.needsModelJudge)
        #expect(!suite.usesSubjectModelForJudging)
    }

    @Test func independentJudgeStillHonorsExplicitSubjectInputLimit() async {
        var suite = EvaluationSuite()
        suite.instructions = ""
        suite.criteria = "The response answers the question."
        suite.cases = [.init(name: "Input cap", prompt: "Question", expected: "Answer")]
        suite.modelConfiguration.maximumInputTokens = 1_500
        suite.scoringMode = .modelJudge
        suite.judgeConfiguration.mode = .connection
        await #expect(throws: (any Error).self) {
            try await EvaluationRunner().preparedPrompt(
                for: suite.cases[0], suite: suite, images: [], contextSize: 4_096,
                tools: [], tokenCounter: SubjectBudgetTokenCounter(promptTokens: 2_000)
            )
        }
    }
}

private struct SubjectBudgetTokenCounter: EvaluationPromptInputTokenCounting {
    struct UnexpectedJudgeSchema: Error {}
    var promptTokens: Int
    var rejectJudgeSchema = false

    func tokenCount(for prompt: Prompt) async throws -> Int { promptTokens }
    func tokenCount(for instructions: Instructions) async throws -> Int { 0 }
    func tokenCount(for schema: GenerationSchema) async throws -> Int {
        if rejectJudgeSchema { throw UnexpectedJudgeSchema() }
        return 0
    }
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int { 0 }
    func tokenCount(for tools: [any Tool]) async throws -> Int { 0 }
    func tokenCount(forText text: String) async throws -> Int { promptTokens }
}
