import XCTest
@testable import IntentsAutomationCore

final class AutomationXCUITestTargetPathTests: XCTestCase {
    func testFreezePinsExpectedPrivateAppPathOnlyForNativeMac() throws {
        let root = URL(fileURLWithPath: "/private/tmp/xcuitest-target-path-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for kind in [TargetIdentity.Kind.nativeMac, .simulator] {
            let directory = root.appendingPathComponent(kind.rawValue)
            let host = directory.appendingPathComponent("Host-Runner.app")
            let subject = directory.appendingPathComponent("Subject.app")
            let plugin = kind == .nativeMac ? "Contents/PlugIns/Host.xctest" : "PlugIns/Host.xctest"
            try FileManager.default.createDirectory(at: host.appendingPathComponent(plugin), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: subject, withIntermediateDirectories: true)
            let entry: [String: Any] = ["BlueprintName": "Host", "TestHostPath": host.path,
                "TestBundlePath": host.appendingPathComponent(plugin).path, "UITargetAppPath": subject.path,
                "IsUITestBundle": true, "EnvironmentVariables": ["INTENTS_AUTOMATION_EXPECTED_APP_PATH": "/untrusted/Other.app"]]
            let app = AppIdentity(logicalID: "fixture", bundleID: "example.Fixture",
                platform: kind == .nativeMac ? "macos" : "ios", productDigest: String(repeating: "a", count: 64))
            let prepared = AutomationPreparedAppleHost(app: app, target: .init(id: "target", kind: kind),
                xctestrunPath: directory.appendingPathComponent("host.xctestrun").path,
                xctestrunDigest: String(repeating: "b", count: 64), subjectProductPath: subject.path,
                hostBundlePath: host.path, hostProductDigest: String(repeating: "c", count: 64),
                hostBundleID: "example.Host.xctrunner", testTarget: "Host")
            for modern in [false, true] {
                let descriptor: [String: Any] = modern ? ["TestConfigurations": [["TestTargets": [entry]]]] : ["Host": entry]
                let frozen = try AutomationXCUITestRouteDriver.freeze(descriptor, prepared: prepared, payload: Data("plan".utf8))
                let target: [String: Any]
                if modern {
                    let configurations = try XCTUnwrap(frozen["TestConfigurations"] as? [[String: Any]])
                    target = try XCTUnwrap((configurations[0]["TestTargets"] as? [[String: Any]])?.first)
                } else { target = try XCTUnwrap(frozen["Host"] as? [String: Any]) }
                let environment = try XCTUnwrap(target["EnvironmentVariables"] as? [String: String])
                XCTAssertEqual(environment["INTENTS_AUTOMATION_EXPECTED_APP_PATH"], kind == .nativeMac ? subject.path : nil)
                XCTAssertEqual(environment["INTENTS_AUTOMATION_UI_PLAN_B64"], Data("plan".utf8).base64EncodedString())
            }
        }
    }
}
