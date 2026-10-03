import Foundation

struct MCPReviewSamplesArguments: Codable, Sendable {
    var suiteID: UUID
    var offset: Int?
    var limit: Int?
}
struct MCPReviewProposalArguments: Codable, Sendable {
    var suiteID: UUID
    var proposalID: UUID
    var runID: UUID
    var sampleID: UUID
    var sourceDigest: String
    var verdict: EvaluationReviewVerdict
    var note: String
    var tags: [String]
}

enum EvaluationReviewMCP {
    static let definitions: [MCPToolDefinition] = [
        .init(name: "eval_list_review_samples", title: "List saved review outputs",
              description: "Read a bounded page of captured samples and human reviews from the explicitly named current suite. Input/output previews are bounded; retrieve the saved run for complete evidence. Discovery ordering does not estimate failure prevalence.",
              inputSchema: schema([
                "suiteID": field("string"), "offset": field("integer"), "limit": field("integer")
              ], required: ["suiteID"]), annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false)),
        .init(name: "eval_propose_review", title: "Propose an output review",
              description: "Store a pending suggestion tied to the exact source digest. A person must accept or reject it in Review; proposals do not change human labels, scores, patterns, baselines or release checks. Reuse proposalID only for an identical retry.",
              inputSchema: schema([
                "suiteID": field("string"), "proposalID": field("string"), "runID": field("string"),
                "sampleID": field("string"), "sourceDigest": field("string"),
                "verdict": .object(["type": .string("string"), "enum": .array(EvaluationReviewVerdict.allCases.map { .string($0.rawValue) })]),
                "note": .object(["type": .string("string"), "minLength": .integer(1), "maxLength": .integer(4000)]),
                "tags": .object(["type": .string("array"), "maxItems": .integer(6),
                                 "items": .object(["type": .string("string"), "maxLength": .integer(60)])])
              ], required: ["suiteID", "proposalID", "runID", "sampleID", "sourceDigest", "verdict", "note", "tags"]),
              annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true))
    ]

    static func validate(_ arguments: MCPReviewSamplesArguments) throws {
        guard (0...10_000).contains(arguments.offset ?? 0), (1...20).contains(arguments.limit ?? 10) else {
            throw MCPToolInputError.invalidArguments
        }
    }
    static func validate(_ arguments: MCPReviewProposalArguments) throws {
        guard arguments.sourceDigest.count == 64,
              arguments.sourceDigest.allSatisfy({ "0123456789abcdef".contains($0) }),
              !arguments.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              arguments.note.count <= 4_000, arguments.tags.count <= 6,
              arguments.tags.allSatisfy({ $0.count <= 60 }) else { throw MCPToolInputError.invalidArguments }
    }

    @MainActor static func list(_ arguments: MCPReviewSamplesArguments, store: EvaluationStore) throws -> MCPToolPayload {
        guard arguments.suiteID == store.selectedSuiteID else { throw EvaluationReviewError.invalid("Select this suite before reading its review samples.") }
        let samples = EvaluationReviewWorkflow.diverseQueue(store.reviewSamples)
        let offset = arguments.offset ?? 0
        let limit = arguments.limit ?? 10
        let page = samples.dropFirst(offset).prefix(limit)
        let values = try page.map { sample -> MCPJSONValue in
            let annotation = store.suiteLocalState.review.annotation(runID: sample.run.id, sampleID: sample.sample.id)
            return .object([
                "runID": .string(sample.run.id.uuidString), "sampleID": .string(sample.sample.id.uuidString),
                "caseID": .string(sample.sample.caseID.uuidString), "caseName": .string(sample.sample.caseName),
                "sourceDigest": .string(sample.sourceDigest), "input": .string(String(sample.sample.prompt.prefix(4_000))),
                "output": .string(String(sample.sample.response.prefix(4_000))),
                "previewTruncated": .bool(sample.sample.prompt.count > 4_000 || sample.sample.response.count > 4_000),
                "completeCapture": .bool(sample.sample.hasCompleteSubjectEvidenceForJudging),
                "environment": try .encode(sample.run.environment),
                "humanReview": try annotation.map(MCPJSONValue.encode) ?? .null,
                "humanReviewCurrent": .bool(annotation.map { EvaluationReviewWorkflow.isCurrent($0, sample: sample) } ?? false)
            ])
        }
        return .init(structuredContent: .object(["samples": .array(values), "total": .integer(Int64(samples.count)),
            "nextOffset": offset + page.count < samples.count ? .integer(Int64(offset + page.count)) : .null]))
    }

    @MainActor static func propose(_ arguments: MCPReviewProposalArguments, store: EvaluationStore) throws -> MCPToolPayload {
        guard arguments.suiteID == store.selectedSuiteID else { throw EvaluationReviewError.invalid("Select this suite before proposing a review.") }
        if let existing = store.suiteLocalState.review.proposals.first(where: { $0.id == arguments.proposalID }) {
            guard existing.annotation.runID == arguments.runID, existing.annotation.sampleID == arguments.sampleID,
                  existing.annotation.sourceDigest == arguments.sourceDigest, existing.annotation.verdict == arguments.verdict,
                  existing.annotation.note == arguments.note.trimmingCharacters(in: .whitespacesAndNewlines),
                  existing.annotation.tags == Array(Set(arguments.tags.map(EvaluationReviewWorkflow.normalizedTag).filter { !$0.isEmpty })).sorted() else {
                throw EvaluationReviewError.invalid("This proposal ID belongs to a different suggestion.")
            }
            return payload(id: existing.id, status: existing.status, outcome: "duplicate")
        }
        let annotation = EvaluationReviewAnnotation(id: arguments.proposalID, runID: arguments.runID,
            sampleID: arguments.sampleID, sourceDigest: arguments.sourceDigest, verdict: arguments.verdict,
            note: arguments.note, tags: arguments.tags, updatedAt: Date())
        try store.proposeReview(.init(id: arguments.proposalID, annotation: annotation))
        return payload(id: arguments.proposalID, status: .pending, outcome: "committed")
    }

    private static func payload(id: UUID, status: EvaluationReviewProposalStatus, outcome: String) -> MCPToolPayload {
        .init(structuredContent: .object(["outcome": .string(outcome), "proposalID": .string(id.uuidString), "status": .string(status.rawValue)]))
    }
    private static func field(_ type: String) -> MCPJSONValue { .object(["type": .string(type)]) }
    private static func schema(_ properties: [String: MCPJSONValue], required: [String]) -> MCPJSONValue {
        .object(["$schema": .string("https://json-schema.org/draft/2020-12/schema"),
                 "type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false)])
    }
}
