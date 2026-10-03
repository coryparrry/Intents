import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioV3HarnessBridgeTests {
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
