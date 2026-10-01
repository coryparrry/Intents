import Foundation
import Network
import Testing
@testable import FoundationEvals

struct EvaluationStoreRunLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func cancellationWhileFinalProgressIsSuspendedMarksRunCancelled() async throws {
        let fixture = try LifecycleCustomModelFixture()
        defer { fixture.stop() }
        let progressGate = FinalProgressGate()
        var suite = EvaluationSuite()
        suite.scoringMode = .exactMatch
        suite.repetitions = 1
        suite.cases = [EvaluationCase(
            name: "Final sample",
            prompt: "Return the fixture response.",
            expected: "Deterministic fixture stream."
        )]
        suite.modelConfiguration.provider = .customHTTP
        suite.modelConfiguration.customProviderSettings.endpoint = fixture.endpoint(path: "/text")

        let task = Task {
            await EvaluationRunner().run(
                id: UUID(),
                suiteRevision: "final-progress-cancellation",
                startedAt: Date(),
                suite: suite,
                images: []
            ) { _, completed, total in
                #expect(completed == total)
                await progressGate.suspend()
            }
        }

        await progressGate.waitUntilSuspended()
        task.cancel()
        await progressGate.release()
        let run = await task.value

        #expect(run.results.count == 1)
        #expect(run.cancelled)
        #expect(run.terminationReason == "cancelled")
        #expect(!run.stoppedEarly)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func exactMatchRunCompletesPersistsReloadsAndAnalyzes() async throws {
        let fixture = try LifecycleCustomModelFixture()
        defer { fixture.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runID = UUID()
        let evaluationCase = EvaluationCase(
            name: "Deterministic response",
            prompt: "Return the fixture response.",
            expected: "Deterministic fixture stream."
        )
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.name = "Lifecycle fixture"
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [evaluationCase]
        store.draftSuite.repetitions = 1
        store.draftSuite.modelConfiguration.provider = .customHTTP
        store.draftSuite.modelConfiguration.customProviderSettings.endpoint = fixture.endpoint(path: "/text")

        #expect(store.saveSuite())
        let revision = try store.currentSuiteRevision()
        let started = try store.startRun(id: runID, expectedRevision: revision)
        #expect(started.phase == .running)
        #expect(started.totalSamples == 1)

        try await waitForRunToFinish(in: store)

        let completed = try #require(store.run(with: runID))
        let result = try #require(completed.results.first)
        #expect(completed.results.count == 1)
        #expect(completed.terminationReason == nil)
        #expect(!completed.cancelled)
        #expect(result.response == evaluationCase.expected)
        #expect(result.status == .passed)
        #expect(result.errorCategory == nil)
        #expect(store.runStatus(id: runID)?.phase == .completed)
        let suiteDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        )
        #expect(!FileManager.default.fileExists(atPath: suiteDirectory.appending(path: "active-run.json").path))
        #expect(FileManager.default.fileExists(
            atPath: suiteDirectory.appending(path: "Runs/\(runID.uuidString).json").path
        ))

        let reloadedStore = EvaluationStore(supportDirectory: directory)
        let reloadedRun = try #require(reloadedStore.run(with: runID))
        #expect(reloadedRun.suiteRevision == revision)
        #expect(reloadedRun.results.first?.response == evaluationCase.expected)
        #expect(reloadedRun.results.first?.status == .passed)
        #expect(reloadedRun.execution?.configuration == store.suite.modelConfiguration)

        let analysis = EvaluationRunAnalysis(run: reloadedRun)
        #expect(analysis.runID == runID)
        #expect(analysis.plannedSampleCount == 1)
        #expect(analysis.completedSampleCount == 1)
        #expect(analysis.missingSampleCount == 0)
        #expect(analysis.scoredSampleCount == 1)
        #expect(analysis.passedSampleCount == 1)
        #expect(analysis.failedSampleCount == 0)
        #expect(analysis.errorSampleCount == 0)
        #expect(analysis.scoredPassRate == 1)
        #expect(analysis.subjectUsage.requestCount == 1)
        #expect(analysis.subjectUsage.outputTokens == 4)
        #expect(analysis.cases.first?.caseID == evaluationCase.id)
        #expect(analysis.cases.first?.repetitionVariation == .insufficientScoredSamples)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func providerFailurePersistsStoppedRunForReloadAndAnalysis() async throws {
        let fixture = try LifecycleCustomModelFixture()
        defer { fixture.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runID = UUID()
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .review
        store.draftSuite.repetitions = 2
        store.draftSuite.modelConfiguration.provider = .customHTTP
        store.draftSuite.modelConfiguration.customProviderSettings.endpoint = fixture.endpoint(path: "/error")

        #expect(store.saveSuite())
        let revision = try store.currentSuiteRevision()
        _ = try store.startRun(id: runID, expectedRevision: revision)
        try await waitForRunToFinish(in: store)

        let stopped = try #require(store.run(with: runID))
        #expect(stopped.results.count == 1)
        #expect(stopped.plannedResultCount == 2)
        #expect(stopped.terminationReason == "customProviderError")
        #expect(stopped.stoppedEarly)
        #expect(!stopped.cancelled)
        #expect(stopped.results.first?.status == .error)
        #expect(stopped.results.first?.errorCategory == "customProviderError")
        #expect(store.runStatus(id: runID)?.phase == .stopped)

        let reloadedStore = EvaluationStore(supportDirectory: directory)
        let reloadedRun = try #require(reloadedStore.run(with: runID))
        #expect(reloadedStore.runStatus(id: runID)?.phase == .stopped)
        #expect(reloadedRun.terminationReason == "customProviderError")
        #expect(reloadedRun.results.first?.errorCategory == "customProviderError")

        let analysis = EvaluationRunAnalysis(run: reloadedRun)
        #expect(analysis.plannedSampleCount == 2)
        #expect(analysis.completedSampleCount == 1)
        #expect(analysis.missingSampleCount == 1)
        #expect(analysis.scoredSampleCount == 0)
        #expect(analysis.errorSampleCount == 1)
        #expect(analysis.cases.first?.missingSampleCount == 1)
        #expect(analysis.cases.first?.errorSampleCount == 1)
    }

    @MainActor
    private func waitForRunToFinish(in store: EvaluationStore) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while store.isRunning {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for the evaluation store run to finish.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "EvaluationStoreRunLifecycleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor FinalProgressGate {
    private var isSuspended = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

final class LifecycleCustomModelFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FoundationEvalsTests.LifecycleHTTPFixture")
    private let ready = DispatchSemaphore(value: 0)
    private let responseDelay: TimeInterval
    private(set) var port: UInt16 = 0

    init(responseDelay: TimeInterval = 0) throws {
        self.responseDelay = responseDelay
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = self.listener.port?.rawValue ?? 0
                self.ready.signal()
            case .failed:
                self.ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
            listener.cancel()
            throw LifecycleCustomModelFixtureError.failedToListen
        }
    }

    func endpoint(path: String) -> String {
        "http://127.0.0.1:\(port)\(path)"
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var request = accumulated
            if let data { request.append(data) }
            guard error == nil else {
                connection.cancel()
                return
            }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.receiveRequest(on: connection, accumulated: request)
                }
                return
            }
            self.respond(to: request, on: connection)
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let requestLine = String(decoding: request, as: UTF8.self)
            .components(separatedBy: "\r\n")
            .first ?? ""
        let body: String
        if requestLine.contains(" /error ") {
            body = #"{"kind":"error","code":"fixtureBackendFailure","message":"Deterministic fixture backend failure."}"# + "\n"
        } else {
            body = [
                #"{"kind":"response","action":"append","content":"Deterministic fixture stream.","tokenCount":4}"#,
                #"{"kind":"usage","usageTarget":"response","usage":{"inputTokens":12,"cachedInputTokens":0,"outputTokens":4,"reasoningTokens":0}}"#
            ].joined(separator: "\n") + "\n"
        }
        let response = """
            HTTP/1.1 200 OK\r
            Content-Type: application/x-ndjson\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
        let send: @Sendable () -> Void = {
            connection.send(
                content: Data(response.utf8),
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
        if responseDelay > 0 {
            queue.asyncAfter(deadline: .now() + responseDelay, execute: send)
        } else {
            send()
        }
    }
}

enum LifecycleCustomModelFixtureError: Error {
    case failedToListen
}
