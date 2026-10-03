import Foundation
import Testing
@testable import FoundationEvals

struct MCPStoreAuthorityTests {
    @MainActor
    @Test func coordinatorVersionsEditedDefinitionsAndInvalidatesPreflight() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let coordinator = ScenarioCoordinator(supportDirectory: store.overviewStorageDirectory, evaluationStore: store)
        coordinator.configuration.containerPath = coordinator.draft.target.projectPath
        coordinator.configuration.destinationIdentifier = "physical-device-1"
        let saved = try await coordinator.freezeAndSave()
        #expect(saved.projectID == store.selectedProjectID)

        coordinator.draft.goal.requestText = "A revised approved request"
        let revised = try await coordinator.freezeAndSave()
        #expect(revised.id == saved.id)
        #expect(revised.version == saved.version + 1)
        #expect(revised.definitionDigest != saved.definitionDigest)
        #expect((try await coordinator.freezeAndSave()).version == revised.version)

        await coordinator.refreshPreflight()
        #expect(coordinator.preflight != nil)
        coordinator.configuration.testBundleIdentifier = "changed.test.bundle"
        coordinator.invalidatePreflight()
        #expect(coordinator.preflight == nil)

        coordinator.invalidParameterDraftIndices.insert(0)
        await #expect(throws: ScenarioValidationError.self) {
            _ = try await coordinator.freezeAndSave()
        }
    }

    @MainActor
    @Test func corruptScenarioDefinitionMakesProjectReportIncomplete() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let intentLabDirectory = store.overviewStorageDirectory.appending(path: "IntentLab", directoryHint: .isDirectory)
        let persistence = ScenarioPersistence(rootDirectory: intentLabDirectory)
        var definition = ScenarioDefinition.starter(projectID: store.selectedProjectID)
        definition.target.destinationIdentifier = "physical-device-1"
        definition = try definition.frozen()
        try await persistence.saveDefinition(definition)
        let path = intentLabDirectory.appending(path: "Definitions/\(definition.id.uuidString)/v\(definition.version)-\(definition.definitionDigest).json")
        try Data("{corrupt".utf8).write(to: path, options: .atomic)

        let result = await MCPStoreAuthority.make(store: store).call(
            .projectReleaseReport(.init(projectID: store.selectedProjectID))
        )
        #expect(!result.isError)
        let output = try result.structuredContent.jsonText()
        let payload = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        let report = payload?["report"] as? [String: Any]
        #expect(report?["outcome"] as? Int == Int(EvaluationReleaseCheckExit.incompleteOrIncompatibleEvidence.rawValue))
        #expect(output.contains("definition storage could not be verified"))
    }

    @MainActor
    @Test func unassignedSavedScenarioCannotVanishFromProjectGate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let persistence = ScenarioPersistence(
            rootDirectory: store.overviewStorageDirectory.appending(path: "IntentLab", directoryHint: .isDirectory)
        )
        var definition = ScenarioDefinition.starter()
        definition.target.destinationIdentifier = "physical-device-1"
        definition = try definition.frozen()
        try await persistence.saveDefinition(definition)

        let result = await MCPStoreAuthority.make(store: store).call(
            .projectReleaseReport(.init(projectID: store.selectedProjectID))
        )
        #expect(!result.isError)
        let output = try result.structuredContent.jsonText()
        let payload = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        let report = payload?["report"] as? [String: Any]
        #expect(report?["outcome"] as? Int == Int(EvaluationReleaseCheckExit.incompleteOrIncompatibleEvidence.rawValue))
        #expect(output.contains("no project assignment"))
    }

    @MainActor
    @Test func orphanedSavedScenarioRunCannotVanishFromProjectGate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let persistence = ScenarioPersistence(
            rootDirectory: store.overviewStorageDirectory.appending(path: "IntentLab", directoryHint: .isDirectory)
        )
        var definition = ScenarioDefinition.starter(projectID: store.selectedProjectID)
        definition.target.destinationIdentifier = "physical-device-1"
        definition = try definition.frozen()
        let now = Date()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: now,
            testIdentity: .init(bundleIdentifier: "dev.example.Tests", className: "Tests", methodName: "testScenario"),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: "physical-device-1",
            scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: UUID().uuidString,
            appProduct: nil, testProduct: nil
        )
        let run = ScenarioRun(
            id: invocation.id, scenarioID: definition.id, scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest, invocation: invocation,
            startedAt: now, completedAt: now,
            environment: .init(
                xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
                operatingSystem: "iOS 27", languageCode: "en", regionCode: "GB",
                timeZoneIdentifier: "Europe/London", executedAt: now
            ),
            executionStatus: .completed, outcome: .passed, laneResults: [],
            linkedFeatureRunID: nil, importedAt: now
        )
        _ = try await persistence.saveRun(run, artifactRoot: nil)

        let result = await MCPStoreAuthority.make(store: store).call(
            .projectReleaseReport(.init(projectID: store.selectedProjectID))
        )
        #expect(!result.isError)
        let output = try result.structuredContent.jsonText()
        #expect(output.contains("saved Intent Lab run(s) have no matching definition"))
        let payload = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        let report = payload?["report"] as? [String: Any]
        #expect(report?["outcome"] as? Int == Int(EvaluationReleaseCheckExit.incompleteOrIncompatibleEvidence.rawValue))
        try await persistence.saveDefinition(definition)
        let restoredDefinitionReport = await MCPStoreAuthority.make(store: store).call(
            .projectReleaseReport(.init(projectID: store.selectedProjectID))
        )
        #expect(!restoredDefinitionReport.isError)
        let restoredOutput = try restoredDefinitionReport.structuredContent.jsonText()
        #expect(restoredOutput.contains("execution journal has not accepted"))
    }

    @MainActor
    @Test func featureLinkRejectsCrossProjectAndPartiallyScoredRuns() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let evaluationCase = EvaluationCase(name: "Feature", prompt: "Fixture", expected: "Response")
        var run = makeRun(case: evaluationCase, resultCount: 2, plannedCount: 2)
        run.results[0].status = .passed
        let digest = try EvaluationSubjectEvidenceSnapshot.digest(
            instructions: "", cases: [evaluationCase], attachments: []
        )
        run.subjectEvidence = .init(instructions: "", cases: [evaluationCase], attachments: [], digest: digest)
        run.developerExecution = .init(
            runnerID: UUID(), runnerName: "Fixture", platform: "macOS", operatingSystem: "macOS 27",
            hardwareModel: "Mac", appBundleIdentifier: "com.coryparry.IntentLabFixture", appVersion: "1",
            featureID: "fixture.feature", featureVersion: "1", protocolMajorVersion: 1, protocolMinorVersion: 0
        )
        var definition = ScenarioDefinition.starter(projectID: store.selectedProjectID)
        definition.directControl.linkedFeatureRunID = run.id
        definition.directControl.linkedFeatureID = "fixture.feature"
        definition.directControl.linkedFeatureSubjectDigest = digest
        run.projectID = UUID()
        #expect(!ScenarioFeatureEvidence.isEligible(run, for: definition))
        run.projectID = store.selectedProjectID
        #expect(!ScenarioFeatureEvidence.isEligible(run, for: definition))
        run.results[1].status = .passed
        #expect(ScenarioFeatureEvidence.isEligible(run, for: definition))
        run.results[1].repetition = 1
        #expect(!ScenarioFeatureEvidence.isEligible(run, for: definition))
        run.results[1].repetition = 2
        run.developerExecution?.featureID = "different.feature"
        #expect(!ScenarioFeatureEvidence.isEligible(run, for: definition))
    }

    @MainActor
    @Test func scenarioReportRedactsSensitiveObservationsAndScreenshots() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let persistence = ScenarioPersistence(
            rootDirectory: store.overviewStorageDirectory.appending(path: "IntentLab", directoryHint: .isDirectory)
        )
        var definition = ScenarioDefinition.starter()
        definition.target.destinationIdentifier = "physical-device-1"
        definition = try definition.frozen()
        try await persistence.saveDefinition(definition)
        let app = ScenarioProductIdentity(
            bundleIdentifier: definition.target.bundleIdentifier,
            executableName: "Fixture",
            sha256: "app-sha"
        )
        let test = ScenarioProductIdentity(
            bundleIdentifier: "dev.example.FixtureUITests",
            executableName: "FixtureUITests",
            sha256: "test-sha"
        )
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString, issuedAt: .now,
            testIdentity: .init(
                bundleIdentifier: test.bundleIdentifier,
                className: "IntentLabScenarioTests",
                methodName: "testIntentLabScenario"
            ),
            harnessVersion: ScenarioInvocationIdentity.currentHarnessVersion,
            destinationIdentifier: definition.target.destinationIdentifier,
            scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: UUID().uuidString,
            appProduct: app,
            testProduct: test
        )
        let now = Date()
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
            outcome: .passed,
            laneResults: [.init(
                caseID: definition.id,
                attempt: 1,
                lane: .intentIntegration,
                executionStatus: .completed,
                outcome: .passed,
                startedAt: now,
                completedAt: now,
                observations: [
                    "selectedNoteID": .string("packing-001"),
                    "accountEmail": .string("secret@example.com"),
                    "feature.encodedValue": .string("ZW5jb2RlZC1wcml2YXRlLWV2aWRlbmNl"),
                    "feature.metadata.note": .string("private-feature-metadata"),
                ],
                assertionResults: [.init(
                    assertionID: definition.assertions[0].id,
                    passed: false,
                    observedValue: .string("assertion-secret@example.com"),
                    message: "Captured assertion-secret@example.com"
                )],
                diagnostic: "Device diagnostic diagnostic-secret@example.com",
                proposedCause: "Device cause cause-secret@example.com",
                artifacts: [.init(
                    kind: .screenshot,
                    filename: "private-screen.png",
                    relativePath: "private-screen.png",
                    contentType: "image/png",
                    byteCount: 10,
                    sha256: "screenshot-sha"
                )]
            )],
            linkedFeatureRunID: nil,
            importedAt: now,
            responseAssessments: [.init(
                assertionID: definition.assertions[0].id,
                lane: .intentIntegration,
                attempt: 1,
                passed: false,
                explanation: "Assessment quoted assessment-secret@example.com",
                assessorIdentity: "test",
                rubric: "Do not expose rubric-secret@example.com"
            )]
        )
        _ = try await persistence.saveRun(run, artifactRoot: nil)

        let payload = await MCPStoreAuthority.make(store: store).call(.getScenarioReport(.init(runID: run.id)))
        let text = try payload.structuredContent.jsonText()

        #expect(text.contains("packing-001"))
        #expect(!text.contains("secret@example.com"))
        #expect(!text.contains("assertion-secret@example.com"))
        #expect(!text.contains("assessment-secret@example.com"))
        #expect(!text.contains("rubric-secret@example.com"))
        #expect(!text.contains("diagnostic-secret@example.com"))
        #expect(!text.contains("cause-secret@example.com"))
        #expect(!text.contains("private-screen.png"))
        #expect(!text.contains("ZW5jb2RlZC1wcml2YXRlLWV2aWRlbmNl"))
        #expect(!text.contains("private-feature-metadata"))
    }

    @MainActor
    @Test func stateUsesOneAuthoritativeSuiteWhileTheUIDraftIsInvalid() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let committed = store.suite
        store.addCase()
        #expect(store.draftSuite.cases.count == 2)
        #expect(store.suite == committed)

        let authority = MCPStoreAuthority.make(store: store)
        let state = await authority.call(.getState).structuredContent.objectValue!
        let reportedSuite = state["suite"]!.objectValue!
        let workload = state["workload"]!.objectValue!

        #expect(reportedSuite["cases"]?.arrayValue?.count == committed.cases.count)
        #expect(workload["plannedSamples"] == .integer(Int64(committed.cases.count * committed.repetitions)))
        #expect(state["readinessBlocker"] == (
            store.validationIssue(for: committed).map(MCPJSONValue.string) ?? .null
        ))
    }

    @MainActor
    @Test func attachmentToolsAreBoundedAndNaturallyIdempotent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let authority = MCPStoreAuthority.make(store: store)
        let attachmentID = UUID()
        let originalRevision = store.suiteRevision
        let arguments = MCPUploadAttachmentArguments(
            id: attachmentID,
            name: "reference.txt",
            mediaType: "text/plain",
            dataBase64: Data("private body".utf8),
            expectedRevision: originalRevision
        )

        let uploaded = await authority.call(.uploadAttachment(arguments))
        #expect(outcome(uploaded) == "committed")
        let retried = await authority.call(.uploadAttachment(arguments))
        #expect(outcome(retried) == "duplicate")

        let state = await authority.call(.getState).structuredContent.objectValue!
        let attachments = state["attachments"]!.arrayValue!
        #expect(attachments.count == 1)
        #expect(attachments[0].objectValue?["text"] == nil)
        #expect(attachments[0].objectValue?["storedFilename"] == nil)
        let stateText = try MCPJSONValue.object(state).jsonText()
        #expect(!stateText.contains("private body"))
        #expect(!stateText.contains(directory.path))

        let resource = await authority.readResource(.attachment(attachmentID))
        #expect(resource.text == "private body")
        #expect(resource.blob == nil)

        let removed = await authority.call(.removeAttachment(.init(
            id: attachmentID,
            expectedRevision: store.suiteRevision,
            confirm: true
        )))
        #expect(outcome(removed) == "committed")
        let repeatedRemoval = await authority.call(.removeAttachment(.init(
            id: attachmentID,
            expectedRevision: originalRevision,
            confirm: true
        )))
        #expect(outcome(repeatedRemoval) == "duplicate")
    }

    @MainActor
    @Test func runAndHistoryPaginationAreCappedAndReportSkippedSamples() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "")
        let run = makeRun(case: evaluationCase, resultCount: 3, plannedCount: 4)
        var older = makeRun(case: evaluationCase, resultCount: 1, plannedCount: 1)
        older.startedAt = run.startedAt.addingTimeInterval(-60)
        older.completedAt = older.startedAt.addingTimeInterval(1)
        store.runs = [run, older]
        let authority = MCPStoreAuthority.make(store: store)

        let first = await authority.call(.getRun(.init(runID: run.id, cursor: nil, limit: 2)))
            .structuredContent.objectValue!["run"]!.objectValue!
        #expect(first["results"]!.arrayValue?.count == 2)
        let cursor = first["nextCursor"]!.stringValue
        #expect(cursor != nil)

        let second = await authority.call(.getRun(.init(runID: run.id, cursor: cursor, limit: 2)))
            .structuredContent.objectValue!["run"]!.objectValue!
        #expect(second["results"]!.arrayValue?.count == 1)
        #expect(second["skipped"]!.arrayValue?.count == 1)
        #expect(second["nextCursor"] == .null)

        let historyFirst = await authority.call(.listRuns(.init(cursor: nil, limit: 1, query: nil, status: nil)))
            .structuredContent.objectValue!
        #expect(historyFirst["runs"]!.arrayValue?.count == 1)
        let historyCursor = historyFirst["nextCursor"]!.stringValue
        let historySecond = await authority.call(.listRuns(.init(cursor: historyCursor, limit: 1, query: nil, status: nil)))
            .structuredContent.objectValue!
        #expect(historySecond["runs"]!.arrayValue?.count == 1)
        #expect(historySecond["nextCursor"] == .null)
    }

    @MainActor
    @Test func cancellationRequestedUsesTheAgentFacingStatusSpelling() throws {
        let operation = EvaluationRunOperation(
            id: UUID(),
            suiteRevision: "revision",
            phase: .cancellationRequested,
            completedSamples: 1,
            totalSamples: 2,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: nil
        )

        let committed = try MCPStoreAuthority.cancellationPayload(previousPhase: .running, operation: operation)
        #expect(outcome(committed) == "committed")
        #expect(committed.structuredContent.objectValue?["status"] == .string("cancellation_requested"))
        #expect(committed.structuredContent.objectValue?["run"]?.objectValue?["phase"] == .string("cancellation_requested"))

        let duplicate = try MCPStoreAuthority.cancellationPayload(
            previousPhase: .cancellationRequested,
            operation: operation
        )
        #expect(outcome(duplicate) == "duplicate")
    }

    @MainActor
    @Test func runResourceIsCanonicalAndDeletionIsDurablyIdempotent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var run = makeRun(
            case: EvaluationCase(name: "Case", prompt: "Prompt", expected: ""),
            resultCount: 1,
            plannedCount: 1
        )
        run.projectID = store.selectedProjectID
        run.suiteID = store.selectedSuiteID
        let canonicalData = try CanonicalJSON.data(for: run)
        let runURL = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        ).appending(path: "Runs/\(run.id.uuidString).json")
        try canonicalData.write(to: runURL, options: .atomic)
        let suiteDirectory = runURL.deletingLastPathComponent().deletingLastPathComponent()
        let evidenceURL = suiteDirectory.appending(path: "RunEvidence/\(run.id.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: evidenceURL, withIntermediateDirectories: true)
        try Data("private evidence".utf8).write(to: evidenceURL.appending(path: "source.bin"))
        store.runs = [run]
        let authority = MCPStoreAuthority.make(store: store)

        let resource = await authority.readResource(.run(run.id))
        #expect(!resource.isError)
        #expect(resource.mimeType == "application/json")
        #expect(resource.text == String(data: canonicalData, encoding: .utf8))
        #expect(resource.blob == nil)

        let deleted = await authority.call(.deleteRun(.init(runID: run.id, confirm: true)))
        #expect(outcome(deleted) == "committed")
        #expect(store.run(with: run.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: runURL.path))
        #expect(!FileManager.default.fileExists(atPath: evidenceURL.path))

        let duplicate = await authority.call(.deleteRun(.init(runID: run.id, confirm: true)))
        #expect(outcome(duplicate) == "duplicate")
    }

    @MainActor
    @Test func failedEvidenceCleanupRetainsADeletionRetryPath() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        var run = makeRun(
            case: EvaluationCase(name: "Case", prompt: "Prompt", expected: ""),
            resultCount: 1,
            plannedCount: 1
        )
        run.projectID = store.selectedProjectID
        run.suiteID = store.selectedSuiteID
        let suiteDirectory = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID
        )
        let runURL = suiteDirectory.appending(path: "Runs/\(run.id.uuidString).json")
        try CanonicalJSON.data(for: run).write(to: runURL, options: .atomic)
        let evidenceParent = suiteDirectory.appending(path: "RunEvidence", directoryHint: .isDirectory)
        let evidenceURL = evidenceParent.appending(path: run.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: evidenceURL, withIntermediateDirectories: true)
        try Data("private evidence".utf8).write(to: evidenceURL.appending(path: "source.bin"))
        store.runs = [run]
        let authority = MCPStoreAuthority.make(store: store)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: evidenceParent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: evidenceParent.path)
        }

        let failed = await authority.call(.deleteRun(.init(runID: run.id, confirm: true)))
        #expect(failed.isError)
        let tombstoneURL = suiteDirectory.appending(path: "RunDeletions/\(run.id.uuidString).json")
        #expect(!FileManager.default.fileExists(atPath: runURL.path))
        #expect(FileManager.default.fileExists(atPath: tombstoneURL.path))
        #expect(FileManager.default.fileExists(atPath: evidenceURL.path))
        #expect(store.run(with: run.id) == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: evidenceParent.path)
        let reloaded = EvaluationStore(supportDirectory: directory)
        #expect(reloaded.run(with: run.id) == nil)
        let reloadedAuthority = MCPStoreAuthority.make(store: reloaded)
        let retried = await reloadedAuthority.call(.deleteRun(.init(runID: run.id, confirm: true)))
        #expect(outcome(retried) == "committed")
        #expect(!FileManager.default.fileExists(atPath: runURL.path))
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL.path))
        #expect(!FileManager.default.fileExists(atPath: evidenceURL.path))
    }

    @MainActor
    @Test func analysisReadsSavedRunsWithoutMutatingSuiteOrStartingModel() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let evaluationCase = EvaluationCase(name: "Case", prompt: "Prompt", expected: "")
        let baseline = makeRun(case: evaluationCase, resultCount: 1, plannedCount: 1)
        var current = baseline
        current.id = UUID()
        store.runs = [current, baseline]
        let revision = store.suiteRevision
        let authority = MCPStoreAuthority.make(store: store)
        let call = try MCPToolCatalog.parse(name: "eval_analyze_run", arguments: .object([
            "runID": .string(current.id.uuidString),
            "baselineRunID": .string(baseline.id.uuidString)
        ]))
        let response = await authority.call(call)
        #expect(!response.isError)
        #expect(response.structuredContent.objectValue?["analysis"] != nil)
        #expect(response.structuredContent.objectValue?["comparison"] != nil)
        #expect(store.suiteRevision == revision)
        #expect(store.activeRun == nil)
        #expect(store.runs.count == 2)

        let unknownBaseline = await authority.call(.analyzeRun(.init(runID: current.id, baselineRunID: UUID())))
        #expect(unknownBaseline.isError)
        let unknownRun = await authority.call(.analyzeRun(.init(runID: UUID(), baselineRunID: nil)))
        #expect(unknownRun.isError)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func evalCheckRetryReturnsTheOwnedActiveOperationBeforeBusyValidation() async throws {
        let fixture = try LifecycleCustomModelFixture(responseDelay: 1)
        defer { fixture.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        store.draftSuite.scoringMode = .review
        store.draftSuite.modelConfiguration.provider = .customHTTP
        store.draftSuite.modelConfiguration.customProviderSettings.endpoint = fixture.endpoint(path: "/text")
        #expect(store.saveSuite())
        let authority = MCPStoreAuthority.make(store: store)
        let runID = UUID()
        let arguments = MCPCheckArguments(
            projectID: store.selectedProjectID,
            suiteID: store.selectedSuiteID,
            runID: runID,
            expectedRevision: store.suiteRevision
        )

        let started = await authority.call(.check(arguments))
        #expect(outcome(started) == "committed")
        let duplicate = await authority.call(.check(arguments))
        #expect(outcome(duplicate) == "duplicate")
        #expect(duplicate.structuredContent.objectValue?["run"]?.objectValue?["id"] == .string(runID.uuidString))

        let conflicting = await authority.call(.check(.init(
            projectID: UUID(), suiteID: store.selectedSuiteID,
            runID: runID, expectedRevision: store.suiteRevision
        )))
        #expect(conflicting.isError)
        #expect(conflicting.structuredContent.objectValue?["error"]?.objectValue?["code"] == .string("resource_conflict"))
        _ = await authority.call(.cancelRun(.init(runID: runID)))
        try await waitForRunToFinish(in: store)
    }

    @MainActor
    @Test func completedRunPollingSurvivesSuiteSelectionChanges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EvaluationStore(supportDirectory: directory)
        let projectID = store.selectedProjectID
        let originalSuiteID = store.selectedSuiteID
        var run = makeRun(
            case: EvaluationCase(name: "Owned", prompt: "Prompt", expected: ""),
            resultCount: 1,
            plannedCount: 1
        )
        run.projectID = projectID
        run.suiteID = originalSuiteID
        let runURL = EvaluationWorkspacePersistence.suiteDirectory(
            supportDirectory: directory,
            projectID: projectID,
            suiteID: originalSuiteID
        ).appending(path: "Runs/\(run.id.uuidString).json")
        try CanonicalJSON.data(for: run).write(to: runURL, options: .atomic)
        store.runs = [run]

        _ = try store.createSuite(name: "Visible elsewhere")
        #expect(store.selectedSuiteID != originalSuiteID)
        let response = await MCPStoreAuthority.make(store: store).call(.getRun(.init(
            runID: run.id, cursor: nil, limit: 50
        )))

        #expect(!response.isError)
        #expect(response.structuredContent.objectValue?["run"]?.objectValue?["id"] == .string(run.id.uuidString))
        #expect(response.structuredContent.objectValue?["run"]?.objectValue?["phase"] == .string("completed"))

        let requestBody = try JSONEncoder.sorted.encode(MCPJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(1),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string("eval_get_run"),
                "arguments": .object([
                    "runID": .string(run.id.uuidString),
                    "limit": .integer(50)
                ])
            ])
        ]))
        let protocolResponse = await MCPProtocolHandler(
            authority: MCPStoreAuthority.make(store: store)
        ).handle(MCPHTTPRequest(
            method: "POST",
            headers: [
                "Host": "127.0.0.1:17873",
                "Content-Type": "application/json",
                "MCP-Protocol-Version": "2025-06-18"
            ],
            body: requestBody
        ))
        let protocolJSON = try JSONDecoder().decode(
            MCPJSONValue.self, from: #require(protocolResponse.body)
        )
        let protocolRun = protocolJSON.objectValue?["result"]?.objectValue?["structuredContent"]?
            .objectValue?["run"]?.objectValue
        #expect(protocolResponse.status == 200)
        #expect(protocolRun?["id"] == .string(run.id.uuidString))
        #expect(protocolRun?["phase"] == .string("completed"))
    }

    @Test func analysisRejectsInvalidIdentifiersAndUnknownOptions() throws {
        for arguments: MCPJSONValue in [
            .object(["runID": .string("invalid")]),
            .object(["runID": .string(UUID().uuidString), "baselineRunID": .integer(1)]),
            .object(["runID": .string(UUID().uuidString), "runModel": .bool(true)])
        ] {
            #expect(throws: MCPToolInputError.self) {
                try MCPToolCatalog.parse(name: "eval_analyze_run", arguments: arguments)
            }
        }
    }

    private func makeRun(case evaluationCase: EvaluationCase, resultCount: Int, plannedCount: Int) -> EvaluationRun {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return EvaluationRun(
            id: UUID(),
            suiteID: UUID(),
            suiteName: "Suite",
            suiteVersion: "v1",
            instructions: "",
            criteria: "Requirement",
            scoringMode: .review,
            repetitions: plannedCount,
            judgePromptVersion: nil,
            judgePassingScore: nil,
            plannedSampleCount: plannedCount,
            suiteRevision: "revision",
            plannedCases: [evaluationCase],
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(4),
            cancelled: resultCount < plannedCount,
            terminationReason: resultCount < plannedCount ? "cancelled" : nil,
            environment: .init(operatingSystem: "Test", locale: "en_GB", model: "Test", modelContextSize: 4_096),
            attachments: [],
            results: (1...resultCount).map { repetition in
                EvaluationSampleResult(
                    caseID: evaluationCase.id,
                    caseName: evaluationCase.name,
                    repetition: repetition,
                    prompt: evaluationCase.prompt,
                    expected: "",
                    response: "Response \(repetition)",
                    status: .unscored,
                    score: nil,
                    rationale: nil,
                    durationMilliseconds: 1,
                    usage: EvaluationUsage(),
                    judgeDurationMilliseconds: nil,
                    judgeUsage: nil,
                    errorCategory: nil,
                    errorMessage: nil,
                    judgeErrorCategory: nil,
                    judgeErrorMessage: nil
                )
            }
        )
    }

    private func outcome(_ payload: MCPToolPayload) -> String? {
        payload.structuredContent.objectValue?["outcome"]?.stringValue
    }

    @MainActor
    private func waitForRunToFinish(in store: EvaluationStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!store.isRunning, "Run did not finish within ten seconds.")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MCPStoreAuthorityTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private extension MCPJSONValue {
    var arrayValue: [MCPJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}
