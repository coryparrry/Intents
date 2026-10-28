import Foundation
import Testing
@testable import FoundationEvals

@MainActor
struct TelemetryConnectorTests {
    /// Counts authenticated admission once per listener, independently of startup and request volume.
    @Test
    func admittedRequestsCountConnectorUseWithoutCountingListenerReadiness() async throws {
        let fixture = try ConnectorTelemetryFixture()
        defer { fixture.cleanup() }
        await fixture.settings.startServer()
        let server = try #require(fixture.factory.latest)
        #expect(fixture.client.connections.isEmpty)
        #expect(fixture.settings.lastConnection == nil)

        let rejected = await server.request(authenticated: false)
        #expect(rejected.status == 401)
        #expect(fixture.client.connections.isEmpty)
        #expect(fixture.settings.lastConnection == nil)

        let admitted = await server.request(authenticated: true)
        #expect(admitted.status == 200)
        #expect(fixture.settings.lastConnection != nil)
        #expect(fixture.client.connections.count == 1)
        let later = Date(timeIntervalSince1970: 2_000_000_000)
        await server.reportAdmission(at: later)
        await fixture.settings.startServer()
        #expect(fixture.settings.lastConnection == later)
        #expect(fixture.factory.servers.count == 1)
        #expect(fixture.client.connections.count == 1)
        #expect(Set(try #require(fixture.client.connections.first).properties.keys) == ["feature"])
        await fixture.runtime.prepareForTermination()
    }

    /// A stopped listener produces one fixed issue; stale requests and failures cannot affect a replacement.
    @Test
    func unexpectedStopRecordsOneIssueAndReconnectCountsNewAdmission() async throws {
        let fixture = try ConnectorTelemetryFixture()
        defer { fixture.cleanup() }
        await fixture.settings.startServer()
        let first = try #require(fixture.factory.latest)
        _ = await first.request(authenticated: true)
        let firstConnection = fixture.settings.lastConnection
        await first.failUnexpectedly()
        await first.failUnexpectedly()
        #expect(fixture.settings.serverState == .failed)
        #expect(fixture.client.issues.count == 1)
        let issue = try #require(fixture.client.issues.first)
        #expect(issue.properties["operation"] as? String == "mcp_start")
        #expect(issue.properties["error_code"] as? String == "unexpected")
        #expect(!fixture.telemetry.diagnosticReport().contains(ConnectorTelemetryServer.privateFailure))
        #expect(!String(describing: fixture.client.events.map(\.properties)).contains(ConnectorTelemetryServer.privateFailure))

        await fixture.settings.startServer()
        let replacement = try #require(fixture.factory.latest)
        await first.reportAdmission(at: Date(timeIntervalSince1970: 123))
        await first.failUnexpectedly()
        #expect(fixture.settings.serverState == .running)
        #expect(fixture.settings.lastConnection == firstConnection)
        #expect(fixture.client.issues.count == 1)
        #expect(fixture.client.connections.count == 1)
        _ = await replacement.request(authenticated: true)
        #expect(fixture.client.connections.count == 2)
        await fixture.runtime.prepareForTermination()
    }

    /// Startup exceptions and stop callbacks before readiness remain a single failed startup span.
    @Test(arguments: [ConnectorTelemetryStartup.throwFailure, .unexpectedStop])
    func startupFailuresDoNotDuplicateDiagnosticIssues(startup: ConnectorTelemetryStartup) async throws {
        let fixture = try ConnectorTelemetryFixture(startup: startup)
        defer { fixture.cleanup() }
        await fixture.settings.startServer()
        #expect(fixture.settings.serverState == .failed)
        #expect(fixture.client.connections.isEmpty)
        #expect(fixture.client.issues.isEmpty)
        let finishes = fixture.client.events.filter { $0.name == "foundation_evals_operation_finished" }
        #expect(finishes.count == 1)
        #expect(finishes.first?.properties["operation"] as? String == "mcp_start")
        #expect(finishes.first?.properties["outcome"] as? String == "failed")
        await fixture.runtime.prepareForTermination()
    }

    /// Intentional removal and shutdown suppress late stop and admission callbacks from drained listeners.
    @Test
    func deliberateStopDoesNotProduceFailureOrConnectionUse() async throws {
        let fixture = try ConnectorTelemetryFixture()
        defer { fixture.cleanup() }
        await fixture.settings.startServer()
        let server = try #require(fixture.factory.latest)
        await fixture.settings.removeFromCodex()
        await server.failUnexpectedly()
        await server.reportAdmission(at: .now)
        #expect(fixture.settings.serverState == .stopped)
        #expect(fixture.settings.lastConnection == nil)
        #expect(fixture.client.issues.isEmpty)
        #expect(fixture.client.connections.isEmpty)
        await fixture.runtime.prepareForTermination()
    }

