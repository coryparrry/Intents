import Foundation

enum EvaluationExperimentAnalyzer {
    static func summarize(
        current: EvaluationRun,
        candidate: EvaluationRun
    ) -> EvaluationExperimentSummary {
        let currentResults = current.effectiveResults
        let candidateResults = candidate.effectiveResults
        let currentByCase = Dictionary(grouping: currentResults, by: \.caseID)
        let candidateByCase = Dictionary(grouping: candidateResults, by: \.caseID)
        let common = Set(currentByCase.keys).intersection(candidateByCase.keys)
        let expectedCurrentCases = Set((current.plannedCases ?? []).map(\.id))
        let expectedCandidateCases = Set((candidate.plannedCases ?? []).map(\.id))
        let expectedCommon = expectedCurrentCases.intersection(expectedCandidateCases)
        let completeCoverage = currentResults.count == current.plannedResultCount
            && candidateResults.count == candidate.plannedResultCount
            && currentResults.allSatisfy { !hasError($0)
                && ($0.status == .passed || $0.status == .failed) }
            && candidateResults.allSatisfy { !hasError($0)
                && ($0.status == .passed || $0.status == .failed) }
            && expectedCurrentCases == expectedCandidateCases
            && common == expectedCommon
            && common.allSatisfy { id in
                hasCompleteRepetitions(currentByCase[id] ?? [], count: current.repetitions)
                    && hasCompleteRepetitions(candidateByCase[id] ?? [], count: candidate.repetitions)
            }
        var improved: [UUID] = []
        var regressed: [UUID] = []
        var unchanged: [UUID] = []
        for id in common {
            let currentRate = passRate(currentByCase[id] ?? [])
            let candidateRate = passRate(candidateByCase[id] ?? [])
            guard let currentRate, let candidateRate else { continue }
            if candidateRate > currentRate { improved.append(id) }
            else if candidateRate < currentRate { regressed.append(id) }
            else { unchanged.append(id) }
        }

        let discordant = improved.count + regressed.count
        let interval = discordant == 0 ? nil : wilsonInterval(successes: improved.count, total: discordant)
        let decision: EvaluationExperimentDecision
        let explanation: String
        if !completeCoverage {
            decision = .collectMoreEvidence
            explanation = "The variants do not have complete, error-free, scored coverage for every planned case and repetition. Missing, unscored, or failed executions cannot justify adoption."
        } else if common.count < 3 || discordant < 2 {
            decision = .collectMoreEvidence
            explanation = "Too few distinct comparable cases changed outcome to justify a winner. Repetitions improve stability but do not add case coverage."
        } else if let interval, interval.lowerBound > 0.5 {
            decision = .adoptCandidate
            explanation = "The candidate improved a majority of discordant cases and the case-level 95% interval excludes an even split."
        } else if let interval, interval.upperBound < 0.5 {
            decision = .keepCurrent
            explanation = "The current variant won a majority of discordant cases and the case-level 95% interval excludes an even split."
        } else {
            decision = .inconclusive
            explanation = "Observed case-level changes do not provide sufficient evidence to choose a winner."
        }

        return EvaluationExperimentSummary(
            improvedCaseIDs: improved.sorted { $0.uuidString < $1.uuidString },
            regressedCaseIDs: regressed.sorted { $0.uuidString < $1.uuidString },
            unchangedCaseIDs: unchanged.sorted { $0.uuidString < $1.uuidString },
            currentMedianLatencyMilliseconds: median(current.results.map(\.durationMilliseconds)),
            candidateMedianLatencyMilliseconds: median(candidate.results.map(\.durationMilliseconds)),
            distinctCaseCoverage: common.count,
            repetitionsPerCase: min(current.repetitions, candidate.repetitions),
            confidenceInterval: interval,
            suggestedDecision: decision,
            explanation: explanation
        )
    }

    static func balancedOrder(
        currentID: UUID,
        candidateID: UUID,
        caseCount: Int,
        repetitions: Int
    ) -> [UUID] {
        guard caseCount > 0, repetitions > 0 else { return [] }
        return (0..<(caseCount * repetitions)).flatMap { index in
            index.isMultiple(of: 2) ? [currentID, candidateID] : [candidateID, currentID]
        }
    }

    private static func passRate(_ results: [EvaluationSampleResult]) -> Double? {
        let scored = results.filter { $0.status == .passed || $0.status == .failed }
        guard !scored.isEmpty else { return nil }
        return Double(scored.count { $0.status == .passed }) / Double(scored.count)
    }

    private static func hasError(_ result: EvaluationSampleResult) -> Bool {
        result.status == .error || result.errorCategory != nil || result.errorMessage != nil
            || result.judgeErrorCategory != nil || result.judgeErrorMessage != nil
    }

