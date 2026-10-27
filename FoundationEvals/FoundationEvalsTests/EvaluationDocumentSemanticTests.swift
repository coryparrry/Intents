import Foundation
import Testing
@testable import FoundationEvals

@MainActor struct EvaluationDocumentSemanticTests {
    /// Keep frozen controls independent of incidental generated citation identifiers while preserving factual evidence.
    @Test func compactAcceptanceFixturesDoNotRequireGeneratedCitationIDs() throws {
        let data = Data(#"{"sources":{},"controls":[{"id":"case","sourceID":"doc","question":"Question","reference":"Answer","citations":[{"passageID":"p","quote":"Source quote"}],"existingQuestions":[],"accepted":false}]}"#.utf8)
        let fixture = try CanonicalJSON.decode(EvaluationDocumentQualityTests.RegressionCorpus.self, from: data)
        #expect(fixture.controls.count == 1)
        #expect(fixture.controls[0].citations[0].quote == "Source quote")
    }

    /// Return the fixture review verdict so acceptance tests control each stage independently.
    private func review(_ value: EvaluationCase, passing: Bool = true) async throws -> EvaluationDocumentSemanticReview {
        var result = try await DocumentTestFixture.semanticReviewer(value, DocumentTestFixture.source, [])
        if !passing { result.checks[0].score = 2; result.checks[0].rationale = "Missing the source restriction." }
        return result
    }

    /// Require a failed review to inform a corrected generation attempt before exposing the candidate for acceptance.
    @Test func rejectedDraftIsRegeneratedWithFeedbackBeforeItCanSurface() async throws {
        let fixture = SemanticSequence()
        var events: [EvaluationDocumentSemanticAttempt] = []
        let result = try await EvaluationDocumentDraftPipeline.generate(source: DocumentTestFixture.source,
            passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: [], batchID: "test",
            generator: { _, _, _, _, feedback in await fixture.generate(feedback) },
            reviewer: { value, _, _ in try await fixture.review(value) }, record: { events.append($0) })
        #expect(result.candidate?.prompt == "Corrected question")
        #expect(events.map(\.outcome) == ["rejected", "accepted"])
        let feedback = await fixture.feedback
        #expect(feedback.count == 2)
        #expect(feedback[0] == nil)
        #expect(feedback[1]?.contains("Missing restriction") == true)
        let acceptedCandidate = try #require(result.candidate)
        #expect(result.review?.matches(acceptedCandidate) == true)
    }

    /// Bound correction work and refuse to surface a rejected candidate when the attempt budget is exhausted.
    @Test func rejectionLimitIsBoundedAndNeverReturnsTheLastBadDraft() async throws {
        let value = DocumentTestFixture.example(reviewed: false)
        let rejected = try await review(value, passing: false)
        var events: [EvaluationDocumentSemanticAttempt] = []
        let result = try await EvaluationDocumentDraftPipeline.generate(source: DocumentTestFixture.source,
            passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: [], batchID: "test",
            generator: { _, _, _, _, _ in value }, reviewer: { _, _, _ in rejected }, record: { events.append($0) })
        #expect(result.candidate == nil)
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.outcome == "rejected" })
    }

    /// Reject unsupported quotations locally before spending a semantic review request on the candidate.
    @Test func invalidQuotesReceiveBoundedCorrectionBeforeSemanticReview() async throws {
        let value = DocumentTestFixture.example(reviewed: false)
        let invalid = EvaluationDocumentGenerator.InvalidDraft(candidate: .init(name: "Bad quote",
            question: value.prompt, answer: value.expected, quotes: ["Invented quote"], supported: true),
            issue: "A supporting quote does not match the complete source.")
        var events: [EvaluationDocumentSemanticAttempt] = []
        let result = try await EvaluationDocumentDraftPipeline.generate(source: DocumentTestFixture.source,
            passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: [], batchID: "test",
            generator: { _, _, _, _, feedback in
                guard let feedback else { throw invalid }
                #expect(feedback.contains("Invented quote"))
                #expect(feedback.contains("does not match"))
                return value
            }, reviewer: DocumentTestFixture.semanticReviewer, record: { events.append($0) })
        #expect(result.candidate == value)
        #expect(events.map(\.outcome) == ["validation_rejected", "accepted"])
        #expect(events[0].review == nil)
        #expect(events[0].supportingQuotes == ["Invented quote"])
        events = []
        let exhausted = try await EvaluationDocumentDraftPipeline.generate(source: DocumentTestFixture.source,
            passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: [], batchID: "test",
            generator: { _, _, _, _, _ in throw invalid },
            reviewer: { _, _, _ in Issue.record("Invalid citations must never reach the judge"); throw URLError(.badURL) },
            record: { events.append($0) })
        #expect(exhausted.candidate == nil)
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.outcome == "validation_rejected" })
    }

    /// Fail closed on transport errors and stale receipts instead of accepting or silently retrying untrusted evidence.
    @Test func providerFailureAndMismatchedVerdictsCannotAcceptOrRegenerate() async throws {
        let value = DocumentTestFixture.example(reviewed: false)
        var mismatched = try await review(value)
        mismatched.candidateDigest = "different"
        let other = mismatched
        let reviewers: [EvaluationDocumentSemanticReviewer.Reviewer] = [
            { _, _, _ in throw URLError(.timedOut) }, { _, _, _ in other }
        ]
        for reviewer in reviewers {
            var events: [EvaluationDocumentSemanticAttempt] = []
            await #expect(throws: EvaluationDocumentDraftPipeline.ReviewUnavailable.self) {
                _ = try await EvaluationDocumentDraftPipeline.generate(source: DocumentTestFixture.source,
                    passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: [], batchID: "test",
                    generator: { _, _, _, _, _ in value }, reviewer: reviewer, record: { events.append($0) })
            }
            #expect(events.map(\.outcome) == ["review_error"])
        }
    }

    /// Keep a late reviewer response from committing acceptance after the operation has been cancelled.
    @Test func cancellationAfterReviewCannotPublishALateAcceptance() async throws {
        let value = DocumentTestFixture.example(reviewed: false)
        let accepted = try await review(value)
        let operation = Task {
            try await EvaluationDocumentDraftPipeline.generate(source: DocumentTestFixture.source,
                passage: DocumentTestFixture.passage, questionType: "Direct fact", existingQuestions: [], batchID: "test",
                generator: { _, _, _, _, _ in value }, reviewer: { _, _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return accepted
                }, record: { _ in Issue.record("Cancelled draft must not be recorded as accepted") })
        }
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
    }

    /// Require complete, uniquely indexed scores and rationales so malformed responses cannot approve a draft.
    @Test func strictVerdictParsingRejectsMissingDuplicateInvalidAndBlankChecks() throws {
        let checks = (1...6).map { ["criterionIndex": $0, "score": 4, "rationale": "Source supports it"] as [String: Any] }
        for variant in [Array(checks.dropLast()), checks + [checks[0]],
                        checks.dropLast() + [checks[0]],
                        checks.dropLast() + [["criterionIndex": 6, "score": 5, "rationale": "Invalid"]],
                        checks.dropLast() + [["criterionIndex": 6, "score": 4, "rationale": " "]]] {
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["requirements": variant]), as: UTF8.self)
            #expect(throws: (any Error).self) {
                try EvaluationDocumentSemanticReviewer.decode(raw, candidateDigest: "digest", connection: DocumentTestFixture.semanticConnection)
            }
        }
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["requirements": checks]), as: UTF8.self)
        let uncheckedQuestion = try EvaluationDocumentSemanticReviewer.decode(raw, candidateDigest: "digest", connection: DocumentTestFixture.semanticConnection)
        #expect(!uncheckedQuestion.accepted)
        #expect(uncheckedQuestion.checks.count == 6)
    }

    /// Bind approval to current scoring content and policy so a stale receipt cannot authorize suite publication.
    @Test func editsAndPolicyChangesInvalidateApprovalAndPublication() async throws {
        let original = DocumentTestFixture.example()
        let accepted = try await review(original)
        var draft = EvaluationDocumentDraft(projectID: UUID(), name: "Checked", source: DocumentTestFixture.source,
            selectedPassageIDs: [DocumentTestFixture.passage.id])
        draft.requiresSemanticReview = true
        draft.cases = [.init(evaluationCase: original, semanticReview: accepted)]
        #expect(draft.acceptedCases.count == 1)
        for field in ["question", "answer", "rubric", "source", "citation"] {
            var edited = original
            switch field {
            case "question": edited.prompt += " changed"
            case "answer": edited.expected += " changed"
            case "rubric": edited.criteriaOverride?[0] += " changed"
            case "source": edited.documentEvidence?.passages[0].text += " changed"
            default: edited.documentEvidence?.citations[0].quote = "Members can view reports but cannot export a workspace."
            }
            edited.acceptDocumentReview()
            draft.cases[0].evaluationCase = edited
            #expect(!accepted.matches(edited))
            #expect(draft.acceptedCases.isEmpty)
            #expect(throws: (any Error).self) { try draft.makeSuite() }
        }
        var stale = accepted; stale.policyVersion = "old"
        #expect(!stale.matches(original))
    }

    /// Recheck question history when a previously excluded sibling rejoins the draft.
    @Test func restoringAnExcludedSiblingRequiresANewDistinctnessCheck() async throws {
        let first = DocumentTestFixture.example()
        var second = first; second.id = UUID(); second.prompt = "Which documented role can export?"
        second.acceptDocumentReview()
        let firstReview = try await review(first)
        var secondReview = try await review(second)
        var draft = EvaluationDocumentDraft(projectID: UUID(), name: "Restore", source: DocumentTestFixture.source,
            selectedPassageIDs: [DocumentTestFixture.passage.id])
        draft.requiresSemanticReview = true
        draft.cases = [.init(evaluationCase: first, discarded: true, semanticReview: firstReview),
                       .init(evaluationCase: second, semanticReview: secondReview)]
        #expect(draft.acceptedCases.count == 1)
        draft.cases[0].discarded = false
        #expect(draft.acceptedCases.isEmpty)
        #expect(!draft.semanticReviewIsCurrent(for: second.id))
        // A newly approved distinct question covers both sides of the pair.
        second.prompt = "What can members do with reports?"; second.expected = "Members can view reports."
        second.acceptDocumentReview()
        secondReview = try await DocumentTestFixture.semanticReviewer(second, draft.source, [first.prompt])
        draft.cases[1] = .init(evaluationCase: second, semanticReview: secondReview)
        #expect(draft.acceptedCases.count == 2)
    }

    /// Refuse generation before model work begins when no semantic reviewer has been explicitly selected.
    @Test func noSelectedJudgeFailsClosedBeforeGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = EvaluationDocumentDraftController(directory: directory, projectID: UUID(),
            generate: { _, _, _, _, _ in Issue.record("Unauthorized generation"); return nil }, availability: { nil })
        controller.draft = .init(projectID: UUID(), name: "No authorization", source: DocumentTestFixture.source,
            selectedPassageIDs: [DocumentTestFixture.passage.id])
        controller.generate()
        await controller.waitUntilIdle()
        #expect(controller.draft?.cases.isEmpty == true)
        #expect(controller.error?.contains("semantic judge") == true)
    }

    /// Ensure the proposed answer cannot rescue an unsupported question or trigger a later reference-stage request.
    @Test func questionRejectionStopsBeforeReferenceCanInfluenceIt() async throws {
        var connection = DocumentTestFixture.semanticConnection
        connection.capabilities.structuredOutputs = true
        connection.capabilities.contextWindowTokens = 100_000
        let client = EvaluationCompatibleJudgeClient(transport: { request in
            let requestBytes = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: requestBytes) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(messages[0]["content"] == EvaluationDocumentSemanticReviewer.questionInstructions,
                "A rejected question must never reach the reference-review stage")
            let checks = (1...3).map { ["criterionIndex": $0, "score": $0 == 1 ? 2 : 4,
                "rationale": "The source gives a retention period, not post-deletion behavior."] as [String: Any] }
            let verdict = String(decoding: try JSONSerialization.data(withJSONObject: ["requirements": checks]), as: UTF8.self)
            let bytes = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": verdict]]]])
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (bytes, response)
        })
        let value = DocumentTestFixture.example(reviewed: false)
        let result = try await EvaluationDocumentSemanticReviewer.review(value, source: DocumentTestFixture.source,
            existingQuestions: [], resolved: .init(connection: connection, apiKey: "synthetic-test-key"), client: client)
        #expect(!result.accepted)
        #expect(result.checks.isEmpty)
        #expect(result.rawResponse.isEmpty)
        #expect(result.feedback.contains("post-deletion"))
        #expect(result.questionRawResponse != nil)
    }

    /// Keep source authority and review instructions independent from candidate text sent through the transport.
    @Test func reviewTransportUsesIndependentPolicyAndCompleteSource() async throws {
        var connection = DocumentTestFixture.semanticConnection
        connection.capabilities.structuredOutputs = true
        connection.capabilities.contextWindowTokens = 100_000
        connection.kind = .openRouter
        connection.baseURL = "https://openrouter.ai/api/v1"
        connection.providerOrder = ["test-provider"]
        let client = EvaluationCompatibleJudgeClient(transport: { request in
            let bytes = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let format = try #require(body["response_format"] as? [String: Any])
            let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: format, options: [.sortedKeys]), as: UTF8.self)
            #expect(schemaText.contains("\"minimum\":1"))
            let messages = try #require(body["messages"] as? [[String: String]])
            let questionOnly = messages[0]["content"] == EvaluationDocumentSemanticReviewer.questionInstructions
            #expect(questionOnly || messages[0]["content"] == EvaluationDocumentSemanticReviewer.instructions)
            #expect(schemaText.contains(questionOnly ? "\"maximum\":3" : "\"maximum\":6"))
            #expect(messages[1]["content"]?.contains(DocumentTestFixture.passage.text) == true)
            #expect(messages[1]["content"]?.contains("Existing question") == true)
            if questionOnly {
                let payload = try #require(messages[1]["content"]?.data(using: .utf8))
                let fields = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
                #expect(Set(fields.keys) == ["source", "question", "existingQuestions", "requirements"])
            }
            let checks = (1...(questionOnly ? 3 : 6)).map { ["criterionIndex": $0, "score": 4, "rationale": "Supported"] as [String: Any] }
            let verdict = String(decoding: try JSONSerialization.data(withJSONObject: ["requirements": checks]), as: UTF8.self)
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": verdict]]], "model": "served-test"])
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (data, response)
        })
        var source = DocumentTestFixture.source
        source.passages.append(.init(id: "second", location: "Page 2", text: "Exports are disabled during maintenance."))
        var value = DocumentTestFixture.example(reviewed: false)
        value.documentEvidence?.passages = Array(source.passages.reversed())
        let result = try await EvaluationDocumentSemanticReviewer.review(value, source: source,
            existingQuestions: ["Existing question"], resolved: .init(connection: connection, apiKey: "synthetic-test-key"), client: client)
        #expect(result.matches(value))
        #expect(result.servedModel == "served-test")
        #expect(result.questionServedModel == "served-test")
        #expect(result.questionChecks?.count == 3)
        value.documentEvidence?.passages.removeLast()
        await #expect(throws: (any Error).self) {
            try await EvaluationDocumentSemanticReviewer.review(value, source: source,
                existingQuestions: [], resolved: .init(connection: connection, apiKey: "synthetic-test-key"), client: client)
        }
    }
}

private actor SemanticSequence {
    var feedback: [String?] = []
    var reviews = 0
    /// Return the next scripted generation candidate without invoking an external or on-device model.
    func generate(_ message: String?) -> EvaluationCase {
        feedback.append(message)
        var value = DocumentTestFixture.example(reviewed: false)
        value.prompt = feedback.count == 1 ? "Bad question" : "Corrected question"
        return value
    }
    /// Return the fixture review verdict so acceptance tests control each stage independently.
    func review(_ value: EvaluationCase) async throws -> EvaluationDocumentSemanticReview {
        reviews += 1
        var result = try await DocumentTestFixture.semanticReviewer(value, DocumentTestFixture.source, [])
        if reviews == 1 { result.checks[0].score = 2; result.checks[0].rationale = "Missing restriction" }
        return result
    }
}
