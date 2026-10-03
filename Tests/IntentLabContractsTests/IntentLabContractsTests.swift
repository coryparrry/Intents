import Foundation
import IntentLabContracts
import XCTest

final class IntentLabContractsTests: XCTestCase {
    func testShippedNotesDeclarationsAllowVerifiedReadOnlyResetCleanup() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["examples/IntentLabFixture/UITests/IntentLabIntegration.json",
                     "examples/IntentLabFixture/UITests/Siri/IntentLabIntegration.json"] {
            let declaration = try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self,
                from: Data(contentsOf: root.appending(path: path)))
            try declaration.validate()
            for operation in ["reset", "resetNotes", "resetFixture"] {
                XCTAssertTrue(declaration.preparationOperations.contains(operation), path)
                XCTAssertTrue(declaration.allowsCleanupOperation(operation), path)
                XCTAssertTrue(declaration.allowsCleanupOperation(operation, requiresMutationCleanup: true), path)
            }
            XCTAssertFalse(declaration.allowsCleanupOperation("undeclared-reset"), path)
            XCTAssertFalse(declaration.allowsCleanupOperation("none", requiresMutationCleanup: true), path)
        }
    }

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

    func testUnchangedStateRejectsFinalValueThatMatchesConstantAfterMutation() {
        let assertion = IntentLabAssertion(
            id: UUID(), kind: .noMutation, observationKey: "selectedNoteID",
            expectedValue: .string("packing-001"), required: true, applicableLanes: nil
        )
        let result = IntentLabAssertionEvaluator.evaluate(
            assertion, observed: .string("packing-001"), before: .string("packing-002")
        )
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.observedValue, .string("packing-001"))
    }

    func testUnchangedStateRequiresTypedBaselineAndPreservesExactValueChecks() {
        let unchanged = IntentLabAssertion(
            id: UUID(), kind: .noMutation, observationKey: "noteStoreMutationCount",
            expectedValue: .integer(0), required: true, applicableLanes: nil
        )
        XCTAssertTrue(IntentLabAssertionEvaluator.evaluate(
            unchanged, observed: .integer(0), before: .integer(0)
        ).passed)
        XCTAssertFalse(IntentLabAssertionEvaluator.evaluate(
            unchanged, observed: .integer(0), before: nil
        ).passed)
        XCTAssertFalse(IntentLabAssertionEvaluator.evaluate(
            unchanged, observed: .integer(0), before: .string("0")
        ).passed)

        let exact = IntentLabAssertion(
            id: UUID(), kind: .returnedField, observationKey: "generatedSummary",
            expectedValue: .string("Summary"), required: true, applicableLanes: nil
        )
        XCTAssertTrue(IntentLabAssertionEvaluator.evaluate(
            exact, observed: .string("Summary"), before: nil
        ).passed)
    }

    func testActionVerifierRejectsWrongActionSameStateAndStaleReceipts() {
        let context = "siri-\(UUID().uuidString)-1"
        let requirement = IntentLabActionRequirement(
            lane: .siri, kind: .productionIntent, operationID: "SummarizeNoteIntent",
            resolvedParameters: ["noteID": .string("packing-001")]
        )
        let now = Date()
        let observed = IntentLabActionReceipt(
            executionID: UUID(), appSessionID: UUID(), attemptContext: context,
            lane: .siri, attempt: 1, kind: .productionIntent,
            operationID: "OpenNoteIntent",
            resolvedParameters: ["noteID": .string("packing-001")],
            terminalStatus: .succeeded, operationError: nil,
            sequence: 1, startedAt: now, completedAt: now,
            observationTransport: "accessibleUI"
        )
        func verdict(_ receipts: [IntentLabActionReceipt]?) -> (IntentLabOutcome, IntentLabActionFailureReason?) {
            IntentLabAssertionEvaluator.actionVerdict(
                requirement: requirement, receipts: receipts,
                lane: .siri, attempt: 1, context: context
            )
        }
        XCTAssertEqual(verdict([observed]).1, .wrongAction)
        XCTAssertEqual(verdict([observed]).0, .failed)
        XCTAssertEqual(verdict(nil).1, .missingActionEvidence)
        var stale = observed
        stale.operationID = requirement.operationID
        stale.attemptContext = "siri-old-attempt-1"
        XCTAssertEqual(verdict([stale]).1, .staleActionEvidence)
        var wrongParameter = observed
        wrongParameter.operationID = requirement.operationID
        wrongParameter.resolvedParameters = ["noteID": .string("packing-002")]
        XCTAssertEqual(verdict([wrongParameter]).1, .wrongParameter)
        var correct = observed
        correct.operationID = requirement.operationID
        XCTAssertEqual(verdict([correct]).0, .passed)
        var inconsistent = correct
        inconsistent.operationError = "A real operation error"
        XCTAssertEqual(verdict([inconsistent]).1, .invalidActionEvidence)
        var missingError = correct
        missingError.terminalStatus = .failed
        XCTAssertEqual(verdict([missingError]).1, .invalidActionEvidence)
        var nested = correct
        nested.executionID = UUID()
        nested.kind = .testSupport
        nested.operationID = "ReadSnapshot"
        nested.isTopLevel = false
        nested.appSessionID = UUID()
        nested.sequence = 2
        XCTAssertEqual(verdict([correct, nested]).1, .invalidActionEvidence)
        nested.appSessionID = correct.appSessionID
        nested.sequence = correct.sequence
        XCTAssertEqual(verdict([correct, nested]).1, .invalidActionEvidence)
        var replay = correct
        replay.sequence = 2
        XCTAssertEqual(verdict([correct, replay]).1, .invalidActionEvidence)
        var extra = observed
        extra.executionID = UUID()
        extra.sequence = 2
        XCTAssertEqual(verdict([correct, extra]).1, .unexpectedExecution)
    }

    func testScopedEvidenceRetainsBeforeObservationAndDecodesLegacyLane() throws {
        let lane = IntentLabLaneResult(
            caseID: UUID(), attempt: 1, lane: .intentIntegration,
            executionStatus: .completed, outcome: .failed,
            startedAt: .now, completedAt: .now,
            observations: ["selectedNoteID": .string("packing-001")],
            assertionResults: [], diagnostic: nil, proposedCause: nil, artifacts: [],
            beforeObservations: ["selectedNoteID": .string("packing-002")]
        )
        let data = try JSONEncoder().encode(lane)
        let restored = try JSONDecoder().decode(IntentLabLaneResult.self, from: data)
        XCTAssertEqual(restored.beforeObservations?["selectedNoteID"], .string("packing-002"))
        var oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        oldObject.removeValue(forKey: "beforeObservations")
        let legacy = try JSONDecoder().decode(
            IntentLabLaneResult.self, from: JSONSerialization.data(withJSONObject: oldObject)
        )
        XCTAssertNil(legacy.beforeObservations)
    }
    func testFractionalDateTransportPreservesScalarAndNestedArrayInstants() throws {
        for timestamp in [1_700_000_000.375, -0.375] {
            let instant = Date(timeIntervalSince1970: timestamp)
            let date = IntentLabValue.date(.init(source: "authored", timeZoneIdentifier: "UTC",
                resolvedInstant: instant))
            for value in [date, .array([date]), .array([.array([date])])] {
                let restored = try JSONDecoder.intentLab.decode(IntentLabValue.self,
                    from: JSONEncoder.intentLab.encode(value))
                XCTAssertEqual(restored, value)
            }
        }
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

    func testVersionTwoConsumerRejectsUnsupportedNativeScope() throws {
        var scenario = try decodeScenario(v2: true)
        scenario.executionScope = .init(lane: .intentIntegration, attempt: 1)
        XCTAssertNoThrow(try scenario.validateContract(harnessVersion: "intent-lab-v2"))

        scenario.executionScope = .init(lane: .intentIntegration, attempt: 2)
        XCTAssertThrowsError(try scenario.validateContract(harnessVersion: "intent-lab-v2"))

        scenario.executionScope = .init(lane: .siri, attempt: 1)
        XCTAssertThrowsError(try scenario.validateContract(harnessVersion: "intent-lab-v2"))

        scenario.coverage.siri = .required
        scenario.goal.requestText = "Summarise my note"
        scenario.executionScope = .init(lane: .siri, attempt: 2)
        XCTAssertNoThrow(try scenario.validateContract(harnessVersion: "intent-lab-v2"))

        scenario.coverage.siriAttemptCount = 0
        XCTAssertThrowsError(try scenario.validateContract(harnessVersion: "intent-lab-v2"))
        scenario.coverage.siriAttemptCount = 3

        scenario.executionScope = .init(lane: .appFeature, attempt: 1)
        XCTAssertThrowsError(try scenario.validateContract(harnessVersion: "intent-lab-v2"))
    }

    func testBasicDeclarationHasAnExplicitCompiledAction() throws {
        let data = Data("""
        {"schemaVersion":1,"id":"example-integration","version":"1","targetBundleIdentifier":"com.example.App","projectIdentity":"App.xcodeproj","targetIdentity":"AppUITests","supportedHarnessProtocols":["intent-lab-v2"],"actions":[{"id":"StartIntent","parameters":[]}],"resultProjections":[],"preparationOperations":["none"],"observers":[],"isolation":{"kind":"readOnly"},"capabilities":["environment-payload","direct-intent-execution"]}
        """.utf8)
        let declaration = try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self, from: data)
        XCTAssertNoThrow(try declaration.validate())
        XCTAssertEqual(declaration.actions.map(\.id), ["StartIntent"])
        XCTAssertNil(declaration.localFeatureControls)
        XCTAssertNil(declaration.readinessControl)
        XCTAssertThrowsError(try declaration.localFeatureControl(
            featureID: "notes", interfaceDigest: String(repeating: "a", count: 64),
            operationID: "create"
        )) { error in
            guard case IntentLabDeclarationError.localFeatureControlNotDeclared = error else {
                return XCTFail("Expected a missing local feature control, got \(error)")
            }
        }
        XCTAssertThrowsError(try declaration.declaredReadinessControl()) { error in
            guard case IntentLabDeclarationError.readinessControlNotDeclared = error else {
                return XCTFail("Expected a missing readiness control, got \(error)")
            }
        }
    }

    func testReadinessControlIsExplicitTypedAndCannotRedirectToAFeatureIntent() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: declarationData()) as? [String: Any])
        json["capabilities"] = ["test-only-intent"]
        json["readinessControl"] = try readinessControlJSON()
        let bytes = try JSONSerialization.data(withJSONObject: json)
        let declaration = try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self, from: bytes)
        try declaration.validate()
        let control = try declaration.declaredReadinessControl()
        XCTAssertEqual(control.operationID, "intentLabReadiness")
        XCTAssertEqual(control.testIntentIdentifier, "IntentLabReadinessIntent")
        XCTAssertEqual(control.response.id, "readiness.ready")
        XCTAssertEqual(control.response.type, .primitive(.boolean))

        var redirected = json
        var invalidControl = try XCTUnwrap(redirected["readinessControl"] as? [String: Any])
        invalidControl["testIntentIdentifier"] = "IntentLabInvokeFeatureIntent"
        redirected["readinessControl"] = invalidControl
        XCTAssertThrowsError(try JSONDecoder.intentLab.decode(
            IntentLabIntegrationDeclaration.self,
            from: JSONSerialization.data(withJSONObject: redirected)
        ).validate())

        var untyped = json
        var untypedControl = try XCTUnwrap(untyped["readinessControl"] as? [String: Any])
        var response = try XCTUnwrap(untypedControl["response"] as? [String: Any])
        response["type"] = ["primitive": ["_0": "string"]]
        untypedControl["response"] = response
        untyped["readinessControl"] = untypedControl
        XCTAssertThrowsError(try JSONDecoder.intentLab.decode(
            IntentLabIntegrationDeclaration.self,
            from: JSONSerialization.data(withJSONObject: untyped)
        ).validate())

        var missingCapability = json
        missingCapability["capabilities"] = ["direct-intent-execution"]
        XCTAssertThrowsError(try JSONDecoder.intentLab.decode(
            IntentLabIntegrationDeclaration.self,
            from: JSONSerialization.data(withJSONObject: missingCapability)
        ).validate())
    }

    func testLocalFeatureControlNegotiatesExactTypedContract() throws {
        let declaration = try decodeFeatureDeclaration()
        XCTAssertNoThrow(try declaration.validate())
        let expectedDigest = try XCTUnwrap(featureControlJSON()["interfaceDigest"] as? String)
        XCTAssertEqual(expectedDigest, "6fefab137a5684642fdc14a0bcb2a6ede5544666cdb6b1db6fd415d41dfd1c26")
        let selected = try declaration.localFeatureControl(
            featureID: "intent-lab.summarize-note", interfaceDigest: expectedDigest,
            operationID: "summarizeNote"
        )
        XCTAssertEqual(selected.testIntentIdentifier, "IntentLabInvokeFeatureIntent")
        XCTAssertEqual(selected.parameters.map(\.name), ["prompt"])
        XCTAssertTrue(selected.outputProjections.isEmpty)
        XCTAssertThrowsError(try declaration.localFeatureControl(
            featureID: "intent-lab.summarize-note", interfaceDigest: String(repeating: "b", count: 64),
            operationID: "summarizeNote"
        )) { error in
            guard case IntentLabDeclarationError.mismatchedIdentity = error else {
                return XCTFail("Expected interface drift to fail negotiation, got \(error)")
            }
        }
    }

    func testLocalFeatureDeclarationRejectsAmbiguousOrUntypedControls() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: featureDeclarationData()) as? [String: Any])
        var duplicate = json
        duplicate["localFeatureControls"] = [featureControlJSON(), featureControlJSON()]
        XCTAssertThrowsError(try JSONDecoder.intentLab.decode(
            IntentLabIntegrationDeclaration.self,
            from: JSONSerialization.data(withJSONObject: duplicate)
        ).validate())

        var missingCapability = json
        missingCapability["capabilities"] = ["direct-intent-execution"]
        XCTAssertThrowsError(try JSONDecoder.intentLab.decode(
            IntentLabIntegrationDeclaration.self,
            from: JSONSerialization.data(withJSONObject: missingCapability)
        ).validate())

        for reservedID in ["feature.response", "intentlab.actionReceipts"] {
            var reservedProjection = json
            let projections = [IntentLabIntegrationDeclaration.Projection(
                id: reservedID,
                type: .primitive(.string),
                path: [
                    .init(kind: .property, name: "value"),
                    .init(kind: .property, name: "response"),
                ]
            )]
            let featureID = "intent-lab.summarize-note"
            let operationID = "summarizeNote"
            let testIntentIdentifier = "IntentLabInvokeFeatureIntent"
            let parameters = [IntentLabIntegrationDeclaration.Parameter(
                name: "prompt", type: .primitive(.string), required: true
            )]
            let control = IntentLabIntegrationDeclaration.FeatureControl(
                featureID: featureID,
                interfaceDigest: try IntentLabIntegrationDeclaration.FeatureControl.calculateInterfaceDigest(
                    featureID: featureID, operationID: operationID,
                    testIntentIdentifier: testIntentIdentifier,
                    parameters: parameters, outputProjections: projections
                ),
                operationID: operationID,
                testIntentIdentifier: testIntentIdentifier,
                parameters: parameters,
                outputProjections: projections
            )
            reservedProjection["localFeatureControls"] = [
                try JSONSerialization.jsonObject(with: JSONEncoder.intentLab.encode(control))
            ]
            XCTAssertThrowsError(try JSONDecoder.intentLab.decode(
                IntentLabIntegrationDeclaration.self,
                from: JSONSerialization.data(withJSONObject: reservedProjection)
            ).validate())
        }
    }

    func testLocalFeatureInputRoundTripsWithTypedValues() throws {
        let input = IntentLabLocalFeatureInput(
            featureID: "notes",
            interfaceDigest: String(repeating: "a", count: 64),
            parameters: [IntentLabParameter(
                name: "title", type: .primitive(.string), isOptional: false,
                presence: .value(.string("Trip"))
            )]
        )
        let encoded = try JSONEncoder.intentLab.encode(input)
        let decoded = try JSONDecoder.intentLab.decode(IntentLabLocalFeatureInput.self, from: encoded)
        XCTAssertEqual(decoded.featureID, input.featureID)
        XCTAssertEqual(decoded.interfaceDigest, input.interfaceDigest)
        XCTAssertEqual(decoded.parameters.first?.name, "title")
        guard case .some(.value(.string("Trip"))) = decoded.parameters.first?.presence else {
            return XCTFail("The local feature payload lost the typed string value.")
        }
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

    private func decodeFeatureDeclaration() throws -> IntentLabIntegrationDeclaration {
        try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self, from: featureDeclarationData())
    }

    private func declarationData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "id": "readiness-app",
            "version": "1",
            "targetBundleIdentifier": "com.example.App",
            "projectIdentity": "App.xcodeproj",
            "targetIdentity": "AppUITests",
            "supportedHarnessProtocols": ["intent-lab-v2"],
            "actions": [],
            "resultProjections": [],
            "preparationOperations": [],
            "observers": [],
            "isolation": ["kind": "readOnly"],
            "capabilities": ["direct-intent-execution"],
        ])
    }

    private func readinessControlJSON() throws -> [String: Any] {
        let control = IntentLabIntegrationDeclaration.ReadinessControl(
            operationID: "intentLabReadiness",
            testIntentIdentifier: "IntentLabReadinessIntent",
            response: .init(
                id: "readiness.ready",
                type: .primitive(.boolean),
                path: [
                    .init(kind: .property, name: "value"),
                    .init(kind: .property, name: "ready"),
                ]
            )
        )
        return try JSONSerialization.jsonObject(with: JSONEncoder.intentLab.encode(control)) as! [String: Any]
    }

    private func featureDeclarationData() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "id": "feature-app",
            "version": "1",
            "targetBundleIdentifier": "com.example.App",
            "projectIdentity": "App.xcodeproj",
            "targetIdentity": "AppUITests",
            "supportedHarnessProtocols": ["intent-lab-v2"],
            "actions": [],
            "resultProjections": [],
            "preparationOperations": [],
            "observers": [],
            "isolation": ["kind": "readOnly"],
            "capabilities": ["local-feature-controls", "test-only-intent"],
            "localFeatureControls": [featureControlJSON()],
        ])
    }

    private func featureControlJSON() -> [String: Any] {
        let featureID = "intent-lab.summarize-note"
        let operationID = "summarizeNote"
        let testIntentIdentifier = "IntentLabInvokeFeatureIntent"
        let parameters = [IntentLabIntegrationDeclaration.Parameter(
            name: "prompt", type: .primitive(.string), required: true
        )]
        let outputProjections: [IntentLabIntegrationDeclaration.Projection] = []
        let control = IntentLabIntegrationDeclaration.FeatureControl(
            featureID: featureID,
            interfaceDigest: try! IntentLabIntegrationDeclaration.FeatureControl.calculateInterfaceDigest(
                featureID: featureID, operationID: operationID,
                testIntentIdentifier: testIntentIdentifier,
                parameters: parameters, outputProjections: outputProjections
            ),
            operationID: operationID,
            testIntentIdentifier: testIntentIdentifier,
            parameters: parameters,
            outputProjections: outputProjections
        )
        return try! JSONSerialization.jsonObject(with: JSONEncoder.intentLab.encode(control)) as! [String: Any]
    }
}

