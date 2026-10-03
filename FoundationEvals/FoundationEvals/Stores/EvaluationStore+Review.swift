import Foundation

@MainActor
extension EvaluationStore {
    var reviewSamples: [EvaluationReviewSample] {
        EvaluationReviewWorkflow.samples(runs: runs, suiteID: selectedSuiteID)
    }

    func saveReview(_ annotation: EvaluationReviewAnnotation) throws {
        let sample = try reviewSample(runID: annotation.runID, sampleID: annotation.sampleID)
        try updateReviewState { try EvaluationReviewWorkflow.save(annotation, sample: sample, state: &$0) }
    }

    func proposeReview(_ proposal: EvaluationReviewProposal) throws {
        let sample = try reviewSample(runID: proposal.annotation.runID, sampleID: proposal.annotation.sampleID)
        try updateReviewState { try EvaluationReviewWorkflow.propose(proposal, sample: sample, state: &$0) }
    }

    func decideReviewProposal(id: UUID, accept: Bool) throws {
        guard let proposal = suiteLocalState.review.proposals.first(where: { $0.id == id }) else {
            throw EvaluationReviewError.invalid("The proposal is no longer available.")
        }
        let sample = try reviewSample(runID: proposal.annotation.runID, sampleID: proposal.annotation.sampleID)
        try updateReviewState { try EvaluationReviewWorkflow.decideProposal(id: id, accept: accept, sample: sample, state: &$0) }
    }

    func reviewSample(runID: UUID, sampleID: UUID) throws -> EvaluationReviewSample {
        guard let sample = reviewSamples.first(where: { $0.run.id == runID && $0.sample.id == sampleID }) else {
            throw EvaluationReviewError.invalid("Choose a saved sample from the current suite.")
        }
        return sample
    }

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

    func setJudgeCheckPartition(exampleID: UUID, partition: EvaluationJudgeCheckPartition) throws {
        guard let example = suiteLocalState.reviewedJudgeExamples.first(where: { $0.id == exampleID }) else {
            throw EvaluationReviewError.invalid("The judge example is no longer available.")
        }
        let sample = try reviewSample(runID: example.sourceRunID, sampleID: example.sampleID)
        var state = suiteLocalState
        try EvaluationReviewJudgePartitions.assign(partition, caseID: sample.sample.caseID, state: &state, runs: runs)
        try commitReviewLocalState(state)
    }
}

/// Every repetition and every saved run of one case belongs to a single partition.
enum EvaluationReviewJudgePartitions {
    static func existing(caseID: UUID, state: EvaluationSuiteLocalState, runs: [EvaluationRun]) -> EvaluationJudgeCheckPartition {
        // A legacy correction inherits an existing held-out case, rather than leaking it into development.
        state.reviewedJudgeExamples.contains { example in
            (example.partition ?? .development) == .test
                && runs.first(where: { $0.id == example.sourceRunID })?.results
                    .first(where: { $0.id == example.sampleID })?.caseID == caseID
        } ? .test : .development
    }

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
