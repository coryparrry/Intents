import Foundation
import IntentLabContracts
import XCTest

final class IntentLabContractsTests: XCTestCase {
    func testCleanupRunsAfterSuccessfulAttempt() throws {
        var events: [String] = []
        let attempt = IntentLabAttemptLifecycle.execute {
            events.append("action")
            return 7
        } cleanupRequired: {
            true
        } cleanup: {
            events.append("cleanup")
        }
        XCTAssertEqual(try attempt.action.get(), 7)
        XCTAssertNil(attempt.cleanupError)
        XCTAssertEqual(events, ["action", "cleanup"])
    }

    func testCleanupRunsAfterThrownActionAndCooperativeCancellation() {
        let errors: [Error] = [LifecycleTestError.actionFailed, CancellationError()]
        for error in errors {
            var cleanupCount = 0
            let attempt: (action: Result<Void, Error>, cleanupError: Error?) = IntentLabAttemptLifecycle.execute {
                throw error
            } cleanupRequired: {
                true
            } cleanup: {
                cleanupCount += 1
            }
            XCTAssertEqual(cleanupCount, 1)
            XCTAssertNil(attempt.cleanupError)
            XCTAssertThrowsError(try attempt.action.get())
        }
    }

    func testCleanupFailureIsReturnedEvenWhenActionSucceeded() throws {
        let attempt = IntentLabAttemptLifecycle.execute {
            "observed"
        } cleanupRequired: {
            true
        } cleanup: {
            throw LifecycleTestError.cleanupFailed
        }
        XCTAssertEqual(try attempt.action.get(), "observed")
        XCTAssertNotNil(attempt.cleanupError)
    }

    func testUnresolvedActionSkipsCleanupAndUnstartedPreparationDoesNotCleanup() {
        var cleanupCount = 0
        let unresolved: (action: Result<Void, Error>, cleanupError: Error?) = IntentLabAttemptLifecycle.execute {
            throw LifecycleTestError.actionFailed
        } cleanupRequired: {
            true
        } skipCleanupAfter: { _ in
            true
        } cleanup: {
            cleanupCount += 1
        }
        let unstarted = IntentLabAttemptLifecycle.execute {
            1
        } cleanupRequired: {
            false
        } cleanup: {
            cleanupCount += 1
        }
        XCTAssertNil(unresolved.cleanupError)
        XCTAssertNil(unstarted.cleanupError)
        XCTAssertEqual(cleanupCount, 0)
    }

