import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

enum DocumentTestFixture {
    static let semanticConnection = EvaluationJudgeConnection(id: UUID(), name: "Test", kind: .customCompatible,
        baseURL: "https://example.invalid/v1", modelID: "test")
    static let semanticReviewer: EvaluationDocumentSemanticReviewer.Reviewer = { value, _, existing in
        let checks = (1...EvaluationDocumentSemanticReviewer.requirements.count).map {
            EvaluationDocumentSemanticReview.Check(criterionIndex: $0, score: 4, rationale: "Fixture approved")
        }
        return .init(policyVersion: EvaluationDocumentSemanticReviewer.version, candidateDigest: value.documentReviewDigest ?? "",
            connectionID: semanticConnection.id, connectionDigest: semanticConnection.disclosureDigest,
            modelID: "test", checks: checks, rawResponse: "fixture",
            reviewedQuestions: EvaluationDocumentSemanticReviewer.questionDigests(existing),
            questionChecks: (1...3).map { .init(criterionIndex: $0, score: 4, rationale: "Fixture question approved") })
    }

    static var passage: EvaluationDocumentPassage {
        .init(id: "page-6-1", location: "Page 6", text: "Owners can export a workspace. Members can view reports but cannot export a workspace.")
    }
    static var source: EvaluationDocumentSource {
        .init(name: "Guide.pdf", fileDigest: String(repeating: "a", count: 64), passages: [passage])
    }
    /// Create an isolated document case with synthetic source, citations, and scoring requirements.
    static func example(reviewed: Bool = true) -> EvaluationCase {
        var value = EvaluationCase(name: "Workspace exports", prompt: "Can members export a workspace, and which documented role can?", expected: "Members cannot export a workspace; owners can.")
        value.criteriaOverride = ["States that members cannot export.", "Identifies the owner role."]
        value.documentEvidence = .init(sourceName: source.name, sourceDigest: source.fileDigest,
            passages: source.passages, citations: [.init(passageID: passage.id, quote: "Owners can export a workspace.")], questionType: "Apply a rule")
        if reviewed { value.acceptDocumentReview() }
        return value
    }
    /// Create an isolated document suite whose source and rubric support deterministic assertions.
    static func suite() -> EvaluationSuite {
        var suite = EvaluationSuite()
        suite.cases = [example()]
        suite.modelConfiguration.contextPolicy = .requireFullInput
        suite.modelConfiguration.maximumResponseTokens = 512
        return suite
    }
}

struct EvaluationDocumentTests {
    /// Allow cosmetic renaming while requiring fresh approval for substantive changes to scoring evidence.
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

    /// Preserve document evidence on current readers and prevent older formats from silently dropping it.
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

    /// Permit explicit context additions while invalidating acceptance when a citation’s factual target changes.
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

    /// Bind scoring identity to effective case criteria and retained source while preserving the shared-rubric fallback.
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

    /// Require exact retained-source support and refuse execution configurations that cannot preserve document guarantees.
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

    /// Give the answering model factual context without leaking the reference answer or grading rubric.
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

    /// Check judge capacity independently so successful answering admission cannot hide scoring-context overflow.
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

    /// Admit a semantic judge only for requirements that cannot be resolved through literal matching.
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

    /// Size each isolated scoring request against its actual payload instead of an unused combined rubric.
    @Test func isolatedJudgeAdmissionDoesNotRequireTheCombinedRubricToFit() async throws {
        var suite = DocumentTestFixture.suite()
        suite.cases[0].criteriaOverride = ["First unique requirement", "Second unique requirement"]
        suite.cases[0].acceptDocumentReview()
        let counter = DocumentTokenCounter(combinedJudgeIsOversized: true)
        _ = try await EvaluationRunner().preparedPrompt(for: suite.cases[0], suite: suite, images: [],
            contextSize: 4_096, tools: [], tokenCounter: counter)
        let combined = EvaluationRunner.judgePrompt(response: "", evaluationCase: suite.cases[0],
            effectivePrompt: "Source", suite: suite.effectiveSuite(for: suite.cases[0]), toolEvidence: nil)
        #expect(try await counter.tokenCount(for: Prompt(combined)) == 10_000)
    }

    /// Keep a per-case override within the supported requirement count and prevent hidden rubric expansion.
    @Test(arguments: ["\n", "\r\n", "\u{2028}"])
    func overrideEntriesCannotIntroduceExtraCriteria(newline: String) {
        var suite = DocumentTestFixture.suite()
        suite.cases[0].criteriaOverride = ["First\(newline)Second"]
        #expect(suite.cases[0].documentValidationIssue != nil)
        #expect(suite.documentValidationIssue() != nil)
    }

    /// Require explicit external capacity before sending retained source and keep the evidence available for scoring.
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

