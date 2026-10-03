import CryptoKit
import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioExpectationAuthoringTests {
    @Test func guidedExpectedValuesMatchDeclaredTypes() throws {
        let types: [ScenarioValueType] = [
            .primitive(.string), .primitive(.boolean), .primitive(.integer),
            .primitive(.number), .primitive(.date),
            .enumeration(typeIdentifier: "Priority", allowedCases: ["high", "low"]),
            .array(element: .primitive(.integer)),
            .array(element: .enumeration(typeIdentifier: "Priority", allowedCases: ["high", "low"]))
        ]
        for type in types {
            let value = try #require(ScenarioDeclaredExpectedValues.initial(for: type))
            #expect(ScenarioValidator.validate(value: value, as: type).isEmpty)
        }
        let entityType = ScenarioValueType.entity(typeIdentifier: "Note")
        let blankEntity = try #require(ScenarioDeclaredExpectedValues.initial(for: entityType))
        #expect(!ScenarioValidator.validate(value: blankEntity, as: entityType).isEmpty)
        let resolvedEntity = ScenarioValue.entity(.init(typeIdentifier: "Note", identifier: "packing-001"))
        #expect(ScenarioValidator.validate(value: resolvedEntity, as: entityType).isEmpty)
        #expect(ScenarioValidator.validate(value: .array([resolvedEntity]),
                                           as: .array(element: entityType)).isEmpty)
    }

    @Test func returnedCheckCreatesAndRemovesDependentWiringTogether() throws {
        let catalog = sampleCatalog()
        var definition = ScenarioDefinition.starter()
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.assertions = []
        definition.directControl.outputFields = []
        definition.observationPlan = []
        definition.requiredClaims = [.executionCompleted]

        let selected = try ScenarioExpectationAuthoring.selectingAction("SummarizeNoteIntent", in: definition, catalog: catalog)
        #expect(selected.directControl.intentIdentifier == "SummarizeNoteIntent")
        #expect(selected.directControl.parameters.map(\.name) == ["noteID"])

        let authored = try ScenarioExpectationAuthoring.addingReturnedCheck(
            projectionID: "generatedSummary", expected: .string("Packing list"),
            lanes: [.intentIntegration], to: selected, catalog: catalog
        )
        #expect(authored.directControl.outputFields.map(\.name) == ["generatedSummary"])
        #expect(authored.observationPlan?.map(\.id) == ["generatedSummary"])
        #expect(authored.requiredClaims?.contains(.returnedValueChecked) == true)
        let check = try #require(authored.assertions.first)
        #expect(check.observationKey == "generatedSummary")

        let updated = try ScenarioExpectationAuthoring.updatingCheck(
            check.id, expected: .string("Changed expectation"), in: authored, catalog: catalog
        )
        #expect(updated.assertions.first?.expectedValue == .string("Changed expectation"))
        #expect(authored.assertions.first?.expectedValue == .string("Packing list"))

        let removed = try ScenarioExpectationAuthoring.removingCheck(check.id, from: updated)
        #expect(removed.assertions.isEmpty)
        #expect(removed.directControl.outputFields.isEmpty)
        #expect(removed.observationPlan?.isEmpty == true)
        #expect(removed.requiredClaims == [.executionCompleted])
    }

    @Test func failedAuthoringLeavesOriginalDefinitionUntouched() throws {
        let catalog = sampleCatalog()
        let original = ScenarioDefinition.starter()
        let originalFields = original.directControl.outputFields
        #expect(throws: ScenarioAuthoringError.self) {
            _ = try ScenarioExpectationAuthoring.addingReturnedCheck(
                projectionID: "generatedSummary", expected: .integer(3),
                lanes: [.intentIntegration], to: original, catalog: catalog
            )
        }
        #expect(original.directControl.outputFields == originalFields)
    }

    @Test func catalogRejectsChangedCompiledBytes() throws {
        let catalog = sampleCatalog()
        let data = try JSONEncoder().encode(catalog)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let identity = ScenarioIntegrationIdentity(id: catalog.id, version: catalog.version, digest: digest)
        #expect(try ScenarioIntegrationCatalog.decodeVerified(data, identity: identity).actions.count == 1)
        #expect(throws: ScenarioAuthoringError.self) {
            _ = try ScenarioIntegrationCatalog.decodeVerified(data + Data(" ".utf8), identity: identity)
        }
    }

    @Test func featureResponseCheckIsExplicitAndCannotPassByCaptureAlone() throws {
        let catalog = sampleCatalog()
        var definition = ScenarioDefinition.starter()
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.assertions = []
        definition.coverage.appFeature = .required
        definition.featureBinding = .init(featureID: "summarize-note",
                                           interfaceDigest: String(repeating: "a", count: 64),
                                           inputMapping: [], outputProjections: [])

        let unassessed = ScenarioResultEvaluator.evaluate(
            definition: definition, lane: .appFeature,
            observations: ["feature.response": .string("Actual summary")],
            executionStatus: .completed
        )
        #expect(unassessed.0 == .needsReview)
        #expect(ScenarioValidator.issues(in: definition).contains {
            $0.path == "coverage.appFeature" && $0.severity == .error
        })

        let authored = try ScenarioExpectationAuthoring.addingFeatureResponseCheck(
            expected: .string("Expected summary"), semantic: false, rubric: "",
            to: definition
        )
        let check = try #require(authored.assertions.first)
        #expect(check.applicableLanes == [.appFeature])
        #expect(check.observationKey == "feature.response")
        #expect(authored.observationPlan == [
            .init(id: "feature.response", source: .testOnlyIntent,
                  operationID: nil, selector: nil)
        ])
        #expect(authored.requiredClaims?.contains(.returnedValueChecked) == true)
        #expect(!ScenarioValidator.issues(in: authored).contains {
            $0.path == "assertions[0].kind" || $0.path == "assertions[0].observationKey"
        })
        var staleOperation = authored
        staleOperation.actionPolicyVersion = 1
        staleOperation.actionRequirements = [.init(
            lane: .appFeature, kind: .productionService,
            operationID: "summarize", resolvedParameters: [:]
        )]
        #expect(ScenarioValidator.issues(in: staleOperation).contains {
            $0.path == "observationPlan[0].operationID"
        })
        staleOperation.observationPlan?[0].operationID = "summarize"
        #expect(!ScenarioValidator.issues(in: staleOperation).contains {
            $0.path == "observationPlan[0].operationID"
        })
        let instant = Date()
        var nativeResult = ScenarioLaneResult(
            caseID: authored.id, attempt: 1, lane: .appFeature,
            executionStatus: .completed, outcome: .passed,
            startedAt: instant, completedAt: instant,
            observations: ["feature.response": .string("Expected summary")],
            assertionResults: [.init(assertionID: check.id, passed: true,
                                     observedValue: .string("Expected summary"), message: "Matched")],
            observationSources: ["feature.response": .testOnlyIntent],
            claims: [.returnedValueChecked]
        )
        #expect(ScenarioResultEvaluator.verifiedClaim(
            .returnedValueChecked, definition: authored, result: nativeResult
        ))
        nativeResult.observationSources?["feature.response"] = .manuallySupplied
        #expect(!ScenarioResultEvaluator.verifiedClaim(
            .returnedValueChecked, definition: authored, result: nativeResult
        ))
        let failed = ScenarioResultEvaluator.evaluate(
            definition: authored, lane: .appFeature,
            observations: ["feature.response": .string("Actual summary")],
            executionStatus: .completed
        )
        #expect(failed.0 == .failed)

        let updated = try ScenarioExpectationAuthoring.updatingCheck(
            check.id, expected: .string("Actual summary"), in: authored, catalog: catalog
        )
        #expect(ScenarioResultEvaluator.evaluate(
            definition: updated, lane: .appFeature,
            observations: ["feature.response": .string("Actual summary")],
            executionStatus: .completed
        ).0 == .passed)
        #expect(throws: ScenarioAuthoringError.self) {
            _ = try ScenarioExpectationAuthoring.addingFeatureResponseCheck(
                expected: .string("Another answer"), semantic: false, rubric: "", to: authored
            )
        }
        let semantic = try ScenarioExpectationAuthoring.addingFeatureResponseCheck(
            expected: .string("Expected summary"), semantic: true,
            rubric: "The response covers the requested note.", to: definition
        )
        #expect(semantic.observationPlan?.first?.source == .testOnlyIntent)
        #expect(!ScenarioValidator.issues(in: semantic).contains {
            $0.path == "assertions[0].kind" || $0.path == "assertions[0].observationKey"
        })
    }

    @Test func localFeatureObservationsRequireEveryDeclaredTypedTestOnlyProjection() {
        let binding = ScenarioFeatureBinding(
            featureID: "summarize-note", interfaceDigest: String(repeating: "a", count: 64),
            inputMapping: [], outputProjections: [
                .init(name: "summary", type: .primitive(.string)),
                .init(name: "wordCount", type: .primitive(.integer))
            ]
        )
        let instant = Date()
        var lane = ScenarioLaneResult(
            caseID: UUID(), attempt: 1, lane: .appFeature,
            executionStatus: .completed, outcome: .passed,
            startedAt: instant, completedAt: instant,
            observations: ["feature.response": .string("Summary"),
                           "summary": .string("Summary"), "wordCount": .integer(1)],
            observationSources: ["feature.response": .testOnlyIntent,
                                 "summary": .testOnlyIntent, "wordCount": .testOnlyIntent]
        )
        #expect(ScenarioValidator.validLocalFeatureObservations(lane, binding: binding))
        lane.observations.removeValue(forKey: "wordCount")
        #expect(!ScenarioValidator.validLocalFeatureObservations(lane, binding: binding))
        lane.observations["wordCount"] = .string("one")
        #expect(!ScenarioValidator.validLocalFeatureObservations(lane, binding: binding))
        lane.observations["wordCount"] = .integer(1)
        lane.observationSources?["summary"] = .applicationInstrumentation
        #expect(!ScenarioValidator.validLocalFeatureObservations(lane, binding: binding))
        lane.observationSources?["summary"] = .testOnlyIntent
        lane.observationSources?["feature.response"] = .applicationInstrumentation
        #expect(!ScenarioValidator.validLocalFeatureObservations(lane, binding: binding))
    }

    private func sampleCatalog() -> ScenarioIntegrationCatalog {
        .init(schemaVersion: 1, id: "notes", version: "1", targetBundleIdentifier: "example.notes",
              actions: [.init(id: "SummarizeNoteIntent", parameters: [
                .init(name: "noteID", type: .primitive(.string), required: true)
              ])],
              resultProjections: [.init(id: "generatedSummary", type: .primitive(.string),
                                        path: [.init(kind: .property, name: "value")])],
              observers: [], preparationOperations: [], capabilities: [])
    }
}
