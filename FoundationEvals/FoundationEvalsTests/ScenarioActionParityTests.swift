import Foundation
#if SWIFT_PACKAGE
import IntentLabContracts
import Testing
@testable import FoundationEvals

struct ScenarioActionParityTests {
    @Test func hostAndDeviceApplyTheSameStrictActionPolicy() throws {
        var definition = ScenarioDefinition.starter()
        let requirement = ScenarioActionRequirement(
            lane: .siri, kind: .productionIntent, operationID: "SummarizeNoteIntent",
            resolvedParameters: ["note": .entity(.init(typeIdentifier: "NoteEntity", identifier: "packing-001"))]
        )
        definition.actionRequirements = [requirement]
        definition.actionPolicyVersion = 1
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: Date(timeIntervalSince1970: 10),
            testIdentity: .init(bundleIdentifier: "example.tests", className: "ScenarioTests", methodName: "testScenario"),
            harnessVersion: ScenarioInvocationIdentity.reusableHarnessVersion,
            destinationIdentifier: "device", scenarioDigest: "frozen", resultBundleIdentity: "bundle",
            appProduct: nil, testProduct: nil
        )
        let context = "siri-\(invocation.id.uuidString)-1"
        let session = UUID()
        let start = Date(timeIntervalSince1970: 10)
        let correct = ScenarioActionReceipt(
            executionID: UUID(), appSessionID: session, attemptContext: context,
            lane: .siri, attempt: 1, kind: .productionIntent,
            operationID: requirement.operationID,
            resolvedParameters: requirement.resolvedParameters,
            terminalStatus: .succeeded, operationError: nil,
            sequence: 1, startedAt: start, completedAt: start.addingTimeInterval(1),
            observationTransport: .accessibleUI
        )
        var wrongAction = correct
        wrongAction.operationID = "OpenNoteIntent"
        var wrongParameter = correct
        wrongParameter.resolvedParameters = [
            "note": .entity(.init(typeIdentifier: "NoteEntity", identifier: "packing-002"))
        ]
        var stale = correct
        stale.attemptContext = "siri-prior-1"
        var wrongAttempt = correct
        wrongAttempt.attempt = 2
        var operationError = correct
        operationError.terminalStatus = .failed
        operationError.operationError = "source unavailable"
        var contradiction = correct
        contradiction.operationError = "source unavailable"
        var emptyError = correct
        emptyError.terminalStatus = .failed
        var extra = correct
        extra.executionID = UUID()
        extra.sequence = 2
        var extraAfterRestart = extra
        extraAfterRestart.appSessionID = UUID()
        var replay = correct
        replay.sequence = 2
        var nested = correct
        nested.executionID = UUID()
        nested.sequence = 2
        nested.kind = .testSupport
        nested.operationID = "ReadSnapshot"
        nested.isTopLevel = false
        var otherSession = nested
        otherSession.appSessionID = UUID()
        var duplicateSequence = nested
        duplicateSequence.sequence = 1
        var invalidTime = correct
        invalidTime.completedAt = start.addingTimeInterval(-1)
        var supportAsTopLevel = correct
        supportAsTopLevel.kind = .testSupport

        let vectors: [(String, [ScenarioActionReceipt]?, ScenarioOutcome, ScenarioActionFailureReason?)] = [
            ("missing", nil, .notObserved, .missingActionEvidence),
            ("correct", [correct], .passed, nil),
            ("wrong action", [wrongAction], .failed, .wrongAction),
            ("wrong entity", [wrongParameter], .failed, .wrongParameter),
            ("stale context", [stale], .notObserved, .staleActionEvidence),
            ("wrong attempt", [wrongAttempt], .notObserved, .staleActionEvidence),
            ("terminal error", [operationError], .failed, .operationError),
            ("success with error", [contradiction], .notObserved, .invalidActionEvidence),
            ("failure without error", [emptyError], .notObserved, .invalidActionEvidence),
            ("extra execution", [correct, extra], .failed, .unexpectedExecution),
            ("extra execution after restart", [correct, extraAfterRestart], .failed, .unexpectedExecution),
            ("replayed ID", [correct, replay], .notObserved, .invalidActionEvidence),
            ("valid nested support", [correct, nested], .passed, nil),
            ("cross session", [correct, otherSession], .notObserved, .invalidActionEvidence),
            ("duplicate sequence", [correct, duplicateSequence], .notObserved, .invalidActionEvidence),
            ("support as top level", [supportAsTopLevel], .notObserved, .invalidActionEvidence),
            ("reverse timestamps", [invalidTime], .notObserved, .invalidActionEvidence),
            ("no business action", [nested], .notObserved, .missingActionEvidence)
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let wireRequirement = try decoder.decode(
            IntentLabActionRequirement.self, from: encoder.encode(requirement)
        )
        for (name, receipts, expectedOutcome, expectedReason) in vectors {
            let host = ScenarioResultEvaluator.actionVerdict(
                definition: definition, lane: .siri, attempt: 1,
                invocation: invocation, receipts: receipts
            )
            let wireReceipts = try receipts.map {
                try decoder.decode([IntentLabActionReceipt].self, from: encoder.encode($0))
            }
            let device = IntentLabAssertionEvaluator.actionVerdict(
                requirement: wireRequirement, receipts: wireReceipts,
                lane: .siri, attempt: 1, context: context
            )
            #expect(host.0 == expectedOutcome, "\(name) host outcome")
            #expect(host.1 == expectedReason, "\(name) host reason")
            #expect(device.0.rawValue == host.0.rawValue, "\(name) route outcome parity")
            #expect(device.1?.rawValue == host.1?.rawValue, "\(name) route reason parity")
        }
        let correctHost = ScenarioResultEvaluator.actionVerdict(
            definition: definition, lane: .siri, attempt: 1,
            invocation: invocation, receipts: [correct]
        )
        let correctDevice = IntentLabAssertionEvaluator.actionVerdict(
            requirement: wireRequirement,
            receipts: try decoder.decode([IntentLabActionReceipt].self, from: encoder.encode([correct])),
            lane: .siri, attempt: 1, context: context
        )
        #expect(ScenarioResultEvaluator.failureReason(
            action: correctHost, deterministicFailure: true
        ) == .wrongOutcome)
        #expect(IntentLabAssertionEvaluator.failureReason(
            action: correctDevice, deterministicFailure: true
        ) == .wrongOutcome)
    }
}
#endif
