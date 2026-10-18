#if os(macOS) || os(Linux)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationXCUITestReleaseTests: XCTestCase, @unchecked Sendable {
    private enum TerminationOutcome: CaseIterable, Sendable {
        case success, notRunning, rejected, timedOut
        var accepted: Bool { self == .success || self == .notRunning }
    }

    private actor TerminationCommands {
        let first: TerminationOutcome
        private(set) var calls: [(String, Duration)] = []
        init(first: TerminationOutcome) { self.first = first }
        func run(bundleID: String, timeout: Duration) throws -> AutomationOwnedCommand.Result {
            calls.append((bundleID, timeout))
            guard calls.count == 1 else {
                return .init(exitStatus: 0, stdout: Data(), stderr: Data(), logsTruncated: false)
            }
            switch first {
            case .success:
                return .init(exitStatus: 0, stdout: Data(repeating: 120, count: 9000), stderr: Data(), logsTruncated: false)
            case .notRunning:
                return .init(exitStatus: 3, stdout: Data(),
                    stderr: Data("NSPOSIXErrorDomain: found nothing to terminate".utf8), logsTruncated: false)
            case .rejected:
                return .init(exitStatus: 64, stdout: Data(), stderr: Data("simulator unavailable".utf8), logsTruncated: false)
            case .timedOut:
                throw AutomationRPCError.timedOut
            }
        }
    }

    func testSimulatorTerminationRetainsEachCommandAndItsBoundedFailure() async throws {
        for outcome in TerminationOutcome.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("simulator-release-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let commands = TerminationCommands(first: outcome)
            let stopped = await AutomationSimulatorTermination.stop(
                bundleIDs: ["example.Subject", "example.Host.xctrunner"], diagnosticRoot: root,
                run: { try await commands.run(bundleID: $0, timeout: $1) },
                retainedLogs: { .init(exitStatus: -1, stdout: Data(), stderr: Data("partial timeout log".utf8), logsTruncated: false) })
            XCTAssertEqual(stopped, outcome.accepted)
            let calls = await commands.calls
            XCTAssertEqual(calls.map(\.0), ["example.Subject", "example.Host.xctrunner"])
            XCTAssertTrue(calls.allSatisfy { $0.1 == .seconds(60) })
            let records = try JSONDecoder().decode([AutomationSimulatorTermination.Record].self,
                from: Data(contentsOf: root.appendingPathComponent("simulator-release.json")))
            XCTAssertEqual(records.map(\.bundleID), calls.map(\.0))
            XCTAssertEqual(records.map(\.accepted), [outcome.accepted, true])
            XCTAssertTrue(records[1].completed)
            XCTAssertNil(records[1].error)
            if outcome == .timedOut {
                XCTAssertFalse(records[0].completed)
                XCTAssertEqual(records[0].error, "timedOut")
                XCTAssertEqual(String(decoding: records[0].stderr, as: UTF8.self), "partial timeout log")
            } else {
                XCTAssertTrue(records[0].completed)
                XCTAssertNil(records[0].error)
                if outcome == .success {
                    XCTAssertEqual(records[0].stdout.count, 8192)
                    XCTAssertTrue(records[0].logsTruncated)
                } else if outcome == .rejected {
                    XCTAssertEqual(records[0].exitStatus, 64)
                    XCTAssertEqual(String(decoding: records[0].stderr, as: UTF8.self), "simulator unavailable")
                }
            }
        }
    }

    func testUnavailableTerminationDiagnosticsDoNotChangeTheReleaseDecision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("simulator-release-" + UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        for outcome in [TerminationOutcome.success, .rejected] {
            let commands = TerminationCommands(first: outcome)
            let stopped = await AutomationSimulatorTermination.stop(bundleIDs: ["example.Subject"], diagnosticRoot: root,
                run: { try await commands.run(bundleID: $0, timeout: $1) },
                retainedLogs: { .init(exitStatus: -1, stdout: Data(), stderr: Data(), logsTruncated: false) })
            XCTAssertEqual(stopped, outcome.accepted)
        }
    }

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
