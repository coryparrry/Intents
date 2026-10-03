import Foundation

enum ScenarioRunnerSelection {
    static func chosenID(candidateIDs: [UUID], selectedID: UUID?) -> UUID? {
        if let selectedID, candidateIDs.contains(selectedID) { return selectedID }
        return candidateIDs.count == 1 ? candidateIDs[0] : nil
    }
}

/// Compares a complete frozen v3 execution. Callers supply saved, immutable
/// records; no latest-run lookup or mutable UI selection enters this decision.
/// The caller first validates each child journal, artifact and trusted
/// definition. This comparison verifies record and child bindings, not file
/// bytes outside the supplied snapshot.
enum ScenarioExecutionComparison {
    struct Snapshot: Sendable {
        var plan: ScenarioExecutionPlan
        var record: ScenarioExecutionRecord
        var runs: [ScenarioRun]
        /// A later immutable selection supersedes capture-time selected results.
        var selectedAssessment: ScenarioAssessmentSelectionRecord? = nil
        /// Required when semantic assertions or selected assessments are present.
        var definition: ScenarioDefinition? = nil
    }

    static func compare(
        baseline: Snapshot,
        candidate: Snapshot,
        policy: ScenarioComparisonPolicy
    ) -> ScenarioComparisonReport {
        var issues = validate(baseline, label: "Baseline") + validate(candidate, label: "Candidate")
        let old = baseline.plan
        let new = candidate.plan
        if policy.baselineRunID != old.id {
            issues.append("The selected baseline does not match the frozen execution plan.")
        }
        if new.comparisonPolicy != policy {
            issues.append("The candidate did not freeze this baseline and comparison policy before execution.")
        }
        if old.id == new.id || baseline.record.id == candidate.record.id {
            issues.append("Comparison needs two distinct immutable executions.")
        }
        if old.definitionID != new.definitionID { issues.append("The case identity changed.") }
        if !validDigest(old.testContractDigest) || !validDigest(new.testContractDigest) {
            issues.append("Stable requirement provenance is missing.")
        } else if old.testContractDigest != new.testContractDigest {
            issues.append("Requirements changed.")
        }
        if !validDigest(old.fixtureContractDigest) || !validDigest(new.fixtureContractDigest) {
            issues.append("Verified fixture-content provenance is missing.")
        } else if old.fixtureContractDigest != new.fixtureContractDigest {
            issues.append("Fixture content or preparation contract changed.")
        }
        if !validDigest(old.appProductDigest) || !validDigest(new.appProductDigest) {
            issues.append("Exact app-build provenance is missing.")
        }
        let oldPopulation = population(baseline)
        let newPopulation = population(candidate)
        if oldPopulation == nil || newPopulation == nil || Set(oldPopulation!.keys) != Set(newPopulation!.keys) {
            issues.append("The frozen case, route, attempt, or required population changed.")
        }
        if policy.mode == .sideBySideInspection {
            issues.append("Side-by-side inspection does not qualify a fix.")
        }
        if policy.mode == .compareEnvironments {
            if old.appProductDigest != new.appProductDigest
                || old.sourceInputsDigest != new.sourceInputsDigest {
                issues.append("The subject implementation changed during an environment comparison.")
            }
            if policy.baselineEnvironmentID == nil || policy.candidateEnvironmentID == nil
                || policy.baselineEnvironmentID == policy.candidateEnvironmentID {
                issues.append("Explicit, different before/after environment identities are required.")
            }
        }

        if let oldPopulation, let newPopulation {
            for key in Set(oldPopulation.keys).intersection(newPopulation.keys).sorted() {
                guard let lhs = oldPopulation[key], let rhs = newPopulation[key] else { continue }
                if lhs.coordinate.lane == .appFeature {
                    compareFeature(lhs, rhs, mode: policy.mode, key: key, issues: &issues)
                } else {
                    compareNative(lhs, rhs, baseline: baseline, candidate: candidate,
                                  mode: policy.mode, key: key, issues: &issues)
                }
            }
        }
        let nativeBefore = baseline.record.records.filter { $0.coordinate.lane != .appFeature }
        let nativeAfter = candidate.record.records.filter { $0.coordinate.lane != .appFeature }
        if nativeBefore.isEmpty != nativeAfter.isEmpty {
            issues.append("Native route evidence is missing from one execution.")
        } else if nativeBefore.isEmpty {
            if policy.mode == .compareEnvironments {
                issues.append("A Feature-only run has no independently observed before/after native environment identity.")
            }
            if policy.mode == .compareAppChanges,
               profileFacts(old.profile) != profileFacts(new.profile) {
                issues.append("The selected execution profile changed between Feature-only runs.")
            }
        } else {
            let oldEnvironments = Set(baseline.runs.compactMap { $0.comparisonEnvironmentIdentity?.profileID })
            let newEnvironments = Set(candidate.runs.compactMap { $0.comparisonEnvironmentIdentity?.profileID })
            if oldEnvironments.count != 1 || newEnvironments.count != 1 {
                issues.append("The native routes do not share one qualified environment profile per execution.")
            }
            if policy.mode == .compareEnvironments,
               (oldEnvironments != Set([policy.baselineEnvironmentID ?? ""])
                || newEnvironments != Set([policy.candidateEnvironmentID ?? ""])) {
                issues.append("The native route environments do not match the explicit before/after policy.")
            }
        }
        compareAssessments(baseline, candidate, issues: &issues)
        let lanes = laneSummaries(baseline, candidate)
        let improved = lanes.filter { $0.candidatePassed > $0.baselinePassed
            && $0.candidateAttempted == $0.baselineAttempted }.map { $0.lane.title }
        let regressed = lanes.filter { $0.candidatePassed < $0.baselinePassed }.map { $0.lane.title }
        let summary: String
        if !issues.isEmpty {
            summary = Array(Set(issues)).sorted().joined(separator: " ")
        } else if !regressed.isEmpty {
            summary = "Observed regression in: \(regressed.joined(separator: ", "))."
        } else if !improved.isEmpty {
            summary = "Observed improvement in: \(improved.joined(separator: ", "))."
        } else {
            summary = "The retained coordinate outcomes did not improve."
        }
        let dimensions = [
            dimension("testContractDigest", old.testContractDigest, new.testContractDigest),
            dimension("fixtureContractDigest", old.fixtureContractDigest, new.fixtureContractDigest),
            dimension("appBuild", old.appProductDigest, new.appProductDigest,
                      compatible: policy.mode == .compareAppChanges || old.appProductDigest == new.appProductDigest),
            dimension("sourceInputsDigest", old.sourceInputsDigest ?? "unknown", new.sourceInputsDigest ?? "unknown",
                      compatible: policy.mode == .compareAppChanges || old.sourceInputsDigest == new.sourceInputsDigest)
        ]
        return .init(isDirectlyComparable: issues.isEmpty, dimensions: dimensions,
                     lanes: lanes, summary: summary, mode: policy.mode,
                     qualificationIssues: Array(Set(issues)).sorted())
    }

