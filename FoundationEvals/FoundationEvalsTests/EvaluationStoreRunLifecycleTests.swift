import Foundation
import Network
import Testing
@testable import FoundationEvals

struct EvaluationStoreRunLifecycleTests {
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func standaloneFeatureCloseJoinsAdapterCleanupAndTerminalSave() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [
            EvaluationCase(name: "Completed", prompt: "first", expected: "FIRST"),
            EvaluationCase(name: "Held", prompt: "second", expected: "LATE"),
            EvaluationCase(name: "Must not run", prompt: "third", expected: "NEVER")
        ]
        try #require(store.saveSuite())
        let revision = try store.currentSuiteRevision()
        let entered = FeatureLifecycleSignal(), cancelled = FeatureLifecycleSignal()
        let cleanupAllowed = FeatureLifecycleSignal()
        let cancellationWait = AsyncStream<Void>.makeStream()
        defer { cancellationWait.continuation.finish() }
        let invocations = SnapshotInvocationCount()
        let id = UUID()
        let caller = Task { @MainActor in
            try await store.runFeatureAdapter(
                id: id, expectedRevision: revision,
                adapter: ClosureFeatureAdapter(displayName: "Held direct integration") { input in
                    await invocations.increment()
                    if input.prompt == "first" { return "FIRST" }
                    #expect(input.prompt == "second")
                    await entered.open()
                    var iterator = cancellationWait.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    #expect(Task.isCancelled)
                    await cancelled.open()
                    // The real adapter still owns cleanup after cancellation.
                    // Its late output must survive the terminal history save.
                    await cleanupAllowed.wait()
                    return "LATE"
                }
            )
        }
        await entered.wait()
        var closed = false
        let closing = Task { @MainActor in
            await store.closeAndWait()
            closed = true
        }
        await cancelled.wait()
        #expect(!closed)
        #expect(store.isRunning)
        #expect(await invocations.count == 2)
        await #expect(throws: EvaluationStoreError.self) {
            try await store.runFeatureAdapter(
                expectedRevision: revision,
                adapter: ClosureFeatureAdapter(displayName: "Must remain closed") { _ in
                    Issue.record("A new action ran after store closing began.")
                    return "NEVER"
                }
            )
        }
        await cleanupAllowed.open()
        await closing.value

        // Read durable history before joining the API caller. closeAndWait
        // itself must guarantee that the child saved its terminal outcome.
        let retained = try #require(EvaluationStore(supportDirectory: directory).run(with: id))
        #expect(closed)
        #expect(!store.isRunning)
        #expect(retained.cancelled)
        #expect(retained.terminationReason == "cancelled")
        #expect(retained.results.map(\.response) == ["FIRST", "LATE"])
        #expect(retained.results.last?.errorCategory == "lateAfterCancellation")
        #expect(await invocations.count == 2)
        let completed = try await caller.value
        #expect(completed.id == retained.id)
        await store.closeAndWait()
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func featureAssessmentImagePreflightFailureRetainsCompletedOutput(removeImage: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try CompatibleJudgeFixture(mode: .valid)
        defer { fixture.stop() }
        let store = EvaluationStore(supportDirectory: directory)
        let connection = EvaluationJudgeConnection(
            id: UUID(), name: "Preflight judge", kind: .localCompatible,
            baseURL: fixture.baseURL, modelID: "judge-fixture"
        )
        try store.saveJudgeConnection(connection, apiKey: nil)
        store.draftSuite.scoringMode = .modelJudge
        store.draftSuite.criteria = "The response is accurate and complete."
        store.draftSuite.cases = [EvaluationCase(name: "Completed", prompt: "request", expected: "RESULT")]
        store.draftSuite.modelConfiguration.provider = .customHTTP
        store.draftSuite.modelConfiguration.customProviderSettings.supportsVision = true
        store.draftSuite.judgeConfiguration = .init(
            mode: .connection, connectionID: connection.id, includeReferenceAttachments: false
        )
        store.approveExternalJudgeDisclosure()
        try #require(store.saveSuite())
        let imageData = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let imported = try await store.importAttachment(
            id: UUID(), name: "reference.png", mediaType: "image/png", data: imageData,
            expectedRevision: store.suiteRevision
        )
        let runID = UUID()
        let revision = try store.currentSuiteRevision()
        let evidenceDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID
        ).appending(path: "RunEvidence/\(runID.uuidString)")
        let invocations = SnapshotInvocationCount()
        let adapter = ClosureFeatureAdapter(displayName: "Completed before image failure") { _ in
            await invocations.increment()
            let images = try FileManager.default.contentsOfDirectory(
                at: evidenceDirectory, includingPropertiesForKeys: nil
            )
            try #require(images.count == 1)
            let image = try #require(images.first)
            if removeImage {
                try FileManager.default.removeItem(at: image)
            } else {
                try Data("changed historical bytes".utf8).write(to: image, options: .atomic)
            }
            return "RESULT"
        }

        let run = try await store.runFeatureAdapter(id: runID, expectedRevision: revision, adapter: adapter)

        #expect(run.results.first?.response == "RESULT")
        #expect(run.results.first?.status == .unscored)
        #expect(run.terminationReason == "assessmentUnavailable")
        #expect(!run.cancelled)
        #expect(run.selectedAssessment == nil)
        #expect(run.subjectEvidence?.hasValidDigest == true)
        #expect(fixture.completionRequestCount == 0)
        #expect(try store.attachmentData(id: imported.attachment.id).data == imageData)
        let retained = try #require(EvaluationStore(supportDirectory: directory).run(with: runID))
        #expect(retained.results.first?.response == "RESULT")
        #expect(retained.terminationReason == "assessmentUnavailable")
        let retried = try await store.runFeatureAdapter(id: runID, expectedRevision: revision, adapter: adapter)
        #expect(retried.id == retained.id)
        #expect(await invocations.count == 1)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func standaloneFeatureKeepsCompletedSamplesAcrossProcessInterruption() async throws {
        let directory = try temporaryDirectory()
        let recoveredDirectory = directory.appendingPathExtension("recovered")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: recoveredDirectory)
        }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [
            EvaluationCase(name: "First", prompt: "first", expected: "RESULT"),
            EvaluationCase(name: "Second", prompt: "second", expected: "RESULT")
        ]
        try #require(store.saveSuite())
        let id = UUID()
        let run = try await store.runFeatureAdapter(
            id: id, expectedRevision: store.currentSuiteRevision(),
            adapter: ClosureFeatureAdapter(displayName: "Durable feature") { _ in "RESULT" }
        ) { completed, _ in
            guard completed == 1 else { return }
            do {
                // Reopen a disk snapshot taken while the original process has
                // completed only one action. Recovery must not invoke the app.
                try FileManager.default.copyItem(at: directory, to: recoveredDirectory)
                await MainActor.run {
                    let recovered = EvaluationStore(supportDirectory: recoveredDirectory)
                    let interrupted = recovered.run(with: id)
                    #expect(interrupted?.results.map(\.response) == ["RESULT"])
                    #expect(interrupted?.terminationReason == "interrupted")
                    #expect(interrupted?.plannedSampleCount == 2)
                }
            } catch { Issue.record("Could not snapshot the in-progress feature run: \(error)") }
        }
        #expect(run.results.count == 2)
        #expect(run.results.allSatisfy { $0.status == .passed })
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func runtimeTerminationJoinsTheRunAndPersistsCancellation() async throws {
        let fixture = try LifecycleCustomModelFixture(responseDelay: 5)
        defer { fixture.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [EvaluationCase(name: "Shutdown", prompt: "request", expected: "RESULT")]
        store.draftSuite.modelConfiguration.provider = .customHTTP
        store.draftSuite.modelConfiguration.customProviderSettings.endpoint = fixture.endpoint(path: "/text")
        try #require(store.saveSuite())
        let id = UUID()
        _ = try store.startRun(id: id, expectedRevision: store.currentSuiteRevision())
        await FoundationEvalsMCPRuntime(store: store).prepareForTermination()
        #expect(!store.isRunning)
        #expect(EvaluationStore(supportDirectory: directory).run(with: id)?.cancelled == true)
        #expect(throws: EvaluationStoreError.self) {
            try store.startRun(id: UUID(), expectedRevision: store.currentSuiteRevision())
        }
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func cancellationStillStopsRunWhenCheckpointCannotBeWritten() async throws {
        let fixture = try LifecycleCustomModelFixture(responseDelay: 5)
        defer { fixture.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [EvaluationCase(name: "Cancel", prompt: "request", expected: "RESULT")]
        store.draftSuite.modelConfiguration.provider = .customHTTP
        store.draftSuite.modelConfiguration.customProviderSettings.endpoint = fixture.endpoint(path: "/text")
        try #require(store.saveSuite())
        let runID = UUID()
        _ = try store.startRun(id: runID, expectedRevision: store.currentSuiteRevision())
        let checkpoint = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory, projectID: store.selectedProjectID, suiteID: store.selectedSuiteID
        ).appending(path: "active-run.json")
        try FileManager.default.removeItem(at: checkpoint)
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
        // A directory at the file destination simulates a failed checkpoint
        // without relying on permission bits or the account running the test.
        #expect(throws: EvaluationStoreError.self) { try store.cancelRun(id: runID) }
        #expect(store.runStatus(id: runID)?.phase == .cancellationRequested)
        try FileManager.default.removeItem(at: checkpoint)
        try await waitForRunToFinish(in: store)
        #expect(store.run(with: runID)?.cancelled == true)
        #expect(store.runStatus(id: runID)?.phase == .cancelled)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func featureSnapshotUsesFeatureAdmissionInsteadOfUnusedDesktopProvider() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var featureSuite = EvaluationSuite()
        featureSuite.scoringMode = .exactMatch
        featureSuite.cases = [EvaluationCase(name: "Feature", prompt: "request", expected: "RESULT")]
        featureSuite.modelConfiguration.provider = .customHTTP
        featureSuite.modelConfiguration.customProviderSettings.endpoint = "unused-desktop-endpoint"
        #expect(store.validationIssue(for: featureSuite, includeModelReadiness: false) != nil)
        let revision = try store.ensureScenarioFeatureSuite(projectID: store.selectedProjectID, suite: featureSuite)
        let run = try await store.runFeatureAdapterSnapshot(
            id: UUID(), projectID: store.selectedProjectID, suite: featureSuite,
            expectedRevision: revision,
            adapter: ClosureFeatureAdapter(displayName: "Independent app feature") { input in
                #expect(input.prompt == "request")
                return "RESULT"
            }
        )
        #expect(run.results.first?.status == .passed)
        #expect(EvaluationStore(supportDirectory: directory).run(with: run.id)?.id == run.id)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func legacyFeatureRunRejectsConversationItCannotTransmit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .exactMatch
        store.draftSuite.cases = [EvaluationCase(name: "Conversation", prompt: "Recall it", expected: "RESULT")]
        store.draftSuite.cases[0].conversation.setupTurns = [.init(prompt: "Remember the meeting is Friday.")]
        try #require(store.saveSuite())
        let feature = DeveloperFeatureDescriptor(
            id: "feature", displayName: "Feature", version: "1",
            inputTypeName: String(reflecting: DeveloperTextFeatureInput.self),
            outputTypeName: String(reflecting: DeveloperFeatureOutput.self)
        )
        let identity = DeveloperRunnerIdentity(
            id: UUID(), displayName: "Fixture", platform: .iPhone,
            operatingSystem: "iOS 27", hardwareModel: "iPhone",
            appBundleIdentifier: "example.fixture", appVersion: "1"
        )
        let runner = DeveloperRunnerSnapshot(identity: identity, features: [feature], state: .connected)
        let client = DeveloperRunnerClient(desktopID: UUID(), trustStoreURL: directory.appending(path: "trust.json"))
        defer { client.shutdown() }
        do {
            _ = try await store.runDeveloperFeature(
                expectedRevision: store.currentSuiteRevision(), runner: runner, feature: feature, client: client
            )
            Issue.record("A conversation must not be silently omitted from the app request.")
        } catch let error as EvaluationStoreError {
            guard case .invalidSuite(let message) = error else { throw error }
            #expect(message.contains("conversation history"))
        }
        #expect(store.runs.isEmpty)
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

private actor FeatureLifecycleSignal {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
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
