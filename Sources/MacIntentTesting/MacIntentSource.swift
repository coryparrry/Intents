import Foundation
import CoreFoundation

/// Builds a small native UI-test bundle. User text is always a Swift string
/// literal or a validated numeric scalar, never executable source or YAML.
enum MacIntentSource {
    static func tests(catalog: MacIntentCatalog, cases: [MacIntentTestCase]) throws -> String {
        guard !cases.isEmpty, cases.count <= 100, Set(cases.map(\.id)).count == cases.count else {
            throw MacIntentTestingError("Supply 1–100 test cases with unique IDs.")
        }
        guard Set(catalog.actions.map(\.id)).count == catalog.actions.count else { throw MacIntentTestingError("Duplicate action identifiers in catalog.") }
        let methods = try cases.map { test in
            guard let action = catalog.actions.first(where: { $0.id == test.actionIdentifier }) else {
                throw MacIntentTestingError("Unknown action \(test.actionIdentifier). Reload the selected app.")
            }
            guard test.inputsJSON.utf8.count <= 64 * 1024,
                  let inputs = try parseJSON(test.inputsJSON) as? [String: Any] else {
                throw MacIntentTestingError("Inputs for \(action.title) must be a JSON object of parameter identifiers and values (up to 64 KB).")
            }
            let unknown = Set(inputs.keys).subtracting(action.parameters.map(\.id))
            guard unknown.isEmpty else { throw MacIntentTestingError("Unknown inputs for \(action.title): \(unknown.sorted().joined(separator: ", ")).") }
            var lines: [String] = []
            for p in action.parameters {
                guard let value = inputs[p.id] else {
                    if p.required { throw MacIntentTestingError("Missing required input \(p.id) for \(action.title).") }
                    continue
                }
                let expression: String
                if p.type == "Enum" {
                    guard let rawValue = value as? String, let enumID = p.enumIdentifier, p.enumCases.contains(rawValue) else {
                        throw MacIntentTestingError("Input \(p.id) must be an enum identifier from: \(p.enumCases.joined(separator: ", ")).")
                    }
                    expression = "definitions.enums[\(literal(enumID))].makeCase(\(literal(rawValue)))"
                } else {
                    expression = try scalar(value, type: p.type, context: "Input \(p.id)")
                }
                lines.append("        intent[dynamicMember: \(literal(p.id))] = \(expression)")
            }
            var assertion = "        _ = try await intent.run()"
            if let expectedJSON = test.expectedValueJSON {
                guard expectedJSON.utf8.count <= 64 * 1024 else { throw MacIntentTestingError("Expected value exceeds 64 KB.") }
                let expected = try scalar(parseJSON(expectedJSON), type: action.outputType, context: "Expected value for \(action.title)")
                assertion = """
                        let result = try await intent.run()
                        let value: \(action.outputType) = try result.value
                        XCTAssertEqual(value, \(expected))
                """
            }
            return """
                func test_\(test.id.uuidString.replacingOccurrences(of: "-", with: "_"))() async throws {
                    let definitions = IntentDefinitions(bundleIdentifier: \(literal(catalog.bundleIdentifier)))
                    var intent = definitions.intents[\(literal(action.id))].makeIntent()
            \(lines.joined(separator: "\n"))
            \(assertion)
                }
            """
        }
        return """
        import Foundation
        import XCTest
        import AppIntentsTesting

        @MainActor
        final class MacIntentTests: XCTestCase {
        \(methods.joined(separator: "\n\n"))
        }
        """
    }

    static func literal(_ value: String) -> String {
        // String(reflecting:) emits Swift's quoted/escaped representation,
        // including interpolation markers, backslashes, and control characters.
        String(reflecting: value)
    }

    private static func parseJSON(_ text: String) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) }
        catch { throw MacIntentTestingError("Invalid JSON: \(error.localizedDescription)") }
    }

    private static func scalar(_ value: Any, type: String, context: String) throws -> String {
        let number = value as? NSNumber
        let boolean = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch type {
        case "String":
            if let string = value as? String { return literal(string) }
        case "Bool":
            if boolean, let number { return number.boolValue ? "true" : "false" }
        case "Int":
            if let number, !boolean,
               // Parsing the printed integer also rejects overflow and fractional JSON.
               let int = Int(number.stringValue), NSNumber(value: int) == number { return "Int(\(int))" }
        case "Double":
            if let number, !boolean, number.doubleValue.isFinite { return "Double(\(number.doubleValue))" }
        default:
            throw MacIntentTestingError("\(context) uses unsupported type \(type). Supported values are String, Bool, Int, Double, and declared enum inputs.")
        }
        throw MacIntentTestingError("\(context) must be a JSON \(type) scalar; null, arrays, objects, and coercions are not supported.")
    }

    static func project(configuration: MacIntentRunConfiguration, identifier: String) throws -> Data {
        // XcodeGen accepts JSON as YAML; JSONEncoder prevents setting injection.
        let settings: [String: Any] = [
            "SWIFT_VERSION": "6.0", "MACOSX_DEPLOYMENT_TARGET": "27.0",
            "GENERATE_INFOPLIST_FILE": "YES", "CODE_SIGN_STYLE": "Manual",
            "CODE_SIGN_IDENTITY": configuration.signingIdentity,
            "DEVELOPMENT_TEAM": configuration.teamIdentifier,
            "ENABLE_APP_SANDBOX": "NO",
        ]
        let spec: [String: Any] = [
            "name": "MacIntentRun",
            "settings": ["base": settings],
            "targets": [
                "MacIntentHost": ["type": "application", "platform": "macOS", "sources": ["Host"],
                                  "settings": ["base": ["PRODUCT_BUNDLE_IDENTIFIER": "dev.intents.testing.host.\(identifier)"]]],
                "MacIntentTests": ["type": "bundle.ui-testing", "platform": "macOS", "sources": ["Tests"],
                                   "dependencies": [["target": "MacIntentHost"]],
                                   "settings": ["base": ["PRODUCT_BUNDLE_IDENTIFIER": "dev.intents.testing.tests.\(identifier)",
                                                         "TEST_TARGET_NAME": "MacIntentHost"]]],
            ],
            "schemes": ["MacIntentRun": ["build": ["targets": ["MacIntentHost": "all"]],
                                         "test": ["targets": ["MacIntentTests"]]]],
        ]
        return try JSONSerialization.data(withJSONObject: spec, options: [.prettyPrinted, .sortedKeys])
    }

    static func xcodebuildArguments(project: URL, result: URL, derivedData: URL) -> [String] {
        ["test", "-project", project.path, "-scheme", "MacIntentRun", "-destination", "platform=macOS",
         "-parallel-testing-enabled", "NO",
         "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "120",
         "-maximum-test-execution-time-allowance", "120",
         "-derivedDataPath", derivedData.path, "-resultBundlePath", result.path]
    }
}
