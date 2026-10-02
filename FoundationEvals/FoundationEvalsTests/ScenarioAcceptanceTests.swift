import Foundation
import Testing
@testable import FoundationEvals

@Suite(.serialized)
struct ScenarioAcceptanceTests {
    @Test func ledgerFailureLeavesSavedRunUnacceptedAfterRelaunch() async throws {
        let root = temporaryDirectory().appending(path: "IntentLab", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (definition, run, _) = try fixture()
        try await persistence.saveDefinition(definition)
        _ = try await persistence.saveRun(run, artifactRoot: nil)
        // A directory at the ledger path makes its atomic write fail after run.json exists.
        try FileManager.default.createDirectory(
            at: root.appending(path: "import-ledger.json"), withIntermediateDirectories: true
        )
        await #expect(throws: Error.self) {
            try await persistence.saveLedger(.init())
        }
        let relaunched = ScenarioPersistence(rootDirectory: root)
        let stored = try #require(await relaunched.loadRuns().first)
        #expect(stored.acceptanceStatus == .pending)
        #expect(ScenarioReleaseCheckEvaluator.report(definition: definition, run: stored)
            .failures.contains { $0.contains("acceptance receipt") })
        try await assertMCPRejects(runID: run.id, root: root)
    }

    @Test func journalFailureLeavesSavedRunUnacceptedAfterRelaunch() async throws {
        let root = temporaryDirectory().appending(path: "IntentLab", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (definition, run, journal) = try fixture()
        try await persistence.saveDefinition(definition)
        _ = try await persistence.saveRun(run, artifactRoot: nil)
        try await persistence.saveLedger(.init())
        try FileManager.default.createDirectory(
            at: root.appending(path: "Journals/\(journal.id.uuidString).json"),
            withIntermediateDirectories: true
        )
        await #expect(throws: Error.self) {
            try await persistence.saveJournal(journal)
        }
        let relaunched = ScenarioPersistence(rootDirectory: root)
        let stored = try #require(await relaunched.loadRuns().first)
        #expect(stored.acceptanceStatus == .pending)
        #expect(ScenarioReleaseCheckEvaluator.report(definition: definition, run: stored)
            .failures.contains { $0.contains("acceptance receipt") })
        try await assertMCPRejectsUnreadableJournal(runID: run.id, root: root)
    }

    @Test func receiptNeedsValidatedJournalAndBindsImmutableRunBytes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (definition, run, journal) = try fixture()
        _ = try await persistence.saveRun(run, artifactRoot: nil)
        await #expect(throws: Error.self) {
            _ = try await persistence.acceptRun(run, journal: journal)
        }
        try await persistence.saveLedger(.init())
        try await persistence.saveJournal(journal)
        let accepted = try await persistence.acceptRun(run, journal: journal)
        #expect(accepted.acceptanceStatus == .accepted)
        #expect(ScenarioReleaseCheckEvaluator.report(definition: definition, run: accepted).outcome == .passed)
        #expect(try await ScenarioPersistence(rootDirectory: root).loadRuns().first?.acceptanceStatus == .accepted)
        let receiptPath = root.appending(path: "Runs/\(run.scenarioID.uuidString)/\(run.id.uuidString)/acceptance.json")
        let receiptBytes = try Data(contentsOf: receiptPath)
        let retried = try await persistence.acceptRun(run, journal: journal)
        #expect(retried.acceptanceStatus == .accepted)
        #expect(try Data(contentsOf: receiptPath) == receiptBytes)
        let path = root.appending(path: "Runs/\(run.scenarioID.uuidString)/\(run.id.uuidString)/run.json")
        var altered = try Data(contentsOf: path)
        altered.append(0x20)
        try altered.write(to: path, options: .atomic)
        #expect(try await ScenarioPersistence(rootDirectory: root).loadRuns().first?.acceptanceStatus == .pending)
    }

    @Test func persistedJournalIdentityMustMatchBeforeAcceptanceReturns() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (definition, run, journal) = try fixture()
        _ = try await persistence.saveRun(run, artifactRoot: nil)
        try await persistence.saveLedger(.init())
        var wrongJournal = journal
        wrongJournal.scenarioVersion += 1
        try await persistence.saveJournal(wrongJournal)
        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.acceptRun(run, journal: journal)
        }
        wrongJournal.scenarioVersion = journal.scenarioVersion
        wrongJournal.invocation.nonce = UUID().uuidString
        try await persistence.saveJournal(wrongJournal)
        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.acceptRun(run, journal: journal)
        }
        let loaded = try #require(await ScenarioPersistence(rootDirectory: root).loadRuns().first)
        #expect(loaded.acceptanceStatus == .pending)
        #expect(ScenarioReleaseCheckEvaluator.report(definition: definition, run: loaded).outcome != .passed)
        #expect(!FileManager.default.fileExists(atPath: root.appending(
            path: "Runs/\(run.scenarioID.uuidString)/\(run.id.uuidString)/acceptance.json"
        ).path))
    }

    @MainActor
    private func assertMCPRejects(runID: UUID, root: URL) async throws {
        let store = EvaluationStore(supportDirectory: root.deletingLastPathComponent())
        let result = await MCPStoreAuthority.make(store: store).call(
            .getScenarioReport(.init(runID: runID))
        )
        #expect(!result.isError)
        let output = try result.structuredContent.jsonText()
        #expect(output.contains("acceptance receipt"))
        #expect(output.contains("incompleteOrIncompatibleEvidence"))
    }

    @MainActor
    private func assertMCPRejectsUnreadableJournal(runID: UUID, root: URL) async throws {
        let store = EvaluationStore(supportDirectory: root.deletingLastPathComponent())
        let result = await MCPStoreAuthority.make(store: store).call(
            .getScenarioReport(.init(runID: runID))
        )
        #expect(result.isError)
        let output = try result.structuredContent.jsonText()
        #expect(output.contains("\"code\":\"invalid_request\""))
        #expect(output.contains("execution journal"))
        #expect(output.contains("unreadable or has inconsistent identity"))
    }

    @MainActor
    @Test(arguments: [false, true])
    func nativeSaveRetryRequiresValidationAndPublishesDurableAcceptance(validationPassed: Bool) async throws {
        let context = try await nativeRetryContext(validationPassed: validationPassed)
        defer { try? FileManager.default.removeItem(at: context.support) }
        let coordinate = try #require(context.plan.coordinates.first)
        let record = await context.coordinator.retryPendingNativeSave(
            planID: context.plan.id, coordinateID: coordinate.id)
        let restored = try #require(try await context.persistence.loadRuns().first)
        if validationPassed {
            #expect(record?.isComplete == true)
            #expect(restored.acceptanceStatus == .accepted)
            let definition = try #require(try await context.persistence.loadDefinitions().first)
            #expect(!ScenarioReleaseCheckEvaluator.report(definition: definition, run: restored)
                .failures.contains { $0.contains("acceptance receipt") })
            #expect(try await context.persistence.loadPendingNativeSave(
                planID: context.plan.id, coordinateID: coordinate.id) == nil)
        } else {
            #expect(record == nil)
            #expect(restored.acceptanceStatus == .pending)
            #expect(try await context.persistence.loadPendingNativeSave(
                planID: context.plan.id, coordinateID: coordinate.id) != nil)
        }
    }

    @MainActor
    @Test func nativeReceiptRemainsRetryableAfterFinalizationFails() async throws {
        let context = try await nativeRetryContext(validationPassed: true)
        defer { try? FileManager.default.removeItem(at: context.support) }
        let coordinate = try #require(context.plan.coordinates.first)
        let blockedRecord = context.support.appending(path:
            "IntentLab/ExecutionRecords/\(context.plan.id.uuidString).json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blockedRecord, withIntermediateDirectories: true)
        let failed = await context.coordinator.retryPendingNativeSave(
            planID: context.plan.id, coordinateID: coordinate.id)
        #expect(failed == nil)
        #expect(try await context.persistence.loadRuns().first?.acceptanceStatus == .accepted)
        #expect(try await context.persistence.loadPendingNativeSave(
            planID: context.plan.id, coordinateID: coordinate.id) != nil)
        try FileManager.default.removeItem(at: blockedRecord)
        let retried = await context.coordinator.retryPendingNativeSave(
            planID: context.plan.id, coordinateID: coordinate.id)
        #expect(retried?.isComplete == true)
        #expect(try await context.persistence.loadRuns().first?.acceptanceStatus == .accepted)
        #expect(try await context.persistence.loadPendingNativeSave(
            planID: context.plan.id, coordinateID: coordinate.id) == nil)
    }

    @Test func conflictingAcceptanceReceiptIsNotOverwritten() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (_, run, journal) = try fixture()
        _ = try await persistence.saveRun(run, artifactRoot: nil)
        try await persistence.saveLedger(.init())
        try await persistence.saveJournal(journal)
        _ = try await persistence.acceptRun(run, journal: journal)
        let path = root.appending(path: "Runs/\(run.scenarioID.uuidString)/\(run.id.uuidString)/acceptance.json")
        let conflict = Data("different receipt".utf8)
        try conflict.write(to: path, options: .atomic)
        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.acceptRun(run, journal: journal)
        }
        #expect(try Data(contentsOf: path) == conflict)
    }

    @MainActor
    private func nativeRetryContext(validationPassed: Bool) async throws -> (
        support: URL, persistence: ScenarioPersistence, coordinator: ScenarioCoordinator, plan: ScenarioExecutionPlan
    ) {
        let support = temporaryDirectory()
        let persistence = ScenarioPersistence(rootDirectory: support.appending(path: "IntentLab"))
        var (definition, run, journal) = try fixture()
        definition.schemaVersion = ScenarioDefinition.stableSchemaVersion
        definition = try definition.frozen()
        run.scenarioDigest = definition.definitionDigest
        run.scenarioSchemaVersion = definition.schemaVersion
        run.testContractDigest = definition.testContractDigest
        run.invocation.scenarioDigest = definition.definitionDigest
        journal.invocation = run.invocation
        journal.evidenceAccepted = false
        let profile = ScenarioExecutionProfile(id: UUID(), projectPath: definition.target.projectPath,
            scheme: definition.target.scheme, testTarget: definition.target.testTarget,
            destinationIdentifier: definition.target.destinationIdentifier,
            signingSelection: nil, trustedConnectionID: nil, buildConfiguration: "Debug")
        let plan = try ScenarioExecutionPlan.make(definition: definition, profile: profile,
            appProductDigest: "app", testProductDigest: "test", sourceInputsDigest: "source",
            runnerBuildID: nil, runnerID: nil)
        let coordinate = try #require(plan.coordinates.first)
        run.laneResults[0].caseID = coordinate.caseID
        run.laneResults[0].lane = coordinate.lane
        run.laneResults[0].attempt = coordinate.repetition
        try await persistence.saveDefinition(definition)
        try await persistence.savePlan(plan)
        var records = plan.coordinates.map(ScenarioExecutionCoordinateRecord.unstarted)
        records[0].state = .recoveryRequired
        try await persistence.saveProgress(.init(planID: plan.id, records: records, updatedAt: .now))
        try await persistence.saveJournal(journal)
        try await persistence.savePendingNativeSave(.init(planID: plan.id, coordinateID: coordinate.id,
            run: run, artifactRootPath: support.path, ledger: .init(),
            evidenceValidationPassed: validationPassed, deviceReadinessProven: true))
        let coordinator = ScenarioCoordinator(supportDirectory: support,
            evaluationStore: EvaluationStore(supportDirectory: support))
        await coordinator.load()
        return (support, persistence, coordinator, plan)
    }

    private func fixture() throws -> (ScenarioDefinition, ScenarioRun, ScenarioExecutionJournal) {
        var definition = ScenarioDefinition.starter()
        definition.target.destinationIdentifier = "physical-device-1"
        definition.schemaVersion = ScenarioDefinition.reusableSchemaVersion
        definition.goal.requestText = ""
        definition.goal.languageCode = ""
        definition.goal.expectedBehavior = "The returned task ID is task-001."
        definition.fixture = .init(id: "", version: "", digest: "", isSynthetic: false,
                                   preparationOperation: "", cleanupOperation: "")
        let assertion = ScenarioAssertion(
            kind: .returnedField, observationKey: "taskID", expectedValue: .string("task-001"),
            explanation: "The returned task ID matches.", applicableLanes: [.intentIntegration]
        )
        definition.assertions = [assertion]
        definition.directControl.outputFields = [.init(
            name: "taskID", type: .primitive(.string), displayName: "Task ID",
            path: [.init(kind: .property, name: "value")]
        )]
        definition.coverage.appFeature = .notApplicable
        definition.coverage.siri = .notApplicable
        definition.purpose = .releaseRequirement
        definition.checkMode = .basic
        definition.requiredClaims = [.executionCompleted, .returnedValueChecked]
        definition.observationPlan = [.init(id: "taskID", source: .intentResult)]
        definition.integration = .init(id: "tasks", version: "1.0", digest: String(repeating: "a", count: 64))
        definition = try definition.frozen()
        let invocation = ScenarioInvocationIdentity(
            id: UUID(), nonce: UUID().uuidString,
            issuedAt: Date(timeIntervalSince1970: 1_800_000_000.125),
            testIdentity: .init(bundleIdentifier: "dev.example.Tests", className: "ScenarioTests", methodName: "testScenario"),
            harnessVersion: ScenarioInvocationIdentity.reusableHarnessVersion,
            destinationIdentifier: definition.target.destinationIdentifier,
            scenarioDigest: definition.definitionDigest,
            resultBundleIdentity: UUID().uuidString,
            appProduct: .init(bundleIdentifier: definition.target.bundleIdentifier, executableName: "Fixture", sha256: "app"),
            testProduct: .init(bundleIdentifier: "dev.example.Tests", executableName: "Tests", sha256: "test"),
            integration: definition.integration,
            requiredCapabilities: ScenarioHarnessCapabilities.required(for: definition).sorted()
        )
        let now = Date()
        let run = ScenarioRun(
            id: invocation.id, scenarioID: definition.id, scenarioVersion: definition.version,
            scenarioDigest: definition.definitionDigest, invocation: invocation,
            startedAt: now, completedAt: now,
            environment: .init(xcodeVersion: "27", sdkVersion: "27", deviceModel: "iPhone",
                               operatingSystem: "iOS 27", languageCode: "en", regionCode: "GB",
                               timeZoneIdentifier: "Europe/London", executedAt: now),
            executionStatus: .completed, outcome: .passed,
            laneResults: [.init(caseID: definition.id, attempt: 1, lane: .intentIntegration,
                                executionStatus: .completed, outcome: .passed,
                                startedAt: now, completedAt: now,
                                observations: ["taskID": .string("task-001")],
                                assertionResults: [.init(assertionID: assertion.id, passed: true,
                                                         observedValue: .string("task-001"), message: "matched")],
                                observationSources: ["taskID": .appIntentsTesting],
                                claims: [.executionCompleted, .returnedValueChecked])],
            linkedFeatureRunID: nil, importedAt: now, xctestExitCode: 0,
            integration: definition.integration, runnerPackageVersion: "0.1.0",
            negotiatedCapabilities: ScenarioHarnessCapabilities.required(for: definition).sorted()
        )
        let journal = ScenarioExecutionJournal(
            phase: .stopped, invocation: invocation, scenarioID: definition.id,
            scenarioVersion: definition.version, resultBundlePath: "", derivedDataPath: "",
            buildLogPath: "", intendedExecutable: "", intendedArguments: [],
            processIdentifier: nil, processStartedAt: nil, updatedAt: now, recoveryReason: nil
        )
        return (definition, run, journal)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }
}
