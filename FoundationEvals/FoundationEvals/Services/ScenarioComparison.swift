import Foundation

struct ScenarioComparisonDimension: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var baseline: String
    var candidate: String
    var compatible: Bool
}

struct ScenarioLaneComparison: Codable, Equatable, Identifiable, Sendable {
    var id: ScenarioLane { lane }
    var lane: ScenarioLane
    var baselinePassed: Int
    var baselineAttempted: Int
    var candidatePassed: Int
    var candidateAttempted: Int
    var changedOutcome: Bool
}

struct ScenarioComparisonReport: Codable, Equatable, Sendable {
    var isDirectlyComparable: Bool
    var dimensions: [ScenarioComparisonDimension]
    var lanes: [ScenarioLaneComparison]
    var summary: String
    var mode: ScenarioComparisonMode? = nil
    var qualificationIssues: [String]? = nil
}

enum ScenarioComparisonMode: String, Codable, CaseIterable, Sendable {
    case compareAppChanges
    case compareEnvironments
    case sideBySideInspection
}

struct ScenarioComparisonPolicy: Codable, Equatable, Sendable {
    var mode: ScenarioComparisonMode
    var baselineRunID: UUID
    /// Required for environment comparisons; values must identify the frozen
    /// before/after profiles, not names inferred from saved result labels.
    var baselineEnvironmentID: String? = nil
    var candidateEnvironmentID: String? = nil
}

enum ScenarioComparison {
    static func compare(
        baseline: ScenarioRun,
        candidate: ScenarioRun,
        statedChangedDimensions: Set<String>? = nil
    ) -> ScenarioComparisonReport {
        if baseline.scenarioSchemaVersion == ScenarioDefinition.stableSchemaVersion
            || candidate.scenarioSchemaVersion == ScenarioDefinition.stableSchemaVersion
            || baseline.testContractDigest != nil || candidate.testContractDigest != nil {
            return compare(baseline: baseline, candidate: candidate,
                           policy: .init(mode: .compareAppChanges, baselineRunID: baseline.id))
        }
        let statedChangedDimensions = statedChangedDimensions
            ?? candidate.statedChangedDimensions
            ?? []
        let dimensions = [
            dimension("scenarioDigest", baseline.scenarioDigest, candidate.scenarioDigest),
            dimension("fixtureID", baseline.fixture?.id ?? "unknown", candidate.fixture?.id ?? "unknown"),
            dimension("fixtureVersion", baseline.fixture?.version ?? "unknown", candidate.fixture?.version ?? "unknown"),
            dimension("fixtureDigest", baseline.fixture?.digest ?? "unknown", candidate.fixture?.digest ?? "unknown"),
            dimension("integrationID", baseline.integration?.id ?? "legacy/unspecified", candidate.integration?.id ?? "legacy/unspecified"),
            dimension("integrationVersion", baseline.integration?.version ?? "legacy/unspecified", candidate.integration?.version ?? "legacy/unspecified"),
            dimension("integrationDigest", baseline.integration?.digest ?? "legacy/unspecified", candidate.integration?.digest ?? "legacy/unspecified"),
            dimension("runnerPackageVersion", baseline.runnerPackageVersion ?? "legacy/unspecified", candidate.runnerPackageVersion ?? "legacy/unspecified"),
            dimension("negotiatedCapabilities", baseline.negotiatedCapabilities?.sorted().joined(separator: ",") ?? "legacy/unspecified",
                      candidate.negotiatedCapabilities?.sorted().joined(separator: ",") ?? "legacy/unspecified"),
            dimension("appBuild", baseline.invocation.appProduct?.sha256 ?? "unknown", candidate.invocation.appProduct?.sha256 ?? "unknown"),
            dimension("testBuild", baseline.invocation.testProduct?.sha256 ?? "unknown", candidate.invocation.testProduct?.sha256 ?? "unknown"),
            dimension("Xcode", baseline.environment.xcodeVersion, candidate.environment.xcodeVersion),
            dimension("SDK", baseline.environment.sdkVersion, candidate.environment.sdkVersion),
            dimension("device", baseline.environment.deviceModel, candidate.environment.deviceModel),
            dimension("operatingSystem", baseline.environment.operatingSystem, candidate.environment.operatingSystem),
            dimension("operatingSystemBuild", baseline.environment.operatingSystemBuild ?? "unknown", candidate.environment.operatingSystemBuild ?? "unknown"),
            dimension("language", baseline.environment.languageCode, candidate.environment.languageCode),
            dimension("region", baseline.environment.regionCode, candidate.environment.regionCode),
            dimension("timeZone", baseline.environment.timeZoneIdentifier, candidate.environment.timeZoneIdentifier),
            dimension("siriConfiguration", baseline.environment.siriConfiguration ?? "unknown", candidate.environment.siriConfiguration ?? "unknown"),
            dimension("siriConfigurationSource", baseline.environment.siriConfigurationSource?.rawValue ?? "unknown", candidate.environment.siriConfigurationSource?.rawValue ?? "unknown")
        ].map { value in
            statedChangedDimensions.contains(value.name)
                ? .init(name: value.name, baseline: value.baseline, candidate: value.candidate, compatible: true)
                : value
        }
        let lanes = ScenarioLane.allCases.map { lane in
            let before = baseline.laneResults.filter { $0.lane == lane }
            let after = candidate.laneResults.filter { $0.lane == lane }
            return ScenarioLaneComparison(
                lane: lane,
                baselinePassed: before.count { $0.outcome == .passed },
                baselineAttempted: before.count,
                candidatePassed: after.count { $0.outcome == .passed },
                candidateAttempted: after.count,
                changedOutcome: before.map(\.outcome) != after.map(\.outcome)
            )
        }
        let compatible = dimensions.allSatisfy(\.compatible)
            && baseline.scenarioID == candidate.scenarioID
            && baseline.scenarioVersion == candidate.scenarioVersion
        let changedLanes = lanes.filter(\.changedOutcome).map { $0.lane.title }
        let summary: String
        if !compatible {
            summary = "The runs are not directly comparable because one or more unstated scenario or environment dimensions changed."
        } else if changedLanes.isEmpty {
            summary = "The retained attempt outcomes did not change in any evidence lane."
        } else {
            summary = "Outcome changes were observed in: \(changedLanes.joined(separator: ", "))."
        }
        return .init(isDirectlyComparable: compatible, dimensions: dimensions, lanes: lanes, summary: summary)
    }

