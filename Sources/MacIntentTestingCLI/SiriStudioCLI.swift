import Foundation
import MacIntentTesting

/// Parses the Siri Studio commands independently of the existing Direct Action flags.
struct SiriStudioOptions {
    static let help = """
    intents-native-tests siri validate --app PATH --scenarios FILE
    intents-native-tests siri export --app PATH --scenarios FILE --output FILE [--scenario UUID …]
    intents-native-tests siri run --app PATH --scenarios FILE --developer-dir PATH --team TEAM --identity ID --output DIRECTORY
        [--scenario UUID …] [--timeout SECONDS] [--allowance SECONDS]
    intents-native-tests siri show --run DIRECTORY

    Live runs require macOS 27.3, Siri AI, Xcode 27.3, XcodeGen, and matching development signing.
    Exit codes: 0 passed/validate/export/help, 1 run did not pass, 2 invalid arguments or unreadable files.
    """

    /// The four Studio actions exposed through the native test CLI.
    enum Command: String { case validate, export, run, show }
    let command: Command
    let values: [String: String]
    let scenarioIDs: Set<UUID>
    let timeout: Double?
    let allowance: Int?

    /// Rejects unknown or duplicate flags, invalid UUID selections and invalid time limits.
    init(_ arguments: [String]) throws {
        guard let first = arguments.first, let command = Command(rawValue: first) else {
            throw MacIntentTestingError("Choose siri validate, export, run, or show. Use siri --help for usage.")
        }
        self.command = command
        let required: Set<String> = switch command {
        case .validate: ["app", "scenarios"]
        case .export: ["app", "scenarios", "output"]
        case .run: ["app", "scenarios", "developer-dir", "team", "identity", "output"]
        case .show: ["run"]
        }
        let allowed = required.union(command == .run ? ["scenario", "timeout", "allowance"] : (command == .export ? ["scenario"] : []))
        var values: [String: String] = [:]
        var selected = Set<UUID>()
        var iterator = arguments.dropFirst().makeIterator()
        while let flag = iterator.next() {
            let key = String(flag.dropFirst(2))
            guard flag.hasPrefix("--"), allowed.contains(key) else {
                throw MacIntentTestingError("Unknown Siri Studio option: \(flag).")
            }
            guard let value = iterator.next(), !value.hasPrefix("--"),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MacIntentTestingError("Provide a value for \(flag).")
            }
            if key == "scenario" {
                guard let id = UUID(uuidString: value), selected.insert(id).inserted else {
                    throw MacIntentTestingError("Each --scenario must be a unique UUID.")
                }
            } else {
                guard values.updateValue(value, forKey: key) == nil else {
                    throw MacIntentTestingError("Duplicate option \(flag).")
                }
            }
        }
        let missing = required.subtracting(values.keys).sorted()
        guard missing.isEmpty else { throw MacIntentTestingError("Missing options: \(missing.map { "--" + $0 }.joined(separator: ", ")).") }
        if let value = values["timeout"] {
            guard let seconds = Double(value), (1...14_400).contains(seconds) else {
                throw MacIntentTestingError("--timeout must be from 1 to 14,400 seconds.")
            }
            timeout = seconds
        } else { timeout = nil }
        if let value = values["allowance"] {
            guard let seconds = Int(value), (1...1800).contains(seconds) else {
                throw MacIntentTestingError("--allowance must be from 1 to 1,800 seconds.")
            }
            allowance = seconds
        } else { allowance = nil }
        scenarioIDs = selected
        self.values = values
    }

    /// Resolves a path from the current working directory.
    func url(_ key: String) -> URL { URL(filePath: values[key] ?? "").standardizedFileURL }

    /// Creates the signed runner configuration for an already validated run command.
    var configuration: MacIntentRunConfiguration {
        .init(developerDirectory: url("developer-dir"), signingIdentity: values["identity"] ?? "",
              teamIdentifier: values["team"] ?? "", outputDirectory: url("output"))
    }
}

/// Keeps the terminal output compact; transcripts stay in the local run directory.
struct SiriStudioCLIOutput: Encodable {
    /// The verdict and pass count for one scenario, without transcript content.
    struct Scenario: Encodable {
        let id: UUID
        let name: String
        let state: SiriStudioState
        let passed: Int?
        let attempted: Int
        let passRate: Double?
        let reason: String?
    }
    let state: SiriStudioState
    let scenarios: [Scenario]
    let log: String
    let resultBundle: String?
    let source: String?

    /// Maps a persisted run to its terminal summary and evidence paths.
    init(_ run: SiriStudioRunRecord) {
        state = run.state
        scenarios = run.scenarios.map { scenario in
            .init(id: scenario.id, name: scenario.name, state: scenario.state, passed: scenario.passed, attempted: scenario.attempted,
                  passRate: scenario.attempted > 0 ? scenario.passed.map { Double($0) / Double(scenario.attempted) } : nil,
                  reason: scenario.reason)
        }
        log = run.logURL.path; resultBundle = run.resultBundleURL?.path; source = run.sourceURL?.path
    }
}
