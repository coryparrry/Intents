import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationLinkedProductTests: XCTestCase {
    private func bundle() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/linked-product-" + UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let info = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "example.Linked", "CFBundleExecutable": "Subject"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0]).write(to: root.appendingPathComponent("Contents/MacOS/Subject"))
        return root
    }
    private func link(_ path: String, _ destination: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }
    func testV2SupportsFrameworkDirectoryAndFileLinksAndBindsTargetsWhileV1StaysFrozen() throws {
        let root = try bundle(), framework = "Contents/Frameworks/Example.framework"
        let file = root.appendingPathComponent(framework + "/Versions/A/Example")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("framework bytes".utf8).write(to: file)
        try link(framework + "/Versions/Current", "A", root: root)
        try link(framework + "/Example", "Versions/Current/Example", root: root)
        XCTAssertThrowsError(try AutomationProductDigest.compute(bundle: root))
        let initial = try AutomationProductDigest.compute(bundle: root, version: 2)
        XCTAssertEqual(initial, try AutomationProductDigest.compute(bundle: root, version: 2))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: AutomationProductDigest.manifestData(bundle: root, version: 2)) as? [String: Any])
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 2)
        XCTAssertEqual((manifest["links"] as? [[String: Any]])?.count, 2)
        try Data("changed framework".utf8).write(to: file)
        XCTAssertNotEqual(initial, try AutomationProductDigest.compute(bundle: root, version: 2))
        let beforeAlias = try AutomationProductDigest.compute(bundle: root, version: 2)
        let current = root.appendingPathComponent(framework + "/Versions/Current")
        try FileManager.default.removeItem(at: current)
        try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: "./A")
        XCTAssertNotEqual(beforeAlias, try AutomationProductDigest.compute(bundle: root, version: 2))
        XCTAssertThrowsError(try AutomationProductDigest.compute(bundle: root, version: 99))
    }
    func testEscapingAbsoluteDanglingCyclicAndOverdeepLinksFailClosed() throws {
        for destination in ["../../outside", "/private/tmp", "missing", "alias"] {
            let root = try bundle()
            try link("alias", destination, root: root)
            XCTAssertThrowsError(try AutomationProductDigest.compute(bundle: root, version: 2), destination)
        }
        let root = try bundle()
        for index in 0..<66 { try link("link\(index)", index == 65 ? "Contents" : "link\(index + 1)", root: root) }
        XCTAssertThrowsError(try AutomationProductDigest.compute(bundle: root, version: 2))
    }
    func testAliasSwapDuringHashingCannotReturnAManifest() throws {
        let root = try bundle()
        try link("alias", "Contents", root: root)
        let alias = root.appendingPathComponent("alias")
        var changed = false
        XCTAssertThrowsError(try AutomationProductDigest.manifestData(bundle: root, fileHashed: { _ in
            if !changed {
                changed = true
                try FileManager.default.removeItem(at: alias)
                try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "/private/tmp")
            }
        }, linkedProduct: true))
    }
    func testNativeIntakeAndCatalogUseV2IncludingInternalMetadataAlias() async throws {
        let root = try bundle()
        let metadata = root.appendingPathComponent("Contents/RealMetadata")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let document: [String: Any] = ["version": 1, "generator": ["name": "xcode-tools", "version": "27A266a"], "actions": [:]]
        try JSONSerialization.data(withJSONObject: document).write(to: metadata.appendingPathComponent("extract.actionsdata"))
        try link("Contents/Resources/Metadata.appintents", "../RealMetadata", root: root)
        let assessment = try AutomationApplicationIntake.assess(root)
        let app = try XCTUnwrap(assessment.candidates.first?.app)
        XCTAssertEqual(app.productDigestVersion, 2)
        XCTAssertEqual(app.productDigest, try AutomationProductDigest.compute(bundle: root, version: 2))
        let catalog = try AutomationSurfaceCatalogReader.read(app: app, product: root)
        XCTAssertTrue(catalog.systemActions.isEmpty)
        XCTAssertFalse(catalog.gaps.contains { $0.contains("unavailable") })
        let verifier = AutomationInstalledSubjectVerifier(developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), workspace: root)
        try await verifier.verify(app: app, target: .init(id: "mac", kind: .nativeMac, loginSession: "test"))
        var wrongVersion = app; wrongVersion.productDigestVersion = nil
        XCTAssertThrowsError(try AutomationSurfaceCatalogReader.read(app: wrongVersion, product: root))
        let alias = root.appendingPathComponent("Contents/Resources/Metadata.appintents")
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "/private/tmp")
        XCTAssertThrowsError(try AutomationSurfaceCatalogReader.read(app: app, product: root))
    }
    func testOldIdentityOmitsVersionAndCannotCompareOnlyAnAlgorithmChangeAsAFix() throws {
        let old = Data(#"{"logicalID":"subject","bundleID":"example.Subject","platform":"ios","productDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","provenanceStrength":"productBytes"}"#.utf8)
        let app = try JSONDecoder().decode(AppIdentity.self, from: old)
        XCTAssertNil(app.productDigestVersion)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as? [String: Any])
        XCTAssertNil(encoded["productDigestVersion"])
        let segment = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "Navigate", requiredCapabilities: [], effects: [.navigate], lifecycle: .persistedStateAcrossSegments)
        let plan = AutomationCase(id: "legacy", app: app, target: .init(id: "sim", kind: .simulator), environmentID: "env", execution: segment)
        let frozen = try AutomationFrozenCase(plan: plan)
        var changed = app; changed.productDigestVersion = 2; changed.productDigest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try AutomationFixContract.candidate(from: frozen, app: changed))
        changed.productDigestVersion = nil
        XCTAssertNoThrow(try AutomationFixContract.candidate(from: frozen, app: changed))
    }
    func testProductReadBindsActualBytesAndAliasTargetToFrozenManifestDuringABAReplacement() throws {
        let root = try bundle(), file = root.appendingPathComponent("Contents/Info.plist")
        let original = try Data(contentsOf: file), digest = try AutomationProductDigest.compute(bundle: root, version: 2)
        var stages: [AutomationProductDigest.ReadStage] = []
        XCTAssertThrowsError(try AutomationProductDigest.readFile(bundle: root, relativePath: "Contents/Info.plist", maximumBytes: 1_048_576, version: 2, expectedDigest: digest, stage: { stage in
            stages.append(stage)
            try (stage == .beforeRead ? Data("transient foreign metadata".utf8) : original).write(to: file, options: .atomic)
        }))
        XCTAssertEqual(stages.count, 2)
        XCTAssertEqual(try AutomationProductDigest.compute(bundle: root, version: 2), digest)
        try Data("permanent replacement".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try AutomationProductDigest.readFile(bundle: root, relativePath: "Contents/Info.plist", maximumBytes: 1_048_576, version: 2, expectedDigest: digest))
        try original.write(to: file, options: .atomic)
        try original.write(to: root.appendingPathComponent("Contents/Other.plist"))
        try link("Metadata", "Contents/Info.plist", root: root)
        let aliasedDigest = try AutomationProductDigest.compute(bundle: root, version: 2)
        let alias = root.appendingPathComponent("Metadata")
        XCTAssertThrowsError(try AutomationProductDigest.readFile(bundle: root, relativePath: "Metadata", maximumBytes: 1_048_576, version: 2, expectedDigest: aliasedDigest, stage: { stage in
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: stage == .beforeRead ? "Contents/Other.plist" : "Contents/Info.plist")
        }))
    }
}
