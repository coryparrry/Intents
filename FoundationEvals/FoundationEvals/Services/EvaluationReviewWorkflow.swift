import CryptoKit
import Foundation

enum EvaluationReviewError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

/// Pure workflow shared by native review and agent proposals. Never changes run scores.
enum EvaluationReviewWorkflow {
    static func samples(runs: [EvaluationRun], suiteID: UUID) -> [EvaluationReviewSample] {
        runs.filter { $0.suiteID == suiteID }.sorted { $0.startedAt > $1.startedAt }.flatMap { run in
            run.results.compactMap { sample in
                guard let digest = try? sourceDigest(run: run, sample: sample) else { return nil }
                return EvaluationReviewSample(run: run, sample: sample, sourceDigest: digest)
            }
        }
    }

    static func sourceDigest(run: EvaluationRun, sample: EvaluationSampleResult) throws -> String {
        struct Source: Encodable {
            var runID: UUID
            var sample: EvaluationSampleResult
            var subjectEvidence: EvaluationSubjectEvidenceSnapshot?
            var subjectContext: Context?
            var environment: EvaluationEnvironment
            var execution: EvaluationExecutionTrace?
            var developerExecution: EvaluationDeveloperExecution?
        }
        // Initial recorded evidence remains immutable; selected/reassessed judgments are excluded.
        return try digest(Source(runID: run.id, sample: sample, subjectEvidence: run.subjectEvidence,
                                 subjectContext: run.suiteDefinition.map(Context.init),
                                 environment: run.environment, execution: run.execution,
                                 developerExecution: run.developerExecution))
    }

    static func isCurrent(_ annotation: EvaluationReviewAnnotation, sample: EvaluationReviewSample) -> Bool {
        annotation.runID == sample.run.id && annotation.sampleID == sample.sample.id
            && annotation.sourceDigest == sample.sourceDigest && sample.run.subjectEvidence?.hasValidDigest != false
    }

    static func validated(_ annotation: EvaluationReviewAnnotation, sample: EvaluationReviewSample) throws -> EvaluationReviewAnnotation {
        guard isCurrent(annotation, sample: sample) else { throw EvaluationReviewError.invalid("The saved source evidence changed. Review this output again.") }
        guard annotation.verdict == .needsEvidence || sample.sample.hasCompleteSubjectEvidenceForJudging else {
            throw EvaluationReviewError.invalid("Incomplete or failed captures need more evidence; they cannot receive a semantic pass or fail.")
        }
        var result = annotation
        result.note = annotation.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.note.isEmpty, result.note.count <= 4_000 else {
            throw EvaluationReviewError.invalid("Explain your review in 1–4,000 characters.")
        }
        guard annotation.tags.count <= 6 else { throw EvaluationReviewError.invalid("Use up to six failure tags.") }
        result.tags = Array(Set(annotation.tags.map(normalizedTag).filter { !$0.isEmpty })).sorted()
        guard result.tags.allSatisfy({ $0.count <= 60 && !$0.contains(where: { $0.isNewline }) }) else {
            throw EvaluationReviewError.invalid("Each tag must be at most 60 characters.")
        }
        return result
    }

