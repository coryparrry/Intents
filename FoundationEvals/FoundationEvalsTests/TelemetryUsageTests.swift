import Foundation
import Testing
@testable import IntentsAutomationCore
@testable import PostHog
@testable import FoundationEvals

@MainActor struct TelemetryUsageTests {
    private func recorder(usage: Bool = true, diagnostics: Bool = false, defaults: UserDefaults? = nil) -> (TelemetryController, UsageRecordingClient) {
        let defaults = defaults ?? UserDefaults(suiteName: "TelemetryUsage.\(UUID())")!
        defaults.set(usage, forKey: TelemetryController.consentKey)
        defaults.set(diagnostics, forKey: TelemetryController.diagnosticsConsentKey)
        let client = UsageRecordingClient()
        return (TelemetryController(defaults: defaults, configuration: .init(projectToken: "phc_test", host: "https://telemetry.invalid"), makeClient: { _ in client }), client)
    }

    @Test func productionEligibilityCannotBeReopenedByVerificationArguments() {
        func eligible(debug: Bool = false, simulator: Bool = false, environment: [String: String] = [:], arguments: [String] = []) -> Bool {
            TelemetryCaptureEligibility(isDebug: debug, isSimulator: simulator, environment: environment, arguments: arguments).allowsProductionCapture
        }
        #expect(eligible())
        #expect(eligible(arguments: ["/Applications/Demo Apps/Intents.app/Intents"]))
        #expect(!eligible(debug: true, arguments: ["--enable-telemetry"]))
        #expect(!eligible(simulator: true, arguments: ["--enable-telemetry"]))
        #expect(!TelemetryCaptureEligibility(isDebug: false, isSimulator: false,
            environment: [:], arguments: ["--enable-telemetry"], isLocallyDisabled: true).allowsProductionCapture)
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier", "XCODE_RUNNING_FOR_PREVIEWS", "INTENTS_DEMO", "INTENTS_TELEMETRY_VERIFICATION"] {
            #expect(!eligible(environment: [key: "1"]))
        }
        for argument in ["--evaluation-storage", "--evaluation-storage-name", "--acceptance-storage", "--uitest", "--preview", "--demo", "--telemetry-verification", "--enable-telemetry-verification"] {
            #expect(!eligible(arguments: [argument]))
        }
        #if DEBUG
        #expect(TelemetryConfiguration.bundled == nil)
        #endif
    }

    @Test func screenAndOpenDeduplicatePerSessionAndFirstUsePersists() {
        let defaults = UserDefaults(suiteName: "TelemetryFirstUse.\(UUID())")!
        let (recorder, client) = recorder(defaults: defaults)
        recorder.screen(.overview)
        recorder.screen(.overview)
        recorder.appBecameActive()
        #expect(client.events.map(\.name) == ["foundation_evals_app_opened", "intents_first_use", "$screen"])
        recorder.screen(.intentLab)
        #expect(client.events.last?.properties["$screen_name"] as? String == "intent_lab")
        client.analyticsSessionID = UUID().uuidString
        recorder.screen(.intentLab)
        #expect(client.events.filter { $0.name == "foundation_evals_app_opened" }.count == 2)
        #expect(client.events.filter { $0.name == "$screen" }.count == 3)
        let (relaunched, newClient) = self.recorder(defaults: defaults)
        relaunched.appBecameActive()
        #expect(newClient.events.map(\.name) == ["foundation_evals_app_opened"])
    }

    @Test func captureRotatingSDKSessionStillRecordsItsOpen() {
        let (recorder, client) = recorder()
        recorder.screen(.overview)
        let oldSession = client.analyticsSessionID
        client.nextScreenSession = UUID().uuidString
        recorder.screen(.intentLab)
        #expect(client.analyticsSessionID != oldSession)
        #expect(client.events.filter { $0.name == "foundation_evals_app_opened" }.count == 2)
        recorder.screen(.intentLab)
        #expect(client.events.filter { $0.name == "$screen" }.count == 2)
    }

    @Test func successfulFeaturesWorkWithoutDiagnosticsAndFailuresDoNotCount() {
        let (recorder, client) = recorder()
        for operation in [TelemetryOperation.evaluation, .scenarioRun, .automationRun, .suiteSave, .mcpStart, .mcpInstall] {
            let success = recorder.begin(operation)
            recorder.end(success)
            recorder.end(success)
            recorder.end(recorder.begin(operation), failure: .timeout)
            recorder.end(recorder.begin(operation), failure: .cancelled)
        }
        #expect(client.events.filter { $0.name == "intents_feature_used" }.count == 6)
        #expect(client.events.allSatisfy { !$0.isDiagnostic })
        #expect(client.events.filter { $0.name == "intents_feature_used" }.allSatisfy { Set($0.properties.keys) == ["feature"] })
        recorder.end(recorder.begin(.workspaceLoad))
        #expect(client.events.filter { $0.name == "intents_feature_used" }.count == 6)
    }

    @Test(arguments: [true, false])
    func diagnosticsChangesPreserveUsageCountsAndStillRevokeOldOperations(hasSDKSession: Bool) {
        let defaults = UserDefaults(suiteName: "TelemetryConsentUsage.\(UUID())")!
        var clients: [UsageRecordingClient] = []
        var epochs: [UUID] = []
        let recorder = TelemetryController(defaults: defaults,
            configuration: .init(projectToken: "phc_test", host: "https://telemetry.invalid")) { config in
                let client = UsageRecordingClient()
                if !hasSDKSession { client.analyticsSessionID = nil }
                clients.append(client)
                epochs.append(config.consentEpoch)
                return client
            }
        recorder.screen(.overview)
        recorder.setDiagnosticsEnabled(true)
        recorder.screen(.overview)
        #expect(clients[0].discardCount == 1)
        #expect(clients[1].events.isEmpty)
        recorder.screen(.intentLab)
        #expect(clients[1].events.map(\.name) == ["$screen"])
        let oldSpan = recorder.begin(.evaluation)
        recorder.setDiagnosticsEnabled(false)
        recorder.end(oldSpan)
        recorder.screen(.intentLab)
        #expect(clients[1].discardCount == 1)
        #expect(clients[2].events.isEmpty)
        #expect(Set(epochs).count == 3)
        #expect(clients.flatMap(\.events).filter { $0.name == "foundation_evals_app_opened" }.count == 1)
        #expect(clients.flatMap(\.events).filter { $0.name == "intents_first_use" }.count == 1)
        if hasSDKSession {
            clients[2].analyticsSessionID = UUID().uuidString
            recorder.screen(.intentLab)
            #expect(clients[2].events.map(\.name) == ["foundation_evals_app_opened", "$screen"])
        }
    }

    @Test func diagnosticsChangeBeforeFirstOpenAndUsageReenableStillCountOpens() {
        let (recorder, client) = recorder()
        recorder.setDiagnosticsEnabled(true)
        recorder.screen(.overview)
        recorder.setEnabled(false)
        recorder.setDiagnosticsEnabled(false)
        recorder.screen(.overview)
        recorder.setEnabled(true)
        recorder.screen(.overview)
        #expect(client.events.filter { $0.name == "foundation_evals_app_opened" }.count == 2)
        #expect(client.events.filter { $0.name == "$screen" }.count == 2)
    }

    @Test(arguments: [true, false])
    func diagnosticsChangeAfterFeatureRotatesSessionStillRecordsTheScreen(diagnosticsInitiallyEnabled: Bool) {
        let defaults = UserDefaults(suiteName: "TelemetryRotatedConsentUsage.\(UUID())")!
        defaults.set(diagnosticsInitiallyEnabled, forKey: TelemetryController.diagnosticsConsentKey)
        var clients: [UsageRecordingClient] = []
        let recorder = TelemetryController(defaults: defaults,
            configuration: .init(projectToken: "phc_test", host: "https://telemetry.invalid")) { _ in
                let client = UsageRecordingClient()
                clients.append(client)
                return client
            }
        recorder.screen(.overview)
        // The SDK can rotate at its maximum session length even when the
        // screen was recorded recently. Feature capture records the new open.
        clients[0].nextFeatureSession = UUID().uuidString
        recorder.end(recorder.begin(.evaluation))
        #expect(clients[0].events.filter { $0.name == "foundation_evals_app_opened" }.count == 2)
        #expect(clients[0].events.filter { $0.name == "$screen" }.count == 1)
        recorder.setDiagnosticsEnabled(!diagnosticsInitiallyEnabled)
        recorder.screen(.overview)
        #expect(clients[1].events.map(\.name) == ["$screen"])
        recorder.screen(.overview)
        #expect(clients[1].events.map(\.name) == ["$screen"])
    }

    @Test func consentSpanningAndForeignMeasurementsNeverCreateAdoption() {
        let (recorder, client) = recorder()
        let span = recorder.begin(.evaluation)
        recorder.setEnabled(false)
        recorder.setEnabled(true)
        recorder.end(span)
        #expect(client.events.isEmpty)
        let (other, _) = self.recorder()
        recorder.end(other.begin(.evaluation))
        #expect(client.events.isEmpty)
        let (off, offClient) = self.recorder(usage: false, diagnostics: true)
        off.screen(.overview)
        off.end(off.begin(.evaluation))
        #expect(offClient.events.allSatisfy { $0.isDiagnostic })
    }

    @Test func invalidDurationsAreDroppedAndAbandonedSpansAreBounded() {
        let (recorder, client) = recorder(diagnostics: true)
        for seconds in [10, -86_401] {
            let span = recorder.begin(.evaluation)
            recorder.end(TelemetrySpan(id: span.id, operation: span.operation, started: .now.advanced(by: .seconds(seconds)), consentGeneration: span.consentGeneration))
        }
        #expect(!client.events.contains { $0.name == "intents_feature_used" || $0.name == "foundation_evals_operation_finished" })
        for _ in 0..<101 { _ = recorder.begin(.evaluation) }
        #expect(client.events.filter { $0.name == "foundation_evals_operation_started" }.count == 102)
    }

    @Test func actualMCPServiceSuccessAndFailureDriveAdoption() async {
        for fails in [false, true] {
            let (recorder, client) = recorder()
            let settings = MCPSettingsController(serverControl: MCPServerControl(
                start: { _ in if fails { throw URLError(.cannotConnectToHost) } }, stop: { }
            ), userDefaults: UserDefaults(suiteName: "TelemetryMCPUsage.\(UUID())")!,
                credentialStore: MCPCredentialStore(load: { String(repeating: "A", count: 43) }, save: { _ in }, remove: { }), telemetry: recorder)
            await settings.startServer()
            #expect(client.events.filter { $0.name == "intents_feature_used" }.count == (fails ? 0 : 1))
            if !fails { #expect(client.events.last?.properties["feature"] as? String == "mcp_started") }
        }
    }

    @Test func automationOutcomeRequiresExecutionAndReleasedResources() {
        let result = AttemptResult(summary: .passed, subjectDispatched: true, subjectCompleted: true, assessed: true, evidenceComplete: true, failedObservations: [], missingObservations: [])
        var report = AutomationAttemptReport(attemptID: "test", result: result, receipts: [], resourcesReleased: true)
        #expect(TelemetryFailure.automationFailure(report) == nil)
        report.resourcesReleased = false
        #expect(TelemetryFailure.automationFailure(report) == .evidence)
        report.resourcesReleased = true
        report.result.subjectCompleted = false
        #expect(TelemetryFailure.automationFailure(report) == .evidence)
        report.result.summary = .cancelled
        #expect(TelemetryFailure.automationFailure(report) == .cancelled)
        report.result.summary = .timedOut
        #expect(TelemetryFailure.automationFailure(report) == .timeout)
    }

    @Test func screenMappingNeverIncludesDocumentOrRunIdentifiers() {
        #expect(TelemetryScreen(selection: .run(UUID())) == .run)
        #expect(TelemetryScreen(selection: .suite) == .suite)
        #expect(TelemetryScreen(selection: .appAutomation) == .appAutomation)
    }
}

