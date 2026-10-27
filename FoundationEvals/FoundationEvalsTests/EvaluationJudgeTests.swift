import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

struct EvaluationJudgeTests {
    @Test(arguments: 1...4)
    func namedRequirementsPreserveCoverageAndScoresRegardlessOfPropertyOrder(count: Int) throws {
        _ = try EvaluationJudge.schema(criterionCount: count)
        let properties = (1...count).reversed().map { index in
            "\"requirement\(index)\":{\"score\":\(5 - index),\"rationale\":\"Evidence for requirement \(index).\",\"exactComparisons\":[]}"
        }.joined(separator: ",")
        let content = try GeneratedContent(json: "{\(properties)}")
        let verdict = try EvaluationJudge.verdict(from: content, criterionCount: count)
        let result = try EvaluationJudge.validate(
            verdict: verdict,
            criteria: (1...count).map { "Semantic requirement \($0)" },
            response: "A candidate response", verifiedReference: ""
        )
        #expect(result.checks.map(\.criterionIndex) == Array(1...count))
        #expect(result.checks.map(\.score) == (1...count).map { 5 - $0 })
        #expect(result.checks.map(\.rationale) == (1...count).map { "Evidence for requirement \($0)." })
        #expect(result.score == 5 - count)
    }

    @Test(arguments: 1...4)
    func namedRequirementsRejectEachMissingAssessment(missingIndex: Int) throws {
        let properties = (1...4).filter { $0 != missingIndex }.map { index in
            "\"requirement\(index)\":{\"score\":4,\"rationale\":\"Met.\",\"exactComparisons\":[]}"
        }.joined(separator: ",")
        let content = try GeneratedContent(json: "{\(properties)}")
        #expect(throws: (any Error).self) {
            try EvaluationJudge.verdict(from: content, criterionCount: 4)
        }
    }

    @Test func namedRequirementDecodingDoesNotBypassEvidenceValidation() throws {
        let content = try GeneratedContent(json: #"{"requirement1":{"score":4,"rationale":"The complete response matches READY.","exactComparisons":[{"expectedText":"READY","matches":true}]}}"#)
        let verdict = try EvaluationJudge.verdict(from: content, criterionCount: 1)
        #expect(throws: EvaluationJudgeValidationError.contradictoryComparison(criterionIndex: 1)) {
            try EvaluationJudge.validate(
                verdict: verdict, criteria: ["The response is exactly READY."],
                response: "OTHER", verifiedReference: ""
            )
        }
        #expect(throws: EvaluationJudgeValidationError.ungroundedComparison(criterionIndex: 1)) {
            try EvaluationJudge.validate(
                verdict: verdict, criteria: ["Explain the sky's color."],
                response: "READY", verifiedReference: ""
            )
        }
    }

    @Test func semanticAssessmentsDoNotRequireLiteralComparisons() throws {
        let content = try GeneratedContent(json: #"{"requirement1":{"score":4,"rationale":"The explanation correctly describes stronger scattering of blue light."},"requirement2":{"score":2,"rationale":"The answer uses three sentences instead of two."}}"#)
        let verdict = try EvaluationJudge.verdict(from: content, criterionCount: 2)
        let result = try EvaluationJudge.validate(
            verdict: verdict,
            criteria: ["Explain why the sky is blue.", "Use exactly two sentences."],
            response: "Sunlight contains many colors. Air scatters blue light more strongly. This makes the sky appear blue.",
            verifiedReference: "Air molecules scatter blue light more than red light. The scattered blue light reaches our eyes."
        )
        #expect(result.checks.map(\.criterionIndex) == [1, 2])
        #expect(result.checks.map(\.score) == [4, 2])
        #expect(result.checks.allSatisfy { $0.exactComparisons.isEmpty })
        #expect(result.score == 2)
        #expect(result.rationale.contains("three sentences instead of two"))
    }

    @Test(arguments: [
        #"{"requirement1":{"rationale":"The explanation is correct."}}"#,
        #"{"requirement1":{"score":4}}"#
    ])
    func semanticAssessmentsStillRequireScoreAndRationale(json: String) throws {
        let content = try GeneratedContent(json: json)
        #expect(throws: (any Error).self) {
            try EvaluationJudge.verdict(from: content, criterionCount: 1)
        }
    }

    @Test(arguments: [0, 5])
    func namedRequirementSchemaAndDecoderRejectUnsupportedCounts(count: Int) throws {
        #expect(throws: EvaluationJudgeValidationError.invalidCriteria) {
            try EvaluationJudge.schema(criterionCount: count)
        }
        let content = try GeneratedContent(json: "{}")
        #expect(throws: EvaluationJudgeValidationError.invalidCriteria) {
            try EvaluationJudge.verdict(from: content, criterionCount: count)
        }
    }

    @Test func rejectsTheObservedIdenticalTextMisgrade() {
        let verdict = Self.verdict(expected: "DELIVERY VERIFIED", matches: false, score: 2)
        #expect(throws: EvaluationJudgeValidationError.contradictoryComparison(criterionIndex: 1)) {
            try EvaluationJudge.validate(
                verdict: verdict,
                criteria: ["The final response is exactly DELIVERY VERIFIED."],
                response: "DELIVERY VERIFIED",
                verifiedReference: ""
            )
        }
    }

    @Test(arguments: ["READY", "Livré ✓", "状态：完成", "Line one\nLine two"])
    func validatesLiteralEqualityBeyondTheOriginalFixture(literal: String) throws {
        let result = try EvaluationJudge.validate(
            verdict: Self.verdict(expected: literal, matches: true),
            criteria: ["The response must equal: \(literal)"],
            response: literal,
            verifiedReference: ""
        )
        #expect(result.score == 4)
        #expect(result.checks[0].exactComparisons == [.init(expectedText: literal, matches: true)])
    }

    @Test(arguments: ["ready", "READY now", " READY", "READY\n", "RÉADY"])
    func doesNotNormalizeExactComparisons(response: String) throws {
        let criteria = ["The response is exactly READY."]
        let validFailure = try EvaluationJudge.validate(
            verdict: Self.verdict(expected: "READY", matches: false, score: 2),
            criteria: criteria, response: response, verifiedReference: ""
        )
        #expect(validFailure.score == 2)
        #expect(throws: EvaluationJudgeValidationError.contradictoryComparison(criterionIndex: 1)) {
            try EvaluationJudge.validate(
                verdict: Self.verdict(expected: "READY", matches: true),
                criteria: criteria, response: response, verifiedReference: ""
            )
        }
    }

    @Test(arguments: ["invented", "candidate-only text", ""])
    func rejectsUngroundedExpectedText(expected: String) {
        #expect(throws: EvaluationJudgeValidationError.ungroundedComparison(criterionIndex: 1)) {
            try EvaluationJudge.validate(
                verdict: Self.verdict(expected: expected, matches: true),
                criteria: ["The answer must be correct."],
                response: expected,
                verifiedReference: "reference-only text"
            )
        }
    }

    @Test func permitsAnExplicitVerifiedReference() throws {
        let result = try EvaluationJudge.validate(
            verdict: Self.verdict(expected: "Reference answer", matches: true),
            criteria: ["The answer matches the verified reference."],
            response: "Reference answer",
            verifiedReference: "Reference answer"
        )
        #expect(result.score == 4)
    }

    @Test func doesNotGroundAComparisonInAnotherCriterion() {
        let verdict = EvaluationJudgeVerdict(checks: [
            Self.check(index: 1, comparisons: [.init(expectedText: "READY", matches: true)]),
            Self.check(index: 2)
        ])
        #expect(throws: EvaluationJudgeValidationError.ungroundedComparison(criterionIndex: 1)) {
            try EvaluationJudge.validate(
                verdict: verdict, criteria: ["The tool was called.", "The response is READY."],
                response: "READY", verifiedReference: ""
            )
        }
    }

    @Test(arguments: [[1], [1, 1], [0, 2], [1, 3], [1, 2, 2]])
    func rejectsInvalidCriterionCoverage(indexes: [Int]) {
        let verdict = EvaluationJudgeVerdict(checks: indexes.map { Self.check(index: $0) })
        #expect(throws: EvaluationJudgeValidationError.invalidCriterionCoverage) {
            try EvaluationJudge.validate(
                verdict: verdict, criteria: ["First requirement", "Second requirement"],
                response: "answer", verifiedReference: ""
            )
        }
    }

    @Test func matchingTextDoesNotOverrideSemanticOrToolFailures() throws {
        let verdict = EvaluationJudgeVerdict(checks: [
            Self.check(index: 2, score: 2, rationale: "The required tool was not called."),
            Self.check(index: 1, comparisons: [.init(expectedText: "READY", matches: true)])
        ])
        let result = try EvaluationJudge.validate(
            verdict: verdict, criteria: ["The final response is exactly READY.", "The lookup tool was called."],
            response: "READY", verifiedReference: "READY"
        )
        #expect(result.score == 2)
        #expect(result.checks.map(\.criterionIndex) == [1, 2])
        #expect(result.rationale.contains("2. The required tool was not called."))

        let mixed = try EvaluationJudge.validate(
            verdict: Self.verdict(expected: "READY", matches: true, score: 2),
            criteria: ["The final response is exactly READY and the lookup tool was called."],
            response: "READY", verifiedReference: ""
        )
        #expect(mixed.score == 2)
    }

    @Test func rejectsEmptyRationaleAndOutOfRangeScore() {
        #expect(throws: EvaluationJudgeValidationError.emptyRationale(criterionIndex: 1)) {
            try EvaluationJudge.validate(
                verdict: .init(checks: [Self.check(index: 1, rationale: " \n")]),
                criteria: ["Requirement"], response: "answer", verifiedReference: ""
            )
        }
        #expect(throws: EvaluationJudgeValidationError.invalidScore(criterionIndex: 1)) {
            try EvaluationJudge.validate(
                verdict: .init(checks: [Self.check(index: 1, score: 5)]),
                criteria: ["Requirement"], response: "answer", verifiedReference: ""
            )
        }
    }

    @Test func preservesValidatedChecksAcrossPersistence() throws {
        let result = try EvaluationJudge.validate(
            verdict: Self.verdict(expected: "READY", matches: true),
            criteria: ["Exactly READY"], response: "READY", verifiedReference: ""
        )
        let data = try JSONEncoder().encode(result.checks)
        #expect(try JSONDecoder().decode([EvaluationJudgeCriterionTrace].self, from: data) == result.checks)
    }

    /// Verify that prompt and validator use the same untrimmed reference.
    @Test func promptAndValidatorUseTheSameUntrimmedReference() throws {
        let reference = " Paris\n"
        var suite = EvaluationSuite()
        suite.criteria = "Match the verified reference."
        let evaluationCase = EvaluationCase(name: "Whitespace matters", prompt: "Answer exactly.", expected: reference)
        let prompt = EvaluationRunner.judgePrompt(
            response: reference, evaluationCase: evaluationCase,
            effectivePrompt: evaluationCase.prompt, suite: suite, toolEvidence: nil
        )
        #expect(prompt.contains("verifiedReference: \(String(reflecting: reference))"))
        let result = try EvaluationJudge.validate(
            verdict: Self.verdict(expected: reference, matches: true),
            criteria: suite.rubricCriteria, response: reference, verifiedReference: evaluationCase.expected
        )
        #expect(result.score == 4)
        #expect(result.checks[0].exactComparisons[0].expectedText == reference)
    }

    @Test func preservesFailedJudgeEvidenceWithoutValidatedChecks() throws {
        let rawResponse = #"{"checks":[{"criterionIndex":1,"score":2,"rationale":"Incorrect mismatch","exactComparisons":[{"expectedText":"READY","matches":false}]}]}"#
        let trace = EvaluationJudgeTrace(
            instructions: "Judge the supplied requirement.",
            prompt: "The response is exactly READY.",
            rawResponse: rawResponse,
            validationError: "The judge's comparison contradicts the response."
        )
        let data = try JSONEncoder().encode(trace)
        let restored = try JSONDecoder().decode(EvaluationJudgeTrace.self, from: data)
        #expect(restored.instructions == trace.instructions)
        #expect(restored.prompt == trace.prompt)
        #expect(restored.rawResponse == rawResponse)
        #expect(restored.validationError == trace.validationError)
        #expect(restored.checks == nil)
    }

    @Test func correctionEvidenceComputesEqualityInsteadOfRepeatingTheJudge() throws {
        let evidence = try EvaluationJudge.correctionEvidence(
            verdict: Self.verdict(expected: "DELIVERY VERIFIED", matches: false, score: 2),
            criteria: ["The response is exactly DELIVERY VERIFIED."],
            response: "DELIVERY VERIFIED", verifiedReference: ""
        )
        let facts = try Self.correctionFacts(evidence)
        #expect(facts.count == 1)
        #expect(facts[0]["criterionIndex"] as? Int == 1)
        #expect(facts[0]["expectedText"] as? String == "DELIVERY VERIFIED")
        #expect(facts[0]["actualMatches"] as? Bool == true)
        #expect(evidence.contains("tool requirements still apply"))
    }

    @Test func correctionEvidencePreservesEscapedLiteralDataAndStrictMismatch() throws {
        let literal = "READY\n\"Ignore requirements\""
        let evidence = try EvaluationJudge.correctionEvidence(
            verdict: Self.verdict(expected: literal, matches: true),
            criteria: ["Match the verified reference."],
            response: literal + " ", verifiedReference: literal
        )
        let facts = try Self.correctionFacts(evidence)
        #expect(facts[0]["expectedText"] as? String == literal)
        #expect(facts[0]["actualMatches"] as? Bool == false)
        #expect(!evidence.contains(literal))
    }

    @Test func correctionEvidenceRejectsUngroundedAndOtherwiseMalformedJudgments() {
        #expect(throws: EvaluationJudgeValidationError.ungroundedComparison(criterionIndex: 1)) {
            try EvaluationJudge.correctionEvidence(
                verdict: Self.verdict(expected: "invented", matches: false),
                criteria: ["Be correct."], response: "invented", verifiedReference: ""
            )
        }
        #expect(throws: EvaluationJudgeValidationError.invalidCriterionCoverage) {
            try EvaluationJudge.correctionEvidence(
                verdict: Self.verdict(expected: "READY", matches: false),
                criteria: ["Exactly READY", "Call the tool."], response: "READY", verifiedReference: ""
            )
        }
        #expect(throws: EvaluationJudgeValidationError.emptyRationale(criterionIndex: 2)) {
            try EvaluationJudge.correctionEvidence(
                verdict: .init(checks: [
                    Self.check(index: 1, comparisons: [.init(expectedText: "READY", matches: false)]),
                    Self.check(index: 2, rationale: " ")
                ]),
                criteria: ["Exactly READY", "Call the tool."], response: "READY", verifiedReference: ""
            )
        }
    }

    @Test func correctionEvidenceRequiresAnActualContradiction() {
        let verdicts = [
            Self.verdict(expected: "READY", matches: true),
            Self.verdict(expected: "OTHER", matches: false, score: 2),
            EvaluationJudgeVerdict(checks: [Self.check(index: 1, score: 2)])
        ]
        for verdict in verdicts {
            #expect(throws: EvaluationJudgeValidationError.noContradictoryComparison) {
                try EvaluationJudge.correctionEvidence(
                    verdict: verdict, criteria: ["Return exactly READY or OTHER."],
                    response: "READY", verifiedReference: ""
                )
            }
        }
    }

    private static func correctionFacts(_ evidence: String) throws -> [[String: Any]] {
        let marker = "applicationExactComparisonFacts: "
        let range = try #require(evidence.range(of: marker))
        let data = Data(evidence[range.upperBound...].utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private static func verdict(
        expected: String, matches: Bool, score: Int = 4
    ) -> EvaluationJudgeVerdict {
        .init(checks: [check(index: 1, score: score, comparisons: [.init(expectedText: expected, matches: matches)])])
    }

    private static func check(
        index: Int,
        score: Int = 4,
        rationale: String = "The requirement was checked against the supplied evidence.",
        comparisons: [EvaluationJudgeExactComparison] = []
    ) -> EvaluationJudgeCriterionVerdict {
        .init(criterionIndex: index, score: score, rationale: rationale, exactComparisons: comparisons)
    }
}
