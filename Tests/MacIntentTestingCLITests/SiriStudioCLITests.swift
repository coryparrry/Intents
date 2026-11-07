import Foundation
import Testing
@testable import MacIntentTestingCLI

/// Protects selection and timeout parsing for the native Siri CLI.
struct SiriStudioCLITests {
    /// Accepts repeated unique scenario IDs and a four-hour timeout, rejecting unsafe or irrelevant options.
    @Test func validatesRunOptionsAndShowPath() throws {
        let first = UUID(), second = UUID()
        let base = ["run", "--app", "/tmp/Courtside.app", "--scenarios", "scenarios.json",
                    "--developer-dir", "/Applications/Xcode.app/Contents/Developer", "--team", "TEAM",
                    "--identity", "Apple Development", "--output", "/tmp/evidence"]
        let options = try SiriStudioOptions(base + ["--scenario", first.uuidString, "--scenario", second.uuidString,
                                                     "--timeout", "14400", "--allowance", "1800"])
        #expect(options.scenarioIDs == [first, second])
        #expect(options.timeout == 14_400 && options.allowance == 1800)
        #expect(try SiriStudioOptions(["show", "--run", "/tmp/evidence"]).url("run").path == "/tmp/evidence")
        for invalid in [["--timeout", "NaN"], ["--timeout", "14401"], ["--allowance", "1801"],
                        ["--scenario", "not-a-uuid"], ["--scenario", first.uuidString, "--scenario", first.uuidString],
                        ["--team", "ANOTHER"], ["--device", "simulator"]] {
            #expect(throws: (any Error).self) { try SiriStudioOptions(base + invalid) }
        }
    }
}