    private static func hasCompleteRepetitions(
        _ results: [EvaluationSampleResult],
        count: Int
    ) -> Bool {
        count > 0
            && results.count == count
            && Set(results.map(\.repetition)) == Set(1...count)
            && Set(results.map(\.id)).count == results.count
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Wilson score interval over distinct discordant cases. Repetitions are first
    /// aggregated within a case and are never counted as independent evidence.
    private static func wilsonInterval(successes: Int, total: Int) -> ClosedRange<Double> {
        let z = 1.959963984540054
        let n = Double(total)
        let p = Double(successes) / n
        let denominator = 1 + z * z / n
        let centre = (p + z * z / (2 * n)) / denominator
        let margin = z * sqrt((p * (1 - p) + z * z / (4 * n)) / n) / denominator
        return max(0, centre - margin)...min(1, centre + margin)
    }
}

enum EvaluationReleaseCheckEvaluator {
    static func report(
        projectID: UUID,
        suite: EvaluationSuite,
        currentSuiteRevision: String,
        run: EvaluationRun?,
        baseline: EvaluationRun?,
        approvedBaseline: EvaluationBaselineApproval?
    ) -> EvaluationReleaseCheckReport {
        var incomplete: [String] = []
        var regressions: [String] = []
        var execution: [String] = []
        let policy = suite.releasePolicy
        let currentScoringContract = try? EvaluationScoringContract(suite: suite)
        if currentScoringContract == nil {
            incomplete.append("The current scoring contract could not be captured.")
        }
        if !(0...(EvaluationStore.maximumPlannedSamples * 2)).contains(policy.maximumErrorCount)
            || !policy.maximumPassRateRegression.isFinite
            || !(0...1).contains(policy.maximumPassRateRegression)
            || policy.maximumAverageLatencyMilliseconds.map({ !$0.isFinite || $0 < 0 }) == true
            || Set(policy.criticalCaseIDs).count != policy.criticalCaseIDs.count
            || !Set(policy.criticalCaseIDs).isSubset(of: Set(suite.cases.map(\.id))) {
            incomplete.append("The suite's release policy is invalid and must be corrected before it can pass.")
        }

        guard let run else {
            return EvaluationReleaseCheckReport(
                projectID: projectID,
                suiteID: suite.id,
                runID: nil,
                assessmentID: nil,
                outcome: .incompleteOrIncompatibleEvidence,
                summary: "No completed run is available for this required suite.",
                failures: ["Run the suite using its current saved definition."],
                generatedAt: Date()
            )
        }
        if run.cancelled || run.stoppedEarly || run.results.count != run.plannedResultCount {
            incomplete.append("The run did not complete every planned sample.")
        }
        let plannedCases = run.plannedCases ?? run.suiteDefinition?.cases ?? []
        let expectedCoordinates = Set((0..<max(0, run.repetitions)).flatMap { offset in
            plannedCases.map { "\($0.id.uuidString):\(offset + 1)" }
        })
        let actualCoordinates = Set(run.results.map { "\($0.caseID.uuidString):\($0.repetition)" })
        if Set(run.results.map(\.id)).count != run.results.count
            || actualCoordinates.count != run.results.count
            || actualCoordinates != expectedCoordinates {
            incomplete.append("The run does not contain exactly one result for every planned case and repetition.")
        }
        if run.suiteID != suite.id {
            incomplete.append("The run belongs to a different suite.")
        }
        if run.scoringMode != suite.scoringMode {
            incomplete.append("The run used a different scoring mode from the current suite.")
        }
        if run.suiteRevision == nil || run.suiteRevision != currentSuiteRevision {
            incomplete.append("The run is stale because the suite definition changed.")
        }
        if let evidence = run.subjectEvidence, !evidence.hasValidDigest {
            incomplete.append("The run's immutable subject evidence failed its integrity check.")
        }
        if (try? EvaluationScoringContract(run: run)) != currentScoringContract {
            incomplete.append("The run's captured cases or scoring configuration do not match the current suite.")
        }
        if run.scoringMode == .modelJudge {
            let resultIDs = Set(run.results.map(\.id))
            if run.selectedAssessment.map({ assessment in
                assessment.runID == run.id
                    && assessment.samples.count == run.results.count
                    && Set(assessment.samples.map(\.sampleID)) == resultIDs
                    && assessment.samples.allSatisfy({ $0.status == .passed || $0.status == .failed })
            }) != true {
                incomplete.append("The selected judge assessment is missing, incomplete, or contains unscored evidence.")
            }
            if let assessment = run.selectedAssessment,
               (assessment.observedJudgeIdentities ?? [assessment.judge]).count != 1 {
                incomplete.append("The selected assessment contains mixed judge model or provider identities.")
            }
            if let assessment = run.selectedAssessment,
               resolvedScoringContract(for: assessment, run: run) != currentScoringContract {
                incomplete.append("The selected assessment used a different rubric, judge prompt policy, passing score, or case scoring contract.")
            }
            if let assessment = run.selectedAssessment,
               let evidence = run.subjectEvidence,
               assessment.subjectEvidenceDigest != evidence.digest {
                incomplete.append("The selected assessment is not bound to this run's immutable subject evidence.")
            }
        }
        if run.scoredCount != run.results.count {
            incomplete.append("The run does not contain pass/fail evidence for every completed sample.")
        }
        if run.errorCount > policy.maximumErrorCount {
            execution.append("The run has \(run.errorCount) errors; the limit is \(policy.maximumErrorCount).")
        }
        if let maximum = policy.maximumAverageLatencyMilliseconds,
           run.averageDurationMilliseconds > maximum {
            regressions.append("Average latency \(Int(run.averageDurationMilliseconds)) ms exceeds the \(Int(maximum)) ms limit.")
        }
        let selectedStatusBySampleID = Dictionary(
            uniqueKeysWithValues: (run.selectedAssessment?.samples ?? []).map { ($0.sampleID, $0.status) }
        )
        for caseID in policy.criticalCaseIDs {
            let results = run.results.filter { $0.caseID == caseID }
            if results.isEmpty || results.contains(where: {
                (selectedStatusBySampleID[$0.id] ?? $0.status) != .passed
            }) {
                regressions.append("Critical case \(caseID.uuidString) did not pass every trial.")
            }
        }

        if policy.requireApprovedBaseline {
            guard let approvedBaseline else {
                incomplete.append("This suite requires an explicitly approved baseline.")
                return result(projectID: projectID, suite: suite, run: run,
                              incomplete: incomplete, regressions: regressions, execution: execution)
            }
            guard approvedBaseline.isCurrent,
                  let baseline,
                  baseline.id == approvedBaseline.runID else {
                incomplete.append("The approved baseline run is missing or no longer current.")
                return result(projectID: projectID, suite: suite, run: run,
                              incomplete: incomplete, regressions: regressions, execution: execution)
            }
            var approvedBaselineRun = baseline
            var approvedContract = approvedBaseline.scoringContract
            if baseline.scoringMode == .modelJudge {
                guard let assessmentID = approvedBaseline.assessmentID,
                      let approvedAssessment = baseline.assessments?.first(where: { $0.id == assessmentID }),
                      approvedAssessment.runID == baseline.id,
                      approvedAssessment.samples.count == baseline.results.count,
                      Set(approvedAssessment.samples.map(\.sampleID)) == Set(baseline.results.map(\.id)),
                      approvedAssessment.samples.allSatisfy({ $0.status == .passed || $0.status == .failed }),
                      baseline.subjectEvidence == nil
                        || approvedAssessment.subjectEvidenceDigest == baseline.subjectEvidence?.digest,
                      (approvedAssessment.observedJudgeIdentities ?? [approvedAssessment.judge]).count == 1 else {
                    incomplete.append("The approved baseline assessment is missing or contains mixed judge identities.")
                    return result(projectID: projectID, suite: suite, run: run,
                                  incomplete: incomplete, regressions: regressions, execution: execution)
                }
                let assessmentContract = resolvedScoringContract(for: approvedAssessment, run: baseline)
                if approvedContract == nil { approvedContract = assessmentContract }
                guard assessmentContract == approvedContract else {
                    incomplete.append("The approved baseline assessment no longer matches its approved scoring contract.")
                    return result(projectID: projectID, suite: suite, run: run,
                                  incomplete: incomplete, regressions: regressions, execution: execution)
                }
                approvedBaselineRun.selectedAssessmentID = assessmentID
            } else if approvedContract == nil {
                approvedContract = try? EvaluationScoringContract(run: baseline)
            }
            guard approvedContract == currentScoringContract else {
                incomplete.append("The approved baseline uses incompatible cases or scoring conditions.")
                return result(projectID: projectID, suite: suite, run: run,
                              incomplete: incomplete, regressions: regressions, execution: execution)
            }
            let comparison = EvaluationRunComparison(current: run, baseline: approvedBaselineRun)
            guard comparison.compatibility == .compatible else {
                incomplete.append("The current run and approved baseline use incompatible comparison conditions.")
                return result(projectID: projectID, suite: suite, run: run,
                              incomplete: incomplete, regressions: regressions, execution: execution)
            }
            if let currentJudge = run.selectedAssessment?.judge,
               let baselineJudge = approvedBaselineRun.selectedAssessment?.judge,
               currentJudge != baselineJudge {
                incomplete.append("Judge conditions changed. Reassess both runs with the same fixed judge before comparison.")
            }
            if let currentRate = run.passRate, let baselineRate = approvedBaselineRun.passRate,
               baselineRate - currentRate > policy.maximumPassRateRegression {
                regressions.append("Pass rate regressed by \((baselineRate - currentRate).formatted(.percent.precision(.fractionLength(1)))).")
            }
        }
        return result(projectID: projectID, suite: suite, run: run,
                      incomplete: incomplete, regressions: regressions, execution: execution)
    }