@MainActor private final class UsageRecordingClient: TelemetryClient {
    var analyticsSessionID: String? = UUID().uuidString
    var events: [TelemetryEvent] = []
    var nextScreenSession: String?
    var nextFeatureSession: String?
    var discardCount = 0
    func capture(_ event: TelemetryEvent) {
        if case .screen = event, let session = nextScreenSession {
            analyticsSessionID = session
            nextScreenSession = nil
        }
        if case .featureUsed = event, let session = nextFeatureSession {
            analyticsSessionID = session
            nextFeatureSession = nil
        }
        events.append(event)
    }
    func stopAndDiscard() { discardCount += 1 }
}

struct TelemetryPayloadFilterTests {
    @Test func exactSDKCallbackWorksOffMainActorAndRetainsOnlySafeFields() async {
        let passed = await Task.detached {
            let id = UUID().uuidString
            let filter = TelemetryPayloadFilter.beforeSend(usage: true, diagnostics: false)
            let event = PostHogEvent(event: "$screen", distinctId: id, properties: [
                "$screen_name": "overview", "$session_id": id, "app": "intents", "environment": "production",
                "platform": "macOS", "schema_version": 2, "app_build": "42", "prompt": "secret",
                "$device_name": "private Mac", "$current_url": "https://private.invalid", "_intents_consent_epoch": id
            ])
            guard let filtered = filter(event) else { return false }
            return filtered.properties["$session_id"] as? String == id
                && filtered.properties["$screen_name"] as? String == "overview"
                && filtered.properties["prompt"] == nil && filtered.properties["$device_name"] == nil
                && filtered.properties["$current_url"] == nil && filtered.properties["platform"] as? String == "macOS"
                && filtered.properties["_intents_consent_epoch"] as? String == id
                && filter(PostHogEvent(event: "$exception", distinctId: id)) == nil
                && filter(PostHogEvent(event: "foundation_evals_operation_started", distinctId: id)) == nil
        }.value
        #expect(passed)
    }

    @Test func unsafeEnumValuesIdentifiersAndNumbersAreRemoved() {
        let properties: [String: Any] = ["feature": "private suite", "$session_id": "private@example.com", "app_build": "42 secret", "schema_version": 2, "duration_ms": Double.infinity]
        let result = TelemetryPayloadFilter.properties(properties, event: "intents_feature_used")
        #expect(result?["feature"] == nil)
        #expect(result?["$session_id"] == nil)
        #expect(result?["app_build"] == nil)
        #expect(result?["duration_ms"] == nil)
        #expect(result?["schema_version"] as? Int == 2)
        #expect(TelemetryPayloadFilter.properties([:], event: "$identify") == nil)
    }
}
