import Foundation
import Testing
@testable import MacIntentTesting

struct MacIntentSummaryTests {
    private func summary(result: String = "Passed", passed: Int = 7, total: Int = 7,
                         failed: Int = 0, skipped: Int = 0, expectedFailures: Int = 0) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["result": result, "passedTests": passed, "totalTestCount": total,
                                                    "failedTests": failed, "skippedTests": skipped, "expectedFailures": expectedFailures])
    }

    @Test func acceptsOnlyCompleteSuccessfulExecution() throws {
        try MacIntentSummary.validate(summary(), expectedCount: 7)
        try MacIntentSummary.validate(summary(passed: 1, total: 1), expectedCount: 1)
    }

    @Test func rejectsZeroMissingSkippedAndFailedTests() throws {
        let invalid = try [summary(passed: 0, total: 0), summary(passed: 6, total: 6),
                           summary(passed: 6, skipped: 1), summary(result: "Failed", passed: 6, failed: 1),
                           summary(passed: 6, expectedFailures: 1), summary(total: 8), summary(result: "Unknown")]
        for data in invalid {
            #expect(throws: (any Error).self) { try MacIntentSummary.validate(data, expectedCount: 7) }
        }
        #expect(throws: (any Error).self) { try MacIntentSummary.validate(summary(passed: 0, total: 0), expectedCount: 0) }
    }

    @Test func rejectsMissingMalformedAndIncorrectlyTypedCounts() throws {
        for field in ["result", "passedTests", "totalTestCount", "failedTests", "skippedTests", "expectedFailures"] {
            var object = try JSONSerialization.jsonObject(with: summary()) as! [String: Any]
            object.removeValue(forKey: field)
            let missing = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try MacIntentSummary.validate(missing, expectedCount: 7) }
        }
        let incorrectCounts: [Any] = [true, "7", -1, 7.5, NSNull()]
        for bad in incorrectCounts {
            var object = try JSONSerialization.jsonObject(with: summary()) as! [String: Any]
            object["passedTests"] = bad
            let malformed = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try MacIntentSummary.validate(malformed, expectedCount: 7) }
        }
        #expect(throws: (any Error).self) { try MacIntentSummary.validate(Data("not JSON".utf8), expectedCount: 7) }
        #expect(throws: (any Error).self) { try MacIntentSummary.validate(Data("[]".utf8), expectedCount: 7) }
    }
}
