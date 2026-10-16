#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationPreparedArtifactIntegrityTests: XCTestCase {
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
}
#endif