    static func compare(
        baseline: ScenarioRun,
        candidate: ScenarioRun,
        policy: ScenarioComparisonPolicy
    ) -> ScenarioComparisonReport {
        // A typed v3 comparison never consults statedChangedDimensions.
        let contract = dimension("testContractDigest", baseline.testContractDigest ?? "unknown",
                                 candidate.testContractDigest ?? "unknown")
        let measurement = dimension("measurementImplementation",
                                    identity(baseline.measurementImplementation),
                                    identity(candidate.measurementImplementation))
        let environment = dimension("environmentProfile",
                                    identity(baseline.comparisonEnvironmentIdentity),
                                    identity(candidate.comparisonEnvironmentIdentity))
        let appBuild = dimension("appBuild", baseline.invocation.appProduct?.sha256 ?? "unknown",
                                 candidate.invocation.appProduct?.sha256 ?? "unknown")
        let subject = dimension("subjectImplementation", identity(baseline.subjectImplementation),
                                 identity(candidate.subjectImplementation))
        let environmentFacts = [
            dimension("Xcode", baseline.environment.xcodeVersion, candidate.environment.xcodeVersion),
            dimension("SDK", baseline.environment.sdkVersion, candidate.environment.sdkVersion),
            dimension("device", baseline.environment.deviceModel, candidate.environment.deviceModel),
            dimension("operatingSystem", baseline.environment.operatingSystem, candidate.environment.operatingSystem),
            dimension("operatingSystemBuild", baseline.environment.operatingSystemBuild ?? "unknown", candidate.environment.operatingSystemBuild ?? "unknown"),
            dimension("language", baseline.environment.languageCode, candidate.environment.languageCode),
            dimension("region", baseline.environment.regionCode, candidate.environment.regionCode),
            dimension("timeZone", baseline.environment.timeZoneIdentifier, candidate.environment.timeZoneIdentifier),
            dimension("siriConfiguration", baseline.environment.siriConfiguration ?? "unknown", candidate.environment.siriConfiguration ?? "unknown"),
            dimension("siriConfigurationSource", baseline.environment.siriConfigurationSource?.rawValue ?? "unknown",
                      candidate.environment.siriConfigurationSource?.rawValue ?? "unknown")
        ]
        var issues: [String] = []
        if baseline.id != policy.baselineRunID { issues.append("The selected baseline does not match the comparison policy.") }
        if baseline.id == candidate.id { issues.append("The comparison needs two distinct execution records.") }
        if baseline.scenarioID != candidate.scenarioID { issues.append("The case identity changed.") }
        if baseline.scenarioSchemaVersion != ScenarioDefinition.stableSchemaVersion
            || candidate.scenarioSchemaVersion != ScenarioDefinition.stableSchemaVersion {
            issues.append("The runs do not both carry version 3 provenance.")
        }
        if baseline.invocation.scenarioDigest != baseline.scenarioDigest
            || candidate.invocation.scenarioDigest != candidate.scenarioDigest {
            issues.append("Execution evidence is not bound to its frozen definition.")
        }
        let baselineCoordinates = baseline.laneResults.map(EvidenceCoordinate.init)
        let candidateCoordinates = candidate.laneResults.map(EvidenceCoordinate.init)
        if baselineCoordinates.isEmpty || candidateCoordinates.isEmpty
            || Set(baselineCoordinates).count != baselineCoordinates.count
            || Set(candidateCoordinates).count != candidateCoordinates.count
            || Set(baselineCoordinates) != Set(candidateCoordinates) {
            issues.append("Case, route, or attempt coverage changed or is ambiguous.")
        }
        if baseline.executionStatus != .completed || candidate.executionStatus != .completed
            || (baseline.laneResults + candidate.laneResults).contains(where: {
                $0.executionStatus != .completed
                    || ($0.outcome != .passed && $0.outcome != .failed)
            }) {
            issues.append("Execution or observed outcomes are incomplete.")
        }
        if !validContractDigest(baseline.testContractDigest) || !validContractDigest(candidate.testContractDigest) {
            issues.append("Requirements provenance is missing.")
        } else if !contract.compatible {
            issues.append("Requirements changed.")
        }
        if baseline.measurementImplementation?.hasCompleteProvenance != true
            || candidate.measurementImplementation?.hasCompleteProvenance != true {
            issues.append("Measurement implementation provenance is missing.")
        } else if !measurement.compatible {
            issues.append("Measurement changed; establish a new qualification and baseline.")
        }
        if baseline.comparisonEnvironmentIdentity?.hasCompleteProvenance != true
            || candidate.comparisonEnvironmentIdentity?.hasCompleteProvenance != true {
            issues.append("Qualified environment profile provenance is missing.")
        }
        if !known(baseline.invocation.appProduct?.sha256)
            || !known(candidate.invocation.appProduct?.sha256) {
            issues.append("App build identity is missing; an exact-build claim cannot be qualified.")
        }
        switch policy.mode {
        case .compareAppChanges:
            if !environment.compatible || environmentFacts.contains(where: { !$0.compatible }) {
                issues.append("The qualified environment changed.")
            }
        case .compareEnvironments:
            if policy.baselineEnvironmentID != baseline.comparisonEnvironmentIdentity?.profileID
                || policy.candidateEnvironmentID != candidate.comparisonEnvironmentIdentity?.profileID
                || policy.baselineEnvironmentID == policy.candidateEnvironmentID {
                issues.append("Explicit, different before/after environment identities are required.")
            }
            if !appBuild.compatible || !subject.compatible
                || baseline.subjectImplementation == nil || candidate.subjectImplementation == nil
                || baseline.subjectImplementation?.modelRevision == nil
                || candidate.subjectImplementation?.modelRevision == nil {
                issues.append("The subject implementation is not proven fixed across environments.")
            }
        case .sideBySideInspection:
            issues.append("Side-by-side inspection does not qualify a fix.")
        }
        let lanes = laneComparisons(baseline: baseline, candidate: candidate)
        let changedLanes = lanes.filter(\.changedOutcome).map { $0.lane.title }
        let improvedLanes = lanes.filter { $0.candidatePassed > $0.baselinePassed
            && $0.candidateAttempted == $0.baselineAttempted }.map { $0.lane.title }
        let summary = issues.isEmpty
            ? (improvedLanes.isEmpty
               ? (changedLanes.isEmpty ? "The retained attempt outcomes did not change in any evidence lane."
                  : "Outcome changes were observed in: \(changedLanes.joined(separator: ", ")).")
               : "Observed improvement in: \(improvedLanes.joined(separator: ", ")).")
            : issues.joined(separator: " ")
        return .init(isDirectlyComparable: issues.isEmpty,
                     dimensions: [contract, measurement, environment, appBuild, subject] + environmentFacts,
                     lanes: lanes, summary: summary, mode: policy.mode, qualificationIssues: issues)
    }

