#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    func testPendingNativeRunCanBeReviewedAndConfirmedWhileApplicationSelectionIsBlocked() async throws {
        let (model, _, bundle) = try await fixture(executor: { _, plan, approval, _, attemptID, _ in
            try await NativeSearchFactExecutor().execute(frozen: AutomationFrozenCase(plan: plan), approval: approval,
                attemptID: attemptID, budget: .init(limits: .firstCampaign))
        })
        model.uiExpectedText = "Complete"
        let preview = try model.previewCommand(), requestID = UUID()
        _ = try model.requestCommand(id: requestID, digest: preview.digest)
        let selected = model.candidateID, epoch = model.selectionEpoch
        XCTAssertFalse(model.canSelectApplicationFromCommand)
        XCTAssertTrue(model.canReviewSelectedApplicationForRun)
        XCTAssertTrue(model.canRun)
        model.select(bundle)
        XCTAssertEqual(model.candidateID, selected)
        XCTAssertEqual(model.selectionEpoch, epoch)
        let review = try await model.prepareNativeConfirmation(.run)
        XCTAssertEqual(review.id, requestID)
        XCTAssertEqual(review.digest, preview.digest)
        XCTAssertFalse(model.canSelectApplicationFromCommand)
        XCTAssertTrue(model.canReviewSelectedApplicationForRun)
        try await model.confirmNativeRequest(review)
        await model.task?.value
        XCTAssertEqual(try model.commandStatus(id: requestID).state, "completed")
        XCTAssertEqual(model.report?.resourcesReleased, true)
        XCTAssertEqual(model.report?.result.subjectDispatched, true)
        XCTAssertNil(model.pendingCommandStatus)
    }
}
#endif

#if os(macOS)
extension InstalledUIStoreTests {
    func testMalformedSearchDoesNotHideValidReproductionOrInjectedCaseReader() async throws {
        let (model, root, _) = try await fixture()
        try selectPreparedSource(model: model, root: root)
        let frozen = try await saveFailure(model: model, root: root)
        let caseRoot = root.appendingPathComponent("support/Cases"), cases = try AutomationCaseStore(root: caseRoot)
        let attempts = try await cases.attempts(for: frozen), original = try XCTUnwrap(attempts.first)
        let proposal = try AutomationNativeUIReproductionProposal.compile(frozen: frozen, original: original,
            subject: .prepared(try XCTUnwrap(model.prepared)), runID: "history-reproduction", disposable: false)
        let report = try await proposal.runCampaign(cases: cases, executor: NativeSearchFactExecutor(fails: true))
        try await AutomationReproductionArchive(caseStoreRoot: caseRoot).save(report)
        let searches = caseRoot.appendingPathComponent("Searches")
        try FileManager.default.createDirectory(at: searches, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let broken = searches.appendingPathComponent("broken.json")
        try Data("malformed navigateGoal".utf8).write(to: broken)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: broken.path)
        model.message = "The current workflow failed: expected task state was not observed."
        let operationError = model.message
        await model.refreshSavedCases()
        XCTAssertEqual(model.message, operationError)
        // fixture() injects an empty case reader; it must still be used.
        XCTAssertTrue(model.savedCases.isEmpty)
        XCTAssertEqual(model.savedReproductions.map(\.runID), [report.runID])
        XCTAssertTrue(model.savedHistoryNotice?.contains("Saved searches could not be verified") == true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(frozen)) as? [String: Any])
        var legacyPlan = try XCTUnwrap(legacy["plan"] as? [String: Any])
        var execution = try XCTUnwrap(legacyPlan["execution"] as? [String: Any])
        execution["uiProgram"] = ["operations": [["id": "old-navigation", "kind": "navigateGoal"]],
                                  "bindings": [String: String](), "timeoutMilliseconds": 120000]
        legacyPlan["execution"] = execution; legacyPlan["id"] = "retired-case"; legacy["plan"] = legacyPlan
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        let digest = AutomationArtifactRegistry.digest(try JSONSerialization.data(withJSONObject: legacyPlan, options: options))
        legacy["digest"] = digest
        let directory = caseRoot.appendingPathComponent("Definitions/retired-case")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let legacyFile = directory.appendingPathComponent("v1-" + digest + ".json")
        try JSONSerialization.data(withJSONObject: legacy, options: options).write(to: legacyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyFile.path)
        let reopened = AppAutomationStore(supportDirectory: root.appendingPathComponent("support"))
        reopened.message = operationError
        await reopened.refreshSavedCases()
        XCTAssertEqual(reopened.message, operationError)
        XCTAssertEqual(reopened.savedCases, [frozen])
        XCTAssertEqual(reopened.savedReproductions.map(\.runID), [report.runID])
        XCTAssertTrue(reopened.savedHistoryNotice?.contains("Saved searches could not be verified") == true)
        XCTAssertTrue(reopened.savedHistoryNotice?.contains("retired controller") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
        await reopened.closeAndWait(); await model.closeAndWait()
    }
}
#endif