    private static func validate(_ snapshot: Snapshot, label: String) -> [String] {
        let plan = snapshot.plan
        let record = snapshot.record
        var issues: [String] = []
        if record.id != plan.id || record.planID != plan.id
            || (try? ScenarioExecutionRecord.make(
                plan: plan, records: record.records,
                selectedAssessments: record.selectedAssessments ?? []
            ).evidenceDigest)
                != record.evidenceDigest {
            issues.append("\(label) execution record seal or plan binding is invalid.")
        }
        if let selection = snapshot.selectedAssessment, !selection.isBound(to: record) {
            issues.append("\(label) selected assessment is not bound to this immutable execution.")
        }
        if !ScenarioExecutionRecord.selectedAssessmentsAreBound(
            effectiveAssessments(snapshot), to: record.records
        ) {
            issues.append("\(label) selected assessment does not bind to its observed coordinate.")
        }
        if let definition = snapshot.definition {
            if !definition.hasValidDigest || definition.id != plan.definitionID
                || definition.definitionDigest != plan.definitionDigest
                || definition.testContractDigest != plan.testContractDigest
                || definition.fixture.digest != plan.fixtureContractDigest {
                issues.append("\(label) trusted frozen definition does not match the execution plan.")
            }
            let expectedCoordinates = ScenarioLane.allCases.flatMap { route -> [String] in
                guard definition.coverage[route] != .notApplicable else { return [] }
                let repetitions = route == .siri
                    ? max(1, definition.coverage.siriAttemptCount ?? 3) : 1
                return (1...repetitions).map { repetition in
                    "\(definition.id.uuidString):\(route.rawValue):\(repetition):\(definition.coverage[route] == .required)"
                }
            }
            if plan.coordinates.map(key).sorted() != expectedCoordinates.sorted() {
                issues.append("\(label) frozen route population does not match trusted requirements.")
            }
            for item in record.records where item.coordinate.required {
                guard let lane = item.laneResult else { continue }
                for assertion in definition.assertions where assertion.required
                    && assertion.applies(to: item.coordinate.lane) {
                    if assertion.kind == .semanticRubric {
                        let selected = selectedAssessments(for: lane, in: snapshot).filter {
                            $0.assertionID == assertion.id
                        }
                        if selected.count != 1 || selected[0].status == .unscored
                            || !selected[0].hasTrustedRequirementBinding(definition: definition, laneResult: lane) {
                            issues.append("\(label) lacks one bound selected semantic assessment at \(key(item.coordinate)).")
                        }
                    } else if lane.assertionResults.count(where: { $0.assertionID == assertion.id }) != 1 {
                        issues.append("\(label) lacks one deterministic assertion result at \(key(item.coordinate)).")
                    }
                }
            }
            for assessment in effectiveAssessments(snapshot) {
                guard let item = record.records.first(where: {
                    $0.evidenceLaneResultID == assessment.laneResultID
                }), let lane = item.laneResult,
                    assessment.hasTrustedRequirementBinding(definition: definition, laneResult: lane) else {
                    issues.append("\(label) selected assessment is not bound to trusted requirements.")
                    break
                }
            }
        } else if !effectiveAssessments(snapshot).isEmpty {
            issues.append("\(label) selected semantic assessment has no trusted frozen definition.")
        }
        if population(plan) == nil { issues.append("\(label) frozen coordinates are ambiguous.") }
        if !validDigest(plan.sourceInputsDigest) {
            issues.append("\(label) checked source provenance is missing.")
        }
        if !validDigest(plan.testProductDigest) {
            issues.append("\(label) checked test-product provenance is missing.")
        }
        let recordIDs = record.records.map(\.coordinate.id)
        if recordIDs.count != plan.coordinates.count
            || Set(recordIDs) != Set(plan.coordinates.map(\.id)) {
            issues.append("\(label) terminal coordinate population does not match its plan.")
        }
        let featureChildren = record.records.compactMap(\.featureChild)
        if Set(featureChildren.map(\.runID)).count != featureChildren.count
            || Set(featureChildren.map(\.sampleID)).count != featureChildren.count {
            issues.append("\(label) feature evidence is reused across coordinates.")
        }
        let referencedNativeIDs = record.records.filter { $0.coordinate.lane != .appFeature }
            .compactMap(\.evidenceRunID)
        if Set(referencedNativeIDs).count != referencedNativeIDs.count
            || Set(referencedNativeIDs) != Set(snapshot.runs.map(\.id))
            || snapshot.runs.count != referencedNativeIDs.count {
            issues.append("\(label) native child-run population is missing, repeated, or unrelated.")
        }
        for item in record.records {
            guard item.state == .completed, let lane = item.laneResult,
                  lane.executionStatus == .completed,
                  effectiveOutcome(lane, in: snapshot) != nil,
                  lane.id == item.evidenceLaneResultID,
                  lane.caseID == item.coordinate.caseID,
                  lane.lane == item.coordinate.lane,
                  lane.attempt == item.coordinate.repetition,
                  item.evidenceRunID != nil else {
                issues.append("\(label) has incomplete or misattributed evidence at \(key(item.coordinate)).")
                continue
            }
            if item.coordinate.required && effectiveOutcome(lane, in: snapshot) == .passed
                && lane.assertionResults.isEmpty && selectedAssessments(for: lane, in: snapshot).isEmpty {
                issues.append("\(label) passed \(key(item.coordinate)) without assessed requirements.")
            }
            if item.coordinate.lane == .appFeature {
                guard let child = item.featureChild, child.hasValidDigest,
                      child.hasVerifiedBuildBinding,
                      child.checkedAppProductDigest == plan.appProductDigest,
                      child.runnerBuildID == plan.runnerBuildID,
                      child.fixtureContractDigest == plan.fixtureContractDigest,
                      child.runID == item.evidenceRunID,
                      child.digest == item.evidenceDigest,
                      child.errorCategory == nil, child.errorMessage == nil,
                      validDigest(child.subjectInputDigest),
                      child.outputMetadata["intentlab.subjectInputDigest"] == child.subjectInputDigest,
                      validMeasurement(child.measurementImplementation),
                      lane.observations["feature.response"] == .string(child.response) else {
                    issues.append("\(label) App Feature child evidence lacks sealed input, build, measurement, or output binding at \(key(item.coordinate)).")
                    continue
                }
                if let definition = snapshot.definition,
                   (child.appBundleIdentifier != definition.target.bundleIdentifier
                    || child.featureID != definition.featureBinding?.featureID) {
                    issues.append("\(label) App Feature child does not match the trusted app and feature declaration at \(key(item.coordinate)).")
                }
            } else {
                guard let run = snapshot.runs.first(where: { $0.id == item.evidenceRunID }),
                      run.id == run.invocation.id,
                      run.scenarioSchemaVersion == ScenarioDefinition.stableSchemaVersion,
                      run.scenarioID == plan.definitionID,
                      run.scenarioVersion == plan.definitionVersion,
                      run.scenarioDigest == plan.definitionDigest,
                      run.testContractDigest == plan.testContractDigest,
                      run.invocation.scenarioDigest == plan.definitionDigest,
                      run.invocation.appProduct?.sha256 == plan.appProductDigest,
                      run.invocation.testProduct?.sha256 == plan.testProductDigest,
                      run.fixture?.digest == plan.fixtureContractDigest,
                      run.executedTestCount == 1,
                      run.xctestExitCode != nil,
                      (run.xctestExitCode == 0 || (
                          lane.outcome == .failed
                          && lane.assertionResults.contains(where: { !$0.passed })
                      )),
                      run.executionStatus == .completed,
                      validMeasurement(run.measurementImplementation),
                      validEnvironment(run.comparisonEnvironmentIdentity),
                      run.laneResults.count == 1,
                      run.laneResults[0] == lane else {
                    issues.append("\(label) native child evidence lacks bound invocation, build, fixture, or measurement at \(key(item.coordinate)).")
                    continue
                }
                if let definition = snapshot.definition,
                   run.invocation.appProduct?.bundleIdentifier != definition.target.bundleIdentifier {
                    issues.append("\(label) native child does not match the trusted app declaration at \(key(item.coordinate)).")
                }
            }
        }
        return issues
    }

