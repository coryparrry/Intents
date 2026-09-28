import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioNoMutationTests {
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
