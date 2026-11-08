import Foundation
import Testing
@testable import MacIntentTesting

/// Covers document compatibility, input safety, and generation from actual fixture metadata.
struct SiriStudioTests {
    private static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let fixture = root.appending(path: "Tests/Fixtures/SiriStudio")

    /// Confirms all four checked-in scenarios generate the known stand-alone Swift file.
    @Test func fixtureGeneratesGoldenSwiftFromCompiledCatalog() throws {
        let document = try SiriStudioDocument.read(from: Self.root.appending(path: "examples/SiriStudioSample/scenarios.json"))
        let catalog = try fixtureCatalog()
        #expect(catalog.actions.first { $0.id == "AddPlayerIntent" }?.parameters.first { $0.id == "team" }?.entityIdentifier == "TeamEntity")
        let generated = try SiriStudioSource.tests(document: document, catalog: catalog)
        #expect(Data(generated.utf8) == (try Data(contentsOf: Self.fixture.appending(path: "Scenarios.swift.golden"))))
        let configuration = MacIntentRunConfiguration(developerDirectory: URL(filePath: "/Xcode"),
            signingIdentity: "Apple Development", teamIdentifier: "EXAMPLE", outputDirectory: URL(filePath: "/tmp"))
        let directory = FileManager.default.temporaryDirectory.appending(path: "siri-source-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let generatedURL = try SiriStudioSource.prepareProject(in: directory, source: generated,
                                                              configuration: configuration, identifier: UUID())
        #expect(try Data(contentsOf: generatedURL) == Data(generated.utf8))
        let project = try String(contentsOf: directory.appending(path: "project.json"), encoding: .utf8)
        #expect(project.contains("bundle.ui-testing") && project.contains("27.3") && project.contains("EXAMPLE"))
    }

