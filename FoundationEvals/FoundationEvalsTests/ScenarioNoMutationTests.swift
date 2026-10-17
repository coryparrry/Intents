import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioNoMutationTests {
    @Test func dateExpectationsMatchExactInstantsWithoutChangingFrozenIdentity() throws {
        let instant = Date(timeIntervalSince1970: 1_700_000_000.375)
        let expected = ScenarioValue.date(.init(
            source: "Authored in the local calendar", timeZoneIdentifier: "Europe/London",
            resolvedInstant: instant
        ))
        let actual = ScenarioValue.date(.init(
            source: ISO8601DateFormatter().string(from: instant), timeZoneIdentifier: "UTC",
            resolvedInstant: instant
        ))
        let later = ScenarioValue.date(.init(
            source: ISO8601DateFormatter().string(from: instant), timeZoneIdentifier: "UTC",
            resolvedInstant: instant.addingTimeInterval(0.125)
        ))
        #expect(actual != expected)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(try encoder.encode(actual) != encoder.encode(expected))
        let vectors: [(ScenarioValue, ScenarioValue, Bool)] = [
            (expected, actual, true), (expected, later, false),
            (.array([expected, .null]), .array([actual, .null]), true),
            (.array([.array([expected])]), .array([.array([actual])]), true),
            (.array([expected, later]), .array([later, actual]), false),
            (.array([expected]), .array([actual, actual]), false),
            (expected, .string(ISO8601DateFormatter().string(from: instant)), false)
        ]
        for (expected, observed, shouldPass) in vectors {
            var definition = ScenarioDefinition.starter()
            definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
            definition.actionRequirements = nil
            definition.actionPolicyVersion = nil
            definition.coverage = .init(appFeature: .notApplicable, intentIntegration: .required,
                                        siri: .notApplicable)
            definition.assertions = [.init(kind: .returnedField, observationKey: "when",
                expectedValue: expected, explanation: "Return the exact requested instant.",
                applicableLanes: [.intentIntegration])]
            definition.observationPlan = [.init(id: "when", source: .intentResult)]
            definition.requiredClaims = [.executionCompleted, .returnedValueChecked]
            definition = try definition.frozen()
            var differentRepresentation = definition
            differentRepresentation.assertions[0].expectedValue = observed
            differentRepresentation = try differentRepresentation.frozen()
            #expect(differentRepresentation.definitionDigest != definition.definitionDigest)
            let evaluated = ScenarioResultEvaluator.evaluate(
                definition: definition, lane: .intentIntegration,
                observations: ["when": observed], executionStatus: .completed
            )
            #expect(evaluated.0 == (shouldPass ? .passed : .failed))
            let lane = ScenarioLaneResult(caseID: definition.id, attempt: 1, lane: .intentIntegration,
                executionStatus: .completed, outcome: evaluated.0, startedAt: instant, completedAt: instant,
                observations: ["when": observed], assertionResults: evaluated.1,
                observationSources: ["when": .appIntentsTesting],
                claims: [.executionCompleted, .returnedValueChecked])
            #expect(ScenarioResultEvaluator.verifiedClaim(.returnedValueChecked,
                definition: definition, result: lane) == shouldPass)
            #expect(ScenarioResultEvaluator.overall(definition: definition, laneResults: [lane])
                == (shouldPass ? .passed : .failed))
        }
        #expect(!ScenarioValueComparison.matches(nil, expected))
        #expect(!ScenarioValueComparison.matches(nil, nil))
        #expect(ScenarioValueComparison.matches(.null, .null))
    }

    @Test func dateNoMutationUsesTheExactInstantForBaselineAndExpectedValue() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000.375)
        let expected = ScenarioValue.date(.init(source: "Local date", timeZoneIdentifier: "America/New_York",
                                                resolvedInstant: instant))
        let actual = ScenarioValue.date(.init(source: "Projected date", timeZoneIdentifier: "UTC",
                                              resolvedInstant: instant))
        let changed = ScenarioValue.date(.init(source: "Projected date", timeZoneIdentifier: "UTC",
                                               resolvedInstant: instant.addingTimeInterval(0.125)))
        var definition = ScenarioDefinition.starter()
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.actionRequirements = nil
        definition.actionPolicyVersion = nil
        definition.assertions = [.init(kind: .noMutation, observationKey: "dueDates",
            expectedValue: .array([expected]), explanation: "Preserve the exact due dates.",
            applicableLanes: [.intentIntegration])]
        definition.observationPlan = [.init(id: "dueDates", source: .testOnlyIntent, operationID: "readDates")]
        for (baseline, outcome) in [
            (ScenarioValue?.some(.array([expected])), ScenarioOutcome.passed),
            (.some(.array([changed])), .failed), (nil, .notObserved)
        ] {
            let before = baseline.map { ["dueDates": $0] }
            let evaluated = ScenarioResultEvaluator.evaluate(
                definition: definition, lane: .intentIntegration,
                observations: ["dueDates": .array([actual])], executionStatus: .completed,
                beforeObservations: before
            )
            #expect(evaluated.0 == outcome)
            let lane = ScenarioLaneResult(caseID: definition.id, attempt: 1, lane: .intentIntegration,
                executionStatus: .completed, outcome: evaluated.0, startedAt: instant, completedAt: instant,
                observations: ["dueDates": .array([actual])], assertionResults: evaluated.1,
                observationSources: ["dueDates": .testOnlyIntent], claims: [.applicationStateChecked],
                beforeObservations: before)
            #expect(ScenarioResultEvaluator.verifiedClaim(.applicationStateChecked,
                definition: definition, result: lane) == (outcome == .passed))
        }
    }

    @Test func stableCheckRequiresTheObservedStateToRemainUnchanged() {
        var definition = ScenarioDefinition.starter()
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.assertions = [.init(
            kind: .noMutation, observationKey: "unrelatedFlag",
            expectedValue: .boolean(true), explanation: "Unrelated state stayed true.",
            applicableLanes: [.intentIntegration]
        )]
        let result = ScenarioResultEvaluator.evaluate(
            definition: definition, lane: .intentIntegration,
            observations: ["unrelatedFlag": .boolean(true)], executionStatus: .completed,
            beforeObservations: ["unrelatedFlag": .boolean(false)]
        )
        #expect(result.0 == .failed)
        #expect(result.1.first?.passed == false)
    }

    @Test func absentBaselineDoesNotQualifyAnUnchangedStateCheck() {
        var definition = ScenarioDefinition.starter()
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.assertions = [.init(
            kind: .noMutation, observationKey: "unrelatedFlag",
            expectedValue: .boolean(true), explanation: "Unrelated state stayed true.",
            applicableLanes: [.intentIntegration]
        )]
        #expect(ScenarioResultEvaluator.evaluate(
            definition: definition, lane: .intentIntegration,
            observations: ["unrelatedFlag": .boolean(true)], executionStatus: .completed
        ).0 == .notObserved)
        #expect(ScenarioResultEvaluator.evaluate(
            definition: definition, lane: .intentIntegration,
            observations: ["unrelatedFlag": .boolean(true)], executionStatus: .completed,
            beforeObservations: ["unrelatedFlag": .boolean(true)]
        ).0 == .passed)
    }

    @Test func historicalFinalValueSemanticsRemainAvailable() {
        var definition = ScenarioDefinition.starter()
        definition.assertions = [.init(
            kind: .noMutation, observationKey: "unrelatedFlag",
            expectedValue: .boolean(true), explanation: "Historical final-value check.",
            applicableLanes: [.intentIntegration]
        )]
        #expect(ScenarioResultEvaluator.evaluate(
            definition: definition, lane: .intentIntegration,
            observations: ["unrelatedFlag": .boolean(true)], executionStatus: .completed
        ).0 == .passed)
    }
}
