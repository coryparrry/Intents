import Foundation
import Testing
@testable import PostHog
@testable import FoundationEvals

@MainActor struct TelemetryControllerTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "TelemetryTests.\(UUID().uuidString)")! }
    private let configuration = TelemetryConfiguration(projectToken: "phc_test", host: "https://us.i.posthog.com")



    @Test(arguments: [false, true])
    func cancellationSpanIsCountedOnceAndRevokedUploadsAreRejected(revoke: Bool) {
        let defaults = defaults()
        defaults.set(true, forKey: TelemetryController.diagnosticsConsentKey)
        var clients: [RecordingTelemetryClient] = []
        let controller = TelemetryController(defaults: defaults, configuration: configuration) { _ in
            let client = RecordingTelemetryClient()
            clients.append(client)
            return client
        }
        let span = controller.begin(.evaluation)
        if revoke { controller.setDiagnosticsEnabled(false); controller.setDiagnosticsEnabled(true) }
        controller.end(span, failure: .cancelled)
        controller.end(span, failure: .cancelled)
        let outcomes = controller.recentDiagnostics.filter {
            $0.properties["operation"] == "evaluation" && $0.properties["outcome"] != nil
        }
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.properties["outcome"] == "cancelled")
        let uploads = clients.flatMap(\.events).filter { $0 == "foundation_evals_operation_finished" }
        #expect(uploads.count == (revoke ? 0 : 1))
    }

    @Test func freshStartupEnablesAnonymousTelemetry() {
        let client = RecordingTelemetryClient()
        var creations = 0
        let controller = TelemetryController(defaults: defaults(), configuration: configuration) { _ in
            creations += 1
            return client
        }
        controller.capture(.appOpened)
        #expect(controller.isEnabled)
        #expect(creations == 1)
        #expect(client.events == ["foundation_evals_app_opened"])
    }

    @Test func savedOptOutIsPreservedOnStartup() {
        let defaults = defaults()
        defaults.set(false, forKey: TelemetryController.consentKey)
        var creations = 0
        let controller = TelemetryController(defaults: defaults, configuration: configuration) { _ in
            creations += 1
            return RecordingTelemetryClient()
        }
        controller.capture(.appOpened)
        #expect(!controller.isEnabled)
        #expect(creations == 0)
        #expect(defaults.object(forKey: TelemetryController.consentKey) as? Bool == false)
    }

    @Test func consentTransitionsCreateOnceDiscardAndUseNewClient() {
        let defaults = defaults()
        defaults.set(false, forKey: TelemetryController.consentKey)
        var clients: [RecordingTelemetryClient] = []
        let controller = TelemetryController(defaults: defaults, configuration: configuration) { _ in
            let client = RecordingTelemetryClient()
            clients.append(client)
            return client
        }
        controller.setEnabled(true)
        controller.setEnabled(true)
        controller.capture(.appOpened)
        #expect(clients.count == 1)
        #expect(clients[0].events == ["foundation_evals_app_opened"])
        #expect(defaults.bool(forKey: TelemetryController.consentKey))
        controller.setEnabled(false)
        controller.capture(.appOpened)
        #expect(clients[0].discardCount == 1)
        #expect(clients[0].events.count == 1)
        #expect(!defaults.bool(forKey: TelemetryController.consentKey))
        controller.setEnabled(true)
        controller.capture(.appOpened)
        #expect(clients.count == 2)
        #expect(clients[1].events == ["foundation_evals_app_opened"])
    }

    @Test func persistedConsentStartsClientButMissingConfigurationFailsClosed() {
        let defaults = defaults()
        defaults.set(true, forKey: TelemetryController.consentKey)
        var creations = 0
        let factory: @MainActor @Sendable (TelemetryConfiguration) -> any TelemetryClient = { _ in
            creations += 1
            return RecordingTelemetryClient()
        }
        let enabled = TelemetryController(defaults: defaults, configuration: configuration, makeClient: factory)
        #expect(enabled.isEnabled)
        #expect(creations == 1)
        let missing = TelemetryController(defaults: defaults, configuration: nil, makeClient: factory)
        missing.setEnabled(true)
        #expect(!missing.isEnabled)
        #expect(!missing.isConfigured)
        #expect(creations == 1)
    }

    @Test func eventAllowlistRejectsEvaluationsAndContent() {
        for name in ["$autocapture", "foundation_evals_evaluation_started", "foundation_evals_evaluation_finished"] {
            #expect(TelemetryEvent.allowedProperties(for: name) == nil)
        }
        #expect(TelemetryEvent.allowedProperties(for: "foundation_evals_app_opened") ==
                TelemetryEvent.allowedProperties(for: "intents_first_use"))
    }

}

