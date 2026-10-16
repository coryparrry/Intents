#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationInstalledToolchainTests: XCTestCase {
    func testInstalledCandidateRankingUsesConfigurationThenSelectionThenVersionAndPath() throws {
        func candidate(_ name: String, _ version: [Int], _ preference: Int = 2) -> AutomationInstalledToolchain.Candidate {
            .init(directory: URL(fileURLWithPath: "/Applications/" + name + ".app/Contents/Developer"), version: version, preference: preference)
        }
        let latest = candidate("Xcode B", [27, 2]), tie = candidate("Xcode A", [27, 2]), older = candidate("Xcode C", [27, 1])
        let selected = candidate("Xcode selected", [26, 4], 1), configured = candidate("Xcode configured", [26, 3], 0)
        XCTAssertEqual(try AutomationInstalledToolchain.select(candidates: [older, latest, tie, selected, configured], requiredSDK: "macosx", probe: { _, _ in true }), configured.directory)
        XCTAssertEqual(try AutomationInstalledToolchain.select(candidates: [older, latest, tie, selected, configured], requiredSDK: "iphonesimulator", probe: { directory, _ in directory != configured.directory && directory != selected.directory }), tie.directory)
    }
    func testExactReviewedToolchainNeverProbesOrSelectsAnAlternative() throws {
        let selected = AutomationInstalledToolchain.Candidate(directory: URL(fileURLWithPath: "/Applications/Xcode-Beta.app/Contents/Developer"), version: [27, 2], preference: 0)
        let alternative = AutomationInstalledToolchain.Candidate(directory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), version: [27], preference: 1)
        var probes: [URL] = []
        XCTAssertThrowsError(try AutomationInstalledToolchain.select(candidates: [selected, alternative], requiredSDK: "macosx",
            requiredDirectory: selected.directory, probe: { directory, _ in probes.append(directory); return directory == alternative.directory }))
        XCTAssertEqual(probes, [selected.directory])
        probes = []
        XCTAssertThrowsError(try AutomationInstalledToolchain.select(candidates: [alternative], requiredSDK: "macosx",
            requiredDirectory: selected.directory, probe: { directory, _ in probes.append(directory); return true }))
        XCTAssertTrue(probes.isEmpty, "A missing selected installation cannot reach another compiler")
        XCTAssertEqual(try AutomationInstalledToolchain.select(candidates: [selected, alternative], requiredSDK: "macosx",
            probe: { directory, _ in directory == alternative.directory }), alternative.directory, "Default discovery keeps its existing fallback")
    }

    func testInvalidConfiguredDirectoryFallsBackToActualInstalledXcode() throws {
        let root = URL(fileURLWithPath: "/private/tmp/xcode-selection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try xcode("Xcode", in: root, version: "27.2")
        let candidates = AutomationInstalledToolchain.candidates(configured: root.appendingPathComponent("missing"), selected: nil, applications: [root])
        let installedPath = try AutomationPath.canonical(installed).path
        XCTAssertEqual(candidates.map { $0.directory.path }, [installedPath])
        XCTAssertEqual(try AutomationInstalledToolchain.select(candidates: candidates, requiredSDK: "macosx", probe: { _, _ in true }).path, installedPath)
    }
    func testNoEligibleToolchainHasSpecificRecoveryWithoutInstallation() {
        let candidate = AutomationInstalledToolchain.Candidate(directory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), version: [27], preference: 0)
        XCTAssertThrowsError(try AutomationInstalledToolchain.select(candidates: [candidate], requiredSDK: "iphoneos", probe: { _, _ in false })) { error in
            let reason = String(describing: error)
            XCTAssertTrue(reason.contains("No eligible installed Xcode")); XCTAssertTrue(reason.contains("iphoneos"))
            XCTAssertTrue(reason.contains("licence")); XCTAssertTrue(reason.contains("inspection remains available"))
        }
    }
    func testCommandLineToolsAndOtherAppsAreNotXcodeCandidates() throws {
        let root = URL(fileURLWithPath: "/private/tmp/xcode-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = try xcode("Other", in: root, version: "99.0", identifier: "example.other")
        XCTAssertTrue(AutomationInstalledToolchain.candidates(configured: fake, selected: root, applications: [root]).isEmpty)
    }
    func testDiskProbeRequiresBothCompilerAndRequestedSDK() throws {
        let root = URL(fileURLWithPath: "/private/tmp/xcode-sdk-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try xcode("Xcode", in: root, version: "27.2")
        for path in ["usr/bin/xcodebuild", "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"] {
            let file = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let sdk = directory.appendingPathComponent("Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try Data().write(to: sdk.appendingPathComponent("SDKSettings.plist"))
        XCTAssertTrue(AutomationInstalledToolchain.diskEligible(directory, sdk: "macosx"))
        XCTAssertFalse(AutomationInstalledToolchain.diskEligible(directory, sdk: "iphoneos"))
    }
    func testReviewedMetadataReplacementAtAsyncCommandFencePreventsLaunch() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/xcode-command-fence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try AutomationPath.canonical(xcode("Xcode", in: root, version: "27.2"))
        let versionFile = directory.deletingLastPathComponent().appendingPathComponent("version.plist")
        func writeBuild(_ build: String) throws {
            try PropertyListSerialization.data(fromPropertyList: ["ProductBuildVersion": build], format: .xml, options: 0).write(to: versionFile)
        }
        try writeBuild("27B5028f")
        let binding = AutomationReviewedToolchain(directory: directory, metadataDigest: try AutomationInstalledToolchain.metadata(directory: directory).digest)
        try binding.validate()
        let gate = ReviewedToolchainCommandGate(), command = AutomationOwnedCommand()
        let marker = root.appendingPathComponent("must-not-exist")
        let operation = Task {
            try await command.run(executable: AutomationPath.canonical(URL(fileURLWithPath: "/usr/bin/touch")),
                arguments: [marker.path], directory: root, environment: [:], timeout: .seconds(10),
                willStart: { await gate.suspend(); try binding.validate() })
        }
        await gate.waitForEntry()
        try writeBuild("27B9999")
        await gate.release()
        do { _ = try await operation.value; XCTFail("Changed reviewed metadata must prevent the command launch") }
        catch {
            XCTAssertTrue(String(describing: error).contains("reviewed Xcode installation changed"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "The command body must never run after the reviewed installation changes")
        XCTAssertNotEqual(try AutomationInstalledToolchain.metadata(directory: directory).digest, binding.metadataDigest)
    }
    private func xcode(_ name: String, in root: URL, version: String, identifier: String = "com.apple.dt.Xcode") throws -> URL {
        let contents = root.appendingPathComponent(name + ".app/Contents"), directory = contents.appendingPathComponent("Developer")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return directory
    }
}
private actor ReviewedToolchainCommandGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true; entry?.resume(); entry = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
}
#endif
