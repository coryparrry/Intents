import Foundation

@MainActor
extension EvaluationStore {
    var reviewSamples: [EvaluationReviewSample] {
        EvaluationReviewWorkflow.samples(runs: runs, suiteID: selectedSuiteID)
    }

    /// Validates an annotation against its current saved sample and persists it through suite-local rollback.
    func saveReview(_ annotation: EvaluationReviewAnnotation) throws {
        let sample = try reviewSample(runID: annotation.runID, sampleID: annotation.sampleID)
        try updateReviewState { try EvaluationReviewWorkflow.save(annotation, sample: sample, state: &$0) }
    }

    /// Validates and persists a review proposal against its saved source sample without confirming the annotation.
    func proposeReview(_ proposal: EvaluationReviewProposal) throws {
        let sample = try reviewSample(runID: proposal.annotation.runID, sampleID: proposal.annotation.sampleID)
        try updateReviewState { try EvaluationReviewWorkflow.propose(proposal, sample: sample, state: &$0) }
    }

    /// Accepts or rejects an existing proposal against its current saved source and persists the decision.
    /// Throws when the proposal or its source is no longer available or workflow validation fails.
    func decideReviewProposal(id: UUID, accept: Bool) throws {
        guard let proposal = suiteLocalState.review.proposals.first(where: { $0.id == id }) else {
            throw EvaluationReviewError.invalid("The proposal is no longer available.")
        }
        let sample = try reviewSample(runID: proposal.annotation.runID, sampleID: proposal.annotation.sampleID)
        try updateReviewState { try EvaluationReviewWorkflow.decideProposal(id: id, accept: accept, sample: sample, state: &$0) }
    }

    /// Finds a saved review sample in the selected suite, throwing when either requested ID is unavailable.
    func reviewSample(runID: UUID, sampleID: UUID) throws -> EvaluationReviewSample {
        guard let sample = reviewSamples.first(where: { $0.run.id == runID && $0.sample.id == sampleID }) else {
            throw EvaluationReviewError.invalid("Choose a saved sample from the current suite.")
        }
        return sample
    }

    /// Adds a current human pass/fail review as a judge-check example for its selected AI rubric assessment.
    /// Requires current prompt/scoring/evidence integrity, replaces any example for that sample, and assigns the partition to every example of its case.
    func addReviewToJudgeChecks(reviewID: UUID, partition: EvaluationJudgeCheckPartition) throws {
        guard let annotation = suiteLocalState.review.annotations.first(where: { $0.id == reviewID }),
              let status = annotation.verdict.resultStatus else { throw EvaluationReviewError.invalid("A judge check needs a human pass or fail.") }
        let sample = try reviewSample(runID: annotation.runID, sampleID: annotation.sampleID)
        guard EvaluationReviewWorkflow.isCurrent(annotation, sample: sample), sample.sample.hasCompleteSubjectEvidenceForJudging,
              let assessment = sample.run.selectedAssessment,
              assessment.promptVersion == EvaluationRunner.judgePromptVersion,
              let contract = assessment.scoringContract,
              contract.scoringMode == .modelJudge,
              assessment.subjectEvidenceDigest == sample.run.subjectEvidence?.digest,
              sample.run.subjectEvidence?.hasValidDigest == true else {
            throw EvaluationReviewError.invalid("Choose a current AI rubric assessment in the run report before adding this judge check.")
        }
        try EvaluationReviewWorkflow.validateJudgeAssessment(assessment, run: sample.run)
        try validateReviewImageEvidence(sample.run)
        var state = suiteLocalState
        state.reviewedJudgeExamples.removeAll { $0.sourceRunID == annotation.runID && $0.sampleID == annotation.sampleID }
        state.reviewedJudgeExamples.append(.init(
            partition: partition, reviewSource: .init(reviewID: annotation.id, runID: annotation.runID,
                sampleID: annotation.sampleID, sourceDigest: annotation.sourceDigest), id: UUID(), sourceRunID: annotation.runID, sourceAssessmentID: assessment.id,
            sampleID: annotation.sampleID, expectedStatus: status, reason: annotation.note, createdAt: Date(),
            scoringContract: contract, subjectEvidenceDigest: sample.run.subjectEvidence?.digest
        ))
        try EvaluationReviewJudgePartitions.assign(partition, caseID: sample.sample.caseID, state: &state, runs: runs)
        try commitReviewLocalState(state)
    }

    /// Assigns the requested partition to all judge-check examples for the selected example's case and persists local state.
    /// Throws if the example or any required source is missing.
    func setJudgeCheckPartition(exampleID: UUID, partition: EvaluationJudgeCheckPartition) throws {
        guard let example = suiteLocalState.reviewedJudgeExamples.first(where: { $0.id == exampleID }) else {
            throw EvaluationReviewError.invalid("The judge example is no longer available.")
        }
        let sample = try reviewSample(runID: example.sourceRunID, sampleID: example.sampleID)
        var state = suiteLocalState
        try EvaluationReviewJudgePartitions.assign(partition, caseID: sample.sample.caseID, state: &state, runs: runs)
        try commitReviewLocalState(state)
    }

    /// Removes one judge example, including an unavailable source, without changing human reviews or other case partitions.
    /// Persists through the existing rollback path and rejects removal while execution or file work owns the suite.
    func removeJudgeCheckExample(id: UUID) throws {
        guard !isRunning, !isReassessing, !isProcessingFiles else {
            throw EvaluationReviewError.invalid("Wait for the current operation to finish before removing a judge example.")
        }
        guard suiteLocalState.reviewedJudgeExamples.contains(where: { $0.id == id }) else {
            throw EvaluationReviewError.invalid("The judge example is no longer available.")
        }
        var state = suiteLocalState
        state.reviewedJudgeExamples.removeAll { $0.id == id }
        try commitReviewLocalState(state)
    }
}

/// Every repetition and every saved run of one case belongs to a single partition.
enum EvaluationReviewJudgePartitions {
    /// Returns test when any saved example for this case is held out, otherwise development.
    /// Legacy corrections inherit an existing held-out partition.
    static func existing(caseID: UUID, state: EvaluationSuiteLocalState, runs: [EvaluationRun]) -> EvaluationJudgeCheckPartition {
        // A legacy correction inherits an existing held-out case, rather than leaking it into development.
        state.reviewedJudgeExamples.contains { example in
            (example.partition ?? .development) == .test
                && runs.first(where: { $0.id == example.sourceRunID })?.results
                    .first(where: { $0.id == example.sampleID })?.caseID == caseID
        } ? .test : .development
    }

    /// Assigns one partition to every example resolving to the case, across runs and repetitions.
    /// Throws if any example's saved run or sample is missing; callers persist a candidate copy only after success.
    static func assign(_ partition: EvaluationJudgeCheckPartition, caseID: UUID,
                       state: inout EvaluationSuiteLocalState, runs: [EvaluationRun]) throws {
        for index in state.reviewedJudgeExamples.indices {
            let example = state.reviewedJudgeExamples[index]
            guard let run = runs.first(where: { $0.id == example.sourceRunID }),
                  let sample = run.results.first(where: { $0.id == example.sampleID }) else {
                throw EvaluationReviewError.invalid("A judge example's source is missing. Restore it before changing partitions.")
            }
            if sample.caseID == caseID { state.reviewedJudgeExamples[index].partition = partition }
        }
    }
}
