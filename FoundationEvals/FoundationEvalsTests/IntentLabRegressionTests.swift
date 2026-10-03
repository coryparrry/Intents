import Foundation
import Testing
import Darwin
@testable import FoundationEvals

struct IntentLabRegressionTests {
    @Test func testProcessDeadlineIncludesDirectLaneButOmitsNotApplicableSiri() {
        let definition = deadlineDefinition(
            directLane: true,
            siriLane: false,
            siriAttemptCount: 3,
            deadlineSeconds: 60
        )

        #expect(XcodeTestDeadlineBudget.seconds(for: definition) == 135)
    }

    @Test func testProcessDeadlineBudgetsThreeSiriAttemptsAndDirectLane() {
        let definition = deadlineDefinition(
            directLane: true,
            siriLane: true,
            siriAttemptCount: 3,
            deadlineSeconds: 60
        )

        #expect(XcodeTestDeadlineBudget.seconds(for: definition) == 540)
    }

    @Test func testProcessDeadlineUsesConfiguredScenarioWaitForEveryLane() {
        let definition = deadlineDefinition(
            directLane: true,
            siriLane: true,
            siriAttemptCount: 3,
            deadlineSeconds: 30
        )

        #expect(XcodeTestDeadlineBudget.seconds(for: definition) == 420)
    }

    @Test func xcresultManifestFindsUUIDExportsAndPrefersFinalEvidence() throws {
        let invocationID = UUID()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpointFile = "\(UUID().uuidString).json"
        let finalFile = "\(UUID().uuidString).json"
        try Data("{}".utf8).write(to: root.appending(path: checkpointFile))
        try Data("{}".utf8).write(to: root.appending(path: finalFile))
        func manifest(_ names: [String]) throws -> Data {
            try JSONSerialization.data(withJSONObject: [[
                "testIdentifier": "IntentLabScenarioTests/testIntentLabScenario()",
                "attachments": names.map { name in
                    ["exportedFileName": name == "checkpoint" ? checkpointFile : finalFile,
                     "suggestedHumanReadableName": "IntentLabEvidence-\(invocationID.uuidString)-\(name)_0_\(UUID().uuidString).json"]
                },
            ]])
        }

        let checkpoint = XcodeTestExecutor.evidenceAttachments(
            in: try manifest(["checkpoint"]), root: root, invocationID: invocationID
        )
        #expect(checkpoint.map(\.url.lastPathComponent) == [checkpointFile])
        #expect(checkpoint.first?.isCheckpoint == true)
        let preferred = XcodeTestExecutor.evidenceAttachments(
            in: try manifest(["checkpoint", "final"]), root: root, invocationID: invocationID
        )
        #expect(preferred.map(\.url.lastPathComponent) == [finalFile])
    }

