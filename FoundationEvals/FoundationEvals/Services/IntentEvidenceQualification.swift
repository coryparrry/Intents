import Foundation

struct IntentEvidenceCaseDecision: Codable, Sendable {
    var caseID: UUID
    var required: Bool
    var report: ScenarioReleaseCheckReport?
    var incompleteEvidence: [String]
    var requiredFailures: [String]
    var notRun: Bool = false
}

struct IntentEvidenceDecisionPayload: Codable, Sendable {
    var schemaVersion = 1
    var policyID: String
    var collectionID: String
    var requirementsMet: Bool
    var comparable: Bool?
    var incompleteEvidence: [String]
    var requiredFailures: [String]
    var cases: [IntentEvidenceCaseDecision]
    var comparisons: [ScenarioComparisonReport]?
    var referenceTime: Date
}

/// One qualification path used by the offline command and available to the
/// app's report surface. Bundle checks establish population and provenance;
/// the existing validator, assertion evaluator, comparison, and release
/// evaluator remain the authorities for individual scenario semantics.
enum IntentEvidenceQualification {
    static func check(
        imported: IntentEvidenceBundle.Imported,
        trusted: IntentEvidenceRequirements,
        expectedSource: String,
        expectedAppDigest: String,
        referenceTime: Date
    ) throws -> IntentEvidenceDecisionPayload {
        try validateTrust(imported: imported, trusted: trusted, expectedSource: expectedSource,
                          expectedAppDigest: expectedAppDigest)
        return decisionForValidatedInput(imported: imported, trusted: trusted, referenceTime: referenceTime)
    }

    private static func decisionForValidatedInput(
        imported: IntentEvidenceBundle.Imported,
        trusted: IntentEvidenceRequirements,
        referenceTime: Date
    ) -> IntentEvidenceDecisionPayload {
        let byID = Dictionary(uniqueKeysWithValues: imported.cases.map { ($0.definition.id, $0) })
        var results: [IntentEvidenceCaseDecision] = []
        for requirement in trusted.cases.sorted(by: { $0.definition.id.uuidString < $1.definition.id.uuidString }) {
            guard let item = byID[requirement.definition.id] else {
                let selected = imported.batchManifest?.cases.contains {
                    $0.id == requirement.definition.id
                } == true
                results.append(.init(caseID: requirement.definition.id, required: requirement.required,
                                     report: nil,
                                     incompleteEvidence: [selected
                                        ? "Selected case has no new terminal execution."
                                        : "Case was not selected in this batch; notRun."],
                                     requiredFailures: [], notRun: true))
                continue
            }
            results.append(qualify(item, requirement: requirement, referenceTime: referenceTime))
        }
        var incomplete = results.filter(\.required).flatMap { result in
            result.incompleteEvidence.map { "\(result.caseID): \($0)" }
        }
        let optionalRunHasNonzeroExit = imported.cases.contains { item in
            !trusted.cases.contains(where: {
                $0.required && $0.definition.id == item.definition.id
            }) && item.runs.contains { ($0.xctestExitCode ?? 0) != 0 }
        }
        if optionalRunHasNonzeroExit {
            incomplete.append("Optional native evidence has a nonzero XCTest process exit without bound failure attribution; the batch remains incomplete.")
        }
        var failures = results.filter(\.required).flatMap { result in
            result.requiredFailures.map { "\(result.caseID): \($0)" }
        }
        var batchIssues: [String] = []
        if !trusted.cases.contains(where: \.required) {
            batchIssues.append("The trusted collection has no required cases to qualify.")
        }
        if let collection = imported.collection,
           let batch = imported.batchManifest,
           let result = imported.batchResult {
            let assessment = ScenarioCollectionService.assess(
                manifest: batch, collection: collection, result: result,
                runs: imported.cases.flatMap(\.runs),
                journals: imported.cases.flatMap(\.journals)
            )
            if batch.scope != .full {
                batchIssues.append("Partial batch scope cannot qualify the full collection; unselected cases are not run.")
            }
            if assessment.qualification == .incomplete
                || assessment.qualification == .incompatible {
                batchIssues.append(contentsOf: assessment.reasons)
            }
            if assessment.qualification == .failedFull {
                failures.append("Full collection batch has failed planned attempts.")
            }
        }
        return .init(policyID: IntentEvidenceBundle.policyID, collectionID: trusted.collectionID,
                     requirementsMet: incomplete.isEmpty && batchIssues.isEmpty && failures.isEmpty,
                     comparable: nil, incompleteEvidence: incomplete + batchIssues,
                     requiredFailures: failures, cases: results, comparisons: nil,
                     referenceTime: referenceTime)
    }

