import CryptoKit
import Foundation

enum EvaluationReviewError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

/// One view evaluation's review sources and latest labels, indexed by their run/sample identity.
struct EvaluationReviewProjection {
    var samples: [EvaluationReviewSample]
    var samplesByID: [String: EvaluationReviewSample]
    var annotationsByID: [String: EvaluationReviewAnnotation]
    var currentAnnotationsByID: [String: EvaluationReviewAnnotation]
}

/// Pure workflow shared by native review and agent proposals. Never changes run scores.
enum EvaluationReviewWorkflow {
    /// Collects reviewable samples for one suite in newest-run order, omitting sources whose digest cannot be encoded.
    static func samples(runs: [EvaluationRun], suiteID: UUID) -> [EvaluationReviewSample] {
        runs.filter { $0.suiteID == suiteID }.sorted {
            ($0.historySequence ?? 0, $0.startedAt) > ($1.historySequence ?? 0, $1.startedAt)
        }.flatMap { run in
            guard let context = try? SampleDigestContext(run: run) else { return [EvaluationReviewSample]() }
            return run.results.compactMap { sample in
                guard let digest = try? context.digest(for: sample) else { return nil }
                return EvaluationReviewSample(run: run, sample: sample, sourceDigest: digest)
            }
        }
    }

    /// Builds sources and label indexes once, checking each run's immutable evidence integrity once for presentation.
    /// Mutation boundaries still validate their supplied source independently through `isCurrent`.
    static func projection(runs: [EvaluationRun], suiteID: UUID, state: EvaluationReviewState) -> EvaluationReviewProjection {
        indexedProjection(samples: samples(runs: runs, suiteID: suiteID), state: state)
    }

    /// Indexes already-collected sources and labels without rescanning annotations or rechecking one run's evidence for each sample.
    private static func indexedProjection(samples: [EvaluationReviewSample], state: EvaluationReviewState) -> EvaluationReviewProjection {
        let annotations = state.annotations.reduce(into: [String: EvaluationReviewAnnotation]()) {
            $0["\($1.runID)/\($1.sampleID)"] = $1
        }
        var integrityByRun: [UUID: Bool] = [:]
        var current: [String: EvaluationReviewAnnotation] = [:]
        var sources: [String: EvaluationReviewSample] = [:]
        for sample in samples {
            if sources[sample.id] == nil { sources[sample.id] = sample }
            guard let annotation = annotations[sample.id], annotation.sourceDigest == sample.sourceDigest else { continue }
            let valid = integrityByRun[sample.run.id] ?? (sample.run.subjectEvidence?.hasValidDigest != false)
            integrityByRun[sample.run.id] = valid
            if valid { current[sample.id] = annotation }
        }
        return .init(samples: samples, samplesByID: sources, annotationsByID: annotations, currentAnnotationsByID: current)
    }

    /// Encodes run-wide source fields once while preserving the exact sorted-key v2 JSON used by saved annotations.
    /// Each sample supplies only its own encoded bytes between the shared prefix and suffix.
    private struct SampleDigestContext {
        var prefix: SHA256
        var suffix: Data

        /// Prepares canonical JSON fields around the sorted `sample` key, omitting optional values exactly as synthesized encoding does.
        init(run: EvaluationRun) throws {
            var fields: [(String, Data)] = []
            /// Encodes one named source field using the same canonical encoder as the original whole-source representation.
            func append<Value: Encodable>(_ name: String, _ value: Value) throws {
                var field = try CanonicalJSON.data(for: name, prettyPrinted: false)
                field.append(contentsOf: ":".utf8)
                field.append(try CanonicalJSON.data(for: value, prettyPrinted: false))
                fields.append((name, field))
            }
            try append("runID", run.id)
            try append("environment", run.environment)
            if let value = run.subjectEvidence { try append("subjectEvidence", value) }
            else { try append("legacySubjectEvidence", LegacySubjectEvidence(run: run)) }
            if let value = run.suiteDefinition { try append("subjectContext", Context(value)) }
            if let value = run.execution { try append("execution", value) }
            if let value = run.developerExecution { try append("developerExecution", value) }
            var before = Data("{".utf8)
            var after = Data()
            for (name, field) in fields.sorted(by: { $0.0 < $1.0 }) {
                if name < "sample" {
                    if before.count > 1 { before.append(contentsOf: ",".utf8) }
                    before.append(field)
                } else {
                    after.append(contentsOf: ",".utf8)
                    after.append(field)
                }
            }
            before.append(contentsOf: ",\"sample\":".utf8)
            after.append(contentsOf: "}".utf8)
            prefix = SHA256()
            prefix.update(data: before)
            suffix = after
        }

