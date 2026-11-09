import Foundation

extension SiriStudioSource {
    /// Produces the macOS 27.3 XcodeGen project for the signed Swift Testing UI target.
    public static func project(configuration: MacIntentRunConfiguration, identifier: String) throws -> Data {
        try MacIntentSource.nativeProject(configuration: configuration, identifier: identifier, name: "SiriStudioRun",
                                          host: "SiriStudioHost", tests: "SiriStudioTests", prefix: "dev.intents.siri",
                                          macOS: "27.3")
    }

    /// Writes the editable project inputs and returns the exact generated Swift file's location.
    public static func prepareProject(in directory: URL, source: String,
                                      configuration: MacIntentRunConfiguration, identifier: UUID) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directory.appendingPathComponent("Host"), withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("Tests/SiriStudioTests.swift")
        try Data(source.utf8).write(to: sourceURL, options: .atomic)
        try """
        import SwiftUI
        @main struct SiriStudioHost: App {
            var body: some Scene { WindowGroup { Text("Siri Studio Test Runner") } }
        }
        """.write(to: directory.appendingPathComponent("Host/SiriStudioHost.swift"), atomically: true, encoding: .utf8)
        try project(configuration: configuration, identifier: identifier.uuidString.lowercased())
            .write(to: directory.appendingPathComponent("project.json"), options: .atomic)
        return sourceURL
    }

    /// Computes bounded allowances and rejects selections that cannot fit within a four-hour run.
    static func timeouts(for scenarios: [SiriStudioScenario], allowance: Int?, timeout: Double?) throws -> (Int, Double) {
        if let allowance, !(1...1800).contains(allowance) {
            throw MacIntentTestingError("The per-scenario allowance must be from 1 to 1,800 seconds.")
        }
        // xcodebuild applies one test allowance to the generated scheme. Budget the same bound per test.
        let longest = scenarios.map { min(1800, 90 * $0.turns.count * $0.repeatCount) }.max() ?? 90
        let effective = allowance ?? longest
        let calculated = 600 + effective * scenarios.count
        guard calculated <= 14_400 else {
            throw MacIntentTestingError("This selection may take more than four hours. Select fewer scenarios or repeats.")
        }
        if let timeout, !timeout.isFinite || !(1...14_400).contains(timeout) {
            throw MacIntentTestingError("The run timeout must be from 1 to 14,400 seconds.")
        }
        return (effective, timeout ?? Double(calculated))
    }

    /// Requests serial test execution, bounded allowances, and explicit local evidence paths.
    static func arguments(in directory: URL, result: URL, allowance: Int) -> [String] {
        ["test", "-project", directory.appendingPathComponent("SiriStudioRun.xcodeproj").path, "-scheme", "SiriStudioRun",
         "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
         "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", String(allowance),
         "-maximum-test-execution-time-allowance", String(allowance), "-derivedDataPath",
         directory.appendingPathComponent("DerivedData").path, "-resultBundlePath", result.path]
    }
}