    static func compare(
        baseline: IntentEvidenceBundle.Imported,
        candidate: IntentEvidenceBundle.Imported,
        trusted: IntentEvidenceRequirements,
        baselineSource: String,
        candidateSource: String,
        baselineAppDigest: String,
        candidateAppDigest: String,
        mode: ScenarioComparisonMode,
        referenceTime: Date
    ) throws -> IntentEvidenceDecisionPayload {
        // Source revisions may differ for app-change comparisons, but each
        // bundle still has to match the externally supplied requirements.
        try validateTrust(imported: baseline, trusted: trusted, expectedSource: baselineSource,
                          expectedAppDigest: baselineAppDigest)
        try validateTrust(imported: candidate, trusted: trusted, expectedSource: candidateSource,
                          expectedAppDigest: candidateAppDigest)
        var decision = decisionForValidatedInput(
            imported: candidate, trusted: trusted, referenceTime: referenceTime
        )
        let baselineDecision = decisionForValidatedInput(
            imported: baseline, trusted: trusted, referenceTime: referenceTime
        )
        decision.incompleteEvidence.append(contentsOf: baselineDecision.incompleteEvidence.map {
            "Baseline: \($0)"
        })
        let before = Dictionary(uniqueKeysWithValues: baseline.cases.map { ($0.definition.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: candidate.cases.map { ($0.definition.id, $0) })
        var comparisons: [ScenarioComparisonReport] = []
        for requirement in trusted.cases.sorted(by: { $0.definition.id.uuidString < $1.definition.id.uuidString }) {
            guard let lhs = before[requirement.definition.id],
                  let rhs = after[requirement.definition.id] else {
                if requirement.required {
                    decision.incompleteEvidence.append("\(requirement.definition.id): Baseline or candidate case is missing.")
                }
                continue
            }
            let comparison = compareComposite(baseline: lhs, candidate: rhs, mode: mode)
            comparisons.append(comparison)
            if requirement.required, !comparison.isDirectlyComparable {
                decision.incompleteEvidence.append("\(requirement.definition.id): \(comparison.summary)")
            }
        }
        decision.comparable = decision.incompleteEvidence.isEmpty
            && comparisons.count == trusted.cases.count
            && comparisons.allSatisfy(\.isDirectlyComparable)
        decision.comparisons = comparisons
        decision.requirementsMet = decision.incompleteEvidence.isEmpty && decision.requiredFailures.isEmpty
            && decision.comparable == true
        return decision
    }

    private static func compareComposite(
        baseline: IntentEvidenceBundleCase,
        candidate: IntentEvidenceBundleCase,
        mode: ScenarioComparisonMode
    ) -> ScenarioComparisonReport {
        let policy = candidate.plan.comparisonPolicy
            ?? ScenarioComparisonPolicy(mode: mode, baselineRunID: baseline.plan.id)
        var report = ScenarioExecutionComparison.compare(
            baseline: .init(plan: baseline.plan, record: baseline.record,
                            runs: baseline.runs, selectedAssessment: baseline.selectedAssessment,
                            definition: baseline.definition),
            candidate: .init(plan: candidate.plan, record: candidate.record,
                             runs: candidate.runs, selectedAssessment: candidate.selectedAssessment,
                             definition: candidate.definition),
            policy: policy
        )
        if policy.mode != mode {
            report.isDirectlyComparable = false
            report.qualificationIssues = (report.qualificationIssues ?? []) + [
                "Requested comparison mode differs from the candidate's frozen policy."
            ]
            report.summary = (report.qualificationIssues ?? []).joined(separator: " ")
        }
        let diagnosticIssues = [
            (baseline.plan.purpose == .partialDiagnostic, "Baseline is a partial diagnostic execution."),
            (candidate.plan.purpose == .partialDiagnostic, "Candidate is a partial diagnostic execution.")
        ].compactMap { item in item.0 ? item.1 : nil }
        if !diagnosticIssues.isEmpty {
            report.isDirectlyComparable = false
            report.qualificationIssues = (report.qualificationIssues ?? []) + diagnosticIssues
            report.summary = (report.qualificationIssues ?? []).joined(separator: " ")
        }
        return report
    }

    static func qualify(
        _ item: IntentEvidenceBundleCase,
        requirement: IntentEvidenceRequirements.CaseRequirement,
        referenceTime: Date
    ) -> IntentEvidenceCaseDecision {
        let definition = requirement.definition
        var incomplete: [String] = []
        var failed: [String] = []
        let plan = item.plan
        let record = item.record
        if definition.schemaVersion >= ScenarioDefinition.reusableSchemaVersion,
           definition.purpose != .releaseRequirement {
            incomplete.append("Exploratory checks do not qualify as release requirements.")
        }
        if plan.definitionID != definition.id || plan.definitionVersion != item.definition.version
            || plan.definitionDigest != item.definition.definitionDigest
            || plan.testContractDigest != item.definition.testContractDigest
            || record.planID != plan.id {
            incomplete.append("The frozen plan, requirement and terminal record do not bind to the same case.")
        }
        let trustedPlan = try? ScenarioExecutionPlan.make(
            definition: definition, profile: plan.profile,
            appProductDigest: plan.appProductDigest,
            testProductDigest: plan.testProductDigest,
            sourceInputsDigest: plan.sourceInputsDigest ?? "",
            sourceRevision: plan.sourceRevision,
            runnerBuildID: plan.runnerBuildID, runnerID: plan.runnerID,
            plannedCoordinates: plan.coordinates,
            purpose: plan.purpose,
            comparisonPolicy: plan.comparisonPolicy,
            id: plan.id, createdAt: plan.createdAt
        )
        if trustedPlan != plan {
            incomplete.append("The planned route and attempt population differs from the trusted requirement.")
        }
        if let rebuilt = try? ScenarioExecutionRecord.make(
            plan: plan, records: record.records,
            selectedAssessments: record.selectedAssessments ?? [],
            completedAt: record.completedAt
        ) {
            if rebuilt != record {
                incomplete.append("The terminal record seal does not match its frozen evidence.")
            }
        } else {
            incomplete.append("The terminal record has invalid sealed coordinates or assessments.")
        }
        if !validSHA256(plan.testContractDigest)
            || !validSHA256(plan.fixtureContractDigest)
            || !validSHA256(plan.sourceInputsDigest)
            || !validSHA256(plan.appProductDigest)
            || !validSHA256(plan.testProductDigest) {
            incomplete.append("The frozen plan lacks exact source, fixture, requirement or product digests.")
        }
        if plan.purpose == .partialDiagnostic {
            incomplete.append("Partial diagnostic execution does not cover the full requirement population and cannot qualify as complete.")
        }
        let plannedIDs = Set(plan.coordinates.map(\.id))
        let terminalIDs = Set(record.records.map(\.id))
        if plannedIDs.count != plan.coordinates.count || terminalIDs.count != record.records.count
            || plannedIDs != terminalIDs || plan.coordinates.isEmpty {
            incomplete.append("The terminal record does not cover the exact frozen coordinate population.")
        }
        let byRun = Dictionary(grouping: item.runs, by: \.id)
        let byJournal = Dictionary(grouping: item.journals, by: \.id)
        if let overlay = item.selectedAssessment, !overlay.isBound(to: record) {
            incomplete.append("The selected semantic assessment overlay does not bind to terminal evidence.")
        }
        let selectedAssessments = item.selectedAssessment?.assessments
            ?? record.selectedAssessments ?? []
        if Set(selectedAssessments.map(\.selectedAssessmentID)).count != selectedAssessments.count
            || Set(item.retainedAssessments.map(\.id)).count != item.retainedAssessments.count
            || Set(selectedAssessments.map(\.selectedAssessmentID)) != Set(item.retainedAssessments.map(\.id)) {
            incomplete.append("Selected semantic assessments do not match retained immutable records.")
        }
        var observed: [ScenarioLaneResult] = []
        var referencedRuns: Set<UUID> = []
        for coordinate in plan.coordinates {
            guard let terminal = record.records.first(where: { $0.id == coordinate.id }),
                  terminal.coordinate == coordinate else {
                incomplete.append("Coordinate \(coordinate.id) has no matching terminal record.")
                continue
            }
            if !coordinate.required && terminal.state != .completed {
                if terminal.state == .recoveryRequired {
                    incomplete.append("Optional coordinate \(coordinate.id) remains in recovery and cannot be safely ignored.")
                }
                continue
            }
            guard terminal.state == .completed,
                  let runID = terminal.evidenceRunID,
                  let resultID = terminal.evidenceLaneResultID,
                  let laneResult = terminal.laneResult,
                  laneResult.id == resultID,
                  laneResult.caseID == coordinate.caseID,
                  laneResult.lane == coordinate.lane,
                  laneResult.attempt == coordinate.repetition else {
                incomplete.append("Coordinate \(coordinate.id) has no completed, exact child evidence.")
                continue
            }
            observed.append(laneResult)
            var wrongFeatureSource = false
            var nativeInvocation: ScenarioInvocationIdentity?
            if coordinate.lane == .appFeature
                && plan.profile.featureBackend == .connectedRunner {
                guard let child = terminal.featureChild,
                      child.hasValidDigest,
                      child.runID == runID,
                      child.caseID == coordinate.caseID,
                      child.attempt == coordinate.repetition,
                      child.appBundleIdentifier == definition.target.bundleIdentifier,
                      child.featureID == definition.featureBinding?.featureID,
                      child.checkedAppProductDigest == plan.appProductDigest,
                      child.fixtureContractDigest == plan.fixtureContractDigest,
                      child.digest == terminal.evidenceDigest,
                      child.hasVerifiedBuildBinding,
                      child.measurementImplementation?.hasCompleteProvenance == true,
                      validSHA256(child.measurementImplementation?.observerDigest),
                      validSHA256(child.measurementImplementation?.evaluatorDigest),
                      validSHA256(child.subjectInputDigest),
                      laneResult.observations["feature.response"] == .string(child.response),
                      child.startedAt <= child.completedAt,
                      child.errorCategory == nil, child.errorMessage == nil else {
                    incomplete.append("App Feature coordinate \(coordinate.id) lacks bound raw child evidence.")
                    continue
                }
                guard let binding = definition.featureBinding,
                      let expectedInputDigest = try? ScenarioFeatureSubjectDigest.digest(
                          binding: binding, fixture: definition.fixture
                      ),
                      child.subjectInputDigest == expectedInputDigest,
                      child.outputMetadata["intentlab.subjectInputDigest"] == expectedInputDigest else {
                    incomplete.append("App Feature input digest differs from the trusted binding and fixture.")
                    continue
                }
                guard child.outputMetadata["intentlab.caseID"] == definition.id.uuidString,
                      child.outputMetadata["intentlab.attemptID"] == coordinate.id.uuidString else {
                    incomplete.append("App Feature metadata does not bind to the planned case and attempt.")
                    continue
                }
                var expectedObservations: [String: ScenarioValue] = [
                    "feature.response": .string(child.response),
                    "feature.runID": .string(child.runID.uuidString),
                    "feature.sampleID": .string(child.sampleID.uuidString),
                    "feature.resultCount": .integer(1)
                ]
                for (key, value) in child.outputMetadata {
                    expectedObservations["feature.metadata.\(key)"] = .string(value)
                }
                expectedObservations.merge(ScenarioObservedFeatureOutput.project(
                    child.encodedOutput, fields: binding.outputProjections
                )) { _, projected in projected }
                guard laneResult.observations == expectedObservations else {
                    incomplete.append("App Feature observations do not match the retained raw child output.")
                    continue
                }
                let fixtureReceipt = ScenarioFixtureReceipt(
                    observed: child.outputMetadata["intentlab.fixtureDigest"]
                        ?? child.outputMetadata["sourceContentDigest"],
                    expected: plan.fixtureContractDigest
                )
                if fixtureReceipt == .missing {
                    incomplete.append("App Feature did not report the resolved fixture content.")
                    continue
                }
                wrongFeatureSource = fixtureReceipt == .wrongSource
            } else {
                let localFeature = coordinate.lane == .appFeature
                    && plan.profile.featureBackend == .projectLocalTestControl
                if localFeature && (terminal.featureChild != nil
                    || plan.runnerID != nil || plan.runnerBuildID != nil
                    || definition.featureBinding.map({
                        !ScenarioValidator.validLocalFeatureObservations(
                            laneResult, binding: $0
                        )
                    }) != false) {
                    incomplete.append("Local Feature coordinate \(coordinate.id) lacks native test-control provenance.")
                    continue
                }
                guard let runs = byRun[runID], runs.count == 1 else {
                    incomplete.append("Native coordinate \(coordinate.id) has no unique saved child run.")
                    continue
                }
                let run = runs[0]
                nativeInvocation = run.invocation
                referencedRuns.insert(runID)
                guard run.laneResults.count == 1,
                      run.laneResults[0] == laneResult,
                      run.id == run.invocation.id,
                      run.scenarioID == definition.id,
                      run.scenarioDigest == item.definition.definitionDigest,
                      run.testContractDigest == definition.testContractDigest,
                      run.invocation.scenarioDigest == item.definition.definitionDigest,
                      run.invocation.appProduct?.sha256 == plan.appProductDigest,
                      run.invocation.testProduct?.sha256 == plan.testProductDigest,
                      (!localFeature || run.invocation.featureBackend == .projectLocalTestControl),
                      (coordinate.lane == .appFeature || run.invocation.featureBackend == nil),
                      run.executedTestCount == 1,
                      run.executionStatus == .completed,
                      run.xctestExitCode != nil,
                      run.startedAt <= run.completedAt,
                      run.fixture?.digest == plan.fixtureContractDigest,
                      run.integration == item.definition.integration,
                      run.invocation.integration == item.definition.integration,
                      run.runnerPackageVersion?.isEmpty == false,
                      ScenarioHarnessCapabilities.required(
                          for: item.definition,
                          scope: .init(lane: coordinate.lane, attempt: coordinate.repetition),
                          featureBackend: plan.profile.featureBackend
                      )
                          .isSubset(of: Set(run.negotiatedCapabilities ?? [])),
                      byJournal[run.id]?.count == 1,
                      ScenarioExecutionRecoveryPolicy.hasBoundJournal(run: run, journals: item.journals) else {
                    incomplete.append("Native coordinate \(coordinate.id) lacks bound invocation, fixture or journal evidence.")
                    continue
                }
                let evidenceAccepted = ScenarioReleaseCheckEvaluator.evidenceAcceptedJournal(
                    for: run, in: item.journals
                )
                if !evidenceAccepted {
                    incomplete.append("Native coordinate \(coordinate.id) has retained terminal evidence that was not accepted for qualification.")
                } else if !ScenarioReleaseCheckEvaluator.acceptedJournal(for: run, in: item.journals) {
                    incomplete.append("Native coordinate \(coordinate.id) has accepted evidence but fixture cleanup or device readiness remains unresolved.")
                }
                if run.measurementImplementation?.hasCompleteProvenance != true
                    || run.comparisonEnvironmentIdentity?.hasCompleteProvenance != true
                    || !validSHA256(run.measurementImplementation?.observerDigest)
                    || !validSHA256(run.measurementImplementation?.evaluatorDigest)
                    || !validSHA256(run.comparisonEnvironmentIdentity?.profileDigest) {
                    incomplete.append("Native coordinate \(coordinate.id) lacks qualified measurement or environment provenance.")
                }
                if run.xctestExitCode != 0 {
                    incomplete.append("Native coordinate \(coordinate.id) has a nonzero XCTest process exit without bound failure attribution; the run is incomplete.")
                }
            }
            // Optional executed routes still require exact child and journal
            // binding, but their asserted outcomes do not gate the requirement.
            if !coordinate.required { continue }
            let recomputed = ScenarioResultEvaluator.evaluate(
                definition: definition, lane: coordinate.lane,
                observations: laneResult.observations,
                executionStatus: laneResult.executionStatus,
                beforeObservations: laneResult.beforeObservations,
                actionReceipts: laneResult.actionReceipts,
                invocation: nativeInvocation,
                attempt: laneResult.attempt
            )
            let semantic = definition.assertions.filter {
                $0.required && $0.kind == .semanticRubric && $0.applies(to: coordinate.lane)
            }
            var semanticIncomplete = false
            var semanticFailed = false
            for assertion in semantic {
                let matches = selectedAssessments.filter {
                    $0.laneResultID == resultID && $0.assertionID == assertion.id
                }
                guard let policy = requirement.semanticPolicy,
                      matches.count == 1,
                      matches[0].scenarioRunID == runID,
                      matches[0].hasTrustedRequirementBinding(
                          definition: definition, laneResult: laneResult
                      ),
                      matches[0].scoringContractDigest == policy.scoringContractDigest,
                      matches[0].judgePolicyDigest == policy.judgePolicyDigest else {
                    semanticIncomplete = true
                    incomplete.append("Coordinate \(coordinate.id) lacks a selected semantic assessment under the pinned policy.")
                    continue
                }
                let retained = item.retainedAssessments.filter {
                    $0.id == matches[0].selectedAssessmentID
                }
                guard retained.count == 1,
                      retained[0].projection == matches[0],
                      retained[0].hasTrustedBinding(
                          definition: definition, laneResult: laneResult,
                          expectedScoringContractDigest: policy.scoringContractDigest,
                          expectedJudgePolicyDigest: policy.judgePolicyDigest,
                          frozenPolicyAt: policy.frozenAt
                      ) else {
                    semanticIncomplete = true
                    incomplete.append("Coordinate \(coordinate.id) has no verified retained semantic assessment.")
                    continue
                }
                switch matches[0].status {
                case .passed: break
                case .failed: semanticFailed = true
                case .unscored: semanticIncomplete = true
                }
            }
            let deterministicFailed = recomputed.1.contains { result in
                definition.assertions.contains {
                    $0.id == result.assertionID && $0.required
                        && $0.kind != .semanticRubric
                } && !result.passed
            }
            let action = ScenarioResultEvaluator.actionVerdict(
                definition: definition, lane: coordinate.lane,
                attempt: laneResult.attempt, invocation: nativeInvocation,
                receipts: laneResult.actionReceipts
            )
            if definition.actionRequirements != nil,
               laneResult.actionReceipts != nil,
               !ScenarioResultEvaluator.actionObservationIsConsistent(laneResult) {
                incomplete.append("Coordinate \(coordinate.id) has action receipts that differ from the raw observed app record.")
            }
            if definition.actionRequirements != nil && laneResult.cleanupVerified != true {
                incomplete.append("Coordinate \(coordinate.id) has no verified fixture cleanup/readiness result.")
            }
            if action.0 == .failed {
                failed.append("Coordinate \(coordinate.id) failed action verification: \(action.1?.rawValue ?? "wrongAction").")
            } else if action.0 == .notObserved {
                incomplete.append("Coordinate \(coordinate.id) lacks attributable action evidence: \(action.1?.rawValue ?? "missingActionEvidence").")
            }
            if deterministicFailed {
                failed.append("Coordinate \(coordinate.id) failed its observed requirement: wrongOutcome.")
            }
            var assessedLane = laneResult
            // A captured semantic response can carry the runner's provisional
            // notObserved verdict. Resolve only that verdict from the trusted,
            // scored assessment; missing observations or action evidence still
            // fail the independent recomputation and integrity checks above.
            let hasScoredSemanticEvidence = !semantic.isEmpty && !semanticIncomplete
                && recomputed.0 == .needsReview && laneResult.executionStatus == .completed
                && action.0 == .passed
            if laneResult.executionStatus != .completed || recomputed.0 == .notObserved
                || semanticIncomplete || (laneResult.outcome == .notObserved && !hasScoredSemanticEvidence)
                || (semantic.isEmpty && laneResult.outcome == .needsReview) {
                incomplete.append("Coordinate \(coordinate.id) has incomplete independently evaluated evidence.")
                assessedLane.outcome = .needsReview
            } else if deterministicFailed || action.0 == .failed || semanticFailed || wrongFeatureSource || laneResult.outcome == .failed {
                if !deterministicFailed {
                    failed.append(wrongFeatureSource
                        ? "Coordinate \(coordinate.id) used different source content than the trusted fixture."
                        : "Coordinate \(coordinate.id) failed its observed requirement.")
                }
                assessedLane.outcome = .failed
            } else if semantic.isEmpty && recomputed.0 == .needsReview {
                incomplete.append("Coordinate \(coordinate.id) has an unscored requirement.")
                assessedLane.outcome = .needsReview
            } else {
                assessedLane.outcome = .passed
            }
            observed[observed.count - 1] = assessedLane
        }
        if Set(item.runs.map(\.id)) != referencedRuns {
            incomplete.append("Native child runs include missing, duplicate or unreferenced evidence.")
        }
        if Set(item.journals.map(\.id)) != referencedRuns {
            incomplete.append("Native child journals do not match the executed child population.")
        }
        for run in item.runs where run.responseAssessments != nil {
            let assessmentIDs = run.responseAssessments!.map(\.id)
            if Set(assessmentIDs).count != assessmentIDs.count {
                incomplete.append("Retained semantic assessments contain repeated identities.")
            }
        }
        if ScenarioValidator.issues(in: definition).contains(where: { $0.severity == .error }) {
            incomplete.append("The trusted frozen scenario is invalid.")
        }
        if definition.purpose != .releaseRequirement {
            incomplete.append("Exploratory checks cannot satisfy release requirements.")
        }
        if definition.schemaVersion != ScenarioDefinition.stableSchemaVersion {
            incomplete.append("Version 3 evidence is required for this policy.")
        }
        let aggregate = ScenarioResultEvaluator.overall(definition: definition, laneResults: observed)
        switch aggregate {
        case .passed: break
        case .failed: failed.append("Required proof claims fail across the coordinated route population.")
        case .needsReview, .notObserved, .notApplicable:
            incomplete.append("Required proof claims are incomplete across the coordinated route population.")
        }
        let outcome: ScenarioReleaseCheckOutcome = !incomplete.isEmpty ? .incompleteOrIncompatibleEvidence
            : !failed.isEmpty ? .failed : .passed
        let report = ScenarioReleaseCheckReport(
            scenarioID: definition.id, runID: nil, outcome: outcome,
            summary: outcome == .passed
                ? "Every required coordinate passed with current bound evidence."
                : "The coordinated execution cannot satisfy the release requirement.",
            failures: incomplete + failed, generatedAt: referenceTime,
            policyVersion: IntentEvidenceBundle.policyID
        )
        return .init(caseID: definition.id, required: requirement.required,
                     report: report, incompleteEvidence: incomplete, requiredFailures: failed)
    }

    private static func validateTrust(
        imported: IntentEvidenceBundle.Imported,
        trusted: IntentEvidenceRequirements,
        expectedSource: String,
        expectedAppDigest: String
    ) throws {
        guard !expectedSource.isEmpty, imported.manifest.sourceRevision == expectedSource else {
            throw IntentEvidenceBundleError.invalid("Unexpected source revision.")
        }
        guard imported.cases.allSatisfy({ item in
            let expected = item.plan.sourceRevision
                ?? item.plan.sourceInputsDigest.map { "inputs-sha256:\($0)" }
            return expected == imported.manifest.sourceRevision
        }) else {
            throw IntentEvidenceBundleError.invalid("Frozen plan source differs from bundle provenance.")
        }
        guard validSHA256(expectedAppDigest),
              imported.cases.allSatisfy({ $0.plan.appProductDigest == expectedAppDigest }) else {
            throw IntentEvidenceBundleError.invalid("App product digest differs from the externally expected build.")
        }
        guard trusted.schemaVersion == IntentEvidenceRequirements.schemaVersion,
              imported.requirements.schemaVersion == trusted.schemaVersion,
              imported.requirements.collectionID == trusted.collectionID,
              imported.manifest.collectionID == trusted.collectionID else {
            throw IntentEvidenceBundleError.invalid("Trusted collection identity changed.")
        }
        guard Set(trusted.cases.map { $0.definition.id }).count == trusted.cases.count,
              Set(imported.requirements.cases.map { $0.definition.id }).count == imported.requirements.cases.count else {
            throw IntentEvidenceBundleError.invalid("Collection has duplicate case identities.")
        }
        let expected = Dictionary(uniqueKeysWithValues: trusted.cases.map { ($0.definition.id, $0) })
        let bundled = Dictionary(uniqueKeysWithValues: imported.requirements.cases.map { ($0.definition.id, $0) })
        for (caseID, requirement) in expected {
            guard requirement.definition.hasValidDigest,
                  let inBundle = bundled[caseID],
                  inBundle.required == requirement.required,
                  inBundle.semanticPolicy == requirement.semanticPolicy,
                  inBundle.definition.testContractDigest == requirement.definition.testContractDigest,
                  inBundle.definition.hasValidDigest else {
                throw IntentEvidenceBundleError.invalid("Trusted requirement or required status changed for \(caseID).")
            }
        }
        guard Set(expected.keys) == Set(bundled.keys) else {
            throw IntentEvidenceBundleError.invalid("The bundle omitted or added collection cases.")
        }
        let exportedIDs = Set(imported.cases.map { $0.definition.id })
        if let batch = imported.batchManifest {
            guard exportedIDs.isSubset(of: Set(batch.cases.map(\.id))),
                  imported.collection != nil, imported.batchResult != nil else {
                throw IntentEvidenceBundleError.invalid("Exported cases are outside the frozen batch scope.")
            }
        } else if exportedIDs != Set(bundled.keys) {
            throw IntentEvidenceBundleError.invalid("The bundle omitted collection cases.")
        }
        for item in imported.cases {
            guard let requirement = expected[item.definition.id],
                  item.definition.hasValidDigest,
                  item.definition.testContractDigest == requirement.definition.testContractDigest else {
                throw IntentEvidenceBundleError.invalid("Case expectations changed in exported evidence.")
            }
        }
    }

    private static func validSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public struct IntentEvidenceCheckResult {
    public let exitCode: Int32
    public let json: Data
}

public enum IntentEvidenceChecker {
    public static let policyID = "intent-lab-report-v3"

    public static func check(
        bundle: URL,
        requirements: URL,
        expectedSource: String,
        expectedAppDigest: String,
        policy: String,
        referenceTime: Date
    ) throws -> IntentEvidenceCheckResult {
        guard policy == policyID else {
            throw IntentEvidenceBundleError.invalid("Unsupported report policy \(policy).")
        }
        let imported = try IntentEvidenceBundle.read(bundle)
        let trusted = try IntentEvidenceBundle.decodeRequirements(requirements)
        let payload = try IntentEvidenceQualification.check(
            imported: imported, trusted: trusted, expectedSource: expectedSource,
            expectedAppDigest: expectedAppDigest,
            referenceTime: referenceTime
        )
        return try result(payload)
    }

    public static func compare(
        baseline: URL,
        candidate: URL,
        requirements: URL,
        baselineSource: String,
        candidateSource: String,
        baselineAppDigest: String,
        candidateAppDigest: String,
        policy: String,
        mode: String,
        referenceTime: Date
    ) throws -> IntentEvidenceCheckResult {
        guard policy == policyID else {
            throw IntentEvidenceBundleError.invalid("Unsupported report policy \(policy).")
        }
        let selected: ScenarioComparisonMode
        switch mode {
        case "app-change": selected = .compareAppChanges
        case "environment-change": selected = .compareEnvironments
        case "side-by-side": selected = .sideBySideInspection
        default: throw IntentEvidenceBundleError.invalid("Unsupported comparison mode \(mode).")
        }
        let lhs = try IntentEvidenceBundle.read(baseline)
        let rhs = try IntentEvidenceBundle.read(candidate)
        let trusted = try IntentEvidenceBundle.decodeRequirements(requirements)
        let payload = try IntentEvidenceQualification.compare(
            baseline: lhs, candidate: rhs, trusted: trusted,
            baselineSource: baselineSource, candidateSource: candidateSource,
            baselineAppDigest: baselineAppDigest, candidateAppDigest: candidateAppDigest,
            mode: selected,
            referenceTime: referenceTime
        )
        return try result(payload)
    }

    private static func result(_ payload: IntentEvidenceDecisionPayload) throws -> IntentEvidenceCheckResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let exitCode: Int32 = !payload.incompleteEvidence.isEmpty || payload.comparable == false ? 20
            : !payload.requiredFailures.isEmpty ? 10
            : !payload.requirementsMet ? 20 : 0
        return .init(exitCode: exitCode, json: try encoder.encode(payload))
    }
}
