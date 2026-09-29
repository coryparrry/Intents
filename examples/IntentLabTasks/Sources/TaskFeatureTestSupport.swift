#if DEBUG && INTENT_LAB_TEST_SUPPORT
import Foundation
import IntentLabContracts

@MainActor
final class TaskFeatureTestSupport: IntentLabFeatureTestSupport {
    static let shared = TaskFeatureTestSupport()

    static let featureID = "com.example.intent-lab-tasks"
    static let completionOperation = "complete-task"
    static let testIntentIdentifier = "IntentLabInvokeFeatureIntent"
    static let preparationOperation = "prepare-task-fixture"
    static let snapshotOperation = "snapshot-task-fixture"
    static let cleanupOperation = "cleanup-task-fixture"

    nonisolated let supportedOperationIDs: Set<String> = [
        "complete-task", "prepare-task-fixture", "snapshot-task-fixture", "cleanup-task-fixture"
    ]

    private static let parameters = [
        IntentLabIntegrationDeclaration.Parameter(
            name: "taskID", type: .primitive(.string), required: true
        )
    ]

    static let interfaceDigest: String = {
        do {
            return try IntentLabIntegrationDeclaration.FeatureControl.calculateInterfaceDigest(
                featureID: featureID,
                operationID: completionOperation,
                testIntentIdentifier: testIntentIdentifier,
                parameters: parameters,
                outputProjections: []
            )
        } catch {
            preconditionFailure("Unable to calculate the task feature interface digest: \(error.localizedDescription)")
        }
    }()

    private init() {}

    func prepare(operationID: String, context: String) async throws {
        guard operationID == Self.preparationOperation else {
            throw TaskFeatureTestSupportError.unsupportedOperation(operationID)
        }
        try Self.prepareDataset(faultValue: "none", context: context)
    }

    func invokeFeature(operationID: String, businessInput: String, context: String) async throws -> String {
        guard operationID == Self.completionOperation else {
            throw TaskFeatureTestSupportError.unsupportedOperation(operationID)
        }
        guard !context.isEmpty,
              businessInput.utf8.count <= 256 * 1_024,
              let inputData = businessInput.data(using: .utf8),
              let input = try? JSONDecoder.intentLab.decode(IntentLabLocalFeatureInput.self, from: inputData),
              input.featureID == Self.featureID,
              input.interfaceDigest == Self.interfaceDigest,
              input.parameters.count == 1,
              let parameter = input.parameters.first,
              parameter.name == "taskID",
              parameter.type == .primitive(.string),
              !parameter.isOptional,
              case .value(.string(let taskID)) = parameter.presence,
              !taskID.isEmpty else {
            throw TaskFeatureTestSupportError.invalidFeatureInput
        }

        let wrapperReceipt = TaskActionReceipts.begin(
            context: context,
            lane: .appFeature,
            kind: .testSupport,
            operationID: Self.testIntentIdentifier,
            resolvedParameters: ["taskID": .string(taskID)],
            isTopLevel: false
        )
        do {
            let result = try TaskCompletionService.shared.completeFromInvocation(
                taskID: taskID,
                expectedIntegrationContext: context,
                context: context,
                lane: .appFeature,
                kind: .productionService,
                operationID: Self.completionOperation
            )
            TaskActionReceipts.finish(wrapperReceipt)
            return result.response
        } catch {
            TaskActionReceipts.finish(wrapperReceipt, error: error)
            throw error
        }
    }

    func snapshot(operationID: String, context: String) async throws -> String {
        guard operationID == Self.snapshotOperation, !context.isEmpty else {
            throw TaskFeatureTestSupportError.unsupportedOperation(operationID)
        }
        guard TaskRepository.shared.integrationContextForEntity == context else {
            throw TaskFeatureTestSupportError.staleSnapshotContext
        }
        let tasks = try TaskRepository.shared.tasks().map { task in
            [
                "id": task.id,
                "title": task.title,
                "isComplete": task.isComplete,
                "invocationContext": task.invocationContext,
                "actionReceiptID": task.actionReceiptID,
                "actionReceipts": TaskActionReceipts.json
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: tasks, options: [.sortedKeys])
        guard let snapshot = String(data: data, encoding: .utf8) else {
            throw TaskFeatureTestSupportError.invalidSnapshot
        }
        return snapshot
    }

    func cleanup(operationID: String, context: String) async throws {
        guard operationID == Self.cleanupOperation else {
            throw TaskFeatureTestSupportError.unsupportedOperation(operationID)
        }
        try Self.prepareDataset(faultValue: "none", context: context)
    }

    static func prepareForLaunch(faultValue: String, context: String) throws {
        try prepareDataset(faultValue: faultValue, context: context)
    }

    private static func prepareDataset(faultValue: String, context: String) throws {
        guard !context.isEmpty else { throw TaskFeatureTestSupportError.emptyContext }
        try TaskRepository.shared.prepareIntegrationDataset(faultValue: faultValue, context: context)
    }
}

private enum TaskFeatureTestSupportError: LocalizedError {
    case emptyContext
    case invalidFeatureInput
    case invalidSnapshot
    case staleSnapshotContext
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .emptyContext: "Task test support requires an invocation context."
        case .invalidFeatureInput: "The task feature input does not match its declared typed interface."
        case .invalidSnapshot: "The task snapshot could not be encoded."
        case .staleSnapshotContext: "The task snapshot request does not match the prepared invocation context."
        case .unsupportedOperation(let operationID): "The task app does not support test operation \(operationID)."
        }
    }
}
#endif
