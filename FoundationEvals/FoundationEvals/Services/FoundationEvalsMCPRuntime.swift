import Foundation

protocol MCPServerLifecycle: Sendable {
    /// Starts the listener and returns when startup succeeds; throws when it cannot become ready.
    func start() async throws
    /// Stops the listener and waits for its shutdown work to finish.
    func stop() async
}

extension MCPServer: MCPServerLifecycle {}

struct MCPRuntimeServerConfiguration: Sendable {
    var port: Int
    var authority: MCPAuthority
    var credential: String
    var onRequest: @Sendable (Date) async -> Void
    var onUnexpectedStop: @Sendable (MCPServerError) async -> Void
}

@MainActor
final class FoundationEvalsMCPRuntime {
    typealias ServerFactory = @MainActor @Sendable (MCPRuntimeServerConfiguration) -> any MCPServerLifecycle

    private let store: EvaluationStore
    private let control: EvaluationAppControl
    private let serverFactory: ServerFactory
    private var server: (any MCPServerLifecycle)?
    private var stopping: (id: UUID, task: Task<Void, Never>)?
    private var serverGeneration: UUID?
    private var isClosing = false
    weak var settingsController: MCPSettingsController?

    /// Connects an evaluation store and shared controls to an injectable server factory. Creates
    /// default app controls when none are supplied.
    init(
        store: EvaluationStore,
        control: EvaluationAppControl? = nil,
        serverFactory: @escaping ServerFactory = { configuration in
            MCPServer(
                port: configuration.port,
                authority: configuration.authority,
                credential: configuration.credential,
                onRequest: configuration.onRequest,
                onUnexpectedStop: configuration.onUnexpectedStop
            )
        }
    ) {
        self.store = store
        self.control = control ?? EvaluationAppControl(store: store)
        self.serverFactory = serverFactory
    }

    /// Starts one authenticated store-backed server and associates callbacks with its generation.
    /// Rejects starts during shutdown or an existing lifecycle, clears failed startup state, and throws
    /// if that generation stops before startup completes.
    func start(_ configuration: CodexMCPConfiguration) async throws {
        guard !isClosing else { throw MCPServerError.stoppedAfterReady(nil) }
        guard server == nil, serverGeneration == nil, stopping == nil else { throw MCPServerError.alreadyRunning }
        let generation = UUID()
        serverGeneration = generation
        let server = serverFactory(MCPRuntimeServerConfiguration(
            port: configuration.port,
            authority: MCPStoreAuthority.make(store: store, control: control),
            credential: configuration.credential,
            onRequest: { [weak self] date in
                await self?.serverDidReceiveRequest(generation: generation, at: date)
            },
            onUnexpectedStop: { [weak self] error in
                await self?.serverDidStop(generation: generation, error: error)
            }
        ))
        self.server = server
        do {
            try await server.start()
        } catch {
            if serverGeneration == generation {
                serverGeneration = nil
                self.server = nil
            }
            throw error
        }
        guard serverGeneration == generation else {
            throw MCPServerError.stoppedAfterReady(nil)
        }
    }

    /// Stops the current server and waits for a shared teardown task, preventing a new start until
    /// draining finishes. Repeated calls join the same teardown.
    func stop() async {
        let drain: (id: UUID, task: Task<Void, Never>)
        if let stopping {
            drain = stopping
        } else {
            guard let server else {
                serverGeneration = nil
                return
            }
            self.server = nil
            serverGeneration = nil
            drain = (UUID(), Task { await server.stop() })
            stopping = drain
        }
        await drain.task.value
        if stopping?.id == drain.id { stopping = nil }
    }

    /// Closes mutation entry points, stops the server, and drains runner, App Intent, production,
    /// evaluation, and MCP tasks before termination.
    func prepareForTermination() async {
        isClosing = true
        store.beginClosing()
        control.mcp.beginClosing()
        await stop()
        await control.runners.closeAndWait()
        await control.appIntentTesting.closeAndWait()
        await control.production.closeAndWait()
        await store.closeAndWait()
        await control.mcp.closeAndWait()
    }

    /// Forwards authenticated request admission only while its listener generation remains current,
    /// preventing drained requests from updating connection time or usage for a replacement listener.
    private func serverDidReceiveRequest(generation: UUID, at date: Date) {
        guard serverGeneration == generation else { return }
        settingsController?.recordConnection(at: date)
    }

    /// Clears only the stopped server's current generation and reports its failure to settings,
    /// ignoring callbacks from older instances.
    private func serverDidStop(generation: UUID, error: MCPServerError) {
        guard serverGeneration == generation else { return }
        serverGeneration = nil
        server = nil
        settingsController?.recordServerFailure(error)
    }
}
