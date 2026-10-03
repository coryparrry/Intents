import AppIntents
import CryptoKit
import Foundation
import IntentLabContracts

struct FixtureTestSnapshot: Codable {
    var selectedNoteID: String
    var noteStoreMutationCount: Int
    var invocationContext: String
    var applicationEvent: String
    var fixtureDigests: [String]
    var fixtureDigest: String?
    var summary: FixtureSummaryReceipt?
    var actionReceipts: [IntentLabActionReceipt]
}

struct FixtureFeatureOutput: Codable, Sendable {
    var response: String
}

struct FixtureReadinessOutput: Sendable {
    var ready: Bool
    var context: String
}

/// The fixture's single app-owned seam for test setup, feature invocation,
/// snapshots, cleanup, and action evidence. Operation names are an explicit
/// registry; payload text never selects an implementation dynamically.
enum FixtureTestSupport {
    static let featureID = "intent-lab.summarize-note"
    static let summaryOperationID = "summarizeNote"
    static let featureTestIntentIdentifier = "IntentLabInvokeFeatureIntent"

    // Canonical interface digest input, once encoded by FeatureControl's
    // calculateInterfaceDigest helper:
    //   featureID: intent-lab.summarize-note
    //   operationID: summarizeNote
    //   testIntentIdentifier: IntentLabInvokeFeatureIntent
    //   parameter: prompt (required string)
    //   outputProjections: [] (feature.response is the reserved value.response)
    static let featureInterfaceDigest: String = {
        do {
            return try IntentLabIntegrationDeclaration.FeatureControl.calculateInterfaceDigest(
                featureID: featureID,
                operationID: summaryOperationID,
                testIntentIdentifier: featureTestIntentIdentifier,
                parameters: [
                    .init(name: "prompt", type: .primitive(.string), required: true)
                ],
                outputProjections: []
            )
        } catch {
            preconditionFailure("The Notes feature interface could not be encoded: \(error.localizedDescription)")
        }
    }()

    private static let preparationOperations: Set<String> = ["", "reset", "resetNotes", "resetFixture"]
    private static let cleanupOperations: Set<String> = ["", "reset", "resetNotes", "resetFixture"]

    private static let featureOperations: [String: FeatureOperation] = [
        summaryOperationID: .summarizeNote
    ]

    private enum FeatureOperation {
        case summarizeNote
    }

    static func prepare(operationID: String, context: String) throws -> FixtureTestSnapshot {
        guard preparationOperations.contains(operationID) else {
            throw FixtureTestSupportError.unsupportedPreparation(operationID)
        }
        FixtureState.reset()
        FixtureState.begin(context: context)
        return snapshot()
    }

    static func cleanup(operationID: String, context: String) throws -> FixtureTestSnapshot {
        guard cleanupOperations.contains(operationID) else {
            throw FixtureTestSupportError.unsupportedCleanup(operationID)
        }
        FixtureState.reset()
        FixtureState.begin(context: context)
        return snapshot()
    }

    static func snapshot() -> FixtureTestSnapshot {
        let defaults = UserDefaults.standard
        let selectedNoteID = defaults.string(forKey: FixtureState.selectedNoteKey) ?? "none"
        let receiptData = defaults.data(forKey: FixtureState.summaryReceiptKey)
        let actionReceipts = FixtureState.validatedActionReceipts(
            from: defaults.data(forKey: FixtureState.actionReceiptsKey)
        )
        return FixtureTestSnapshot(
            selectedNoteID: selectedNoteID,
            noteStoreMutationCount: defaults.integer(forKey: FixtureState.mutationCountKey),
            invocationContext: defaults.string(forKey: FixtureState.observedContextKey) ?? "none",
            applicationEvent: defaults.string(forKey: FixtureState.eventKey) ?? "none",
            fixtureDigests: FixtureNotes.all.map(FixtureNotes.contentDigest).sorted(),
            fixtureDigest: FixtureNotes.note(id: selectedNoteID).map(FixtureNotes.contentDigest),
            summary: receiptData.flatMap { try? JSONDecoder().decode(FixtureSummaryReceipt.self, from: $0) },
            actionReceipts: actionReceipts
        )
    }

    static func snapshotJSON() -> String {
        guard let data = try? JSONEncoder.intentLab.encode(snapshot()),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    static func readiness(context: String) throws -> FixtureReadinessOutput {
        guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FixtureTestSupportError.invalidReadinessContext
        }
        return FixtureReadinessOutput(ready: true, context: context)
    }

    static func beginProductionService(
        note: FixtureNote,
        resolvedParameters: [String: IntentLabValue]
    ) -> FixtureIntentActionStart? {
        FixtureState.beginProductionService(
            operationID: summaryOperationID,
            noteID: note.id,
            resolvedParameters: resolvedParameters
        )
    }

    static func finishProductionService(_ action: FixtureIntentActionStart?, error: Error? = nil) {
        FixtureState.finishProductionIntent(action, error: error)
    }

