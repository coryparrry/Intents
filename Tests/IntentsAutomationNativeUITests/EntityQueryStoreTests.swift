#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

/// Store contract fixtures only; no generated host, device or live query qualification.
@MainActor final class EntityQueryStoreTests: XCTestCase {
    private func fixture(evidenceImporter: (@Sendable (AutomationCase, AutomationAttemptReport, URL, AutomationEvidenceExposure) async throws -> AutomationNativeEvidenceDocument)? = nil, executor: @escaping AutomationNativeEntityQueryExecutor) throws -> (AppAutomationStore, AutomationPreparedApplication, ApplicationSurfaceCatalog.SystemAction.Parameter) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("entity-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = AppAutomationStore(supportDirectory: root, savedCasesReader: { [] }, entityQueryExecutor: executor, evidenceImporter: evidenceImporter)
        let sourceID = root.appendingPathComponent("Source.xcodeproj").path + "#SOURCE"
        var app = AppIdentity(logicalID: sourceID, bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        app.configuration = "Debug"
        let target = TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let parameter = ApplicationSurfaceCatalog.SystemAction.Parameter(name: "task", family: "entity", optional: false, typeID: "TaskEntity")
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [.init(id: "CompleteTask", typeName: "Subject.CompleteTask", title: "Complete task", parameters: [parameter], parametersComplete: true, compiled: true, registered: false, executed: false)], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [], entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "Subject.TaskQuery", properties: ["title": "text", "owner": "text", "completed": "bool"], propertyTitles: [:])])
        let prepared = AutomationPreparedApplication(source: .init(sourceRoot: root.path, files: [], directories: [], excludedPaths: []), generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "HOST", bundleID: "unused", configuration: "Debug", templateDigest: String(repeating: "c", count: 64)), host: .init(app: app, target: target, xctestrunPath: "unused", xctestrunDigest: String(repeating: "d", count: 64), subjectProductPath: "unused", hostBundlePath: "unused", hostProductDigest: String(repeating: "e", count: 64), hostBundleID: "unused", testTarget: "unused"), catalog: catalog, buildLogPath: "unused", buildLogTruncated: false)
        model.intake = .init(candidates: [.init(id: sourceID, name: "Source", kind: .sourceTarget, containerPath: root.path, targetID: "SOURCE", bundleID: app.bundleID, platform: "ios", architectures: ["arm64"], configurations: ["Debug"], app: nil)], gaps: [], requiresBuildApproval: true)
        model.candidateID = sourceID; model.configuration = "Debug"; model.simulatorID = target.id
        model.prepared = prepared; model.catalog = catalog; model.actionID = "CompleteTask"; model.workflowRoute = "system"
        model.entityQueryTexts["task"] = "Send invoice"; model.effectChoice = "fixture"; model.effectsConfirmed = true; model.disposable = true
        return (model, prepared, parameter)
    }
    func testSuccessfulAndStaleUnresolvedQueryReportsBothReachNativeEvidenceImporter() async throws {
        let imported = QueryEvidenceImports()
        let (model, _, parameter) = try fixture(evidenceImporter: { plan, report, _, _ in try await imported.record(plan, report) }) {
            prepared, entity, _, approval, attemptID, _, _ in try Self.result(prepared: prepared, entity: entity, approval: approval, attemptID: attemptID)
        }
        await model.findEntities(parameter)
        let first = await imported.reports
        XCTAssertEqual(first.count, 1); XCTAssertEqual(first[0].report, model.entityQueryReport)
        XCTAssertEqual(first[0].frozen.plan.execution.kind, .systemQuery)
        XCTAssertEqual(model.evidenceImportRevision, 1)
        let gate = EntityQueryGate(), staleImports = QueryEvidenceImports()
        let (stale, _, staleParameter) = try fixture(evidenceImporter: { plan, report, _, _ in try await staleImports.record(plan, report) }) {
            prepared, entity, _, approval, attemptID, _, _ in
            await gate.hold()
            return try Self.result(prepared: prepared, entity: entity, approval: approval, attemptID: attemptID, released: false)
        }
        let task = Task { await stale.findEntities(staleParameter) }
        await gate.waitUntilEntered(); stale.entityQueryTexts["task"] = "Changed"; stale.entityQueryChanged("task")
        await gate.release(); await task.value
        let saved = await staleImports.reports
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved[0].report, stale.entityQueryReport)
        XCTAssertFalse(saved[0].report.resourcesReleased); XCTAssertNil(stale.entityChoices["task"])
        XCTAssertFalse(stale.canRun)
    }
    func testTypedInputsUseDeclaredDefaultsAndBindValidChangesToConfirmationDigest() throws {
        let (model, original, _) = try fixture { _, _, _, _, _, _, _ in throw QueryFixtureError.failed }
        var prepared = original
        var number = ApplicationSurfaceCatalog.SystemAction.Parameter(name: "count", family: "integer", optional: false)
        number.defaultValue = .integer("42")
        var flag = ApplicationSurfaceCatalog.SystemAction.Parameter(name: "flag", family: "bool", optional: false)
        flag.defaultValue = .bool(false)
        var mode = ApplicationSurfaceCatalog.SystemAction.Parameter(name: "mode", family: "enum", optional: false, typeID: "Mode")
        mode.defaultValue = .enumeration(typeID: "Mode", value: "careful")
        prepared.catalog.systemActions[0].parameters = [number, flag, mode]
        prepared.catalog.enumerations = [.init(typeID: "Mode", title: "Mode", cases: [.init(id: "careful", title: "Careful"), .init(id: "fast", title: "Fast")])]
        model.prepared = prepared; model.catalog = prepared.catalog
        XCTAssertTrue(model.canRun)
        let initial = try model.previewCommand()
        model.inputs["count"] = "9007199254740993"
        XCTAssertTrue(model.canRun); XCTAssertNotEqual(try model.previewCommand().digest, initial.digest)
        model.inputs["count"] = "9223372036854775808"
        XCTAssertFalse(model.canRun); XCTAssertThrowsError(try model.previewCommand())
        model.inputs["count"] = nil; model.inputs["mode"] = "invented"
        XCTAssertFalse(model.canRun); XCTAssertThrowsError(try model.previewCommand())
        model.inputs["mode"] = nil; model.inputs["flag"] = "true"
        XCTAssertTrue(model.canRun); XCTAssertNotEqual(try model.previewCommand().digest, initial.digest)
        model.inputs["flag"] = nil
        XCTAssertEqual(try model.previewCommand().digest, initial.digest)
        let requestID = UUID()
        _ = try model.requestCommand(id: requestID, digest: initial.digest)
        model.inputs["count"] = "9007199254740993"
        model.run()
        XCTAssertEqual(try model.commandStatus(id: requestID).state, "invalidated")
        XCTAssertFalse(model.busy); XCTAssertNil(model.report)
    }
    func testDateInputRequiresExplicitTimeZoneAndChangesNativeConfirmation() throws {
        let (model, original, _) = try fixture { _, _, _, _, _, _, _ in throw QueryFixtureError.failed }
        var prepared = original
        prepared.catalog.systemActions[0].parameters = [.init(name: "date", family: "date", optional: false)]
        model.prepared = prepared; model.catalog = prepared.catalog
        XCTAssertFalse(model.canRun)
        let date = AutomationDateInput(value: "2026-10-06T12:30:00Z", timeZone: "Europe/London")
        model.inputs["date"] = try date.encoded()
        XCTAssertTrue(model.canRun)
        let preview = try model.previewCommand()
        model.inputs["date"] = try AutomationDateInput(value: date.value, timeZone: "UTC").encoded()
        XCTAssertTrue(model.canRun); XCTAssertNotEqual(try model.previewCommand().digest, preview.digest)
        model.inputs["date"] = #"{"value":"2026-10-06T12:30:00Z"}"#
        XCTAssertFalse(model.canRun); XCTAssertThrowsError(try model.previewCommand())
    }
    nonisolated private static func result(prepared: AutomationPreparedApplication, entity: ApplicationSurfaceCatalog.Entity, approval: RunApproval, attemptID: String, released: Bool = true) throws -> AutomationEntityQueryResult {
        let plan = try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: "Send invoice", approval: approval)
        let report = AutomationAttemptReport(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: false, subjectCompleted: false, observations: [], termination: released ? .infrastructureFailed : .unresolved), receipts: [], resourcesReleased: released)
        let choice = AutomationQueryEntityChoice(id: "personal", typeID: entity.typeID, properties: ["title": .text("Send invoice"), "owner": .text("Personal"), "completed": .bool(false)], sourceAttemptID: attemptID, app: prepared.host.app, target: prepared.host.target, environmentID: approval.environmentID, catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog))
        return .init(report: report, choices: released ? [choice] : [], selectionGap: nil)
    }
    func testActualScopedChoicesAreRequiredAndQueryChangeInvalidatesThem() async throws {
        let (model, _, parameter) = try fixture { prepared, entity, _, approval, attemptID, _, _ in try Self.result(prepared: prepared, entity: entity, approval: approval, attemptID: attemptID) }
        XCTAssertFalse(model.canRun); XCTAssertTrue(model.canFindEntities(parameter))
        await model.findEntities(parameter)
        XCTAssertEqual(model.entityChoices["task"]?.count, 1)
        model.selectedEntityIDs["task"] = "invented"; XCTAssertFalse(model.canRun)
        model.selectedEntityIDs["task"] = "personal"; XCTAssertTrue(model.canRun)
        model.entityQueryTexts["task"] = "Different"; model.entityQueryChanged("task")
        XCTAssertNil(model.selectedEntity("task")); XCTAssertFalse(model.canRun)
    }
    func testUnreleasedNormalAttemptBlocksQueryBeforeExecutor() async throws {
        let counter = QueryInvocationCounter()
        let (model, prepared, parameter) = try fixture { _, _, _, _, _, _, _ in await counter.record(); throw QueryFixtureError.failed }
        let approval = RunApproval(runID: "previous", app: prepared.host.app, target: prepared.host.target, environmentID: "selected-simulator:" + prepared.host.target.id, effects: [.observe], maximumActions: 20, disposable: true)
        model.report = try Self.result(prepared: prepared, entity: prepared.catalog.entities![0], approval: approval, attemptID: "previous", released: false).report
        XCTAssertFalse(model.canFindEntities(parameter)); await model.findEntities(parameter)
        let calls = await counter.calls; XCTAssertEqual(calls, 0)
        model.workflowSelectionChanged(); model.selectAction()
        XCTAssertNil(model.report); XCTAssertNotNil(model.retainedUnresolvedNormalReport)
        XCTAssertFalse(model.canFindEntities(parameter)); XCTAssertFalse(model.canRun)
        XCTAssertFalse(model.canSelectApplicationFromCommand)
    }
    func testThrownPreparationFailureRetainsExactAttemptAndBlocksNewWork() async throws {
        let counter = QueryInvocationCounter()
        let (model, _, parameter) = try fixture { _, _, _, _, attemptID, _, _ in await counter.record(attemptID); throw QueryFixtureError.failed }
        await model.findEntities(parameter)
        let id = await counter.attemptID
        XCTAssertEqual(model.unresolvedEntityQueryAttemptID, id); XCTAssertNotNil(id)
        XCTAssertTrue(model.message?.contains(id!) == true)
        model.entityQueryTexts["task"] = "Changed"; model.entityQueryChanged("task")
        XCTAssertFalse(model.canFindEntities(parameter)); XCTAssertFalse(model.canRun)
        await model.findEntities(parameter); let calls = await counter.calls; XCTAssertEqual(calls, 1)
    }
    func testInvalidTextDoesNotAcquireOwnershipAndValidEditCanQuery() async throws {
        let counter = QueryInvocationCounter()
        let (model, _, parameter) = try fixture { prepared, entity, _, approval, attemptID, _, _ in
            await counter.record(attemptID)
            return try Self.result(prepared: prepared, entity: entity, approval: approval, attemptID: attemptID)
        }
        for text in [String(repeating: "x", count: 32769), String(repeating: "😀", count: 16385), " \n\t"] {
            model.entityQueryTexts["task"] = text; model.entityQueryChanged("task")
            XCTAssertFalse(model.canFindEntities(parameter))
            await model.findEntities(parameter)
            XCTAssertNil(model.unresolvedEntityQueryAttemptID); XCTAssertNil(model.entityQueryReport)
            XCTAssertFalse(model.busy); XCTAssertTrue(model.canSelectApplicationFromCommand)
        }
        let invalidCalls = await counter.calls; XCTAssertEqual(invalidCalls, 0)
        model.entityQueryTexts["task"] = "Send invoice"; model.entityQueryChanged("task")
        XCTAssertTrue(model.canFindEntities(parameter)); await model.findEntities(parameter)
        let validCalls = await counter.calls; XCTAssertEqual(validCalls, 1)
        XCTAssertNil(model.unresolvedEntityQueryAttemptID); XCTAssertNotNil(model.entityChoices["task"])
        model.selectedEntityIDs["task"] = "personal"; XCTAssertTrue(model.canRun)
    }
    func testLocalPlanFailureDoesNotBecomeUnresolvedExecution() async throws {
        let counter = QueryInvocationCounter()
        let (model, prepared, parameter) = try fixture { prepared, entity, _, approval, attemptID, _, _ in
            await counter.record(attemptID)
            return try Self.result(prepared: prepared, entity: entity, approval: approval, attemptID: attemptID)
        }
        model.catalog?.entities?[0].title = "Stale entity declaration"
        XCTAssertTrue(model.canFindEntities(parameter)); await model.findEntities(parameter)
        let invalidCalls = await counter.calls; XCTAssertEqual(invalidCalls, 0)
        XCTAssertNil(model.unresolvedEntityQueryAttemptID); XCTAssertNil(model.entityQueryReport)
        XCTAssertNotNil(model.message); XCTAssertFalse(model.busy); XCTAssertTrue(model.canSelectApplicationFromCommand)
        model.catalog = prepared.catalog
        XCTAssertTrue(model.canFindEntities(parameter)); await model.findEntities(parameter)
        let validCalls = await counter.calls; XCTAssertEqual(validCalls, 1)
        XCTAssertNil(model.unresolvedEntityQueryAttemptID); XCTAssertNotNil(model.entityChoices["task"])
    }
    func testHeldSelectionChangeCannotPublishChoicesAndRetainsUnreleasedQuery() async throws {
        let gate = EntityQueryGate()
        let (model, _, parameter) = try fixture { prepared, entity, _, approval, attemptID, _, _ in
            await gate.hold()
            return try Self.result(prepared: prepared, entity: entity, approval: approval, attemptID: attemptID, released: false)
        }
        let task = Task { await model.findEntities(parameter) }
        await gate.waitUntilEntered(); XCTAssertTrue(model.busy)
        model.entityQueryTexts["task"] = "Changed"; model.entityQueryChanged("task")
        await gate.release(); await task.value
        XCTAssertEqual(model.entityQueryReport?.resourcesReleased, false)
        XCTAssertNil(model.entityChoices["task"]); XCTAssertNil(model.unresolvedEntityQueryAttemptID)
        XCTAssertFalse(model.canFindEntities(parameter)); XCTAssertFalse(model.canRun)
    }
    func testCloseDrainsHeldQueryAndPreservesUnresolvedAttempt() async throws {
        let gate = EntityQueryGate()
        let (model, _, parameter) = try fixture { prepared, entity, _, approval, attemptID, _, _ in
            await gate.hold()
            return try Self.result(prepared: prepared, entity: entity, approval: approval, attemptID: attemptID, released: false)
        }
        let task = Task { await model.findEntities(parameter) }
        await gate.waitUntilEntered(); model.close(); XCTAssertTrue(model.busy)
        await gate.release(); await task.value
        XCTAssertFalse(model.busy); XCTAssertEqual(model.entityQueryReport?.resourcesReleased, false)
        XCTAssertNil(model.entityChoices["task"]); XCTAssertFalse(model.canFindEntities(parameter))
    }
}
private actor QueryEvidenceImports {
    var reports: [AutomationNativeEvidenceDocument] = []
    func record(_ plan: AutomationCase, _ report: AutomationAttemptReport) throws -> AutomationNativeEvidenceDocument {
        let document = try AutomationNativeEvidenceDocument(frozen: AutomationFrozenCase(plan: plan), report: report, artifacts: [])
        reports.append(document); return document
    }
}
private enum QueryFixtureError: Error { case failed }
private actor QueryInvocationCounter {
    var calls = 0
    var attemptID: String?
    func record(_ id: String? = nil) { calls += 1; attemptID = id }
}
private actor EntityQueryGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; waiting?.resume(); waiting = nil; await withCheckedContinuation { pending = $0 } }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { waiting = $0 } } }
    func release() { pending?.resume(); pending = nil }
}
#endif
