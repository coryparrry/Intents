import Foundation
import IntentLabContracts
#if INTENT_LAB_SIRI_ONLY
import IntentLabCoreTesting
typealias NotesTestingIntegration = IntentLabSiriIntegration
#else
import IntentLabTesting
typealias NotesTestingIntegration = IntentLabIntegration
#endif
import XCTest

@available(iOS 27.0, *)
@MainActor
struct NotesIntentLabIntegration: NotesTestingIntegration {
    var supportedCapabilities: Set<String> {
        #if INTENT_LAB_SIRI_ONLY
        ["environment-payload", "preparation", "accessible-result", "siri",
         "siri-completion", "invocation-correlation", "action-receipt-v1"]
        #else
        ["environment-payload", "direct-intent-execution", "direct-intent-output",
         "preparation", "accessible-result", "siri", "siri-completion", "invocation-correlation",
         "action-receipt-v1", "test-only-intent", "local-feature-controls"]
        #endif
    }
    func prepare(bundleIdentifier: String, context: String, operationID: String) throws -> XCUIApplication {
        guard ["", "reset", "resetNotes", "resetFixture"].contains(operationID) else {
            throw NotesIntegrationError.unsupportedPreparation(operationID)
        }
        let application = XCUIApplication(bundleIdentifier: bundleIdentifier)
        application.launchArguments = [
            "-intent-lab-reset", "-intent-lab-operation", operationID,
            "-intent-lab-context", context
        ]
        application.launch()
        return application
    }

    func cleanup(bundleIdentifier: String, context: String, operationID: String) throws {
        guard ["", "reset", "resetNotes", "resetFixture"].contains(operationID) else {
            throw NotesIntegrationError.unsupportedCleanup(operationID)
        }
        let application = XCUIApplication(bundleIdentifier: bundleIdentifier)
        application.launchArguments = [
            "-intent-lab-cleanup", "-intent-lab-operation", operationID,
            "-intent-lab-context", context
        ]
        application.launch()
        defer { application.terminate() }
        let observations = try observe(application: application)
        guard observations["selectedNoteID"] == .string("none"),
              observations["noteStoreMutationCount"] == .integer(0),
              observations["applicationEvent"] == .string("none") else {
            throw NotesIntegrationError.resetNotObserved
        }
    }

    func observe(application: XCUIApplication) throws -> [String: IntentLabValue] {
        var observations: [String: IntentLabValue] = [:]
        let snapshotElement = application.staticTexts["intentlab.fixtureSnapshot"]
        if snapshotElement.waitForExistence(timeout: 2),
           let data = snapshotElement.label.data(using: .utf8),
           let snapshot = try? JSONDecoder().decode(NotesFixtureSnapshot.self, from: data) {
            observations["selectedNoteID"] = .string(snapshot.selectedNoteID)
            observations["noteStoreMutationCount"] = .integer(Int64(snapshot.noteStoreMutationCount))
            observations["invocationContext"] = .string(snapshot.invocationContext)
            observations["applicationEvent"] = .string(snapshot.applicationEvent)
            if let digest = snapshot.fixtureDigest { observations["intentlab.fixtureDigest"] = .string(digest) }
            if let encodedDigests = try? JSONEncoder().encode(snapshot.fixtureDigests),
               let json = String(data: encodedDigests, encoding: .utf8) {
                observations["intentlab.fixtureDigests"] = .string(json)
            }
        }
        let receiptElement = application.staticTexts["intentlab.actionReceipts"]
        if receiptElement.waitForExistence(timeout: 2) {
            let json = receiptElement.label
            if json.utf8.count <= 65_536,
               let data = json.data(using: .utf8),
               (try? JSONDecoder.intentLab.decode([IntentLabActionReceipt].self, from: data)) != nil {
                observations["intentlab.actionReceipts"] = .string(json)
            }
        }
        let selected = application.staticTexts["intent-lab-selected-note-id"]
        if selected.waitForExistence(timeout: 2) { observations["selectedNoteID"] = .string(selected.label) }
        let preparedDigests = application.staticTexts["intent-lab-fixture-digests"]
        if preparedDigests.waitForExistence(timeout: 2) {
            observations["intentlab.fixtureDigests"] = .string(preparedDigests.label)
        }
        let fixtureDigest = application.staticTexts["intent-lab-fixture-digest"]
        if case .string(let selectedID)? = observations["selectedNoteID"],
           selectedID != "none",
           fixtureDigest.waitForExistence(timeout: 2) {
            observations["intentlab.fixtureDigest"] = .string(fixtureDigest.label)
        }
        let mutation = application.staticTexts["intent-lab-mutation-count"]
        if mutation.exists, let count = Int64(mutation.label) { observations["noteStoreMutationCount"] = .integer(count) }
        let context = application.staticTexts["intent-lab-observed-context"]
        if context.exists { observations["invocationContext"] = .string(context.label) }
        let event = application.staticTexts["intent-lab-last-event"]
        if event.exists {
            observations["applicationEvent"] = .string(event.label)
        }
        let summary = application.staticTexts["intent-lab-visible-summary"]
        if summary.exists, !summary.label.isEmpty {
            observations["visibleSummary"] = .string(summary.label)
            observations["visibleResponse"] = .string(summary.label)
        }
        for (key, selector) in [
            ("summarySourceNoteID", "intent-lab-summary-source-note-id"),
            ("summarySourceContentDigest", "intent-lab-summary-source-digest"),
            ("summaryContext", "intent-lab-summary-context"),
            ("summaryCompletionID", "intent-lab-summary-completion-id"),
            ("summaryCaseID", "intent-lab-summary-case-id"),
            ("summaryAttemptID", "intent-lab-summary-attempt-id")
        ] {
            let element = application.staticTexts[selector]
            if element.exists, !element.label.isEmpty {
                observations[key] = .string(element.label)
            }
        }
        return observations
    }

