import Foundation

enum EvaluationDocumentArchive {
    /// Export a bounded document-only suite after validating its evidence and removing provider bindings.
    static func data(for suite: EvaluationSuite) throws -> Data {
        guard !suite.cases.isEmpty, suite.cases.allSatisfy({ $0.documentEvidence != nil }) else {
            throw EvaluationStoreError.invalidSuite("This export supports suites containing only document cases. Mixed manual/document suites cannot be exported through this route.")
        }
        if let issue = suite.documentValidationIssue(requireReview: false) { throw EvaluationStoreError.invalidSuite(issue) }
        var portable = suite
        // Portable evidence never grants network access or transfers local model/judge bindings.
        portable.modelConfiguration = .init()
        portable.modelConfiguration.contextPolicy = .requireFullInput
        portable.modelConfiguration.maximumResponseTokens = 512
        portable.judgeConfiguration = .init()
        portable.features = .init()
        let data = try CanonicalJSON.data(for: portable)
        guard data.count <= EvaluationDocumentDraftStorage.maximumBytes else {
            throw EvaluationStoreError.invalidSuite("The document suite export exceeds 5 MB.")
        }
        return data
    }

    /// Import a bounded archive into an editable draft while retaining original evidence and requiring fresh review.
    static func draft(from data: Data, projectID: UUID) throws -> EvaluationDocumentDraft {
        guard data.count <= EvaluationDocumentDraftStorage.maximumBytes else { throw EvaluationStoreError.invalidSuite("The saved document suite exceeds 5 MB.") }
        let decoded = try CanonicalJSON.decode(EvaluationSuite.self, from: data)
        // Reuse export validation and strip provider bindings even when the input was authored outside Intents.
        let suite = try CanonicalJSON.decode(EvaluationSuite.self, from: self.data(for: decoded))
        guard suite.cases.count <= 100, let first = suite.cases.first?.documentEvidence else {
            throw EvaluationStoreError.invalidSuite("The file does not contain a supported document suite.")
        }
        var passages: [EvaluationDocumentPassage] = []
        for evaluationCase in suite.cases {
            guard let evidence = evaluationCase.documentEvidence, evidence.sourceDigest == first.sourceDigest else {
                throw EvaluationStoreError.invalidSuite("A document suite must reference one source snapshot.")
            }
            for passage in evidence.passages {
                if let previous = passages.first(where: { $0.id == passage.id }) {
                    guard previous == passage else { throw EvaluationStoreError.invalidSuite("The archive contains conflicting source passages.") }
                } else { passages.append(passage) }
            }
        }
        guard passages.count <= 512, passages.reduce(0, { $0 + $1.text.count }) <= 128_000 else {
            throw EvaluationStoreError.invalidSuite("The archived source exceeds the document selection limits.")
        }
        var draft = EvaluationDocumentDraft(projectID: projectID, name: suite.name,
            source: .init(name: first.sourceName, fileDigest: first.sourceDigest, passages: passages,
                warnings: ["Imported suite: each case keeps its own retained source context. Model and judge settings reset to on-device. Review imported cases before creating a new suite."]),
            selectedPassageIDs: Set(passages.map(\.id)))
        draft.importedTemplate = suite
        draft.cases = suite.cases.map { evaluationCase in
            var value = evaluationCase
            value.documentEvidence?.reviewedDigest = nil
            return .init(evaluationCase: value)
        }
        return draft
    }
}