    private static func compareFeature(
        _ lhs: ScenarioExecutionCoordinateRecord, _ rhs: ScenarioExecutionCoordinateRecord,
        mode: ScenarioComparisonMode, key: String, issues: inout [String]
    ) {
        guard let old = lhs.featureChild, let new = rhs.featureChild else { return }
        if old.runID == new.runID || old.sampleID == new.sampleID {
            issues.append("App Feature child evidence was reused across executions at \(key).")
        }
        if old.appBundleIdentifier != new.appBundleIdentifier
            || old.featureID != new.featureID || old.fixtureContractDigest != new.fixtureContractDigest
            || old.subjectInputDigest != new.subjectInputDigest {
            issues.append("App Feature input or logical binding changed at \(key).")
        }
        if old.measurementImplementation != new.measurementImplementation {
            issues.append("Measurement changed at \(key); establish a new qualification and baseline.")
        }
        if mode == .compareEnvironments,
           (old.checkedAppProductDigest != new.checkedAppProductDigest
            || old.featureVersion != new.featureVersion) {
            issues.append("App Feature implementation changed during environment comparison at \(key).")
        }
    }

    private static func compareNative(
        _ lhs: ScenarioExecutionCoordinateRecord, _ rhs: ScenarioExecutionCoordinateRecord,
        baseline: Snapshot, candidate: Snapshot, mode: ScenarioComparisonMode,
        key: String, issues: inout [String]
    ) {
        guard let oldID = lhs.evidenceRunID, let newID = rhs.evidenceRunID,
              let old = baseline.runs.first(where: { $0.id == oldID }),
              let new = candidate.runs.first(where: { $0.id == newID }) else { return }
        if oldID == newID {
            issues.append("Native child evidence was reused across executions at \(key).")
        }
        if old.invocation.appProduct?.bundleIdentifier != new.invocation.appProduct?.bundleIdentifier {
            issues.append("Native app identity changed at \(key).")
        }
        if old.measurementImplementation != new.measurementImplementation {
            issues.append("Measurement changed at \(key); establish a new qualification and baseline.")
        }
        if mode == .compareAppChanges,
           (old.comparisonEnvironmentIdentity != new.comparisonEnvironmentIdentity
            || environmentFacts(old.environment) != environmentFacts(new.environment)) {
            issues.append("The qualified native environment changed at \(key).")
        }
        if mode == .compareEnvironments {
            guard let oldSubject = old.subjectImplementation,
                  let newSubject = new.subjectImplementation,
                  oldSubject.modelRevision != nil, newSubject.modelRevision != nil,
                  oldSubject == newSubject else {
                issues.append("The native subject implementation is not proven fixed across environments at \(key).")
                return
            }
        }
    }

