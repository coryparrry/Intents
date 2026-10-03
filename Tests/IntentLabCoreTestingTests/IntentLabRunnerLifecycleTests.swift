import Foundation
import IntentLabContracts
@testable import IntentLabCoreTesting
import XCTest

@available(macOS 27.0, iOS 27.0, *)
@MainActor
final class IntentLabRunnerLifecycleTests: XCTestCase {
    func testDirectDriverErrorCapturesRawStateBeforeReturning() throws {
        var observationRead = false
        let receiptValue = try serializedReceipt(status: .failed)

        let capture = try IntentLabScenarioEngine.captureDirectObservations(
            execute: { throw RunnerTestError.driverFailed },
            observe: {
                observationRead = true
                return ["intentlab.actionReceipts": .string(receiptValue)]
            }
        )

        XCTAssertTrue(observationRead)
        XCTAssertEqual(capture.driverError?.localizedDescription, "Driver failure")
        XCTAssertNil(capture.observationError)
        XCTAssertEqual(capture.stateObservations["intentlab.actionReceipts"], .string(receiptValue))
    }

    func testDirectTimeoutDoesNotReadStateThatMayStillBeChanging() {
        var observationRead = false
        XCTAssertThrowsError(try IntentLabScenarioEngine.captureDirectObservations(
            execute: { throw IntentLabDirectIntentTimeout() },
            observe: {
                observationRead = true
                return [:]
            }
        )) { error in
            XCTAssertTrue(error is IntentLabDirectIntentTimeout)
        }
        XCTAssertFalse(observationRead)
    }

    func testCompletedActionWaitsForItsOwnPublishedReceipt() throws {
        let context = "feature-current"
        let start = Date(timeIntervalSince1970: 10)
        let receipt = IntentLabActionReceipt(
            executionID: UUID(), appSessionID: UUID(), attemptContext: context,
            lane: .appFeature, attempt: 1, kind: .productionService,
            operationID: "summarizeNote", resolvedParameters: ["prompt": .string("packing-001")],
            terminalStatus: .succeeded, operationError: nil,
            sequence: 1, startedAt: start, completedAt: start.addingTimeInterval(1),
            observationTransport: "accessibleUI"
        )
        let raw = try serialized([receipt])
        var reads = 0
        let captured = try IntentLabScenarioEngine.captureDirectObservations(
            execute: { ["feature.response": .string("Packing list")] },
            observe: {
                reads += 1
                return ["intentlab.actionReceipts": .string(reads == 1 ? "[]" : raw)]
            },
            receiptContext: context, receiptLane: .appFeature,
            receiptWaitSeconds: 0.5, receiptPollInterval: 0
        )
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(IntentLabScenarioEngine.hasAttributableTerminalAction(
            captured.stateObservations, context: context, lane: .appFeature
        ))
    }

    func testZeroWaitCaptureRetainsMissingReceiptArray() throws {
        var reads = 0
        let captured = try IntentLabScenarioEngine.captureDirectObservations(
            execute: { ["feature.response": .string("Response without action proof")] },
            observe: {
                reads += 1
                return ["intentlab.actionReceipts": .string("[]")]
            },
            receiptContext: "current", receiptLane: .appFeature,
            receiptWaitSeconds: 0, receiptPollInterval: 0
        )
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(captured.stateObservations["intentlab.actionReceipts"], .string("[]"))
        XCTAssertFalse(IntentLabScenarioEngine.hasAttributableTerminalAction(
            captured.stateObservations, context: "current", lane: .appFeature
        ))
    }

    func testReceiptCapturePreservesDuplicateRecords() throws {
        let raw = try serializedReceipt(status: .succeeded)
        let receipt = try JSONDecoder.intentLab.decode([IntentLabActionReceipt].self, from: Data(raw.utf8))[0]
        let duplicates = try serialized([receipt, receipt])
        let captured = try IntentLabScenarioEngine.captureDirectObservations(
            execute: { [:] },
            observe: { ["intentlab.actionReceipts": .string(duplicates)] },
            receiptContext: receipt.attemptContext, receiptLane: receipt.lane,
            receiptWaitSeconds: 0, receiptPollInterval: 0
        )
        // Capture must never filter records to the expected operation or deduplicate them.
        XCTAssertEqual(captured.stateObservations["intentlab.actionReceipts"], .string(duplicates))
    }

