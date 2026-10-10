import Darwin
import Foundation
import Network
import Testing
@testable import FoundationEvals

struct EvaluationStoreRunLifecycleTests {
    @Test
    func lifecycleFixtureFramesRequestBodiesByBytes() {
        let header = Data("POST /text HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n".utf8)
        #expect(LifecycleCustomModelFixture.requestState(for: Data(header.dropLast())) == .incomplete)
        #expect(LifecycleCustomModelFixture.requestState(for: header) == .incomplete)
        #expect(LifecycleCustomModelFixture.requestState(for: header + Data([0xC3])) == .incomplete)
        #expect(LifecycleCustomModelFixture.requestState(for: header + Data("é".utf8)) == .complete)
        #expect(LifecycleCustomModelFixture.requestState(for: header + Data("abc".utf8)) == .invalid)
        #expect(LifecycleCustomModelFixture.requestState(for: Data("GET /text HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)) == .complete)
        for length in ["-1", "+1", "bad", "999999999999999999999999", "1048576", "1\r\nContent-Length: 1"] {
            let malformed = Data("POST /text HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n".utf8)
            #expect(LifecycleCustomModelFixture.requestState(for: malformed) == .invalid)
        }
        #expect(LifecycleCustomModelFixture.requestState(for: Data("POST /text HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .invalid)
        #expect(LifecycleCustomModelFixture.requestState(for: Data("POST /text HTTP/1.1\r\ncontent-length: 0\r\n\r\n".utf8)) == .complete)
    }

    @Test(.timeLimit(.minutes(1)))
    func lifecycleFixtureWaitsForFinalBodyFragmentAndReturnsCleanEOF() throws {
        let fixture = try LifecycleCustomModelFixture()
        defer { fixture.stop() }
        let fd = try lifecycleSocket(port: fixture.port)
        defer { Darwin.close(fd) }
        let partial = Data("POST /text HTTP/1.1\r\nHost: localhost\r\nContent-Length: 6\r\n\r\nabc".utf8)
        try sendLifecycleBytes(partial, to: fd)
        var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        // The old fixture replied at the header delimiter. Hold the body incomplete
        // long enough to observe that response rather than coalescing every fragment.
        try #require(Darwin.poll(&readiness, 1, 200) == 0)
        try sendLifecycleBytes(Data("def".utf8), to: fd)
        try #require(Darwin.shutdown(fd, SHUT_WR) == 0)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = Darwin.recv(fd, &buffer, buffer.count, 0)
            try #require(received >= 0)
            if received == 0 { break }
            response.append(contentsOf: buffer.prefix(received))
            try #require(response.count < 1024 * 1024)
        }
        let text = String(decoding: response, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Deterministic fixture stream."))
        let split = try #require(response.range(of: Data("\r\n\r\n".utf8)))
        let headers = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        let length = try #require(headers.components(separatedBy: "\r\n").first { $0.hasPrefix("Content-Length: ") })
        #expect(Int(length.dropFirst("Content-Length: ".count)) == response.count - split.upperBound)
    }

    @Test(.timeLimit(.minutes(1)))
    func lifecycleFixtureRejectsEOFBeforeDeclaredBodyFinishes() throws {
        let fixture = try LifecycleCustomModelFixture()
        defer { fixture.stop() }
        let fd = try lifecycleSocket(port: fixture.port)
        defer { Darwin.close(fd) }
        try sendLifecycleBytes(Data("POST /text HTTP/1.1\r\nContent-Length: 6\r\n\r\nabc".utf8), to: fd)
        try #require(Darwin.shutdown(fd, SHUT_WR) == 0)
        var byte: UInt8 = 0
        let received = Darwin.recv(fd, &byte, 1, 0)
        let receiveError = errno
        #expect(received == 0 || (received == -1 && receiveError == ECONNRESET))
    }

