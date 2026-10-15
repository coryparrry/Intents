import Foundation
import CryptoKit

/// Standalone workflow boundaries around the app's own evaluators and frozen contracts.
@available(macOS 27.0, *)
enum AppEngineWorkflows {
    struct ExperimentRequest: Decodable, Sendable {
        var suite: EvaluationSuite
        var candidateInstructions: String? = nil
        var name: String? = nil
        var experiment: EvaluationExperiment? = nil
        var images: [AppEngineBridge.ImageInput]? = nil
        var emitEvents: Bool? = nil
        var currentRunID: UUID? = nil
        var candidateRunID: UUID? = nil
    }
    struct ExperimentOutput: Encodable, Sendable {
        var experiment: EvaluationExperiment
        var current: EvaluationRun
        var candidate: EvaluationRun
        var summary: EvaluationExperimentSummary
    }
    struct ComparisonRequest: Decodable { var current: EvaluationRun; var baseline: EvaluationRun }
    struct SummaryRequest: Decodable { var current: EvaluationRun; var candidate: EvaluationRun }
    struct ReleaseRequest: Decodable {
        var projectID: UUID
        var suite: EvaluationSuite
        var run: EvaluationRun? = nil
        var baseline: EvaluationRun? = nil
        var approvedBaseline: EvaluationBaselineApproval? = nil
    }
    struct ReleaseOutput: Encodable { var report: EvaluationReleaseCheckReport; var markdown: String }
    struct ProjectReleaseRequest: Decodable { var projectID: UUID; var suites: [EvaluationProjectReleaseSuiteReport] }
    struct ProjectReleaseOutput: Encodable { var report: EvaluationProjectReleaseCheckReport; var markdown: String }
    struct BaselineRequest: Decodable {
        var suite: EvaluationSuite
        var run: EvaluationRun
        var assessmentID: UUID? = nil
        var note: String? = nil
    }
    struct CorrectionRequest: Decodable {
        var suite: EvaluationSuite
        var run: EvaluationRun
        var assessmentID: UUID? = nil
        var sampleID: UUID
        var correctedStatus: EvaluationResultStatus
        var correctedScore: Int? = nil
        var reason: String
        var reviewer: String? = nil
        var collectAsJudgeCheck: Bool? = nil
    }
    struct CorrectionOutput: Encodable {
        var run: EvaluationRun
        var correction: EvaluationHumanCorrection
        var reviewedJudgeExample: EvaluationReviewedJudgeExample? = nil
    }
    struct SelectionRequest: Decodable { var run: EvaluationRun; var assessmentID: UUID }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try CanonicalJSON.data(for: value, prettyPrinted: false)).map { String(format: "%02x", $0) }.joined()
    }
    static func createExperiment(_ request: ExperimentRequest) throws -> EvaluationExperiment {
        guard let instructions = request.candidateInstructions else { throw RunnerFailure.validation("Provide candidate instructions.") }
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != request.suite.instructions else {
            throw RunnerFailure.validation("Enter candidate instructions that differ from the current instructions.")
        }
        var candidateSuite = request.suite
        candidateSuite.instructions = trimmed
        if let issue = AppEngineValidation.validationIssue(for: request.suite, includeModelReadiness: false)
            ?? AppEngineValidation.validationIssue(for: candidateSuite, includeModelReadiness: false) {
            throw RunnerFailure.validation(issue)
        }
        let sourceRevision = try AppEngineBridge.revision(for: request.suite)
        let current = EvaluationExperimentVariant(id: UUID(), name: "Current", instructions: request.suite.instructions, suiteRevision: sourceRevision)
        let candidate = EvaluationExperimentVariant(id: UUID(), name: "Candidate", instructions: trimmed, suiteRevision: try AppEngineBridge.revision(for: candidateSuite))
        return EvaluationExperiment(id: UUID(), name: request.name ?? "Instruction experiment", createdAt: Date(), suiteRevision: sourceRevision,
            casesDigest: try digest(request.suite.cases),
            scoringDigest: try digest([request.suite.scoringMode.rawValue, request.suite.criteria]),
            judgeDigest: try digest(request.suite.judgeConfiguration), current: current, candidate: candidate,
            executionOrder: EvaluationExperimentAnalyzer.balancedOrder(currentID: current.id, candidateID: candidate.id,
                caseCount: request.suite.cases.count, repetitions: request.suite.repetitions), runIDs: [], decision: nil)
    }
    static func runExperiment(_ request: ExperimentRequest) async throws -> ExperimentOutput {
        var experiment = try request.experiment ?? createExperiment(request)
        let suite = request.suite
        if let issue = AppEngineValidation.validationIssue(for: suite, includeModelReadiness: false) {
            throw RunnerFailure.validation(issue)
        }
        let trimmed = experiment.candidate.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == experiment.candidate.instructions, trimmed != suite.instructions else {
            throw RunnerFailure.validation("The frozen candidate instructions must be nonempty, trimmed, and different from current instructions.")
        }
        let revision = try AppEngineBridge.revision(for: suite)
        guard experiment.suiteRevision == revision,
              experiment.current.instructions == suite.instructions,
              experiment.casesDigest == (try digest(suite.cases)),
              experiment.scoringDigest == (try digest([suite.scoringMode.rawValue, suite.criteria])),
              experiment.judgeDigest == (try digest(suite.judgeConfiguration)),
              experiment.current.id != experiment.candidate.id,
              experiment.executionOrder == EvaluationExperimentAnalyzer.balancedOrder(currentID: experiment.current.id,
                candidateID: experiment.candidate.id, caseCount: suite.cases.count, repetitions: suite.repetitions) else {
            throw RunnerFailure.validation("The suite changed after the experiment was frozen, or its frozen order/digests are invalid.")
        }
        var candidateSuite = suite
        candidateSuite.instructions = experiment.candidate.instructions
        guard experiment.current.suiteRevision == revision,
              experiment.candidate.suiteRevision == (try AppEngineBridge.revision(for: candidateSuite)) else {
            throw RunnerFailure.validation("The frozen experiment variant revisions do not match their instructions.")
        }
        if let issue = AppEngineValidation.validationIssue(for: suite, includeModelReadiness: false)
            ?? AppEngineValidation.validationIssue(for: candidateSuite, includeModelReadiness: false) {
            throw RunnerFailure.validation(issue)
        }
        let images = try AppEngineBridge.resolveImages(suite: suite, inputs: request.images ?? [])
        let currentID = request.currentRunID ?? UUID()
        let candidateID = request.candidateRunID ?? UUID()
        guard currentID != candidateID else { throw RunnerFailure.validation("Experiment variant run IDs must differ.") }
        let actor = EvaluationRunner()
        let runner = EvaluationExperimentRunner(runPart: { id, revision, date, one, images, progress in
            await actor.run(id: id, suiteRevision: revision, startedAt: date, suite: one, images: images,
                liveResponse: { value in
                    if request.emitEvents == true { AppEngineBridge.event(AppEngineBridge.LiveEvent(value: value, runID: id)) }
                }, progress: progress)
        })
        let frozen = experiment
        let result = try await runner.run(suite: suite, experiment: experiment, images: images,
            currentRunID: currentID, candidateRunID: candidateID,
            progress: { result, completed, total in
                if request.emitEvents == true {
                    let variantID = frozen.executionOrder[completed - 1]
                    let runID = variantID == frozen.current.id ? currentID : candidateID
                    AppEngineBridge.event(AppEngineBridge.SampleEvent(result: result, completed: completed, total: total, runID: runID))
                }
            })
        experiment.runIDs = [result.current.id, result.candidate.id]
        return ExperimentOutput(experiment: experiment, current: result.current, candidate: result.candidate,
            summary: EvaluationExperimentAnalyzer.summarize(current: result.current, candidate: result.candidate))
    }
    static func summarizeExperiment(_ request: SummaryRequest) throws -> EvaluationExperimentSummary {
        let current = request.current
        let candidate = request.candidate
        guard current.suiteID == candidate.suiteID,
              current.repetitions == candidate.repetitions,
              try summaryScoringContract(for: current) == summaryScoringContract(for: candidate) else {
            throw RunnerFailure.validation("Experiment summaries require matching saved cases, repetitions, and scoring conditions.")
        }
        if try summaryJudgeIdentity(for: current) != summaryJudgeIdentity(for: candidate) {
            throw RunnerFailure.validation("Experiment summaries require the same judge identity for both variants.")
        }
        return EvaluationExperimentAnalyzer.summarize(current: current, candidate: candidate)
    }

    private static func summaryScoringContract(for run: EvaluationRun) throws -> EvaluationScoringContract {
        guard let cases = run.plannedCases ?? run.suiteDefinition?.cases,
              !cases.isEmpty, Set(cases.map(\.id)).count == cases.count else {
            throw RunnerFailure.validation("Experiment summaries require saved, uniquely identified case definitions.")
        }
        let contract = try EvaluationScoringContract(run: run)
        if run.scoringMode == .modelJudge, let assessment = run.selectedAssessment {
            let assessedContract = try EvaluationScoringContract(
                scoringMode: run.scoringMode,
                rubricCriteria: assessment.rubric.split(whereSeparator: \Character.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                judgePromptVersion: assessment.promptVersion,
                judgePassingScore: assessment.passingScore,
                cases: cases
            )
            guard assessment.runID == run.id,
                  assessment.scoringContract.map({ $0 == assessedContract }) != false else {
                throw RunnerFailure.validation("The selected assessment does not match the run's scoring conditions.")
            }
            return assessedContract
        }
        return contract
    }

    private static func summaryJudgeIdentity(for run: EvaluationRun) throws -> EvaluationJudgeIdentity? {
        guard run.scoringMode == .modelJudge else { return nil }
        let identities: [EvaluationJudgeIdentity]
        if let assessment = run.selectedAssessment {
            identities = (assessment.observedJudgeIdentities ?? []) + [assessment.judge]
        } else {
            guard run.selectedAssessmentID == nil else {
                throw RunnerFailure.validation("The selected experiment assessment is unavailable.")
            }
            let scoredSamples = run.effectiveResults.filter { $0.status == .passed || $0.status == .failed }
            guard scoredSamples.allSatisfy({ $0.judgeIdentity != nil }) else {
                throw RunnerFailure.validation("Saved model-judged samples require known judge identities before experiment comparison.")
            }
            identities = scoredSamples.compactMap(\.judgeIdentity)
        }
        guard identities.allSatisfy({ identity in
            identity.mode == .sameModel
                && !identity.requestedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (identity.provider == nil || identity.provider == "onDevice"
                    || (identity.requestedModelID == "none" && identity.provider == "local"))
        }) else {
            throw RunnerFailure.validation("Experiment summaries support only identified on-device or deterministic judges.")
        }
        // Objective-only cases need no model request. Mixed objective/semantic
        // runs use the actual model identity, matching initial-assessment capture.
        let modelIdentities = identities.filter { $0.requestedModelID != "none" }
        let considered = modelIdentities.isEmpty ? identities : modelIdentities
        guard let identity = considered.first else { return nil }
        if modelIdentities.isEmpty {
            let rubric = (run.selectedAssessment?.rubric ?? run.criteria)
                .split(whereSeparator: \Character.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !rubric.isEmpty,
                  rubric.allSatisfy({ EvaluationExactCriterion.expectedText(in: $0) != nil }) else {
                throw RunnerFailure.validation("A no-model judge identity requires an entirely deterministic rubric.")
            }
        }
        guard considered.allSatisfy({ $0 == identity }) else {
            throw RunnerFailure.validation("An experiment variant contains conflicting judge identities.")
        }
        return identity
    }

    static func releaseCheck(_ request: ReleaseRequest) throws -> ReleaseOutput {
        let report = EvaluationReleaseCheckEvaluator.report(projectID: request.projectID, suite: request.suite,
            currentSuiteRevision: try AppEngineBridge.revision(for: request.suite), run: request.run,
            baseline: request.baseline, approvedBaseline: request.approvedBaseline)
        return ReleaseOutput(report: report, markdown: EvaluationReleaseCheckEvaluator.markdown(report))
    }
    static func projectReleaseCheck(_ request: ProjectReleaseRequest) -> ProjectReleaseOutput {
        let report = EvaluationReleaseCheckEvaluator.projectReport(projectID: request.projectID, suites: request.suites)
        return ProjectReleaseOutput(report: report, markdown: EvaluationReleaseCheckEvaluator.projectMarkdown(report))
    }
    static func approveBaseline(_ request: BaselineRequest) throws -> EvaluationBaselineApproval {
        let run = request.run
        let assessmentID = request.assessmentID ?? run.selectedAssessmentID
        guard !run.cancelled, !run.stoppedEarly, run.results.count == run.plannedResultCount,
              run.subjectEvidence?.hasValidDigest != false else {
            throw RunnerFailure.validation("Only a complete saved run can become a baseline.")
        }
        let scoringContract: EvaluationScoringContract
        if run.scoringMode == .modelJudge {
            guard let assessmentID,
                  let assessment = run.assessments?.first(where: { $0.id == assessmentID }),
                  assessment.runID == run.id,
                  assessment.samples.count == run.results.count,
                  Set(assessment.samples.map(\.sampleID)) == Set(run.results.map(\.id)),
                  assessment.samples.allSatisfy({ $0.status == .passed || $0.status == .failed }),
                  (assessment.observedJudgeIdentities ?? [assessment.judge]).count == 1,
                  run.subjectEvidence == nil
                    || assessment.subjectEvidenceDigest == run.subjectEvidence?.digest else {
                throw RunnerFailure.validation("Choose a complete, fully scored assessment before approving the baseline.")
            }
            let derivedContract = try EvaluationScoringContract(
                scoringMode: run.scoringMode,
                rubricCriteria: assessment.rubric
                    .split(whereSeparator: \Character.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                judgePromptVersion: assessment.promptVersion,
                judgePassingScore: assessment.passingScore,
                cases: run.plannedCases ?? run.suiteDefinition?.cases ?? []
            )
            if let captured = assessment.scoringContract {
                guard captured == derivedContract else {
                    throw RunnerFailure.validation(
                        "The assessment's saved scoring contract does not match its rubric or judge policy."
                    )
                }
                scoringContract = captured
            } else {
                scoringContract = derivedContract
            }
        } else {
            scoringContract = try EvaluationScoringContract(run: run)
        }
        return EvaluationBaselineApproval(id: UUID(), runID: run.id, assessmentID: assessmentID,
            suiteRevision: run.suiteRevision ?? "legacy", approvedAt: Date(), note: request.note,
            revokedAt: nil, scoringContract: scoringContract)
    }
    static func correctJudgment(_ request: CorrectionRequest) throws -> CorrectionOutput {
        let trimmed = request.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RunnerFailure.validation("Explain why the judgment is incorrect.") }
        let run = request.run
        guard let assessmentID = request.assessmentID ?? run.selectedAssessmentID,
              let assessment = run.assessments?.first(where: { $0.id == assessmentID }),
              let sample = assessment.samples.first(where: { $0.sampleID == request.sampleID }) else {
            throw RunnerFailure.validation("The saved judgment does not exist.")
        }
        if request.collectAsJudgeCheck == true {
            guard let subject = run.results.first(where: { $0.id == request.sampleID }), subject.hasCompleteSubjectEvidenceForJudging else {
                throw RunnerFailure.validation("Only a complete saved subject response can become a known-good judge check.")
            }
            guard request.correctedStatus == .passed || request.correctedStatus == .failed else {
                throw RunnerFailure.validation("A known-good judge check must use a passed or failed corrected status.")
            }
            guard assessment.promptVersion == EvaluationRunner.judgePromptVersion else {
                throw RunnerFailure.validation("Only an assessment using the current judge prompt can become a known-good judge check.")
            }
        }
        let correction = EvaluationHumanCorrection(id: UUID(), runID: run.id, assessmentID: assessmentID, sampleID: request.sampleID,
            originalStatus: sample.status, originalScore: sample.score, correctedStatus: request.correctedStatus,
            correctedScore: request.correctedScore, reason: trimmed, reviewer: request.reviewer, createdAt: Date())
        let example: EvaluationReviewedJudgeExample? = request.collectAsJudgeCheck == true ? .init(
            id: UUID(), sourceRunID: run.id, sourceAssessmentID: assessmentID, sampleID: request.sampleID,
            expectedStatus: request.correctedStatus, reason: trimmed, createdAt: Date(), scoringContract: assessment.scoringContract,
            subjectEvidenceDigest: assessment.subjectEvidenceDigest ?? run.subjectEvidence?.digest) : nil
        return CorrectionOutput(run: run, correction: correction, reviewedJudgeExample: example)
    }
    static func selectAssessment(_ request: SelectionRequest) throws -> EvaluationRun {
        var run = request.run
        guard run.assessments?.contains(where: { $0.id == request.assessmentID }) == true else {
            throw RunnerFailure.validation("The saved assessment does not exist.")
        }
        run.selectedAssessmentID = request.assessmentID
        return run
    }
}