    private static func population(_ plan: ScenarioExecutionPlan) -> [String: ScenarioPlannedCoordinate]? {
        var result: [String: ScenarioPlannedCoordinate] = [:]
        for coordinate in plan.coordinates {
            let coordinateKey = key(coordinate)
            if result[coordinateKey] != nil { return nil }
            result[coordinateKey] = coordinate
        }
        return result
    }

    private static func population(_ plan: ScenarioExecutionPlan,
                                   _ record: ScenarioExecutionRecord) -> [String: ScenarioExecutionCoordinateRecord]? {
        guard let planned = population(plan), record.records.count == planned.count else { return nil }
        var result: [String: ScenarioExecutionCoordinateRecord] = [:]
        for item in record.records {
            let coordinateKey = key(item.coordinate)
            guard planned[coordinateKey] == item.coordinate, result[coordinateKey] == nil else { return nil }
            result[coordinateKey] = item
        }
        return result
    }

    private static func population(_ snapshot: Snapshot) -> [String: ScenarioExecutionCoordinateRecord]? {
        population(snapshot.plan, snapshot.record)
    }

    private static func key(_ coordinate: ScenarioPlannedCoordinate) -> String {
        "\(coordinate.caseID.uuidString):\(coordinate.lane.rawValue):\(coordinate.repetition):\(coordinate.required)"
    }

