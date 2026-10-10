import XCTest
@testable import IntentsAutomationCore

final class AutomationPreparedSourceIntegrityTests: XCTestCase {
    private struct Fixture {
        let root: URL, frozen: URL, manifest: AutomationSourceManifest, graph: AutomationSourceGraph
    }
    private func fixture(role: String = "explicitSwiftMembership") throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("prepared-source-integrity-" + UUID().uuidString)
        let original = root.appendingPathComponent("original"), session = root.appendingPathComponent("prepare")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data("struct Captured: AppIntent {}\n".utf8).write(to: original.appendingPathComponent("Source.swift"))
        let manifest = try AutomationSourceSnapshot.capture(source: original, sessionRoot: session)
        let file = try XCTUnwrap(manifest.files.first)
        var graph = AutomationSourceGraph(sourceManifestDigest: try manifest.digest, projectRelativePath: "App.xcodeproj", targetID: "APP", configuration: "Debug", nodes: [], edges: [],
            inputs: [.init(relativePath: file.relativePath, sha256: file.sha256, owner: "App.xcodeproj#APP", role: role)], declarations: [], gaps: [])
        if role == "synchronizedSwiftMembership" { graph.synchronizedMembershipVersion = 1 }
        return .init(root: root, frozen: session.appendingPathComponent("source"), manifest: manifest, graph: graph)
    }
    func testEveryScannedOrUncertainInputIsCheckedAndPrivateMutationPreservesOriginal() throws {
        for role in ["explicitSwiftMembership", "packageSwiftMembership", "synchronizedSwiftMembership", "inactiveSwiftMembership", "unresolvedSwiftMembership", "packageManifest", "buildConfiguration"] {
            let fixture = try fixture(role: role)
            try AutomationPreparedSourceIntegrity.verify(graph: fixture.graph, manifest: fixture.manifest, frozenRoot: fixture.frozen)
            try Data("struct Mutated: AppIntent {}\n".utf8).write(to: fixture.frozen.appendingPathComponent("Source.swift"))
            XCTAssertThrowsError(try AutomationPreparedSourceIntegrity.verify(graph: fixture.graph, manifest: fixture.manifest, frozenRoot: fixture.frozen)) { error in
                XCTAssertEqual(error as? AutomationContractError, .conflictingOperation)
            }
            try AutomationSourceSnapshot.verifyOriginal(fixture.manifest)
        }
    }
    func testMissingLinkedAndForeignInputsCannotPass() throws {
        let fixture = try fixture(), path = fixture.frozen.appendingPathComponent("Source.swift")
        try FileManager.default.removeItem(at: path)
        XCTAssertThrowsError(try AutomationPreparedSourceIntegrity.verify(graph: fixture.graph, manifest: fixture.manifest, frozenRoot: fixture.frozen))
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: fixture.manifest.files[0].inputPath)
        XCTAssertThrowsError(try AutomationPreparedSourceIntegrity.verify(graph: fixture.graph, manifest: fixture.manifest, frozenRoot: fixture.frozen))
        var graph = fixture.graph
        graph.inputs[0].relativePath = "../original/Source.swift"
        XCTAssertThrowsError(try AutomationPreparedSourceIntegrity.verify(graph: graph, manifest: fixture.manifest, frozenRoot: fixture.frozen))
        graph = fixture.graph; graph.sourceManifestDigest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try AutomationPreparedSourceIntegrity.verify(graph: graph, manifest: fixture.manifest, frozenRoot: fixture.frozen))
    }
    func testDuplicateOwnerCannotHideConflictingHashAndCapturedEntriesAreUnique() throws {
        let fixture = try fixture()
        var graph = fixture.graph, second = graph.inputs[0]
        second.owner = "Package.swift#target:Other"; graph.inputs.append(second)
        try AutomationPreparedSourceIntegrity.verify(graph: graph, manifest: fixture.manifest, frozenRoot: fixture.frozen)
        graph.inputs[1].sha256 = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try AutomationPreparedSourceIntegrity.verify(graph: graph, manifest: fixture.manifest, frozenRoot: fixture.frozen))
        var manifest = fixture.manifest; manifest.files.append(manifest.files[0])
        graph = fixture.graph; graph.sourceManifestDigest = try manifest.digest
        XCTAssertThrowsError(try AutomationPreparedSourceIntegrity.verify(graph: graph, manifest: manifest, frozenRoot: fixture.frozen))
    }
    func testGeneratorOwnedFilesAreOutsideCapturedDiscoveryInputs() throws {
        let fixture = try fixture()
        try Data("generated host\n".utf8).write(to: fixture.frozen.appendingPathComponent("GeneratedHost.swift"))
        try AutomationPreparedSourceIntegrity.verify(graph: fixture.graph, manifest: fixture.manifest, frozenRoot: fixture.frozen)
        try AutomationSourceSnapshot.verifyOriginal(fixture.manifest)
    }
}
