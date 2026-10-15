#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationGeneratedSupportRecoveryTests: XCTestCase {
    private func fixture() throws -> (URL, URL, AutomationGeneratedHost, AutomationGeneratedSupportRecovery) {
        let root = URL(fileURLWithPath: "/private/tmp/generated-repair-" + UUID().uuidString), session = root.appendingPathComponent("session")
        let scheme = "IntentsAutomationHost_test", project = session.appendingPathComponent("source/Subject.xcodeproj")
        let sources = session.appendingPathComponent("generated-host/" + scheme + "/Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let schemes = project.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        try Data("customer project".utf8).write(to: project.appendingPathComponent("project.pbxproj"))
        try Data("customer app".utf8).write(to: session.appendingPathComponent("source/App.swift"))
        try Data("scheme".utf8).write(to: schemes.appendingPathComponent(scheme + ".xcscheme"))
        var records: [String: String] = [:]
        for file in AutomationHostGenerator.templateFiles {
            let bytes = Data(("support " + file).utf8); try bytes.write(to: sources.appendingPathComponent(file))
            records[file] = AutomationArtifactRegistry.digest(bytes)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let generated = AutomationGeneratedHost(projectPath: project.path, scheme: scheme, targetID: "target", bundleID: "example.host",
            configuration: "Debug", templateDigest: AutomationArtifactRegistry.digest(try encoder.encode(records)))
        return (root, session, generated, try AutomationGeneratedSupportRecovery(sessionRoot: session, generated: generated, workspaceRelativePath: nil))
    }
    func testRestoreRepairsOnlyCapturedGeneratedSourcesAndScheme() throws {
        let (root, session, generated, recovery) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let beforeApp = try Data(contentsOf: session.appendingPathComponent("source/App.swift"))
        let beforeProject = try Data(contentsOf: URL(fileURLWithPath: generated.projectPath).appendingPathComponent("project.pbxproj"))
        let sources = session.appendingPathComponent(recovery.sourceDirectory)
        XCTAssertTrue(try recovery.isMaterialized())
        try FileManager.default.removeItem(at: sources.appendingPathComponent("SegmentTests.swift"))
        try Data("damaged".utf8).write(to: sources.appendingPathComponent("HostPlan.swift"))
        XCTAssertFalse(try recovery.isMaterialized())
        XCTAssertTrue(try recovery.restore())
        try AutomationHostGenerator.verifyGeneratedSources(generated, sessionRoot: session)
        XCTAssertTrue(try recovery.isMaterialized())
        XCTAssertFalse(try recovery.restore())
        XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("source/App.swift")), beforeApp)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: generated.projectPath).appendingPathComponent("project.pbxproj")), beforeProject)
    }
    func testRepairRejectsSymlinkWriteOutsideSessionWithoutChangingForeignBytes() throws {
        let (root, session, _, recovery) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let foreign = root.appendingPathComponent("foreign.swift"), bytes = Data("foreign app input".utf8)
        try bytes.write(to: foreign)
        let support = session.appendingPathComponent(recovery.sourceDirectory + "/SegmentTests.swift")
        try FileManager.default.removeItem(at: support)
        try FileManager.default.createSymbolicLink(at: support, withDestinationURL: foreign)
        XCTAssertThrowsError(try recovery.restore())
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["foreign.swift", "session"])
    }
    func testRepairRefusesUnknownGeneratedSourceRatherThanDeletingIt() throws {
        let (root, session, _, recovery) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let unknown = session.appendingPathComponent(recovery.sourceDirectory + "/Customer.swift"), bytes = Data("unknown".utf8)
        try bytes.write(to: unknown)
        XCTAssertThrowsError(try recovery.restore())
        XCTAssertEqual(try Data(contentsOf: unknown), bytes)
    }
}
#endif
