import Foundation
import MacIntentTesting
import Testing
@testable import MacIntentTestingCLI

struct NativeTestsCLITests {
    @Test func runOutputPreservesTheFrozenTestedProductIdentity() throws {
        let identity = try JSONDecoder().decode(MacIntentProductIdentity.self,
            from: Data(#"{"bundlePath":"/Applications/Sample.app","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8))
        let result = MacIntentRunResult(succeeded: true, resultBundleURL: nil,
            logURL: URL(fileURLWithPath: "/tmp/run.log"), summary: "Passed", productIdentity: identity)
        let output = NativeTestsRunOutput(result: result, caseManifestURL: URL(fileURLWithPath: "/tmp/cases.json"), cases: [])
        let data = try JSONEncoder().encode(output)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try #require(json["productIdentity"] as? [String: String])
        #expect(encoded["sha256"] == identity.sha256)
        #expect(encoded["bundlePath"] == identity.bundlePath)
    }

    @Test func runOutputRetainsAuthoredInputsAndExpectationsAfterManifestReplacementAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("cases.json")
        let outputURL = directory.appendingPathComponent("run.json")
        let originalManifest = #"""
        [
          {"actionIdentifier":"Echo","inputs":{"text":"original \"quoted\" text","flag":true,"count":42,"number":1.5},"expectedValue":"original result"},
          {"actionIdentifier":"CheckFlag","inputs":{"enabled":false},"expectedValue":false},
          {"actionIdentifier":"Smoke","inputs":{"name":"unchanged"}}
        ]
        """#
        try Data(originalManifest.utf8).write(to: manifestURL)
        let authored = try NativeTestsManifest.decode(Data(contentsOf: manifestURL))
        let issued = authored.map(NativeTestsIssuedCase.init)
        let result = MacIntentRunResult(succeeded: true, resultBundleURL: nil,
            logURL: directory.appendingPathComponent("run.log"), summary: "Passed", cases: authored)
        let output = NativeTestsRunOutput(result: result, caseManifestURL: manifestURL, cases: issued)
        try JSONEncoder().encode(output).write(to: outputURL)

        try Data(#"[{"actionIdentifier":"Replacement","inputs":{"text":"changed"},"expectedValue":99}]"#.utf8)
            .write(to: manifestURL, options: .atomic)
        #expect(try NativeTestsManifest.decode(Data(contentsOf: manifestURL))[0].actionIdentifier == "Replacement")
        try FileManager.default.removeItem(at: manifestURL)
        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))

        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: outputURL)) as? [String: Any])
        let retained = try JSONDecoder().decode([MacIntentTestCase].self,
            from: JSONSerialization.data(withJSONObject: try #require(json["authoredCases"])))
        #expect(retained == authored)
        #expect(retained.map(\.actionIdentifier) == ["Echo", "CheckFlag", "Smoke"])
        let inputs = try #require(JSONSerialization.jsonObject(with: Data(retained[0].inputsJSON.utf8)) as? [String: Any])
        #expect(inputs["text"] as? String == #"original "quoted" text"#)
        #expect(inputs["flag"] as? Bool == true)
        #expect(inputs["count"] as? Int == 42)
        #expect(inputs["number"] as? Double == 1.5)
        #expect(retained[0].expectedValueJSON == #""original result""#)
        #expect(retained[1].expectedValueJSON == "false")
        #expect(retained[2].expectedValueJSON == nil)
        #expect(json["caseManifestURL"] as? String == manifestURL.absoluteString)
        let labels = try #require(json["cases"] as? [[String: Any]])
        #expect(labels.count == issued.count)
        for (label, issuedCase) in zip(labels, issued) {
            #expect(label["id"] as? String == issuedCase.id.uuidString)
            #expect(label["actionIdentifier"] as? String == issuedCase.actionIdentifier)
            #expect(label["testMethod"] as? String == issuedCase.testMethod)
        }
    }

    @Test func catalogRequiresOnlyAppAndSupportsSpacesInPaths() throws {
        let options = try NativeTestsOptions(["catalog", "--app", "/Applications/My App.app"])
        #expect(options.command == .catalog)
        #expect(options.url("app").path == "/Applications/My App.app")
        #expect(try NativeTestsOptions(["--help"]).command == .help)
        #expect(try NativeTestsOptions(["run", "--help"]).command == .help)
    }

    @Test func runParsesCompleteConfigurationAndDefaultsTimeout() throws {
        let arguments = ["run", "--app", "/App.app", "--cases", "/cases.json", "--developer-dir", "/Xcode/Contents/Developer",
                         "--team", "TEAM", "--identity", "Apple Development: User", "--output", "/tmp/results"]
        let options = try NativeTestsOptions(arguments)
        #expect(options.command == .run)
        #expect(options.configuration.teamIdentifier == "TEAM")
        #expect(options.configuration.timeoutSeconds == 600)
        #expect(try NativeTestsOptions(arguments + ["--timeout", "120.5"]).configuration.timeoutSeconds == 120.5)
        for invalid in ["0", "3601", "NaN", "Infinity", "invalid"] {
            #expect(throws: (any Error).self) { try NativeTestsOptions(arguments + ["--timeout", invalid]) }
        }
    }

    @Test func invalidAndMissingArgumentsReportActionableErrors() {
        for arguments in [[], ["unknown"], ["catalog"], ["catalog", "--app"], ["catalog", "--app", ""],
                          ["catalog", "--app", "--other"], ["catalog", "--app", "/A", "--app", "/B"],
                          ["catalog", "--device", "phone"], ["run", "--app", "/A"]] {
            do {
                _ = try NativeTestsOptions(arguments)
                Issue.record("Expected invalid arguments to fail: \(arguments)")
            } catch { #expect(!error.localizedDescription.isEmpty) }
        }
    }

    @Test func naturalManifestAssignsUniqueIDsAndPreservesJSONTypes() throws {
        let text = #"""
        [
          {"actionIdentifier":"Smoke"},
          {"actionIdentifier":"Echo","inputs":{"text":"quoted \"text\" \\(notCode)","flag":true,"count":42,"number":1.5},"expectedValue":"quoted \"text\" \\(notCode)"},
          {"actionIdentifier":"Bool","expectedValue":false},
          {"actionIdentifier":"Int","expectedValue":42},
          {"actionIdentifier":"Double","expectedValue":1.5}
        ]
        """#
        let cases = try NativeTestsManifest.decode(Data(text.utf8))
        #expect(cases.count == 5)
        #expect(Set(cases.map(\.id)).count == 5)
        #expect(cases[0].inputsJSON == "{}")
        #expect(cases[0].expectedValueJSON == nil)
        let inputs = try JSONSerialization.jsonObject(with: Data(cases[1].inputsJSON.utf8)) as! [String: Any]
        #expect(inputs["text"] as? String == #"quoted "text" \(notCode)"#)
        #expect(inputs["flag"] as? Bool == true)
        #expect(cases[2].expectedValueJSON == "false")
        #expect(cases[3].expectedValueJSON == "42")
        #expect(cases[4].expectedValueJSON == "1.5")
        let issued = NativeTestsIssuedCase(cases[1])
        #expect(issued.actionIdentifier == "Echo")
        #expect(issued.testMethod == "MacIntentTests/test_" + cases[1].id.uuidString.replacingOccurrences(of: "-", with: "_"))
    }

    @Test func malformedManifestsAndExplicitNullRejectClearly() {
        for text in ["invalid", "{}", "[]", "[1]", "[{}]", #"[{"actionIdentifier":" "}]"#,
                     #"[{"actionIdentifier":"Echo","inputs":null}]"#,
                     #"[{"actionIdentifier":"Echo","inputs":[]}]"#,
                     #"[{"actionIdentifier":"Echo","expectedValue":null}]"#,
                     #"[{"actionIdentifier":"Echo","expectedValue":[]}]"#,
                     #"[{"actionIdentifier":"Echo","expectedValue":{}}]"#,
                     #"[{"actionIdentifier":"Echo","expectdValue":"typo"}]"#] {
            do {
                _ = try NativeTestsManifest.decode(Data(text.utf8))
                Issue.record("Expected invalid manifest to fail: \(text)")
            } catch { #expect(!error.localizedDescription.isEmpty) }
        }
        let tooMany = "[" + Array(repeating: #"{"actionIdentifier":"Smoke"}"#, count: 101).joined(separator: ",") + "]"
        #expect(throws: (any Error).self) { try NativeTestsManifest.decode(Data(tooMany.utf8)) }
    }
}