    /// Settings suppress callbacks during deliberate shutdown and restore the running state if stop fails.
    @Test(arguments: [false, true])
    func settingsMarksRemovalAsStoppingBeforeInvokingServerControl(stopFails: Bool) async throws {
        let fixture = try ConnectorTelemetryFixture()
        defer { fixture.cleanup() }
        var controller: MCPSettingsController?
        controller = MCPSettingsController(serverControl: .init(start: { _ in }, stop: {
            #expect(controller?.serverState == .stopping)
            controller?.recordServerFailure(.stoppedAfterReady(ConnectorTelemetryServer.privateFailure))
            controller?.recordConnection()
            if stopFails { throw MCPServerError.stoppedAfterReady(ConnectorTelemetryServer.privateFailure) }
        }), userDefaults: fixture.defaults, credentialStore: ConnectorTelemetryFixture.credentialStore,
            configurationDirectory: fixture.directory, telemetry: fixture.telemetry)
        let settings = try #require(controller)
        await settings.startServer()
        await settings.removeFromCodex()
        #expect(settings.serverState == (stopFails ? .running : .stopped))
        #expect(fixture.client.issues.isEmpty)
        #expect(fixture.client.connections.isEmpty)
        let finish = fixture.client.events.last { $0.name == "foundation_evals_operation_finished" }
        #expect(finish?.properties["operation"] as? String == "mcp_stop")
        #expect(finish?.properties["outcome"] as? String == (stopFails ? "failed" : "succeeded"))
        controller = nil
        await fixture.runtime.prepareForTermination()
    }

    /// Connector usage and unexpected-stop diagnostics obey their independent sharing preferences.
    @Test(arguments: [true, false])
    func connectionAndStopEventsRespectSeparateConsent(usage: Bool) async throws {
        let fixture = try ConnectorTelemetryFixture(usage: usage, diagnostics: !usage)
        defer { fixture.cleanup() }
        await fixture.settings.startServer()
        let server = try #require(fixture.factory.latest)
        _ = await server.request(authenticated: true)
        await server.failUnexpectedly()
        #expect(fixture.client.connections.count == (usage ? 1 : 0))
        #expect(fixture.client.issues.count == (usage ? 0 : 1))
        #expect(fixture.telemetry.recentDiagnostics.filter { $0.event == "foundation_evals_diagnostic_issue" }.count == 1)
        await fixture.runtime.prepareForTermination()
    }

    /// An opted-out admission updates the UI without consuming the first later consented request.
    @Test
    func enablingUsageCountsTheNextAdmittedRequestOnce() async throws {
        let fixture = try ConnectorTelemetryFixture(usage: false)
        defer { fixture.cleanup() }
        await fixture.settings.startServer()
        let server = try #require(fixture.factory.latest)
        _ = await server.request(authenticated: true)
        #expect(fixture.settings.lastConnection != nil)
        #expect(fixture.client.connections.isEmpty)

        fixture.telemetry.setEnabled(true)
        #expect(fixture.client.connections.isEmpty)
        _ = await server.request(authenticated: true)
        #expect(fixture.client.connections.count == 1)
        _ = await server.request(authenticated: true)
        #expect(fixture.client.connections.count == 1)
        #expect(fixture.factory.servers.count == 1)
        await fixture.runtime.prepareForTermination()
    }
}

enum ConnectorTelemetryStartup: Sendable {
    case succeeds, throwFailure, unexpectedStop
}

@MainActor
private final class ConnectorTelemetryFixture {
    static let credential = String(repeating: "A", count: 43)
    static var credentialStore: MCPCredentialStore {
        .init(load: { credential }, save: { _ in Issue.record("Unexpected credential write") }, remove: {})
    }
    let directory: URL
    let defaults: UserDefaults
    let suiteName = "TelemetryConnectorTests.\(UUID().uuidString)"
    let client: ConnectorTelemetryClient
    let telemetry: TelemetryController
    let factory: ConnectorTelemetryFactory
    let runtime: FoundationEvalsMCPRuntime
    let settings: MCPSettingsController

