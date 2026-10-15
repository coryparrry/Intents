import XCTest
@testable import IntentsAutomationCore

final class AutomationLegacyUIRequestArchiveTests: XCTestCase, @unchecked Sendable {
    func testSelectorlessSchemaThreeReopensUnchangedAndCannotRestoreQualification() async throws {
        let (root, record, run) = try await fixture(ordered: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try AutomationUIFailureSearchArchive(caseStoreRoot: root)
        try await archive.save(record)
        let path = root.appendingPathComponent("Searches/" + record.id + ".json")
        let originalBytes = try Data(contentsOf: path)
        XCTAssertFalse(String(decoding: originalBytes, as: UTF8.self).contains("requestInputControl"))
        let reopened = try AutomationUIFailureSearchArchive(caseStoreRoot: root)
        let loaded = try await reopened.load(id: record.id)
        XCTAssertEqual(loaded.schemaVersion, 3); XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded.baseline.digest, record.baseline.digest); XCTAssertEqual(loaded.report, record.report)
        XCTAssertEqual(loaded.verificationScope, "historicalFactsWithUnqualifiedRequestExecution")
        XCTAssertNotNil(loaded.historicalQualificationNotice)
        XCTAssertEqual(try Data(contentsOf: path), originalBytes)
        XCTAssertThrowsError(try loaded.baseline.plan.uiRequestFixture!.validate(plan: loaded.baseline.plan))
        XCTAssertThrowsError(try AutomationUIRequestFixtureTracker(plan: loaded.baseline.plan, approval: run))
        do {
            _ = try await AutomationFailureSearch(cases: .init(root: root)).run(baseline: loaded.baseline, mutations: loaded.mutations,
                approval: .init(run: run, approvedDigests: Set(([loaded.baseline] + loaded.mutations.map(\.frozen)).map(\.digest))),
                capabilities: .init(), executor: LegacyArchiveAdmissionExecutor())
            XCTFail("Historical unqualified request execution acquired live authority")
        } catch {}
    }
    func testOrderedSchemaFiveRoundTripsWithoutChangingFrozenDefinitionsOrFacts() async throws {
        let (root, record, _) = try await fixture(ordered: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try AutomationUIFailureSearchArchive(caseStoreRoot: root)
        try await archive.save(record)
        let loaded = try await archive.load(id: record.id)
        XCTAssertEqual(loaded.schemaVersion, 5); XCTAssertEqual(loaded, record)
        XCTAssertNil(loaded.historicalQualificationNotice)
        XCTAssertEqual(loaded.baseline.plan.execution.uiProgram?.operations.first?.goal?.requestInputControl, .init(.label, "Prompt"))
        XCTAssertEqual(loaded.report.qualificationAttempts?.count, 2)
    }
    private func fixture(ordered: Bool) async throws -> (URL, AutomationUIFailureSearchRecord, RunApproval) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("request-history-" + UUID().uuidString)
        let app = AppIdentity(logicalID: "local-ai", bundleID: "example.LocalAI", platform: "ios")
        let target = TargetIdentity(id: "history-simulator", kind: .simulator)
        var run = RunApproval(runID: "history-run", app: app, target: target, environmentID: "disposable", effects: [.observe, .navigate, .fixtureWrite], maximumActions: 30, disposable: true)
        var plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Submit the frozen request", endpoint: "Response",
            approvedText: "Show completed tasks", expectedVisibleText: "Complete", approval: run, localeIdentifier: "en_GB")
        plan.provenance["ui.runtimeManifestDigest"] = String(repeating: "a", count: 64)
        let declaration = AutomationUIRequestFixture(resetControl: .init(.label, "New conversation"), sessionIdentity: .init(.label, "Session ID"),
            emptyState: .init(.label, "No messages"), expectedEmptyState: "No messages", submitControl: .init(.label, "Send"),
            requestInputControl: ordered ? .init(.label, "Prompt") : nil)
        if ordered { plan = try declaration.applying(to: plan, approval: run) }
        else {
            // Concrete bytes in the old format: three setup operations, no input
            // selector, no empty-input readback and no ordered completion proof.
            plan.uiRequestFixture = declaration
            var reset = AutomationSegment(id: AutomationUIRequestFixture.segmentID, kind: .ui, phase: .setup,
                operation: "Create and independently verify a fresh empty local AI session", effects: [.observe, .navigate, .fixtureWrite, .reset], lifecycle: .persistedStateAcrossSegments)
            reset.uiProgram = .init(operations: [.init(id: "new-session", kind: .tap, locator: declaration.resetControl),
                .init(id: AutomationUIRequestFixture.identityID, kind: .observeProperty, locator: declaration.sessionIdentity, property: "value"),
                .init(id: AutomationUIRequestFixture.emptyID, kind: .observeProperty, locator: declaration.emptyState, property: "text")])
            plan.setup = [reset]
            plan.execution.uiProgram!.operations[0].goal!.minimumBindingUses = ["approvedText": 1]
            plan.execution.uiProgram!.operations[0].goal!.saveControl = declaration.submitControl
        }
        plan.id = ordered ? "ordered.baseline" : "legacy.baseline"
        let baseline = try AutomationFrozenCase(plan: plan)
        var variant = plan; variant.id = ordered ? "ordered.phrase" : "legacy.phrase"
        variant.execution.uiProgram!.bindings["approvedText"] = "List completed tasks"
        let mutation = AutomationMutationCase(frozen: try .init(plan: variant), recipeIDs: [], kinds: [.alternatePhrasing], requiredCapabilities: [],
            semanticJustification: "Historical equivalent task filter", subjectPhraseSlot: .uiRequestBinding("approvedText"))
        run.effects.insert(.reset); run.approvedCaseDigest = baseline.digest
        let cases = try AutomationCaseStore(root: root)
        for frozen in [baseline, mutation.frozen] { _ = try await cases.freeze(frozen.plan) }
        var report = AutomationFailureSearchReport(baselineDigest: baseline.digest)
        report.qualificationAttempts = []
        for id in ["qualification-one", "qualification-two"] {
            let retained = facts(plan: plan, runID: run.runID, id: id)
            try await cases.saveAttempt(retained, for: baseline)
            report.qualificationAttempts!.append(.init(caseDigest: baseline.digest, report: retained))
        }
        for index in 0..<4 {
            let frozen = index == 3 ? mutation.frozen : baseline, id = "trial-" + String(index)
            let retained = facts(plan: frozen.plan, runID: run.runID, id: id)
            try await cases.saveAttempt(retained, for: frozen)
            report.attempts.append(.init(stage: index == 3 ? .discovery : .baseline, caseDigest: frozen.digest, report: retained))
            report.counters.record(retained.result)
        }
        report.usage.attempts = 6; report.usage.reservedSubjectOperations = 6 * (ordered ? 28 : 27)
        report.usage.reservedSetupOperations = 6 * (ordered ? 5 : 4); report.usage.reservedObserverOperations = 12
        report.usage.reservedUIActions = 36; report.usage.controllerCalls = 18; report.stopReason = "Approved search population completed"
        return (root, .init(id: ordered ? "ordered-search" : "legacy-search", runID: run.runID, baseline: baseline, mutations: [mutation], report: report), run)
    }
    private func facts(plan: AutomationCase, runID: String, id: String) -> AutomationAttemptReport {
        let observer = plan.observations[0]
        let fact = AutomationObservation(id: observer.id, app: plan.app, target: plan.target, environmentID: plan.environmentID,
            attemptID: id, stepID: observer.id, route: observer.kind, proof: .visibleState, value: plan.requirements[0].expected)
        let receipts = (plan.setup + [plan.execution] + plan.observations).enumerated().map { index, segment in
            var outputs: [String: AutomationValue]? = nil
            if segment.phase == .setup {
                outputs = [AutomationUIRequestFixture.identityID: .text("session-" + id), AutomationUIRequestFixture.emptyID: .text("No messages")]
                if plan.uiRequestFixture?.requestInputControl != nil { outputs![AutomationUIRequestFixture.inputID] = .text("") }
            }
            return AutomationSegmentReceipt(scope: .init(runID: runID, attemptID: id, segmentID: segment.id, leaseGeneration: index + 1),
                app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind, dispatched: true, completed: true,
                observations: segment.phase == .observe ? [fact] : [], artifact: "historical-capture-" + id, verifiedOutputs: outputs, environmentID: plan.environmentID)
        }
        return .init(attemptID: id, result: AutomationAssessment.assess(plan: plan, attemptID: id, subjectDispatched: true,
            subjectCompleted: true, observations: [fact], receipts: receipts, runID: runID), receipts: receipts, resourcesReleased: true)
    }
}
private struct LegacyArchiveAdmissionExecutor: AutomationCampaignAttemptExecutor {
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) throws -> AutomationAttemptReport {
        XCTFail("Historical request facts dispatched a live subject"); throw AutomationContractError.invalidIdentity
    }
}