    @Test(.timeLimit(.minutes(1)))
    func lifecycleFixtureCompletesURLSessionUploadsAndStreams() async throws {
        let fixture = try LifecycleCustomModelFixture()
        defer { fixture.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for _ in 0..<12 {
            var request = URLRequest(url: try #require(URL(string: fixture.endpoint(path: "/text"))))
            request.httpMethod = "POST"
            request.httpBody = Data(repeating: 0x61, count: 128 * 1024)
            request.timeoutInterval = 5
            let (bytes, response) = try await session.bytes(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            #expect(body.count == response.expectedContentLength)
            #expect(String(decoding: body, as: UTF8.self).contains("Deterministic fixture stream."))
        }
    }

    private func lifecycleSocket(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        do {
            var noSignal: Int32 = 1
            try #require(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0)
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            try #require(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
            try #require(setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(connected == 0)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func sendLifecycleBytes(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                try #require(count > 0)
                sent += count
            }
        }
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func scenarioFeatureSuiteRegistrationPreservesSelectionAndRejectsChangedContract() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let projectID = store.selectedProjectID
        let visibleSuiteID = store.selectedSuiteID
        let visibleDraft = store.draftSuite
        let visibleSelection = store.selection
        var scenarioSuite = EvaluationSuite()
        scenarioSuite.name = "Scenario feature"
        scenarioSuite.scoringMode = .exactMatch
        scenarioSuite.cases = [EvaluationCase(name: "Frozen", prompt: "request", expected: "RESULT")]

        let revision = try store.ensureScenarioFeatureSuite(projectID: projectID, suite: scenarioSuite)
        #expect(revision == (try EvaluationStore.revision(for: scenarioSuite)))
        #expect(try store.ensureScenarioFeatureSuite(projectID: projectID, suite: scenarioSuite) == revision)
        #expect(store.selectedProjectID == projectID)
        #expect(store.selectedSuiteID == visibleSuiteID)
        #expect(store.draftSuite == visibleDraft)
        #expect(store.selection == visibleSelection)

        scenarioSuite.cases[0].expected = "CHANGED"
        #expect(throws: EvaluationStoreError.self) {
            try store.ensureScenarioFeatureSuite(projectID: projectID, suite: scenarioSuite)
        }
        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.projects.first { $0.id == projectID }?.suites.contains {
            $0.id == scenarioSuite.id
        } == true)
        #expect(reloaded.selectedSuiteID == visibleSuiteID)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func snapshotFeatureRunKeepsOriginalWorkspaceWhenSelectionChanges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [EvaluationCase(name: "Frozen", prompt: "request", expected: "RESULT")]
        #expect(store.saveSuite())
        let projectID = store.selectedProjectID
        let snapshot = store.suite
        let revision = try store.currentSuiteRevision()
        let otherSuiteID = try store.createSuite(name: "Other")
        try store.switchSuite(id: snapshot.id)
        let gate = FinalProgressGate()
        let runID = UUID()
        let task = Task {
            try await store.runFeatureAdapterSnapshot(
                id: runID, projectID: projectID, suite: snapshot,
                expectedRevision: revision,
                adapter: ClosureFeatureAdapter(displayName: "Frozen fixture") { _ in
                    await gate.suspend()
                    return "RESULT"
                }
            )
        }
        await gate.waitUntilSuspended()
        try store.switchSuite(id: otherSuiteID)
        await gate.release()
        let run = try await task.value
        #expect(store.selectedSuiteID == otherSuiteID)
        #expect(run.id == runID)
        #expect(run.projectID == projectID)
        #expect(run.suiteID == snapshot.id)
        #expect(run.suiteRevision == revision)
        #expect(run.results.first?.status == .passed)
        #expect(EvaluationStore(supportDirectory: directory).run(with: runID)?.suiteID == snapshot.id)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func snapshotSaveRetryDoesNotRepeatAppAction() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SnapshotWriterGate()
        let store = EvaluationStore(supportDirectory: directory, runWriter: { data, url in
            if writer.shouldFail { throw SnapshotWriterError.forced }
            try data.write(to: url, options: .atomic)
        })
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [EvaluationCase(name: "Saved", prompt: "request", expected: "RESULT")]
        #expect(store.saveSuite())
        let snapshot = store.suite
        let projectID = store.selectedProjectID
        let revision = try store.currentSuiteRevision()
        let runID = UUID()
        let invocations = SnapshotInvocationCount()
        do {
            _ = try await store.runFeatureAdapterSnapshot(
                id: runID, projectID: projectID, suite: snapshot,
                expectedRevision: revision,
                adapter: ClosureFeatureAdapter(displayName: "Save retry fixture") { _ in
                    await invocations.increment()
                    return "RESULT"
                }
            )
            Issue.record("Expected the first history save to fail.")
        } catch let error as EvaluationStoreError {
            guard case .persistence = error else { Issue.record("Unexpected error: \(error)"); return }
        }
        #expect(await invocations.count == 1)
        writer.shouldFail = false
        let retried = try store.retrySnapshotRunSave(
            id: runID, projectID: projectID, suiteID: snapshot.id
        )
        let saved = try #require(retried)
        #expect(saved.results.first?.status == .passed)
        #expect(await invocations.count == 1)
        #expect(EvaluationStore(supportDirectory: directory).run(with: runID)?.id == runID)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func cancelledSnapshotRunPersistsCancelledOutcome() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [EvaluationCase(name: "Cancelled", prompt: "request", expected: "RESULT")]
        #expect(store.saveSuite())
        let snapshot = store.suite
        let projectID = store.selectedProjectID
        let revision = try store.currentSuiteRevision()
        let gate = FinalProgressGate()
        let runID = UUID()
        let task = Task {
            try await store.runFeatureAdapterSnapshot(
                id: runID, projectID: projectID, suite: snapshot,
                expectedRevision: revision,
                adapter: ClosureFeatureAdapter(displayName: "Cancellation fixture") { _ in
                    await gate.suspend()
                    try Task.checkCancellation()
                    return "RESULT"
                }
            )
        }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.release()
        let run = try await task.value
        #expect(run.cancelled)
        #expect(run.terminationReason == "cancelled")
        #expect(EvaluationStore(supportDirectory: directory).run(with: runID)?.cancelled == true)
    }

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
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
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
        queue.sync {
            stopped = true
            listener.cancel()
            let owned = Array(connections.values)
            connections.removeAll()
            owned.forEach { $0.cancel() }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.finish(connection)
        }
        receiveRequest(on: connection, accumulated: Data())
    }

    enum RequestState: Equatable {
        case incomplete, complete, invalid
    }

    static func requestState(for request: Data) -> RequestState {
        let limit = 1024 * 1024
        guard request.count <= limit else { return .invalid }
        guard let delimiter = request.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let headers = String(data: request[..<delimiter.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        var contentLength: Int?
        for line in headers.components(separatedBy: "\r\n").dropFirst() {
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return .invalid }
            let name = fields[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding" { return .invalid }
            if name == "content-length" {
                guard contentLength == nil, !value.isEmpty,
                      value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let length = Int(value), length <= limit - delimiter.upperBound else { return .invalid }
                contentLength = length
            }
        }
        let received = request.count - delimiter.upperBound
        let expected = contentLength ?? 0
        if received > expected { return .invalid }
        return received == expected ? .complete : .incomplete
    }

    private func finish(_ connection: NWConnection) {
        guard connections.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        connection.cancel()
    }

    private func drainUntilClosed(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, complete, error in
            guard let self, self.connections[ObjectIdentifier(connection)] != nil else { return }
            if complete || error != nil {
                self.finish(connection)
            } else {
                self.drainUntilClosed(on: connection)
            }
        }
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.connections[ObjectIdentifier(connection)] != nil else { return }
            var request = accumulated
            if let data { request.append(data) }
            guard error == nil else { self.finish(connection); return }
            switch Self.requestState(for: request) {
            case .invalid:
                self.finish(connection)
            case .incomplete:
                if isComplete { self.finish(connection) }
                else { self.receiveRequest(on: connection, accumulated: request) }
            case .complete:
                self.respond(to: request, on: connection)
            }
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
        let send: @Sendable () -> Void = { [weak self] in
            guard let self, !self.stopped,
                  self.connections[ObjectIdentifier(connection)] != nil else { return }
            connection.send(
                content: Data(response.utf8),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    guard let self, self.connections[ObjectIdentifier(connection)] != nil else { return }
                    if error != nil { self.finish(connection) }
                    else { self.drainUntilClosed(on: connection) }
                }
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

private enum SnapshotWriterError: Error {
    case forced
}

private final class SnapshotWriterGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true

    var shouldFail: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); defer { lock.unlock() }; failing = newValue }
    }
}

private actor SnapshotInvocationCount {
    private(set) var count = 0

    func increment() { count += 1 }
}
