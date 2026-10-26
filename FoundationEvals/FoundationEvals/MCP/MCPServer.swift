import Foundation
import Hummingbird
import HTTPTypes
import Logging

actor MCPServer {
    private let port: Int
    private let maximumBodyBytes: Int
    private let handler: MCPProtocolHandler
    private let onUnexpectedStop: (@Sendable (MCPServerError) async -> Void)?
    private var serviceTask: Task<Void, Never>?
    private var stopping: (id: UUID, task: Task<Void, Never>)?
    private var generation: UUID?

    /// Creates a loopback HTTP server and protocol handler with shared body/concurrency limits,
    /// credential, and request/lifecycle callbacks. Does not bind a socket until start.
    init(
        port: Int = 17_873,
        authority: MCPAuthority,
        credential: String,
        maximumBodyBytes: Int = 16 * 1_024 * 1_024,
        maximumConcurrentRequests: Int = 8,
        onRequest: (@Sendable (Date) async -> Void)? = nil,
        onUnexpectedStop: (@Sendable (MCPServerError) async -> Void)? = nil
    ) {
        self.port = port
        self.maximumBodyBytes = maximumBodyBytes
        self.onUnexpectedStop = onUnexpectedStop
        self.handler = MCPProtocolHandler(
            port: port,
            authority: authority,
            credential: credential,
            maximumBodyBytes: maximumBodyBytes,
            maximumConcurrentRequests: maximumConcurrentRequests,
            onRequest: onRequest
        )
    }

    /// Binds the loopback listener and waits for its ready signal. Rejects overlapping starts or
    /// teardown, drains a failed startup, and reports later unexpected stops through the callback.
    func start() async throws {
        guard serviceTask == nil, stopping == nil else { throw MCPServerError.alreadyRunning }

        let startup = MCPServerStartupSignal()
        let adapter = MCPHummingbirdAdapter(handler: handler, maximumBodyBytes: maximumBodyBytes)
        let router = Router()
        router.post("/mcp") { request, context in
            await adapter.response(for: request, context: context)
        }
        router.get("/mcp") { request, context in
            await adapter.response(for: request, context: context)
        }
        router.delete("/mcp") { request, context in
            await adapter.response(for: request, context: context)
        }

        var logger = Logger(label: "FoundationEvals.MCP")
        logger.logLevel = .warning
        let application = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: port),
                serverName: "FoundationEvals-MCP"
            ),
            onServerRunning: { _ in await startup.succeed() },
            logger: logger
        )

        let runGeneration = UUID()
        generation = runGeneration
        let task = Task { [weak self] in
            let terminalError: MCPServerError?
            do {
                try await application.run()
                terminalError = .stoppedAfterReady(nil)
            } catch is CancellationError {
                terminalError = .stoppedAfterReady("The listener was cancelled.")
            } catch {
                terminalError = .stoppedAfterReady(error.localizedDescription)
            }

            if await startup.didSucceed {
                await self?.didStop(generation: runGeneration, unexpectedError: terminalError)
            } else {
                switch terminalError {
                case .stoppedAfterReady(.some(let message)):
                    await startup.fail(.startFailed(message))
                default:
                    await startup.fail(.stoppedBeforeReady)
                }
                await self?.didStop(generation: runGeneration, unexpectedError: nil)
            }
        }
        serviceTask = task

        do {
            try await startup.wait()
        } catch {
            task.cancel()
            if generation == runGeneration {
                serviceTask = nil
                generation = nil
            }
            await task.value
            throw error
        }
    }

    /// Cancels the listener and waits for its service task, sharing one teardown task among concurrent
    /// callers. Keeps teardown ownership until the listener and requests drain.
    func stop() async {
        let drain: (id: UUID, task: Task<Void, Never>)
        if let stopping {
            drain = stopping
        } else {
            guard let task = serviceTask else { return }
            serviceTask = nil
            generation = nil
            // Keep teardown owned until the listener and its requests have drained.
            drain = (UUID(), Task { task.cancel(); await task.value })
            stopping = drain
        }
        await drain.task.value
        // Any waiter may return first; it must release its completed drain,
        // without clearing a later stop that another caller has already begun.
        if stopping?.id == drain.id { stopping = nil }
    }

    /// Clears the current listener generation after termination and invokes its unexpected-stop
    /// callback. Ignores stale generations and intentional stops whose ownership was already cleared.
    private func didStop(
        generation stoppedGeneration: UUID,
        unexpectedError: MCPServerError?
    ) async {
        guard generation == stoppedGeneration else { return }
        generation = nil
        serviceTask = nil
        if let unexpectedError {
            await onUnexpectedStop?(unexpectedError)
        }
    }
}