    /// Rejects the specified invalid authoring cases before Swift generation.
    @Test func rejectsUnknownIDsInvalidMatchersRegexAndContradictions() throws {
        let catalog = try fixtureCatalog()
        let original = try SiriStudioDocument.read(from: Self.root.appending(path: "examples/SiriStudioSample/scenarios.json"))
        /// Mutates an isolated copy and checks the reason shared by the editor and export.
        func reject(_ expected: String, _ change: (inout SiriStudioDocument) -> Void) {
            var edited = original
            change(&edited)
            do {
                _ = try SiriStudioSource.tests(document: edited, catalog: catalog)
                Issue.record("Expected a validation error containing \(expected).")
            } catch { #expect(error.localizedDescription.contains(expected)) }
        }
        reject("Unknown action") { $0.scenarios[0].turns[0].expectations.calls[0].actionIdentifier = "Unknown" }
        reject("Unknown parameter") { $0.scenarios[0].turns[0].expectations.calls[0].arguments[0].parameterIdentifier = "Unknown" }
        reject("not allowed") { $0.scenarios[0].turns[0].expectations.calls[0].arguments[0].matcher = .boolEquals(true) }
        reject("Invalid regular expression") { $0.scenarios[0].turns[0].expectations.calls[0].arguments[0].matcher = .containsRegex("[") }
        reject("both required and forbidden") {
            $0.scenarios[0].scenarioExpectations.forbidden.append(.init(actionIdentifier: "AddPlayerIntent"))
        }
        reject("at least one expectation") { $0.scenarios[0].turns[0].expectations = .init() }
        reject("Duplicate authored ID") { $0.scenarios[0].turns[0].id = $0.scenarios[0].id }
        reject("Setup: Unknown action") { $0.scenarios[0].setup?.actionIdentifier = "Unknown" }
    }

    /// Keeps source-like text inside literals, and emits only the requested scenario and active metrics.
    @Test func selectedExportEscapesUntrustedTextAndParameterIdentifiers() throws {
        let payload = #"quoted "line" \(fatalError())"#
        let argument = "x\n) { injected() }"
        let catalog = MacIntentCatalog(bundleIdentifier: "dev.intents.test", appURL: URL(filePath: "/tmp/Test.app"),
            actions: [.init(id: "Act", title: "Act", parameters: [.init(id: argument, name: "Text", type: "String", required: false)])])
        let turn = SiriStudioTurn(utterance: payload,
            expectations: .init(calls: [.init(actionIdentifier: "Act", arguments: [
                .init(parameterIdentifier: argument, matcher: .equals(payload))
            ])]))
        let selected = SiriStudioScenario(name: payload, repeatCount: 2, turns: [turn])
        let other = SiriStudioScenario(name: "Other Scenario", turns: [.init(utterance: "Other",
            expectations: .init(replyContains: [.init(text: "OK")]))])
        let document = SiriStudioDocument(bundleIdentifier: catalog.bundleIdentifier, scenarios: [selected, other])
        let swift = try SiriStudioSource.tests(document: document, catalog: catalog, scenarioIDs: [selected.id])
        #expect(swift.contains(String(reflecting: payload)))
        #expect(swift.contains(String(reflecting: argument)))
        #expect(!swift.contains(argument))
        #expect(swift.contains("0..<2"))
        #expect(swift.contains("Metric.intentsAllPass"))
        #expect(!swift.contains("Metric.siriResponseAllPass"))
        #expect(!swift.contains(other.id.uuidString))
        let digest = try selected.contentDigest(bundleIdentifier: catalog.bundleIdentifier)
        #expect(swift.contains("authoredDigest: \(String(reflecting: digest))"))
        #expect(swift.contains("object[\"authoredDigest\"] = authoredDigest"))
    }

    /// Reopens a two-turn document and verifies revisions track saved content rather than repeated writes.
    @Test func savedDocumentIsStableAndRevisionAdvancesOnce() throws {
        let original = try SiriStudioDocument.read(from: Self.root.appending(path: "examples/SiriStudioSample/scenarios.json"))
        let target = FileManager.default.temporaryDirectory.appending(path: "siri-document-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: target) }
        try original.write(to: target)
        let bytes = try Data(contentsOf: target)
        var reopened = try SiriStudioDocument.read(from: target)
        #expect(reopened == original && reopened.scenarios[1].turns.count == 2)
        try reopened.write(to: target)
        #expect(try Data(contentsOf: target) == bytes)
        reopened.scenarios[1].turns[1].utterance = "The jersey number is 12."
        reopened.updateRevisions(from: original)
        #expect(reopened.scenarios[1].revision == original.scenarios[1].revision + 1)
        #expect(reopened.scenarios[0].revision == original.scenarios[0].revision)
        let saved = reopened
        reopened.updateRevisions(from: saved)
        #expect(reopened == saved)
    }

    /// Rejects old platform versions and oversized scenario selections before build.
    @Test func preflightVersionAndTimeBudgets() throws {
        #expect(!SiriStudioRunner.supportedXcode("Xcode 27.2\nBuild version beta"))
        #expect(SiriStudioRunner.supportedXcode("Xcode 27.3\nBuild version 27C5020n"))
        #expect(throws: MacIntentTestingError.self) {
            try SiriStudioRunner.requireSupportedOS(.init(majorVersion: 27, minorVersion: 2, patchVersion: 9))
        }
        let scenario = SiriStudioScenario(name: "Long", repeatCount: 10, turns: Array(repeating: .init(), count: 12))
        let (allowance, timeout) = try SiriStudioSource.timeouts(for: [scenario], allowance: nil, timeout: nil)
        #expect(allowance == 1800 && timeout == 2400)
        #expect(throws: MacIntentTestingError.self) {
            _ = try SiriStudioSource.timeouts(for: Array(repeating: scenario, count: 8), allowance: nil, timeout: nil)
        }
    }

    /// Opens actual compiled metadata from the synthetic Courtside app.
    private func fixtureCatalog() throws -> MacIntentCatalog {
        try MacIntentCatalog.decode(data: Data(contentsOf: Self.fixture.appending(path: "Courtside.actions.json")),
            bundleIdentifier: "dev.intents.samples.Courtside", appURL: URL(filePath: "/tmp/Courtside.app"))
    }
}
