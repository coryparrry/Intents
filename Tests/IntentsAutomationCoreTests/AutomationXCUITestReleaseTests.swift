#if os(macOS) || os(Linux)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationXCUITestReleaseTests: XCTestCase, @unchecked Sendable {
    private actor TerminationAnswers {
        private let initial: Bool
        private(set) var calls = 0
        init(initial: Bool) { self.initial = initial }
        func verify() -> Bool {
            calls += 1
            return calls == 1 ? initial : !initial
        }
    }

    func testRepeatedReleaseKeepsFailedSubjectTerminationUnreleased() async throws {
        for terminated in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcuitest-release-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
            let prepared = AutomationPreparedAppleHost(app: app, target: .init(id: "simulator", kind: .simulator),
                xctestrunPath: root.appendingPathComponent("unused.xctestrun").path, xctestrunDigest: String(repeating: "b", count: 64),
                subjectProductPath: root.appendingPathComponent("Subject.app").path, hostBundlePath: root.appendingPathComponent("Host.app").path,
                hostProductDigest: String(repeating: "c", count: 64), hostBundleID: "example.Host.xctrunner", testTarget: "Host")
            let answers = TerminationAnswers(initial: terminated)
            let driver = AutomationXCUITestRouteDriver(prepared: prepared, root: root,
                artifacts: try AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts")),
                developerDirectory: URL(fileURLWithPath: "/unused"), simulatorTerminationVerifier: { await answers.verify() })
            // Exercise the same started-state transition used after owned test dispatch.
            await driver.markTestStarted()
            for _ in 0..<3 {
                let proof = await driver.release()
                XCTAssertTrue(proof.commandsDrained)
                XCTAssertEqual(proof.runnerTerminated, terminated,
                    "Repeated release must not turn a failed subject termination into a release proof")
                XCTAssertTrue(proof.privatePayloadCleaned)
            }
            let calls = await answers.calls
            XCTAssertEqual(calls, 1, "A repeated release must retain its prior termination result")
        }
    }
}
#endif