    private static func laneComparisons(baseline: ScenarioRun, candidate: ScenarioRun) -> [ScenarioLaneComparison] {
        ScenarioLane.allCases.map { lane in
            let before = baseline.laneResults.filter { $0.lane == lane }
            let after = candidate.laneResults.filter { $0.lane == lane }
            return .init(lane: lane, baselinePassed: before.count { $0.outcome == .passed },
                         baselineAttempted: before.count, candidatePassed: after.count { $0.outcome == .passed },
                         candidateAttempted: after.count,
                         changedOutcome: before.map(outcomeAtCoordinate).sorted()
                            != after.map(outcomeAtCoordinate).sorted())
        }
    }

    private struct EvidenceCoordinate: Hashable {
        var caseID: UUID
        var lane: ScenarioLane
        var attempt: Int
        init(_ result: ScenarioLaneResult) {
            caseID = result.caseID
            lane = result.lane
            attempt = result.attempt
        }
    }

    private static func outcomeAtCoordinate(_ result: ScenarioLaneResult) -> String {
        "\(result.caseID.uuidString):\(result.attempt):\(result.executionStatus.rawValue):\(result.outcome.rawValue)"
    }

    private static func identity(_ value: ScenarioMeasurementImplementation?) -> String {
        guard let value else { return "unknown" }
        return [value.observerID, value.observerDigest, value.evaluatorID, value.evaluatorDigest].joined(separator: ":")
    }

