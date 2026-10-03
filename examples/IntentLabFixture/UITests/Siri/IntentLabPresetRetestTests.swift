import Foundation
import XCTest
import IntentLabContracts
@testable import IntentLabCoreTesting

@available(iOS 27.0, *)
@MainActor
final class IntentLabPresetRetestTests: XCTestCase {
    func testOpenPackingNotePreset() throws {
        try checkPreset(kind: "OpenNoteIntent", phrase: "Open the packing note in Intent Lab Fixture")
    }

    func testSummaryPackingNotePreset() throws {
        try checkPreset(kind: "SummarizeNoteIntent", phrase: "Summarize the packing note in Intent Lab Fixture")
    }

    private func checkPreset(kind: String, phrase: String) throws {
        executionTimeAllowance = 90
        continueAfterFailure = false
        let bundleID = "com.coryparry.IntentLabFixture"
        let app = XCUIApplication(bundleIdentifier: bundleID)
        let integration = PresetPhoneIntegration()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "IntentLabIntegration", withExtension: "json"))
        let declaration = try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self, from: Data(contentsOf: url))
        let safety = try JSONDecoder.intentLab.decode(IntentLabSafety.self, from: Data("{\"deadlineSeconds\":12}".utf8))
        let context = "phone-retest-\(UUID().uuidString)"
        let cleanup = PresetRetestCleanup()
        addTeardownBlock { @MainActor in
            defer { app.terminate(); XCUIDevice.shared.press(.home) }
            // Never reset an unresolved attempt that may still publish a result.
            if cleanup.confirmedCompletion {
                try integration.cleanup(bundleIdentifier: bundleID, context: context, operationID: "reset")
            }
        }
        do {
            let prepared = try integration.prepare(bundleIdentifier: bundleID, context: context, operationID: "reset")
            let baseline = try integration.observe(application: prepared)
            try NotesIntentLabIntegration.verifyReset(baseline)
            let observations = try SiriProbe.run(request: phrase, application: prepared,
                expectedContext: context, safety: safety, testCase: self,
                integration: integration, declaration: declaration, permitsChooserAssistance: false)
            cleanup.confirmedCompletion = true
            let attachment = XCTAttachment(data: try JSONEncoder.intentLab.encode(observations), uniformTypeIdentifier: "public.json")
            attachment.name = "phone-retest-\(kind)-observations"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(observations["applicationEvent"], .string("\(kind):packing-001"))
            XCTAssertEqual(observations["selectedNoteID"], .string("packing-001"))
            XCTAssertEqual(observations["invocationContext"], .string(context))
            XCTAssertEqual(observations["noteStoreMutationCount"], .integer(0))
            if kind == "SummarizeNoteIntent" {
                XCTAssertEqual(observations["summaryContext"], .string(context))
                XCTAssertEqual(observations["summarySourceNoteID"], .string("packing-001"))
                XCTAssertEqual(observations["summarySourceContentDigest"], observations["intentlab.fixtureDigest"])
                guard case .string(let text) = observations["visibleSummary"] else {
                    XCTFail("No live generated summary was observed"); return
                }
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            let screenshot = XCTAttachment(screenshot: prepared.screenshot())
            screenshot.name = "phone-retest-\(kind)-fixture"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }
}

@available(iOS 27.0, *)
@MainActor
private final class PresetRetestCleanup {
    var confirmedCompletion = false
}