    func testDriverFailureWaitsForDelayedTerminalReceipt() throws {
        let raw = try serializedReceipt(status: .failed)
        let receipt = try JSONDecoder.intentLab.decode([IntentLabActionReceipt].self, from: Data(raw.utf8))[0]
        var reads = 0
        let captured = try IntentLabScenarioEngine.captureDirectObservations(
            execute: { throw RunnerTestError.driverFailed },
            observe: {
                reads += 1
                return ["intentlab.actionReceipts": .string(reads == 1 ? "[]" : raw)]
            },
            receiptContext: receipt.attemptContext, receiptLane: receipt.lane,
            receiptWaitSeconds: 0.5, receiptPollInterval: 0
        )
        XCTAssertEqual(reads, 2)
        XCTAssertNotNil(captured.driverError)
        XCTAssertTrue(IntentLabScenarioEngine.hasAttributableTerminalAction(
            captured.stateObservations, context: receipt.attemptContext, lane: receipt.lane
        ))
    }

    func testDriverFailureNeedsAnAttributableAppActionBeforeBusinessClassification() throws {
        let context = "intent-current"
        let missing = try IntentLabScenarioEngine.captureDirectObservations(
            execute: { throw RunnerTestError.driverFailed },
            observe: { ["selectedNoteID": .string("packing-001")] }
        )
        XCTAssertFalse(IntentLabScenarioEngine.hasAttributableTerminalAction(
            missing.stateObservations, context: context, lane: .intentIntegration
        ))

        let start = Date(timeIntervalSince1970: 10)
        let receipt = IntentLabActionReceipt(
            executionID: UUID(), appSessionID: UUID(), attemptContext: context,
            lane: .intentIntegration, attempt: 1, kind: .productionIntent,
            operationID: "OpenNoteIntent", resolvedParameters: [:],
            terminalStatus: .failed, operationError: "operation failed",
            sequence: 1, startedAt: start, completedAt: start.addingTimeInterval(1),
            observationTransport: "accessibleUI"
        )
        let raw = String(decoding: try JSONEncoder.intentLab.encode([receipt]), as: UTF8.self)
        let captured = try IntentLabScenarioEngine.captureDirectObservations(
            execute: { throw RunnerTestError.driverFailed },
            observe: { ["intentlab.actionReceipts": .string(raw)] }
        )
        XCTAssertTrue(IntentLabScenarioEngine.hasAttributableTerminalAction(
            captured.stateObservations, context: context, lane: .intentIntegration
        ))
        XCTAssertFalse(IntentLabScenarioEngine.hasAttributableTerminalAction(
            captured.stateObservations, context: "intent-previous", lane: .intentIntegration
        ))
    }

    func testSiriTerminalReceiptCorrelatesWithoutVisibleContextLabel() throws {
        let receiptValue = try serializedReceipt(status: .failed)
        let observations: [String: IntentLabValue] = [
            "intentlab.actionReceipts": .string(receiptValue)
        ]

        XCTAssertNotNil(SiriProbe.correlatedCompletion(
            observations: observations,
            expectedContext: "siri-current",
            integration: InertIntegration()
        ))
        XCTAssertNil(SiriProbe.correlatedCompletion(
            observations: observations,
            expectedContext: "siri-previous",
            integration: InertIntegration()
        ))
    }

    func testUnassistedSiriPollingObservesCompletionWithoutSelectingChooser() throws {
        let observations: [String: IntentLabValue] = [
            "intentlab.actionReceipts": .string(try serializedReceipt(status: .succeeded))
        ]
        var completionObservations: [String: IntentLabValue]?
        var observationReads = 0
        var chooserSelections = 0

        for _ in 0..<2 {
            SiriProbe.pollDuringActivation(
                permitsChooserAssistance: false,
                observeCompletion: {
                    observationReads += 1
                    // An earlier timer tick may see no terminal receipt yet.
                    let current = observationReads == 1 ? [:] : observations
                    completionObservations = SiriProbe.correlatedCompletion(
                        observations: current,
                        expectedContext: "siri-current",
                        integration: InertIntegration()
                    )
                },
                selectChooser: { chooserSelections += 1 }
            )
        }

        XCTAssertEqual(observationReads, 2)
        XCTAssertEqual(chooserSelections, 0)
        XCTAssertEqual(completionObservations, observations)
        XCTAssertTrue(SiriProbe.recoverableActivationTimeout(
            description: "Timed out waiting for Siri to activate",
            osMajor: 27,
            observations: completionObservations,
            expectedContext: "siri-current",
            integration: InertIntegration()
        ))
        XCTAssertFalse(SiriProbe.recoverableActivationTimeout(
            description: "Timed out waiting for the app to activate",
            osMajor: 27,
            observations: completionObservations,
            expectedContext: "siri-current",
            integration: InertIntegration()
        ))
        XCTAssertFalse(SiriProbe.recoverableActivationTimeout(
            description: "Timed out waiting for Siri to activate",
            osMajor: 28,
            observations: completionObservations,
            expectedContext: "siri-current",
            integration: InertIntegration()
        ))
    }

