import Foundation
import MacIntentTesting
import Testing
@testable import FoundationEvals

/// Checks that onboarding follows real readiness and creates actionable, isolated example drafts.
@MainActor struct SiriStudioGuideTests {
    /// Missing prerequisites take precedence over authored content, and a complete selection reaches Run.
    @Test func progressTracksTheNextIncompleteStage() {
        let catalog = MacIntentCatalog(bundleIdentifier: "example.Guide", appURL: URL(filePath: "/Guide.app"),
            actions: [.init(id: "Echo", title: "Echo", parameters: [], outputType: "String")])
        #expect(SiriStudioGuideStep.current(catalog: nil, macReady: true, conversationReady: true) == .app)
        #expect(SiriStudioGuideStep.current(catalog: catalog, macReady: false, conversationReady: true) == .mac)
        #expect(SiriStudioGuideStep.current(catalog: catalog, macReady: true, conversationReady: false) == .conversation)
        #expect(SiriStudioGuideStep.current(catalog: catalog, macReady: true, conversationReady: true) == .run)
    }

    /// A starter names a real catalog action and remains valid when another conversation is unfinished.
    @Test func exampleIsRunnableAlongsideAnUnfinishedDraft() throws {
        let catalog = MacIntentCatalog(bundleIdentifier: "example.Guide", appURL: URL(filePath: "/Guide.app"),
            actions: [.init(id: "Echo", title: "Echo a message", parameters: [], outputType: "String")])
        let example = try #require(SiriStudioGuideStep.example(for: catalog))
        #expect(example.turns[0].utterance.contains("Guide"))
        #expect(example.turns[0].expectations.calls[0].actionIdentifier == "Echo")
        let unfinished = SiriStudioScenario(name: "Unfinished")
        let document = SiriStudioDocument(bundleIdentifier: catalog.bundleIdentifier, scenarios: [unfinished, example])
        try SiriStudioValidation.validate(document, catalog: catalog, scenarioIDs: [example.id])
        #expect(throws: (any Error).self) { try SiriStudioValidation.validate(document, catalog: catalog) }
        #expect(document.scenarios[0] == unfinished)
    }

    /// Apps without compiled actions cannot receive an invented example or a false ready state.
    @Test func emptyCatalogDoesNotInventAnAction() {
        let catalog = MacIntentCatalog(bundleIdentifier: "example.Empty", appURL: URL(filePath: "/Empty.app"), actions: [])
        #expect(SiriStudioGuideStep.example(for: catalog) == nil)
        #expect(SiriStudioGuideStep.current(catalog: catalog, macReady: true, conversationReady: true) == .app)
    }
}
