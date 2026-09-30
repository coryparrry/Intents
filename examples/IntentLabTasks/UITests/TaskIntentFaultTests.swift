import AppIntentsTesting
import IntentLabContracts
import IntentLabTesting
import XCTest

@available(iOS 27.0, *)
@MainActor
final class TaskIntentFaultTests: XCTestCase {
    func testLocalFeatureControlUsesProductionTaskServiceAndRecordsServiceReceipt() async throws {
        let integration = TaskIntegration()
        let context = "feature-\(UUID().uuidString)"
        let application = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context,
            operationID: TaskIntegration.preparationOperation
        )
        defer { application.terminate() }

        let declarationURL = try XCTUnwrap(
            Bundle(for: TaskIntegration.self).url(forResource: "IntentLabIntegration", withExtension: "json")
        )
        let declaration = try JSONDecoder.intentLab.decode(
            IntentLabIntegrationDeclaration.self,
            from: Data(contentsOf: declarationURL)
        )
        try declaration.validate()
        XCTAssertTrue(declaration.capabilities.contains("local-feature-controls"))
        XCTAssertTrue(declaration.capabilities.contains("test-only-intent"))
        let digest = "caeb9a954c99c4e035ec5d94bd8892622bb0676d24541dfedecae3d42096937d"
        let control = try declaration.localFeatureControl(
            featureID: "com.example.intent-lab-tasks",
            interfaceDigest: digest,
            operationID: "complete-task"
        )
        XCTAssertEqual(control.testIntentIdentifier, "IntentLabInvokeFeatureIntent")
        XCTAssertEqual(control.parameters.map(\.name), ["taskID"])
        XCTAssertEqual(control.parameters.first?.type, .primitive(.string))
        XCTAssertEqual(control.parameters.first?.required, true)
        XCTAssertTrue(control.outputProjections.isEmpty)
        XCTAssertEqual(
            try IntentLabIntegrationDeclaration.FeatureControl.calculateInterfaceDigest(
                featureID: control.featureID,
                operationID: control.operationID,
                testIntentIdentifier: control.testIntentIdentifier,
                parameters: control.parameters,
                outputProjections: control.outputProjections
            ),
            digest
        )
        let input = [
            IntentLabParameter(
                name: "taskID",
                type: .primitive(.string),
                isOptional: false,
                presence: .value(.string("task-001"))
            )
        ]

        let result = try await IntentLabTestIntentTransport.invoke(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            control: control,
            parameters: input,
            context: context
        )