    func completed(observations: [String: IntentLabValue], context: String) -> Bool {
        guard observations["invocationContext"] == .string(context),
              case .string(let selectedID) = observations["selectedNoteID"],
              selectedID != "none", !selectedID.isEmpty,
              case .string(let event) = observations["applicationEvent"],
              event != "none", !event.isEmpty else { return false }
        if event == "OpenNoteIntent:\(selectedID)" { return true }
        guard ["SummarizeNoteIntent", "AppFeature", "AppUI"].contains(where: { event == "\($0):\(selectedID)" }) else {
            return false
        }
        guard observations["summaryContext"] == .string(context),
              observations["summarySourceNoteID"] == .string(selectedID),
              case .string(let summary) = observations["visibleSummary"],
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .string(let digest) = observations["summarySourceContentDigest"],
              digest.count == 64, digest.allSatisfy({ $0.isHexDigit }),
              case .string(let completionID) = observations["summaryCompletionID"], UUID(uuidString: completionID) != nil else {
            return false
        }
        return true
    }

    func source(for observationKey: String) -> String { "accessibleUI" }
}

private struct NotesFixtureSnapshot: Decodable {
    var selectedNoteID: String
    var noteStoreMutationCount: Int
    var invocationContext: String
    var applicationEvent: String
    var fixtureDigests: [String]
    var fixtureDigest: String?
}

private enum NotesIntegrationError: LocalizedError {
    case unsupportedPreparation(String)
    case unsupportedCleanup(String)
    case resetNotObserved

    var errorDescription: String? {
        switch self {
        case .unsupportedPreparation(let operation):
            "The Notes fixture does not provide preparation operation \(operation)."
        case .unsupportedCleanup(let operation):
            "The Notes fixture does not provide cleanup operation \(operation)."
        case .resetNotObserved:
            "The synthetic note fixture did not return to its empty baseline."
        }
    }
}

@available(iOS 27.0, *)
@MainActor
final class NotesActionReceiptObserverTests: XCTestCase {
    func testPreparedAppExposesTypedEmptyActionReceiptJSON() throws {
        let context = "intent-\(UUID().uuidString)"
        let application = try NotesIntentLabIntegration().prepare(
            bundleIdentifier: "com.coryparry.IntentLabFixture.integration-tests",
            context: context,
            operationID: "reset"
        )
        defer { application.terminate() }

        let observations = try NotesIntentLabIntegration().observe(application: application)
        guard case .string(let json) = observations["intentlab.actionReceipts"],
              let data = json.data(using: .utf8) else {
            return XCTFail("The app must expose its bounded action receipt array as JSON.")
        }
        let receipts = try JSONDecoder.intentLab.decode([IntentLabActionReceipt].self, from: data)
        XCTAssertTrue(receipts.isEmpty)
        XCTAssertEqual(NotesIntentLabIntegration().source(for: "intentlab.actionReceipts"), "accessibleUI")
    }
}