        /// Finishes one sample's source hash without re-encoding its run's shared evidence and execution context.
        func digest(for sample: EvaluationSampleResult) throws -> String {
            var hash = prefix
            hash.update(data: try CanonicalJSON.data(for: sample, prettyPrinted: false))
            hash.update(data: suffix)
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Hashes immutable source evidence and context while excluding selected or reassessed judgments.
    /// Legacy runs also bind their recorded instructions, cases and attachments; encoding failures propagate.
    static func sourceDigest(run: EvaluationRun, sample: EvaluationSampleResult) throws -> String {
        try sourceDigest(run: run, sample: sample, bindLegacyInputs: true)
    }

    /// Computes a canonical source digest, optionally binding legacy inputs for migration compatibility.
    /// Captured evidence snapshots keep their existing digest representation.
    private static func sourceDigest(run: EvaluationRun, sample: EvaluationSampleResult, bindLegacyInputs: Bool) throws -> String {
        struct Source: Encodable {
            var runID: UUID
            var sample: EvaluationSampleResult
            var subjectEvidence: EvaluationSubjectEvidenceSnapshot?
            var legacySubjectEvidence: LegacySubjectEvidence?
            var subjectContext: Context?
            var environment: EvaluationEnvironment
            var execution: EvaluationExecutionTrace?
            var developerExecution: EvaluationDeveloperExecution?
        }
        // Initial recorded evidence remains immutable; selected/reassessed judgments are excluded.
        // Omit the fallback for captured snapshots to preserve their existing review digests.
        return try digest(Source(runID: run.id, sample: sample, subjectEvidence: run.subjectEvidence,
                                 legacySubjectEvidence: bindLegacyInputs && run.subjectEvidence == nil ? LegacySubjectEvidence(run: run) : nil,
                                 subjectContext: run.suiteDefinition.map(Context.init),
                                 environment: run.environment, execution: run.execution,
                                 developerExecution: run.developerExecution))
    }

    /// Rebind old labels once, after verifying every field their original digest covered.
    /// Persist the returned state before exposing it; currentness never accepts a v1 fallback.
    static func migratingLegacySources(in state: EvaluationSuiteLocalState, runs: [EvaluationRun]) throws -> EvaluationSuiteLocalState? {
        let annotations = (state.review.annotations + state.review.proposals.map(\.annotation))
            .filter { $0.sourceDigestVersion == nil }
        guard !annotations.isEmpty else { return nil }
        let needed = Set(annotations.map { "\($0.runID)/\($0.sampleID)" })
        let runCounts = Dictionary(grouping: runs, by: \.id).mapValues(\.count)
        var digests: [String: (old: String, current: String)] = [:]
        for run in runs where run.subjectEvidence?.hasValidDigest != false && runCounts[run.id] == 1 {
            let sampleCounts = Dictionary(grouping: run.results, by: \.id).mapValues(\.count)
            for sample in run.results where sampleCounts[sample.id] == 1 {
                let key = "\(run.id)/\(sample.id)"
                guard needed.contains(key) else { continue }
                digests[key] = (try sourceDigest(run: run, sample: sample, bindLegacyInputs: false),
                                try sourceDigest(run: run, sample: sample))
            }
        }
        var upgradedReferences: [EvaluationRegressionSource: String] = [:]
        var changed = false
        /// Upgrades an unversioned annotation when its unique source is available, rebinding only a matching legacy digest.
        /// Tracks changed regression references so judge examples can follow the migrated review.
        func upgraded(_ annotation: EvaluationReviewAnnotation) -> EvaluationReviewAnnotation {
            guard annotation.sourceDigestVersion == nil,
                  let pair = digests["\(annotation.runID)/\(annotation.sampleID)"] else { return annotation }
            var value = annotation
            value.sourceDigestVersion = EvaluationReviewAnnotation.currentSourceDigestVersion
            changed = true
            if annotation.sourceDigest == pair.old {
                value.sourceDigest = pair.current
                upgradedReferences[.init(reviewID: annotation.id, runID: annotation.runID,
                    sampleID: annotation.sampleID, sourceDigest: annotation.sourceDigest)] = pair.current
            }
            return value
        }
        var candidate = state
        candidate.review.annotations = state.review.annotations.map(upgraded)
        for index in candidate.review.proposals.indices {
            candidate.review.proposals[index].annotation = upgraded(candidate.review.proposals[index].annotation)
        }
        for index in candidate.reviewedJudgeExamples.indices {
            let example = candidate.reviewedJudgeExamples[index]
            if var source = example.reviewSource, source.runID == example.sourceRunID,
               source.sampleID == example.sampleID, let current = upgradedReferences[source] {
                source.sourceDigest = current
                candidate.reviewedJudgeExamples[index].reviewSource = source
            }
        }
        return changed ? candidate : nil
    }

    /// Requires matching run, sample and source digest identities and rejects an explicitly invalid captured-evidence digest.
    static func isCurrent(_ annotation: EvaluationReviewAnnotation, sample: EvaluationReviewSample) -> Bool {
        annotation.runID == sample.run.id && annotation.sampleID == sample.sample.id
            && annotation.sourceDigest == sample.sourceDigest && sample.run.subjectEvidence?.hasValidDigest != false
    }

    /// Normalizes a current annotation and validates verdict evidence, required note and tag limits.
    /// Throws for stale sources or semantic verdicts on incomplete captures.
    static func validated(_ annotation: EvaluationReviewAnnotation, sample: EvaluationReviewSample) throws -> EvaluationReviewAnnotation {
        guard isCurrent(annotation, sample: sample) else { throw EvaluationReviewError.invalid("The saved source evidence changed. Review this output again.") }
        guard annotation.verdict == .needsEvidence || sample.sample.hasCompleteSubjectEvidenceForJudging else {
            throw EvaluationReviewError.invalid("Incomplete or failed captures need more evidence; they cannot receive a semantic pass or fail.")
        }
        var result = annotation
        result.sourceDigestVersion = EvaluationReviewAnnotation.currentSourceDigestVersion
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

    /// Collapses whitespace and lowercases a failure tag for consistent grouping.
    static func normalizedTag(_ tag: String) -> String {
        tag.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Validates and appends a review, moving updates to the end so they become the sample's current annotation.
    /// Throws for identity reuse with different evidence or a new annotation beyond the suite limit.
    static func save(_ annotation: EvaluationReviewAnnotation, sample: EvaluationReviewSample, state: inout EvaluationReviewState) throws {
        let validated = try validated(annotation, sample: sample)
        if let index = state.annotations.firstIndex(where: { $0.id == validated.id }) {
            let old = state.annotations[index]
            guard old.runID == validated.runID, old.sampleID == validated.sampleID,
                  old.sourceDigest == validated.sourceDigest else { throw EvaluationReviewError.invalid("A review ID already belongs to different evidence.") }
            // The last annotation for a sample is its current review, including
            // when a restored draft updates an older review ID.
            state.annotations.remove(at: index)
            state.annotations.append(validated)
        } else {
            guard state.annotations.count < 10_000 else { throw EvaluationReviewError.invalid("This suite has reached its review limit.") }
            state.annotations.append(validated)
        }
    }

    /// Adds a uniquely identified pending proposal with validated source evidence, enforcing the per-suite proposal limit.
    static func propose(_ proposal: EvaluationReviewProposal, sample: EvaluationReviewSample, state: inout EvaluationReviewState) throws {
        guard proposal.status == .pending, !state.proposals.contains(where: { $0.id == proposal.id }),
              state.proposals.count < 1_000 else { throw EvaluationReviewError.invalid("Proposal IDs must be new and the suite can hold up to 1,000 proposals.") }
        var proposed = proposal
        proposed.annotation = try validated(proposal.annotation, sample: sample)
        state.proposals.append(proposed)
    }

    /// Accepts or rejects one pending proposal; acceptance saves a current annotation before changing proposal status.
    /// Throws when the proposal is no longer pending or its accepted evidence is invalid.
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

    /// Groups current human-confirmed failures by tag, ordered by frequency and then tag text.
    static func patterns(samples: [EvaluationReviewSample], state: EvaluationReviewState) -> [EvaluationFailurePattern] {
        var groups: [String: [EvaluationReviewSample]] = [:]
        let projection = indexedProjection(samples: samples, state: state)
        for sample in samples {
            guard let annotation = projection.currentAnnotationsByID[sample.id], annotation.verdict == .failed else { continue }
            for tag in annotation.tags { groups[tag, default: []].append(sample) }
        }
        return groups.map { .init(tag: $0.key, samples: $0.value) }.sorted {
            $0.samples.count == $1.samples.count ? $0.tag < $1.tag : $0.samples.count > $1.samples.count
        }
    }

    /// Coverage representatives then stable shuffled picks, computing each sample's ordering hash once per projection.
    /// A discovery queue, never a prevalence estimate.
    static func diverseQueue(_ samples: [EvaluationReviewSample]) -> [EvaluationReviewSample] {
        let groups = Dictionary(grouping: samples) {
            "\($0.sample.caseID)/\($0.run.environment.model)/\($0.run.environment.locale)/\($0.sample.status.rawValue)"
        }
        let representatives = groups.keys.sorted().compactMap { groups[$0]?.first }
        let represented = Set(representatives.map(\.id))
        let remainder = samples.filter { !represented.contains($0.id) }
            .map { (sample: $0, order: stableOrder($0.id)) }
            .sorted { $0.order < $1.order }
            .map(\.sample)
        var queue: [EvaluationReviewSample] = []
        var index = 0
        for (offset, representative) in representatives.enumerated() {
            queue.append(representative)
            if offset % 2 == 1, index < remainder.count { queue.append(remainder[index]); index += 1 }
        }
        queue.append(contentsOf: remainder.dropFirst(index))
        return queue
    }

    /// Creates a new regression case only from a current confirmed failure with complete, unchanged source configuration.
    /// Validates local identities, attachments, expected text, scoring and capacity; records the originating review without mutating the suite.
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
        guard !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expected.count <= EvaluationStore.maximumFieldCharacters else {
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
        /// Captures the instruction, model and feature configuration that determines review-source context.
        init(_ definition: EvaluationSuiteDefinition) {
            instructions = definition.instructions
            model = definition.modelConfiguration
            features = definition.features
        }
    }

    private struct LegacySubjectEvidence: Encodable {
        var instructions: String
        var cases: [EvaluationCase]?
        var attachments: [EvaluationAttachmentTrace]
        /// Captures recorded legacy instructions, planned cases and attachments for source-digest migration.
        init(run: EvaluationRun) {
            instructions = run.instructions
            cases = run.plannedCases ?? run.suiteDefinition?.cases
            attachments = run.attachments
        }
    }

    /// Hashes only instruction, model and feature context to detect setup changes independently of case additions.
    private static func contextDigest(_ definition: EvaluationSuiteDefinition) throws -> String {
        try digest(Context(definition))
    }

    /// Requires historical local-model and file-search identities to match the current setup before creating a regression.
    /// Throws when the necessary execution trace is missing or differs.
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

    /// Validates a reviewed judge example against its original output digest and unambiguous saved assessment.
    /// Legacy examples without a review source retain their existing validation path.
    static func validateJudgeSource(_ example: EvaluationReviewedJudgeExample, run: EvaluationRun) throws {
        guard let source = example.reviewSource else { return } // Preserve legacy correction checks.
        guard source.runID == run.id, source.sampleID == example.sampleID,
              let sample = run.results.first(where: { $0.id == source.sampleID }),
              try source.sourceDigest == sourceDigest(run: run, sample: sample) else {
            throw EvaluationReviewError.invalid("The reviewed output changed. Review this source again before replaying its human label.")
        }
        guard let assessment = run.assessments?.first(where: { $0.id == example.sourceAssessmentID }) else {
            throw EvaluationReviewError.invalid("The reviewed assessment is no longer available.")
        }
        try validateJudgeAssessment(assessment, run: run)
    }

    /// Requires the assessment to belong to the run and have unique assessment and sample identities; throws on ambiguity.
    static func validateJudgeAssessment(_ assessment: EvaluationAssessment, run: EvaluationRun) throws {
        guard assessment.runID == run.id,
              run.assessments?.count(where: { $0.id == assessment.id }) == 1,
              Set(assessment.samples.map(\.sampleID)).count == assessment.samples.count else {
            throw EvaluationReviewError.invalid("The reviewed assessment has invalid or ambiguous source identities.")
        }
    }
    /// Hashes canonical JSON bytes with SHA-256, propagating encoding errors.
    private static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try CanonicalJSON.data(for: value, prettyPrinted: false)).map { String(format: "%02x", $0) }.joined()
    }
    /// Returns a deterministic SHA-256 ordering key for reproducible review-queue shuffling.
    private static func stableOrder(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
