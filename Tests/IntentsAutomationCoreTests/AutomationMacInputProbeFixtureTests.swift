#if os(macOS)
import XCTest
import Darwin
@testable import IntentsAutomationCore

final class AutomationMacInputProbeFixtureTests: XCTestCase {
    func testAuthoredFixtureIsSelectableAndCannotReplaceExistingSource() throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("intents-input-source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = try AutomationPath.canonical(requested)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original")
        let fixture = try AutomationMacInputProbeFixture.write(at: source)
        let intake = try AutomationApplicationIntake.assess(fixture.project)
        XCTAssertEqual(intake.candidates.count, 1)
        XCTAssertEqual(intake.candidates.first?.targetID, fixture.targetID)
        let original = try Data(contentsOf: source.appendingPathComponent("Subject.swift"))
        XCTAssertThrowsError(try AutomationMacInputProbeFixture.write(at: source))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Subject.swift")), original)
        XCTAssertEqual(try Data(contentsOf: fixture.project.appendingPathComponent("project.pbxproj")), fixture.projectData)
    }
    func testFailedAuthoredPreconditionsThrowBeforeCalibration() throws {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("intents-input-contract-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = try AutomationPath.canonical(requested)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), session = root.appendingPathComponent("session")
        let fixture = try AutomationMacInputProbeFixture.write(at: original)
        let manifest = try AutomationSourceSnapshot.capture(source: original, sessionRoot: session)
        let frozen = session.appendingPathComponent("source")
        try AutomationMacInputProbeFixture.validateSource(manifest, fixture: fixture, original: original, frozenRoot: frozen)
        let app = AppIdentity(logicalID: "Subject", bundleID: "com.intents.fixture.mac-host", platform: "macos", productDigest: nil)
        let action = ApplicationSurfaceCatalog.SystemAction(id: "HostProbeIntent", typeName: "HostProbeIntent", title: "Probe",
            parameters: [.init(name: "sample", family: "text", optional: false)], parametersComplete: true, compiled: true, registered: false, executed: false)
        func catalog(_ action: ApplicationSurfaceCatalog.SystemAction) -> ApplicationSurfaceCatalog {
            .init(app: app, systemActions: [action], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [])
        }
        XCTAssertEqual(try AutomationMacInputProbeFixture.validateCatalog(catalog(action), app: app), "HostProbeIntent")
        let mutations: [(inout ApplicationSurfaceCatalog.SystemAction) -> Void] = [
            { $0.compiled = false }, { $0.parametersComplete = false }, { $0.registered = true }, { $0.executed = true },
            { $0.id = "ForeignIntent" }, { $0.parameters[0].family = "bool" }, { $0.parameters[0].optional = true },
            { $0.parameters[0].name = "foreign" }, { $0.parameters.append($0.parameters[0]) }
        ]
        for mutation in mutations {
            var changed = action; mutation(&changed)
            XCTAssertThrowsError(try AutomationMacInputProbeFixture.validateCatalog(catalog(changed), app: app))
        }
        var duplicate = catalog(action); duplicate.systemActions.append(action)
        XCTAssertThrowsError(try AutomationMacInputProbeFixture.validateCatalog(duplicate, app: app))
        var foreign = app; foreign.bundleID = "example.foreign"
        XCTAssertThrowsError(try AutomationMacInputProbeFixture.validateCatalog(catalog(action), app: foreign))
        let file = frozen.appendingPathComponent("Subject.swift")
        let bytes = try Data(contentsOf: file)
        try (bytes + Data("\n// drift".utf8)).write(to: file)
        XCTAssertThrowsError(try AutomationMacInputProbeFixture.validateSource(manifest, fixture: fixture, original: original, frozenRoot: frozen))
        try bytes.write(to: file)
        try (bytes + Data("\n// original drift".utf8)).write(to: original.appendingPathComponent("Subject.swift"))
        XCTAssertThrowsError(try AutomationMacInputProbeFixture.validateSource(manifest, fixture: fixture, original: original, frozenRoot: frozen))
    }
    func testAuthoredInputProbeFixtureWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        let live = environment["INTENTS_MAC_INPUT_PROBE_FIXTURE_LIVE"] == "1"
        guard live || environment["INTENTS_MAC_INPUT_PROBE_FIXTURE_BUILD"] == "1" else {
            throw XCTSkip("Authored input probe build/live calibration is opt-in")
        }
        // Target validation and owned host/runner release checks below govern this
        // fixture. Unrelated account processes are not an admission prerequisite.
        let target = try AutomationMacGUIIdentity.currentTarget()
        // Keep the prepared subject and SDK host on the explicitly selected toolchain.
        // This allows side-by-side Xcode qualification without changing xcode-select.
        let developer = try AutomationPath.canonical(URL(fileURLWithPath:
            environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"))
        let retainedParent = environment["INTENTS_MAC_INPUT_PROBE_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0) }
        let parent = try AutomationPath.canonical(retainedParent ?? FileManager.default.temporaryDirectory)
        let requestedRoot = parent.appendingPathComponent("intents-input-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = try AutomationPath.canonical(requestedRoot)
        if live || retainedParent != nil { print("Owned input fixture evidence root: \(root.path)") }
        // Preserve live attempt artifacts and uncertain release evidence for inspection.
        defer { if !live && retainedParent == nil { try? FileManager.default.removeItem(at: root) } }
        let source = root.appendingPathComponent("original")
        let fixture = try AutomationMacInputProbeFixture.write(at: source)
        let intake = try AutomationApplicationIntake.assess(fixture.project)
        guard intake.candidates.count == 1, let candidate = intake.candidates.first, candidate.targetID == fixture.targetID else {
            throw AutomationContractError.conflictingOperation
        }
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let prepared = try await AutomationPreparation().prepare(candidate: candidate,
            approval: .init(sourceRoot: source.path, candidateID: candidate.id, configuration: "Debug", target: target),
            sessionRoot: root.appendingPathComponent("prepare"), templates: templates, developerDirectory: developer)
        try AutomationMacInputProbeFixture.validateSource(prepared.source, fixture: fixture, original: source,
            frozenRoot: root.appendingPathComponent("prepare/source"))
        guard let graph = prepared.sourceGraph, graph.targetID == fixture.targetID, graph.projectRelativePath == "Subject.xcodeproj",
              graph.sourceManifestDigest == (try prepared.source.digest), prepared.catalog.sourceGraphDigest == (try graph.digest),
              graph.inputs == [.init(relativePath: "Subject.swift", sha256: AutomationArtifactRegistry.digest(Data(AutomationMacInputProbeFixture.source.utf8)),
                  owner: "Subject.xcodeproj#" + fixture.targetID, role: "explicitSwiftMembership")] else {
            throw AutomationContractError.conflictingOperation
        }
        let settings = try AutomationReadOnlyFile.read(root: root.appendingPathComponent("prepare"),
            relativePath: "source-compilation-settings.json", maximumBytes: 1_048_576, requirePrivateOwnership: true)
        guard let context = graph.platformContext, context.settingsSHA256 == AutomationArtifactRegistry.digest(settings),
              context.selected.platformFamily == "macos", context.filterFamily == "macos" else { throw AutomationContractError.conflictingOperation }
        let replayedGraph = try AutomationSourceGraphReader.read(manifest: prepared.source,
            frozenRoot: root.appendingPathComponent("prepare/source"), projectRelativePath: "Subject.xcodeproj",
            targetID: fixture.targetID, configuration: "Debug",
            projectData: AutomationReadOnlyFile.read(root: root.appendingPathComponent("prepare"), relativePath: "source-graph-project.pbxproj", maximumBytes: 16 * 1024 * 1024, requirePrivateOwnership: true),
            platformSettings: settings, developerDirectory: developer)
        guard try replayedGraph.digest == graph.digest else { throw AutomationContractError.conflictingOperation }
        guard !prepared.buildLogTruncated else { throw AutomationContractError.missingEvidence("Authored fixture build log is truncated") }
        print("Authored fixture bundle \(prepared.host.app.bundleID); subjectSHA256 \(prepared.host.app.productDigest ?? "unknown"); hostSHA256 \(prepared.host.hostProductDigest)")
        let actionID = try AutomationMacInputProbeFixture.validateCatalog(prepared.catalog, app: prepared.host.app)
        let plan = try AutomationInputAdapterProbePlan(prepared: prepared, actionID: actionID, parameterNames: ["sample"])
        guard plan.parameters.count == 1, plan.parameters[0].samples == [.text("Intents adapter probe")] else {
            throw AutomationContractError.conflictingOperation
        }
        if !live {
            print("Authored String input fixture and dedicated SDK host compiled; no app, probe or intent runtime launched")
            return
        }
        let installed = AutomationInstalledSubjectVerifier(developerDirectory: developer, workspace: root)
        let subject = AutomationMacGUISubjectVerifier(subject: installed, identity: { try AutomationMacGUIIdentity.validate($0) })
        let owner = try AutomationInputAdapterProbeRunner(plan: plan,
            approval: .init(runID: "authored-input-fixture", probeDigest: plan.digest, app: prepared.host.app, target: target),
            developerDirectory: developer, state: root.appendingPathComponent("probe-owner"),
            leases: AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json")),
            artifacts: AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts")), subject: subject,
            release: AutomationMacAssociatedHostReleaseVerifier(host: prepared.host))
        let report = try await owner.run(attemptID: "string-calibration")
        XCTAssertNil(report.failure)
        XCTAssertTrue(report.resourcesReleased)
        let observation = try XCTUnwrap(report.observation)
        XCTAssertEqual(observation.echoedSamples["sample"], [.text("Intents adapter probe")])
        XCTAssertNotNil(report.artifact)
        print("Authored String setter/readback calibration only; runner absence checked; complete child closure and generic codec availability remain unqualified")
    }
}
#endif
