#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

@MainActor
final class AutomationPrivateMacSDKUnitTests: XCTestCase {
    private func fixture() throws -> (URL, AutomationPrivateMacSDKUnit.Receipt) {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        let root = try AutomationPath.canonical(requested)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var paths = [AutomationPrivateMacSDKUnit.helperPath, "agent-device/package.json", "agent-device/bin/agent-device.mjs",
            "agent-device/LICENSE", "agent-device/intents-private-lifecycle-patch.json", "agent-device/dist/src/index.js"]
        paths += (0..<466).map { "agent-device/dist/src/fixture-\($0).js" }
        let data = Data("synthetic SDK file".utf8), digest = AutomationArtifactRegistry.digest(data)
        for relative in paths {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let receipt = AutomationPrivateMacSDKUnit.Receipt(schemaVersion: 1, artifactVariant: "private-owned-mac-source",
            customerRuntimeEnabled: false, hardwareQualified: false, developerIDSigned: false, helperInvoked: false,
            sourceRevision: "35f407e6e9352544847732d3b8aa74b7b3d34d51",
            officialArchiveSHA256: "2dadf033c359810e0623479206048c6d4696874d1cf6aa03f1b0090a531b2e48",
            sdkInventorySHA256: "872fd17f3a397e7b058813dd1ed2132e18834a47733c880acb6cfeb88dc56105",
            helperCheckpointSHA256: "2ec8bc561a0d36802ee9a1a99849d3e0d6c000aba7132178d92294a5ac8debd4",
            helperRelativePath: AutomationPrivateMacSDKUnit.helperPath, requiredHelperEnvironment: "AGENT_DEVICE_MACOS_HELPER_BIN",
            files: Dictionary(uniqueKeysWithValues: paths.map { ($0, digest) }))
        return (root, receipt)
    }
    private func write(_ receipt: AutomationPrivateMacSDKUnit.Receipt, root: URL) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        try data.write(to: root.appendingPathComponent(AutomationPrivateMacSDKUnit.receiptName))
        return AutomationArtifactRegistry.digest(data)
    }
    private func verify(_ receipt: AutomationPrivateMacSDKUnit.Receipt, root: URL) throws -> AutomationPrivateMacSDKUnit.Evidence {
        try AutomationPrivateMacSDKUnit.verify(root: root, expectedReceiptSHA256: write(receipt, root: root))
    }
    func testValidationReturnsOnlyDisabledEvidenceAndProductionRejectsSyntheticReceipt() throws {
        let (root, receipt) = try fixture(), evidence = try verify(receipt, root: root)
        XCTAssertEqual(evidence.fileCount, 472); XCTAssertEqual(evidence.artifactVariant, "private-owned-mac-source")
        XCTAssertFalse(evidence.customerRuntimeEnabled); XCTAssertFalse(evidence.hardwareQualified); XCTAssertFalse(evidence.developerIDSigned)
        XCTAssertThrowsError(try AutomationRuntimeBundle.verifiedPrivateMacSDKUnit(root: root))
    }
    func testEnabledQualifiedOrRelabelledReceiptsAreRejected() throws {
        let (root, receipt) = try fixture()
        for change: (inout AutomationPrivateMacSDKUnit.Receipt) -> Void in [
            { $0.customerRuntimeEnabled = true }, { $0.hardwareQualified = true }, { $0.developerIDSigned = true },
            { $0.helperInvoked = true }, { $0.artifactVariant = "published-npm" }, { $0.schemaVersion = 2 },
            { $0.sourceRevision = "unknown" }, { $0.requiredHelperEnvironment = "OTHER_HELPER" },
            { $0.helperRelativePath = "agent-device/dist/other" }, { $0.sdkInventorySHA256 = String(repeating: "0", count: 64) }] {
            var bad = receipt; change(&bad)
            XCTAssertThrowsError(try verify(bad, root: root))
        }
    }
    func testMissingExtraAndModifiedPayloadFilesAreRejected() throws {
        for modification in ["missing", "extra", "modified"] {
            let (root, receipt) = try fixture()
            switch modification {
            case "missing": try FileManager.default.removeItem(at: root.appendingPathComponent(AutomationPrivateMacSDKUnit.helperPath))
            case "extra": try Data("extra".utf8).write(to: root.appendingPathComponent("unlisted.js"))
            default: try Data("modified".utf8).write(to: root.appendingPathComponent("agent-device/dist/src/index.js"))
            }
            XCTAssertThrowsError(try verify(receipt, root: root))
        }
    }
    func testSymlinkHardlinkAndWritablePayloadsAreRejected() throws {
        for modification in ["symlink", "hardlink", "writable"] {
            let (root, receipt) = try fixture(), file = root.appendingPathComponent("agent-device/dist/src/index.js")
            if modification == "writable" {
                try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
            } else {
                try FileManager.default.removeItem(at: file)
                let source = root.appendingPathComponent("agent-device/LICENSE")
                if modification == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source) }
                else { try FileManager.default.linkItem(at: source, to: file) }
            }
            XCTAssertThrowsError(try verify(receipt, root: root))
        }
    }
    func testReceiptAndRootAliasesAreRejected() throws {
        let (root, receipt) = try fixture(), digest = try write(receipt, root: root)
        let alias = root.appendingPathComponent("root-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try AutomationPrivateMacSDKUnit.verify(root: alias, expectedReceiptSHA256: digest))
        try FileManager.default.removeItem(at: alias)
        let original = root.appendingPathComponent(AutomationPrivateMacSDKUnit.receiptName)
        let saved = root.appendingPathComponent("receipt-original")
        try FileManager.default.moveItem(at: original, to: saved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: saved)
        XCTAssertThrowsError(try AutomationPrivateMacSDKUnit.verify(root: root, expectedReceiptSHA256: digest))
    }
    func testTraversalDigestCountAndDepthLimitsAreRejected() throws {
        let (root, receipt) = try fixture()
        for change: (inout AutomationPrivateMacSDKUnit.Receipt) -> Void in [
            { $0.files["agent-device/dist/src/index.js"] = "bad" },
            { $0.files["agent-device/../outside"] = $0.files.removeValue(forKey: "agent-device/dist/src/index.js") },
            { $0.files.removeValue(forKey: AutomationPrivateMacSDKUnit.helperPath) }] {
            var bad = receipt; change(&bad)
            XCTAssertThrowsError(try verify(bad, root: root))
        }
        let deep = (0..<34).reduce(root) { $0.appendingPathComponent("dir\($1)") }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        XCTAssertThrowsError(try verify(receipt, root: root))
    }
    func testFrozenPrivateUnitAtPublicLoaderBoundaryWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_PRIVATE_MAC_SDK_UNIT_ROOT"] else {
            throw XCTSkip("Read-only frozen private SDK unit qualification is opt-in")
        }
        let evidence = try AutomationRuntimeBundle.verifiedPrivateMacSDKUnit(root: URL(fileURLWithPath: path))
        XCTAssertEqual(evidence.receiptSHA256, AutomationPrivateMacSDKUnit.pinnedReceiptSHA256)
        XCTAssertEqual(evidence.fileCount, 472); XCTAssertFalse(evidence.customerRuntimeEnabled)
    }
}
#endif
