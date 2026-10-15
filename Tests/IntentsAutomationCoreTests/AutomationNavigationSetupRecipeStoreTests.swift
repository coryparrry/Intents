import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationNavigationSetupRecipeStoreTests: XCTestCase {
    private func fixture() throws -> (FreshFixtureTestData, [AutomationCapturedSetupAttempt]) {
        var plan = try FreshFixtureTestData().plan
        plan.setup[0].uiProgram = .init(operations: [.init(id: "create", kind: .navigateGoal,
            goal: .init(id: "create", instruction: "Create", endpoint: .init(.testId, "done")))], bindings: ["title": "Send invoice"])
        let fixture = try FreshFixtureTestData(plan: plan)
        let attempts = try ["first", "second"].map { id -> AutomationCapturedSetupAttempt in
            let live = fixture.evidence(id: id, prefix: id)
            return try .init(live: live, capture: .init(scope: live.report.receipts[0].scope, operations: [
                .init(id: "learned.0", kind: .fillBinding, locator: .init(.testId, "task.title"), binding: "title"),
                .init(id: "learned.endpoint", kind: .assertEndpoint, locator: .init(.testId, "done"))]), bindings: fixture.bindings)
        }
        return (fixture, attempts)
    }
    private func root() -> URL { URL(fileURLWithPath: "/private/tmp/setup-recipes-" + UUID().uuidString) }

    func testReopeningPreservesActualTwoAttemptEvidenceAndOnlyProposesFreshSetup() throws {
        let (fixture, attempts) = try fixture()
        XCTAssertThrowsError(try AutomationQualifiedNavigationSetupRecipe(attempts: [attempts[0]]))
        XCTAssertThrowsError(try AutomationQualifiedNavigationSetupRecipe(attempts: [attempts[0], attempts[0]]))
        let live = try AutomationQualifiedNavigationSetupRecipe(attempts: attempts)
        let proposal = try live.savedProposal(), root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try AutomationNavigationSetupRecipeStore(supportRoot: root).save(proposal)
        let restored = try XCTUnwrap(AutomationNavigationSetupRecipeStore(supportRoot: root).read(context: proposal.context))
        XCTAssertEqual(restored, proposal)
        XCTAssertEqual(restored.qualificationAttemptIDs, attempts.map { $0.live.report.attemptID })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(restored.qualificationReportDigests, try attempts.map { AutomationArtifactRegistry.digest(try encoder.encode($0.live.report)) })
        let fresh = try restored.propose(plan: fixture.plan, context: proposal.context)
        XCTAssertEqual(fresh.execution, fixture.plan.execution)
        XCTAssertEqual(fresh.observations, fixture.plan.observations)
        XCTAssertEqual(fresh.setupChecks, fixture.plan.setupChecks)
        let codecCapabilities = CapabilityProfile(records: ["apple.codec.entity": .init(state: .available,
            reason: "Synthetic driver conversion contract", probeVersion: "test", evidence: [])])
        XCTAssertThrowsError(try PlanValidator.validate(fresh, approval: fixture.approval, capabilities: codecCapabilities))
        let bytes = try Data(contentsOf: root.appendingPathComponent("learned-setup-recipes.json"))
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        for privateValue in ["Send invoice", "first-Personal", "second-Work", "verifiedOutputs", "receipts", "approvedCaseDigest"] {
            XCTAssertFalse(json.contains(privateValue), "Persisted private attempt content: \(privateValue)")
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("learned-setup-recipes.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExactIdentityAndApprovedFixtureContractMustStillMatch() throws {
        let (fixture, attempts) = try fixture(), recipe = try AutomationQualifiedNavigationSetupRecipe(attempts: attempts).savedProposal()
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try AutomationNavigationSetupRecipeStore(supportRoot: root); try store.save(recipe)
        for field in ["app", "target", "environmentID", "catalogDigest", "hostDigest", "localeIdentifier", "uiRuntimeManifestDigest"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe.context)) as? [String: Any])
            if field == "app" {
                var app = try XCTUnwrap(json[field] as? [String: Any]); app["productDigest"] = String(repeating: "b", count: 64); json[field] = app
            } else if field == "target" {
                var target = try XCTUnwrap(json[field] as? [String: Any]); target["id"] = "other-device"; json[field] = target
            } else { json[field] = field.hasSuffix("Digest") ? String(repeating: "b", count: 64) : "other" }
            let changed = try JSONDecoder().decode(AutomationRecipeContext.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertNil(try store.read(context: changed))
            XCTAssertThrowsError(try recipe.propose(plan: fixture.plan, context: changed))
        }
        var changed = fixture.plan; changed.setup[0].uiProgram?.bindings["title"] = "Changed task"
        XCTAssertThrowsError(try recipe.propose(plan: changed, context: recipe.context))
        changed = fixture.plan; changed.setupChecks = []
        XCTAssertThrowsError(try recipe.propose(plan: changed, context: recipe.context))
    }

    func testMalformedOversizedAndUnknownArchivesAreRejectedAndPreserved() throws {
        let (_, attempts) = try fixture(), recipe = try AutomationQualifiedNavigationSetupRecipe(attempts: attempts).savedProposal()
        for mode in ["malformed", "oversized", "unknown", "duplicate", "bad-evidence", "bad-operation"] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try AutomationNavigationSetupRecipeStore(supportRoot: root)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any])
            if mode == "bad-evidence" { json["qualificationAttemptIDs"] = ["same", "same"] }
            if mode == "bad-operation" {
                var operations = try XCTUnwrap(json["operations"] as? [[String: Any]])
                operations[0]["kind"] = "navigateGoal"; json["operations"] = operations
            }
            let archive: [String: Any] = ["version": mode == "unknown" ? 99 : 1, "recipes": mode == "duplicate" ? [json, json] : [json]]
            let data = mode == "malformed" ? Data("{".utf8) : mode == "oversized" ? Data(repeating: 32, count: 524_289) : try JSONSerialization.data(withJSONObject: archive)
            let path = root.appendingPathComponent("learned-setup-recipes.json"); try data.write(to: path)
            XCTAssertThrowsError(try store.read(context: recipe.context), mode)
            XCTAssertThrowsError(try store.save(recipe), mode)
            XCTAssertEqual(try Data(contentsOf: path), data, mode)
        }
    }

    func testArchiveBoundsContextHistoryWithoutMixingCompatibleSelections() throws {
        let (_, attempts) = try fixture(), recipe = try AutomationQualifiedNavigationSetupRecipe(attempts: attempts).savedProposal()
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try AutomationNavigationSetupRecipeStore(supportRoot: root)
        var contexts: [AutomationRecipeContext] = []
        for index in 0..<9 {
            let context = AutomationRecipeContext(app: recipe.context.app, target: recipe.context.target, environmentID: "environment-\(index)",
                catalogDigest: recipe.context.catalogDigest, hostDigest: recipe.context.hostDigest, localeIdentifier: recipe.context.localeIdentifier,
                uiRuntimeManifestDigest: recipe.context.uiRuntimeManifestDigest)
            contexts.append(context)
            let saved = AutomationSavedNavigationSetupRecipe(context: context, qualificationAttemptIDs: recipe.qualificationAttemptIDs,
                qualificationReportDigests: recipe.qualificationReportDigests, fixtureDigest: recipe.fixtureDigest,
                segmentID: recipe.segmentID, operations: recipe.operations)
            try store.save(saved)
        }
        XCTAssertNil(try store.read(context: contexts[0]))
        for context in contexts.dropFirst() { XCTAssertEqual(try store.read(context: context)?.context, context) }
    }

    func testQualificationRejectsUnreleasedOrUncertainAttemptWithoutPersistingSuccess() throws {
        let (_, attempts) = try fixture()
        for unreleased in [true, false] {
            var report = attempts[1].live.report
            if unreleased { report.resourcesReleased = false } else { report.result.subjectDispatchUncertain = true }
            let live = AutomationLiveRecipeEvidence(context: attempts[1].live.context, plan: attempts[1].live.plan, approval: attempts[1].live.approval, report: report)
            XCTAssertThrowsError(try AutomationCapturedSetupAttempt(live: live, capture: attempts[1].capture, bindings: attempts[1].bindings))
        }
    }
}
