import XCTest
@testable import IntentsAutomationCore

final class AutomationUIRequestFixtureTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (AutomationCase, RunApproval) {
        let app = AppIdentity(logicalID: "local-ai", bundleID: "example.LocalAI", platform: "ios")
        let target = TargetIdentity(id: "disposable-simulator", kind: .simulator)
        var approval = RunApproval(runID: "request-search", app: app, target: target, environmentID: "disposable",
            effects: [.observe, .navigate, .fixtureWrite], maximumActions: 30, disposable: true)
        var original = try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Submit the frozen local request",
            endpoint: "Response", approvedText: "Show completed tasks", expectedVisibleText: "Complete", approval: approval, localeIdentifier: "en_GB")
        original.provenance["ui.runtimeManifestDigest"] = String(repeating: "a", count: 64)
        let declaration = AutomationUIRequestFixture(resetControl: .init(.label, "New conversation"), sessionIdentity: .init(.label, "Session ID"),
            emptyState: .init(.label, "No messages"), expectedEmptyState: "No messages", submitControl: .init(.label, "Send"), requestInputControl: .init(.label, "Prompt"))
        let plan = try declaration.applying(to: original, approval: approval)
        approval.effects.insert(.reset); approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        return (plan, approval)
    }
    private func receipt(plan: AutomationCase, runID: String, attemptID: String, identity: String, empty: String = "No messages") -> AutomationSegmentReceipt {
        .init(scope: .init(runID: runID, attemptID: attemptID, segmentID: AutomationUIRequestFixture.segmentID, leaseGeneration: 1),
            app: plan.app, target: plan.target, segmentID: AutomationUIRequestFixture.segmentID, route: .ui, dispatched: true, completed: true,
            artifact: "retained-ui-capture", verifiedOutputs: [AutomationUIRequestFixture.identityID: .text(identity), AutomationUIRequestFixture.emptyID: .text(empty), AutomationUIRequestFixture.inputID: .text("")],
            environmentID: plan.environmentID)
    }
    func testRequestFixtureRequiresFrozenFillAndSubmitAndRejectsContractChanges() throws {
        let (plan, approval) = try fixture()
        try PlanValidator.validate(plan, approval: approval, capabilities: .init())
        XCTAssertEqual(plan.execution.uiProgram?.operations[0].goal?.minimumBindingUses, ["approvedText": 1])
        XCTAssertEqual(plan.execution.uiProgram?.operations[0].goal?.saveControl, .init(.label, "Send"))
        XCTAssertEqual(plan.setup[0].effects, [.observe, .navigate, .fixtureWrite, .reset])
        let baseline = try AutomationFrozenCase(plan: plan)
        let alternate = try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .uiRequestBinding("approvedText"),
            request: "List completed tasks", semanticJustification: "Same reviewed local query")
        XCTAssertEqual(try AutomationUIRequestFixture.contract(plan), try AutomationUIRequestFixture.contract(alternate.frozen.plan))
        for change in 0..<4 {
            var changed = plan
            switch change {
            case 0: changed.execution.uiProgram!.operations[0].goal!.minimumBindingUses = nil
            case 1: changed.execution.uiProgram!.operations[0].goal!.saveControl = nil
            case 2: changed.setup[0].uiProgram!.operations.removeLast()
            default: changed.execution.effects.insert(.externalWrite)
            }
            XCTAssertThrowsError(try changed.uiRequestFixture!.validate(plan: changed))
        }
    }
    func testPreDispatchTrackerRejectsReusedMissingWrongEmptyAndForeignSession() async throws {
        let (plan, approval) = try fixture(), tracker = try AutomationUIRequestFixtureTracker(plan: plan, approval: approval)
        try await tracker.reserveBeforeSubject(receipts: [receipt(plan: plan, runID: approval.runID, attemptID: "one", identity: "session-1")], plan: plan, approval: approval, attemptID: "one")
        for change in 0..<6 {
            var candidate = receipt(plan: plan, runID: approval.runID, attemptID: "two", identity: "session-2")
            switch change {
            case 0: candidate.verifiedOutputs?[AutomationUIRequestFixture.identityID] = .text("session-1")
            case 1: candidate.verifiedOutputs?.removeValue(forKey: AutomationUIRequestFixture.identityID)
            case 2: candidate.verifiedOutputs?[AutomationUIRequestFixture.emptyID] = .text("Existing messages")
            case 3: candidate.environmentID = "foreign"
            case 4: candidate.artifact = nil
            default: candidate.verifiedOutputs?[AutomationUIRequestFixture.inputID] = .text("Stale request")
            }
            do {
                try await tracker.reserveBeforeSubject(receipts: [candidate], plan: plan, approval: approval, attemptID: "two")
                XCTFail("Invalid or reused session reached subject admission")
            } catch {}
        }
        try await tracker.reserveBeforeSubject(receipts: [receipt(plan: plan, runID: approval.runID, attemptID: "two", identity: "session-2")], plan: plan, approval: approval, attemptID: "two")
    }
    func testSavedSessionProposalDoesNotRestoreLiveAdmission() async throws {
        let (plan, run) = try fixture(), baseline = try AutomationFrozenCase(plan: plan)
        let mutation = try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .uiRequestBinding("approvedText"),
            request: "List completed tasks", semanticJustification: "Reviewed equivalent query")
        let restored = try JSONDecoder().decode(AutomationMutationCase.self, from: JSONEncoder().encode(mutation))
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await AutomationFailureSearch(cases: .init(root: root)).run(baseline: baseline, mutations: [restored],
                approval: .init(run: run, approvedDigests: [baseline.digest, restored.frozen.digest]), capabilities: .init(), executor: NoUIFixtureAuthorityExecutor())
            XCTFail("Decoded fixture proposal restored live authority")
        } catch {}
    }
}
private struct NoUIFixtureAuthorityExecutor: AutomationCampaignAttemptExecutor {
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) throws -> AutomationAttemptReport {
        XCTFail("Unqualified UI fixture entered executor"); throw AutomationContractError.invalidIdentity
    }
}
