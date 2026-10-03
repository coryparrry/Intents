import AppIntentsTesting
import IntentLabContracts
import IntentLabTesting
import XCTest

@available(iOS 27.0, *)
@MainActor
final class NotesLocalFeatureControlTests: XCTestCase {
    func testDeclarationHasFixedTypedReadinessControl() throws {
        let declaration = try Self.loadDeclaration()
        try declaration.validate()
        let control = try declaration.declaredReadinessControl()

        XCTAssertEqual(control.operationID, "intentLabReadiness")
        XCTAssertEqual(control.testIntentIdentifier, "IntentLabReadinessIntent")
        XCTAssertEqual(control.response.id, "readiness.ready")
        XCTAssertEqual(control.response.type, .primitive(.boolean))
        XCTAssertEqual(control.response.path.map(\.name), ["value", "ready"])
    }

    func testDeclaredFeatureControlCallsProductionServiceDirectly() async throws {
        let declaration = try Self.loadDeclaration()
        try declaration.validate()
        guard let control = declaration.localFeatureControls?.first(where: {
            $0.featureID == FixtureFeatureContract.featureID
                && $0.operationID == FixtureFeatureContract.operationID
        }) else {
            return XCTFail("The fixture must declare the app-owned feature transport.")
        }
        let recomputedDigest = try IntentLabIntegrationDeclaration.FeatureControl.calculateInterfaceDigest(
            featureID: control.featureID,
            operationID: control.operationID,
            testIntentIdentifier: control.testIntentIdentifier,
            parameters: control.parameters,
            outputProjections: control.outputProjections
        )
        XCTAssertEqual(control.interfaceDigest, recomputedDigest)
        XCTAssertEqual(control.interfaceDigest, "6fefab137a5684642fdc14a0bcb2a6ede5544666cdb6b1db6fd415d41dfd1c26")
        XCTAssertEqual(control.testIntentIdentifier, "IntentLabInvokeFeatureIntent")
        XCTAssertEqual(control.parameters.map(\.name), ["prompt"])
        XCTAssertTrue(control.outputProjections.isEmpty)

        let context = "feature-\(UUID().uuidString)"
        let application = try NotesIntentLabIntegration().prepare(
            bundleIdentifier: declaration.targetBundleIdentifier,
            context: context,
            operationID: "resetFixture"
        )
        defer { application.terminate() }

        let parameter = IntentLabParameter(
            name: "prompt",
            type: .primitive(.string),
            isOptional: false,
            presence: .value(.string("packing-001"))
        )
        var featureResult: IntentLabTestIntentResult?
        var invocationError: Error?
        do {
            featureResult = try await IntentLabTestIntentTransport.invoke(
                bundleIdentifier: declaration.targetBundleIdentifier,
                control: control,
                parameters: [parameter],
                context: context
            )
        } catch {
            // On devices without an available Foundation Model, the real service
            // records its failed terminal receipt before reporting unavailability.
            invocationError = error
        }

        let integration = NotesIntentLabIntegration()
        var observations: [String: IntentLabValue] = [:]
        for _ in 0..<20 {
            observations = try integration.observe(application: application)
            if case .string(let json) = observations["intentlab.actionReceipts"], json.contains(context) {
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard case .string(let rawReceipts) = observations["intentlab.actionReceipts"],
              let receiptData = rawReceipts.data(using: .utf8) else {
            return XCTFail("The app must expose its action receipts after the feature call.")
        }
        let receipts = try JSONDecoder.intentLab.decode([IntentLabActionReceipt].self, from: receiptData)
        let serviceReceipts = receipts.filter {
            $0.kind == .productionService
                && $0.operationID == FixtureFeatureContract.operationID
                && $0.attemptContext == context
        }
        XCTAssertEqual(serviceReceipts.count, 1, "The test intent must enter the real production service exactly once.")
        XCTAssertEqual(serviceReceipts.first?.lane, .appFeature)
        XCTAssertTrue(serviceReceipts.first?.isTopLevel == true)
        XCTAssertEqual(serviceReceipts.first?.resolvedParameters["prompt"], .string("packing-001"))

        let wrapperReceipts = receipts.filter {
            $0.kind == .testSupport
                && $0.operationID == "IntentLabInvokeFeatureIntent"
                && $0.attemptContext == context
        }
        XCTAssertEqual(wrapperReceipts.count, 1, "The transport wrapper must be identified only as test support.")
        XCTAssertTrue(wrapperReceipts.first?.isTopLevel == false)
        if let wrapper = wrapperReceipts.first, let service = serviceReceipts.first {
            XCTAssertLessThan(wrapper.sequence, service.sequence,
                              "Receipt ordering must preserve wrapper-before-service execution.")
        }

        let executionEvidence = NotesFeatureExecutionEvidence(
            context: context,
            featureResponse: featureResult?.observations["feature.response"].flatMap {
                if case .string(let value) = $0 { return value }
                return nil
            },
            productionServiceReceipt: serviceReceipts.first,
            wrapperReceipt: wrapperReceipts.first,
            invocationError: invocationError?.localizedDescription
        )
        let evidenceAttachment = XCTAttachment(data: try JSONEncoder.intentLab.encode(executionEvidence),
                                               uniformTypeIdentifier: "public.json")
        evidenceAttachment.name = "NotesLocalFeatureExecution.json"
        evidenceAttachment.lifetime = .keepAlways
        add(evidenceAttachment)

        if serviceReceipts.first?.terminalStatus == .succeeded {
            guard case .string(let response)? = featureResult?.observations["feature.response"] else {
                return XCTFail("A successful service call must project value.response as feature.response.")
            }
            XCTAssertFalse(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
            XCTAssertNotNil(invocationError, "A failed service receipt must surface the App Intent error.")
        }
    }

    func testMalformedFeatureContextDoesNotCreateActionReceipts() async throws {
        let declaration = try Self.loadDeclaration()
        let control = try featureControl(in: declaration)
        let context = "feature-invalid"
        let application = try NotesIntentLabIntegration().prepare(
            bundleIdentifier: declaration.targetBundleIdentifier,
            context: context,
            operationID: "resetFixture"
        )
        defer { application.terminate() }

        do {
            _ = try await invokeFeature(
                prompt: "unknown-note", control: control,
                bundleIdentifier: declaration.targetBundleIdentifier, context: context
            )
            XCTFail("An unknown note should fail inside the production feature service.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Name exactly one synthetic note by stable ID or full title."
            )
        }

        let snapshot = try await readFixtureSnapshot(bundleIdentifier: declaration.targetBundleIdentifier)
        XCTAssertTrue(snapshot.actionReceipts.isEmpty,
                      "A malformed feature context must not be stamped onto action receipts.")
    }

    func testReceiptCountOverflowFailsClosedAcrossReadersUntilFixtureReset() async throws {
        let declaration = try Self.loadDeclaration()
        let control = try featureControl(in: declaration)
        let integration = NotesIntentLabIntegration()
        let context = "intent-\(UUID().uuidString)"
        let application = try integration.prepare(
            bundleIdentifier: declaration.targetBundleIdentifier,
            context: context,
            operationID: "resetFixture"
        )
        defer { application.terminate() }

        for index in 0..<16 {
            do {
                _ = try await invokeFeature(
                    prompt: "unknown-note-\(index)", control: control,
                    bundleIdentifier: declaration.targetBundleIdentifier, context: context
                )
                XCTFail("An unknown note should fail after recording its test-support receipt.")
            } catch {
                // The failed wrapper receipt fills the bounded buffer without
                // creating a production action receipt.
            }
        }

        let fullSnapshot = try await readFixtureSnapshot(
            bundleIdentifier: declaration.targetBundleIdentifier
        )
        XCTAssertEqual(fullSnapshot.actionReceipts.count, 16)
        XCTAssertTrue(fullSnapshot.actionReceipts.allSatisfy { !$0.isTopLevel })

        // The next action would leave a recent matching top-level receipt if
        // the old behavior silently evicted earlier entries.
        _ = try await runOpenNote(
            bundleIdentifier: declaration.targetBundleIdentifier, noteID: "packing-001"
        )

        let overflowSnapshot = try await readFixtureSnapshot(
            bundleIdentifier: declaration.targetBundleIdentifier
        )
        XCTAssertTrue(overflowSnapshot.actionReceipts.isEmpty)

        let visibleReceipts = try await waitForVisibleActionReceipts(
            application: application, integration: integration
        )
        XCTAssertTrue(visibleReceipts.isEmpty, "The accessible UI must not expose a truncated receipt history.")

        application.terminate()
        let resetContext = "intent-\(UUID().uuidString)"
        let resetApplication = try integration.prepare(
            bundleIdentifier: declaration.targetBundleIdentifier,
            context: resetContext,
            operationID: "resetFixture"
        )
        defer { resetApplication.terminate() }

        do {
            _ = try await invokeFeature(
                prompt: "unknown-after-reset", control: control,
                bundleIdentifier: declaration.targetBundleIdentifier, context: resetContext
            )
            XCTFail("An unknown note should fail after fixture reset.")
        } catch {
            // This receipt proves reset cleared the sticky overflow state.
        }
        let resetSnapshot = try await readFixtureSnapshot(
            bundleIdentifier: declaration.targetBundleIdentifier
        )
        XCTAssertEqual(resetSnapshot.actionReceipts.count, 1)
        XCTAssertEqual(resetSnapshot.actionReceipts.first?.attemptContext, resetContext)
    }

    func testReceiptByteOverflowFailsClosedBeforeLaterTopLevelAction() async throws {
        let declaration = try Self.loadDeclaration()
        let control = try featureControl(in: declaration)
        let integration = NotesIntentLabIntegration()
        let context = "intent-\(UUID().uuidString)"
        let application = try integration.prepare(
            bundleIdentifier: declaration.targetBundleIdentifier,
            context: context,
            operationID: "resetFixture"
        )
        defer { application.terminate() }

        do {
            _ = try await invokeFeature(
                prompt: String(repeating: "x", count: 70_000), control: control,
                bundleIdentifier: declaration.targetBundleIdentifier, context: context
            )
            XCTFail("An oversized unknown note prompt should fail after recording its bounded receipt.")
        } catch {
            // The prompt fits the test transport bound but makes the app receipt
            // exceed its independent persisted-byte bound.
        }

        _ = try await runOpenNote(
            bundleIdentifier: declaration.targetBundleIdentifier, noteID: "packing-001"
        )

        let snapshot = try await readFixtureSnapshot(
            bundleIdentifier: declaration.targetBundleIdentifier
        )
        XCTAssertTrue(snapshot.actionReceipts.isEmpty)
        let visibleReceipts = try await waitForVisibleActionReceipts(
            application: application, integration: integration
        )
        XCTAssertTrue(visibleReceipts.isEmpty)
    }

    private func featureControl(
        in declaration: IntentLabIntegrationDeclaration
    ) throws -> IntentLabIntegrationDeclaration.FeatureControl {
        guard let control = declaration.localFeatureControls?.first(where: {
            $0.featureID == FixtureFeatureContract.featureID
                && $0.operationID == FixtureFeatureContract.operationID
        }) else {
            throw NotesIntegrationDeclarationError.missingFeatureControl
        }
        return control
    }

    private func invokeFeature(
        prompt: String,
        control: IntentLabIntegrationDeclaration.FeatureControl,
        bundleIdentifier: String,
        context: String
    ) async throws -> IntentLabTestIntentResult {
        let parameter = IntentLabParameter(
            name: "prompt",
            type: .primitive(.string),
            isOptional: false,
            presence: .value(.string(prompt))
        )
        return try await IntentLabTestIntentTransport.invoke(
            bundleIdentifier: bundleIdentifier,
            control: control,
            parameters: [parameter],
            context: context
        )
    }

    private func runOpenNote(bundleIdentifier: String, noteID: String) async throws -> String {
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)
        var intent = definitions.intents["OpenNoteIntent"].makeIntent()
        intent[dynamicMember: "note"] = definitions.entities["NoteEntity"].makeReference(identifier: noteID)
        let result = try await intent.run()
        return try result.value
    }

    private func readFixtureSnapshot(bundleIdentifier: String) async throws -> FixtureReceiptSnapshot {
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)
        var intent = definitions.intents["IntentLabReadSnapshot"].makeIntent()
        intent[dynamicMember: "operationID"] = "readSnapshot"
        let result = try await intent.run()
        let snapshotJSON: String = try result.value
        return try JSONDecoder.intentLab.decode(
            FixtureReceiptSnapshot.self,
            from: Data(snapshotJSON.utf8)
        )
    }

    private func waitForVisibleActionReceipts(
        application: XCUIApplication,
        integration: NotesIntentLabIntegration
    ) async throws -> [IntentLabActionReceipt] {
        var observations: [String: IntentLabValue] = [:]
        for _ in 0..<20 {
            observations = try integration.observe(application: application)
            if case .string(let json) = observations["intentlab.actionReceipts"], json == "[]" {
                return try JSONDecoder.intentLab.decode([IntentLabActionReceipt].self, from: Data(json.utf8))
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard case .string(let json) = observations["intentlab.actionReceipts"] else {
            throw NotesIntegrationDeclarationError.missingActionReceipts
        }
        return try JSONDecoder.intentLab.decode([IntentLabActionReceipt].self, from: Data(json.utf8))
    }

    private static func loadDeclaration() throws -> IntentLabIntegrationDeclaration {
        guard let url = Bundle(for: NotesLocalFeatureControlTests.self)
            .url(forResource: "IntentLabIntegration", withExtension: "json") else {
            throw NotesIntegrationDeclarationError.missing
        }
        return try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self, from: Data(contentsOf: url))
    }
}

private enum FixtureFeatureContract {
    static let featureID = "intent-lab.summarize-note"
    static let operationID = "summarizeNote"
}

private enum NotesIntegrationDeclarationError: LocalizedError {
    case missing
    case missingFeatureControl
    case missingActionReceipts
    var errorDescription: String? {
        switch self {
        case .missing: "The Notes fixture declaration resource is missing."
        case .missingFeatureControl: "The Notes fixture declaration is missing its feature control."
        case .missingActionReceipts: "The fixture UI did not expose its bounded action receipt JSON."
        }
    }
}

private struct FixtureReceiptSnapshot: Decodable {
    var actionReceipts: [IntentLabActionReceipt]
}

private struct NotesFeatureExecutionEvidence: Encodable {
    var context: String
    var featureResponse: String?
    var productionServiceReceipt: IntentLabActionReceipt?
    var wrapperReceipt: IntentLabActionReceipt?
    var invocationError: String?
}