    static func normalizedTag(_ tag: String) -> String {
        tag.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func save(_ annotation: EvaluationReviewAnnotation, sample: EvaluationReviewSample, state: inout EvaluationReviewState) throws {
        let validated = try validated(annotation, sample: sample)
        if let index = state.annotations.firstIndex(where: { $0.id == validated.id }) {
            let old = state.annotations[index]
            guard old.runID == validated.runID, old.sampleID == validated.sampleID,
                  old.sourceDigest == validated.sourceDigest else { throw EvaluationReviewError.invalid("A review ID already belongs to different evidence.") }
            state.annotations[index] = validated
        } else {
            guard state.annotations.count < 10_000 else { throw EvaluationReviewError.invalid("This suite has reached its review limit.") }
            state.annotations.append(validated)
        }
    }

    static func propose(_ proposal: EvaluationReviewProposal, sample: EvaluationReviewSample, state: inout EvaluationReviewState) throws {
        guard proposal.status == .pending, !state.proposals.contains(where: { $0.id == proposal.id }),
              state.proposals.count < 1_000 else { throw EvaluationReviewError.invalid("Proposal IDs must be new and the suite can hold up to 1,000 proposals.") }
        var proposed = proposal
        proposed.annotation = try validated(proposal.annotation, sample: sample)
        state.proposals.append(proposed)
    }

    static func decideProposal(id: UUID, accept: Bool, sample: EvaluationReviewSample, state: inout EvaluationReviewState) throws {
        guard let index = state.proposals.firstIndex(where: { $0.id == id }), state.proposals[index].status == .pending else {
            throw EvaluationReviewError.invalid("This proposal is no longer pending.")
        }
        if accept {
            var annotation = state.proposals[index].annotation
            annotation.id = state.annotation(runID: sample.run.id, sampleID: sample.sample.id).flatMap {
                isCurrent($0, sample: sample) ? $0.id : nil
            } ?? UUID()
            annotation.updatedAt = Date()
            try save(annotation, sample: sample, state: &state)
        }
        state.proposals[index].status = accept ? .accepted : .rejected
    }

    static func patterns(samples: [EvaluationReviewSample], state: EvaluationReviewState) -> [EvaluationFailurePattern] {
        var groups: [String: [EvaluationReviewSample]] = [:]
        for sample in samples {
            guard let annotation = state.annotation(runID: sample.run.id, sampleID: sample.sample.id),
                  annotation.verdict == .failed, isCurrent(annotation, sample: sample) else { continue }
            for tag in annotation.tags { groups[tag, default: []].append(sample) }
        }
        return groups.map { .init(tag: $0.key, samples: $0.value) }.sorted {
            $0.samples.count == $1.samples.count ? $0.tag < $1.tag : $0.samples.count > $1.samples.count
        }
    }

    /// Coverage representatives then stable shuffled picks. A discovery queue, never a prevalence estimate.
    static func diverseQueue(_ samples: [EvaluationReviewSample]) -> [EvaluationReviewSample] {
        let groups = Dictionary(grouping: samples) {
            "\($0.sample.caseID)/\($0.run.environment.model)/\($0.run.environment.locale)/\($0.sample.status.rawValue)"
        }
        let representatives = groups.keys.sorted().compactMap { groups[$0]?.first }
        let represented = Set(representatives.map(\.id))
        let remainder = samples.filter { !represented.contains($0.id) }.sorted {
            stableOrder($0.id) < stableOrder($1.id)
        }
        var queue: [EvaluationReviewSample] = []
        var index = 0
        for (offset, representative) in representatives.enumerated() {
            queue.append(representative)
            if offset % 2 == 1, index < remainder.count { queue.append(remainder[index]); index += 1 }
        }
        queue.append(contentsOf: remainder.dropFirst(index))
        return queue
    }

    static func regression(annotation: EvaluationReviewAnnotation, sample: EvaluationReviewSample,
                           suite: EvaluationSuite, expected: String) throws -> EvaluationCase {
        guard isCurrent(annotation, sample: sample), annotation.verdict == .failed,
              sample.sample.hasCompleteSubjectEvidenceForJudging,
              let evidence = sample.run.subjectEvidence, evidence.hasValidDigest,
              let original = evidence.cases.first(where: { $0.id == sample.sample.caseID }),
              let definition = sample.run.suiteDefinition else {
            throw EvaluationReviewError.invalid("A regression requires a confirmed failure and complete, unchanged source configuration.")
        }
        let currentAttachments = suite.attachments.map {
            EvaluationSubjectAttachmentSnapshot(id: $0.id, name: $0.name, kind: $0.kind,
                byteCount: $0.byteCount, sha256: $0.sha256, storedFilename: nil, text: $0.text)
        }
        let sourceAttachments = evidence.attachments.map { attachment in
            var value = attachment; value.storedFilename = nil; return value
        }
        try validateLocalContext(run: sample.run, suite: suite)
        guard try contextDigest(definition) == contextDigest(EvaluationSuiteDefinition(suite: suite)),
              sourceAttachments == currentAttachments else {
            throw EvaluationReviewError.invalid("The current instructions, model, features or attachments differ from this run. Restore its setup before creating a regression.")
        }
        let expected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty, expected.count <= EvaluationStore.maximumFieldCharacters else {
            throw EvaluationReviewError.invalid("Supply the correct expected response or verified reference answer.")
        }
        guard suite.scoringMode != .review || !(original.fieldAssertions ?? []).isEmpty else {
            throw EvaluationReviewError.invalid("Choose a scoring method in Setup before creating this regression case.")
        }
        guard suite.cases.count < EvaluationStore.maximumCases,
              suite.cases.count < EvaluationStore.maximumPlannedSamples / max(1, suite.repetitions) else {
            throw EvaluationReviewError.invalid("This suite has reached its planned-sample limit.")
        }
        var regression = original
        regression.id = UUID()
        regression.name = "Regression: " + original.name
        regression.expected = expected
        regression.reviewSource = .init(reviewID: annotation.id, runID: sample.run.id,
                                        sampleID: sample.sample.id, sourceDigest: sample.sourceDigest)
        return regression
    }

    private struct Context: Encodable {
        var instructions: String
        var model: EvaluationModelConfiguration
        var features: EvaluationFeatureConfiguration
        init(_ definition: EvaluationSuiteDefinition) {
            instructions = definition.instructions
            model = definition.modelConfiguration
            features = definition.features
        }
    }

    private static func contextDigest(_ definition: EvaluationSuiteDefinition) throws -> String {
        try digest(Context(definition))
    }

    private static func validateLocalContext(run: EvaluationRun, suite: EvaluationSuite) throws {
        let usesLocalModel = suite.modelConfiguration.provider == .coreAI
            || run.suiteDefinition?.modelConfiguration.provider == .coreAI
            || run.execution?.configuration.provider == .coreAI
        let usesLocalSearch = suite.features.spotlightSearch.enabled
            && suite.features.spotlightSearch.fileSource.enabled
        guard usesLocalModel || usesLocalSearch else { return }
        guard let execution = run.execution,
              (!usesLocalModel || execution.configuration == suite.modelConfiguration),
              (!usesLocalSearch || execution.features == suite.features) else {
            throw EvaluationReviewError.invalid("The historical local model or search-source identity is unavailable or changed. Capture this setup again before creating a regression.")
        }
    }

    static func validateJudgeSource(_ example: EvaluationReviewedJudgeExample, run: EvaluationRun) throws {
        guard let source = example.reviewSource else { return } // Preserve legacy correction checks.
        guard source.runID == run.id, source.sampleID == example.sampleID,
              let sample = run.results.first(where: { $0.id == source.sampleID }),
              try source.sourceDigest == sourceDigest(run: run, sample: sample) else {
            throw EvaluationReviewError.invalid("The reviewed output changed. Review this source again before replaying its human label.")
        }
    }
    private static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try CanonicalJSON.data(for: value, prettyPrinted: false)).map { String(format: "%02x", $0) }.joined()
    }
    private static func stableOrder(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
