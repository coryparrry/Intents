import Foundation

protocol MCPServerLifecycle: Sendable {
    func start() async throws
    func stop() async
}

extension MCPServer: MCPServerLifecycle {}

struct MCPRuntimeServerConfiguration: Sendable {
    var port: Int
    var authority: MCPAuthority
    var onRequest: @Sendable (Date) async -> Void
    var onUnexpectedStop: @Sendable (MCPServerError) async -> Void
}

@MainActor
final class FoundationEvalsMCPRuntime {
    typealias ServerFactory = @MainActor @Sendable (MCPRuntimeServerConfiguration) -> any MCPServerLifecycle

    private let store: EvaluationStore
    private let serverFactory: ServerFactory
    private var server: (any MCPServerLifecycle)?
    private var serverGeneration: UUID?
    weak var settingsController: MCPSettingsController?

    init(
        store: EvaluationStore,
        serverFactory: @escaping ServerFactory = { configuration in
            MCPServer(
                port: configuration.port,
                authority: configuration.authority,
                onRequest: configuration.onRequest,
                onUnexpectedStop: configuration.onUnexpectedStop
            )
        }
    ) {
        self.store = store
        self.serverFactory = serverFactory
    }

    func start(_ configuration: CodexMCPConfiguration) async throws {
        guard server == nil, serverGeneration == nil else { throw MCPServerError.alreadyRunning }
        let generation = UUID()
        serverGeneration = generation
        let server = serverFactory(MCPRuntimeServerConfiguration(
            port: configuration.port,
            authority: MCPStoreAuthority.make(store: store),
            onRequest: { [weak self] date in
                await self?.settingsController?.recordConnection(at: date)
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

    func stop() async {
        guard let server else {
            serverGeneration = nil
            return
        }
        self.server = nil
        serverGeneration = nil
        await server.stop()
    }

    func prepareForTermination() async {
        store.saveSuite()
        store.cancelRun()
        await stop()
    }

    private func serverDidStop(generation: UUID, error: MCPServerError) {
        guard serverGeneration == generation else { return }
        serverGeneration = nil
        server = nil
        settingsController?.recordServerFailure(error)
    }
}
