import Foundation
import IntentLabContracts
import IntentLabTesting
import XCTest

@available(iOS 27.0, *)
@MainActor
final class TaskIntegration: IntentLabIntegration {
    static let testingBundleIdentifier = "com.example.IntentLabTasks.integration-tests"
    static let preparationOperation = "prepare-task-fixture"
    static let cleanupOperation = "cleanup-task-fixture"
    static let capabilities: Set<String> = [
        "environment-payload",
        "direct-intent-execution",
        "direct-intent-output",
        "preparation",
        "entity-query",
        "siri",
        "siri-completion",
        "invocation-correlation",
        "local-feature-controls",
        "test-only-intent"
    ]

    private let faultMode: String
    private let forceCleanupFailure: Bool
    private(set) var completedCleanups = 0
    private var activeBundleIdentifier: String?
    private var activeContext: String?
    private var baselineReceiptByContext: [String: String] = [:]

    init(faultMode: String = "none", forceCleanupFailure: Bool = false) {
        self.faultMode = faultMode
        self.forceCleanupFailure = forceCleanupFailure
    }

    var supportedCapabilities: Set<String> { Self.capabilities }

    func prepare(bundleIdentifier: String, context: String, operationID: String) throws -> XCUIApplication {
        guard bundleIdentifier == Self.testingBundleIdentifier else {
            throw TaskIntegrationError.unsupportedBundle(bundleIdentifier)
        }
        guard operationID == Self.preparationOperation else {
            throw TaskIntegrationError.unsupportedOperation(operationID)
        }
        guard !context.isEmpty else { throw TaskIntegrationError.emptyContext }

        let application = XCUIApplication(bundleIdentifier: bundleIdentifier)
        if application.state != .notRunning {
            application.terminate()
        }
        application.launchArguments = [
            "-intent-lab-reset", "YES",
            "-intent-lab-fault", faultMode,
            "-intent-lab-context", context
        ]
        application.launch()

        guard application.navigationBars["Tasks"].waitForExistence(timeout: 20) else {
            throw TaskIntegrationError.appDidNotLaunch
        }
        guard waitForIncompleteTask(application, identifier: "task-001"),
              waitForIncompleteTask(application, identifier: "task-002") else {
            throw TaskIntegrationError.invalidPreparedDataset
        }

        activeBundleIdentifier = bundleIdentifier
        activeContext = context
        // Dataset seeding clears all prior action receipts. The runner takes its
        // own declaration-backed baseline observation after prepare returns.
        baselineReceiptByContext[context] = ""
        return application
    }

    func cleanup(bundleIdentifier: String, context: String, operationID: String) throws {
        guard operationID == Self.cleanupOperation else {
            throw IntentLabIntegrationError.unsupportedCleanup(operationID)
        }
        if forceCleanupFailure { throw TaskIntegrationError.forcedCleanupFailure }
        // Re-seed through the consumer's test-only launch path, then verify
        // persisted state through the independent entity query.
        let application = try prepare(
            bundleIdentifier: bundleIdentifier,
            context: context,
            operationID: Self.preparationOperation
        )
        defer { application.terminate() }
        let state = try readTaskObservations()
        guard state["task-001.isComplete"] == .boolean(false),
              state["task-002.isComplete"] == .boolean(false),
              state["actionReceiptID"] == .string("") else {
            throw TaskIntegrationError.invalidCleanedDataset
        }
        completedCleanups += 1
    }

    func observe(application: XCUIApplication) throws -> [String: IntentLabValue] {
        guard application.state != .notRunning else { throw TaskIntegrationError.appDidNotLaunch }
        return [:]
    }

    func observeTasks() throws -> [String: IntentLabValue] {
        try readTaskObservations()
    }

    func completed(observations: [String: IntentLabValue], context: String) -> Bool {
        guard activeContext == context,
              observations["invocationContext"] == .string(context),
              let receipt = try? requiredString("actionReceiptID", from: observations),
              !receipt.isEmpty,
              baselineReceiptByContext[context] != receipt else {
            return false
        }
        return true
    }

    func source(for observationKey: String) -> String {
        let queryObservations: Set<String> = [
            "task-001.id", "task-001.title", "task-001.isComplete",
            "task-002.id", "task-002.title", "task-002.isComplete",
            "invocationContext", "actionReceiptID", "intentlab.actionReceipts"
        ]
        return queryObservations.contains(observationKey) ? "entityQuery" : "accessibleUI"
    }

    private func readTaskObservations() throws -> [String: IntentLabValue] {
        guard let bundleIdentifier = activeBundleIdentifier else { throw TaskIntegrationError.notPrepared }
        let declarationURL = try Self.declarationURL()
        let declaration = try JSONDecoder.intentLab.decode(
            IntentLabIntegrationDeclaration.self,
            from: Data(contentsOf: declarationURL)
        )
        return try IntentLabQueryObserver.observe(
            bundleIdentifier: bundleIdentifier,
            declaration: declaration,
            deadlineSeconds: 20
        )
    }

    private func waitForIncompleteTask(_ application: XCUIApplication, identifier: String) -> Bool {
        let status = application.staticTexts["task-status-\(identifier)"]
        return status.waitForExistence(timeout: 10) && status.label == "Incomplete"
    }

    private static func declarationURL() throws -> URL {
        guard let url = Bundle(for: TaskIntegration.self).url(
            forResource: "IntentLabIntegration",
            withExtension: "json"
        ) else {
            throw TaskIntegrationError.missingDeclaration
        }
        return url
    }

    private func requiredString(_ key: String, from observations: [String: IntentLabValue]) throws -> String {
        guard case .string(let value)? = observations[key] else {
            throw TaskIntegrationError.missingObservation(key)
        }
        return value
    }
}

private enum TaskIntegrationError: LocalizedError {
    case unsupportedBundle(String)
    case unsupportedOperation(String)
    case emptyContext
    case appDidNotLaunch
    case invalidPreparedDataset
    case invalidCleanedDataset
    case forcedCleanupFailure
    case notPrepared
    case missingDeclaration
    case missingObservation(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedBundle(let value): "Task integration refuses non-test bundle \(value)."
        case .unsupportedOperation(let value): "The task adapter does not allow preparation operation \(value)."
        case .emptyContext: "Task preparation requires a fresh invocation context."
        case .appDidNotLaunch: "The isolated task app did not reach its task list."
        case .invalidPreparedDataset: "Task preparation did not restore both expected incomplete records."
        case .invalidCleanedDataset: "Task cleanup did not restore the persisted incomplete records and empty receipt."
        case .forcedCleanupFailure: "The injected task fixture cleanup failure fired."
        case .notPrepared: "Prepare the task integration before querying app state."
        case .missingDeclaration: "The UI-test bundle is missing IntentLabIntegration.json."
        case .missingObservation(let key): "Task query did not return required observation \(key)."
        }
    }
}
