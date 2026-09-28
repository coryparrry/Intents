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
}