    func testUnassistedSiriPollingRejectsMissingOrUncorrelatedCompletion() throws {
        var stale = receipt(status: .succeeded)
        stale.attemptContext = "siri-previous"
        var wrongLane = receipt(status: .succeeded)
        wrongLane.lane = .intentIntegration
        var nested = receipt(status: .succeeded)
        nested.isTopLevel = false
        let invalidObservations: [[String: IntentLabValue]] = [
            [:],
            ["intentlab.actionReceipts": .string("[]")],
            ["intentlab.actionReceipts": .string("malformed")],
            ["intentlab.actionReceipts": .string(try serialized([stale]))],
            ["intentlab.actionReceipts": .string(try serialized([wrongLane]))],
            ["intentlab.actionReceipts": .string(try serialized([nested]))]
        ]

        for observations in invalidObservations {
            var completionObservations: [String: IntentLabValue]?
            var observationReads = 0
            var chooserSelections = 0
            SiriProbe.pollDuringActivation(
                permitsChooserAssistance: false,
                observeCompletion: {
                    observationReads += 1
                    completionObservations = SiriProbe.correlatedCompletion(
                        observations: observations,
                        expectedContext: "siri-current",
                        integration: InertIntegration()
                    )
                },
                selectChooser: { chooserSelections += 1 }
            )

            XCTAssertEqual(observationReads, 1)
            XCTAssertEqual(chooserSelections, 0)
            XCTAssertNil(completionObservations)
            XCTAssertFalse(SiriProbe.recoverableActivationTimeout(
                description: "Timed out waiting for Siri to activate",
                osMajor: 27,
                observations: completionObservations,
                expectedContext: "siri-current",
                integration: InertIntegration()
            ))
        }
    }

    func testCleanupFailureRetainsActionEvidenceAndMarksReadinessFalse() {
        let receipt = receipt(status: .failed)
        let lane = IntentLabLaneResult(
            caseID: UUID(), attempt: 1, lane: .siri,
            executionStatus: .completed, outcome: .failed,
            startedAt: receipt.startedAt, completedAt: receipt.completedAt,
            observations: ["selectedTaskID": .string("wrong-task")],
            assertionResults: [], diagnostic: "wrongAction",
            proposedCause: nil, artifacts: [], actionReceipts: [receipt],
            actionFailureReason: .wrongAction
        )

        let retained = IntentLabScenarioEngine.addingCleanupFailure(
            RunnerTestError.cleanupFailed,
            to: lane
        )

        XCTAssertEqual(retained.outcome, .failed)
        XCTAssertEqual(retained.observations["selectedTaskID"], .string("wrong-task"))
        XCTAssertEqual(retained.actionReceipts?.map(\.executionID), [receipt.executionID])
        XCTAssertEqual(retained.actionFailureReason, .wrongAction)
        XCTAssertEqual(retained.cleanupVerified, false)
        XCTAssertTrue(retained.diagnostic?.contains("wrongAction") == true)
        XCTAssertTrue(retained.diagnostic?.contains("Fixture cleanup failed") == true)
    }

    func testCleanupVerificationDistinguishesSuccessFailureAndSkippedCleanup() {
        XCTAssertEqual(IntentLabScenarioEngine.cleanupVerification(
            required: true, cleanupError: nil, cleanupWasSkipped: false
        ), true)
        XCTAssertEqual(IntentLabScenarioEngine.cleanupVerification(
            required: true, cleanupError: RunnerTestError.cleanupFailed, cleanupWasSkipped: false
        ), false)
        XCTAssertEqual(IntentLabScenarioEngine.cleanupVerification(
            required: true, cleanupError: nil, cleanupWasSkipped: true
        ), false)
        XCTAssertNil(IntentLabScenarioEngine.cleanupVerification(
            required: false, cleanupError: nil, cleanupWasSkipped: false
        ))
    }

