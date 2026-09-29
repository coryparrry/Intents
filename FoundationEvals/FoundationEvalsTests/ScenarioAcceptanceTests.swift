import CryptoKit
import Foundation
import Testing
@testable import FoundationEvals

struct ScenarioAcceptanceTests {
    @Test @MainActor func completedFailureNeedsVerifiedCleanupBeforeDeviceRelease() throws {
        let (_, original, _) = try fixture()
        var failed = original
        failed.xctestExitCode = 0
        failed.outcome = .failed
        failed.laneResults[0].outcome = .failed
        let final = ScenarioEvidenceAttachment(
            url: URL(filePath: "/tmp/final.json"), name: "IntentLabEvidence-final"
        )
        #expect(!ScenarioCoordinator.canReleaseDevice(
            processExitCode: 0, attachments: [final], importedRuns: [failed],
            requiresCleanupProof: true
        ))
        failed.laneResults[0].cleanupVerified = true
        #expect(ScenarioCoordinator.canReleaseDevice(
            processExitCode: 0, attachments: [final], importedRuns: [failed],
            requiresCleanupProof: true
        ))
    }

    @Test @MainActor func nonzeroXCTestExitRetainsBusinessFailureButNeverReleasesDevice() throws {
        let (_, original, _) = try fixture()
        let final = ScenarioEvidenceAttachment(
            url: URL(filePath: "/tmp/final.json"), name: "IntentLabEvidence-final"
        )

        for reason in [ScenarioActionFailureReason.wrongAction, .wrongOutcome] {
            var failed = original
            failed.xctestExitCode = 1
            failed.outcome = .failed
            failed.laneResults[0].outcome = .failed
            failed.laneResults[0].actionFailureReason = reason
            failed.laneResults[0].cleanupVerified = true
            #expect(ScenarioExecutionRecoveryPolicy.shouldPreserveTerminalBusinessFailure(
                failed, attachment: final
            ))
            #expect(!ScenarioExecutionRecoveryPolicy.acceptsFinalEvidence(
                attachments: [final], runs: [failed], xctestExitCode: 1
            ))
            #expect(!ScenarioCoordinator.canReleaseDevice(
                processExitCode: 1, attachments: [final], importedRuns: [failed],
                requiresCleanupProof: true
            ))

            failed.xctestExitCode = 0
            #expect(ScenarioCoordinator.canReleaseDevice(
                processExitCode: 0, attachments: [final], importedRuns: [failed],
                requiresCleanupProof: true
            ))
            failed.laneResults[0].cleanupVerified = false
            #expect(!ScenarioCoordinator.canReleaseDevice(
                processExitCode: 0, attachments: [final], importedRuns: [failed],
                requiresCleanupProof: true
            ))
        }

        var unknown = original
        unknown.xctestExitCode = 1
        unknown.outcome = .failed
        unknown.laneResults[0].outcome = .failed
        unknown.laneResults[0].cleanupVerified = true
        #expect(!ScenarioExecutionRecoveryPolicy.acceptsFinalEvidence(
            attachments: [final], runs: [unknown], xctestExitCode: 1
        ))
        #expect(!ScenarioExecutionRecoveryPolicy.shouldPreserveTerminalBusinessFailure(
            unknown, attachment: final
        ))
        #expect(!ScenarioCoordinator.canReleaseDevice(
            processExitCode: 1, attachments: [final], importedRuns: [unknown],
            requiresCleanupProof: true
        ))

        let checkpoint = ScenarioEvidenceAttachment(
            url: URL(filePath: "/tmp/checkpoint.json"), name: "IntentLabEvidence-checkpoint"
        )
        var attributed = original
        attributed.xctestExitCode = 1
        attributed.outcome = .failed
        attributed.laneResults[0].outcome = .failed
        attributed.laneResults[0].actionFailureReason = .wrongOutcome
        attributed.laneResults[0].cleanupVerified = true
        #expect(!ScenarioExecutionRecoveryPolicy.acceptsFinalEvidence(
            attachments: [checkpoint], runs: [attributed], xctestExitCode: 1
        ))
        #expect(!ScenarioExecutionRecoveryPolicy.shouldPreserveTerminalBusinessFailure(
            attributed, attachment: checkpoint
        ))
    }

    @Test func completedBusinessFailureCanBeAcceptedWithoutBecomingAPass() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (definition, original, journal) = try fixture()
        var failed = original
        failed.outcome = .failed
        failed.laneResults[0].outcome = .failed
        failed.laneResults[0].diagnostic = "wrongAction: another operation completed"
        _ = try await persistence.saveRun(failed, artifactRoot: nil)
        try await persistence.saveLedger(ledger(for: failed))
        try await persistence.saveJournal(journal)

        let accepted = try await persistence.acceptRun(failed, journal: journal)
        #expect(accepted.acceptanceStatus == .accepted)
        let reloaded = try #require(await ScenarioPersistence(rootDirectory: root).loadRuns().first)
        #expect(reloaded.acceptanceStatus == .accepted)
        #expect(reloaded.executionStatus == .completed)
        #expect(reloaded.outcome == .failed)
        #expect(reloaded.laneResults[0].diagnostic == "wrongAction: another operation completed")
        #expect(ScenarioReleaseCheckEvaluator.report(definition: definition, run: reloaded).outcome == .failed)
    }

    @Test func stoppedJournalWithoutExplicitEvidenceAcceptanceCannotPublishReceipt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (_, run, journal) = try fixture()
        _ = try await persistence.saveRun(run, artifactRoot: nil)
        try await persistence.saveLedger(ledger(for: run))
        var rejected = journal
        rejected.evidenceAccepted = false
        try await persistence.saveJournal(rejected)

        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.acceptRun(run, journal: rejected)
        }
        #expect(try await ScenarioPersistence(rootDirectory: root).loadRuns().first?.acceptanceStatus == .pending)
    }

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
        try await persistence.saveLedger(ledger(for: run))
        try await persistence.saveJournal(journal)
        let accepted = try await persistence.acceptRun(run, journal: journal)
        #expect(accepted.acceptanceStatus == .accepted)
        #expect(ScenarioReleaseCheckEvaluator.report(definition: definition, run: accepted).outcome == .passed)
        #expect(try await ScenarioPersistence(rootDirectory: root).loadRuns().first?.acceptanceStatus == .accepted)
        let receiptPath = root.appending(path: "Runs/\(run.scenarioID.uuidString)/\(run.id.uuidString)/acceptance.json")
        let receiptBytes = try Data(contentsOf: receiptPath)
        let repeated = try await persistence.acceptRun(run, journal: journal)
        #expect(repeated.acceptanceStatus == .accepted)
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
        try await persistence.saveLedger(ledger(for: run))
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

    @Test func missingDurableLedgerCannotAcceptEvenWithValidatedJournal() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (_, run, journal) = try fixture()
        _ = try await persistence.saveRun(run, artifactRoot: nil)
        try await persistence.saveJournal(journal)
        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.acceptRun(run, journal: journal)
        }
        #expect(try await ScenarioPersistence(rootDirectory: root).loadRuns().first?.acceptanceStatus == .pending)
    }

    @Test func callerCannotForgeAcceptanceOverRejectedDurableJournal() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (_, run, journal) = try fixture()
        _ = try await persistence.saveRun(run, artifactRoot: nil)
        try await persistence.saveLedger(ledger(for: run))
        var rejected = journal
        rejected.evidenceAccepted = false
        try await persistence.saveJournal(rejected)
        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.acceptRun(run, journal: journal)
        }
        #expect(try await ScenarioPersistence(rootDirectory: root).loadRuns().first?.acceptanceStatus == .pending)
    }

    @Test func alteredRawRunCannotReceiveFirstAcceptanceReceipt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (_, run, journal) = try fixture()
        _ = try await persistence.saveRun(run, artifactRoot: nil)
        try await persistence.saveLedger(ledger(for: run))
        try await persistence.saveJournal(journal)
        let path = root.appending(path: "Runs/\(run.scenarioID.uuidString)/\(run.id.uuidString)/run.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var lanes = try #require(raw["laneResults"] as? [[String: Any]])
        lanes[0]["diagnostic"] = "altered after capture"
        raw["laneResults"] = lanes
        try JSONSerialization.data(withJSONObject: raw).write(to: path, options: .atomic)

        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.acceptRun(run, journal: journal)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(
            path: "Runs/\(run.scenarioID.uuidString)/\(run.id.uuidString)/acceptance.json"
        ).path))
    }

    @Test func changedSavedArtifactPathOrBytesCannotBeAccepted() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (_, fixtureRun, journal) = try fixture()
        let source = root.appending(path: "Capture", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let originalBytes = Data("original evidence".utf8)
        try originalBytes.write(to: source.appending(path: "capture.json"))
        var run = fixtureRun
        let artifact = ScenarioArtifactReference(
            kind: .evidenceJSON, filename: "capture.json", relativePath: "capture.json",
            contentType: "application/json", byteCount: originalBytes.count,
            sha256: SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
        )
        run.laneResults[0].artifacts = [artifact]
        let saved = try await persistence.saveRun(run, artifactRoot: source)
        try await persistence.saveLedger(ledger(for: run))
        try await persistence.saveJournal(journal)
        let runPath = root.appending(path: "Runs/\(run.scenarioID.uuidString)/\(run.id.uuidString)/run.json")
        let originalRun = try Data(contentsOf: runPath)
        var raw = try #require(JSONSerialization.jsonObject(with: originalRun) as? [String: Any])
        var lanes = try #require(raw["laneResults"] as? [[String: Any]])
        var artifacts = try #require(lanes[0]["artifacts"] as? [[String: Any]])
        artifacts[0]["relativePath"] = "capture.json"
        lanes[0]["artifacts"] = artifacts
        raw["laneResults"] = lanes
        try JSONSerialization.data(withJSONObject: raw).write(to: runPath, options: .atomic)
        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.acceptRun(run, journal: journal)
        }

        try originalRun.write(to: runPath, options: .atomic)
        let storedArtifact = runPath.deletingLastPathComponent()
            .appending(path: saved.laneResults[0].artifacts[0].relativePath)
        try Data("altered! evidence".utf8).write(to: storedArtifact, options: .atomic)
        await #expect(throws: ScenarioPersistenceError.self) {
            _ = try await persistence.acceptRun(run, journal: journal)
        }
        try originalBytes.write(to: storedArtifact, options: .atomic)
        #expect(try await persistence.acceptRun(run, journal: journal).acceptanceStatus == .accepted)
    }

    @Test func sharedRunOmitsRawAndTypedActionReceiptParameters() async throws {
        let persistence = ScenarioPersistence(rootDirectory: temporaryDirectory())
        let (_, fixtureRun, _) = try fixture()
        var run = fixtureRun
        let secret = "sensitive-parameter-value"
        run.laneResults[0].observations["intentlab.actionReceipts"] = .string(secret)
        let now = Date()
        run.laneResults[0].actionReceipts = [.init(
            executionID: UUID(), appSessionID: UUID(), attemptContext: "intent-\(run.id.uuidString)-1",
            lane: .intentIntegration, attempt: 1, kind: .productionIntent,
            operationID: "CreateTaskIntent", resolvedParameters: ["task": .string(secret)],
            terminalStatus: .succeeded, operationError: nil, sequence: 1,
            startedAt: now, completedAt: now, observationTransport: .appIntentsTesting
        )]
        let shared = await persistence.redactedSharingCopy(of: run)
        #expect(shared.laneResults[0].observations["intentlab.actionReceipts"] == nil)
        #expect(shared.laneResults[0].actionReceipts == nil)
        #expect(!String(decoding: try JSONEncoder().encode(shared), as: UTF8.self).contains(secret))
        #expect(run.laneResults[0].actionReceipts?.count == 1)
    }

    @Test func nativePendingSaveRetainsArtifactsAndRejectsAlteredSavedRun() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (definition, fixtureRun, _) = try fixture()
        let profile = ScenarioExecutionProfile(
            id: UUID(), projectPath: "/example/App.xcodeproj", scheme: "App",
            testTarget: "AppTests", destinationIdentifier: definition.target.destinationIdentifier,
            signingSelection: nil, trustedConnectionID: nil, buildConfiguration: "Debug"
        )
        let coordinate = ScenarioPlannedCoordinate(
            id: UUID(), caseID: definition.id, lane: .intentIntegration,
            repetition: 1, required: true
        )
        let plan = ScenarioExecutionPlan(
            id: UUID(), definitionID: definition.id, definitionVersion: definition.version,
            definitionDigest: definition.definitionDigest, testContractDigest: "test-contract",
            profile: profile, appProductDigest: "app", testProductDigest: "test",
            fixtureContractDigest: definition.fixture.digest, coordinates: [coordinate],
            comparisonPolicy: nil, createdAt: Date(), sourceInputsDigest: "source"
        )
        try await persistence.savePlan(plan)
        var run = fixtureRun
        let evidence = root.appending(path: "NativeEvidence", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let bytes = Data("captured native evidence".utf8)
        try bytes.write(to: evidence.appending(path: "capture.json"))
        run.laneResults[0].artifacts.append(.init(
            id: UUID(), kind: .evidenceJSON, filename: "capture.json",
            relativePath: "capture.json", contentType: "application/json",
            byteCount: bytes.count,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        ))
        let pending = ScenarioPendingNativeSave(
            planID: plan.id, coordinateID: coordinate.id, run: run,
            artifactRootPath: evidence.path, ledger: ledger(for: run),
            evidenceValidationPassed: true, deviceReadinessProven: true
        )
        try await persistence.savePendingNativeSave(pending)
        try FileManager.default.removeItem(at: evidence)
        let relaunched = ScenarioPersistence(rootDirectory: root)
        let stage = try #require(await relaunched.loadPendingNativeSave(
            planID: plan.id, coordinateID: coordinate.id
        ))
        let saved = try await relaunched.commitPendingNativeSave(stage)
        #expect(saved.laneResults[0].artifacts.count == 1)
        #expect(try Data(contentsOf: root.appending(
            path: "PendingNativeSaves/\(plan.id.uuidString)-\(coordinate.id.uuidString)/capture.json"
        )) == bytes)

        let path = root.appending(path: "Runs/\(run.scenarioID.uuidString)/\(run.id.uuidString)/run.json")
        let original = try Data(contentsOf: path)
        for changedField in ["diagnostic", "cleanupVerified", "outcome",
                             "actionReceipts", "actionFailureReason"] {
            var raw = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            if changedField == "outcome" {
                raw["outcome"] = "failed"
            } else {
                var lanes = try #require(raw["laneResults"] as? [[String: Any]])
                if changedField == "cleanupVerified" {
                    lanes[0][changedField] = true
                } else if changedField == "actionReceipts" {
                    lanes[0][changedField] = []
                } else if changedField == "actionFailureReason" {
                    lanes[0][changedField] = "wrongAction"
                } else {
                    lanes[0][changedField] = "altered"
                }
                raw["laneResults"] = lanes
            }
            try JSONSerialization.data(withJSONObject: raw).write(to: path, options: .atomic)
            await #expect(throws: ScenarioPersistenceError.self) {
                _ = try await relaunched.commitPendingNativeSave(stage)
            }
        }
        try original.write(to: path, options: .atomic)
        #expect(try await relaunched.commitPendingNativeSave(stage).id == run.id)
    }

    @Test func ordinaryPendingSaveRetriesLedgerAndReceiptFaultsWithoutAnotherAction() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (_, fixtureRun, journal) = try fixture()
        var run = fixtureRun
        let rawDirectory = root.appending(path: "Evidence", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        let rawArtifact = rawDirectory.appending(path: "capture.json")
        let artifactBytes = Data("captured once".utf8)
        try artifactBytes.write(to: rawArtifact)
        let artifactID = UUID()
        run.laneResults[0].artifacts.append(.init(
            id: artifactID, kind: .evidenceJSON, filename: "capture.json",
            relativePath: "capture.json", contentType: "application/json",
            byteCount: artifactBytes.count,
            sha256: SHA256.hash(data: artifactBytes).map { String(format: "%02x", $0) }.joined()
        ))
        let pending = ScenarioPendingOrdinarySave(
            invocationID: run.id, runs: [run], artifactRootPath: rawDirectory.path,
            ledger: ledger(for: run), evidenceValidationPassed: true,
            deviceReadinessProven: true
        )
        try await persistence.savePendingOrdinarySave(pending)
        try FileManager.default.removeItem(at: rawDirectory)
        #expect(FileManager.default.fileExists(atPath: root.appending(
            path: "PendingOrdinarySaves/\(run.id.uuidString)/capture.json"
        ).path))
        let ledgerPath = root.appending(path: "import-ledger.json")
        try FileManager.default.createDirectory(at: ledgerPath, withIntermediateDirectories: true)
        await #expect(throws: Error.self) {
            _ = try await persistence.commitPendingOrdinarySave(pending)
        }
        #expect(try await persistence.loadRuns().first?.acceptanceStatus == .pending)

        try FileManager.default.removeItem(at: ledgerPath)
        let relaunched = ScenarioPersistence(rootDirectory: root)
        let staged = try #require(await relaunched.loadPendingOrdinarySave(invocationID: run.id))
        let saved = try #require(await relaunched.commitPendingOrdinarySave(staged).first)
        try await relaunched.saveJournal(journal)
        let receiptPath = root.appending(path: "Runs/\(run.scenarioID.uuidString)/\(run.id.uuidString)/acceptance.json")
        try FileManager.default.createDirectory(at: receiptPath, withIntermediateDirectories: true)
        await #expect(throws: Error.self) {
            _ = try await relaunched.acceptRun(saved, journal: journal)
        }
        #expect(try await relaunched.loadPendingOrdinarySave(invocationID: run.id) != nil)

        try FileManager.default.removeItem(at: receiptPath)
        let accepted = try await relaunched.acceptRun(saved, journal: journal)
        #expect(accepted.acceptanceStatus == .accepted)
        try await relaunched.clearPendingOrdinarySave(invocationID: run.id)
        #expect(try await ScenarioPersistence(rootDirectory: root).loadRuns().first?.acceptanceStatus == .accepted)
        #expect(try await relaunched.loadPendingOrdinarySaves().isEmpty)
    }

    @MainActor
    @Test func ordinaryCoordinatorRetryUsesSavedEvidenceWithoutDeviceDispatch() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = support.appending(path: "IntentLab", directoryHint: .isDirectory)
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (_, run, journal) = try fixture()
        let pending = ScenarioPendingOrdinarySave(
            invocationID: run.id, runs: [run], artifactRootPath: support.path,
            ledger: ledger(for: run), evidenceValidationPassed: true,
            deviceReadinessProven: true
        )
        try await persistence.savePendingOrdinarySave(pending)
        _ = try await persistence.saveRun(run, artifactRoot: support)
        try await persistence.saveJournal(journal)

        let coordinator = ScenarioCoordinator(
            supportDirectory: support,
            evaluationStore: EvaluationStore(supportDirectory: support),
            executionAdmission: ScenarioExecutionAdmission()
        )
        await coordinator.load()
        #expect(coordinator.pendingOrdinarySaves.map(\.invocationID) == [run.id])
        let retryResult = await coordinator.retryPendingOrdinarySave(invocationID: run.id)
        let recovered = try #require(retryResult, "Save retry failed: \(coordinator.notice ?? "unknown reason")")
        #expect(recovered.first?.acceptanceStatus == .accepted)
        #expect(coordinator.pendingOrdinarySaves.isEmpty)
        #expect(try await ScenarioPersistence(rootDirectory: root).loadRuns().first?.acceptanceStatus == .accepted)
    }

    @MainActor
    @Test func diagnosticSaveRetryReleasesReadyDeviceWithoutAcceptingEvidence() async throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = support.appending(path: "IntentLab", directoryHint: .isDirectory)
        let persistence = ScenarioPersistence(rootDirectory: root)
        let (_, run, acceptedJournal) = try fixture()
        var journal = acceptedJournal
        journal.phase = .running
        journal.evidenceAccepted = nil
        try await persistence.saveJournal(journal)
        try await persistence.savePendingOrdinarySave(.init(
            invocationID: run.id, runs: [run], artifactRootPath: support.path,
            ledger: ledger(for: run), evidenceValidationPassed: false,
            deviceReadinessProven: true
        ))

        let coordinator = ScenarioCoordinator(
            supportDirectory: support,
            evaluationStore: EvaluationStore(supportDirectory: support),
            executionAdmission: ScenarioExecutionAdmission()
        )
        await coordinator.load()
        let retryResult = await coordinator.retryPendingOrdinarySave(invocationID: run.id)
        let recovered = try #require(retryResult, "Save retry failed: \(coordinator.notice ?? "unknown reason")")
        #expect(recovered.first?.acceptanceStatus == .pending)
        #expect(coordinator.recoveryJournals.isEmpty)
        let durable = try #require(await persistence.loadJournals().first { $0.id == run.id })
        #expect(durable.phase == .stopped)
        #expect(durable.evidenceAccepted == false)
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
        var acceptedJournal = journal
        acceptedJournal.evidenceAccepted = true
        return (definition, run, acceptedJournal)
    }

    private func ledger(for run: ScenarioRun) -> ScenarioImportLedger {
        var ledger = ScenarioImportLedger()
        ledger.importedInvocationIDs.insert(run.invocation.id)
        ledger.importedNonces.insert(run.invocation.nonce)
        ledger.importedArtifactIDs.formUnion(run.laneResults.flatMap(\.artifacts).map(\.id))
        return ledger
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }
}
