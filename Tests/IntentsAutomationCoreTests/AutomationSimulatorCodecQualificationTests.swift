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
        let current = await AutomationPreparedCodecAuthority.shared.contains(prepared)
        XCTAssertTrue(current)
        let input: AutomationValue = .array([.integer("1")])
        let capabilities = CapabilityProfile(records: ["apple.intent.invoke": .init(state: .available,
            reason: "Associated Apple host; invocation proves registration", probeVersion: "host-v2", evidence: [prepared.host.xctestrunDigest])])
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
        XCTAssertEqual(unchangedVeto, veto)
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

    func testSerializedMetadataDoesNotCreatePreparationAuthority() async throws {
        let app = AppIdentity(logicalID: "subject", bundleID: "example.subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let prepared = AutomationPreparedApplication(source: .init(sourceRoot: "/private/tmp", files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "unused", scheme: "Owned", targetID: "owned", bundleID: "owned", configuration: "Debug", templateDigest: AutomationSimulatorCodecQualification.qualified.context.hostTemplate),
            host: .init(app: app, target: .init(id: "target", kind: .simulator), xctestrunPath: "unused", xctestrunDigest: "unused", subjectProductPath: "unused", hostBundlePath: "unused", hostProductDigest: "unused", hostBundleID: "owned", testTarget: "Owned"),
            catalog: .init(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []), buildLogPath: "unused", buildLogTruncated: false)
        let decoded = try JSONDecoder().decode(AutomationPreparedApplication.self, from: JSONEncoder().encode(prepared))
        let authority = AutomationPreparedCodecAuthority()
        let initiallyAdmitted = await authority.contains(decoded)
        XCTAssertFalse(initiallyAdmitted)
        await authority.register(prepared)
        let currentAdmitted = await authority.contains(prepared)
        XCTAssertTrue(currentAdmitted)
        var changed = decoded; changed.host.hostProductDigest = "different"
        let changedAdmitted = await authority.contains(changed)
        XCTAssertFalse(changedAdmitted)
        let capabilities = try await AutomationSimulatorCodecQualification.enrich(.init(), prepared: decoded,
            requiredCapabilities: ["apple.codec.integerArray"], developerDirectory: URL(fileURLWithPath: "/missing"), workspace: URL(fileURLWithPath: "/missing"))
        XCTAssertTrue(capabilities.records.isEmpty)
        let cached = AutomationSimulatorCodecQualification.applying(AutomationSimulatorCodecQualification.qualified,
            context: AutomationSimulatorCodecQualification.qualified.context, to: .init())
        XCTAssertTrue(cached.supports(["apple.codec.integerArray"]))
        let revoked = try await AutomationSimulatorCodecQualification.enrich(cached, prepared: decoded,
            requiredCapabilities: ["apple.codec.integerArray"], developerDirectory: URL(fileURLWithPath: "/missing"), workspace: URL(fileURLWithPath: "/missing"))
        XCTAssertFalse(revoked.supports(["apple.codec.integerArray"]))
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: URL(fileURLWithPath: "/private/tmp"))
        let plan = AutomationCase(id: "foreign-case", app: .init(logicalID: "foreign", bundleID: "example.foreign", platform: "ios"),
            target: prepared.host.target, environmentID: "unowned",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Read",
                requiredCapabilities: ["apple.codec.integerArray"], effects: [.observe], lifecycle: .persistedStateAcrossSegments))
        do {
            _ = try await runner.capabilitiesForExecution(subject: .prepared(decoded), plan: plan, capabilities: .init())
            XCTFail("Campaign qualification must reject a different approved subject")
        } catch { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
    }

    func testIntelOnlyProductsCannotUseArmCanaryAndLaunchPinsArchitecture() {
        XCTAssertFalse(AutomationSimulatorCodecQualification.supportsQualifiedArchitecture("x86_64\n"))
        XCTAssertTrue(AutomationSimulatorCodecQualification.supportsQualifiedArchitecture("x86_64 arm64\n"))
        #if arch(arm64)
        XCTAssertEqual(AutomationAppleRouteDriver.simulatorDestination(targetID: "selected"), "platform=iOS Simulator,id=selected,arch=arm64")
        #endif
    }

    func testInvalidAdHocSignatureIsNotAcceptedAsDisplayMetadata() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let product = root.appendingPathComponent("signed-canary")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: product)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: product.path)
        let signed = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", product.path], directory: root, environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(15))
        XCTAssertEqual(signed.exitStatus, 0)
        let developer = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")
        let valid = try await AutomationSimulatorCodecQualification.verifiesSignature(product, developer: developer, workspace: root)
        XCTAssertTrue(valid)
        var bytes = try Data(contentsOf: product); bytes[4096] ^= 1
        try bytes.write(to: product)
        let invalid = try await AutomationSimulatorCodecQualification.verifiesSignature(product, developer: developer, workspace: root)
        XCTAssertFalse(invalid)
    }

    func testQualificationCitesRetainedCanaryMetadata() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/Automation/simulator-codec-qualification-2.json")
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let verified = try XCTUnwrap(metadata["verified"] as? [[String: Any]])
        XCTAssertEqual(Set(verified.compactMap { $0["reportSHA256"] as? String }), Set(AutomationSimulatorCodecQualification.qualified.reports))
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

    func testMatchingCanaryAdmitsOnlyTheVerifiedAdapterFamilies() {
        let qualification = AutomationSimulatorCodecQualification.qualified
        let capabilities = AutomationSimulatorCodecQualification.applying(qualification, context: qualification.context, to: .init())
        XCTAssertTrue(capabilities.supports(["apple.codec.integerArray"]))
        XCTAssertFalse(capabilities.supports(["apple.codec.url"]))
        XCTAssertFalse(capabilities.supports(["apple.intent.invoke"]))
        XCTAssertEqual(capabilities.records["apple.codec.integerArray"]?.evidence, qualification.reports)
        XCTAssertEqual(Set(capabilities.records.keys), Set(qualification.families.map { "apple.codec." + $0 }))
        let legacy = AutomationSimulatorCodecQualification.legacyQualified
        let oldCapabilities = AutomationSimulatorCodecQualification.applying(legacy, context: legacy.context, to: .init())
        XCTAssertTrue(oldCapabilities.supports(["apple.codec.integerArray"]))
        XCTAssertFalse(oldCapabilities.supports(["apple.codec.entity"]))
        XCTAssertFalse(oldCapabilities.supports(["apple.codec.integer"]))
    }

    func testEveryEnvironmentChangeKeepsConversionUnavailable() {
        let qualification = AutomationSimulatorCodecQualification.qualified
        let fields: [WritableKeyPath<AutomationSimulatorCodecQualification.Context, String>] = [
            \.hostTemplate, \.macOSBuild, \.architecture, \.xcodeBuild, \.sdkBuild,
            \.runnerBuild, \.runtimeBuild, \.frameworkDigest, \.signing
        ]
        for field in fields {
            var context = qualification.context
            context[keyPath: field] += "-different"
            let result = AutomationSimulatorCodecQualification.applying(qualification, context: context, to: .init())
            XCTAssertTrue(result.records.isEmpty, "Mismatched \(field) admitted a codec")
        }
    }

    func testQualificationDoesNotOverrideVetoConsentOrCallerEvidence() {
        let qualification = AutomationSimulatorCodecQualification.qualified
        for state in [CapabilityProfile.State.unavailable, .consentRequired, .available] {
            let existing = CapabilityProfile(records: ["apple.codec.integerArray": .init(state: state,
                reason: "Caller decision", probeVersion: "caller", evidence: ["caller-evidence"])])
            let result = AutomationSimulatorCodecQualification.applying(qualification, context: qualification.context, to: existing)
            XCTAssertEqual(result.records["apple.codec.integerArray"], existing.records["apple.codec.integerArray"])
        }
        let unknown = CapabilityProfile(records: ["apple.codec.integerArray": .init(state: .unknown,
            reason: "Not yet checked", probeVersion: "unknown", evidence: [])])
        let result = AutomationSimulatorCodecQualification.applying(qualification, context: qualification.context, to: unknown)
        XCTAssertTrue(result.supports(["apple.codec.integerArray"]))
    }
}
#endif
