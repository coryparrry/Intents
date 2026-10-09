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
    private func read(_ value: [String: Any]) throws -> AutomationImportedSiriSubmission {
        try AutomationSiriSubmissionReceipt.importReceipt(JSONSerialization.data(withJSONObject: value), scope: scope, app: app, program: program)
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
}
