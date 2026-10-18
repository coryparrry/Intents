import Foundation
import Testing
#if SWIFT_PACKAGE
import IntentLabContracts
#endif
@testable import FoundationEvals

struct ScenarioV3HarnessBridgeTests {
    @Test func localControlAuthoringAllowsPartialInputsButOnlyCompleteBindingDispatches() throws {
        let catalog = ScenarioIntegrationCatalog(
            schemaVersion: 1, id: "notes", version: "1.0",
            targetBundleIdentifier: "com.coryparry.IntentLabFixture",
            actions: [.init(id: "OpenNoteIntent", parameters: [])],
            resultProjections: [], observers: [], preparationOperations: ["resetPackingNotes"],
            capabilities: ["local-feature-controls", "test-only-intent"],
            localFeatureControls: [.init(
                featureID: "summarize-note", interfaceDigest: String(repeating: "a", count: 64),
                operationID: "SummarizeNoteService", testIntentIdentifier: "InvokeFeatureTestIntent",
                parameters: [.init(name: "noteID", type: .primitive(.string), required: true)],
                outputProjections: [.init(
                    id: "summary", type: .primitive(.string),
                    path: [.init(kind: .property, name: "summary")]
                )]
            )]
        )
        let direct = try ScenarioExpectationAuthoring.withDeclaredIntentActionRequirements(
            stableScenario(), catalog: catalog
        )
        let partial = try ScenarioExpectationAuthoring.selectingLocalFeatureControl(
            featureID: "summarize-note", operationID: "SummarizeNoteService",
            inputMapping: [], in: direct, catalog: catalog
        )
        #expect(partial.featureBinding?.featureID == "summarize-note")
        #expect(catalog.localFeatureControl(for: partial) == nil)
        let complete = try ScenarioExpectationAuthoring.selectingLocalFeatureControl(
            featureID: "summarize-note", operationID: "SummarizeNoteService",
            inputMapping: [.init(featureInputName: "noteID", value: .string("packing-001"))],
            in: direct, catalog: catalog
        )
        #expect(catalog.localFeatureControl(for: complete)?.testIntentIdentifier
            == "InvokeFeatureTestIntent")
        #expect(complete.actionRequirements?.count == 2)
        #expect(complete.actionRequirements?.first(where: { $0.lane == .appFeature })?
            .resolvedParameters == ["noteID": .string("packing-001")])
    }

    @Test func strictActionPolicyRejectsStaleEnteredParametersButPreservesLegacyV3() throws {
        let legacy = try stableScenario()
        try ScenarioValidator.validate(legacy)

        var strict = legacy
        strict.actionPolicyVersion = 1
        strict.actionRequirements = [.init(
            lane: .intentIntegration, kind: .productionIntent,
            operationID: strict.directControl.intentIdentifier,
            resolvedParameters: ["note": .string("another-note")]
        )]
        strict = try strict.frozen()
        #expect(ScenarioValidator.issues(in: strict).contains {
            $0.severity == .error && $0.path.contains("resolvedParameters")
        })
        strict.actionRequirements?[0].resolvedParameters = [
            "note": .entity(.init(typeIdentifier: "NoteEntity", identifier: "packing-001"))
        ]
        strict = try strict.frozen()
        try ScenarioValidator.validate(strict)
    }

    @Test func featureScopeRequiresExplicitLocalBackendAndCarriesFrozenBinding() throws {
        var definition = try stableScenario()
        definition.coverage.appFeature = .required
        definition.featureBinding = .init(
            featureID: "summarize-note", interfaceDigest: String(repeating: "a", count: 64),
            inputMapping: [.init(featureInputName: "noteID", value: .string("packing-001"))],
            outputProjections: [.init(name: "summary", type: .primitive(.string),
                                      path: [.init(kind: .property, name: "summary")])]
        )
        definition.actionRequirements = [.init(
            lane: .appFeature, kind: .productionService,
            operationID: "SummarizeNoteService", resolvedParameters: ["noteID": .string("packing-001")]
        )]
        definition.actionPolicyVersion = 1
        definition = try definition.frozen()
        let scope = ScenarioNativeExecutionScope(lane: .appFeature, attempt: 1)
        #expect(!scope.isValid(for: definition))
        #expect(scope.isValid(for: definition, featureBackend: .projectLocalTestControl))
        #expect(!ScenarioHarnessCapabilities.required(for: definition).contains("local-feature-controls"))
        #expect(ScenarioHarnessCapabilities.required(
            for: definition, scope: scope, featureBackend: .projectLocalTestControl
        ).contains("local-feature-controls"))
        #expect(throws: XCTestRunInvocationTransportError.self) {
            _ = try XCTestRunInvocationTransport.scenarioPayload(for: definition, scope: scope)
        }
        let data = try XCTestRunInvocationTransport.scenarioPayload(
            for: definition, scope: scope, featureBackend: .projectLocalTestControl
        )
        let wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let binding = try #require(wire["featureBinding"] as? [String: Any])
        let selected = try #require(wire["executionScope"] as? [String: Any])
        #expect(binding["featureID"] as? String == "summarize-note")
        #expect(binding["interfaceDigest"] as? String == String(repeating: "a", count: 64))
        #expect(selected["lane"] as? String == "appFeature")
        #expect(wire["featureBackend"] == nil)
        #expect(wire["target"] != nil)
    }

    @Test func scopedChildrenKeepFrozenContractWithoutForeignFeatureObservation() throws {
        var definition = try stableScenario()
        definition.coverage.appFeature = .required
        definition.coverage.siri = .required
        definition.checkMode = .behaviour
        definition.requiredClaims = [
            .executionCompleted, .returnedValueChecked, .applicationStateChecked
        ]
        definition.featureBinding = .init(
            featureID: "summarize-note", interfaceDigest: String(repeating: "a", count: 64),
            inputMapping: [.init(featureInputName: "noteID", value: .string("packing-001"))],
            outputProjections: [.init(
                name: "summary", type: .primitive(.string),
                path: [.init(kind: .property, name: "summary")]
            )]
        )
        definition.observationPlan?.append(.init(
            id: "selectedNoteState", source: .uiElement,
            operationID: nil, selector: "selectedNoteState"
        ))
        definition.observationPlan?.append(.init(
            id: "feature.response", source: .testOnlyIntent,
            operationID: "SummarizeNoteService", selector: nil
        ))
        definition.assertions.append(.init(
            kind: .entityIdentifier, observationKey: "selectedNoteState",
            expectedValue: .string("packing-001"), explanation: "Selected note state is visible.",
            applicableLanes: [.appFeature, .intentIntegration, .siri]
        ))
        definition.assertions.append(.init(
            kind: .returnedField, observationKey: "feature.response",
            expectedValue: .string("Packing summary"), explanation: "Feature response is captured.",
            applicableLanes: [.appFeature]
        ))
        let intentParameters = Dictionary(
            definition.directControl.parameters.compactMap { parameter -> (String, ScenarioValue)? in
                guard case .value(let value) = parameter.presence else { return nil }
                return (parameter.name, value)
            }, uniquingKeysWith: { first, _ in first }
        )
        definition.actionPolicyVersion = 1
        definition.actionRequirements = [
            .init(lane: .appFeature, kind: .productionService,
                  operationID: "SummarizeNoteService",
                  resolvedParameters: ["noteID": .string("packing-001")]),
            .init(lane: .intentIntegration, kind: .productionIntent,
                  operationID: definition.directControl.intentIdentifier,
                  resolvedParameters: intentParameters),
            .init(lane: .siri, kind: .productionIntent,
                  operationID: definition.directControl.intentIdentifier,
                  resolvedParameters: intentParameters),
        ]
        definition = try definition.frozen()
        try ScenarioValidator.validate(definition)

        for lane in [ScenarioLane.intentIntegration, .siri, .appFeature] {
            let data = try XCTestRunInvocationTransport.scenarioPayload(
                for: definition,
                scope: .init(lane: lane, attempt: 1),
                featureBackend: .projectLocalTestControl
            )
            let wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let observations = try #require(wire["observationPlan"] as? [[String: Any]])
            let assertionWire = try #require(wire["assertions"] as? [[String: Any]])
            let requirementWire = try #require(wire["actionRequirements"] as? [[String: Any]])
            let coverage = try #require(wire["coverage"] as? [String: Any])
            #expect(wire["definitionDigest"] as? String == definition.definitionDigest)
            #expect(assertionWire.count == definition.assertions.count)
            #expect(Set(requirementWire.compactMap { $0["lane"] as? String })
                == Set(["appFeature", "intentIntegration", "siri"]))
            let featureAssertion = try #require(assertionWire.first {
                $0["observationKey"] as? String == "feature.response"
            })
            #expect(Set(featureAssertion["applicableLanes"] as? [String] ?? []) == ["appFeature"])
            #expect(coverage["appFeature"] as? String == "required")
            #expect(coverage["intentIntegration"] as? String == "required")
            #expect(coverage["siri"] as? String == "required")
            let observationIDs = observations.compactMap { $0["id"] as? String }
            #expect(observationIDs.contains("selectedNoteID"))
            #expect(observationIDs.contains("selectedNoteState"))
            #expect(observationIDs.contains("feature.response") == (lane == .appFeature))
            #expect((wire["featureBinding"] is [String: Any]) == (lane == .appFeature))
        }
    }

    @Test func reusableCapabilitiesFollowPlannedNativeRoutes() throws {
        var siriOnly = try stableScenario()
        siriOnly.coverage.intentIntegration = .notApplicable
        siriOnly.coverage.siri = .required
        siriOnly.checkMode = .behaviour
        siriOnly.requiredClaims = [.executionCompleted, .applicationStateChecked]
        siriOnly.assertions = [.init(
            kind: .entityIdentifier, observationKey: "selectedNoteID",
            expectedValue: .string("packing-001"),
            explanation: "Siri selected the requested note.", applicableLanes: [.siri]
        )]
        siriOnly.observationPlan = [.init(
            id: "selectedNoteID", source: .uiElement,
            operationID: nil, selector: "selectedNoteID"
        )]
        siriOnly = try siriOnly.frozen()
        try ScenarioValidator.validate(siriOnly)
        #expect(ScenarioNativeExecutionScope(lane: .siri, attempt: 1).isValid(for: siriOnly))
        let siriCapabilities = ScenarioHarnessCapabilities.required(for: siriOnly)
        #expect(siriCapabilities == [
            "environment-payload", "preparation", "accessible-result",
            "siri", "siri-completion", "invocation-correlation"
        ])

        let directOnly = try stableScenario()
        let directCapabilities = ScenarioHarnessCapabilities.required(for: directOnly)
        #expect(directCapabilities.contains("direct-intent-execution"))
        #expect(directCapabilities.contains("direct-intent-output"))
        #expect(!directCapabilities.contains("siri"))

        var mixed = directOnly
        mixed.coverage.siri = .required
        let mixedCapabilities = ScenarioHarnessCapabilities.required(for: mixed)
        #expect(mixedCapabilities.contains("direct-intent-execution"))
        #expect(mixedCapabilities.contains("direct-intent-output"))
        #expect(mixedCapabilities.contains("siri"))

        var legacy = siriOnly
        legacy.schemaVersion = ScenarioDefinition.currentSchemaVersion
        #expect(ScenarioHarnessCapabilities.required(for: legacy) == [
            "environment-payload", "fixture-reset", "invocation-correlation",
            "accessible-result", "direct-intent-output"
        ])
    }

    @Test func stableDefinitionUsesVersionTwoDeviceWireWithoutLocalRequirements() throws {
        let definition = try stableScenario()
        let scope = ScenarioNativeExecutionScope(lane: .intentIntegration, attempt: 1)
        let data = try XCTestRunInvocationTransport.scenarioPayload(for: definition, scope: scope)
        let wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try #require(wire["target"] as? [String: Any])
        let direct = try #require(wire["directControl"] as? [String: Any])
        let selected = try #require(wire["executionScope"] as? [String: Any])

        #expect(wire["schemaVersion"] as? Int == ScenarioDefinition.reusableSchemaVersion)
        #expect(wire["definitionDigest"] as? String == definition.definitionDigest)
        #expect(wire["testContractDigest"] == nil)
        #expect(target["bundleIdentifier"] as? String == definition.target.bundleIdentifier)
        #expect(target["projectPath"] == nil)
        #expect(target["destinationIdentifier"] == nil)
        #expect(direct["linkedFeatureRunID"] == nil)
        #expect(selected["lane"] as? String == "intentIntegration")
        #expect(selected["attempt"] as? Int == 1)
        #expect(ScenarioHarnessCapabilities.required(for: definition).contains("direct-intent-execution"))
        #expect(!ScenarioHarnessCapabilities.required(for: definition).contains("fixture-reset"))
        #expect(throws: XCTestRunInvocationTransportError.self) {
            _ = try XCTestRunInvocationTransport.scenarioPayload(
                for: definition, scope: .init(lane: .siri, attempt: 1)
            )
        }
    }

    @Test func versionTwoEnvelopeImportsAgainstStableHostContractAndJournalDestination() throws {
        let definition = try stableScenario()
        let invocation = boundInvocation(for: definition)
        let journal = executionJournal(for: definition, invocation: invocation)
        let envelope = evidence(for: definition, invocation: invocation)
        var ledger = ScenarioImportLedger()
        let run = try XCTestEvidenceImporter().importEvidence(
            data: try encode(envelope), definition: definition, journal: journal,
            artifactRoot: FileManager.default.temporaryDirectory, ledger: &ledger
        )

        #expect(run.outcome == .passed)
        #expect(run.scenarioSchemaVersion == ScenarioDefinition.stableSchemaVersion)
        #expect(run.scenarioDigest == definition.definitionDigest)
        #expect(run.testContractDigest == definition.testContractDigest)
        #expect(run.executedTestCount == 1)
        #expect(run.invocation.destinationIdentifier == "selected-device")
        #expect(run.integration == definition.integration)
        #expect(run.measurementImplementation == nil)
        #expect(run.comparisonEnvironmentIdentity == nil)
        #expect(run.subjectImplementation == nil)
        #expect(ledger.importedInvocationIDs.contains(invocation.id))

        var completedRun = run
        completedRun.xctestExitCode = 0
        let release = ScenarioReleaseCheckEvaluator.report(
            definition: definition, run: completedRun, journalAccepted: true
        )
        #expect(release.outcome != .passed)
        #expect(release.failures.contains { $0.contains("measurement or qualified environment provenance") })
    }

    @Test func importerRejectsClaimedPassWithWrongAppActionAndRetainsHonestFailure() throws {
        var definition = try stableScenario()
        definition.actionPolicyVersion = 1
        definition.actionRequirements = [.init(
            lane: .intentIntegration, kind: .productionIntent,
            operationID: definition.directControl.intentIdentifier,
            resolvedParameters: ["note": .entity(.init(
                typeIdentifier: "NoteEntity", identifier: "packing-001"
            ))]
        )]
        definition = try definition.frozen()
        try ScenarioValidator.validate(definition)
        let invocation = boundInvocation(for: definition)
        let journal = executionJournal(for: definition, invocation: invocation)
        var envelope = evidence(for: definition, invocation: invocation)
        let now = Date()
        let wrong = ScenarioActionReceipt(
            executionID: UUID(), appSessionID: UUID(),
            attemptContext: "intent-\(invocation.id.uuidString)",
            lane: .intentIntegration, attempt: 1, kind: .productionIntent,
            operationID: "AnotherIntent", resolvedParameters: [:],
            terminalStatus: .succeeded, operationError: nil,
            sequence: 1, startedAt: now, completedAt: now,
            observationTransport: .accessibleUI
        )
        envelope.results[0].actionReceipts = [wrong]
        let receiptEncoder = JSONEncoder()
        receiptEncoder.dateEncodingStrategy = .iso8601
        envelope.results[0].observations["intentlab.actionReceipts"] = .string(
            String(decoding: try receiptEncoder.encode([wrong]), as: UTF8.self)
        )
        envelope.results[0].observationSources?["intentlab.actionReceipts"] = .accessibleUI
        var ledger = ScenarioImportLedger()
        #expect(throws: ScenarioEvidenceImportError.self) {
            _ = try XCTestEvidenceImporter().importEvidence(
                data: try encode(envelope), definition: definition, journal: journal,
                artifactRoot: FileManager.default.temporaryDirectory, ledger: &ledger
            )
        }
        #expect(ledger == ScenarioImportLedger())

        envelope.results[0].outcome = .failed
        envelope.results[0].actionFailureReason = .wrongAction
        let retained = try XCTestEvidenceImporter().importEvidence(
            data: try encode(envelope), definition: definition, journal: journal,
            artifactRoot: FileManager.default.temporaryDirectory, ledger: &ledger
        )
        #expect(retained.executionStatus == .completed)
        #expect(retained.laneResults[0].outcome == .failed)
        #expect(retained.laneResults[0].actionFailureReason == .wrongAction)

        var rawOnly = envelope
        rawOnly.results[0].actionReceipts = nil
        rawOnly.results[0].actionFailureReason = nil
        rawOnly.results[0].outcome = .notObserved
        var independentLedger = ScenarioImportLedger()
        let derived = try XCTestEvidenceImporter().importEvidence(
            data: try encode(rawOnly), definition: definition, journal: journal,
            artifactRoot: FileManager.default.temporaryDirectory,
            ledger: &independentLedger
        )
        #expect(derived.laneResults[0].outcome == .failed)
        #expect(derived.laneResults[0].actionFailureReason == .wrongAction)
        #expect(derived.laneResults[0].actionReceipts?.map(\.executionID) == [wrong.executionID])
        #expect(derived.laneResults[0].actionReceipts?.map(\.operationID) == ["AnotherIntent"])
    }

    @Test func stableImportRejectsOtherDestinationAndMissingProductProvenance() throws {
        let definition = try stableScenario()
        let invocation = boundInvocation(for: definition)
        let journal = executionJournal(for: definition, invocation: invocation)
        let importer = XCTestEvidenceImporter()

        var wrongDestination = evidence(for: definition, invocation: invocation)
        wrongDestination.invocation.destinationIdentifier = "another-device"
        var ledger = ScenarioImportLedger()
        #expect(throws: ScenarioEvidenceImportError.self) {
            _ = try importer.importEvidence(
                data: try encode(wrongDestination), definition: definition,
                journal: journal, artifactRoot: FileManager.default.temporaryDirectory,
                ledger: &ledger
            )
        }
        #expect(ledger == ScenarioImportLedger())

        var wrongJournal = journal
        wrongJournal.scenarioID = UUID()
        #expect(throws: ScenarioEvidenceImportError.self) {
            _ = try importer.importEvidence(
                data: try encode(evidence(for: definition, invocation: invocation)),
                definition: definition, journal: wrongJournal,
                artifactRoot: FileManager.default.temporaryDirectory, ledger: &ledger
            )
        }
        #expect(ledger == ScenarioImportLedger())

        var missingProduct = evidence(for: definition, invocation: invocation)
        missingProduct.invocation.appProduct = nil
        #expect(throws: ScenarioEvidenceImportError.self) {
            _ = try importer.importEvidence(
                data: try encode(missingProduct), definition: definition,
                journal: journal, artifactRoot: FileManager.default.temporaryDirectory,
                ledger: &ledger
            )
        }
        #expect(ledger == ScenarioImportLedger())
    }

    @Test func scopedImportRequiresItsOwnJournalAndCannotQualifyWholeCheck() throws {
        let definition = try stableScenario()
        let scope = ScenarioNativeExecutionScope(lane: .intentIntegration, attempt: 1)
        let invocation = boundInvocation(for: definition)
        var journal = executionJournal(for: definition, invocation: invocation)
        journal.scope = scope
        let envelope = evidence(for: definition, invocation: invocation)
        let importer = XCTestEvidenceImporter()
        var ledger = ScenarioImportLedger()

        let scoped = try importer.importEvidence(
            data: try encode(envelope), definition: definition, journal: journal,
            artifactRoot: FileManager.default.temporaryDirectory, ledger: &ledger,
            scope: scope
        )
        #expect(scoped.laneResults.count == 1)
        #expect(scoped.laneResults[0].outcome == .passed)
        #expect(scoped.outcome == .notObserved)

        var freshLedger = ScenarioImportLedger()
        #expect(throws: ScenarioEvidenceImportError.self) {
            _ = try importer.importEvidence(
                data: try encode(envelope), definition: definition, journal: journal,
                artifactRoot: FileManager.default.temporaryDirectory, ledger: &freshLedger
            )
        }
        #expect(freshLedger == ScenarioImportLedger())

        var wrongCoordinate = envelope
        wrongCoordinate.results[0].attempt = 2
        #expect(throws: ScenarioEvidenceImportError.self) {
            _ = try importer.importEvidence(
                data: try encode(wrongCoordinate), definition: definition, journal: journal,
                artifactRoot: FileManager.default.temporaryDirectory, ledger: &freshLedger,
                scope: scope
            )
        }
        #expect(freshLedger == ScenarioImportLedger())
    }

    @Test func importerRejectsUnverifiedMeasurementIdentity() throws {
        let definition = try stableScenario()
        let invocation = boundInvocation(for: definition)
        let journal = executionJournal(for: definition, invocation: invocation)
        var ledger = ScenarioImportLedger()
        let invented = ScenarioMeasurementImplementation(
            observerID: "ui-test-executable:invented", observerDigest: "invented",
            evaluatorID: "host-executable:invented", evaluatorDigest: "invented"
        )
        #expect(throws: ScenarioEvidenceImportError.self) {
            _ = try XCTestEvidenceImporter().importEvidence(
                data: try encode(evidence(for: definition, invocation: invocation)),
                definition: definition, journal: journal,
                artifactRoot: FileManager.default.temporaryDirectory, ledger: &ledger,
                measurementImplementation: invented
            )
        }
        #expect(ledger == ScenarioImportLedger())
    }

    @Test func mixedRoutesRequireOnlyTheirOwnDeclaredProof() throws {
        let definition = try mixedRouteScenario()
        var results = try ScenarioLane.allCases.map { lane in
            try mixedRouteResult(for: definition, lane: lane, invocation: boundInvocation(for: definition))
        }
        #expect(ScenarioResultEvaluator.overall(definition: definition, laneResults: results) == .passed)
        let featureIndex = try #require(results.firstIndex { $0.lane == .appFeature })
        results[featureIndex].observationSources?["feature.response"] = .manuallySupplied
        #expect(ScenarioResultEvaluator.overall(definition: definition, laneResults: results) == .notObserved)
        results[featureIndex].observationSources?["feature.response"] = .testOnlyIntent
        let siriIndex = try #require(results.firstIndex { $0.lane == .siri })
        results[siriIndex].claims = [.executionCompleted]
        #expect(ScenarioResultEvaluator.overall(definition: definition, laneResults: results) == .notObserved)
    }

    @Test func scopedPayloadAndImporterPreserveMixedRouteProofRequirements() throws {
        let definition = try mixedRouteScenario()
        for lane in ScenarioLane.allCases {
            let data = try XCTestRunInvocationTransport.scenarioPayload(
                for: definition, scope: .init(lane: lane, attempt: 1),
                featureBackend: .projectLocalTestControl
            )
            let wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let claims = Set(try #require(wire["requiredClaims"] as? [String]))
            let expected: Set<String> = lane == .siri
                ? ["executionCompleted", "applicationStateChecked"]
                : ["executionCompleted", "returnedValueChecked"]
            #expect(claims == expected)
            #expect(wire["checkMode"] as? String == (lane == .siri ? "behaviour" : "basic"))
            #expect(wire["definitionDigest"] as? String == definition.definitionDigest)
            #if SWIFT_PACKAGE
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(IntentLabScenario.self, from: data)
            try payload.validateContract(harnessVersion: "intent-lab-v2")
            #endif
        }

        let scope = ScenarioNativeExecutionScope(lane: .intentIntegration, attempt: 1)
        var invocation = boundInvocation(for: definition)
        invocation.requiredCapabilities = ScenarioHarnessCapabilities.required(
            for: definition, scope: scope, featureBackend: .projectLocalTestControl
        ).sorted()
        var journal = executionJournal(for: definition, invocation: invocation)
        journal.scope = scope
        var envelope = evidence(for: definition, invocation: invocation)
        envelope.results = [try mixedRouteResult(for: definition, lane: .intentIntegration, invocation: invocation)]
        var ledger = ScenarioImportLedger()
        let imported = try XCTestEvidenceImporter().importEvidence(
            data: try encode(envelope), definition: definition, journal: journal,
            artifactRoot: FileManager.default.temporaryDirectory, ledger: &ledger, scope: scope
        )
        #expect(imported.laneResults.first?.outcome == .passed)
        #expect(imported.outcome == .notObserved, "A correct child still cannot certify the full multi-route contract")

        envelope.results[0].observations["selectedNoteID"] = .string("wrong-note")
        var freshLedger = ScenarioImportLedger()
        let failed = try XCTestEvidenceImporter().importEvidence(
            data: try encode(envelope), definition: definition, journal: journal,
            artifactRoot: FileManager.default.temporaryDirectory, ledger: &freshLedger, scope: scope
        )
        #expect(failed.laneResults.first?.outcome == .failed)
        #expect(failed.laneResults.first?.actionFailureReason == .wrongOutcome)
    }

    private func mixedRouteScenario() throws -> ScenarioDefinition {
        var definition = try stableScenario()
        definition.coverage = .init(appFeature: .required, intentIntegration: .required, siri: .required, siriAttemptCount: 1)
        definition.featureBinding = .init(
            featureID: "summarize-note", interfaceDigest: String(repeating: "a", count: 64),
            inputMapping: [], outputProjections: []
        )
        definition.checkMode = .behaviour
        definition.requiredClaims = [.executionCompleted, .returnedValueChecked, .applicationStateChecked]
        definition.observationPlan?.append(contentsOf: [
            .init(id: "feature.response", source: .testOnlyIntent, operationID: "SummarizeNoteService"),
            .init(id: "selectedNoteState", source: .uiElement, selector: "selectedNoteState"),
        ])
        definition.assertions.append(contentsOf: [
            .init(kind: .returnedField, observationKey: "feature.response", expectedValue: .string("Packing summary"),
                  explanation: "The Feature returned the requested response.", applicableLanes: [.appFeature]),
            .init(kind: .entityIdentifier, observationKey: "selectedNoteState", expectedValue: .string("packing-001"),
                  explanation: "Siri selected the requested note.", applicableLanes: [.siri]),
        ])
        let parameters = Dictionary(uniqueKeysWithValues: definition.directControl.parameters.compactMap {
            parameter -> (String, ScenarioValue)? in
            guard case .value(let value) = parameter.presence else { return nil }
            return (parameter.name, value)
        })
        definition.actionPolicyVersion = 1
        definition.actionRequirements = [
            .init(lane: .appFeature, kind: .productionService, operationID: "SummarizeNoteService", resolvedParameters: [:]),
            .init(lane: .intentIntegration, kind: .productionIntent,
                  operationID: definition.directControl.intentIdentifier, resolvedParameters: parameters),
            .init(lane: .siri, kind: .productionIntent,
                  operationID: definition.directControl.intentIdentifier, resolvedParameters: parameters),
        ]
        definition = try definition.frozen()
        try ScenarioValidator.validate(definition)
        return definition
    }

    private func mixedRouteResult(
        for definition: ScenarioDefinition, lane: ScenarioLane, invocation: ScenarioInvocationIdentity
    ) throws -> ScenarioLaneResult {
        let requirement = try #require(definition.actionRequirements?.first { $0.lane == lane })
        let assertion = try #require(definition.assertions.first { $0.applies(to: lane) })
        let expected = try #require(assertion.expectedValue)
        let now = Date(timeIntervalSince1970: 1_000)
        let source: ScenarioObservationSource = lane == .appFeature ? .testOnlyIntent : .accessibleUI
        let context = lane == .siri ? "siri-\(invocation.id.uuidString)-1"
            : "\(lane == .appFeature ? "feature" : "intent")-\(invocation.id.uuidString)"
        let receipt = ScenarioActionReceipt(
            executionID: UUID(), appSessionID: UUID(), attemptContext: context,
            lane: lane, attempt: 1, kind: requirement.kind, operationID: requirement.operationID,
            resolvedParameters: requirement.resolvedParameters, terminalStatus: .succeeded,
            operationError: nil, sequence: 1, startedAt: now, completedAt: now,
            observationTransport: source
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let raw = String(decoding: try encoder.encode([receipt]), as: UTF8.self)
        return .init(
            caseID: definition.id, attempt: 1, lane: lane, executionStatus: .completed, outcome: .passed,
            startedAt: now, completedAt: now,
            observations: [assertion.observationKey: expected, "intentlab.actionReceipts": .string(raw)],
            assertionResults: [.init(assertionID: assertion.id, passed: true, observedValue: expected, message: "Matched")],
            observationSources: [assertion.observationKey: lane == .intentIntegration ? .appIntentsTesting : source,
                                 "intentlab.actionReceipts": source],
            claims: lane == .siri ? [.executionCompleted, .applicationStateChecked] : [.executionCompleted, .returnedValueChecked],
            actionReceipts: [receipt], cleanupVerified: true
        )
    }

    private func stableScenario() throws -> ScenarioDefinition {
        var definition = ScenarioDefinition.starter()
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.target.projectPath = "stale-checkout.xcodeproj"
        definition.target.destinationIdentifier = "stale-device"
        definition.goal.requestText = "Open the packing note"
        definition.goal.languageCode = "en-GB"
        definition.goal.expectedBehavior = "Return the selected note identifier"
        definition.assertions = [.init(
            kind: .returnedField, observationKey: "selectedNoteID",
            expectedValue: .string("packing-001"),
            explanation: "The returned note is the requested note.",
            applicableLanes: [.intentIntegration]
        )]
        definition.directControl.outputFields = [.init(
            name: "selectedNoteID", type: .primitive(.string),
            path: [.init(kind: .property, name: "selectedNoteID")]
        )]
        definition.coverage.appFeature = .notApplicable
        definition.coverage.siri = .notApplicable
        definition.purpose = .exploratory
        definition.checkMode = .basic
        definition.requiredClaims = [.executionCompleted, .returnedValueChecked]
        definition.observationPlan = [.init(
            id: "selectedNoteID", source: .intentResult,
            operationID: nil, selector: nil
        )]
        definition.integration = .init(
            id: "notes", version: "1.0", digest: String(repeating: "a", count: 64)
        )
        definition = try definition.frozen()
        try ScenarioValidator.validate(definition)
        return definition
    }

    private func boundInvocation(for definition: ScenarioDefinition) -> ScenarioInvocationIdentity {
        let app = ScenarioProductIdentity(
            bundleIdentifier: definition.target.bundleIdentifier, executableName: "Notes", sha256: "app-build"
        )
        let test = ScenarioProductIdentity(
            bundleIdentifier: "dev.example.NotesUITests", executableName: "NotesUITests", sha256: "test-build"
        )
        return .init(
            id: UUID(), nonce: UUID().uuidString, issuedAt: Date(),
            testIdentity: .init(bundleIdentifier: test.bundleIdentifier,
                                className: "IntentLabScenarioTests", methodName: "testIntentLabScenario"),
            harnessVersion: ScenarioInvocationIdentity.reusableHarnessVersion,
            destinationIdentifier: "selected-device", scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: "IntentLab.xcresult", appProduct: app, testProduct: test,
            integration: definition.integration,
            requiredCapabilities: ScenarioHarnessCapabilities.required(for: definition).sorted()
        )
    }

    private func executionJournal(
        for definition: ScenarioDefinition, invocation: ScenarioInvocationIdentity
    ) -> ScenarioExecutionJournal {
        .init(
            phase: .stopped, invocation: invocation, scenarioID: definition.id,
            scenarioVersion: definition.version, resultBundlePath: "/tmp/IntentLab.xcresult",
            derivedDataPath: "/tmp/DerivedData", buildLogPath: "/tmp/build.log",
            intendedExecutable: "/usr/bin/xcodebuild", intendedArguments: [],
            processIdentifier: nil, processStartedAt: nil, updatedAt: Date(), recoveryReason: nil
        )
    }

    private func evidence(
        for definition: ScenarioDefinition, invocation: ScenarioInvocationIdentity
    ) -> ScenarioEvidenceEnvelope {
        let now = Date()
        let direct = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .intentIntegration,
            executionStatus: .completed, outcome: .passed, startedAt: now, completedAt: now,
            observations: ["selectedNoteID": .string("packing-001")],
            assertionResults: [.init(
                assertionID: definition.assertions[0].id, passed: true,
                observedValue: .string("packing-001"),
                message: "The returned note matches the requested note."
            )],
            observationSources: ["selectedNoteID": .appIntentsTesting],
            claims: [.executionCompleted, .returnedValueChecked]
        )
        return .init(
            schemaVersion: ScenarioEvidenceEnvelope.reusableSchemaVersion,
            invocation: invocation, sourceBundleIdentifier: definition.target.bundleIdentifier,
            observedAppProduct: invocation.appProduct!, observedTestProduct: invocation.testProduct!,
            environment: .init(
                xcodeVersion: "27.0", sdkVersion: "27.0", deviceModel: "iPhone",
                operatingSystem: "iOS 27", operatingSystemBuild: nil, languageCode: "en-GB",
                regionCode: "GB", timeZoneIdentifier: "Europe/London", siriConfiguration: nil,
                siriConfigurationSource: nil, executedAt: now
            ),
            testCount: 1, results: [direct], integration: definition.integration,
            runnerPackageVersion: "0.2.0", negotiatedCapabilities:
                ScenarioHarnessCapabilities.required(for: definition).sorted()
        )
    }

    private func encode(_ envelope: ScenarioEvidenceEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }
}