    private static func effectiveAssessments(_ snapshot: Snapshot) -> [ScenarioSelectedAssessmentProjection] {
        snapshot.selectedAssessment?.assessments ?? snapshot.record.selectedAssessments ?? []
    }

    private static func selectedAssessments(
        for lane: ScenarioLaneResult, in snapshot: Snapshot
    ) -> [ScenarioSelectedAssessmentProjection] {
        effectiveAssessments(snapshot).filter { $0.laneResultID == lane.id }
    }

    private static func effectiveOutcome(
        _ lane: ScenarioLaneResult, in snapshot: Snapshot
    ) -> ScenarioOutcome? {
        switch lane.outcome {
        case .passed, .failed: return lane.outcome
        case .needsReview:
            let selected = selectedAssessments(for: lane, in: snapshot)
            guard !selected.isEmpty, selected.allSatisfy({ $0.status != .unscored }) else { return nil }
            // Native evaluation records an unscored placeholder for semantic
            // assertions. A later judge selection can replace that placeholder,
            // but it cannot erase a failed deterministic requirement.
            let failedDeterministic = lane.assertionResults.contains { result in
                guard !result.passed else { return false }
                guard let assertion = snapshot.definition?.assertions.first(where: {
                    $0.id == result.assertionID
                }) else { return true }
                return assertion.required && assertion.applies(to: lane.lane)
                    && assertion.kind != .semanticRubric
            }
            if failedDeterministic { return .failed }
            return selected.contains(where: { $0.status == .failed }) ? .failed : .passed
        case .notObserved, .notApplicable: return nil
        }
    }

    private static func assessmentKey(_ value: ScenarioSelectedAssessmentProjection) -> String {
        "\(value.caseID.uuidString):\(value.lane.rawValue):\(value.attempt):\(value.observationKey)"
    }

