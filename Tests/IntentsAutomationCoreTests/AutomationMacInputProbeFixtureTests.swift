#if os(macOS)
import XCTest
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

}
#endif
