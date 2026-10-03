import Foundation
import IntentLabContracts
@testable import IntentLabCoreTesting
import XCTest

final class IntentLabRoutePolicyTests: XCTestCase {
    func testSiriOnlyRejectsUnscopedDirectRequirement() throws {
        let scenario = try makeScenario()
        XCTAssertThrowsError(try IntentLabRoutePolicy.validate(
            scenario: scenario, directExecutorAvailable: false, queryOperationsAvailable: false
        )) { error in
            guard case IntentLabExecutionPathError.directIntentRequired = error else {
                return XCTFail("Expected direct route rejection, got \(error)")
            }
        }
    }

    func testSiriOnlyRejectsQueryObservation() throws {
        let scenario = try makeScenario(
            directCoverage: "notApplicable",
            observationPlan: [[
                "id": "task-state", "source": "entityQuery",
                "operationID": "task-by-id", "selector": "task-001.state"
            ]]
        )
        XCTAssertThrowsError(try IntentLabRoutePolicy.validate(
            scenario: scenario, directExecutorAvailable: false, queryOperationsAvailable: false
        )) { error in
            guard case IntentLabExecutionPathError.queryObservationRequired = error else {
                return XCTFail("Expected query route rejection, got \(error)")
            }
        }
    }

    func testScopedSiriAllowsSeparateDirectEvidence() throws {
        let scenario = try makeScenario(scope: "siri")
        XCTAssertNoThrow(try IntentLabRoutePolicy.validate(
            scenario: scenario, directExecutorAvailable: false, queryOperationsAvailable: false
        ))
    }

    func testLocalFeatureRequiresFrameworkExecutor() throws {
        let scenario = try makeFeatureScenario()
        XCTAssertThrowsError(try IntentLabRoutePolicy.validate(
            scenario: scenario,
            directExecutorAvailable: false,
            queryOperationsAvailable: false,
            featureExecutorAvailable: false
        )) { error in
            guard case IntentLabLocalFeatureExecutionError.executorRequired = error else {
                return XCTFail("Expected the project-local feature executor rejection, got \(error)")
            }
        }

        XCTAssertNoThrow(try IntentLabRoutePolicy.validate(
            scenario: scenario,
            directExecutorAvailable: false,
            queryOperationsAvailable: false,
            featureExecutorAvailable: true
        ))
    }

    func testAppFeatureWireScopeRequiresItsFrozenServiceOperation() throws {
        let valid = try makeFeatureScenario()
        XCTAssertNoThrow(try valid.validateContract(harnessVersion: "intent-lab-v2"))

        var missingBinding = valid
        missingBinding.featureBinding = nil
        XCTAssertThrowsError(try missingBinding.validateContract(harnessVersion: "intent-lab-v2"))

        var wrongAction = valid
        wrongAction.actionRequirements?[0].kind = .productionIntent
        XCTAssertThrowsError(try wrongAction.validateContract(harnessVersion: "intent-lab-v2"))

        var receiptProjection = valid
        receiptProjection.featureBinding?.outputProjections = [
            .init(name: "intentlab.actionReceipts", type: .primitive(.string), path: [])
        ]
        XCTAssertThrowsError(try receiptProjection.validateContract(harnessVersion: "intent-lab-v2"))
    }

    @available(macOS 27.0, iOS 27.0, *)
    @MainActor
    func testFeatureResponsePlanOnlyUsesBoundLocalTestIntentSource() throws {
        let scenario = try makeFeatureScenario()
        let control = IntentLabIntegrationDeclaration.FeatureControl(
            featureID: "notes.summarize",
            interfaceDigest: String(repeating: "a", count: 64),
            operationID: "notes.summarize",
            testIntentIdentifier: "RunNotesFeatureTestIntent",
            parameters: [],
            outputProjections: []
        )
        let valid = try plannedObservation(
            id: "feature.response",
            source: "testOnlyIntent",
            operationID: "notes.summarize"
        )
        XCTAssertTrue(IntentLabScenarioEngine.isBoundLocalFeatureResponseObservation(
            valid, scenario: scenario, control: control
        ))

        let wrongOperation = try plannedObservation(
            id: "feature.response",
            source: "testOnlyIntent",
            operationID: "notes.other"
        )
        let wrongSource = try plannedObservation(
            id: "feature.response",
            source: "valueQuery",
            operationID: "notes.summarize"
        )
        let directIntentSource = try plannedObservation(
            id: "feature.response",
            source: "intentResult",
            operationID: "notes.summarize"
        )
        let unreservedKey = try plannedObservation(
            id: "summary",
            source: "testOnlyIntent",
            operationID: "notes.summarize"
        )
        let selectedByUI = try plannedObservation(
            id: "feature.response",
            source: "testOnlyIntent",
            operationID: "notes.summarize",
            selector: "feature.response"
        )
        XCTAssertFalse(IntentLabScenarioEngine.isBoundLocalFeatureResponseObservation(
            wrongOperation, scenario: scenario, control: control
        ))
        XCTAssertFalse(IntentLabScenarioEngine.isBoundLocalFeatureResponseObservation(
            wrongSource, scenario: scenario, control: control
        ))
        XCTAssertFalse(IntentLabScenarioEngine.isBoundLocalFeatureResponseObservation(
            directIntentSource, scenario: scenario, control: control
        ))
        XCTAssertFalse(IntentLabScenarioEngine.isBoundLocalFeatureResponseObservation(
            unreservedKey, scenario: scenario, control: control
        ))
        XCTAssertFalse(IntentLabScenarioEngine.isBoundLocalFeatureResponseObservation(
            selectedByUI, scenario: scenario, control: control
        ))

        var unboundScenario = scenario
        unboundScenario.featureBinding = nil
        XCTAssertFalse(IntentLabScenarioEngine.isBoundLocalFeatureResponseObservation(
            valid, scenario: unboundScenario, control: control
        ))
        var mismatchedControl = control
        mismatchedControl.operationID = "notes.other"
        XCTAssertFalse(IntentLabScenarioEngine.isBoundLocalFeatureResponseObservation(
            valid, scenario: scenario, control: mismatchedControl
        ))
    }