    func testLocalFeatureInputMappingUsesDeclaredNamesAndTypes() throws {
        let parameter = try decodeFeatureParameter(name: "prompt", required: true)
        let mapping = [IntentLabFeatureBinding.InputMapping(
            featureInputName: "prompt", value: .string("Summarize the note")
        )]

        XCTAssertEqual(try IntentLabScenarioEngine.resolveFeatureParameters(
            mapping, against: [parameter]
        ), ["prompt": .string("Summarize the note")])
        XCTAssertThrowsError(try IntentLabScenarioEngine.resolveFeatureParameters(
            [.init(featureInputName: "unlisted", value: .string("value"))],
            against: [parameter]
        ))
        XCTAssertThrowsError(try IntentLabScenarioEngine.resolveFeatureParameters(
            [.init(featureInputName: "prompt", value: .integer(7))],
            against: [parameter]
        ))
        XCTAssertThrowsError(try IntentLabScenarioEngine.resolveFeatureParameters(
            [], against: [parameter]
        ))
    }

    func testLocalFeatureExecutorCannotSupplyAppOwnedActionReceipt() throws {
        let output = IntentLabOutputField(
            name: "summary",
            type: .primitive(.string),
            path: [.init(kind: .property, name: "value"), .init(kind: .property, name: "summary")]
        )
        let binding = IntentLabFeatureBinding(
            featureID: "notes.summarize",
            interfaceDigest: String(repeating: "a", count: 64),
            inputMapping: [],
            outputProjections: [output]
        )
        XCTAssertNoThrow(try IntentLabScenarioEngine.validateFeatureObservations(
            ["feature.response": .string("The note summary"), "summary": .string("concise")],
            binding: binding
        ))
        XCTAssertThrowsError(try IntentLabScenarioEngine.validateFeatureObservations(
            ["feature.response": .string("The note summary"), "summary": .integer(1)],
            binding: binding
        ))
        XCTAssertThrowsError(try IntentLabScenarioEngine.validateFeatureObservations(
            ["feature.response": .string("The note summary"),
             "intentlab.actionReceipts": .string("[]")],
            binding: binding
        ))
        XCTAssertThrowsError(try IntentLabScenarioEngine.validateFeatureObservations(
            ["summary": .string("concise")], binding: binding
        ))
        XCTAssertThrowsError(try IntentLabScenarioEngine.validateFeatureObservations(
            ["feature.response": .string("The note summary")], binding: binding
        ))
    }

    func testLocalFeatureRequiresEveryDeclaredProjectionFromTransport() throws {
        let binding = IntentLabFeatureBinding(
            featureID: "notes.summarize",
            interfaceDigest: String(repeating: "a", count: 64),
            inputMapping: [],
            outputProjections: [
                .init(
                    name: "summary",
                    type: .primitive(.string),
                    path: [.init(kind: .property, name: "value"), .init(kind: .property, name: "summary")]
                ),
                .init(
                    name: "characterCount",
                    type: .primitive(.integer),
                    path: [.init(kind: .property, name: "value"), .init(kind: .property, name: "characterCount")]
                )
            ]
        )

        XCTAssertThrowsError(try IntentLabScenarioEngine.validateFeatureObservations(
            ["feature.response": .string("The note summary"), "summary": .string("concise")],
            binding: binding
        ))
        XCTAssertNoThrow(try IntentLabScenarioEngine.validateFeatureObservations(
            [
                "feature.response": .string("The note summary"),
                "summary": .string("concise"),
                "characterCount": .integer(8)
            ],
            binding: binding
        ))
    }

