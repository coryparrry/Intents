import Foundation
import Testing
@testable import MacIntentTesting

/// Explicitly opted-in qualification against the developer-signed synthetic Courtside fixture.
struct SiriStudioLiveTests {
    /// Confirms Apple's verdict and observed arguments on a compatible Mac with Siri AI and development signing.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTENTS_RUN_LIVE_SIRI"] == "1"))
    @MainActor func signedCourtsideSiri() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["INTENTS_SIRI_FIXTURE_APP"])
        let developer = try #require(environment["DEVELOPER_DIR"])
        let team = try #require(environment["INTENTS_SIRI_TEAM"])
        let signing = try #require(environment["INTENTS_SIRI_IDENTITY"])
        let output = try #require(environment["INTENTS_SIRI_EVIDENCE"])
        let catalog = try await MacIntentCatalog.loadAsync(appURL: URL(filePath: path))
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = try SiriStudioDocument.read(from: root.appending(path: "examples/SiriStudioSample/scenarios.json"))
        let configuration = MacIntentRunConfiguration(developerDirectory: URL(filePath: developer),
            signingIdentity: signing, teamIdentifier: team, outputDirectory: URL(filePath: output))
        let record = try await SiriStudioRunner().run(document: document, catalog: catalog, configuration: configuration)
        let outcomes = Dictionary(uniqueKeysWithValues: record.scenarios.map { ($0.name, $0) })
        #expect(outcomes["Add and open"]?.state == .passed)
        let negative = try #require(outcomes["Deliberate mismatch"])
        #expect(negative.state == .failed)
        #expect(negative.reports.flatMap(\.turns).flatMap(\.invocations)
            .contains { $0.intent == "AddPlayerIntent" && $0.arguments["number"] == "12" })
        let question = try #require(outcomes["Don’t act on a question"])
        #expect(question.state == .passed || (question.state == .failed && question.reports.flatMap(\.turns).flatMap(\.invocations)
            .contains { ["AddPlayerIntent", "DeletePlayerIntent"].contains($0.intent) && ($0.ran || $0.outcome == "awaitingConfirmation") }))
    }
}