    private static func compareAssessments(
        _ baseline: Snapshot, _ candidate: Snapshot, issues: inout [String]
    ) {
        let before = effectiveAssessments(baseline)
        let after = effectiveAssessments(candidate)
        let oldKeys = before.map(assessmentKey)
        let newKeys = after.map(assessmentKey)
        if Set(oldKeys).count != oldKeys.count || Set(newKeys).count != newKeys.count
            || Set(oldKeys) != Set(newKeys) {
            issues.append("Selected semantic assessment population changed or is ambiguous.")
        }
        let oldMap = Dictionary(grouping: before, by: assessmentKey)
        let newMap = Dictionary(grouping: after, by: assessmentKey)
        for key in Set(oldMap.keys).intersection(newMap.keys) {
            guard let old = oldMap[key]?.first, let new = newMap[key]?.first else { continue }
            if old.status == .unscored || new.status == .unscored {
                issues.append("Selected semantic assessment is unscored at \(key).")
            }
            if old.verifiedReferenceDigest != new.verifiedReferenceDigest
                || old.rubricDigest != new.rubricDigest {
                issues.append("Requirements changed in semantic assessment at \(key).")
            }
            if old.scoringContractDigest != new.scoringContractDigest
                || old.judgePolicyDigest != new.judgePolicyDigest
                || old.judgePromptVersion != new.judgePromptVersion
                || old.requestedJudgeModelID != new.requestedJudgeModelID
                || old.reportedJudgeModelID != new.reportedJudgeModelID
                || old.judgeConnectionID != new.judgeConnectionID {
                issues.append("Measurement changed in selected semantic assessment at \(key).")
            }
        }
    }

    private static func laneSummaries(_ baseline: Snapshot,
                                      _ candidate: Snapshot) -> [ScenarioLaneComparison] {
        ScenarioLane.allCases.map { lane in
            let before = baseline.record.records.filter { $0.coordinate.lane == lane }
            let after = candidate.record.records.filter { $0.coordinate.lane == lane }
            let beforeOutcomes = before.map { outcomeKey($0, in: baseline) }.sorted()
            let afterOutcomes = after.map { outcomeKey($0, in: candidate) }.sorted()
            return .init(lane: lane,
                         baselinePassed: before.count { passing($0, in: baseline) },
                         baselineAttempted: before.count,
                         candidatePassed: after.count { passing($0, in: candidate) },
                         candidateAttempted: after.count,
                         changedOutcome: beforeOutcomes != afterOutcomes)
        }
    }

    private static func outcomeKey(
        _ item: ScenarioExecutionCoordinateRecord, in snapshot: Snapshot
    ) -> String {
        let outcome = item.laneResult.flatMap { effectiveOutcome($0, in: snapshot) }
        return key(item.coordinate) + ":" + (outcome?.rawValue ?? "missing")
    }

    private static func passing(
        _ item: ScenarioExecutionCoordinateRecord, in snapshot: Snapshot
    ) -> Bool {
        item.laneResult.flatMap { effectiveOutcome($0, in: snapshot) } == .passed
    }

    private static func validDigest(_ digest: String?) -> Bool {
        guard let digest, digest.count == 64 else { return false }
        return digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validMeasurement(_ identity: ScenarioMeasurementImplementation?) -> Bool {
        guard let identity, identity.hasCompleteProvenance else { return false }
        return validDigest(identity.observerDigest) && validDigest(identity.evaluatorDigest)
    }

    private static func validEnvironment(_ identity: ScenarioEnvironmentIdentity?) -> Bool {
        guard let identity, identity.hasCompleteProvenance else { return false }
        return validDigest(identity.profileDigest)
    }

    private static func profileFacts(_ profile: ScenarioExecutionProfile) -> [String] {
        [profile.destinationIdentifier, profile.signingSelection ?? "",
         profile.buildConfiguration ?? "", profile.scheme, profile.testTarget]
    }

    private static func environmentFacts(_ environment: ScenarioEnvironment) -> [String] {
        [environment.xcodeVersion, environment.sdkVersion,
         environment.deviceModel, environment.operatingSystem,
         environment.operatingSystemBuild ?? "unknown",
         environment.languageCode, environment.regionCode,
         environment.timeZoneIdentifier,
         environment.siriConfiguration ?? "unknown",
         environment.siriConfigurationSource?.rawValue ?? "unknown"]
    }

    private static func dimension(_ name: String, _ baseline: String, _ candidate: String,
                                  compatible: Bool? = nil) -> ScenarioComparisonDimension {
        .init(name: name, baseline: baseline, candidate: candidate,
              compatible: compatible ?? (baseline == candidate))
    }
}