        XCTAssertEqual(result.observations["feature.response"], .string("Completed Buy milk."))
        let observations = try integration.observeTasks()
        XCTAssertEqual(observations["task-001.isComplete"], .boolean(true))
        XCTAssertEqual(observations["task-002.isComplete"], .boolean(false))
        guard case .string(let rawReceipts) = observations["intentlab.actionReceipts"],
              let receiptData = rawReceipts.data(using: .utf8) else {
            return XCTFail("The task query should expose the app-owned action receipts.")
        }
        let receipts = try JSONDecoder.intentLab.decode([IntentLabActionReceipt].self, from: receiptData)
        let receipt = try XCTUnwrap(receipts.first {
            $0.attemptContext == context && $0.operationID == "complete-task"
        })
        XCTAssertEqual(receipt.lane, .appFeature)
        XCTAssertEqual(receipt.kind, .productionService)
        XCTAssertEqual(receipt.resolvedParameters["taskID"], .string("task-001"))
        XCTAssertEqual(receipt.attempt, 1)
        XCTAssertEqual(receipt.terminalStatus, .succeeded)
        XCTAssertTrue(receipt.isTopLevel)
        let wrapperReceipt = try XCTUnwrap(receipts.first {
            $0.attemptContext == context && $0.operationID == "IntentLabInvokeFeatureIntent"
        })
        XCTAssertEqual(wrapperReceipt.kind, .testSupport)
        XCTAssertEqual(wrapperReceipt.lane, .appFeature)
        XCTAssertEqual(wrapperReceipt.terminalStatus, .succeeded)
        XCTAssertFalse(wrapperReceipt.isTopLevel)
        XCTAssertLessThan(wrapperReceipt.sequence, receipt.sequence)
    }

    func testReceiptCountOverflowFailsClosedUntilTaskFixtureReset() async throws {
        let integration = TaskIntegration()
        let context = "receipt-count-\(UUID().uuidString)"
        let application = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context,
            operationID: TaskIntegration.preparationOperation
        )
        defer { application.terminate() }
        let control = try taskFeatureControl()

        for index in 0..<8 {
            do {
                _ = try await invokeTaskFeature(
                    taskID: "missing-\(index)", control: control, context: context
                )
                XCTFail("A missing task should fail after recording its paired receipts.")
            } catch {
                // Each rejected action records a service receipt and a wrapper receipt.
            }
        }

        let fullReceipts = try actionReceipts(from: integration.observeTasks())
        XCTAssertEqual(fullReceipts.count, 16)
        XCTAssertTrue(fullReceipts.allSatisfy { $0.terminalStatus == .failed })

        // This successful top-level action would survive count truncation and
        // could falsely qualify after the earlier failed calls were evicted.
        _ = try await invokeTaskFeature(taskID: "task-001", control: control, context: context)
        XCTAssertTrue(try actionReceipts(from: integration.observeTasks()).isEmpty)

        let resetContext = "receipt-reset-\(UUID().uuidString)"
        let resetApplication = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: resetContext,
            operationID: TaskIntegration.preparationOperation
        )
        defer { resetApplication.terminate() }

        _ = try await invokeTaskFeature(taskID: "task-001", control: control, context: resetContext)
        let resetReceipts = try actionReceipts(from: integration.observeTasks())
        XCTAssertEqual(resetReceipts.count, 2)
        XCTAssertTrue(resetReceipts.contains {
            $0.operationID == "complete-task" && $0.isTopLevel && $0.terminalStatus == .succeeded
        })
    }

    func testReceiptByteOverflowFailsClosedBeforeLaterTopLevelAction() async throws {
        let integration = TaskIntegration()
        let context = "receipt-bytes-\(UUID().uuidString)"
        let application = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context,
            operationID: TaskIntegration.preparationOperation
        )
        defer { application.terminate() }
        let control = try taskFeatureControl()

        do {
            _ = try await invokeTaskFeature(
                taskID: String(repeating: "x", count: 70_000), control: control, context: context
            )
            XCTFail("An unknown oversized task ID should fail after recording its bounded receipt.")
        } catch {
            // The input fits the transport limit but its receipt exceeds the
            // app's independent byte limit.
        }

        _ = try await invokeTaskFeature(taskID: "task-001", control: control, context: context)
        XCTAssertTrue(try actionReceipts(from: integration.observeTasks()).isEmpty)
    }

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

    func testDirectProbePreservesParameterOrderMissingValuesAndLegacyResponseAlias() async throws {
        let integration = TaskIntegration()
        let context = "probe-v1-\(UUID().uuidString)"
        let application = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context,
            operationID: TaskIntegration.preparationOperation
        )
        defer { application.terminate() }
        var scenario = try probeScenario(context: context, schemaVersion: 1)
        // The final supplied value wins; a later missing value does not clear it.
        scenario.directControl.parameters.insert(.init(
            name: "expectedIntegrationContext", type: .primitive(.string),
            isOptional: false, presence: .value(.string("stale-context"))
        ), at: 0)
        scenario.directControl.parameters.append(.init(
            name: "expectedIntegrationContext", type: .primitive(.string),
            isOptional: true, presence: .missing
        ))

        let observations = try await IntentProbe.run(scenario)
        XCTAssertEqual(observations, [
            "response": .string("Completed Buy milk."),
            "visibleResponse": .string("Completed Buy milk."),
        ])
        XCTAssertEqual(try readStatusesAfterReopen(application)["task-001"], "Complete")
    }

    func testDirectProbeRunsBeforeDuplicateProjectionValidation() async throws {
        let integration = TaskIntegration()
        let context = "probe-v2-\(UUID().uuidString)"
        let application = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context,
            operationID: TaskIntegration.preparationOperation
        )
        defer { application.terminate() }
        var scenario = try probeScenario(context: context, schemaVersion: 2)
        scenario.directControl.outputFields.append(scenario.directControl.outputFields[0])

        do {
            _ = try await IntentProbe.run(scenario)
            XCTFail("Duplicate output names must fail after the intent invocation.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The value for response does not match its declared type.")
        }
        XCTAssertEqual(try readStatusesAfterReopen(application)["task-001"], "Complete")
    }

    func testReadinessTransportInvokesFrameworkIntentAndReturnsTypedReadyValue() async throws {
        let integration = TaskIntegration()
        let context = "probe-readiness-\(UUID().uuidString)"
        let application = try integration.prepare(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            context: context,
            operationID: TaskIntegration.preparationOperation
        )
        defer { application.terminate() }
        let declarationURL = try XCTUnwrap(
            Bundle(for: TaskIntegration.self).url(forResource: "IntentLabIntegration", withExtension: "json")
        )
        let declaration = try JSONDecoder.intentLab.decode(
            IntentLabIntegrationDeclaration.self, from: Data(contentsOf: declarationURL)
        )
        let result = try await IntentLabReadinessTestIntentTransport.invoke(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            declaration: declaration,
            context: context
        )
        XCTAssertEqual(result.observations, ["readiness.ready": .boolean(true)])
        let statuses = try readStatusesAfterReopen(application)
        XCTAssertEqual(statuses["task-001"], "Incomplete")
        XCTAssertEqual(statuses["task-002"], "Incomplete")
    }

    private func probeScenario(context: String, schemaVersion: Int) throws -> IntentLabScenario {
        let parameters = [IntentLabParameter(
            name: "expectedIntegrationContext", type: .primitive(.string),
            isOptional: false, presence: .value(.string(context))
        )]
        let outputs = [IntentLabOutputField(
            name: "response", type: .primitive(.string),
            path: schemaVersion == 2 ? [.init(kind: .property, name: "value")] : nil
        )]
        let json: [String: Any] = [
            "schemaVersion": schemaVersion,
            "id": UUID().uuidString,
            "version": 1,
            "definitionDigest": String(repeating: "a", count: 64),
            "target": ["bundleIdentifier": TaskIntegration.testingBundleIdentifier],
            "goal": ["requestText": "Complete Buy milk", "languageCode": "en"],
            "fixture": ["id": "task-fixture", "version": "1", "digest": String(repeating: "b", count: 64),
                        "preparationOperation": TaskIntegration.preparationOperation,
                        "cleanupOperation": TaskIntegration.cleanupOperation],
            "directControl": [
                "intentIdentifier": "AttemptContextTaskMutationTestIntent",
                "parameters": try JSONSerialization.jsonObject(with: JSONEncoder.intentLab.encode(parameters)),
                "outputFields": try JSONSerialization.jsonObject(with: JSONEncoder.intentLab.encode(outputs)),
            ],
            "assertions": [],
            "coverage": ["appFeature": "notApplicable", "intentIntegration": "required", "siri": "notApplicable"],
            "safety": ["deadlineSeconds": 30],
        ]
        return try JSONDecoder.intentLab.decode(
            IntentLabScenario.self, from: JSONSerialization.data(withJSONObject: json)
        )
    }

    private func awaitContextMutation(bundleIdentifier: String, context: String) async throws -> String {
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)
        var intent = definitions.intents["AttemptContextTaskMutationTestIntent"].makeIntent()
        intent[dynamicMember: "expectedIntegrationContext"] = context
        let result = try await intent.run()
        return try result.value
    }

    private func taskFeatureControl() throws -> IntentLabIntegrationDeclaration.FeatureControl {
        let declarationURL = try XCTUnwrap(
            Bundle(for: TaskIntegration.self).url(forResource: "IntentLabIntegration", withExtension: "json")
        )
        let declaration = try JSONDecoder.intentLab.decode(
            IntentLabIntegrationDeclaration.self,
            from: Data(contentsOf: declarationURL)
        )
        try declaration.validate()
        return try declaration.localFeatureControl(
            featureID: "com.example.intent-lab-tasks",
            interfaceDigest: "caeb9a954c99c4e035ec5d94bd8892622bb0676d24541dfedecae3d42096937d",
            operationID: "complete-task"
        )
    }

    private func invokeTaskFeature(
        taskID: String,
        control: IntentLabIntegrationDeclaration.FeatureControl,
        context: String
    ) async throws -> IntentLabTestIntentResult {
        try await IntentLabTestIntentTransport.invoke(
            bundleIdentifier: TaskIntegration.testingBundleIdentifier,
            control: control,
            parameters: [
                IntentLabParameter(
                    name: "taskID",
                    type: .primitive(.string),
                    isOptional: false,
                    presence: .value(.string(taskID))
                )
            ],
            context: context
        )
    }

    private func actionReceipts(
        from observations: [String: IntentLabValue]
    ) throws -> [IntentLabActionReceipt] {
        guard case .string(let json)? = observations["intentlab.actionReceipts"] else {
            throw TaskIntegrationObservationError.missingActionReceipts
        }
        return try JSONDecoder.intentLab.decode([IntentLabActionReceipt].self, from: Data(json.utf8))
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

private enum TaskIntegrationObservationError: LocalizedError {
    case missingActionReceipts
    var errorDescription: String? { "The task entity query did not expose its bounded action receipts." }
}
