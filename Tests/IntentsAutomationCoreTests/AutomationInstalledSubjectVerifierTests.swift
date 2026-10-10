#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationInstalledSubjectVerifierTests: XCTestCase {
    private let mac = TargetIdentity(id: "mac", kind: .nativeMac, loginSession: "test")
    private let simulator = TargetIdentity(id: "6F1E2D3C-4B5A-6978-8A9B-0C1D2E3F4A5B", kind: .simulator)
    private let physical = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
    private let unavailable = AutomationContractError.missingEvidence("Installed product bytes unavailable for this target")

    private func bundle(identifier: String = "example.Subject") throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/installed-subject-" + UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try writeInfo(identifier: identifier, root: root)
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0]).write(to: root.appendingPathComponent("Contents/MacOS/Subject"))
        return root
    }
    private func writeInfo(identifier: String, root: URL) throws {
        let info = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": identifier, "CFBundleExecutable": "Subject"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
    }
    private func macApp(_ root: URL?, digest: String?, bundleID: String = "example.Subject") -> AppIdentity {
        var app = AppIdentity(logicalID: "subject", bundleID: bundleID, platform: "macos", productDigest: digest)
        app.canonicalBundlePath = root?.path; app.productDigestVersion = 2
        return app
    }
    private func verifier(_ workspace: URL = URL(fileURLWithPath: "/private/tmp")) -> AutomationInstalledSubjectVerifier {
        AutomationInstalledSubjectVerifier(developerDirectory: URL(fileURLWithPath: "/private/tmp/missing-developer-" + UUID().uuidString), workspace: workspace)
    }
    private func assertRefuses(_ app: AppIdentity, on target: TargetIdentity, with expected: AutomationContractError,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { try await verifier().verify(app: app, target: target); XCTFail("Accepted \(app.bundleID) on \(target.kind)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AutomationContractError, expected, file: file, line: line) }
    }

    func testMatchingNativeMacBundleIsAccepted() async throws {
        let root = try bundle()
        try await verifier(root).verify(app: macApp(root, digest: AutomationProductDigest.compute(bundle: root, version: 2)), target: mac)
    }
    func testIdentityMustNameABundleForTheTargetPlatform() async throws {
        let root = try bundle(), digest = try AutomationProductDigest.compute(bundle: root, version: 2)
        var iosOnMac = macApp(root, digest: digest); iosOnMac.platform = "ios"
        await assertRefuses(iosOnMac, on: mac, with: .invalidIdentity)
        await assertRefuses(macApp(root, digest: digest), on: simulator, with: .invalidIdentity)
        await assertRefuses(macApp(root, digest: digest), on: physical, with: .invalidIdentity)
        await assertRefuses(macApp(root, digest: digest, bundleID: ""), on: mac, with: .invalidIdentity)
        await assertRefuses(AppIdentity(logicalID: "subject", bundleID: "", platform: "ios"), on: simulator, with: .invalidIdentity)
    }
    func testNativeMacDigestRequiresAnExistingCanonicalBundlePath() async throws {
        let root = try bundle(), digest = try AutomationProductDigest.compute(bundle: root, version: 2)
        await assertRefuses(macApp(nil, digest: digest), on: mac, with: .invalidIdentity)
        await assertRefuses(macApp(root.appendingPathComponent("Missing.app"), digest: digest), on: mac, with: .invalidIdentity)
    }
    func testChangedBundleBytesConflictWithTheApprovedDigest() async throws {
        let root = try bundle(), digest = try AutomationProductDigest.compute(bundle: root, version: 2)
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,1]).write(to: root.appendingPathComponent("Contents/MacOS/Subject"))
        XCTAssertNotEqual(digest, try AutomationProductDigest.compute(bundle: root, version: 2))
        await assertRefuses(macApp(root, digest: digest), on: mac, with: .conflictingOperation)
        let stale = try bundle()
        await assertRefuses(macApp(stale, digest: String(repeating: "0", count: 64)), on: mac, with: .conflictingOperation)
    }
    func testMatchingDigestForADifferentBundleIdentifierConflicts() async throws {
        let root = try bundle(identifier: "example.Foreign")
        let digest = try AutomationProductDigest.compute(bundle: root, version: 2)
        await assertRefuses(macApp(root, digest: digest, bundleID: "example.Subject"), on: mac, with: .conflictingOperation)
        try writeInfo(identifier: "example.Subject", root: root)
        let rebuilt = try AutomationProductDigest.compute(bundle: root, version: 2)
        XCTAssertNotEqual(digest, rebuilt)
        await assertRefuses(macApp(root, digest: digest, bundleID: "example.Foreign"), on: mac, with: .conflictingOperation)
        try await verifier(root).verify(app: macApp(root, digest: rebuilt), target: mac)
    }
    func testDigestOnTargetsWithoutReadableInstalledBytesIsRefused() async {
        let digest = String(repeating: "a", count: 64)
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: digest)
        await assertRefuses(app, on: physical, with: unavailable)
        await assertRefuses(app, on: .init(id: "booted", kind: .simulator), with: unavailable)
        await assertRefuses(AppIdentity(logicalID: "subject", bundleID: "example Subject;rm", platform: "ios", productDigest: digest), on: simulator, with: unavailable)
    }
    func testUndigestedSubjectsAreAcceptedOnlyOffPhysicalTargets() async throws {
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios")
        try await verifier().verify(app: app, target: simulator)
        try await verifier().verify(app: app, target: .init(id: "not-a-udid", kind: .simulator))
        try await verifier().verify(app: macApp(nil, digest: nil), target: mac)
        await assertRefuses(app, on: physical, with: .missingEvidence("Physical apps require positive installed-bundle presence evidence"))
    }
}
#endif
