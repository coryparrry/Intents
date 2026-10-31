import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationStarterPackReferenceTests {
    /// Keeps expected answers out of the subject prompt when a case's oracle changes.
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
    }
}