    func testUndeclaredMutatingCleanupIsRejectedWhileLegacyNoOpRemainsAllowed() throws {
        let data = Data("""
        {"schemaVersion":1,"id":"example-integration","version":"1","targetBundleIdentifier":"com.example.App","projectIdentity":"App.xcodeproj","targetIdentity":"AppUITests","supportedHarnessProtocols":["intent-lab-v2"],"actions":[],"resultProjections":[],"preparationOperations":["none"],"observers":[],"isolation":{"kind":"readOnly"},"capabilities":[]}
        """.utf8)
        var declaration = try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self, from: data)
        XCTAssertTrue(declaration.allowsCleanupOperation("none"))
        XCTAssertFalse(declaration.allowsCleanupOperation("delete-records"))
        XCTAssertFalse(declaration.allowsCleanupOperation("none", requiresMutationCleanup: true))
        declaration.cleanupOperations = ["restore-synthetic-records"]
        XCTAssertTrue(declaration.allowsCleanupOperation("restore-synthetic-records"))
        XCTAssertTrue(declaration.allowsCleanupOperation("restore-synthetic-records", requiresMutationCleanup: true))
        XCTAssertFalse(declaration.allowsCleanupOperation("none"))
        declaration.cleanupOperations = ["restore-synthetic-records", "restore-synthetic-records"]
        XCTAssertThrowsError(try declaration.validate())
    }

    private enum LifecycleTestError: Error {
        case actionFailed
        case cleanupFailed
    }

    func testDirectTimeoutFenceRejectsEveryLaterAttempt() throws {
        var fence = IntentLabAttemptFence()
        XCTAssertNoThrow(try fence.validateNewAttempt())
        fence.recordUnresolvedDirectTimeout()
        XCTAssertTrue(fence.isQuarantined)
        XCTAssertThrowsError(try fence.validateNewAttempt())
        XCTAssertThrowsError(try fence.validateNewAttempt())
    }

    func testUnresolvedSiriFenceRejectsSecondRun() throws {
        var fence = IntentLabAttemptFence()
        try fence.beginSiriAttempt()
        XCTAssertTrue(fence.isQuarantined)
        XCTAssertThrowsError(try fence.validateNewAttempt()) { error in
            guard case IntentLabAttemptFenceError.unresolvedSiriAttempt = error else {
                return XCTFail("Expected the unresolved Siri fence, got \(error)")
            }
        }
        XCTAssertThrowsError(try fence.beginSiriAttempt())
    }

    func testVerifiedSiriCompletionDoesNotFenceWrongOutcome() throws {
        var fence = IntentLabAttemptFence()
        try fence.beginSiriAttempt()
        // The observation was fresh and correlated; later assertion comparison
        // may still fail, but that completed action cannot block the next run.
        fence.recordVerifiedSiriCompletion()
        XCTAssertFalse(fence.isQuarantined)
        XCTAssertNoThrow(try fence.validateNewAttempt())
        try fence.beginSiriAttempt()
        fence.recordVerifiedSiriCompletion()
        XCTAssertNoThrow(try fence.validateNewAttempt())
    }

    func testV1TransportKeepsLegacyProtocol() throws {
        let scenario = try decodeScenario(v2: false)
        XCTAssertNoThrow(try scenario.validateContract(harnessVersion: "intent-lab-v1"))
        XCTAssertThrowsError(try scenario.validateContract(harnessVersion: "intent-lab-v2"))
    }

    func testV2TransportRequiresBoundIntegrationAndClaims() throws {
        let scenario = try decodeScenario(v2: true)
        XCTAssertNoThrow(try scenario.validateContract(harnessVersion: "intent-lab-v2"))
        XCTAssertThrowsError(try scenario.validateContract(harnessVersion: "intent-lab-v1"))

        var missingBinding = scenario
        missingBinding.integration = nil
        XCTAssertThrowsError(try missingBinding.validateContract(harnessVersion: "intent-lab-v2"))

        var missingClaim = scenario
        missingClaim.requiredClaims = []
        XCTAssertThrowsError(try missingClaim.validateContract(harnessVersion: "intent-lab-v2"))
    }

    func testV2SyntheticMutationRequiresRealCleanupOperation() throws {
        var scenario = try decodeScenario(v2: true)
        scenario.safety.mutationPolicy = .syntheticMutation
        XCTAssertThrowsError(try scenario.validateContract(harnessVersion: "intent-lab-v2"))
        scenario.fixture.cleanupOperation = "restore-synthetic-records"
        XCTAssertNoThrow(try scenario.validateContract(harnessVersion: "intent-lab-v2"))
    }

    func testBehaviourNeedsAStateSource() throws {
        var scenario = try decodeScenario(v2: true)
        scenario.checkMode = .behaviour
        scenario.requiredClaims = [.executionCompleted, .applicationStateChecked]
        XCTAssertThrowsError(try scenario.validateContract(harnessVersion: "intent-lab-v2"))
    }

    func testSiriCannotUseAnEmptyRequest() throws {
        var scenario = try decodeScenario(v2: true)
        scenario.coverage.siri = .required
        scenario.goal.requestText = " "
        XCTAssertThrowsError(try scenario.validateContract(harnessVersion: "intent-lab-v2"))
    }

    func testBasicDeclarationHasAnExplicitCompiledAction() throws {
        let data = Data("""
        {"schemaVersion":1,"id":"example-integration","version":"1","targetBundleIdentifier":"com.example.App","projectIdentity":"App.xcodeproj","targetIdentity":"AppUITests","supportedHarnessProtocols":["intent-lab-v2"],"actions":[{"id":"StartIntent","parameters":[]}],"resultProjections":[],"preparationOperations":["none"],"observers":[],"isolation":{"kind":"readOnly"},"capabilities":["environment-payload","direct-intent-execution"]}
        """.utf8)
        let declaration = try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self, from: data)
        XCTAssertNoThrow(try declaration.validate())
        XCTAssertEqual(declaration.actions.map(\.id), ["StartIntent"])
    }

    func testTypedObservationRejectsWrongValue() {
        let boolean = IntentLabValueType.primitive(.boolean)
        XCTAssertTrue(boolean.accepts(.boolean(true)))
        XCTAssertFalse(boolean.accepts(.string("true")))
        XCTAssertFalse(IntentLabValueType.array(element: .primitive(.integer)).accepts(.array([.integer(1), .string("2")])))
    }

    func testQueryObserverCannotReferenceAnUndeclaredOperation() throws {
        let data = Data("""
        {"schemaVersion":1,"id":"example-integration","version":"1","targetBundleIdentifier":"com.example.App","projectIdentity":"App.xcodeproj","targetIdentity":"AppUITests","supportedHarnessProtocols":["intent-lab-v2"],"actions":[{"id":"StartIntent","parameters":[]}],"resultProjections":[],"preparationOperations":["none"],"observers":[{"id":"status","source":"entityQuery","type":{"primitive":{"_0":"boolean"}},"operationID":"unknown","selector":"task-001.isComplete"}],"isolation":{"kind":"readOnly"},"capabilities":["entity-query"]}
        """.utf8)
        let declaration = try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self, from: data)
        XCTAssertThrowsError(try declaration.validate())
    }

    func testQueryObserverSourceMustMatchItsOperation() throws {
        let data = Data("""
        {"schemaVersion":1,"id":"example-integration","version":"1","targetBundleIdentifier":"com.example.App","projectIdentity":"App.xcodeproj","targetIdentity":"AppUITests","supportedHarnessProtocols":["intent-lab-v2"],"actions":[{"id":"StartIntent","parameters":[]}],"resultProjections":[],"preparationOperations":["none"],"queryOperations":[{"id":"lookup","source":"valueQuery","typeIdentifier":"StatusQuery","input":{"string":{"_0":"task-001"}}}],"observers":[{"id":"status","source":"entityQuery","type":{"primitive":{"_0":"boolean"}},"operationID":"lookup","selector":"task-001.isComplete"}],"isolation":{"kind":"readOnly"},"capabilities":["entity-query","value-query"]}
        """.utf8)
        let declaration = try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self, from: data)
        XCTAssertEqual(declaration.queryOperations?.first?.source, .valueQuery)
        XCTAssertEqual(declaration.queryOperations?.first?.input, .string("task-001"))
        XCTAssertThrowsError(try declaration.validate())
    }

    func testReturnedValueCannotMasqueradeAsStateObservation() throws {
        var scenario = try decodeScenario(v2: true)
        scenario.directControl.outputFields = try JSONDecoder.intentLab.decode(
            [IntentLabOutputField].self,
            from: Data("[{\"name\":\"state\",\"type\":{\"primitive\":{\"_0\":\"boolean\"}},\"path\":[{\"kind\":\"property\",\"name\":\"value\"}]}]".utf8)
        )
        scenario.observationPlan = try JSONDecoder.intentLab.decode(
            [IntentLabPlannedObservation].self,
            from: Data("[{\"id\":\"state\",\"source\":\"entityQuery\",\"operationID\":\"tasks\",\"selector\":\"task-001.isComplete\"}]".utf8)
        )
        XCTAssertThrowsError(try scenario.validateContract(harnessVersion: "intent-lab-v2"))
    }

    private func decodeScenario(v2: Bool) throws -> IntentLabScenario {
        var json: [String: Any] = [
            "schemaVersion": v2 ? 2 : 1,
            "id": "00000000-0000-0000-0000-000000000001",
            "version": 1,
            "definitionDigest": "frozen-digest",
            "target": ["bundleIdentifier": "com.example.App"],
            "goal": ["requestText": "", "languageCode": "en-GB"],
            "fixture": ["id": "read-only", "version": "1", "digest": "fixture", "preparationOperation": "none", "cleanupOperation": "none"],
            "directControl": ["intentIdentifier": "StartIntent", "parameters": [], "outputFields": []],
            "assertions": [],
            "coverage": ["appFeature": "notApplicable", "intentIntegration": "required", "siri": "notApplicable"],
            "safety": ["deadlineSeconds": 10]
        ]
        if v2 {
            json["purpose"] = "exploratory"
            json["checkMode"] = "basic"
            json["requiredClaims"] = ["executionCompleted"]
            json["observationPlan"] = []
            json["integration"] = ["id": "example-integration", "version": "1", "digest": String(repeating: "a", count: 64)]
        }
        return try JSONDecoder.intentLab.decode(IntentLabScenario.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
