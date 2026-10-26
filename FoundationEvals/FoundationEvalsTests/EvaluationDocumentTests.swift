import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

enum DocumentTestFixture {
    static var passage: EvaluationDocumentPassage {
        .init(id: "page-6-1", location: "Page 6", text: "Owners can export a workspace. Members can view reports but cannot export a workspace.")
    }
    static var source: EvaluationDocumentSource {
        .init(name: "Guide.pdf", fileDigest: String(repeating: "a", count: 64), passages: [passage])
    }
    static func example(reviewed: Bool = true) -> EvaluationCase {
        var value = EvaluationCase(name: "Workspace exports", prompt: "Can members export a workspace?", expected: "No. Only owners can export.")
        value.criteriaOverride = ["States that members cannot export.", "Identifies the owner role."]
        value.documentEvidence = .init(sourceName: source.name, sourceDigest: source.fileDigest,
            passages: source.passages, citations: [.init(passageID: passage.id, quote: "Owners can export a workspace.")], questionType: "Apply a rule")
        if reviewed { value.acceptDocumentReview() }
        return value
    }
    static func suite() -> EvaluationSuite {
        var suite = EvaluationSuite()
        suite.cases = [example()]
        suite.modelConfiguration.contextPolicy = .requireFullInput
        suite.modelConfiguration.maximumResponseTokens = 512
        return suite
    }
}

struct EvaluationDocumentTests {
    @Test func sourceReviewTracksContentButNotDisplayNames() {
        var value = DocumentTestFixture.example()
        #expect(value.hasReviewedDocument)
        value.name = "Renamed"
        #expect(value.hasReviewedDocument)
        value.expected = "Members can export."
        #expect(!value.hasReviewedDocument)
        value.acceptDocumentReview()
        #expect(value.hasReviewedDocument)
        value.criteriaOverride?[0] = "Changed requirement"
        #expect(!value.hasReviewedDocument)
        value.acceptDocumentReview()
        value.documentEvidence?.passages[0].text += " Additional condition."
        #expect(!value.hasReviewedDocument)
    }

