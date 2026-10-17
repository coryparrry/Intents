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

    #if os(macOS)
    private actor MacInventoryAnswers {
        private let completeOnRelease: Bool
        private(set) var calls = 0
        init(completeOnRelease: Bool) { self.completeOnRelease = completeOnRelease }
        func inspect() -> AutomationMacProcessInventory {
            calls += 1
            var inventory = AutomationMacProcessInventory(userID: 501,
                complete: calls == 1 || completeOnRelease, processes: [])
            inventory.executableScope = ["/private/tmp/Subject", "/private/tmp/Runner"].sorted()
            return inventory
        }
    }

    func testMacReleaseRetriesIndependentStopObservationAfterInitialDrainFailure() async throws {
        for observedAbsent in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcuitest-mac-release-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "macos", productDigest: String(repeating: "a", count: 64))
            let prepared = AutomationPreparedAppleHost(app: app, target: .init(id: "native-mac", kind: .nativeMac),
                xctestrunPath: root.appendingPathComponent("unused.xctestrun").path, xctestrunDigest: String(repeating: "b", count: 64),
                subjectProductPath: root.appendingPathComponent("Subject.app").path, hostBundlePath: root.appendingPathComponent("Host.app").path,
                hostProductDigest: String(repeating: "c", count: 64), hostBundleID: "example.Host.xctrunner", testTarget: "Host")
            let answers = MacInventoryAnswers(completeOnRelease: observedAbsent)
            let lifecycle = AutomationMacXCUITestLifecycle(paths: ["/private/tmp/Subject", "/private/tmp/Runner"],
                userID: 501, inspect: { await answers.inspect() }, validate: {})
            try await lifecycle.prepare()
            let driver = AutomationXCUITestRouteDriver(prepared: prepared, root: root,
                artifacts: try AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts")),
                developerDirectory: URL(fileURLWithPath: "/unused"))
            await driver.markTestStarted(macLifecycle: lifecycle)
            let first = await driver.release(commandsDrained: false)
            XCTAssertFalse(first.commandsDrained)
            XCTAssertFalse(first.runnerTerminated)
            let beforeRetry = await answers.calls
            XCTAssertEqual(beforeRetry, 1, "A failed drain must not inspect subject or runner absence")
            for _ in 0..<2 {
                let retried = await driver.release(commandsDrained: true)
                XCTAssertTrue(retried.commandsDrained)
                XCTAssertEqual(retried.runnerTerminated, observedAbsent,
                    "A successful drain still requires independent Mac absence proof")
                XCTAssertTrue(retried.privatePayloadCleaned)
            }
            let afterRetry = await answers.calls
            XCTAssertEqual(afterRetry, 2, "Observe pending Mac termination once; retain either verified absence or failure")
        }
    }
    #endif

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
