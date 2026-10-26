import Foundation
import MacIntentTesting

struct NativeTestsOptions {
    static let help = """
    intents-native-tests catalog --app PATH
    intents-native-tests run --app PATH --cases FILE --developer-dir PATH --team TEAM --identity ID --output PATH [--timeout SECONDS]

    Cases: a JSON array of {"actionIdentifier":"IntentID","inputs":{},"expectedValue":"expected"}.
    Omit expectedValue for an execution smoke test. null is unsupported.
    Requires macOS 27, Xcode 27, XcodeGen, and an installed Mac app signed by the selected team.
    Exit codes: 0 passed/catalog/help, 1 native test failed or cancelled, 2 invalid setup or arguments.
    """
    enum Command { case catalog, run, help }
    let command: Command
    let values: [String: String]

    /// Parses catalog/run options, rejecting unknown, duplicate, missing, or empty values and out-of-range timeouts.
    init(_ arguments: [String]) throws {
        if arguments == ["--help"] || arguments == ["help"] || arguments == ["catalog", "--help"] || arguments == ["run", "--help"] {
            command = .help; values = [:]; return
        }
        guard let first = arguments.first, first == "catalog" || first == "run" else {
            throw MacIntentTestingError("Choose catalog or run. Use --help for usage.")
        }
        command = first == "catalog" ? .catalog : .run
        let required: Set<String> = command == .catalog ? ["app"] : ["app", "cases", "developer-dir", "team", "identity", "output"]
        let allowed = required.union(command == .run ? ["timeout"] : [])
        var parsed: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--"), allowed.contains(String(argument.dropFirst(2))) else {
                throw MacIntentTestingError("Unknown argument: \(argument). Use --help for usage.")
            }
            let name = String(argument.dropFirst(2))
            guard parsed[name] == nil else { throw MacIntentTestingError("Duplicate argument: \(argument).") }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"),
                  !arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MacIntentTestingError("Missing value for \(argument).")
            }
            parsed[name] = arguments[index + 1]
            index += 2
        }
        let missing = required.subtracting(parsed.keys).sorted()
        guard missing.isEmpty else { throw MacIntentTestingError("Missing arguments: \(missing.map { "--" + $0 }.joined(separator: ", ")).") }
        if let timeout = parsed["timeout"] {
            guard let seconds = Double(timeout), seconds.isFinite, (1...3600).contains(seconds) else {
                throw MacIntentTestingError("--timeout must be a number from 1 to 3600 seconds.")
            }
        }
        values = parsed
    }

    /// Builds a file URL from an option already required by the selected command; callers must request a validated key.
    func url(_ name: String) -> URL { URL(fileURLWithPath: values[name]!) }
    var configuration: MacIntentRunConfiguration {
        .init(developerDirectory: url("developer-dir"), signingIdentity: values["identity"]!,
              teamIdentifier: values["team"]!, outputDirectory: url("output"),
              timeoutSeconds: values["timeout"].flatMap(Double.init) ?? 600)
    }
}

enum NativeTestsManifest {
    /// Loads a case manifest of at most 16 MiB and decodes its authored cases.
    static func load(_ url: URL) throws -> [MacIntentTestCase] {
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1024 * 1024 else { throw MacIntentTestingError("Cases manifest exceeds 16 MB.") }
        return try decode(data)
    }

    /// Parses 1–100 strict case objects, preserving JSON inputs and optional scalar expected values while rejecting unknown fields.
    static func decode(_ data: Data) throws -> [MacIntentTestCase] {
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) }
        catch { throw MacIntentTestingError("Cases manifest is not valid JSON: \(error.localizedDescription)") }
        guard let entries = raw as? [[String: Any]], (1...100).contains(entries.count) else {
            throw MacIntentTestingError("Cases manifest must be a JSON array of 1–100 case objects.")
        }
        return try entries.enumerated().map { index, entry in
            let label = "Case \(index + 1)"
            let unknown = Set(entry.keys).subtracting(["actionIdentifier", "inputs", "expectedValue"])
            guard unknown.isEmpty else { throw MacIntentTestingError("\(label) has unknown fields: \(unknown.sorted().joined(separator: ", ")).") }
            guard let action = entry["actionIdentifier"] as? String,
                  !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MacIntentTestingError("\(label) needs a nonempty actionIdentifier.")
            }
            let inputs: [String: Any]
            if let supplied = entry["inputs"] {
                guard let object = supplied as? [String: Any] else { throw MacIntentTestingError("\(label) inputs must be a JSON object.") }
                inputs = object
            } else { inputs = [:] }
            var expected: String?
            if let supplied = entry["expectedValue"] {
                guard !(supplied is NSNull), supplied is String || supplied is NSNumber else {
                    throw MacIntentTestingError("\(label) expectedValue must be a JSON String, Bool, Int, or Double scalar; omit it for a smoke test.")
                }
                expected = try json(supplied)
            }
            return .init(actionIdentifier: action, inputsJSON: try json(inputs), expectedValueJSON: expected)
        }
    }

    /// Encodes a JSON object or scalar fragment with sorted keys for stable authored case text.
    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
}

struct NativeTestsIssuedCase: Encodable {
    let id: UUID
    let actionIdentifier: String
    let testMethod: String
    /// Maps an authored case UUID to the generated XCTest method identifier retained in CLI evidence.
    init(_ test: MacIntentTestCase) {
        id = test.id; actionIdentifier = test.actionIdentifier
        testMethod = "MacIntentTests/test_" + test.id.uuidString.replacingOccurrences(of: "-", with: "_")
    }
}

struct NativeTestsRunOutput: Encodable {
    let succeeded: Bool
    let resultBundleURL: URL?
    let logURL: URL
    let summary: String
    let productIdentity: MacIntentProductIdentity?
    let caseManifestURL: URL
    let cases: [NativeTestsIssuedCase]
    /// Frozen authored inputs and expectations from the completed run.
    let authoredCases: [MacIntentTestCase]
    /// Copies run evidence and frozen authored cases into the CLI response alongside the issued-case manifest location.
    init(result: MacIntentRunResult, caseManifestURL: URL, cases: [NativeTestsIssuedCase]) {
        succeeded = result.succeeded; resultBundleURL = result.resultBundleURL
        logURL = result.logURL; summary = result.summary
        productIdentity = result.productIdentity
        self.caseManifestURL = caseManifestURL; self.cases = cases
        authoredCases = result.cases
    }
}
