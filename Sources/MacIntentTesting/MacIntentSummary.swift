import Foundation
import CoreFoundation

/// A successful xcodebuild exit alone does not prove that every authored test ran.
enum MacIntentSummary {
    /// Requires the result summary to report every authored test passed, with no skipped, failed, or expected-failure tests.
    /// Throws when required counts are absent, malformed, or disagree with `expectedCount`.
    static func validate(_ data: Data, expectedCount: Int) throws {
        guard expectedCount > 0,
              let summary = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = summary["result"] as? String,
              let passed = count(summary["passedTests"]),
              let total = count(summary["totalTestCount"]),
              let failed = count(summary["failedTests"]),
              let skipped = count(summary["skippedTests"]),
              let expectedFailures = count(summary["expectedFailures"]) else {
            throw MacIntentTestingError("The result bundle summary is missing required test counts. Native test success could not be verified.")
        }
        guard result == "Passed", passed == expectedCount, total == expectedCount,
              failed == 0, skipped == 0, expectedFailures == 0 else {
            throw MacIntentTestingError("The result bundle did not confirm every authored test passed: result=\(result), passed=\(passed), total=\(total), failed=\(failed), skipped=\(skipped), expectedFailures=\(expectedFailures), authored=\(expectedCount).")
        }
    }

    /// Accepts only nonnegative integer JSON numbers, excluding Boolean values and nonintegral numeric text.
    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue), integer >= 0 else { return nil }
        return integer
    }
}
