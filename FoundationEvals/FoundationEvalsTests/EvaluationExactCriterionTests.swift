import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationExactCriterionTests {
    @Test(arguments: ["DELIVERY VERIFIED", "READY", "ORDER_104 SHIPPED", "BUILD-17 OK"])
    func acceptsConservativeUnquotedStatusLiterals(literal: String) {
        #expect(EvaluationExactCriterion.expectedText(in: "The final response is exactly \(literal).") == literal)
        #expect(EvaluationExactCriterion.expectedText(in: "The response is exactly \(literal).") == literal)
    }

    @Test func decodesQuotedLiteralGrammarWithoutLosingContent() {
        #expect(EvaluationExactCriterion.expectedText(in: #"exact: "Paris, France!""#) == "Paris, France!")
        #expect(EvaluationExactCriterion.expectedText(in: #"The final response is exactly "Livré ✓"."#) == "Livré ✓")
        #expect(EvaluationExactCriterion.expectedText(in: #"The response is exactly "状态：完成"."#) == "状态：完成")
        #expect(EvaluationExactCriterion.expectedText(in: #"exact: """#) == "")
        #expect(EvaluationExactCriterion.expectedText(in: #"exact: "Line one\n\"Line two\"\t""#) == "Line one\n\"Line two\"\t")
        #expect(EvaluationExactCriterion.expectedText(in: #"exact: "\u0052EADY""#) == "READY")
        #expect(EvaluationExactCriterion.expectedText(in: #"The response is exactly "AND OR IF"."#) == "AND OR IF")
    }

    @Test func preservesExactWhitespaceInsideQuotedValues() {
        #expect(EvaluationExactCriterion.expectedText(in: " \nexact: \" Paris\\n\" \n") == " Paris\n")
        #expect(EvaluationExactCriterion.check(criterion: #"exact: " Paris\n""#, index: 2, response: " Paris\n")?.score == 4)
        #expect(EvaluationExactCriterion.check(criterion: #"exact: " Paris\n""#, index: 2, response: "Paris")?.score == 1)
    }

    @Test func theObservedMisgradeUsesActualStringEquality() throws {
        let criterion = "The final response is exactly DELIVERY VERIFIED."
        let check = try #require(EvaluationExactCriterion.check(criterion: criterion, index: 3, response: "DELIVERY VERIFIED"))
        #expect(check.criterionIndex == 3)
        #expect(check.criterion == criterion)
        #expect(check.score == 4)
        #expect(check.exactComparisons == [.init(expectedText: "DELIVERY VERIFIED", matches: true)])
    }

    @Test(arguments: ["delivery verified", "DELIVERY VERIFIED now", " DELIVERY VERIFIED", "DELIVERY VERIFIED\n"])
    func rejectsWrongCaseAndExtraText(response: String) {
        let check = EvaluationExactCriterion.check(
            criterion: "The final response is exactly DELIVERY VERIFIED.", index: 1, response: response
        )
        #expect(check?.score == 1)
        #expect(check?.exactComparisons.first?.matches == false)
    }

    @Test(arguments: [
        "The final response is exactly READY and the tool was called.",
        "The final response is exactly READY AND THE TOOL WAS CALLED.",
        "The final response is exactly READY OR WAIT.",
        "The final response is exactly READY IF COMPLETE.",
        "The final response is exactly READY UNLESS INCOMPLETE.",
        "The final response is exactly READY EXCEPT WHEN FAILED.",
        "The final response is exactly READY BUT ONLY AFTER LOOKUP.",
        "The final response is exactly READY THEN STOP.",
        "The final response is not exactly READY.",
        "If the tool succeeds, the response is exactly READY.",
        "Do not return exactly READY.",
        "The response is exactly READY. Also call a tool.",
        "The response is exactly READY, with no other words.",
        "The response is exactly Ready.",
        "The response is exactly READY",
        "The response is exactly READY!.",
        "The response is exactly READY .",
        "The response is exactly A B C D E F G H I.",
        "The response is exactly RÉADY.",
        "The response is exactly READY\nNOW.",
        "exact: READY",
        "exact: true",
        "exact: {\"text\":\"READY\"}",
        "exact: \"READY\" and call a tool",
        "exact: \"READY\".",
        "The response is exactly \"READY\" and the tool was called.",
        "The response is exactly \"READY\"",
        "exact: \"unterminated"
    ])
    func leavesOtherRubricSemanticsUntouched(criterion: String) {
        #expect(EvaluationExactCriterion.expectedText(in: criterion) == nil)
        #expect(EvaluationExactCriterion.check(criterion: criterion, index: 1, response: "READY") == nil)
    }

    @Test func exactRulesDoNotBypassOtherRubricRequirements() throws {
        var suite = EvaluationSuite()
        suite.criteria = "exact: \"READY\"\nThe lookup tool was called."
        #expect(suite.needsModelJudge)
        let exact = try #require(EvaluationExactCriterion.check(
            criterion: suite.rubricCriteria[0], index: 1, response: "READY"))
        let semantic = EvaluationJudgeCriterionTrace(
            criterionIndex: 2, criterion: suite.rubricCriteria[1], score: 1,
            rationale: "No lookup was called.", exactComparisons: [])
        let result = EvaluationJudge.aggregate(checks: [semantic, exact])
        #expect(result.score == 1)
        #expect(result.checks.map(\.criterionIndex) == [1, 2])
        suite.criteria = "exact: \"READY\""
        #expect(!suite.needsModelJudge)
    }

}