    static func projectMarkdown(_ report: EvaluationProjectReleaseCheckReport) -> String {
        let heading = report.outcome == .passed ? "Project release check passed" : "Project release check did not pass"
        let suites = report.suites.map { item in
            "- \(item.suiteName) (`\(item.suiteID.uuidString)`): \(item.report.outcome.rawValue) — \(item.report.summary)"
        }.joined(separator: "\n")
        return """
        # \(heading)

        \(report.summary)

        - Project: `\(report.projectID.uuidString)`
        - Exit status: `\(report.outcome.rawValue)`

        ## Required suites

        \(suites.isEmpty ? "- None configured" : suites)
        """
    }

    static func projectReport(
        projectID: UUID,
        suites: [EvaluationProjectReleaseSuiteReport]
    ) -> EvaluationProjectReleaseCheckReport {
        let required = suites.filter(\.required)
        let outcome: EvaluationReleaseCheckExit
        if required.contains(where: { $0.report.outcome == .executionError }) {
            outcome = .executionError
        } else if required.contains(where: { $0.report.outcome == .incompleteOrIncompatibleEvidence }) {
            outcome = .incompleteOrIncompatibleEvidence
        } else if required.contains(where: { $0.report.outcome == .regression }) {
            outcome = .regression
        } else {
            outcome = .passed
        }
        let summary: String
        if required.isEmpty {
            summary = "No suites are currently required for this project."
        } else if outcome == .passed {
            summary = "All \(required.count) required suites passed."
        } else {
            let failed = required.count { $0.report.outcome != .passed }
            summary = "\(failed) of \(required.count) required suites did not pass."
        }
        return EvaluationProjectReleaseCheckReport(
            projectID: projectID,
            outcome: outcome,
            summary: summary,
            suites: required,
            generatedAt: Date()
        )
    }

