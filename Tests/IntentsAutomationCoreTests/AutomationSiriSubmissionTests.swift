import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationSiriSubmissionTests: XCTestCase {
    private let target = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
    private let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: String(repeating: "a", count: 64))
    private let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "siri", leaseGeneration: 1)
    private let program = AutomationSiriTextProgram(request: "Complete the approved test task in Example")
    private func segment() -> AutomationSegment {
        var value = AutomationSegment(id: "siri", kind: .siriText, phase: .subject, operation: "submitRecognizedText",
            requiredCapabilities: ["siri.recognizedText.api"], effects: [.navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
        value.siriProgram = program; return value
    }
    private func receipt() -> [String: Any] {
        ["schemaVersion": 1, "runID": "run", "attemptID": "attempt", "segmentID": "siri", "leaseGeneration": 1,
         "bundleID": app.bundleID, "productDigest": app.productDigest!, "requestDigest": program.requestDigest,
         "submissionStarted": true, "submissionReturned": true,
         "runner": ["pid": 42, "startIdentity": "1:2", "executablePath": "/private/var/containers/Bundle/Application/fixture/Owned-Runner.app/Owned-Runner"]]
    }
    private func read(_ value: [String: Any], app: AppIdentity? = nil) throws -> AutomationImportedSiriSubmission {
        try read(JSONSerialization.data(withJSONObject: value), app: app)
    }
    private func read(_ data: Data, app: AppIdentity? = nil) throws -> AutomationImportedSiriSubmission {
        try AutomationSiriSubmissionReceipt.importReceipt(data, scope: scope, app: app ?? self.app, program: program)
    }
    private func assertRejected(_ value: [String: Any], app: AppIdentity? = nil, _ message: String, line: UInt = #line) {
        XCTAssertThrowsError(try read(value, app: app), message, line: line) {
            XCTAssertEqual($0 as? AutomationContractError, .invalidIdentity, message, line: line)
        }
    }
    private func receipt(runner changes: [String: Any?]) -> [String: Any] {
        var value = receipt(), runner = value["runner"] as! [String: Any]
        for (key, change) in changes { runner[key] = change }
        value["runner"] = runner; return value
    }
    func testFrozenPhysicalSubmissionProgramAndCodableRoundTrip() throws {
        let segment = segment(); try program.validate(segment: segment, target: target)
        XCTAssertEqual(try JSONDecoder().decode(AutomationSegment.self, from: JSONEncoder().encode(segment)), segment)
        for request in ["", "  \n", "bad\0request", String(repeating: "x", count: 2049)] {
            XCTAssertThrowsError(try AutomationSiriTextProgram(request: request).validate(segment: segment, target: target))
        }
        XCTAssertThrowsError(try program.validate(segment: segment, target: .init(id: UUID().uuidString, kind: .simulator)))
        for mutation in [0,1,2,3,4] {
            var changed = segment
            switch mutation {
            case 0: changed.kind = .systemIntent
            case 1: changed.phase = .observe
            case 2: changed.lifecycle = .processContinuityRequired
            case 3: changed.requiredCapabilities = []
            default: changed.inputs = ["request": .text("another request")]
            }
            XCTAssertThrowsError(try program.validate(segment: changed, target: target))
        }
    }
    func testReturnedReceiptCorrelatesSubmissionWithoutBusinessOutputs() throws {
        let imported = try read(receipt())
        XCTAssertEqual(imported.requestDigest, program.requestDigest)
        XCTAssertEqual(imported.runner.pid, 42)
        // Remote PID is data only: no local presence check or process signal.
        XCTAssertEqual(imported.runner.startIdentity, "1:2")
    }
    func testPhysicalOSBuildIsRequiredAndBoundedInVersionTwo() throws {
        var value = receipt(); value["schemaVersion"] = 2; value["osBuild"] = "24B5028f"
        XCTAssertEqual(try read(value).osBuild, "24B5028f")
        XCTAssertNil(try read(receipt()).osBuild, "Historical submission receipts cannot qualify a current device environment")
        for invalid in ["", "bad\nversion", String(repeating: "x", count: 129)] {
            value["osBuild"] = invalid; XCTAssertThrowsError(try read(value))
        }
    }
    func testCheckpointUnreturnedForeignScopeAndInventedOutcomeCannotComplete() {
        for (key, value) in [("submissionReturned", false as Any), ("submissionStarted", false),
                             ("runID", "other"), ("attemptID", "other"), ("segmentID", "other"),
                             ("leaseGeneration", 2), ("bundleID", "foreign.App"), ("requestDigest", String(repeating: "b", count: 64)),
                             ("productDigest", String(repeating: "b", count: 64)), ("schemaVersion", 2)] {
            var changed = receipt(); changed[key] = value; XCTAssertThrowsError(try read(changed), key)
        }
        for key in ["recognizedRequest", "invocationCompleted", "businessOutcome", "observations"] {
            var changed = receipt(); changed[key] = true; XCTAssertThrowsError(try read(changed), key)
        }
    }
    func testReceiptSizeIsBoundedAt16KiB() throws {
        let encoded = try JSONSerialization.data(withJSONObject: receipt())
        let padding = { (count: Int) in encoded + Data(repeating: UInt8(ascii: " "), count: count - encoded.count) }
        XCTAssertEqual(try read(padding(16_384)).runner.pid, 42)
        XCTAssertThrowsError(try read(padding(16_385))) { XCTAssertEqual($0 as? AutomationContractError, .invalidIdentity) }
    }
    func testRunnerPIDMustBeAPositiveInt32() throws {
        XCTAssertEqual(try read(receipt(runner: ["pid": 1])).runner.pid, 1)
        XCTAssertEqual(try read(receipt(runner: ["pid": 2_147_483_647])).runner.pid, Int32.max)
        for pid: Any in [0, -1, 1.5, 2_147_483_648, "42", true] {
            assertRejected(receipt(runner: ["pid": pid]), "pid \(pid)")
        }
    }
    func testRunnerStartIdentityMustBeBootAndStartCounters() throws {
        XCTAssertEqual(try read(receipt(runner: ["startIdentity": "12345678901234567890:123456"])).runner.startIdentity,
                       "12345678901234567890:123456")
        for start: Any in ["abc", "1:1234567", "123456789012345678901:1", "", "1:", ":2", "1:2 ", "-1:2", 12] {
            assertRejected(receipt(runner: ["startIdentity": start]), "startIdentity \(start)")
        }
    }
    func testRunnerExecutablePathMustBeAbsoluteSingleLineAndBounded() throws {
        let longest = "/" + String(repeating: "x", count: 4095)
        XCTAssertEqual(try read(receipt(runner: ["executablePath": longest])).executablePath, longest)
        for path: Any in ["relative/Owned-Runner", "", "/runner\0suffix", "/runner\nsuffix", "/" + String(repeating: "x", count: 4096), 7] {
            assertRejected(receipt(runner: ["executablePath": path]), "executablePath \(path)")
        }
    }
    func testRunnerMustBeExactlyPIDStartIdentityAndExecutablePath() {
        for key in ["pid", "startIdentity", "executablePath"] {
            assertRejected(receipt(runner: [key: nil]), "missing runner.\(key)")
        }
        assertRejected(receipt(runner: ["bundleID": "example.App"]), "extra runner key")
        var missing = receipt(); missing["runner"] = nil; assertRejected(missing, "missing runner")
        for runner: Any in ["/runner", 42, [42, "1:2"], NSNull()] {
            var changed = receipt(); changed["runner"] = runner; assertRejected(changed, "runner \(runner)")
        }
    }
    func testProductDigestVersionKeyIsRequiredExactlyWhenTheAppDeclaresIt() throws {
        var versioned = app; versioned.productDigestVersion = 1
        var value = receipt(); value["productDigestVersion"] = 1
        XCTAssertEqual(try read(value, app: versioned).runner.pid, 42)
        assertRejected(receipt(), app: versioned, "versioned app without productDigestVersion")
        assertRejected(value, "unversioned app with productDigestVersion")
        for version: Any in [2, 0, "1", NSNull()] {
            var changed = value; changed["productDigestVersion"] = version
            assertRejected(changed, app: versioned, "productDigestVersion \(version)")
        }
        var unsupported = app; unsupported.productDigestVersion = 2
        value["productDigestVersion"] = 2; assertRejected(value, app: unsupported, "unsupported app productDigestVersion")
    }
    func testAppMustBeIOSWithLowercaseHexProductDigest() {
        var mac = app; mac.platform = "macos"; assertRejected(receipt(), app: mac, "macos app")
        var undigested = app; undigested.productDigest = nil; assertRejected(receipt(), app: undigested, "missing product digest")
        for digest in [String(repeating: "A", count: 64), String(repeating: "g", count: 64),
                       String(repeating: "a", count: 63), String(repeating: "a", count: 65)] {
            var changed = app; changed.productDigest = digest
            var value = receipt(); value["productDigest"] = digest
            assertRejected(value, app: changed, "product digest \(digest)")
        }
    }
}
