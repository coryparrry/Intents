#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationPrivateMacDaemonUnitTests: XCTestCase {
    private func fixture() throws -> (URL, [String: Any]) {
        let root = URL(fileURLWithPath: "/private/tmp/intents-daemon-unit-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let names = ["node", "helpers/agent-device-macos-helper", "sidecar/src/macOwnedDaemonMain.js",
            "sdk/dist/src/intents-daemon.js", "intents-native-daemon-stage.json", "package-lock.json", "dependencies.lock.json"]
        var hashes: [String: String] = [:]
        for name in names {
            let file = root.appendingPathComponent(name), data = Data(("fixture " + name).utf8)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file); hashes[name] = AutomationArtifactRegistry.digest(data)
            try FileManager.default.setAttributes([.posixPermissions: name == "node" || name.hasPrefix("helpers/") ? 0o755 : 0o644], ofItemAtPath: file.path)
        }
        return (root, ["schemaVersion": 1, "artifactVariant": "private-owned-mac-daemon-integration",
            "customerRuntimeEnabled": false, "hardwareQualified": false, "developerIDSigned": false,
            "checkpointSHA256": String(repeating: "a", count: 64), "entryRelativePath": "sidecar/src/macOwnedDaemonMain.js",
            "nodeRelativePath": "node", "helperRelativePath": "helpers/agent-device-macos-helper",
            "enclosingApplicationVerified": false, "privateEntryExecuted": false, "files": hashes])
    }
    private func write(_ record: [String: Any], to root: URL) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent(AutomationPrivateMacDaemonUnit.receiptName))
        return AutomationArtifactRegistry.digest(data)
    }
    func testAvailableFillRuntimeRequiresWholeReceiptInventoryWithoutLaunching() throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_MAC_FILL_RUNTIME"] else { throw XCTSkip("Requires exact private fill daemon runtime") }
        let unit = try AutomationPrivateMacDaemonUnit.load(root: URL(fileURLWithPath: path))
        XCTAssertEqual(unit.evidence.receiptSHA256, AutomationPrivateMacDaemonUnit.pinnedFillProgramReceiptSHA256)
        XCTAssertEqual(unit.evidence.fileCount, 5475)
        XCTAssertEqual(unit.inputCapabilities, .ordinaryFillAndScroll)
        XCTAssertEqual(unit.inputCapabilities.helperSHA256, AutomationMacNativeHelperBridge.privateFillHelperSHA256)
        XCTAssertFalse(unit.evidence.hardwareQualified); XCTAssertFalse(unit.evidence.customerRuntimeEnabled)
    }
    func testAvailableV2RuntimePinsAllCompiledModulesWithoutLaunching() throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_MAC_V2_RUNTIME"] else { throw XCTSkip("Requires exact private v2 daemon runtime") }
        let unit = try AutomationPrivateMacDaemonUnit.load(root: URL(fileURLWithPath: path))
        XCTAssertEqual(unit.evidence.receiptSHA256, AutomationPrivateMacDaemonUnit.pinnedV2ProgramReceiptSHA256)
        XCTAssertEqual(unit.evidence.fileCount, 5481)
        XCTAssertEqual(unit.programDigestVersion, .lexicalV2)
        XCTAssertEqual(unit.inputCapabilities, .ordinaryFillAndScroll)
        XCTAssertFalse(unit.evidence.hardwareQualified); XCTAssertFalse(unit.evidence.customerRuntimeEnabled)
        XCTAssertFalse(unit.evidence.developerIDSigned)
    }
    func testInternalEvidenceHasNoCustomerAuthorityAndPublicPinRejectsFixture() throws {
        let (root, receipt) = try fixture(), digest = try write(receipt, to: root)
        let loaded = try AutomationPrivateMacDaemonUnit.load(root: root, expectedReceiptSHA256: digest)
        XCTAssertEqual(loaded.evidence.fileCount, 7)
        XCTAssertFalse(loaded.evidence.customerRuntimeEnabled); XCTAssertFalse(loaded.evidence.hardwareQualified)
        XCTAssertFalse(loaded.evidence.developerIDSigned)
        XCTAssertEqual(loaded.entry.path, root.appendingPathComponent("sidecar/src/macOwnedDaemonMain.js").path)
        XCTAssertThrowsError(try AutomationPrivateMacDaemonUnit.verify(root: root))
        XCTAssertThrowsError(try AutomationPrivateMacDaemonUnit.load(root: root, expectedReceiptSHA256: String(repeating: "0", count: 64)))
    }
    func testMissingExtraChangedAndNonExecutableFilesAreRejected() throws {
        for change in ["missing", "extra", "changed", "nonexecutable"] {
            let (root, receipt) = try fixture(), digest = try write(receipt, to: root), node = root.appendingPathComponent("node")
            switch change {
            case "missing": try FileManager.default.removeItem(at: node)
            case "extra": try Data().write(to: root.appendingPathComponent("unreviewed.js"))
            case "changed": try Data("different".utf8).write(to: node)
            default: try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: node.path)
            }
            XCTAssertThrowsError(try AutomationPrivateMacDaemonUnit.load(root: root, expectedReceiptSHA256: digest), change)
        }
    }
    func testSymlinksHardLinksAndWritableInputsAreRejected() throws {
        for change in ["symlink", "hardlink", "writable"] {
            let (root, receipt) = try fixture(), digest = try write(receipt, to: root), node = root.appendingPathComponent("node")
            if change == "writable" { try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: node.path) }
            else {
                let alias = root.appendingPathComponent("alias")
                if change == "symlink" { try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: node) }
                else { try FileManager.default.linkItem(at: node, to: alias) }
            }
            XCTAssertThrowsError(try AutomationPrivateMacDaemonUnit.load(root: root, expectedReceiptSHA256: digest), change)
        }
    }
    func testCallerCannotChangeBoundariesPathsOrReceiptShape() throws {
        for field in ["customerRuntimeEnabled", "hardwareQualified", "developerIDSigned", "enclosingApplicationVerified", "privateEntryExecuted", "entryRelativePath", "artifactVariant", "unknown"] {
            let (root, original) = try fixture(); var receipt = original
            receipt[field] = field.hasSuffix("Path") ? "../escape" : field == "artifactVariant" ? "customer" : true
            let digest = try write(receipt, to: root)
            XCTAssertThrowsError(try AutomationPrivateMacDaemonUnit.load(root: root, expectedReceiptSHA256: digest), field)
        }
        let (root, original) = try fixture(); var receipt = original, files = original["files"] as! [String: String]
        files["../escape"] = String(repeating: "0", count: 64); receipt["files"] = files
        XCTAssertThrowsError(try AutomationPrivateMacDaemonUnit.load(root: root, expectedReceiptSHA256: write(receipt, to: root)))
    }
    func testActualFrozenPolicyDiagnosticsUnitVerificationWhenExplicitlySelected() throws {
        guard let selected = ProcessInfo.processInfo.environment["INTENTS_MAC_POLICY_RUNTIME"] else { throw XCTSkip("Requires explicitly selected frozen policy diagnostics runtime") }
        let unit = try AutomationPrivateMacDaemonUnit.load(root: AutomationPath.canonical(URL(fileURLWithPath: selected)))
        XCTAssertEqual(unit.evidence.receiptSHA256, AutomationPrivateMacDaemonUnit.pinnedPolicyDiagnosticsProgramReceiptSHA256)
        XCTAssertEqual(unit.evidence.fileCount, 5487)
        XCTAssertEqual(unit.programDigestVersion, .lexicalV2)
        XCTAssertEqual(unit.inputCapabilities, .ordinaryFillAndScroll)
        XCTAssertEqual(unit.secretProgramEntry?.lastPathComponent, "secretProgramMain.js")
        XCTAssertFalse(unit.evidence.customerRuntimeEnabled); XCTAssertFalse(unit.evidence.hardwareQualified)
    }
    func testActualFrozenSecretUnitVerificationWhenExplicitlySelected() throws {
        guard let selected = ProcessInfo.processInfo.environment["INTENTS_MAC_SECRET_RUNTIME"] else { throw XCTSkip("Requires explicitly selected frozen secret runtime") }
        let unit = try AutomationPrivateMacDaemonUnit.load(root: AutomationPath.canonical(URL(fileURLWithPath: selected)))
        XCTAssertEqual(unit.evidence.receiptSHA256, AutomationPrivateMacDaemonUnit.pinnedSecretProgramReceiptSHA256)
        XCTAssertEqual(unit.evidence.fileCount, 5485); XCTAssertEqual(unit.programDigestVersion, .lexicalV2)
        XCTAssertEqual(unit.secretProgramEntry?.lastPathComponent, "secretProgramMain.js")
        XCTAssertFalse(unit.evidence.customerRuntimeEnabled); XCTAssertFalse(unit.evidence.hardwareQualified)
    }
    func testActualFrozenPrivateUnitVerificationWhenExplicitlySelected() throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTS_PRIVATE_DAEMON_UNIT"] else { throw XCTSkip("Requires the explicitly selected frozen private unit") }
        let evidence = try AutomationPrivateMacDaemonUnit.verify(root: URL(fileURLWithPath: path))
        let program = evidence.receiptSHA256 == AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256
        XCTAssertEqual(evidence.fileCount, program ? 5473 : 5465)
        XCTAssertEqual(evidence.receiptSHA256, program ? AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256 : AutomationPrivateMacDaemonUnit.pinnedReceiptSHA256)
        XCTAssertFalse(evidence.customerRuntimeEnabled); XCTAssertFalse(evidence.hardwareQualified)
    }
}
#endif