    /// Reject repeated factual targets even when a model changes the question’s wording.
    @Test func paraphrasedQuestionsWithIdenticalFactsAreDuplicates() {
        let original = DocumentTestFixture.suite().cases[0]
        var reworded = original
        reworded.prompt = "A differently worded question about the same fact."
        #expect(EvaluationDocumentGenerator.repeatsFact(reworded, among: [original]))
        reworded.expected += " Rephrased target."
        #expect(EvaluationDocumentGenerator.repeatsFact(reworded, among: [original]))
        reworded = original
        reworded.criteriaOverride = ["A differently worded requirement."]
        #expect(EvaluationDocumentGenerator.repeatsFact(reworded, among: [original]))
        reworded.documentEvidence?.citations[0].quote = "A distinct source fact."
        #expect(!EvaluationDocumentGenerator.repeatsFact(reworded, among: [original]))
        reworded = original
        reworded.documentEvidence?.sourceDigest = String(repeating: "0", count: 64)
        #expect(!EvaluationDocumentGenerator.repeatsFact(reworded, among: [original]))
    }

    /// Recover the original source span across wrapping differences without accepting reworded quotations.
    @Test func generatedQuotesRecoverOnlyOriginalWhitespace() {
        let source = "Records under an\nactive hold stay for 30 days."
        #expect(EvaluationDocumentGenerator.sourceQuote("Records under an active hold stay for 30 days.", in: source) == source)
        #expect(EvaluationDocumentGenerator.sourceQuote("active hold stay for 30 days.", in: source) == "active hold stay for 30 days.")
        #expect(EvaluationDocumentGenerator.sourceQuote("Records under an active hold stay for 60 days.", in: source) == nil)
        #expect(EvaluationDocumentGenerator.sourceQuote("records under an active hold stay for 30 days.", in: source) == nil)
        #expect(EvaluationDocumentGenerator.sourceQuote("Records under an active hold stay for 30 days!", in: source) == nil)
        #expect(EvaluationDocumentGenerator.sourceQuote(" \n", in: source) == nil)
    }

    /// Retain relevant factual conditions in semantic criteria while allowing meaning-preserving paraphrases.
    @Test func generatedRubricsPreserveTheWholeAnswerWithoutLiteralMatching() throws {
        for answer in ["Only release-role operators may approve.",
                       "Retry with exponential backoff, starting at one second and capped at one minute.",
                       "Press any control-panel button.\nThe printer wakes."] {
            let criterion = EvaluationDocumentGenerator.criterion(for: answer, question: "What is the documented rule?")
            #expect(criterion.contains(answer.split(whereSeparator: \.isWhitespace).joined(separator: " ")))
            let containsNewline = criterion.contains(where: \.isNewline)
            #expect(!containsNewline)
            #expect(EvaluationExactCriterion.expectedText(in: criterion) == nil)
        }
    }

