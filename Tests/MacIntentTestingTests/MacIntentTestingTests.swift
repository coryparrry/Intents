import Foundation
import Testing
@testable import MacIntentTesting

struct MacIntentTestingTests {
    private let url = URL(fileURLWithPath: "/Applications/Example.app")
    private func catalog(parameters: [MacIntentParameter] = [], output: String = "String") -> MacIntentCatalog {
        .init(bundleIdentifier: "dev.example.app", appURL: url,
              actions: [.init(id: "Echo", title: "Echo", parameters: parameters, outputType: output)])
    }
    private func source(_ catalog: MacIntentCatalog, inputs: String = "{}", expected: String? = nil) throws -> String {
        try MacIntentSource.tests(catalog: catalog, cases: [.init(actionIdentifier: "Echo", inputsJSON: inputs, expectedValueJSON: expected)])
    }

    @Test func parsesCompiledMetadataAndEnums() throws {
        let metadata = #"""
        {"version":1,"actions":{"Echo":{"identifier":"Echo","title":{"key":"Echo text"},"outputType":{"primitive":{"wrapper":{"typeIdentifier":7}}},"parameters":[
        {"name":"text","title":{"key":"Text"},"isOptional":false,"valueType":{"primitive":{"wrapper":{"typeIdentifier":0}}}},
        {"name":"choice","isOptional":false,"typeSpecificMetadata":["LNValueTypeSpecificMetadataKeyDefaultValue",{"string":{"wrapper":"first"}}],"valueType":{"linkEnumeration":{"wrapper":{"identifier":"Choice"}}}}
        ]}},"enums":[{"identifier":"Choice","cases":[{"identifier":"first"},{"identifier":"second"}]}]}
        """#
        let decoded = try MacIntentCatalog.decode(data: Data(metadata.utf8), bundleIdentifier: "dev.example", appURL: url)
        let action = try #require(decoded.actions.first)
        #expect(action.title == "Echo text")
        #expect(action.outputType == "Double")
        #expect(action.parameters[0].type == "String")
        #expect(action.parameters[0].required)
        #expect(!action.parameters[1].required)
        #expect(action.parameters[1].enumIdentifier == "Choice")
        #expect(action.parameters[1].enumCases == ["first", "second"])
    }

    @Test func rejectsInvalidMetadataSchemas() {
        for invalid in [#"{"version":2,"actions":{}}"#, #"{"version":true,"actions":{}}"#,
                        #"{"version":1,"actions":{}}"#, #"{"version":1,"actions":{"Echo":{"identifier":"Different","parameters":[]}}}"#] {
            #expect(throws: (any Error).self) {
                try MacIntentCatalog.decode(data: Data(invalid.utf8), bundleIdentifier: "dev.example", appURL: url)
            }
        }
    }

    @Test func rejectsNonMacApplicationBundles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try MacIntentCatalog.load(appURL: directory) }
    }

    @Test func inputsMustMatchDeclaredTypes() {
        let p = MacIntentParameter(id: "value", name: "Value", type: "Int", required: true)
        for invalid in ["{}", #"{"value":true}"#, #"{"value":"1"}"#, #"{"value":1.2}"#,
                        #"{"value":null}"#, #"{"value":9223372036854775808}"#,
                        #"{"value":1,"unknown":2}"#, "[]", "invalid"] {
            #expect(throws: (any Error).self) { try source(catalog(parameters: [p]), inputs: invalid) }
        }
    }

    @Test func scalarInputsAreGeneratedWithoutCoercion() throws {
        for (type, input, expression) in [("String", #""hello""#, #""hello""#), ("Bool", "true", "true"),
                                          ("Int", "42", "Int(42)"), ("Double", "1.5", "Double(1.5)")] {
            let p = MacIntentParameter(id: "value", name: "Value", type: type, required: true)
            let generated = try source(catalog(parameters: [p], output: type), inputs: "{\"value\":\(input)}", expected: input)
            #expect(generated.contains("intent[dynamicMember: \"value\"] = \(expression)"))
            #expect(generated.contains("let value: \(type) = try result.value"))
            #expect(generated.contains("XCTAssertEqual(value, \(expression))"))
        }
    }

    @Test func enumInputsUseDefinitionAndDeclaredCaseIdentifiers() throws {
        let p = MacIntentParameter(id: "choice", name: "Choice", type: "Enum", required: true,
                                   enumIdentifier: "Choice", enumCases: ["first"])
        let generated = try source(catalog(parameters: [p]), inputs: #"{"choice":"first"}"#)
        #expect(generated.contains(#"definitions.enums["Choice"].makeCase("first")"#))
        #expect(throws: (any Error).self) { try source(catalog(parameters: [p]), inputs: #"{"choice":"First"}"#) }
    }

    @Test func unsupportedValuesHaveExplicitDiagnostics() throws {
        let p = MacIntentParameter(id: "entity", name: "Entity", type: "unsupported", required: true)
        do {
            _ = try source(catalog(parameters: [p]), inputs: #"{"entity":"identifier"}"#)
            Issue.record("Expected unsupported input to fail")
        } catch {
            #expect(error.localizedDescription.contains("unsupported type"))
        }
        #expect(throws: (any Error).self) { try source(catalog(output: "unsupported"), expected: "{}") }
        let smoke = try source(catalog(output: "unsupported"))
        #expect(smoke.contains("_ = try await intent.run()"))
        #expect(!smoke.contains("XCTAssertEqual"))
    }

    @Test func sourceEscapesInjectionAndInterpolation() throws {
        let payload = "\"); fatalError(\"injected\"); // \\(danger)\n\u{0}\""
        let encoded = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
        let p = MacIntentParameter(id: "value", name: "Value", type: "String", required: true)
        let generated = try source(catalog(parameters: [p]), inputs: "{\"value\":\(encoded)}", expected: encoded)
        #expect(generated.contains(MacIntentSource.literal(payload)))
        #expect(!generated.contains("\n\0"))
        #expect(MacIntentSource.literal("\\(danger)") == "\"\\\\(danger)\"")
    }

    @Test func runnerCommandsAreMacOnlyAndUseSeparateArguments() throws {
        let args = MacIntentSource.xcodebuildArguments(project: url, result: url, derivedData: url)
        #expect(args.contains("platform=macOS"))
        #expect(args.contains("-parallel-testing-enabled"))
        #expect(!args.contains("-maximum-concurrent-test-macos-destinations"))
        #expect(!args.joined().contains("simulator"))
        let config = MacIntentRunConfiguration(developerDirectory: url, signingIdentity: "Signing \"Identity\"\nFAKE_SETTING: YES",
                                               teamIdentifier: "TEAM", outputDirectory: url)
        let project = try JSONSerialization.jsonObject(with: MacIntentSource.project(configuration: config, identifier: "unique")) as! [String: Any]
        let targets = project["targets"] as! [String: [String: Any]]
        #expect(targets.values.allSatisfy { $0["platform"] as? String == "macOS" })
        let base = (project["settings"] as! [String: Any])["base"] as! [String: Any]
        #expect(base["CODE_SIGN_IDENTITY"] as? String == config.signingIdentity)
        #expect(base["FAKE_SETTING"] == nil)
    }

    @Test func rejectsEmptyDuplicateAndUnknownCases() {
        let test = MacIntentTestCase(actionIdentifier: "Echo")
        #expect(throws: (any Error).self) { try MacIntentSource.tests(catalog: catalog(), cases: []) }
        #expect(throws: (any Error).self) { try MacIntentSource.tests(catalog: catalog(), cases: [test, test]) }
        #expect(throws: (any Error).self) {
            try MacIntentSource.tests(catalog: catalog(), cases: [.init(actionIdentifier: "Missing")])
        }
    }

    @MainActor @Test func signingTeamRequiresExactMetadataLine() {
        #expect(MacIntentRunner.signingTeam(in: "Executable=/App\nTeamIdentifier=TEAM123\n") == "TEAM123")
        #expect(MacIntentRunner.signingTeam(in: "OtherTeamIdentifier=TEAM123") == nil)
        #expect(MacIntentRunner.signingTeam(in: "TeamIdentifier=not set") == "not set")
    }

    @MainActor @Test func subprocessLaunchFailureAndTimeoutAreBounded() async throws {
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close(); try? FileManager.default.removeItem(at: logURL) }
        let runner = MacIntentRunner()
        do {
            _ = try await runner.execute(executable: URL(fileURLWithPath: "/missing-command"), arguments: [],
                                         directory: FileManager.default.temporaryDirectory,
                                         environment: ProcessInfo.processInfo.environment, log: log, timeout: 1)
            Issue.record("Missing command should fail")
        } catch { #expect(!error.localizedDescription.isEmpty) }
        do {
            _ = try await runner.execute(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                         directory: FileManager.default.temporaryDirectory,
                                         environment: ProcessInfo.processInfo.environment, log: log, timeout: 0.05)
            Issue.record("Sleeping command should time out")
        } catch { #expect(error.localizedDescription.contains("timeout")) }
    }

    @MainActor @Test func registrationPathIgnoresDirectoryURLTrailingSlash() {
        let file = URL(fileURLWithPath: "/Applications/Sample.app", isDirectory: false)
        let directory = URL(fileURLWithPath: "/Applications/Sample.app", isDirectory: true)
        #expect(MacIntentRunner.sameApplicationPath(file, directory))
        #expect(!MacIntentRunner.sameApplicationPath(file, URL(fileURLWithPath: "/Applications/Other.app")))
    }
    @Test func catalogIncludesDefinitionsHiddenFromSiriAndUnsupportedTypes() throws {
        let metadata = #"""
        {"version":1,"actions":{
          "Hidden":{"identifier":"Hidden","isDiscoverable":false,"title":{"key":"Hidden action"},"parameters":[
            {"name":"value","isOptional":false,"valueType":{"entity":{"wrapper":{"identifier":"ExampleEntity"}}}}
          ],"outputType":{"array":{"wrapper":{"memberValueType":{"primitive":{"wrapper":{"typeIdentifier":0}}}}}}},
          "Visible":{"identifier":"Visible","isDiscoverable":true,"parameters":[]}
        }}
        """#
        let decoded = try MacIntentCatalog.decode(data: Data(metadata.utf8), bundleIdentifier: "dev.example", appURL: url)
        #expect(decoded.actions.map(\.id) == ["Hidden", "Visible"])
        let hidden = try #require(decoded.actions.first { $0.id == "Hidden" })
        #expect(hidden.title == "Hidden action")
        #expect(hidden.parameters.first?.type == "unsupported")
        #expect(hidden.outputType == "unsupported")
    }

}