@MainActor private final class RecordingTelemetryClient: TelemetryClient {
    var events: [String] = []
    var discardCount = 0
    func capture(_ event: TelemetryEvent) { events.append(event.name) }
    func stopAndDiscard() { discardCount += 1 }
}

@Suite(.serialized) struct TelemetryTransportTests {
    /// Verifies SDK setup supplies the initial session without a test-only startSession call.
    @MainActor @Test func realSDKInitialUsageSharesOneSession() async throws {
        TelemetryRecordingProtocol.clear()
        let fixture = TelemetrySDKFixture()
        defer { fixture.cleanUp() }
        let defaultsName = "TelemetrySDKStartup.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        var client: PostHogTelemetryClient?
        let controller = TelemetryController(defaults: defaults, configuration: fixture.configuration,
            makeClient: { configuration in
                let created = fixture.makeClient(configuration: configuration)
                client = created
                return created
            }, discardPendingCrashes: {})
        let initializedSession = try #require(client?.analyticsSessionID)
        #expect(UUID(uuidString: initializedSession) != nil)
        controller.screen(.overview)
        controller.screen(.overview)
        controller.appBecameActive()
        let activeClient = try #require(client)
        try await fixture.waitUntil {
            activeClient.flush()
            return try TelemetryRecordingProtocol.events().count == 3
        }
        let events = try TelemetryRecordingProtocol.events()
        #expect(events.compactMap { $0["event"] as? String }.sorted() ==
            ["$screen", "foundation_evals_app_opened", "intents_first_use"].sorted())
        #expect(events.allSatisfy { ($0["properties"] as? [String: Any])?["$session_id"] as? String == initializedSession })
        #expect(client?.analyticsSessionID == initializedSession)
    }

    /// Verifies actual SDK expiry plus missing-session callback recovery without changing global lifecycle state.
    @MainActor @Test func realSDKRecoversMissingUsageSessionWithoutRotatingDiagnostics() async throws {
        TelemetryRecordingProtocol.clear()
        let fixture = TelemetrySDKFixture()
        defer { fixture.cleanUp() }
        var configuration = fixture.configuration
        configuration.diagnosticsEnabled = true
        let client = fixture.makeClient(configuration: configuration)
        let sdk = try #require(fixture.sdk)
        let firstSession = try #require(client.analyticsSessionID)
        var properties = TelemetryController.diagnosticContext(sessionID: UUID())
        properties["environment"] = "production"
        properties["_intents_consent_epoch"] = configuration.consentEpoch.uuidString
        properties["$screen_name"] = "overview"
        // Setup starts foregrounded on macOS. This exercises normal SDK expiry
        // without replacing its process-global clock or waiting thirty minutes.
        sdk.capture("$screen", properties: properties, timestamp: Date().addingTimeInterval(1_801))
        let expiredSession = try #require(client.analyticsSessionID)
        #expect(UUID(uuidString: expiredSession) != nil)
        #expect(expiredSession != firstSession)
        // Detach only this SDK instance's context observer: in the foreground
        // it otherwise immediately recreates a session when endSession clears it.
        // This preserves a missing session without global lifecycle mutation.
        sdk.sessionManager.onSessionIdChanged = PostHogMulticastCallback<Void>()
        sdk.endSession()
        #expect(client.analyticsSessionID == nil)
        properties["$screen_name"] = "evaluations"
        // Exercise the real beforeSend/queue/transport path with the missing
        // session output that SDK background expiry can produce. This deliberately
        // does not simulate or claim an actual application background transition.
        sdk.captureInternal("$screen", properties: properties, skipBuildProperties: true)
        let recoveredSession = try #require(client.analyticsSessionID)
        #expect(UUID(uuidString: recoveredSession) != nil)
        #expect(recoveredSession != expiredSession)
        client.capture(.appOpened)
        #expect(client.analyticsSessionID == recoveredSession)
        client.capture(.operationFinished(.evaluation, UUID(), .failed, 125, .timeout))
        #expect(client.analyticsSessionID == recoveredSession)
        // A sessionless diagnostic entering the same callback must stay
        // sessionless rather than manufacture a product-usage session.
        sdk.endSession()
        properties["operation"] = "evaluation"
        properties["error_code"] = "timeout"
        sdk.captureInternal("foundation_evals_diagnostic_issue", properties: properties, skipBuildProperties: true)
        #expect(client.analyticsSessionID == nil)
        try await fixture.waitUntil {
            client.flush()
            return try TelemetryRecordingProtocol.events().count == 5
        }
        let events = try TelemetryRecordingProtocol.events()
        let screens = events.filter { $0["event"] as? String == "$screen" }
        #expect(screens.count == 2)
        let initialScreen = try #require(screens.first { ($0["properties"] as? [String: Any])?["$screen_name"] as? String == "overview" })
        let repairedScreen = try #require(screens.first { ($0["properties"] as? [String: Any])?["$screen_name"] as? String == "evaluations" })
        #expect((initialScreen["properties"] as? [String: Any])?["$session_id"] as? String == expiredSession)
        #expect((repairedScreen["properties"] as? [String: Any])?["$session_id"] as? String == recoveredSession)
        let diagnostic = try #require(events.first { $0["event"] as? String == "foundation_evals_diagnostic_issue" })
        #expect((diagnostic["properties"] as? [String: Any])?["$session_id"] == nil)
    }

    /// Retries an actual disk-backed SDK event after closing and recreating the SDK without a consent purge.
    @MainActor @Test func realSDKReopensPersistedOfflineQueueWithoutPurging() async throws {
        TelemetryRecordingProtocol.clear(networkError: .notConnectedToInternet)
        defer { TelemetryRecordingProtocol.clear() }
        let fixture = TelemetrySDKFixture()
        defer { fixture.cleanUp() }
        let first = fixture.makeClient()
        let originalIdentity = try #require(fixture.sdk?.getDistinctId())
        let originalSession = try #require(first.analyticsSessionID)
        let delivery = DeliveryRecorder()
        first.setDeliveryHandler { delivery.record($0) }
        first.capture(.appOpened)
        try await fixture.waitUntil { delivery.latest == .failed }
        fixture.closeRetainingQueue()
        let queueURL = fixture.storage.appendingPathComponent("posthog.queueFolder.uuid")
        let files = try FileManager.default.contentsOfDirectory(at: queueURL, includingPropertiesForKeys: nil)
        let persistedFile = try #require(files.first)
        #expect(files.count == 1)
        let persisted = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: persistedFile)) as? [String: Any])
        #expect(persisted["event"] as? String == "foundation_evals_app_opened")
        #expect((persisted["properties"] as? [String: Any])?["_intents_consent_epoch"] as? String == fixture.configuration.consentEpoch.uuidString)

        TelemetryRecordingProtocol.clear()
        let reopened = fixture.makeClient()
        #expect(fixture.sdk?.getDistinctId() == originalIdentity)
        #expect(reopened.analyticsSessionID != originalSession)
        reopened.flush()
        try await fixture.waitUntil { try TelemetryRecordingProtocol.events().count == 1 }
        let event = try #require(try TelemetryRecordingProtocol.events().first)
        #expect(event["event"] as? String == "foundation_evals_app_opened")
        #expect(event["distinct_id"] as? String == originalIdentity)
        #expect(event["uuid"] as? String == persisted["uuid"] as? String)
        #expect(event["timestamp"] as? String == persisted["timestamp"] as? String)
        let forwardedProperties = try #require(event["properties"] as? [String: Any])
        #expect(forwardedProperties["$session_id"] as? String == originalSession)
        #expect(forwardedProperties["_intents_consent_epoch"] == nil)
        try await fixture.waitUntil {
            try FileManager.default.contentsOfDirectory(atPath: queueURL.path).isEmpty
        }
    }

    @MainActor @Test func SDKIdentitySurvivesRelaunchAndConsentQueuePurge() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryRecordingProtocol.self]
        let token = "phc_identity_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "").appendingPathComponent(token)
        defer { try? FileManager.default.removeItem(at: storage) }
        var identities: [String] = []
        func makeClient() -> PostHogTelemetryClient {
            PostHogTelemetryClient(configuration: .init(projectToken: token, host: "https://telemetry.invalid"),
                sessionConfiguration: configuration, makeSDK: { config in
                    config.disableReachabilityForTesting = true
                    let sdk = PostHogSDK.with(config)
                    identities.append(sdk.getDistinctId())
                    return sdk
                })
        }
        let first = makeClient()
        first.capture(.appOpened)
        first.stopAndDiscard()
        let second = makeClient()
        second.capture(.appOpened)
        second.stopAndDiscard()
        #expect(identities.count == 2)
        #expect(identities[0] == identities[1])
        #expect(UUID(uuidString: identities[0]) != nil)
        #expect(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("posthog.queueFolder.uuid").path))
    }

    @Test func uploadBodySurvivesAndRemoteConfigIsBlocked() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryRecordingProtocol.self]
        TelemetryRecordingProtocol.clear()
        let transport = TelemetryTransport(host: "https://telemetry.invalid", sessionConfiguration: configuration)
        defer { transport.stop() }
        let session = URLSession(configuration: transport.configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://telemetry.invalid/batch")!)
        request.httpMethod = "POST"
        let payload = Data("{\"batch\":[{\"event\":\"foundation_evals_app_opened\"}]}".utf8)
        _ = try await session.upload(for: request, from: payload)
        let forwarded = try #require(TelemetryRecordingProtocol.bodies().first)
        #expect(String(decoding: forwarded, as: UTF8.self).contains("foundation_evals_app_opened"))
        do {
            _ = try await session.data(from: URL(string: "https://telemetry.invalid/flags")!)
            Issue.record("Feature flags must be blocked")
        } catch { }
        #expect(TelemetryRecordingProtocol.bodies().count == 1)
    }

    /// Verifies the real SDK's consent restoration, property filtering and intercepted diagnostic delivery.
    @MainActor @Test func realSDKSerializesSafeDiagnosticsAndDeliversThemThroughTransport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryRecordingProtocol.self]
        TelemetryRecordingProtocol.clear()
        let client = PostHogTelemetryClient(configuration: .init(
            projectToken: "phc_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            host: "https://telemetry.invalid", diagnosticsEnabled: true
        ), sessionConfiguration: configuration, makeSDK: { config in
            // The injected HTTPS protocol needs no network. Do not let the SDK's
            // real SCNetworkReachability veto this deterministic transport test.
            config.disableReachabilityForTesting = true
            let sdk = PostHogSDK.with(config)
            // Simulate an SDK opt-out flag left behind when queue deletion fails.
            sdk.optOut()
            return sdk
        })
        defer { client.stopAndDiscard() }
        client.capture(.operationFinished(.evaluation, UUID(), .failed, 125, .timeout))
        client.flush()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while TelemetryRecordingProtocol.bodies().isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            client.flush()
        }
        let body = try #require(TelemetryRecordingProtocol.bodies().first)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let batch = try #require(payload["batch"] as? [[String: Any]])
        let event = try #require(batch.first)
        #expect(event["event"] as? String == "foundation_evals_operation_finished")
        let properties = try #require(event["properties"] as? [String: Any])
        #expect(properties["operation"] as? String == "evaluation")
        #expect(properties["error_code"] as? String == "timeout")
        #expect(properties["duration_ms"] as? Int == 125)
        #expect(properties["$process_person_profile"] as? Bool == false)
        #expect(properties["$geoip_disable"] as? Bool == true)
        #expect(properties["$device_id"] == nil)
        #expect((properties["$session_id"] as? String).flatMap(UUID.init(uuidString:)) != nil)
        #expect(properties["$screen_name"] == nil)
        #expect(Set(properties.keys).isSubset(of: TelemetryEvent.allowedProperties(for: "foundation_evals_operation_finished")!))
    }

    @Test func emptyQueryIsAcceptedButQueryParametersAreBlocked() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryRecordingProtocol.self]
        TelemetryRecordingProtocol.clear()
        let transport = TelemetryTransport(host: "https://telemetry.invalid", sessionConfiguration: configuration)
        defer { transport.stop() }
        let session = URLSession(configuration: transport.configuration)
        defer { session.invalidateAndCancel() }
        let payload = Data(#"{"batch":[{"event":"foundation_evals_app_opened"}]}"#.utf8)
        var request = URLRequest(url: URL(string: "https://telemetry.invalid/batch?")!)
        request.httpMethod = "POST"
        _ = try await session.upload(for: request, from: payload)
        request.url = URL(string: "https://telemetry.invalid/batch?secret=forbidden")!
        do {
            _ = try await session.upload(for: request, from: payload)
            Issue.record("Query parameters must be blocked")
        } catch { }
        #expect(TelemetryRecordingProtocol.bodies().count == 1)
    }

    @Test func fullyRevokedBatchIsAcknowledgedWithoutNetworkOrAcceptedStatus() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryRecordingProtocol.self]
        TelemetryRecordingProtocol.clear()
        let transport = TelemetryTransport(host: "https://telemetry.invalid", sessionConfiguration: configuration,
            allowsUsage: false, allowsDiagnostics: false)
        defer { transport.stop() }
        let delivery = DeliveryRecorder()
        transport.setDeliveryHandler { delivery.record($0) }
        let session = URLSession(configuration: transport.configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://telemetry.invalid/batch")!)
        request.httpMethod = "POST"
        let (_, response) = try await session.upload(for: request, from: Data(#"{"batch":[{"event":"foundation_evals_app_opened"}]}"#.utf8))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(TelemetryRecordingProtocol.bodies().isEmpty)
        #expect(delivery.latest != .accepted)
    }

    @Test func HTTPRejectionIsVisibleAsDeliveryFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryRecordingProtocol.self]
        TelemetryRecordingProtocol.clear(statusCode: 503)
        defer { TelemetryRecordingProtocol.clear() }
        let transport = TelemetryTransport(host: "https://telemetry.invalid", sessionConfiguration: configuration)
        defer { transport.stop() }
        let delivery = DeliveryRecorder()
        transport.setDeliveryHandler { delivery.record($0) }
        let session = URLSession(configuration: transport.configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://telemetry.invalid/batch")!)
        request.httpMethod = "POST"
        _ = try await session.upload(for: request, from: Data(#"{"batch":[{"event":"foundation_evals_app_opened"}]}"#.utf8))
        #expect(delivery.latest == .failed)
    }

    @Test func persistedBatchIsFilteredUsingCurrentConsentAndSafeValues() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryRecordingProtocol.self]
        TelemetryRecordingProtocol.clear()
        let transport = TelemetryTransport(host: "https://telemetry.invalid", sessionConfiguration: configuration,
            allowsUsage: true, allowsDiagnostics: false)
        defer { transport.stop() }
        let session = URLSession(configuration: transport.configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://telemetry.invalid/batch")!)
        request.httpMethod = "POST"
        let payload = Data(#"{"private":"secret","batch":[{"event":"foundation_evals_app_opened","properties":{"app_version":"1.0","prompt":"secret","os_major":27}},{"event":"foundation_evals_operation_finished","properties":{"operation":"evaluation","outcome":"failed","error_code":"timeout"}},{"event":"$exception","properties":{"message":"secret"}}]}"#.utf8)
        _ = try await session.upload(for: request, from: payload)
        let body = try #require(TelemetryRecordingProtocol.bodies().first)
        let forwarded = String(decoding: body, as: UTF8.self)
        #expect(forwarded.contains("foundation_evals_app_opened"))
        #expect(!forwarded.contains("secret"))
        #expect(!forwarded.contains("operation_finished"))
        #expect(!forwarded.contains("$exception"))
        // This simulates a retained SDK batch after diagnostic opt-out, independently of queue deletion.
    }

    @Test func revokedEpochCannotReplayAfterSharingIsReenabled() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryRecordingProtocol.self]
        TelemetryRecordingProtocol.clear()
        let previousEpoch = UUID()
        let currentEpoch = UUID()
        let transport = TelemetryTransport(host: "https://telemetry.invalid", sessionConfiguration: configuration,
            allowsUsage: true, allowsDiagnostics: true, consentEpoch: currentEpoch)
        defer { transport.stop() }
        let session = URLSession(configuration: transport.configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://telemetry.invalid/batch")!)
        request.httpMethod = "POST"
        let events: [[String: Any]] = [
            ["event": "foundation_evals_diagnostic_issue", "properties": ["operation": "evaluation", "error_code": "timeout", "_intents_consent_epoch": previousEpoch.uuidString]],
            ["event": "foundation_evals_app_opened", "properties": ["app_version": "1.0", "_intents_consent_epoch": currentEpoch.uuidString]]
        ]
        _ = try await session.upload(for: request, from: JSONSerialization.data(withJSONObject: ["batch": events]))
        let body = try #require(TelemetryRecordingProtocol.bodies().first)
        let forwarded = String(decoding: body, as: UTF8.self)
        #expect(!forwarded.contains("diagnostic_issue"))
        #expect(!forwarded.contains("consent_epoch"))
        #expect(forwarded.contains("app_opened"))
    }

    @Test func revokedSessionCannotSendAfterNewConsent() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryRecordingProtocol.self]
        TelemetryRecordingProtocol.clear()
        let old = TelemetryTransport(host: "https://telemetry.invalid", sessionConfiguration: configuration)
        let oldSession = URLSession(configuration: old.configuration)
        old.stop()
        let current = TelemetryTransport(host: "https://telemetry.invalid", sessionConfiguration: configuration)
        defer { current.stop(); oldSession.invalidateAndCancel() }
        let currentSession = URLSession(configuration: current.configuration)
        defer { currentSession.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://telemetry.invalid/batch")!)
        request.httpMethod = "POST"
        do {
            _ = try await oldSession.upload(for: request, from: Data(#"{"batch":[{"event":"foundation_evals_app_opened","properties":{"app_version":"old"}}]}"#.utf8))
            Issue.record("Revoked transport must stay blocked")
        } catch { }
        _ = try await currentSession.upload(for: request, from: Data(#"{"batch":[{"event":"foundation_evals_app_opened","properties":{"app_version":"new"}}]}"#.utf8))
        #expect(TelemetryRecordingProtocol.bodies().count == 1)
        #expect(String(decoding: TelemetryRecordingProtocol.bodies()[0], as: UTF8.self).contains("new"))
    }
}

/// Owns a synthetic project store and a locally intercepted SDK connection.
@MainActor private final class TelemetrySDKFixture {
    let configuration = TelemetryConfiguration(
        projectToken: "phc_restart_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        host: "https://telemetry.invalid")
    private(set) var sdk: PostHogSDK?
    private var transport: TelemetryTransport?
    var storage: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "")
            .appendingPathComponent(configuration.projectToken)
    }

    /// Creates a real SDK with the production filter and transport, intercepting network requests locally.
    func makeClient(configuration: TelemetryConfiguration? = nil) -> PostHogTelemetryClient {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [TelemetryRecordingProtocol.self]
        return PostHogTelemetryClient(configuration: configuration ?? self.configuration,
            sessionConfiguration: session, makeSDK: { config in
                config.disableReachabilityForTesting = true
                config.disableQueueTimerForTesting = true
                config.disableFlushOnBackgroundForTesting = true
                var request = URLRequest(url: URL(string: "https://telemetry.invalid/batch")!)
                request.allHTTPHeaderFields = config.urlSessionConfiguration?.httpAdditionalHeaders as? [String: String]
                transport = TelemetryTransport.lookup(request)
                let created = PostHogSDK.with(config)
                sdk = created
                return created
            })
    }

    /// Closes real SDK/session resources while preserving persisted consent, identity and queue files.
    func closeRetainingQueue() {
        sdk?.close()
        transport?.stop()
        sdk = nil
        transport = nil
    }

    /// Removes only this fixture's random project directory after its final assertions.
    func cleanUp() {
        closeRetainingQueue()
        try? FileManager.default.removeItem(at: storage)
    }

    /// Waits a bounded interval for asynchronous SDK delivery or queue acknowledgements.
    func waitUntil(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(try condition())
    }
}

private final class TelemetryRecordingProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [Data] = []
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var networkError: URLError.Code?
    /// Resets intercepted requests and selects a local HTTP response or transport failure.
    static func clear(statusCode: Int = 200, networkError: URLError.Code? = nil) {
        lock.withLock { captured = []; Self.statusCode = statusCode; Self.networkError = networkError }
    }
    static func bodies() -> [Data] { lock.withLock { captured } }
    /// Decodes events that reached the actual final transport gate, preserving batch boundaries on the wire.
    static func events() throws -> [[String: Any]] {
        try bodies().flatMap { data in
            let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(payload["batch"] as? [[String: Any]])
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// Captures the locally forwarded body and completes with the configured response or offline error.
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let (statusCode, networkError) = Self.lock.withLock {
            Self.captured.append(body)
            return (Self.statusCode, Self.networkError)
        }
        if let networkError {
            client?.urlProtocol(self, didFailWithError: URLError(networkError))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class DeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TelemetryDelivery?
    var latest: TelemetryDelivery? { lock.withLock { value } }
    func record(_ status: TelemetryDelivery) { lock.withLock { value = status } }
}