    /// Creates isolated defaults, workspace storage, fake telemetry, and socket-free protocol handling.
    init(usage: Bool = true, diagnostics: Bool = true, startup: ConnectorTelemetryStartup = .succeeds) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(usage, forKey: TelemetryController.consentKey)
        defaults.set(diagnostics, forKey: TelemetryController.diagnosticsConsentKey)
        let client = ConnectorTelemetryClient()
        self.client = client
        telemetry = TelemetryController(defaults: defaults,
            configuration: .init(projectToken: "phc_test", host: "https://telemetry.invalid"),
            makeClient: { _ in client }, discardPendingCrashes: {})
        let factory = ConnectorTelemetryFactory(startup: startup)
        self.factory = factory
        let runtime = FoundationEvalsMCPRuntime(store: EvaluationStore(supportDirectory: directory),
            serverFactory: { factory.make($0) })
        self.runtime = runtime
        settings = MCPSettingsController(serverControl: .init(
            start: { try await runtime.start($0) }, stop: { await runtime.stop() }),
            userDefaults: defaults, credentialStore: Self.credentialStore, configurationDirectory: directory,
            pasteboardWriter: { _ in Issue.record("Unexpected clipboard write") }, telemetry: telemetry)
        runtime.settingsController = settings
    }

    /// Removes only the fixture's temporary files and isolated preferences.
    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class ConnectorTelemetryFactory {
    let startup: ConnectorTelemetryStartup
    var servers: [ConnectorTelemetryServer] = []
    var latest: ConnectorTelemetryServer? { servers.last }

    /// Selects the startup behavior for listeners created by this fixture.
    init(startup: ConnectorTelemetryStartup) { self.startup = startup }

    /// Retains injectable listeners so tests can deliver current and stale lifecycle callbacks.
    func make(_ configuration: MCPRuntimeServerConfiguration) -> ConnectorTelemetryServer {
        let server = ConnectorTelemetryServer(configuration: configuration, startup: startup)
        servers.append(server)
        return server
    }
}

private actor ConnectorTelemetryServer: MCPServerLifecycle {
    static let privateFailure = "private-provider.invalid/private-path secret-credential"
    let configuration: MCPRuntimeServerConfiguration
    let startup: ConnectorTelemetryStartup
    let handler: MCPProtocolHandler

    /// Wires the real authentication/admission handler to runtime callbacks without opening a socket.
    init(configuration: MCPRuntimeServerConfiguration, startup: ConnectorTelemetryStartup) {
        self.configuration = configuration
        self.startup = startup
        handler = MCPProtocolHandler(port: configuration.port, authority: configuration.authority,
            credential: configuration.credential, onRequest: configuration.onRequest)
    }

    /// Simulates successful readiness or the two startup failure paths under test.
    func start() async throws {
        switch startup {
        case .succeeds: return
        case .throwFailure: throw MCPServerError.startFailed(Self.privateFailure)
        case .unexpectedStop: await failUnexpectedly()
        }
    }

    /// Delivers late callbacks during draining to test deliberate-stop generation filtering.
    func stop() async {
        await failUnexpectedly()
        await reportAdmission(at: .now)
    }

    /// Exercises real HTTP preflight and MCP ping handling using synthetic bearer authentication.
    func request(authenticated: Bool) async -> MCPHTTPResponse {
        await handler.handle(MCPHTTPRequest(method: "POST", headers: [
            "Host": "127.0.0.1:\(configuration.port)",
            "Content-Type": "application/json",
            "MCP-Protocol-Version": MCPProtocolHandler.protocolVersion,
            "Authorization": "Bearer \(authenticated ? configuration.credential : "rejected")"
        ], body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)))
    }

    /// Injects an already-admitted request callback with a deterministic timestamp.
    func reportAdmission(at date: Date) async { await configuration.onRequest(date) }

    /// Injects an unexpected stop containing private detail that telemetry must never include.
    func failUnexpectedly() async { await configuration.onUnexpectedStop(.stoppedAfterReady(Self.privateFailure)) }
}

@MainActor
private final class ConnectorTelemetryClient: TelemetryClient {
    var events: [TelemetryEvent] = []
    var connections: [TelemetryEvent] {
        events.filter { $0.name == "intents_feature_used" && $0.properties["feature"] as? String == "mcp_connected" }
    }
    var issues: [TelemetryEvent] { events.filter { $0.name == "foundation_evals_diagnostic_issue" } }

    /// Keeps emitted events in memory without configuring a network destination.
    func capture(_ event: TelemetryEvent) { events.append(event) }
    /// The in-memory destination has no pending uploads to cancel.
    func stopAndDiscard() {}
}
