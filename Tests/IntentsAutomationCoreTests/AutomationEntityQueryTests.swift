#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

final class AutomationEntityQueryTests: XCTestCase, @unchecked Sendable {
    private func fixture(root: URL) throws -> (AutomationPreparedApplication, ApplicationSurfaceCatalog.Entity, RunApproval) {
        var prepared = try AutomationPreparedCodecRegressionTests.makeFixture(root: root.appendingPathComponent("prepared")).prepared
        let app = prepared.host.app, target = prepared.host.target
        let entity = ApplicationSurfaceCatalog.Entity(typeID: "TaskEntity", title: "Task", queryIdentifier: "Subject.TaskQuery", properties: ["title": "text", "completed": "bool"], propertyTitles: [:])
        prepared.catalog.entities = [entity]
        return (prepared, entity, .init(runID: "query-run", app: app, target: target, environmentID: "disposable", effects: [.observe], maximumActions: 10, disposable: true))
    }
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("entity-query-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testFinalizedPlanAcceptsItsExactApprovalAndRejectsForeignDigest() throws {
        let (prepared, entity, original) = try fixture(root: try root())
        let plan = try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: "Invoice", approval: original)
        var exact = original; exact.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertEqual(try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: "Invoice", approval: exact), plan)
        exact.approvedCaseDigest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: "Invoice", approval: exact))
    }
    func testRealPreparationFailureRecoveryRetainsUnresolvedReportWithoutChoicesAndCannotReuseAttempt() async throws {
        let root = try root(), (prepared, entity, approval) = try fixture(root: root)
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: URL(fileURLWithPath: "/private/tmp"), simulatorInventory: { _, _, _, _ in throw AutomationContractError.terminationUnverified })
        let result = try await AutomationEntityQuery.execute(runner: runner, prepared: prepared, entity: entity, text: "Invoice", approval: approval, attemptID: "query-attempt", allowBootAndInstall: true)
        XCTAssertEqual(result.report.attemptID, "query-attempt"); XCTAssertEqual(result.report.result.summary, .unresolved)
        XCTAssertFalse(result.report.resourcesReleased); XCTAssertTrue(result.choices.isEmpty)
        XCTAssertFalse(result.report.result.subjectDispatched)
        var foreignRun = approval; foreignRun.runID = "other-run"
        for (text, current) in [("Other query", approval), ("Invoice", foreignRun), ("Invoice", approval)] {
            do {
                _ = try await AutomationEntityQuery.execute(runner: runner, prepared: prepared, entity: entity, text: text, approval: current, attemptID: "query-attempt", allowBootAndInstall: true)
                XCTFail("A previous empty-receipt report was reused")
            } catch { XCTAssertEqual(error as? AutomationContractError, .ambiguousDispatch) }
        }
    }
    func testRecoveryDoesNotReadSymlinksOrCreateMissingAttempts() async throws {
        let root = try root(), outside = try self.root(), (prepared, entity, approval) = try fixture(root: root)
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: URL(fileURLWithPath: "/private/tmp"))
        let plan = try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: "Invoice", approval: approval)
        try Data("untrusted historical report".utf8).write(to: outside.appendingPathComponent("report.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let absent = try await runner.retainedAttempt(attemptID: "missing", plan: plan, runID: approval.runID)
        let linked = try await runner.retainedAttempt(attemptID: "linked", plan: plan, runID: approval.runID)
        XCTAssertNil(absent); XCTAssertNil(linked)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["report.json"])
    }
    func testSuggestedQueryFreezesItsExplicitModeAndRejectsStringMatching() throws {
        var (prepared, entity, approval) = try fixture(root: root())
        entity.properties = [:]; entity.queryMode = .suggested
        prepared.catalog.entities = [entity]
        let plan = try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: "", approval: approval)
        XCTAssertEqual(plan.execution.hostProgram?.operations.first?.querySuggested, true)
        XCTAssertNil(plan.execution.hostProgram?.operations.first?.queryText)
        XCTAssertThrowsError(try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: "invented search", approval: approval))
        var foreign = entity; foreign.queryMode = nil
        XCTAssertThrowsError(try AutomationEntityQuery.plan(prepared: prepared, entity: foreign, text: "Search", approval: approval))
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertEqual(try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: "", approval: approval), plan)
    }
}
#endif