enum MCPServerError: LocalizedError, Sendable {
    case alreadyRunning
    case stoppedBeforeReady
    case startFailed(String)
    case stoppedAfterReady(String?)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "The MCP server is already running."
        case .stoppedBeforeReady: "The MCP server stopped before it began listening."
        case .startFailed(let message): "The MCP server could not start: \(message)"
        case .stoppedAfterReady(let message):
            if let message {
                "The MCP server stopped unexpectedly: \(message)"
            } else {
                "The MCP server stopped unexpectedly."
            }
        }
    }
}

private struct MCPHummingbirdAdapter: Sendable {
    let handler: MCPProtocolHandler
    let maximumBodyBytes: Int

    /// Adapts HTTP headers and performs preflight before collecting a bounded request body. Releases
    /// admission on collection failure and returns 413; otherwise delegates protocol handling with the
    /// reserved admission.
    func response(for request: Request, context: BasicRequestContext) async -> Response {
        var headers: [String: String] = [:]
        for field in request.headers {
            let name = field.name.canonicalName
            if let existing = headers[name] {
                headers[name] = existing + "," + field.value
            } else {
                headers[name] = field.value
            }
        }
        if headers["host"] == nil, let authority = request.head.authority {
            headers["host"] = authority
        }

        let requestHead = MCPHTTPRequest(method: request.method.rawValue, headers: headers)
        let admission: MCPRequestAdmission
        switch await handler.preflight(requestHead) {
        case .rejected(let response):
            return makeResponse(response)
        case .admitted(let value):
            admission = value
        }

        let body: Data
        do {
            let buffer = try await request.body.collect(upTo: maximumBodyBytes + 1)
            body = Data(buffer.readableBytesView)
        } catch {
            await handler.abandon(admission)
            return makeResponse(.empty(413))
        }

        let response = await handler.handleAdmitted(
            MCPHTTPRequest(method: request.method.rawValue, headers: headers, body: body),
            admission: admission
        )
        return makeResponse(response)
    }

    /// Converts protocol response headers and optional bytes into a Hummingbird response, omitting
    /// invalid header names.
    private func makeResponse(_ response: MCPHTTPResponse) -> Response {
        var fields = HTTPFields()
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            guard let fieldName = HTTPField.Name(name) else { continue }
            fields.append(HTTPField(name: fieldName, value: value))
        }
        guard let data = response.body else {
            return Response(status: .init(code: response.status), headers: fields)
        }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return Response(
            status: .init(code: response.status),
            headers: fields,
            body: .init(byteBuffer: buffer)
        )
    }
}

private actor MCPServerStartupSignal {
    private var result: Result<Void, MCPServerError>?
    private var continuation: CheckedContinuation<Void, any Error>?

    var didSucceed: Bool {
        guard case .success? = result else { return false }
        return true
    }

    /// Waits for the one startup outcome or returns its previously resolved result. Designed for a
    /// single pending startup waiter.
    func wait() async throws {
        if let result {
            return try result.get()
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Resolves startup successfully; later resolutions are ignored.
    func succeed() {
        resolve(.success(()))
    }

    /// Resolves startup with the supplied listener error; later resolutions are ignored.
    func fail(_ error: MCPServerError) {
        resolve(.failure(error))
    }

    /// Stores the first startup result and resumes its pending continuation exactly once.
    private func resolve(_ result: Result<Void, MCPServerError>) {
        guard self.result == nil else { return }
        self.result = result
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result.mapError { $0 as any Error })
        }
    }
}
