import Foundation
import Testing
@testable import FoundationEvals

@MainActor struct TelemetryDiagnosticsTests {
    private func makeController(usage: Bool = false, diagnostics: Bool = false) -> (TelemetryController, DiagnosticRecordingClient) {
        let defaults = UserDefaults(suiteName: "DiagnosticsTests.\(UUID().uuidString)")!
        defaults.set(usage, forKey: TelemetryController.consentKey)
        defaults.set(diagnostics, forKey: TelemetryController.diagnosticsConsentKey)
        let client = DiagnosticRecordingClient()
        return (TelemetryController(defaults: defaults,
            configuration: .init(projectToken: "phc_test", host: "https://telemetry.invalid"),
            makeClient: { _ in client }), client)
    }

    @Test func usageConsentDoesNotAuthorizeDiagnosticSharing() {
        let (controller, client) = makeController(usage: true)
        controller.capture(.appOpened)
        let span = controller.begin(.scenarioRun)
        controller.end(span, failure: .timeout)
        #expect(!controller.diagnosticsEnabled)
        #expect(client.events.map(\.name) == ["foundation_evals_app_opened"])
        #expect(controller.recentDiagnostics.count == 2)
        #expect(controller.diagnosticReport().contains("timeout"))
    }

    @Test func diagnosticConsentIsIndependentAndCompletionIsExactlyOnce() {
        let (controller, client) = makeController(diagnostics: true)
        controller.capture(.appOpened)
        let span = controller.begin(.scenarioRun)
        controller.end(span, failure: .cancelled)
        controller.end(span, failure: .unexpected)
        #expect(client.events.count == 2)
        #expect(client.events.last?.properties["outcome"] as? String == "cancelled")
        #expect((client.events.last?.properties["duration_ms"] as? Int ?? -1) >= 0)
        #expect(controller.recentDiagnostics.count == 2)
    }

    @Test func consentChangeDoesNotUploadAnEarlierOperationOrAcceptStaleDelivery() async {
        let (controller, client) = makeController(diagnostics: true)
        let oldHandler = client.handler
        let span = controller.begin(.evaluation)
        controller.setDiagnosticsEnabled(false)
        controller.setDiagnosticsEnabled(true)
        controller.end(span, failure: .generation)
        controller.issue(.evaluation, .provider, relatedTo: span)
        #expect(client.events.count == 1)
        #expect(client.discardCount == 1)
        #expect(controller.recentDiagnostics.count == 3)
        oldHandler?(.accepted)
        await Task.yield()
        #expect(controller.delivery == .idle)
        client.handler?(.failed)
        for _ in 0..<5 { await Task.yield() }
        #expect(controller.delivery == .failed)
    }

    @Test func consentEpochPersistsAcrossLaunchesAndRotatesBeforeReenable() throws {
        let defaults = UserDefaults(suiteName: "TelemetryEpoch.\(UUID())")!
        let client = DiagnosticRecordingClient()
        let configuration = TelemetryConfiguration(projectToken: "phc_test", host: "https://telemetry.invalid")
        var epochs: [UUID] = []
        let first = TelemetryController(defaults: defaults, configuration: configuration) { config in
            epochs.append(config.consentEpoch)
            return client
        }
        let second = TelemetryController(defaults: defaults, configuration: configuration) { config in
            epochs.append(config.consentEpoch)
            return client
        }
        #expect(epochs[0] == epochs[1])
        first.setEnabled(false)
        let revokedEpoch = try #require(defaults.string(forKey: TelemetryController.consentEpochKey))
        #expect(revokedEpoch != epochs[0].uuidString)
        first.setEnabled(true)
        #expect(epochs.last?.uuidString != revokedEpoch)
        #expect(second.isEnabled)
    }

