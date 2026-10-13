#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationSimulatorCodecQualificationTests: XCTestCase {
    func testProductionCanaryAdmissionFromFreshPreparationWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_SIMULATOR_CODEC_LIVE_PROFILE"] else {
            throw XCTSkip("Requires an approved source build and disposable simulator profile")
        }
        struct Profile: Decodable {
            let inputPath: String
            let approval: AutomationBuildApproval
            let sessionRoot: String
            let templates: String
            let developerDirectory: String
        }
        let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let intake = try AutomationApplicationIntake.assess(URL(fileURLWithPath: profile.inputPath))
        let candidate = try XCTUnwrap(intake.candidates.first { $0.id == profile.approval.candidateID })
        let root = URL(fileURLWithPath: profile.sessionRoot).appendingPathComponent("attempt-" + UUID().uuidString)
        let developer = URL(fileURLWithPath: profile.developerDirectory)
        let prepared = try await AutomationPreparation().prepare(candidate: candidate, approval: profile.approval,
            sessionRoot: root, templates: URL(fileURLWithPath: profile.templates), developerDirectory: developer)
        print("PRODUCTION_CODEC_PREPARATION=\(root.path)")
        try AutomationPreparedCodecAuthority.verify(prepared)
        let input: AutomationValue = .array([.integer("1")])
        let capabilities = AutomationPreparedCapabilities.base(prepared)
        var plan = AutomationCase(id: "production-codec-canary", app: prepared.host.app, target: prepared.host.target,
            environmentID: "selected-simulator:" + prepared.host.target.id,
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Authored pure echo",
                requiredCapabilities: ["apple.intent.invoke", "apple.codec.integerArray"], effects: [.observe, .navigate],
                lifecycle: .persistedStateAcrossSegments))
        plan.execution.hostProgram = .init(operations: [.init(id: "echo", kind: .invoke,
            typeID: "QualificationEchoIntegerArrayIntent", parameters: ["value": input], resultCodec: "integerArray", parameterCodecs: ["value": "integerArray"])])
        let id = UUID().uuidString
        var approval = RunApproval(runID: id, app: plan.app, target: plan.target, environmentID: plan.environmentID,
            effects: [.observe, .navigate], maximumActions: 1, disposable: true)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let runner = try AutomationApplicationRunner(supportRoot: root.appendingPathComponent("production-attempts"), developerDirectory: developer)
        let campaignCapabilities = try await runner.capabilitiesForExecution(subject: .prepared(prepared), plan: plan,
            capabilities: capabilities)
        XCTAssertTrue(campaignCapabilities.supports(["apple.codec.integerArray"]))
        var veto = capabilities
        veto.records["apple.codec.integerArray"] = .init(state: .unavailable, reason: "Explicit test veto",
            probeVersion: "test", evidence: [])
        let unchangedVeto = try await runner.capabilitiesForExecution(subject: .prepared(prepared), plan: plan,
            capabilities: veto)
        XCTAssertEqual(unchangedVeto.records["apple.codec.integerArray"], veto.records["apple.codec.integerArray"])
        let report = try await runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: campaignCapabilities,
            attemptID: id, allowBootAndInstall: true)
        XCTAssertTrue(report.resourcesReleased)
        XCTAssertTrue(report.result.subjectCompleted)
        XCTAssertFalse(report.result.subjectDispatchUncertain)
        XCTAssertEqual(report.result.summary, .executedUnassessed)
        XCTAssertEqual(report.receipts.first?.verifiedOutputs?["echo"], input)
        let records = try await AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("production-attempts/target-leases.json")).recoveryRecords()
        XCTAssertTrue(records.isEmpty)
        print("PRODUCTION_CODEC_CANARY=\(root.path) attempt=\(id)")
    }

    func testGeneratedTemplateChangesAndAddedSourcesAreRejected() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("generated-host/Owned/Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        for file in AutomationHostGenerator.templateFiles {
            try FileManager.default.copyItem(at: templates.appendingPathComponent(file), to: sources.appendingPathComponent(file))
        }
        var records: [String: String] = [:]
        for file in AutomationHostGenerator.templateFiles { records[file] = AutomationArtifactRegistry.digest(try Data(contentsOf: templates.appendingPathComponent(file))) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let generated = AutomationGeneratedHost(projectPath: "unused", scheme: "Owned", targetID: "owned", bundleID: "owned", configuration: "Debug", templateDigest: AutomationArtifactRegistry.digest(try encoder.encode(records)))
        XCTAssertNoThrow(try AutomationHostGenerator.verifyGeneratedSources(generated, sessionRoot: root))
        let changed = sources.appendingPathComponent("HostPlan.swift")
        let original = try Data(contentsOf: changed)
        try (original + Data("\n// altered during build".utf8)).write(to: changed)
        XCTAssertThrowsError(try AutomationHostGenerator.verifyGeneratedSources(generated, sessionRoot: root))
        try original.write(to: changed)
        try Data("// extra code".utf8).write(to: sources.appendingPathComponent("Extra.swift"))
        XCTAssertThrowsError(try AutomationHostGenerator.verifyGeneratedSources(generated, sessionRoot: root))
    }





    func testRecoverExplicitShutdownCalibrationWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_CALIBRATION_RECOVERY_PROFILE"] else {
            throw XCTSkip("Requires an explicit failed disposable calibration profile")
        }
        struct Profile: Decodable { let ledger: String; let simulatorID: String; let runID: String; let developerDirectory: String }
        let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let ledger = URL(fileURLWithPath: profile.ledger).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path
        guard ledger.path.hasPrefix(temporary + "/intents-codec-calibration-"), UUID(uuidString: profile.simulatorID) != nil else {
            throw AutomationContractError.invalidIdentity
        }
        let manager = try AutomationDeviceLeaseManager(storeURL: ledger)
        let records = try await manager.recoveryRecords()
        let record = try XCTUnwrap(records.first { $0.target.id == profile.simulatorID && $0.runID == profile.runID })
        let inventory = try await AutomationSimulatorInventory.read(developerDirectory: URL(fileURLWithPath: profile.developerDirectory),
            workspace: ledger.deletingLastPathComponent())
        guard record.target.kind == .simulator, [.absent, .replaced].contains(record.owner.presence()),
              record.runners.allSatisfy({ [.absent, .replaced].contains($0.process.presence()) }),
              inventory.first(where: { $0.id == profile.simulatorID })?.state == "Shutdown" else {
            throw AutomationContractError.terminationUnverified
        }
        // These facts authorize release only. The original dispatched install
        // and unresolved report remain historical evidence, never a retry token.
        try await manager.reconcile(record, commandsDrained: true, ownedRunnerTerminated: true)
        let remaining = try await manager.recoveryRecords()
        XCTAssertTrue(remaining.isEmpty)
    }




}
#endif