    private static func resolvedScoringContract(
        for assessment: EvaluationAssessment,
        run: EvaluationRun
    ) -> EvaluationScoringContract? {
        let derived = try? EvaluationScoringContract(
            scoringMode: run.scoringMode,
            rubricCriteria: assessment.rubric
                .split(whereSeparator: \Character.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            judgePromptVersion: assessment.promptVersion,
            judgePassingScore: assessment.passingScore,
            cases: run.plannedCases ?? run.suiteDefinition?.cases ?? []
        )
        guard let scoringContract = assessment.scoringContract else { return derived }
        return scoringContract == derived ? scoringContract : nil
    }

    static func markdown(_ report: EvaluationReleaseCheckReport) -> String {
        let heading = report.outcome == .passed ? "Release check passed" : "Release check did not pass"
        let failures = report.failures.isEmpty ? "- None" : report.failures.map { "- \($0)" }.joined(separator: "\n")
        return """
        # \(heading)

        \(report.summary)

        - Project: `\(report.projectID.uuidString)`
        - Suite: `\(report.suiteID.uuidString)`
        - Run: `\(report.runID?.uuidString ?? "unavailable")`
        - Assessment: `\(report.assessmentID?.uuidString ?? "unavailable")`
        - Exit status: `\(report.outcome.rawValue)`

        ## Findings

        \(failures)
        """
    }

    private static func result(
        projectID: UUID,
        suite: EvaluationSuite,
        run: EvaluationRun,
        incomplete: [String],
        regressions: [String],
        execution: [String]
    ) -> EvaluationReleaseCheckReport {
        let outcome: EvaluationReleaseCheckExit
        let failures: [String]
        if !execution.isEmpty {
            outcome = .executionError
            failures = execution + incomplete + regressions
        } else if !incomplete.isEmpty {
            outcome = .incompleteOrIncompatibleEvidence
            failures = incomplete + regressions
        } else if !regressions.isEmpty {
            outcome = .regression
            failures = regressions
        } else {
            outcome = .passed
            failures = []
        }
        return EvaluationReleaseCheckReport(
            projectID: projectID,
            suiteID: suite.id,
            runID: run.id,
            assessmentID: run.selectedAssessmentID,
            outcome: outcome,
            summary: outcome == .passed ? "All configured release requirements passed." : "One or more release requirements were not satisfied.",
            failures: failures,
            generatedAt: Date()
        )
    }
}
