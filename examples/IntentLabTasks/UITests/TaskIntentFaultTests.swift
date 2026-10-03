import AppIntentsTesting
import IntentLabContracts
import XCTest

@available(iOS 27.0, *)
@MainActor
final class TaskIntentFaultTests: XCTestCase {
    func testSuccessfulReturnCannotProvePersistenceWhenStoreSaveIsSuppressed() async throws {
        let integration = TaskIntegration(faultMode: "suppressPersistence")
        let context = "suppressed-\(UUID().uuidString)"
        let application = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context,
            operationID: TaskIntegration.preparationOperation
        )
        defer { application.terminate() }

        let response = try await awaitContextMutation(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context
        )
        XCTAssertTrue(response.contains("Buy milk"), "The injected persistence defect should preserve a plausible intent response.")

        let status = try readStatusesAfterReopen(application)
        XCTAssertEqual(status["task-001"], "Incomplete")
        XCTAssertEqual(status["task-002"], "Incomplete")
    }

    func testUnrelatedTaskMutationRemainsVisibleAfterSuccessfulCompletion() async throws {
        let integration = TaskIntegration(faultMode: "mutateUnrelatedTask")
        let context = "unrelated-\(UUID().uuidString)"
        let application = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context,
            operationID: TaskIntegration.preparationOperation
        )
        defer { application.terminate() }

        let response = try await awaitContextMutation(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context
        )
        XCTAssertTrue(response.contains("Buy milk"))
        let status = try readStatusesAfterReopen(application)
        XCTAssertEqual(status["task-001"], "Complete")
        XCTAssertEqual(status["task-002"], "Complete")
    }

    func testCorrectActionProducesFreshContextBoundReceiptAndLeavesOtherTaskAlone() async throws {
        let integration = TaskIntegration()
        let context = "correct-\(UUID().uuidString)"
        let application = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context,
            operationID: TaskIntegration.preparationOperation
        )
        defer { application.terminate() }

        let response = try await awaitContextMutation(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context
        )
        XCTAssertTrue(response.contains("Buy milk"))
        let status = try readStatusesAfterReopen(application)
        XCTAssertEqual(status["task-001"], "Complete")
        XCTAssertEqual(status["task-002"], "Incomplete")
    }

    func testReceiptFromAnEarlierAttemptCannotCompleteCurrentAttempt() async throws {
        let integration = TaskIntegration()
        let firstContext = "old-\(UUID().uuidString)"
        let firstApp = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: firstContext,
            operationID: TaskIntegration.preparationOperation
        )
        _ = try await awaitContextMutation(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: firstContext
        )
        firstApp.terminate()

        let currentContext = "current-\(UUID().uuidString)"
        let currentApp = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: currentContext,
            operationID: TaskIntegration.preparationOperation
        )
        defer { currentApp.terminate() }

        XCTAssertFalse(integration.completed(observations: [
            "invocationContext": .string(firstContext),
            "actionReceiptID": .string(UUID().uuidString)
        ], context: currentContext))
    }

    func testEarlierAttemptContextCannotMutateResetStore() async throws {
        let integration = TaskIntegration()
        let oldContext = "entity-old-\(UUID().uuidString)"
        let oldApp = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: oldContext,
            operationID: TaskIntegration.preparationOperation
        )
        oldApp.terminate()

        let currentContext = "entity-current-\(UUID().uuidString)"
        let currentApp = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: currentContext,
            operationID: TaskIntegration.preparationOperation
        )
        defer { currentApp.terminate() }

        var oldContextWasRejected = false
        do {
            _ = try await awaitContextMutation(
                bundleIdentifier: TaskIntegration.testingBundleIdentifier,
                context: oldContext
            )
        } catch {
            oldContextWasRejected = true
        }
        XCTAssertTrue(oldContextWasRejected, "An earlier invocation context must not complete a newly prepared store.")
        let status = try readStatusesAfterReopen(currentApp)
        XCTAssertEqual(status["task-001"], "Incomplete")
        XCTAssertEqual(status["task-002"], "Incomplete")
    }

    func testUnboundShortcutEntityCannotMutateResetIntegrationStore() async throws {
        let integration = TaskIntegration()
        let oldContext = "shortcut-old-\(UUID().uuidString)"
        let oldApp = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: oldContext,
            operationID: TaskIntegration.preparationOperation
        )
        oldApp.terminate()

        let currentContext = "shortcut-current-\(UUID().uuidString)"
        let currentApp = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: currentContext,
            operationID: TaskIntegration.preparationOperation
        )
        defer { currentApp.terminate() }

        // A serialized shortcut may replay an entity without a context token.
        // Empty must not be interpreted as a wildcard for the active attempt.
        var unboundContextWasRejected = false
        do {
            _ = try await awaitContextMutation(
                bundleIdentifier: TaskIntegration.testingBundleIdentifier,
                context: ""
            )
        } catch {
            unboundContextWasRejected = true
        }
        XCTAssertTrue(unboundContextWasRejected, "An unbound shortcut entity must not act on a newly reset store.")
        let status = try readStatusesAfterReopen(currentApp)
        XCTAssertEqual(status["task-001"], "Incomplete")
        XCTAssertEqual(status["task-002"], "Incomplete")
    }

    func testCurrentContextAllowsIntentAndPersistsAfterReopen() async throws {
        let integration = TaskIntegration()
        let context = "shortcut-resolved-\(UUID().uuidString)"
        let application = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context,
            operationID: TaskIntegration.preparationOperation
        )
        defer { application.terminate() }

        let response = try await awaitContextMutation(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context
        )
        XCTAssertTrue(response.contains("Buy milk"))
        let status = try readStatusesAfterReopen(application)
        XCTAssertEqual(status["task-001"], "Complete")
        XCTAssertEqual(status["task-002"], "Incomplete")
    }

    private func awaitContextMutation(bundleIdentifier: String, context: String) async throws -> String {
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)
        var intent = definitions.intents["AttemptContextTaskMutationTestIntent"].makeIntent()
        intent[dynamicMember: "expectedIntegrationContext"] = context
        let result = try await intent.run()
        return try result.value
    }

    private func readStatusesAfterReopen(_ application: XCUIApplication) throws -> [String: String] {
        application.terminate()
        let reopened = XCUIApplication(bundleIdentifier: TaskIntegration.testingBundleIdentifier)
        reopened.launch()
        defer { reopened.terminate() }
        XCTAssertTrue(reopened.navigationBars["Tasks"].waitForExistence(timeout: 20))

        var statuses: [String: String] = [:]
        for identifier in ["task-001", "task-002"] {
            let status = reopened.staticTexts["task-status-\(identifier)"]
            XCTAssertTrue(status.waitForExistence(timeout: 10), "Task status \(identifier) should appear after reopening the persistent store.")
            statuses[identifier] = status.label
        }
        return statuses
    }

}