    func testFeatureStateCollisionCannotOverwriteTransportOutputOrPass() throws {
        let context = "feature-collision"
        let featureObservations: [String: IntentLabValue] = [
            "feature.response": .string("typed response"),
            "summary": .string("typed projection")
        ]
        let serviceReceipt = IntentLabActionReceipt(
            executionID: UUID(), appSessionID: UUID(), attemptContext: context,
            lane: .appFeature, attempt: 1, kind: .productionService,
            operationID: "notes.summarize",
            resolvedParameters: ["prompt": .string("Summarize the note")],
            terminalStatus: .succeeded, operationError: nil,
            sequence: 1, startedAt: Date(timeIntervalSince1970: 20),
            completedAt: Date(timeIntervalSince1970: 21),
            observationTransport: "accessibleUI"
        )
        let appObservations: [String: IntentLabValue] = [
            "feature.response": .string("observer response"),
            "summary": .string("observer projection"),
            "intentlab.actionReceipts": .string(try serialized([serviceReceipt]))
        ]

        let merged = IntentLabScenarioEngine.mergeFeatureObservations(
            featureObservations: featureObservations,
            appObservations: appObservations
        )

        XCTAssertEqual(merged.collisions, ["feature.response", "summary"])
        XCTAssertEqual(merged.featureOutputKeys, Set(featureObservations.keys))
        XCTAssertEqual(merged.observations["feature.response"], .string("typed response"))
        XCTAssertEqual(merged.observations["summary"], .string("typed projection"))
        XCTAssertEqual(
            merged.observations["intentlab.actionReceipts"],
            appObservations["intentlab.actionReceipts"]
        )

        let requirement = IntentLabActionRequirement(
            lane: .appFeature, kind: .productionService,
            operationID: "notes.summarize",
            resolvedParameters: ["prompt": .string("Summarize the note")]
        )
        var scenario = try localFeatureScenario(requirement: requirement)
        scenario.assertions[0].expectedValue = .string("typed response")
        let lane = IntentLabScenarioEngine.result(
            for: .appFeature,
            scenario: scenario,
            observations: merged.observations,
            baseline: nil,
            integration: InertIntegration(),
            declaration: nil,
            context: context,
            startedAt: serviceReceipt.startedAt,
            resultKeysOverride: ["feature.response", "summary"],
            featureOutputKeys: merged.featureOutputKeys
        )
        XCTAssertEqual(lane.outcome, .passed)
        let rejected = IntentLabScenarioEngine.rejectingFeatureObservationCollisions(
            merged.collisions,
            in: lane
        )

        XCTAssertEqual(rejected.outcome, .failed)
        XCTAssertEqual(rejected.observationSources?["feature.response"], "testOnlyIntent")
        XCTAssertEqual(rejected.observationSources?["summary"], "testOnlyIntent")
        XCTAssertEqual(rejected.actionReceipts?.map(\.executionID), [serviceReceipt.executionID])
        XCTAssertTrue(rejected.diagnostic?.contains("App state reused local feature output keys") == true)
    }

    func testLocalFeatureEvidenceUsesAppOwnedProductionServiceReceipt() throws {
        let context = "feature-current"
        let start = Date(timeIntervalSince1970: 20)
        let requirement = IntentLabActionRequirement(
            lane: .appFeature, kind: .productionService,
            operationID: "notes.summarize",
            resolvedParameters: ["prompt": .string("Summarize the note")]
        )
        let receipt = IntentLabActionReceipt(
            executionID: UUID(), appSessionID: UUID(), attemptContext: context,
            lane: .appFeature, attempt: 1, kind: .productionService,
            operationID: "notes.summarize",
            resolvedParameters: requirement.resolvedParameters,
            terminalStatus: .succeeded, operationError: nil,
            sequence: 1, startedAt: start, completedAt: start.addingTimeInterval(1),
            observationTransport: "accessibleUI"
        )
        let lane = IntentLabScenarioEngine.result(
            for: .appFeature,
            scenario: try localFeatureScenario(requirement: requirement),
            observations: [
                "feature.response": .string("A concise summary"),
                "intentlab.actionReceipts": .string(try serialized([receipt]))
            ],
            baseline: nil,
            integration: InertIntegration(),
            declaration: nil,
            context: context,
            startedAt: start,
            resultKeysOverride: ["feature.response"],
            featureOutputKeys: ["feature.response"]
        )

        XCTAssertEqual(lane.outcome, .passed)
        XCTAssertEqual(lane.observationSources?["feature.response"], "testOnlyIntent")
        XCTAssertEqual(lane.actionReceipts?.first?.kind, .productionService)
        XCTAssertEqual(lane.actionReceipts?.first?.observationTransport, "accessibleUI")
        XCTAssertTrue(lane.claims?.contains(.returnedValueChecked) == true)
    }