extension IntentLabContractsTests {
    func testReturnedProofRejectsOptionalMismatchAndAcceptsRequiredMatch() throws {
        let id = UUID()
        func assertion(required: Bool) throws -> IntentLabAssertion {
            let object: [String: Any] = ["id": id.uuidString, "kind": "returnedField",
                "observationKey": "answer", "expectedValue": ["string": ["_0": "expected"]],
                "required": required]
            return try JSONDecoder().decode(IntentLabAssertion.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        let optional = try assertion(required: false)
        let failed = IntentLabAssertionResult(assertionID: id, passed: false,
            observedValue: .string("wrong"), message: "mismatch")
        XCTAssertFalse(IntentLabReturnedValueProof.isVerified(assertions: [optional],
            observations: ["answer": .string("wrong")], resultKeys: ["answer"], checks: [failed]))
        let required = try assertion(required: true)
        let passed = IntentLabAssertionResult(assertionID: id, passed: true,
            observedValue: .string("expected"), message: "matched")
        XCTAssertTrue(IntentLabReturnedValueProof.isVerified(assertions: [required],
            observations: ["answer": .string("expected")], resultKeys: ["answer"], checks: [passed]))
        XCTAssertFalse(IntentLabReturnedValueProof.isVerified(assertions: [required],
            observations: [:], resultKeys: ["answer"], checks: [passed]))
    }
}