    @Test func xcresultScreenshotExportsKeepEnvelopeFilenamesAndBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let exported = "\(UUID().uuidString).png"
        let bytes = Data("screenshot-bytes".utf8)
        try bytes.write(to: root.appending(path: exported))
        let manifest = try JSONSerialization.data(withJSONObject: [[
            "testIdentifier": "IntentLabScenarioTests/testIntentLabScenario()",
            "attachments": [["exportedFileName": exported,
                "suggestedHumanReadableName": "IntentLabArtifact-\(id.uuidString)_0.png"]],
        ]])
        try XcodeTestExecutor.restoreArtifactFilenames(in: manifest, root: root)
        #expect(try Data(contentsOf: root.appending(path: "IntentLabArtifact-\(id.uuidString).png")) == bytes)
    }

    @Test func xcresultFailureMessageIsExtractedWithoutPromotingItToEvidence() {
        let nodes: [String: Any] = [
            "testNodes": [["children": [[
                "nodeType": "Failure Message",
                "name": "Timed out waiting for Siri to activate",
            ]]]]
        ]
        #expect(XcodeTestExecutor.failureMessages(in: nodes) == ["Timed out waiting for Siri to activate"])
        #expect(ScenarioDiagnosticClassifier.checkpointDiagnostic(for: "Timed out waiting for Siri to activate")
            .contains("approve it, then rerun"))
    }

    @Test func injectedSemanticAssessmentFinalizesLaneAndRunOutcome() async throws {
        var definition = ScenarioDefinition.starter()
        let assertion = ScenarioAssertion(
            kind: .semanticRubric,
            observationKey: "specificResponse",
            explanation: "The response confirms that the packing note opened.",
            applicableLanes: [.siri]
        )
        definition.assertions = [assertion]
        definition.coverage.intentIntegration = .notApplicable
        definition = try definition.frozen()
        let now = Date()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(),
            nonce: UUID().uuidString,
            issuedAt: now,
            testIdentity: .init(
                bundleIdentifier: "dev.example.FixtureUITests",
                className: "IntentLabScenarioTests",
                methodName: "testIntentLabScenario"
            ),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: "physical-device-1",
            scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: UUID().uuidString
        )
        let run = ScenarioRun(
            id: invocation.id,
            scenarioID: definition.id,
            scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest,
            invocation: invocation,
            startedAt: now,
            completedAt: now,
            environment: .init(
                xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
                operatingSystem: "iOS 27", languageCode: "en", regionCode: "GB",
                timeZoneIdentifier: "Europe/London", executedAt: now
            ),
            executionStatus: .completed,
            outcome: .needsReview,
            laneResults: [.init(
                caseID: definition.id,
                attempt: 1,
                lane: .siri,
                executionStatus: .completed,
                outcome: .needsReview,
                startedAt: now,
                completedAt: now,
                observations: ["specificResponse": .string("Opened the packing note"), "visibleResponse": .string("Unrelated response")],
                assertionResults: [.init(
                    assertionID: assertion.id,
                    passed: false,
                    observedValue: .string("Opened the packing note"),
                    message: "Pending semantic review."
                )]
            )],
            linkedFeatureRunID: nil,
            importedAt: now
        )

        let assessed = try await ScenarioResponseAssessmentService.assess(
            run,
            definition: definition
        ) { receivedAssertion, response, _ in
            #expect(receivedAssertion.id == assertion.id)
            #expect(response == "Opened the packing note")
            return ScenarioSemanticAssessment(passed: true, explanation: "The response satisfies the rubric.")
        }

        #expect(assessed.laneResults[0].outcome == .passed)
        #expect(assessed.laneResults[0].assertionResults[0].passed)
        #expect(assessed.outcome == .passed)
        #expect(assessed.responseAssessments?.first?.passed == true)
    }

    @MainActor
    @Test func frozenExecutionDefinitionSurvivesLaterDraftEdits() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        let coordinator = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        coordinator.configuration.containerPath = "/tmp/Fixture.xcodeproj"
        coordinator.configuration.destinationIdentifier = "physical-device-1"
        coordinator.configuration.generatedResourceDirectory = "/tmp/Generated"
        let frozen = try await coordinator.freezeAndSave()
        coordinator.draft.goal.requestText = "A different request while the device is running"
        #expect(frozen.goal.requestText != coordinator.draft.goal.requestText)
        #expect(coordinator.definitions.first?.definitionDigest == frozen.definitionDigest)
        #expect(coordinator.definitions.first?.goal.requestText == frozen.goal.requestText)
    }

    @MainActor
    @Test func corruptRecoveryJournalPreventsScenarioRun() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journals = root.appending(path: "IntentLab/Journals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        try Data("invalid journal".utf8).write(to: journals.appending(path: "corrupt.json"))
        let store = EvaluationStore(supportDirectory: root)
        let coordinator = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)

        await coordinator.load()
        #expect(!coordinator.hasLoaded)
        await coordinator.run()
        #expect(coordinator.notice?.contains("must load successfully") == true)
        let saved = try await ScenarioPersistence(rootDirectory: root.appending(path: "IntentLab"))
            .loadDefinitions()
        #expect(saved.isEmpty)
    }

    @MainActor
    @Test func approvingWordingCreatesANewFrozenVersion() async throws {
        let root = try temporaryDirectory()
        let store = EvaluationStore(supportDirectory: root)
        let coordinator = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        await coordinator.load()
        coordinator.configuration.containerPath = "/tmp/Fixture.xcodeproj"
        coordinator.configuration.destinationIdentifier = "physical-device-1"
        coordinator.configuration.generatedResourceDirectory = "/tmp/Generated"
        try await coordinator.freezeAndSave()
        let originalVersion = coordinator.draft.version

        coordinator.approveSuggestion(.init(
            requestText: "Open my packing note in the fixture app",
            category: "paraphrase",
            note: "Approved alternate wording"
        ))

        #expect(coordinator.draft.version == originalVersion + 1)
        #expect(coordinator.draft.definitionDigest.isEmpty)
        #expect(coordinator.draft.goal.requestText == "Open my packing note in the fixture app")

        try await coordinator.freezeAndSave()
        let reloaded = ScenarioPersistence(
            rootDirectory: store.overviewStorageDirectory.appending(path: "IntentLab", directoryHint: .isDirectory)
        )
        let saved = try await reloaded.loadDefinitions().filter { $0.id == coordinator.draft.id }
        #expect(saved.map(\.version).sorted() == [originalVersion, originalVersion + 1])
        #expect(saved.last(where: { $0.version == originalVersion + 1 })?.goal.requestText == "Open my packing note in the fixture app")
    }

    @MainActor
    @Test func executionSetupReloadsButProjectTrustDoesNot() async throws {
        let root = try temporaryDirectory()
        let store = EvaluationStore(supportDirectory: root)
        let persistence = ScenarioPersistence(
            rootDirectory: store.overviewStorageDirectory.appending(path: "IntentLab", directoryHint: .isDirectory)
        )
        var olderDefinition = ScenarioDefinition.starter()
        olderDefinition.target.projectPath = "/tmp/Old.xcodeproj"
        olderDefinition.target.scheme = "OldScheme"
        olderDefinition.target.destinationIdentifier = "old-device"
        olderDefinition = try olderDefinition.frozen()
        try await persistence.saveDefinition(olderDefinition)
        let coordinator = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        await coordinator.load()
        coordinator.configuration.containerPath = "/tmp/Fixture.xcodeproj"
        coordinator.configuration.scheme = "Fixture"
        coordinator.configuration.destinationIdentifier = "physical-device-1"
        coordinator.configuration.testBundleIdentifier = "dev.example.FixtureUITests"
        coordinator.configuration.generatedResourceDirectory = "/tmp/FixtureGenerated"
        coordinator.projectTrusted = true
        await coordinator.refreshPreflight()

        let reloaded = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        await reloaded.load()

        #expect(reloaded.configuration.testBundleIdentifier == "dev.example.FixtureUITests")
        #expect(reloaded.configuration.generatedResourceDirectory == "/tmp/FixtureGenerated")
        #expect(reloaded.configuration.containerPath == "/tmp/Fixture.xcodeproj")
        #expect(reloaded.configuration.scheme == "Fixture")
        #expect(reloaded.configuration.destinationIdentifier == "physical-device-1")
        #expect(reloaded.projectTrusted == false)
    }

    @MainActor
    @Test func reloadingRenamedScenarioSelectsLatestVersionOfLastRunScenario() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvaluationStore(supportDirectory: root)
        let persistence = ScenarioPersistence(
            rootDirectory: store.overviewStorageDirectory.appending(path: "IntentLab", directoryHint: .isDirectory)
        )
        var original = ScenarioDefinition.starter()
        original.name = "Open the packing note"
        original.target.destinationIdentifier = "physical-device-1"
        original = try original.frozen()
        var renamed = original
        renamed.version = 2
        renamed.name = "Negative control — wrong expected note"
        renamed = try renamed.frozen()
        try await persistence.saveDefinition(original)
        try await persistence.saveDefinition(renamed)

        let withoutRun = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        await withoutRun.load()
        #expect(withoutRun.draft.id == renamed.id)
        #expect(withoutRun.draft.version == renamed.version)

        var unrelated = ScenarioDefinition.starter()
        unrelated.name = "Zulu unrelated scenario"
        unrelated.target.destinationIdentifier = "physical-device-1"
        unrelated = try unrelated.frozen()
        try await persistence.saveDefinition(unrelated)
        let now = Date()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: now,
            testIdentity: .init(bundleIdentifier: "dev.example.FixtureUITests",
                                className: "IntentLabScenarioTests", methodName: "testIntentLabScenario"),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: "physical-device-1", scenarioDigest: renamed.definitionDigest,
            resultBundleIdentity: "IntentLab.xcresult"
        )
        let failedIntent = ScenarioLaneResult(
            caseID: renamed.id, attempt: 1, lane: .intentIntegration,
            executionStatus: .completed, outcome: .failed,
            startedAt: now, completedAt: now
        )
        let failedSiri = (1...(renamed.coverage.siriAttemptCount ?? 3)).map { attempt in
            ScenarioLaneResult(
                caseID: renamed.id, attempt: attempt, lane: .siri,
                executionStatus: .completed, outcome: .failed,
                startedAt: now, completedAt: now
            )
        }
        let run = ScenarioRun(
            id: invocation.id, scenarioID: renamed.id, scenarioVersion: renamed.version,
            scenarioDigest: renamed.definitionDigest, invocation: invocation,
            startedAt: now, completedAt: now,
            environment: .init(xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
                               operatingSystem: "iOS 27", languageCode: "en", regionCode: "GB",
                               timeZoneIdentifier: "Europe/London", executedAt: now),
            executionStatus: .completed, outcome: .failed, laneResults: [failedIntent] + failedSiri,
            linkedFeatureRunID: nil, importedAt: now
        )
        _ = try await persistence.saveRun(run, artifactRoot: nil)

        let reloaded = ScenarioCoordinator(supportDirectory: root, evaluationStore: store)
        await reloaded.load()
        #expect(reloaded.selectedRunID == run.id)
        #expect(reloaded.draft.id == renamed.id)
        #expect(reloaded.draft.version == renamed.version)
        #expect(reloaded.draft.name == renamed.name)
    }

    @MainActor
    @Test func failedOrUnobservedFinalEvidenceKeepsDeviceQuarantined() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let executor = XcodeTestExecutor(workDirectory: root.appending(path: "Executor"), persistence: persistence)
        var definition = ScenarioDefinition.starter()
        definition = try definition.frozen()
        let now = Date()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: now,
            testIdentity: .init(bundleIdentifier: "dev.example.FixtureUITests",
                                className: "IntentLabScenarioTests", methodName: "testIntentLabScenario"),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: "physical-device-1", scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: "IntentLab.xcresult"
        )
        let journal = ScenarioExecutionJournal(
            phase: .stopped, invocation: invocation, scenarioID: definition.id,
            scenarioVersion: definition.version, resultBundlePath: "", derivedDataPath: "",
            buildLogPath: "", intendedExecutable: "", intendedArguments: [],
            processIdentifier: nil, processStartedAt: nil, updatedAt: now, recoveryReason: nil
        )
        let siri = ScenarioLaneResult(
            caseID: definition.id, attempt: 1, lane: .siri,
            executionStatus: .timedOut, outcome: .notObserved,
            startedAt: now, completedAt: now, observations: [:], assertionResults: []
        )
        let run = ScenarioRun(
            id: invocation.id, scenarioID: definition.id, scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest, invocation: invocation,
            startedAt: now, completedAt: now,
            environment: .init(xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
                               operatingSystem: "iOS 27", languageCode: "en", regionCode: "GB",
                               timeZoneIdentifier: "Europe/London", executedAt: now),
            executionStatus: .timedOut, outcome: .notObserved, laneResults: [siri],
            linkedFeatureRunID: nil, importedAt: now
        )
        let final = ScenarioEvidenceAttachment(url: root.appending(path: "final.json"), name: "IntentLabEvidence-final")
        #expect(!ScenarioCoordinator.canReleaseDevice(
            processExitCode: 1, attachments: [final], importedRuns: [run]
        ))
        #expect(!ScenarioCoordinator.canReleaseDevice(
            processExitCode: 0, attachments: [final], importedRuns: [run]
        ))
        var complete = run
        complete.executionStatus = .completed
        complete.outcome = .passed
        complete.laneResults[0].executionStatus = .completed
        complete.laneResults[0].outcome = .passed
        #expect(ScenarioCoordinator.canReleaseDevice(
            processExitCode: 0, attachments: [final], importedRuns: [complete]
        ))
        let cancelled = try #require(ScenarioCoordinator.evidenceForCommit([complete], cancelled: true).first)
        #expect(cancelled.executionStatus == .invalidEvidence)
        #expect(cancelled.outcome == .needsReview)
        #expect(!ScenarioCoordinator.canReleaseDevice(
            processExitCode: 0, attachments: [final], importedRuns: [cancelled]
        ))
        try await executor.finishEvidenceValidation(journal: journal, accepted: false)
        #expect(await executor.reservation(for: invocation.destinationIdentifier) != nil)
    }

    @Test func cancellationBetweenBuildAndTestStopsNextProcessBeforeLaunch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let executor = XcodeTestExecutor(workDirectory: root.appending(path: "Executor"), persistence: persistence)
        let definition = try ScenarioDefinition.starter().frozen()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: Date(),
            testIdentity: .init(bundleIdentifier: "dev.example.FixtureUITests",
                                className: "IntentLabScenarioTests", methodName: "testIntentLabScenario"),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: "physical-device-1", scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: "IntentLab.xcresult"
        )
        let journal = ScenarioExecutionJournal(
            phase: .preparing, invocation: invocation, scenarioID: definition.id,
            scenarioVersion: definition.version, resultBundlePath: "", derivedDataPath: "",
            buildLogPath: "", intendedExecutable: "/bin/sh", intendedArguments: [],
            processIdentifier: nil, processStartedAt: nil, updatedAt: Date(), recoveryReason: nil
        )
        try await executor.persistPreparingJournal(journal)
        let cancelled = await executor.cancelActiveExecution(grace: .milliseconds(10))
        #expect(cancelled?.phase == .recoveryRequired)
        let marker = root.appending(path: "launched")
        do {
            _ = try await executor.runProcess(
                executable: "/bin/sh", arguments: ["-c", "touch \(marker.path)"],
                logURL: root.appending(path: "process.log"), invocationID: invocation.id,
                destinationIdentifier: invocation.destinationIdentifier, journal: journal,
                appendLog: false
            )
            Issue.record("A cancelled invocation launched another process.")
        } catch XcodeTestExecutorError.cancelled {
            // The cancellation is expected before process launch.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(await executor.reservation(for: invocation.destinationIdentifier) != nil)
    }

    @Test func journalWriteFailureStopsLaunchedProcess() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let executor = XcodeTestExecutor(workDirectory: root.appending(path: "Executor"), persistence: persistence)
        let definition = try ScenarioDefinition.starter().frozen()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: Date(),
            testIdentity: .init(bundleIdentifier: "dev.example.FixtureUITests",
                                className: "IntentLabScenarioTests", methodName: "testIntentLabScenario"),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: "physical-device-1", scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: "IntentLab.xcresult"
        )
        let journal = ScenarioExecutionJournal(
            phase: .preparing, invocation: invocation, scenarioID: definition.id,
            scenarioVersion: definition.version, resultBundlePath: "", derivedDataPath: "",
            buildLogPath: "", intendedExecutable: "/bin/sh", intendedArguments: [],
            processIdentifier: nil, processStartedAt: nil, updatedAt: Date(), recoveryReason: nil
        )
        let blockedJournal = root.appending(path: "Journals/\(invocation.id.uuidString).json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blockedJournal, withIntermediateDirectories: true)
        let launchedProcess = ProcessIDRecorder()
        do {
            _ = try await executor.runProcess(
                executable: "/bin/sleep", arguments: ["10"],
                logURL: root.appending(path: "process.log"), invocationID: invocation.id,
                destinationIdentifier: invocation.destinationIdentifier, journal: journal,
                appendLog: false,
                onProcessLaunched: { launchedProcess.record($0) }
            )
            Issue.record("The blocked journal unexpectedly saved.")
        } catch {
            let processID = try #require(launchedProcess.value)
            let processCheck = kill(processID, 0)
            let processError = errno
            #expect(processCheck == -1)
            #expect(processError == ESRCH)
            #expect(!(await executor.hasActiveExecution()))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "IntentLabRegressionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private final class ProcessIDRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Int32?

        var value: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }

        func record(_ processID: Int32) {
            lock.lock()
            defer { lock.unlock() }
            storedValue = processID
        }
    }

    private func deadlineDefinition(
        directLane: Bool,
        siriLane: Bool,
        siriAttemptCount: Int,
        deadlineSeconds: Double
    ) -> ScenarioDefinition {
        var definition = ScenarioDefinition.starter()
        definition.coverage.intentIntegration = directLane ? .required : .notApplicable
        definition.coverage.siri = siriLane ? .required : .notApplicable
        definition.coverage.siriAttemptCount = siriAttemptCount
        definition.safety.deadlineSeconds = deadlineSeconds
        return definition
    }
}