    @Test func versionedCasesRoundTripAndLegacyReadersRefuseThem() throws {
        struct OldCase: Decodable { var prompt: String; var expected: String }
        let value = DocumentTestFixture.example()
        let data = try CanonicalJSON.data(for: value)
        #expect(try CanonicalJSON.decode(EvaluationCase.self, from: data) == value)
        #expect(throws: (any Error).self) { try CanonicalJSON.decode(OldCase.self, from: data) }
        let normal = EvaluationCase(name: "Old", prompt: "Question", expected: "Answer")
        let oldData = try CanonicalJSON.data(for: normal)
        #expect(try CanonicalJSON.decode(OldCase.self, from: oldData).prompt == "Question")
        #expect(try CanonicalJSON.decode(EvaluationCase.self, from: oldData) == normal)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "documentEvidence")
        json.removeValue(forKey: "criteriaOverride")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try CanonicalJSON.decode(EvaluationCase.self, from: stripped) }
    }

    @Test func citationCanMoveToAddedContextWithoutLosingReviewIntegrity() {
        var value = DocumentTestFixture.example()
        let additional = EvaluationDocumentPassage(id: "page-7-1", location: "Page 7", text: "Workspace exports require the owner role.")
        value.documentEvidence?.passages.append(additional)
        value.documentEvidence?.citations[0].passageID = additional.id
        #expect(value.documentValidationIssue != nil)
        value.documentEvidence?.citations[0].quote = additional.text
        value.documentEvidence?.passages.removeAll { $0.id == DocumentTestFixture.passage.id }
        #expect(value.documentValidationIssue == nil)
        #expect(!value.hasReviewedDocument)
        value.acceptDocumentReview()
        #expect(value.hasReviewedDocument)
        var draft = EvaluationDocumentDraft(projectID: UUID(), name: "Guide", source: DocumentTestFixture.source,
            selectedPassageIDs: [DocumentTestFixture.passage.id])
        draft.cases = [.init(evaluationCase: value)]
        #expect(draft.representedPassageIDs.isEmpty)
    }

    @Test func criteriaFallbackAndScoringIdentityIncludeSourceAndOverrides() throws {
        var suite = DocumentTestFixture.suite()
        let ordinary = EvaluationCase(name: "Manual", prompt: "Question", expected: "Answer")
        suite.cases.append(ordinary)
        #expect(suite.effectiveCriteria(for: ordinary) == suite.rubricCriteria)
        #expect(suite.effectiveCriteria(for: suite.cases[0]) == suite.cases[0].criteriaOverride)
        let before = try EvaluationScoringContract(suite: suite)
        suite.cases[0].criteriaOverride?[0] = "A different requirement"
        #expect(try EvaluationScoringContract(suite: suite) != before)
        let changedCriteria = try EvaluationScoringContract(suite: suite)
        suite.cases[0].documentEvidence?.passages[0].text += " Exception."
        #expect(try EvaluationScoringContract(suite: suite) != changedCriteria)
        suite.cases[0].criteriaOverride = []
        #expect(suite.documentValidationIssue() != nil)
    }

    @Test func quotesMustResolveAndUnsafeExecutionModesAreRejected() {
        var suite = DocumentTestFixture.suite()
        #expect(suite.documentValidationIssue() == nil)
        suite.modelConfiguration.contextPolicy = .fitReferences
        #expect(suite.documentValidationIssue() != nil)
        suite.modelConfiguration.contextPolicy = .requireFullInput
        suite.modelConfiguration.referenceMode = .lookupTool
        #expect(suite.documentValidationIssue() != nil)
        suite.modelConfiguration.referenceMode = .inline
        suite.cases[0].documentEvidence?.citations[0].passageID = "invented"
        #expect(suite.cases[0].documentValidationIssue != nil)
        suite.cases[0].documentEvidence?.citations[0].passageID = DocumentTestFixture.passage.id
        suite.cases[0].documentEvidence?.citations[0].quote = "Members may export."
        #expect(suite.cases[0].documentValidationIssue != nil)
    }

    @Test func answeringGetsCompleteSourceButNoGradingFields() async throws {
        var suite = DocumentTestFixture.suite()
        suite.cases[0].expected = "REFERENCE_ONLY"
        suite.cases[0].criteriaOverride = ["CRITERION_ONLY"]
        suite.cases[0].acceptDocumentReview()
        let prepared = try await EvaluationRunner().preparedPrompt(for: suite.cases[0], suite: suite,
            images: [], contextSize: 32_768, tools: [], tokenCounter: DocumentTokenCounter())
        #expect(prepared.text.contains(DocumentTestFixture.passage.text))
        #expect(!prepared.text.contains("REFERENCE_ONLY"))
        #expect(!prepared.text.contains("CRITERION_ONLY"))
        #expect(!prepared.text.contains("reviewedDigest"))
        let judge = EvaluationRunner.judgePrompt(response: "Candidate", evaluationCase: suite.cases[0],
            effectivePrompt: prepared.text, suite: suite.effectiveSuite(for: suite.cases[0]), toolEvidence: nil)
        #expect(judge.contains("REFERENCE_ONLY"))
        #expect(judge.contains("CRITERION_ONLY"))
        #expect(judge.contains(DocumentTestFixture.passage.text))
    }

    @Test func localJudgeOverflowIsRejectedEvenWhenAnsweringFits() async throws {
        var suite = DocumentTestFixture.suite()
        suite.judgeConfiguration.mode = .connection
        _ = try await EvaluationRunner().preparedPrompt(for: suite.cases[0], suite: suite, images: [],
            contextSize: 4_096, tools: [], tokenCounter: DocumentTokenCounter(oversizedJudge: true))
        suite.judgeConfiguration.mode = .sameModel
        await #expect(throws: (any Error).self) {
            try await EvaluationRunner().preparedPrompt(for: suite.cases[0], suite: suite, images: [],
                contextSize: 4_096, tools: [], tokenCounter: DocumentTokenCounter(oversizedJudge: true))
        }
    }

    @Test func mixedExactAndSemanticCasesOnlyAdmitTheRequiredJudge() async throws {
        var suite = DocumentTestFixture.suite()
        suite.cases[0].criteriaOverride = ["The response is exactly READY."]
        var semantic = DocumentTestFixture.example()
        semantic.id = UUID()
        suite.cases.append(semantic)
        #expect(suite.needsModelJudge)
        #expect(!suite.effectiveSuite(for: suite.cases[0]).needsModelJudge)
        _ = try await EvaluationRunner().preparedPrompt(for: suite.cases[0], suite: suite, images: [],
            contextSize: 4_096, tools: [], tokenCounter: DocumentTokenCounter(oversizedJudge: true))
    }

    @Test(arguments: ["\n", "\r\n", "\u{2028}"])
    func overrideEntriesCannotIntroduceExtraCriteria(newline: String) {
        var suite = DocumentTestFixture.suite()
        suite.cases[0].criteriaOverride = ["First\(newline)Second"]
        #expect(suite.cases[0].documentValidationIssue != nil)
        #expect(suite.documentValidationIssue() != nil)
    }

    @Test func externalJudgeRequiresDeclaredCapacityAndPreservesEvidence() throws {
        var connection = EvaluationJudgeConnection(id: UUID(), name: "Test", kind: .localCompatible,
            baseURL: "http://127.0.0.1:1234", modelID: "fixture")
        let configuration = EvaluationCompatibleJudgeClient.requestConfiguration(for: connection, criteriaCount: 2)
        #expect(throws: (any Error).self) {
            try EvaluationCompatibleJudgeClient.validateDocumentBudget(prompt: "Evidence", configuration: configuration, connection: connection)
        }
        connection.capabilities.contextWindowTokens = 32_768
        try EvaluationCompatibleJudgeClient.validateDocumentBudget(prompt: "Evidence", configuration: configuration, connection: connection)
        #expect(throws: (any Error).self) {
            try EvaluationCompatibleJudgeClient.validateDocumentBudget(prompt: String(repeating: "x", count: 40_000), configuration: configuration, connection: connection)
        }
    }

    @Test func malformedAndDuplicateGeneratedDraftsCannotBeAccepted() throws {
        var candidate = EvaluationDocumentGenerator.Candidate(supported: true, name: "Export", question: "Can members export?",
            answer: "No.", criteria: ["Says no."], quotes: ["A fabricated quote."])
        #expect(throws: (any Error).self) {
            try EvaluationDocumentGenerator.validated(candidate, source: DocumentTestFixture.source,
                passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: [])
        }
        candidate.quotes = ["Owners can export a workspace."]
        let draft = try #require(try EvaluationDocumentGenerator.validated(candidate, source: DocumentTestFixture.source,
            passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: []))
        #expect(!draft.hasReviewedDocument)
        #expect(try EvaluationDocumentGenerator.validated(candidate, source: DocumentTestFixture.source,
            passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: ["CAN MEMBERS EXPORT!"]) == nil)
    }
}

private struct DocumentTokenCounter: EvaluationPromptInputTokenCounting {
    var oversizedJudge = false
    func tokenCount(for prompt: Prompt) async throws -> Int {
        oversizedJudge && String(describing: prompt).contains("candidateResponse:") ? 10_000 : 400
    }
    func tokenCount(for instructions: Instructions) async throws -> Int { 100 }
    func tokenCount(for schema: GenerationSchema) async throws -> Int { 100 }
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int { 0 }
    func tokenCount(for tools: [any Tool]) async throws -> Int { 0 }
    func tokenCount(forText text: String) async throws -> Int { 400 }
}
