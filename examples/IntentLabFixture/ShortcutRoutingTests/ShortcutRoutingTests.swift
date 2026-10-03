import AppIntents
import Foundation
import Testing
@testable import FixtureShortcutRouting

@Suite(.serialized)
@MainActor
struct ShortcutRoutingTests {
    private func prepare() {
        FixtureState.reset()
        UserDefaults.standard.set("offline-preset-routing", forKey: FixtureState.activeContextKey)
        SummaryService.calls = []
        SummaryService.shouldFail = false
    }

    @Test func openingThePresetUsesTheOpenProductionIntent() async throws {
        prepare()
        defer { FixtureState.reset() }
        let result = try await OpenPackingNoteIntent().perform()
        #expect(result.value == "packing-001")
        #expect(UserDefaults.standard.string(forKey: FixtureState.eventKey) == "OpenNoteIntent:packing-001")
        #expect(SummaryService.calls.isEmpty)
        #expect(UserDefaults.standard.data(forKey: FixtureState.summaryReceiptKey) == nil)
    }

    @Test func summarizingThePresetUsesTheSummaryProductionIntentAndPublishesItsOutput() async throws {
        prepare()
        defer { FixtureState.reset() }
        let result = try await SummarizePackingNoteIntent().perform()
        #expect(result.value == "Summary of packing-001")
        #expect(SummaryService.calls == ["packing-001"])
        #expect(UserDefaults.standard.string(forKey: FixtureState.eventKey) == "SummarizeNoteIntent:packing-001")
        let data = try #require(UserDefaults.standard.data(forKey: FixtureState.summaryReceiptKey))
        let receipt = try JSONDecoder().decode(FixtureSummaryReceipt.self, from: data)
        #expect(receipt.noteID == "packing-001")
        #expect(receipt.summary == result.value)
        #expect(receipt.route == "SummarizeNoteIntent")
        #expect(receipt.context == "offline-preset-routing")
    }

    @Test func summaryFailurePropagatesAndDoesNotOpenTheNote() async throws {
        prepare()
        defer { FixtureState.reset() }
        SummaryService.shouldFail = true
        await #expect(throws: SummaryService.Failure.unavailable) {
            try await SummarizePackingNoteIntent().perform()
        }
        #expect(SummaryService.calls == ["packing-001"])
        #expect(UserDefaults.standard.string(forKey: FixtureState.eventKey) != "OpenNoteIntent:packing-001")
        #expect(UserDefaults.standard.data(forKey: FixtureState.summaryReceiptKey) == nil)
    }
}