    private func decodeFeatureParameter(
        name: String,
        required: Bool
    ) throws -> IntentLabIntegrationDeclaration.Parameter {
        let data = try JSONEncoder.intentLab.encode(EnvelopeShape(parameters: [
            .init(name: name, type: .primitive(.string), required: required)
        ]))
        return try XCTUnwrap(
            JSONDecoder.intentLab.decode(Envelope.self, from: data).parameters.first
        )
    }

    private struct EnvelopeShape: Codable {
        var parameters: [ParameterShape]
        struct ParameterShape: Codable {
            var name: String
            var type: IntentLabValueType
            var required: Bool
        }
    }

    private struct Envelope: Codable {
        var parameters: [IntentLabIntegrationDeclaration.Parameter]
    }

    private func localFeatureScenario(
        requirement: IntentLabActionRequirement
    ) throws -> IntentLabScenario {
        let json: [String: Any] = [
            "schemaVersion": 1,
            "id": UUID().uuidString,
            "version": 1,
            "definitionDigest": String(repeating: "a", count: 64),
            "target": ["bundleIdentifier": "com.example.IntentLab"],
            "goal": ["requestText": "Summarize a note", "languageCode": "en"],
            "fixture": [
                "id": "test", "version": "1", "digest": String(repeating: "b", count: 64),
                "preparationOperation": "prepare", "cleanupOperation": "cleanup"
            ],
            "directControl": ["intentIdentifier": "CompleteTask", "parameters": [], "outputFields": []],
            "assertions": [],
            "coverage": ["appFeature": "required", "intentIntegration": "notApplicable", "siri": "notApplicable"],
            "safety": ["deadlineSeconds": 5]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        var scenario = try JSONDecoder.intentLab.decode(IntentLabScenario.self, from: data)
        scenario.schemaVersion = 2
        scenario.requiredClaims = [.executionCompleted, .returnedValueChecked]
        scenario.executionScope = .init(lane: .appFeature, attempt: 1)
        scenario.assertions = [
            .init(
                id: UUID(), kind: .returnedField, observationKey: "feature.response",
                expectedValue: .string("A concise summary"), required: true,
                applicableLanes: [.appFeature]
            )
        ]
        scenario.actionRequirements = [requirement]
        return scenario
    }

    private func serialized(_ receipts: [IntentLabActionReceipt]) throws -> String {
        try XCTUnwrap(String(data: JSONEncoder.intentLab.encode(receipts), encoding: .utf8))
    }

    private func serializedReceipt(status: IntentLabActionTerminalStatus) throws -> String {
        let data = try JSONEncoder.intentLab.encode([receipt(status: status)])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func receipt(status: IntentLabActionTerminalStatus) -> IntentLabActionReceipt {
        let start = Date(timeIntervalSince1970: 10)
        return IntentLabActionReceipt(
            executionID: UUID(), appSessionID: UUID(), attemptContext: "siri-current",
            lane: .siri, attempt: 1, kind: .productionIntent,
            operationID: "CompleteTask", resolvedParameters: [:],
            terminalStatus: status, operationError: status == .failed ? "operation failed" : nil,
            sequence: 1, startedAt: start, completedAt: start.addingTimeInterval(1),
            observationTransport: "appIntentsTesting"
        )
    }

    private struct InertIntegration: IntentLabSiriIntegration {
        var supportedCapabilities: Set<String> { [] }
        var supportsMutatingChecks: Bool { true }

        func prepare(bundleIdentifier: String, context: String, operationID: String) throws -> XCUIApplication {
            XCTFail("This test does not launch the app")
            return XCUIApplication()
        }

        func cleanup(bundleIdentifier: String, context: String, operationID: String) throws {}
        func observe(application: XCUIApplication) throws -> [String: IntentLabValue] { [:] }
        func completed(observations: [String: IntentLabValue], context: String) -> Bool { false }
    }

    private enum RunnerTestError: LocalizedError {
        case driverFailed
        case cleanupFailed

        var errorDescription: String? {
            switch self {
            case .driverFailed: "Driver failure"
            case .cleanupFailed: "Cleanup failure"
            }
        }
    }
}