    /// Allow an explicitly requested exception to cite its supporting passage outside the generation focus.
    @Test func generatedQuotesCanCiteRequestedExceptionsFromOtherPassages() throws {
        let focus = EvaluationDocumentPassage(id: "frequency", location: "Page 1", text: "Autosave runs every 60 seconds with unsaved changes.")
        let exception = EvaluationDocumentPassage(id: "exception", location: "Page 2", text: "Autosave does not run in read-only mode.")
        let source = EvaluationDocumentSource(name: "Editor.txt", fileDigest: String(repeating: "a", count: 64), passages: [focus, exception])
        var candidate = EvaluationDocumentGenerator.Candidate(name: "Autosave",
            question: "How often does autosave run, and what changes in read-only mode?",
            answer: "Every 60 seconds with unsaved changes, but never in read-only mode.",
            quotes: [focus.text, exception.text], supported: true)
        let value = try #require(try EvaluationDocumentGenerator.validated(candidate, source: source,
            passage: focus, questionType: "Direct fact", existingQuestions: []))
        #expect(value.documentEvidence?.citations.map(\.passageID) == [focus.id, exception.id])
        candidate.quotes = [focus.text, exception.text, focus.text]
        let deduplicated = try #require(try EvaluationDocumentGenerator.validated(candidate, source: source,
            passage: focus, questionType: "Direct fact", existingQuestions: []))
        #expect(deduplicated.documentEvidence?.citations.map(\.passageID) == [focus.id, exception.id])
        for invalid in [[exception.text], [focus.text, "Runs every 30 seconds."]] {
            candidate.quotes = invalid
            #expect(throws: (any Error).self) {
                try EvaluationDocumentGenerator.validated(candidate, source: source, passage: focus,
                    questionType: "Direct fact", existingQuestions: [])
            }
        }
    }

    /// Retain background qualifications without treating their presence as accepted question coverage.
    @Test func generatedContextKeepsExceptionsWithoutClaimingTheyWereCovered() throws {
        var source = DocumentTestFixture.source
        let exception = EvaluationDocumentPassage(id: "exception", location: "Page 2", text: "Exports are disabled during maintenance.")
        source.passages.append(exception)
        let candidate = EvaluationDocumentGenerator.Candidate(name: "Export", question: "Who can export outside maintenance?",
            answer: "Owners can export outside maintenance.", quotes: ["Owners can export a workspace."], supported: true)
        var value = try #require(try EvaluationDocumentGenerator.validated(candidate, source: source,
            passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: []))
        #expect(value.documentEvidence?.passages == source.passages)
        #expect(value.criteriaOverride == [EvaluationDocumentGenerator.criterion(for: candidate.answer, question: candidate.question)])
        value.acceptDocumentReview()
        var draft = EvaluationDocumentDraft(projectID: UUID(), name: "Fixture", source: source,
            selectedPassageIDs: Set(source.passages.map(\.id)))
        draft.cases = [.init(evaluationCase: value)]
        #expect(draft.representedPassageIDs == [DocumentTestFixture.passage.id])
        #expect(draft.coverageLabel(for: exception.id) == "Not yet considered")
        #expect(throws: (any Error).self) {
            try EvaluationDocumentGenerator.validated(candidate, source: DocumentTestFixture.source,
                passage: exception, questionType: "Direct fact", existingQuestions: [])
        }
    }

    /// Reject invalid fields and duplicate candidates before they enter the accepted draft set.
    @Test func malformedAndDuplicateGeneratedDraftsCannotBeAccepted() throws {
        var candidate = EvaluationDocumentGenerator.Candidate(name: "Export", question: "Can members export?",
            answer: "Members cannot export.", quotes: ["A fabricated quote."], supported: true)
        #expect(throws: (any Error).self) {
            try EvaluationDocumentGenerator.validated(candidate, source: DocumentTestFixture.source,
                passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: [])
        }
        candidate.quotes = ["Owners can export a workspace."]
        let draft = try #require(try EvaluationDocumentGenerator.validated(candidate, source: DocumentTestFixture.source,
            passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: []))
        #expect(!draft.hasReviewedDocument)
        let fallback = try #require(try EvaluationDocumentGenerator.validated(candidate, source: DocumentTestFixture.source,
            passage: DocumentTestFixture.passage, questionType: "Apply a rule", existingQuestions: []))
        #expect(fallback.documentEvidence?.questionType == "Direct fact")
        #expect(fallback.documentEvidence?.requestedQuestionType == "Apply a rule")
        var extraQuote = candidate
        extraQuote.quotes.append(candidate.quotes[0])
        let deduplicated = try #require(try EvaluationDocumentGenerator.validated(extraQuote, source: DocumentTestFixture.source,
            passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: []))
        #expect(deduplicated.documentEvidence?.citations.count == 1)
        #expect(!deduplicated.hasReviewedDocument)
        candidate.questionType = "Invented category"
        #expect(throws: (any Error).self) {
            try EvaluationDocumentGenerator.validated(candidate, source: DocumentTestFixture.source,
                passage: DocumentTestFixture.passage, questionType: "Apply a rule", existingQuestions: [])
        }
        candidate.questionType = "Direct fact"
        #expect(try EvaluationDocumentGenerator.validated(candidate, source: DocumentTestFixture.source,
            passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: ["CAN MEMBERS EXPORT!"]) == nil)
    }
}

private struct DocumentTokenCounter: EvaluationPromptInputTokenCounting {
    var oversizedJudge = false
    var combinedJudgeIsOversized = false
    /// Return a controlled token estimate so admission and context-budget boundaries remain reproducible.
    func tokenCount(for prompt: Prompt) async throws -> Int {
        if combinedJudgeIsOversized, String(describing: prompt).contains("First unique requirement"),
           String(describing: prompt).contains("Second unique requirement") { return 10_000 }
        return oversizedJudge && (String(describing: prompt).contains("candidateResponse:")
            || String(describing: prompt).contains("candidateAnswer")) ? 10_000 : 400
    }
    /// Return a controlled token estimate so admission and context-budget boundaries remain reproducible.
    func tokenCount(for instructions: Instructions) async throws -> Int { 100 }
    /// Return a controlled token estimate so admission and context-budget boundaries remain reproducible.
    func tokenCount(for schema: GenerationSchema) async throws -> Int { 100 }
    /// Return a controlled token estimate so admission and context-budget boundaries remain reproducible.
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int { 0 }
    /// Return a controlled token estimate so admission and context-budget boundaries remain reproducible.
    func tokenCount(for tools: [any Tool]) async throws -> Int { 0 }
    /// Return a controlled token estimate so admission and context-budget boundaries remain reproducible.
    func tokenCount(forText text: String) async throws -> Int { 400 }
}
