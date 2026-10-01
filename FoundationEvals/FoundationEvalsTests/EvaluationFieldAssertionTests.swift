import Foundation
import Testing
@testable import FoundationEvals

struct EvaluationFieldAssertionTests {
    @Test func resolvesEscapedPointersArraysAndExplicitNull() {
        let assertions = [
            assertion("/a~1b/~0key/0", .equals, "null"),
            assertion("/a~1b/~0key/1", .equals, "\"Paris\""),
            assertion("/a~1b/~0key/0", .exists)
        ]
        let results = EvaluationFieldAssertions.evaluate(
            response: #"{"a/b":{"~key":[null,"Paris"]}}"#, assertions: assertions
        )
        #expect(results.allSatisfy { $0.passed })
        #expect(results[0].actualJSON == "null")
        #expect(results[1].actualJSON == "\"Paris\"")
    }

    @Test func rejectsMissingFieldsInvalidPointersAndInvalidArrayIndexes() {
        let results = EvaluationFieldAssertions.evaluate(response: #"{"items":[1]}"#, assertions: [
            assertion("/missing", .exists), assertion("/items/01", .exists),
            assertion("/items/-", .exists), assertion("/items/9", .exists),
            assertion("items", .exists), assertion("/bad~2", .exists)
        ])
        #expect(results.allSatisfy { !$0.passed })
        #expect(results.allSatisfy { $0.actualJSON == nil })
    }

    @Test func keepsJSONTypesDistinctAndComparesObjectsStructurally() {
        let results = EvaluationFieldAssertions.evaluate(response: #"{"n":1,"b":true,"s":"1","obj":{"b":2,"a":1}}"#, assertions: [
            assertion("/n", .equals, "true"), assertion("/b", .equals, "1"),
            assertion("/s", .equals, "1"), assertion("/obj", .equals, #"{"a":1,"b":2}"#)
        ])
        #expect(results.map(\.passed) == [false, false, false, true])
    }

    @Test func checksInclusiveNumericBoundsWithoutCoercingStringsOrBooleans() {
        let results = EvaluationFieldAssertions.evaluate(response: #"{"n":1.5,"s":"1.5","b":true}"#, assertions: [
            assertion("/n", .minimum, "1.5"), assertion("/n", .maximum, "1.5"),
            assertion("/n", .maximum, "1.4"), assertion("/s", .minimum, "1"),
            assertion("/b", .minimum, "0")
        ])
        #expect(results.map(\.passed) == [true, true, false, false, false])
    }

    @Test func containsTextIsCaseSensitiveAndStringOnly() {
        let results = EvaluationFieldAssertions.evaluate(response: #"{"text":"Hello Paris","n":42}"#, assertions: [
            assertion("/text", .containsText, "Paris"), assertion("/text", .containsText, "paris"),
            assertion("/n", .containsText, "42")
        ])
        #expect(results.map(\.passed) == [true, false, false])
    }

    @Test func rejectsMalformedResponsesAndSupportsWholeDocumentPointer() {
        for response in ["```json\n{}\n```", "{} trailing", "{", "NaN"] {
            let result = EvaluationFieldAssertions.evaluate(response: response, assertions: [assertion("", .exists)])
            #expect(result.first?.passed == false)
        }
        #expect(EvaluationFieldAssertions.evaluate(
            response: "[1,true,null]", assertions: [assertion("", .equals, "[1,true,null]")]
        ).first?.passed == true)
    }

    @Test func validatesConfigurationBeforeRun() {
        #expect(EvaluationFieldAssertions.validationIssue(assertions: [assertion("", .exists)], scoringMode: .review) != nil)
        #expect(EvaluationFieldAssertions.validationIssue(assertions: [], scoringMode: .review) == nil)
        for item in [assertion("/n", .minimum, "\"2\""), assertion("/n", .maximum, "true"),
                     assertion("/x", .equals, "unquoted"), assertion("/x", .containsText)] {
            #expect(EvaluationFieldAssertions.configurationIssue(item) != nil)
        }
    }

    @Test func rejectsNumbersThatWouldLosePrecision() {
        let tooPrecise = "12345678901234567890123456789012345678901"
        let checks = [assertion("", .equals, "1")]
        #expect(EvaluationFieldAssertions.evaluate(response: tooPrecise, assertions: checks).first?.passed == false)
        #expect(EvaluationFieldAssertions.configurationIssue(assertion("", .equals, tooPrecise)) != nil)
        #expect(EvaluationFieldAssertions.evaluate(response: "1e-200", assertions: checks).first?.passed == false)
        #expect(EvaluationFieldAssertions.evaluate(response: "1.00", assertions: checks).first?.passed == true)
    }

    @Test func assertionGateNeverPromotesBaseFailureOrIssue() {
        let failing = EvaluationFieldAssertions.evaluate(response: "{}", assertions: [assertion("/missing", .exists)])
        let passing = EvaluationFieldAssertions.evaluate(response: "{}", assertions: [assertion("", .exists)])
        #expect(EvaluationFieldAssertions.gatedStatus(baseStatus: .passed, results: failing) == .failed)
        #expect(EvaluationFieldAssertions.gatedStatus(baseStatus: .passed, results: passing) == .passed)
        for status in [EvaluationResultStatus.failed, .unscored, .error] {
            #expect(EvaluationFieldAssertions.gatedStatus(baseStatus: status, results: passing) == status)
            #expect(EvaluationFieldAssertions.gatedStatus(baseStatus: status, results: failing) == status)
        }
    }

    private func assertion(_ pointer: String, _ operation: EvaluationFieldAssertionOperation, _ expected: String = "") -> EvaluationFieldAssertion {
        EvaluationFieldAssertion(pointer: pointer, operation: operation, expectedValue: expected)
    }
}