    static func invokeFeature(
        operationID: String,
        businessInput: String,
        context: String
    ) async throws -> FixtureFeatureOutput {
        guard let operation = featureOperations[operationID] else {
            throw FixtureTestSupportError.unsupportedFeature(operationID)
        }
        let bytes = Data(businessInput.utf8)
        guard bytes.count <= 256 * 1_024,
              let input = try? JSONDecoder.intentLab.decode(IntentLabLocalFeatureInput.self, from: bytes),
              input.featureID == featureID,
              input.interfaceDigest == featureInterfaceDigest,
              input.parameters.count == 1,
              let promptParameter = input.parameters.first,
              promptParameter.name == "prompt",
              promptParameter.type == .primitive(.string),
              !promptParameter.isOptional,
              case .value(.string(let prompt)) = promptParameter.presence else {
            throw FixtureTestSupportError.invalidFeatureInput
        }

        FixtureState.begin(context: context)
        let testSupportAction = FixtureState.beginTestSupport(
            operationID: featureTestIntentIdentifier,
            resolvedParameters: ["prompt": .string(prompt)]
        )
        do {
            let output = try await FixtureActionContext.$parentKind.withValue(IntentLabActionKind.testSupport.rawValue) {
                switch operation {
                case .summarizeNote:
                    let note = try FixtureNotes.resolve(prompt: prompt)
                    FixtureState.beginSummaryAttempt(noteID: note.id)
                    let summary = try await SummaryService.summarize(
                        note,
                        resolvedParameters: ["prompt": .string(prompt)]
                    )
                    _ = try FixtureState.publishSummary(summary, for: note, route: "AppFeature")
                    return FixtureFeatureOutput(response: summary)
                }
            }
            FixtureState.finishProductionIntent(testSupportAction)
            return output
        } catch {
            FixtureState.finishProductionIntent(testSupportAction, error: error)
            throw error
        }
    }
}

enum FixtureTestSupportError: LocalizedError {
    case unsupportedPreparation(String)
    case unsupportedCleanup(String)
    case unsupportedFeature(String)
    case invalidFeatureInput
    case invalidReadinessContext

    var errorDescription: String? {
        switch self {
        case .unsupportedPreparation(let operationID): "The Notes fixture does not provide preparation operation \(operationID)."
        case .unsupportedCleanup(let operationID): "The Notes fixture does not provide cleanup operation \(operationID)."
        case .unsupportedFeature(let operationID): "The Notes fixture does not provide feature operation \(operationID)."
        case .invalidFeatureInput: "The local feature input does not match the Notes fixture's typed interface."
        case .invalidReadinessContext: "The Notes fixture readiness check requires a non-empty context."
        }
    }
}

enum FixtureActionContext {
    @TaskLocal static var parentKind: String?
}

#if DEBUG && INTENT_LAB_TEST_SUPPORT
@available(iOS 27.0, *)
struct IntentLabPrepareFixture: AppIntent {
    static let title: LocalizedStringResource = "Prepare Intent Lab fixture"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @Parameter(title: "Operation") var operationID: String
    @Parameter(title: "Context") var context: String

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let snapshot = try FixtureTestSupport.prepare(operationID: operationID, context: context)
        return .result(value: snapshot.selectedNoteID)
    }
}

@available(iOS 27.0, *)
struct IntentLabInvokeFeatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Invoke Intent Lab feature"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @Parameter(title: "Operation") var operationID: String
    @Parameter(title: "Business input") var businessInput: String
    @Parameter(title: "Context") var context: String

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<IntentLabFeatureTestResult> {
        let output = try await FixtureTestSupport.invokeFeature(
            operationID: operationID,
            businessInput: businessInput,
            context: context
        )
        return .result(value: IntentLabFeatureTestResult(response: output.response))
    }
}

@available(iOS 27.0, *)
struct IntentLabReadSnapshot: AppIntent {
    static let title: LocalizedStringResource = "Read Intent Lab fixture snapshot"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @Parameter(title: "Operation") var operationID: String

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard operationID == "readSnapshot" else {
            throw FixtureTestSupportError.unsupportedFeature(operationID)
        }
        return .result(value: FixtureTestSupport.snapshotJSON())
    }
}

@available(iOS 27.0, *)
struct IntentLabResetFixture: AppIntent {
    static let title: LocalizedStringResource = "Reset Intent Lab fixture"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @Parameter(title: "Operation") var operationID: String
    @Parameter(title: "Context") var context: String

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let snapshot = try FixtureTestSupport.cleanup(operationID: operationID, context: context)
        return .result(value: snapshot.selectedNoteID)
    }
}

@available(iOS 27.0, *)
struct IntentLabReadinessIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Intent Lab app readiness"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @Parameter(title: "Intent Lab context") var context: String

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<IntentLabReadinessTestResult> {
        let readiness = try FixtureTestSupport.readiness(context: context)
        return .result(value: IntentLabReadinessTestResult(
            ready: readiness.ready,
            context: readiness.context
        ))
    }
}

@available(iOS 27.0, *)
struct IntentLabFeatureTestResult: AppEntity, Identifiable {
    var id: String { response }
    @Property(title: "Response") var response: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Intent Lab feature response"
    static let defaultQuery = IntentLabFeatureTestResultQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(response)") }

    init(response: String) { self.response = response }
}

@available(iOS 27.0, *)
struct IntentLabFeatureTestResultQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [IntentLabFeatureTestResult] { [] }
}

@available(iOS 27.0, *)
struct IntentLabReadinessTestResult: AppEntity, Identifiable {
    var id: String { context }
    @Property(title: "Ready") var ready: Bool
    @Property(title: "Context") var context: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Intent Lab app readiness"
    static let defaultQuery = IntentLabReadinessTestResultQuery()
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: ready ? "Ready" : "Not ready")
    }

    init(ready: Bool, context: String) {
        self.ready = ready
        self.context = context
    }
}

@available(iOS 27.0, *)
struct IntentLabReadinessTestResultQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [IntentLabReadinessTestResult] { [] }
}
#endif
