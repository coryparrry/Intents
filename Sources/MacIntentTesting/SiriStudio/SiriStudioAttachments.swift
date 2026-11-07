import Foundation
import CoreFoundation

/// Loads only Studio's own JSON attachments, never Apple's opaque evaluation result.
struct SiriStudioAttachments {
    private struct Test: Decodable {
        let testIdentifier: String
        let attachments: [Attachment]
    }

    private struct Attachment: Decodable {
        let exportedFileName: String
        let suggestedHumanReadableName: String
    }

    private struct Header: Decodable { let schema: String; let version: Int }

    private struct TestTree: Decodable {
        let testNodes: [Node]

        struct Node: Decodable {
            let nodeIdentifier: String?
            let nodeType: String
            let result: String?
            let children: [Node]?
        }
    }

    var reports: [SiriStudioReport] = []
    var summaries: [SiriStudioSummary] = []

    /// Reads attachments listed by xcresulttool and rejects foreign paths, unsupported schemas, and mismatched tests.
    static func load(from directory: URL) throws -> Self {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode([Test].self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        var evidence = Self()
        for test in manifest {
            for attachment in test.attachments where attachment.suggestedHumanReadableName.hasPrefix("siri-studio-") {
                let name = attachment.exportedFileName
                let file = directory.appendingPathComponent(name)
                let resolved = file.resolvingSymlinksInPath()
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                      resolved.deletingLastPathComponent().standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
                      try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw MacIntentTestingError("The result manifest contains an invalid attachment path.")
                }
                let bytes = try read(resolved)
                let header = try decoder.decode(Header.self, from: bytes)
                guard header.version == 1 else { throw MacIntentTestingError("Unsupported Siri Studio attachment version.") }
                switch header.schema {
                case SiriStudioReport.schemaID:
                    let report = try decoder.decode(SiriStudioReport.self, from: bytes)
                    try requireTest(test.testIdentifier, id: report.scenarioID)
                    guard report.consistent else { throw MacIntentTestingError("An imported transcript has inconsistent turn counts.") }
                    evidence.reports.append(report)
                case SiriStudioSummary.schemaID:
                    let summary = try decoder.decode(SiriStudioSummary.self, from: bytes)
                    try requireTest(test.testIdentifier, id: summary.scenarioID)
                    evidence.summaries.append(summary)
                default: throw MacIntentTestingError("Unknown Siri Studio attachment schema.")
                }
            }
        }
        return evidence
    }

    /// Reads at most 16 MB per attachment before decoding it.
    private static func read(_ file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let limit = 16 * 1024 * 1024
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw MacIntentTestingError("A Siri Studio attachment exceeds 16 MB.") }
        return bytes
    }

    /// Finds generated test executions without counting unrelated tests in a developer's scheme.
    static func studioTests(_ data: Data) throws -> [UUID: Bool] {
        let tree = try JSONDecoder().decode(TestTree.self, from: data)
        var stack = tree.testNodes
        var results: [UUID: Bool] = [:]
        while let node = stack.popLast() {
            stack.append(contentsOf: node.children ?? [])
            guard node.nodeType == "Test Case", let name = node.nodeIdentifier else { continue }
            let parts = name.split(separator: "/")
            guard parts.count >= 2, parts[parts.count - 2] == "SiriStudioScenarios",
                  let method = parts.last, method.hasPrefix("scenario_") else { continue }
            let token = method.hasSuffix("()") ? method.dropLast(2) : method[...]
            guard let id = UUID(uuidString: token.dropFirst("scenario_".count).replacingOccurrences(of: "_", with: "-")) else { continue }
            let completed = node.result == "Passed" || node.result == "Failed"
            let repetitions = node.children?.filter { ["Repetition", "Test Case Run"].contains($0.nodeType) }.count ?? 0
            results[id] = results[id] == nil && completed && repetitions <= 1
        }
        return results
    }

    /// Reads the original run timestamps and a single known OS build from Xcode's summary.
    static func runFacts(_ data: Data) throws -> (started: Date, ended: Date, osBuild: String) {
        struct Facts: Decodable {
            let startTime: Double
            let finishTime: Double
            let devicesAndConfigurations: [Configuration]?

            struct Configuration: Decodable {
                let device: Device

                struct Device: Decodable {
                    let osVersion: String
                    let osBuildNumber: String?
                }
            }
        }
        let facts = try JSONDecoder().decode(Facts.self, from: data)
        guard facts.startTime >= 0, facts.finishTime >= facts.startTime else {
            throw MacIntentTestingError("The result bundle has invalid run timestamps.")
        }
        let builds = Set((facts.devicesAndConfigurations ?? []).map { configuration in
            let device = configuration.device
            return device.osBuildNumber.map { "macOS \(device.osVersion) (\($0))" } ?? "macOS \(device.osVersion)"
        })
        return (Date(timeIntervalSince1970: facts.startTime), Date(timeIntervalSince1970: facts.finishTime),
                builds.count == 1 ? builds.first ?? "External run" : "External run")
    }

    /// Associates attachment content with the generated Swift Testing function in the result manifest.
    private static func requireTest(_ identifier: String, id: UUID) throws {
        let token = "scenario_" + id.uuidString.replacingOccurrences(of: "-", with: "_")
        guard identifier.split(separator: "/").last.map(String.init).map({ $0 == token || $0 == token + "()" }) == true else {
            throw MacIntentTestingError("A Siri Studio attachment belongs to a different test.")
        }
    }

    /// Requires all selected tests to execute, allowing assertion failures for Apple's verdict.
    static func verifyTests(_ bytes: Data, expectedCount: Int) throws {
        let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        /// Reads an exact count, excluding JSON booleans.
        func count(_ key: String) -> Int? {
            guard let number = json?[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = Int(number.stringValue), (0...expectedCount).contains(value) else { return nil }
            return value
        }
        guard expectedCount > 0, count("totalTestCount") == expectedCount, count("skippedTests") == 0,
              count("expectedFailures") == 0, let passed = count("passedTests"), let failed = count("failedTests"),
              passed + failed == expectedCount else {
            throw MacIntentTestingError("The result bundle did not confirm all \(expectedCount) selected Siri tests executed.")
        }
    }

    /// Finds unambiguous evidence for this scenario and optionally preserves historical transcripts.
    func result(for scenario: SiriStudioScenario, bundleIdentifier: String, blocked: String? = nil, cancelled: String? = nil,
                allowStale: Bool = false) -> SiriStudioScenarioResult {
        let summaries = summaries.filter { $0.scenarioID == scenario.id }
        let summary = summaries.count == 1 ? summaries.first : nil
        let reports = reports.filter { $0.scenarioID == scenario.id }
        if allowStale, let summary, summary.revision != scenario.revision {
            let historical = reports.filter { $0.revision == summary.revision && $0.contentDigest == summary.contentDigest }
            return .stale(scenario, reports: historical, summary: summary, blocked: blocked)
        }
        return .assess(scenario, bundleIdentifier: bundleIdentifier, reports: reports, summary: summary,
                       blocked: blocked, cancelled: cancelled)
    }
}