    private static func identity(_ value: ScenarioEnvironmentIdentity?) -> String {
        guard let value else { return "unknown" }
        return value.profileID + ":" + value.profileDigest
    }

    private static func identity(_ value: ScenarioSubjectImplementation?) -> String {
        guard let value else { return "unknown" }
        return [value.sourceRevision ?? "unknown", value.promptDigest ?? "unknown", value.modelRevision ?? "unknown"].joined(separator: ":")
    }

    private static func known(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty && value.lowercased() != "unknown" && value != "legacy/unspecified"
    }

    private static func validContractDigest(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }


    private static func dimension(_ name: String, _ baseline: String, _ candidate: String) -> ScenarioComparisonDimension {
        .init(name: name, baseline: baseline, candidate: candidate, compatible: baseline == candidate)
    }
}

enum ScenarioReleaseCheckOutcome: String, Codable, Sendable {
    case passed
    case failed
    case incompleteOrIncompatibleEvidence
}

struct ScenarioReleaseCheckReport: Codable, Equatable, Sendable {
    var scenarioID: UUID
    var runID: UUID?
    var outcome: ScenarioReleaseCheckOutcome
    var summary: String
    var failures: [String]
    var generatedAt: Date
    var policyVersion: String? = nil
}

enum ScenarioReleaseCheckEvaluator {
    static let reusablePolicyVersion = "intent-lab-report-v2"
    static func report(
        definition: ScenarioDefinition,
        run: ScenarioRun?,
        comparison: ScenarioComparisonReport? = nil,
        journalAccepted: Bool? = nil
    ) -> ScenarioReleaseCheckReport {
        var failures: [String] = []
        if definition.schemaVersion >= ScenarioDefinition.reusableSchemaVersion,
           definition.purpose != .releaseRequirement {
            failures.append("Exploratory checks do not qualify as release requirements.")
        }
        if definition.schemaVersion >= ScenarioDefinition.reusableSchemaVersion,
           ScenarioValidator.issues(in: definition).contains(where: { $0.severity == .error }) {
            failures.append("The scenario definition is invalid or its frozen digest changed.")
        }
        guard let run else {
            var report = ScenarioReleaseCheckReport(
                scenarioID: definition.id,
                runID: nil,
                outcome: .incompleteOrIncompatibleEvidence,
                summary: "No imported scenario run is available.",
                failures: failures + ["Run the current frozen scenario and import its bound evidence."],
                generatedAt: Date()
            )
            if definition.schemaVersion >= ScenarioDefinition.reusableSchemaVersion {
                report.policyVersion = reusablePolicyVersion
            }
            return report
        }
        if run.scenarioID != definition.id || run.scenarioVersion != definition.version
            || run.scenarioDigest != definition.definitionDigest || !definition.hasValidDigest {
            failures.append("The run does not match the current frozen scenario definition.")
        }
        if definition.schemaVersion == ScenarioDefinition.stableSchemaVersion {
            if run.scenarioSchemaVersion != ScenarioDefinition.stableSchemaVersion
                || run.testContractDigest != definition.testContractDigest
                || run.invocation.scenarioDigest != definition.definitionDigest {
                failures.append("The run lacks matching stable requirement provenance.")
            }
            if run.measurementImplementation?.hasCompleteProvenance != true
                || run.comparisonEnvironmentIdentity?.hasCompleteProvenance != true {
                failures.append("The run lacks measurement or qualified environment provenance.")
            }
        }
        if run.executionStatus != .completed {
            failures.append("The scenario execution did not complete successfully.")
        }
        if journalAccepted == false {
            failures.append("The run's execution journal has not accepted its final evidence.")
        }
        if run.xctestExitCode == nil {
            failures.append("The saved run does not record a successful XCTest exit, so its release evidence is incomplete.")
        } else if let exitCode = run.xctestExitCode, exitCode != 0 {
            failures.append("XCTest failed with exit code \(exitCode). Its retained evidence is diagnostic only.")
        }
        if !ScenarioLane.allCases.contains(where: { definition.coverage[$0] == .required }) {
            failures.append("The scenario has no required evidence lane, so it cannot gate a release.")
        }
        let requiredObservableAssertions = definition.assertions.filter { assertion in
            assertion.required && ScenarioLane.allCases.contains {
                definition.coverage[$0] == .required && assertion.applies(to: $0)
            }
        }
        if requiredObservableAssertions.isEmpty {
            failures.append("The scenario has no required observable outcome assertion in a required lane.")
        }
        if definition.schemaVersion >= ScenarioDefinition.reusableSchemaVersion {
            if run.acceptanceStatus != .accepted {
                failures.append("The saved run has no verified durable acceptance receipt for its execution journal.")
            }
            if run.integration != definition.integration
                || run.runnerPackageVersion?.isEmpty != false
                || !ScenarioHarnessCapabilities.required(for: definition).isSubset(
                    of: Set(run.negotiatedCapabilities ?? [])
                ) {
                failures.append("The saved run lacks compatible integration and runner capability evidence.")
            }
            if Set(definition.requiredClaims ?? []) == Set([.executionCompleted]) {
                failures.append("Execution-only evidence cannot satisfy a release requirement.")
            }
            if ScenarioResultEvaluator.overall(definition: definition, laneResults: run.laneResults) != .passed {
                failures.append("The required proof claims are not supported by verified observations.")
            }
        }
        for lane in ScenarioLane.allCases where definition.coverage[lane] == .required {
            if !definition.assertions.contains(where: { $0.required && $0.applies(to: lane) }) {
                failures.append("The required \(lane.title) lane has no required observable outcome assertion.")
            }
            let results = run.laneResults.filter { $0.lane == lane }
            if results.isEmpty {
                failures.append("The required \(lane.title) lane is missing.")
            } else if results.contains(where: { $0.executionStatus != .completed || $0.outcome != .passed }) {
                failures.append("The required \(lane.title) lane is incomplete or failed.")
            }
        }
        let requiredAssertionMissingOrFailed = run.laneResults.contains { laneResult in
            guard definition.coverage[laneResult.lane] == .required else { return false }
            let requiredIDs = Set(definition.assertions.filter {
                $0.required && $0.applies(to: laneResult.lane)
            }.map(\.id))
            return requiredIDs.contains { requiredID in
                let matches = laneResult.assertionResults.filter { $0.assertionID == requiredID }
                return matches.count != 1 || !matches[0].passed
            }
        }
        if requiredAssertionMissingOrFailed {
            failures.append("One or more required observable outcome assertions are missing or failed.")
        }
        if definition.schemaVersion < ScenarioDefinition.stableSchemaVersion,
           comparison?.isDirectlyComparable == false {
            failures.append("The run is not directly comparable with the preceding scenario run because an environment or scenario dimension changed without being stated.")
        }
        let outcome: ScenarioReleaseCheckOutcome
        if failures.isEmpty {
            outcome = .passed
        } else if run.outcome == .failed {
            outcome = .failed
        } else {
            outcome = .incompleteOrIncompatibleEvidence
        }
        let successfulSummary: String
        if definition.schemaVersion == ScenarioDefinition.stableSchemaVersion,
           let comparison, !comparison.isDirectlyComparable {
            successfulSummary = "Absolute requirements passed. Previous-run comparison: \(comparison.summary)"
        } else {
            successfulSummary = "Every required scenario lane passed with current compatible evidence."
        }
        var report = ScenarioReleaseCheckReport(
            scenarioID: definition.id,
            runID: run.id,
            outcome: outcome,
            summary: failures.isEmpty
                ? successfulSummary
                : "The scenario cannot satisfy the release requirement.",
            failures: failures,
            generatedAt: Date()
        )
        if definition.schemaVersion >= ScenarioDefinition.reusableSchemaVersion {
            report.policyVersion = reusablePolicyVersion
        }
        return report
    }

    static func acceptedJournal(for run: ScenarioRun, in journals: [ScenarioExecutionJournal]) -> Bool {
        journals.contains { journal in
            journal.id == run.id &&
            journal.invocation.nonce == run.invocation.nonce &&
            journal.invocation.testIdentity == run.invocation.testIdentity &&
            journal.invocation.harnessVersion == run.invocation.harnessVersion &&
            journal.invocation.destinationIdentifier == run.invocation.destinationIdentifier &&
            journal.invocation.scenarioDigest == run.invocation.scenarioDigest &&
            journal.invocation.resultBundleIdentity == run.invocation.resultBundleIdentity &&
            journal.invocation.appProduct == run.invocation.appProduct &&
            journal.invocation.testProduct == run.invocation.testProduct &&
            journal.scenarioID == run.scenarioID &&
            journal.scenarioVersion == run.scenarioVersion &&
            journal.phase == .stopped && journal.evidenceAccepted == true
        }
    }
}