    @Test func localReportIsBoundedAndNeverContainsRawErrorContent() throws {
        let (controller, _) = makeController()
        let secret = "secret-token@example.com /Users/private/customer/prompt"
        for _ in 0..<120 {
            controller.issue(.runSave, .classify(NSError(domain: NSCocoaErrorDomain,
                code: NSFileWriteNoPermissionError, userInfo: [NSLocalizedDescriptionKey: secret])))
        }
        #expect(controller.recentDiagnostics.count == 100)
        let report = controller.diagnosticReport()
        #expect(!report.contains(secret))
        #expect(report.contains("permission"))
        #expect(try JSONSerialization.jsonObject(with: Data(report.utf8)) is [String: Any])
        #expect(TelemetryFailure.classify(URLError(.timedOut)) == .timeout)
        #expect(TelemetryFailure.evaluationCategory(secret) == .unexpected)
        #expect(TelemetryPayloadFilter.properties(["$exception_level": "fatal"], event: "$exception") == nil)
        #expect(TelemetryEvent.allowedProperties(for: "foundation_evals_operation_finished")?.contains("error_message") == false)
    }

    @Test func realScenarioStorageAndPreflightFailuresAreRecorded() async throws {
        let (telemetry, _) = makeController()
        let directory = FileManager.default.temporaryDirectory.appending(path: "TelemetryScenario-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory, telemetry: telemetry)
        // A regular file where a directory is required forces the actual storage failure.
        let blocker = directory.appending(path: "blocker")
        try Data("private content must not enter telemetry".utf8).write(to: blocker)
        let broken = ScenarioCoordinator(supportDirectory: blocker, evaluationStore: store)
        await broken.load()
        #expect(telemetry.recentDiagnostics.contains { $0.properties["operation"] == "scenario_load" && $0.properties["outcome"] == "failed" })
        let scenario = ScenarioCoordinator(supportDirectory: directory, evaluationStore: store)
        await scenario.run()
        #expect(telemetry.recentDiagnostics.contains { $0.properties["operation"] == "scenario_run" && $0.properties["outcome"] == "failed" })
        #expect(!telemetry.diagnosticReport().contains(directory.path))
    }

    @Test func judgeErrorsAssertionsAndCancellationHaveDistinctOutcomes() {
        var result = EvaluationSampleResult(caseID: UUID(), caseName: "private case", repetition: 1,
            prompt: "private prompt", expected: "private reference", response: "private response", status: .error,
            score: nil, rationale: nil, durationMilliseconds: 1, usage: .init(),
            judgeDurationMilliseconds: nil, judgeUsage: nil, errorCategory: nil, errorMessage: nil,
            judgeErrorCategory: "private judge error", judgeErrorMessage: "private judge detail")
        #expect(TelemetryFailure.evaluationFailure(results: [result], cancelled: false) == .judge)
        #expect(TelemetryFailure.evaluationFailure(results: [result], cancelled: true) == .cancelled)
        result.judgeErrorCategory = nil
        result.judgeErrorMessage = nil
        result.status = .failed
        #expect(TelemetryFailure.evaluationFailure(results: [result], cancelled: false) == nil)
        result.errorCategory = "customProviderError"
        #expect(TelemetryFailure.evaluationFailure(results: [result], cancelled: false) == .provider)
    }

    @Test(arguments: [true, false])
    func stableScenarioSetupFailuresReportValidationBeforeAnyExecutionRecord(invalidDefinition: Bool) async throws {
        let (telemetry, client) = makeController(diagnostics: true)
        let directory = FileManager.default.temporaryDirectory.appending(path: "TelemetryStableSetup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory, telemetry: telemetry)
        let coordinator = ScenarioCoordinator(supportDirectory: directory, evaluationStore: store,
            executionAdmission: ScenarioExecutionAdmission())
        await coordinator.load()
        #expect(coordinator.hasLoaded)
        var definition = ScenarioDefinition.starter(projectID: store.selectedProjectID)
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition.purpose = .exploratory
        definition.checkMode = .basic
        definition.requiredClaims = [.executionCompleted, .returnedValueChecked]
        definition.observationPlan = [.init(id: "taskID", source: .intentResult)]
        definition.assertions = [.init(kind: .returnedField, observationKey: "taskID",
            expectedValue: .string("task-001"), explanation: "The returned ID matches.",
            applicableLanes: [.intentIntegration])]
        definition.directControl.outputFields = [.init(name: "taskID", type: .primitive(.string),
            path: [.init(kind: .property, name: "value")])]
        definition.goal = .init(requestText: "", languageCode: "", expectedBehavior: "")
        definition.fixture = .init(id: "", version: "", digest: "", isSynthetic: false,
            preparationOperation: "", cleanupOperation: "")
        definition.coverage = .init(appFeature: .notApplicable, intentIntegration: .required,
            siri: .notApplicable, siriAttemptCount: nil)
        definition.integration = invalidDefinition ? nil : .init(id: "fixture", version: "1",
            digest: String(repeating: "a", count: 64))
        if !invalidDefinition { try ScenarioValidator.validate(try definition.frozen()) }
        coordinator.draft = definition
        await coordinator.run()
        let finished = client.events.filter {
            $0.name == "foundation_evals_operation_finished" && $0.properties["operation"] as? String == "scenario_run"
        }
        #expect(finished.count == 1)
        #expect(finished.first?.properties["error_code"] as? String == "validation")
        #expect(finished.first?.properties["outcome"] as? String == "failed")
        #expect(coordinator.executionRecords.isEmpty)
        #expect(coordinator.notice?.contains(invalidDefinition ? "integration" : "Approve this project") == true)
        #expect(!telemetry.diagnosticReport().contains(directory.path))
    }

    @Test func stableSetupErrorCategoriesRemainDistinctAndContentFree() {
        let secret = "/private/customer/build.log private@example.com"
        #expect(TelemetryFailure.classify(XcodeTestExecutorError.buildFailed(1, secret)) == .build)
        #expect(TelemetryFailure.classify(XcodeTestExecutorError.connectionCheck(secret)) == .validation)
        #expect(TelemetryFailure.classify(XcodeTestExecutorError.deviceUnavailable(secret)) == .deviceUnavailable)
        #expect(TelemetryFailure.classify(XcodeTestExecutorError.evidenceMissing) == .evidence)
        #expect(TelemetryFailure.classify(XcodeTestExecutorError.cancelled) == .cancelled)
        #expect(TelemetryFailure.classify(XcodeTestExecutorError.timedOut) == .timeout)
    }

    @Test func corruptCatalogRecoveryReportsStorageFailure() throws {
        let (telemetry, _) = makeController()
        let directory = FileManager.default.temporaryDirectory.appending(path: "TelemetryCatalog-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("invalid private catalog".utf8).write(to: directory.appending(path: EvaluationWorkspacePersistence.catalogFilename))
        _ = EvaluationStore(supportDirectory: directory, telemetry: telemetry)
        #expect(telemetry.recentDiagnostics.contains { $0.properties["operation"] == "workspace_load" && $0.properties["error_code"] == "storage" })
        #expect(!telemetry.diagnosticReport().contains("private catalog"))
    }

    @Test func realMCPStartFailureIsRecordedWithoutCredentialOrErrorMessage() async {
        let (telemetry, _) = makeController()
        let privateMessage = "https://private-provider.invalid/auth?token=secret"
        let controller = MCPSettingsController(serverControl: MCPServerControl(
            start: { _ in throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: privateMessage]) },
            stop: { }
        ), userDefaults: UserDefaults(suiteName: "TelemetryMCP.\(UUID())")!,
           credentialStore: MCPCredentialStore(load: { String(repeating: "A", count: 43) }, save: { _ in }, remove: { }),
           telemetry: telemetry)
        await controller.startServer()
        #expect(telemetry.recentDiagnostics.last?.properties["operation"] == "mcp_start")
        #expect(telemetry.recentDiagnostics.last?.properties["error_code"] == "network")
        #expect(!telemetry.diagnosticReport().contains(privateMessage))
    }
}

@MainActor final class DiagnosticRecordingClient: TelemetryClient {
    var events: [TelemetryEvent] = []
    var discardCount = 0
    var handler: (@Sendable (TelemetryDelivery) -> Void)?
    func capture(_ event: TelemetryEvent) { events.append(event) }
    func stopAndDiscard() { discardCount += 1 }
    func setDeliveryHandler(_ handler: @escaping @Sendable (TelemetryDelivery) -> Void) { self.handler = handler }
}