    private func makeScenario(
        directCoverage: String = "required",
        observationPlan: [[String: String]] = [],
        scope: String? = nil
    ) throws -> IntentLabScenario {
        var json: [String: Any] = [
            "schemaVersion": 1,
            "id": UUID().uuidString,
            "version": 1,
            "definitionDigest": String(repeating: "a", count: 64),
            "target": ["bundleIdentifier": "com.example.IntentLab"],
            "goal": ["requestText": "Complete task", "languageCode": "en"],
            "fixture": [
                "id": "test", "version": "1", "digest": String(repeating: "b", count: 64),
                "preparationOperation": "prepare", "cleanupOperation": "cleanup"
            ],
            "directControl": ["intentIdentifier": "CompleteTask", "parameters": [], "outputFields": []],
            "assertions": [],
            "coverage": [
                "appFeature": "notApplicable", "intentIntegration": directCoverage,
                "siri": "required", "siriAttemptCount": 1
            ],
            "safety": ["deadlineSeconds": 5],
            "observationPlan": observationPlan
        ]
        if let scope {
            json["executionScope"] = ["lane": scope, "attempt": 1]
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        let scenario = try JSONDecoder.intentLab.decode(IntentLabScenario.self, from: data)
        try scenario.validateContract(harnessVersion: "intent-lab-v1")
        return scenario
    }

    private func makeFeatureScenario() throws -> IntentLabScenario {
        let requirement = IntentLabActionRequirement(
            lane: .appFeature, kind: .productionService,
            operationID: "notes.summarize", resolvedParameters: [:]
        )
        let requirementData = try JSONEncoder.intentLab.encode([requirement])
        let actionRequirements = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requirementData) as? [[String: Any]]
        )
        let binding = IntentLabFeatureBinding(
            featureID: "notes.summarize",
            interfaceDigest: String(repeating: "a", count: 64),
            inputMapping: [], outputProjections: []
        )
        let bindingData = try JSONEncoder.intentLab.encode(binding)
        let bindingObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bindingData) as? [String: Any]
        )
        let json: [String: Any] = [
            "schemaVersion": 2,
            "id": UUID().uuidString,
            "version": 1,
            "definitionDigest": String(repeating: "b", count: 64),
            "target": ["bundleIdentifier": "com.example.IntentLab"],
            "goal": ["requestText": "Summarize a note", "languageCode": "en"],
            "fixture": [
                "id": "notes", "version": "1", "digest": String(repeating: "c", count: 64),
                "preparationOperation": "prepare", "cleanupOperation": "readOnly"
            ],
            "directControl": ["intentIdentifier": "CompleteTask", "parameters": [], "outputFields": []],
            "assertions": [],
            "coverage": [
                "appFeature": "required", "intentIntegration": "notApplicable", "siri": "notApplicable"
            ],
            "safety": ["deadlineSeconds": 5, "mutationPolicy": "readOnly"],
            "purpose": "releaseRequirement",
            "checkMode": "basic",
            "requiredClaims": ["executionCompleted"],
            "observationPlan": [],
            "integration": [
                "id": "notes", "version": "1", "digest": String(repeating: "d", count: 64)
            ],
            "executionScope": ["lane": "appFeature", "attempt": 1],
            "featureBinding": bindingObject,
            "actionRequirements": actionRequirements,
            "actionPolicyVersion": 1
        ]
        return try JSONDecoder.intentLab.decode(
            IntentLabScenario.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }

    private func plannedObservation(
        id: String,
        source: String,
        operationID: String,
        selector: String? = nil
    ) throws -> IntentLabPlannedObservation {
        var observation: [String: Any] = [
            "id": id,
            "source": source,
            "operationID": operationID
        ]
        if let selector {
            observation["selector"] = selector
        }
        let data = try JSONSerialization.data(withJSONObject: ["observation": observation])
        return try JSONDecoder.intentLab.decode(
            PlannedObservationEnvelope.self,
            from: data
        ).observation
    }

    private struct PlannedObservationEnvelope: Decodable {
        var observation: IntentLabPlannedObservation
    }
}
