import Foundation
import FoundationEvals

@main
enum IntentsEvidenceCommand {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first, command == "check" || command == "compare" else {
                throw CommandError.usage
            }
            let flags = try parseFlags(Array(arguments.dropFirst()))
            guard flags["format"] == "json" else { throw CommandError.invalid("--format json is required") }
            let referenceTime: Date
            if let raw = flags["reference-time"] {
                guard let parsed = ISO8601DateFormatter().date(from: raw) else {
                    throw CommandError.invalid("--reference-time must be ISO 8601 UTC")
                }
                referenceTime = parsed
            } else {
                referenceTime = Date()
            }
            let result: IntentEvidenceCheckResult
            if command == "check" {
                let bundle = try required("bundle", in: flags)
                let requirements = try required("requirements", in: flags)
                let source = try required("expected-source", in: flags)
                let appDigest = try required("expected-app-digest", in: flags)
                let policy = try required("policy", in: flags)
                try allowOnly(flags, ["bundle", "requirements", "expected-source", "expected-app-digest", "policy", "format", "reference-time"])
                result = try IntentEvidenceChecker.check(
                    bundle: URL(fileURLWithPath: bundle), requirements: URL(fileURLWithPath: requirements),
                    expectedSource: source, expectedAppDigest: appDigest,
                    policy: policy, referenceTime: referenceTime
                )
            } else {
                let baseline = try required("baseline", in: flags)
                let candidate = try required("candidate", in: flags)
                let requirements = try required("requirements", in: flags)
                let baselineSource = try required("baseline-source", in: flags)
                let candidateSource = try required("candidate-source", in: flags)
                let baselineAppDigest = try required("baseline-app-digest", in: flags)
                let candidateAppDigest = try required("candidate-app-digest", in: flags)
                let policy = try required("policy", in: flags)
                let mode = try required("mode", in: flags)
                try allowOnly(flags, ["baseline", "candidate", "requirements",
                                      "baseline-source", "candidate-source",
                                      "baseline-app-digest", "candidate-app-digest", "policy",
                                      "mode", "format", "reference-time"])
                result = try IntentEvidenceChecker.compare(
                    baseline: URL(fileURLWithPath: baseline), candidate: URL(fileURLWithPath: candidate),
                    requirements: URL(fileURLWithPath: requirements),
                    baselineSource: baselineSource, candidateSource: candidateSource,
                    baselineAppDigest: baselineAppDigest, candidateAppDigest: candidateAppDigest,
                    policy: policy, mode: mode, referenceTime: referenceTime
                )
            }
            FileHandle.standardOutput.write(result.json)
            FileHandle.standardOutput.write(Data([0x0a]))
            exit(result.exitCode)
        } catch {
            let payload = ErrorPayload(schemaVersion: 1, validationErrors: [error.localizedDescription])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(payload) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0a]))
            }
            exit(30)
        }
    }

    private static func parseFlags(_ arguments: [String]) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else { throw CommandError.usage }
        var flags: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), flag.count > 2, !arguments[index + 1].isEmpty else {
                throw CommandError.usage
            }
            let key = String(flag.dropFirst(2))
            guard flags[key] == nil else { throw CommandError.invalid("Duplicate --\(key)") }
            flags[key] = arguments[index + 1]
        }
        return flags
    }

    private static func required(_ key: String, in flags: [String: String]) throws -> String {
        guard let value = flags[key], !value.isEmpty else {
            throw CommandError.invalid("Missing --\(key)")
        }
        return value
    }

    private static func allowOnly(_ flags: [String: String], _ supported: Set<String>) throws {
        guard let unsupported = flags.keys.first(where: { !supported.contains($0) }) else { return }
        throw CommandError.invalid("Unknown --\(unsupported)")
    }

    private struct ErrorPayload: Encodable {
        var schemaVersion: Int
        var validationErrors: [String]
    }

    private enum CommandError: LocalizedError {
        case usage
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .usage:
                "Usage: intents-evidence check --bundle PATH --requirements PATH --expected-source REV --expected-app-digest SHA256 --policy intent-lab-report-v3 --format json [--reference-time ISO8601], or intents-evidence compare --baseline PATH --candidate PATH --requirements PATH --baseline-source REV --candidate-source REV --baseline-app-digest SHA256 --candidate-app-digest SHA256 --policy intent-lab-report-v3 --mode app-change --format json [--reference-time ISO8601]"
            case .invalid(let message): message
            }
        }
    }
}
