import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationStarterPackReferenceTests {
    @Test func groundedStarterProvidesTheReferenceToTheSubject() throws {
        let suite = EvaluationStarterPack.groundedAnswers.makeSuite()
        #expect(suite.instructions.contains("Verified product reference:"))
        #expect(suite.instructions.contains("saved run can be exported as a JSON report from its detail view"))
        #expect(suite.instructions.contains("passing local build proves compilation"))
        #expect(suite.instructions.contains("App Store approval is a separate external review outcome"))
        #expect(!suite.instructions.localizedCaseInsensitiveContains("retention"))
        let unknown = try #require(suite.cases.first { $0.name == "Unknown policy" })
        #expect(unknown.prompt.contains("logs retained"))
        #expect(unknown.expected.contains("does not specify"))
    }

    @Test func changingAnOracleDoesNotChangeTheSubjectReferenceOrPrompt() throws {
        let suite = EvaluationStarterPack.groundedAnswers.makeSuite()
        var evaluationCase = try #require(suite.cases.first)
        let original = EvaluationRunner.promptText(
            for: evaluationCase, attachments: suite.attachments,
            textCharacterLimit: 100_000, referenceMode: suite.modelConfiguration.referenceMode
        )
        evaluationCase.expected = "ORACLE_ONLY_SENTINEL"
        let changed = EvaluationRunner.promptText(
            for: evaluationCase, attachments: suite.attachments,
            textCharacterLimit: 100_000, referenceMode: suite.modelConfiguration.referenceMode
        )
        #expect(changed == original)
        #expect(!changed.contains("ORACLE_ONLY_SENTINEL"))
        #expect(!suite.instructions.contains("ORACLE_ONLY_SENTINEL"))
    }
}
