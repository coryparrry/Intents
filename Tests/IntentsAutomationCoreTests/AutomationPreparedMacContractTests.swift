#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPreparedMacContractTests: XCTestCase, @unchecked Sendable {
    struct ArtifactFixture: Sendable {
        let root: URL
        let host: AutomationPreparedAppleHost
    }

    func fixture() throws -> ArtifactFixture {
        let root = URL(fileURLWithPath: "/private/tmp/prepared-mac-contract-" + UUID().uuidString)
        let host = root.appendingPathComponent("OwnedHost-Runner.app"), subject = root.appendingPathComponent("Subject.app")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (bundle, id, name) in [(host, "example.Host.xctrunner", "OwnedHost-Runner"), (subject, "example.Subject", "Subject")] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": id, "CFBundleExecutable": name, "CFBundleSupportedPlatforms": ["MacOSX"]]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0]).write(to: bundle.appendingPathComponent("Contents/MacOS/" + name))
        }
        try FileManager.default.createDirectory(at: host.appendingPathComponent("Contents/PlugIns/OwnedHost.xctest"), withIntermediateDirectories: true)
        let entry: [String: Any] = ["BlueprintName": "OwnedHost", "TestHostPath": "__TESTROOT__/OwnedHost-Runner.app",
                                  "TestBundlePath": "__TESTHOST__/Contents/PlugIns/OwnedHost.xctest", "UITargetAppPath": "__TESTROOT__/Subject.app", "IsUITestBundle": true]
        let testFile = root.appendingPathComponent("host.xctestrun"), data = try PropertyListSerialization.data(fromPropertyList: ["OwnedHost": entry], format: .xml, options: 0)
        try data.write(to: testFile)
        let target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-login")
        var app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "macos", productDigest: try AutomationProductDigest.compute(bundle: subject, version: 2))
        app.productDigestVersion = 2; app.canonicalBundlePath = subject.path
        let prepared = AutomationPreparedAppleHost(app: app, target: target, xctestrunPath: testFile.path, xctestrunDigest: AutomationArtifactRegistry.digest(data), subjectProductPath: subject.path,
            hostBundlePath: host.path, hostProductDigest: try AutomationProductDigest.compute(bundle: host, version: 2), hostBundleID: "example.Host.xctrunner", testTarget: "OwnedHost", hostProductDigestVersion: 2)
        return .init(root: root, host: prepared)
    }
}
#endif
