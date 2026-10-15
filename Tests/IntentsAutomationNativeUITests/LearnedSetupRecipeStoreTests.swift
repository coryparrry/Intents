#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore
@testable import IntentsAutomationNativeUI

extension InstalledUIStoreTests {
    func testDeterministicSetupCannotMintLiveLearnedAuthorityOnReload() async throws {
        let (model, root, _) = try await fixture(); try selectFreshSource(model: model, root: root)
        let prepared = try XCTUnwrap(model.prepared), request = try model.makeFreshRecordRequest(runID: "learning")
        XCTAssertThrowsError(try learnedCapture(request, prepared: prepared, id: "first"))
        model.reloadSelectedLearnedSetup(); model.reloadSelectedLearnedSetup()
        XCTAssertTrue(model.learnedSetupAttempts.isEmpty); XCTAssertNil(model.learnedSetupRecipe)
        XCTAssertNil(model.savedLearnedSetupRecipe)
        XCTAssertEqual(try model.makeFreshRecordRequest(runID: "reload").caseDigest, request.caseDigest)
    }
    func testSelectedAppReloadRejectsChangedHostAndKeepsExecutionMessage() async throws {
        let (model, root, _) = try await fixture()
        try selectFreshSource(model: model, root: root)
        let prepared = try XCTUnwrap(model.prepared)
        let context = AutomationRecipeContext(app: prepared.host.app, target: prepared.host.target,
            environmentID: "selected-simulator:" + prepared.host.target.id,
            catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog), hostDigest: prepared.host.hostProductDigest,
            localeIdentifier: Locale.current.identifier)
        let saved = AutomationSavedNavigationSetupRecipe(context: context,
            qualificationAttemptIDs: ["first", "second"], qualificationReportDigests: [String(repeating: "f", count: 64), String(repeating: "b", count: 64)],
            fixtureDigest: String(repeating: "a", count: 64), segmentID: "fixture.create",
            operations: [.init(id: "learned.0", kind: .fillBinding, locator: .init(.testId, "title"), binding: "approvedText"),
                         .init(id: "learned.endpoint", kind: .assertEndpoint, locator: .init(.label, "Tasks"))])
        try AutomationNavigationSetupRecipeStore(supportRoot: model.support).save(saved)
        model.reloadSelectedLearnedSetup()
        XCTAssertEqual(model.savedLearnedSetupRecipe, saved)
        XCTAssertNil(model.learnedSetupRecipe); XCTAssertTrue(model.learnedSetupAttempts.isEmpty)
        model.message = "Review the retained execution before continuing"
        model.prepared?.host.hostProductDigest = String(repeating: "f", count: 64); model.reloadSelectedLearnedSetup()
        XCTAssertNil(model.savedLearnedSetupRecipe); XCTAssertNil(model.learnedSetupRecipe)
        XCTAssertTrue(model.learnedSetupAttempts.isEmpty)
        XCTAssertEqual(model.message, "Review the retained execution before continuing")
        XCTAssertFalse(model.busy)
    }
}

@MainActor final class LearnedSetupRecipeStoreTests: XCTestCase {
    private func proposal() -> AutomationSavedNavigationSetupRecipe {
        // Serialized proposal fixture; this never represents live qualification.
        .init(context: .init(app: .init(logicalID: "selected", bundleID: "example.Selected", platform: "ios", productDigest: String(repeating: "a", count: 64)),
                            target: .init(id: "owned", kind: .simulator), environmentID: "selected-simulator:owned",
                            catalogDigest: String(repeating: "c", count: 64), hostDigest: String(repeating: "d", count: 64),
                            localeIdentifier: "en_GB", uiRuntimeManifestDigest: String(repeating: "e", count: 64)),
              qualificationAttemptIDs: ["first", "second"], qualificationReportDigests: [String(repeating: "f", count: 64), String(repeating: "b", count: 64)],
              fixtureDigest: String(repeating: "a", count: 64), segmentID: "create",
              operations: [.init(id: "learned.0", kind: .fillBinding, locator: .init(.testId, "title"), binding: "title"),
                           .init(id: "learned.endpoint", kind: .assertEndpoint, locator: .init(.testId, "done"))])
    }
    func testReopeningLoadsOnlyProposalAndNeverRestoresApprovalOrLiveAttempts() throws {
        let root = URL(fileURLWithPath: "/private/tmp/native-setup-recipe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = proposal(); try AutomationNavigationSetupRecipeStore(supportRoot: root).save(saved)
        let reopened = AppAutomationStore(supportDirectory: root)
        XCTAssertNil(reopened.savedLearnedSetupRecipe)
        reopened.reloadLearnedSetup(context: saved.context)
        XCTAssertEqual(reopened.savedLearnedSetupRecipe, saved)
        XCTAssertNil(reopened.learnedSetupRecipe); XCTAssertTrue(reopened.learnedSetupAttempts.isEmpty)
        XCTAssertNil(reopened.prepared); XCTAssertNil(reopened.report)
        XCTAssertFalse(reopened.busy); XCTAssertNil(reopened.learnedSetupPersistenceError)
        var app = saved.context.app; app.productDigest = String(repeating: "b", count: 64)
        let incompatible = AutomationRecipeContext(app: app, target: saved.context.target, environmentID: saved.context.environmentID,
            catalogDigest: saved.context.catalogDigest, hostDigest: saved.context.hostDigest, localeIdentifier: saved.context.localeIdentifier,
            uiRuntimeManifestDigest: saved.context.uiRuntimeManifestDigest)
        reopened.reloadLearnedSetup(context: incompatible)
        XCTAssertNil(reopened.savedLearnedSetupRecipe); XCTAssertFalse(reopened.busy)
        XCTAssertEqual(try AutomationNavigationSetupRecipeStore(supportRoot: root).read(context: saved.context), saved)
    }
    func testReloadFailureClearsStaleProposalWithoutChangingExecutionEvidence() throws {
        let root = URL(fileURLWithPath: "/private/tmp/native-setup-recipe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = proposal(); try AutomationNavigationSetupRecipeStore(supportRoot: root).save(saved)
        let model = AppAutomationStore(supportDirectory: root); model.reloadLearnedSetup(context: saved.context)
        model.message = "Existing unresolved execution still needs reconciliation"
        let data = Data("unknown or malformed archive".utf8)
        let path = root.appendingPathComponent("learned-setup-recipes.json"); try data.write(to: path)
        model.reloadLearnedSetup(context: saved.context)
        XCTAssertNil(model.savedLearnedSetupRecipe); XCTAssertNotNil(model.learnedSetupPersistenceError)
        XCTAssertEqual(model.message, "Existing unresolved execution still needs reconciliation")
        XCTAssertEqual(try Data(contentsOf: path), data)
        XCTAssertFalse(model.busy)
    }
}
#endif
