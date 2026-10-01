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
}

enum ScenarioComparison {
    static func compare(
        baseline: ScenarioRun,
        candidate: ScenarioRun,
        statedChangedDimensions: Set<String>? = nil
    ) -> ScenarioComparisonReport {
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
        comparison: ScenarioComparisonReport? = nil
    ) -> ScenarioReleaseCheckReport {
        var failures: [String] = []
        if definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion,
           definition.purpose != .releaseRequirement {
            failures.append("Exploratory checks do not qualify as release requirements.")
        }
        if definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion,
           ScenarioValidator.issues(in: definition).contains(where: { $0.severity == .error }) {
            failures.append("The version 2 scenario definition is invalid or its frozen digest changed.")
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
            if definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion {
                report.policyVersion = reusablePolicyVersion
            }
            return report
        }
        if run.scenarioID != definition.id || run.scenarioVersion != definition.version
            || run.scenarioDigest != definition.definitionDigest || !definition.hasValidDigest {
            failures.append("The run does not match the current frozen scenario definition.")
        }
        if run.executionStatus != .completed {
            failures.append("The scenario execution did not complete successfully.")
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
        if definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion {
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
        if comparison?.isDirectlyComparable == false {
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
        var report = ScenarioReleaseCheckReport(
            scenarioID: definition.id,
            runID: run.id,
            outcome: outcome,
            summary: failures.isEmpty
                ? "Every required scenario lane passed with current compatible evidence."
                : "The scenario cannot satisfy the release requirement.",
            failures: failures,
            generatedAt: Date()
        )
        if definition.schemaVersion == ScenarioDefinition.reusableSchemaVersion {
            report.policyVersion = reusablePolicyVersion
        }
        return report
    }
}
