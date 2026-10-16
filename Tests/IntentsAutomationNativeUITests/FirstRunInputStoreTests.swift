#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

/// Store and injected-runner contracts; these fixtures do not qualify live app queries.
@MainActor final class FirstRunInputStoreTests: XCTestCase {
    private func fixture(mac: Bool = false,
                         recoverySimulatorShutdown: @escaping @Sendable (TargetIdentity, URL, URL) async throws -> Void = { _, _, _ in },
                         executor: @escaping AutomationNativeEntityQueryExecutor) throws
        -> (AppAutomationStore, AutomationPreparedApplication, ApplicationSurfaceCatalog.SystemAction.Parameter) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("first-run-inputs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let target = mac ? TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-login")
            : TargetIdentity(id: UUID().uuidString, kind: .simulator)
        let model = AppAutomationStore(supportDirectory: root, savedCasesReader: { [] },
            entityQueryExecutor: executor, nativeMacTargetReader: { target },
            recoverySimulatorShutdown: recoverySimulatorShutdown)
        let sourceID = root.appendingPathComponent("Source.xcodeproj").path + "#SOURCE"
        var app = AppIdentity(logicalID: sourceID, bundleID: "example.Subject", platform: mac ? "macos" : "ios", productDigest: String(repeating: "a", count: 64))
        app.configuration = "Debug"
        let source = AutomationSourceManifest(sourceRoot: root.path, files: [], directories: [], excludedPaths: [])
        let subject = root.appendingPathComponent("Subject.app")
        try FileManager.default.createDirectory(at: subject, withIntermediateDirectories: true)
        app.canonicalBundlePath = subject.path
        app.sourceManifestDigest = try source.digest
        let parameter = ApplicationSurfaceCatalog.SystemAction.Parameter(name: "task", family: "entity", optional: false, typeID: "TaskEntity")
        let catalog = ApplicationSurfaceCatalog(app: app,
            systemActions: [.init(id: "CompleteTask", typeName: "Subject.CompleteTask", title: "Complete task", parameters: [parameter], parametersComplete: true, compiled: true, registered: false, executed: false)],
            systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [],
            entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "Subject.TaskQuery", properties: ["title": "text"], propertyTitles: [:])])
        let prepared = AutomationPreparedApplication(source: source,
            generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "HOST", bundleID: "unused", configuration: "Debug", templateDigest: String(repeating: "c", count: 64)),
            host: .init(app: app, target: target, xctestrunPath: "unused", xctestrunDigest: String(repeating: "d", count: 64), subjectProductPath: subject.path, hostBundlePath: "unused", hostProductDigest: String(repeating: "e", count: 64), hostBundleID: "unused", testTarget: "unused"),
            catalog: catalog, buildLogPath: "unused", buildLogTruncated: false)
        model.intake = .init(candidates: [.init(id: sourceID, name: "Source", kind: .sourceTarget, containerPath: root.path, targetID: "SOURCE", bundleID: app.bundleID,
            platform: app.platform, architectures: ["arm64"], configurations: ["Debug"], app: nil)], gaps: [], requiresBuildApproval: true)
        model.candidateID = sourceID; model.configuration = "Debug"; model.simulatorID = target.id
        model.preparationDestination = mac ? .macOS : .simulator
        model.selectedMacTarget = mac ? target : nil
        model.prepared = prepared; model.catalog = catalog; model.firstRunIncludesActions = true
        model.setFirstRunEntityQueryText("Send invoice", actionID: "CompleteTask", parameter: "task")
        return (model, prepared, parameter)
    }

    nonisolated private static func result(_ prepared: AutomationPreparedApplication, entity: ApplicationSurfaceCatalog.Entity,
        approval: RunApproval, attemptID: String, ids: [String] = ["personal"], released: Bool = true) throws -> AutomationEntityQueryResult {
        let plan = try AutomationEntityQuery.plan(prepared: prepared, entity: entity, text: entity.usesSuggestedQuery ? "" : "Send invoice", approval: approval)
        let report = AutomationAttemptReport(attemptID: attemptID,
            result: AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: false, subjectCompleted: false,
                observations: [], termination: released ? .infrastructureFailed : .unresolved), receipts: [], resourcesReleased: released)
        let choices = try ids.map {
            AutomationQueryEntityChoice(id: $0, typeID: entity.typeID, properties: entity.usesSuggestedQuery ? [:] : ["title": .text("Send invoice")],
                sourceAttemptID: attemptID, app: prepared.host.app, target: prepared.host.target,
                environmentID: approval.environmentID, catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog))
        }
        return .init(report: report, choices: choices, selectionGap: nil)
    }

    func testTypedValuesAreScopedPerActionAndInvalidValuesLeaveOnlyThatActionUnavailable() throws {
        let (model, _, _) = try fixture { _, _, _, _, _, _, _ in throw FirstRunQueryError.failed }
        let integer = ApplicationSurfaceCatalog.SystemAction.Parameter(name: "count", family: "integer", optional: false)
        let action = ApplicationSurfaceCatalog.SystemAction(id: "Count", typeName: "Subject.Count", title: "Count", parameters: [integer], parametersComplete: true, compiled: true, registered: false, executed: false)
        model.catalog?.systemActions.append(action)
        model.setFirstRunInput("9007199254740993", actionID: "Count", parameter: "count")
        let valid = model.firstRunTypedInputs()
        XCTAssertEqual(valid.inputs["Count"]?["count"]?.value, .integer("9007199254740993"))
        XCTAssertTrue(valid.unavailableActions.isEmpty)
        model.setFirstRunInput("9223372036854775808", actionID: "Count", parameter: "count")
        let invalid = model.firstRunTypedInputs()
        XCTAssertNil(invalid.inputs["Count"]); XCTAssertNotNil(invalid.unavailableActions["Count"])
        XCTAssertNil(invalid.unavailableActions["CompleteTask"])
    }

    func testDefaultsOptionalParametersAndEnumsNeedNoManualEditors() throws {
        let (model, _, _) = try fixture { _, _, _, _, _, _, _ in throw FirstRunQueryError.failed }
        var action = model.catalog!.systemActions[0]
        action.parameters += [.init(name: "flag", family: "bool", optional: false, defaultValue: .bool(false)),
            .init(name: "note", family: "text", optional: true), .init(name: "mode", family: "enum", optional: false, typeID: "Mode")]
        XCTAssertEqual(model.firstRunInputParameters(for: action).map(\.name), ["task"])
    }

    func testLinkedReviewIncludesTypedInputAndRejectsAChangedApprovedValue() throws {
        let (model, original, _) = try fixture { _, _, _, _, _, _, _ in throw FirstRunQueryError.failed }
        var prepared = original
        prepared.catalog.systemActions = [.init(id: "Count", typeName: "Subject.Count", title: "Count",
            parameters: [.init(name: "count", family: "integer", optional: false)], parametersComplete: true,
            compiled: true, registered: false, executed: false, resultFamily: "noValue")]
        model.prepared = prepared; model.catalog = prepared.catalog
        model.effectChoice = "navigation"; model.firstRunEffectsConfirmed = true
        model.setFirstRunInput("42", actionID: "Count", parameter: "count")
        let review = try model.reviewFirstChecks()
        let request = try XCTUnwrap(review.requests.first { $0.plan.execution.hostProgram != nil })
        XCTAssertEqual(request.plan.execution.hostProgram?.operations.first?.parameters["count"], .integer("42"))
        model.setFirstRunInput("43", actionID: "Count", parameter: "count")
        XCTAssertNotEqual(try model.reviewFirstChecks().id, review.id)
        model.runFirstChecks(review)
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.message); XCTAssertTrue(model.firstRunReports.isEmpty)
        model.setFirstRunInput("invalid", actionID: "Count", parameter: "count")
        let invalid = try model.reviewFirstChecks()
        XCTAssertFalse(invalid.requests.contains { $0.plan.execution.hostProgram != nil })
        XCTAssertTrue(invalid.gaps.contains { $0.contains("Count") })
    }

    func testEditsAreRefusedDuringReviewAndRunOwnership() throws {
        let (model, _, _) = try fixture { _, _, _, _, _, _, _ in throw FirstRunQueryError.failed }
        for reviewing in [true, false] {
            model.firstRunInputReviewID = reviewing ? "review" : nil
            model.progress = reviewing ? nil : "Running"
            model.setFirstRunInput("changed", actionID: "CompleteTask", parameter: "text")
            model.setFirstRunEntityQueryText("changed", actionID: "CompleteTask", parameter: "task")
            XCTAssertNil(model.firstRunInputs["CompleteTask"])
            XCTAssertEqual(model.firstRunEntityQueryTexts["CompleteTask"]?["task"], "Send invoice")
        }
        model.progress = nil
        XCTAssertTrue(model.canEditFirstRunInputs)
    }

    func testUniqueQuerySelectsLiveChoiceAndChangedTextInvalidatesSelection() async throws {
        let (model, _, parameter) = try fixture { prepared, entity, _, approval, attemptID, _, _ in
            try Self.result(prepared, entity: entity, approval: approval, attemptID: attemptID)
        }
        await model.findFirstRunEntities(actionID: "CompleteTask", parameter: parameter)
        XCTAssertEqual(model.firstRunSelectedEntities()["CompleteTask"]?["task"]?.id, "personal")
        model.selectFirstRunEntity("invented", actionID: "CompleteTask", parameter: "task")
        XCTAssertEqual(model.firstRunSelectedEntities()["CompleteTask"]?["task"]?.id, "personal")
        model.setFirstRunEntityQueryText("Different", actionID: "CompleteTask", parameter: "task")
        XCTAssertNil(model.firstRunSelectedEntities()["CompleteTask"])
    }

    func testAmbiguousResultsRequireAnExplicitReturnedChoice() async throws {
        let (model, _, parameter) = try fixture { prepared, entity, _, approval, attemptID, _, _ in
            try Self.result(prepared, entity: entity, approval: approval, attemptID: attemptID, ids: ["personal", "work"])
        }
        await model.findFirstRunEntities(actionID: "CompleteTask", parameter: parameter)
        XCTAssertNil(model.firstRunSelectedEntities()["CompleteTask"])
        model.selectFirstRunEntity("work", actionID: "CompleteTask", parameter: "task")
        XCTAssertEqual(model.firstRunSelectedEntities()["CompleteTask"]?["task"]?.id, "work")
    }

    func testInvalidTextDoesNotInvokeOrAcquireUnresolvedOwnership() async throws {
        let calls = FirstRunQueryCalls()
        let (model, _, parameter) = try fixture { _, _, _, _, id, _, _ in await calls.record(id); throw FirstRunQueryError.failed }
        for text in [" \n\t", String(repeating: "x", count: 32769)] {
            model.setFirstRunEntityQueryText(text, actionID: "CompleteTask", parameter: "task")
            await model.findFirstRunEntities(actionID: "CompleteTask", parameter: parameter)
            XCTAssertNil(model.unresolvedEntityQueryAttemptID)
        }
        let count = await calls.count; XCTAssertEqual(count, 0)
    }

    func testCatalogAndDestinationDriftRefuseQueriesBeforeDispatch() async throws {
        let calls = FirstRunQueryCalls()
        let (model, prepared, parameter) = try fixture { _, _, _, _, id, _, _ in await calls.record(id); throw FirstRunQueryError.failed }
        model.catalog?.entities?[0].title = "Changed declaration"
        XCTAssertFalse(model.canFindFirstRunEntities(actionID: "CompleteTask", parameter: parameter))
        await model.findFirstRunEntities(actionID: "CompleteTask", parameter: parameter)
        model.catalog = prepared.catalog; model.simulatorID = UUID().uuidString
        XCTAssertFalse(model.canFindFirstRunEntities(actionID: "CompleteTask", parameter: parameter))
        await model.findFirstRunEntities(actionID: "CompleteTask", parameter: parameter)
        let count = await calls.count; XCTAssertEqual(count, 0)
        XCTAssertNil(model.unresolvedEntityQueryAttemptID)
    }

    func testSelectingApplicationClearsFirstRunInputsAndChoices() async throws {
        let (model, _, parameter) = try fixture { prepared, entity, _, approval, attemptID, _, _ in
            try Self.result(prepared, entity: entity, approval: approval, attemptID: attemptID)
        }
        await model.findFirstRunEntities(actionID: "CompleteTask", parameter: parameter)
        model.setFirstRunInput("entered", actionID: "CompleteTask", parameter: "unused")
        XCTAssertFalse(model.firstRunEntityChoices.isEmpty)
        model.selectCandidate(); await model.task?.value
        XCTAssertTrue(model.firstRunInputs.isEmpty); XCTAssertTrue(model.firstRunEntityQueryTexts.isEmpty)
        XCTAssertTrue(model.firstRunEntityChoices.isEmpty); XCTAssertTrue(model.firstRunSelectedEntityIDs.isEmpty)
    }

    func testThrownQueryRetainsAttemptAndBlocksOtherAdmission() async throws {
        let calls = FirstRunQueryCalls()
        let (model, _, parameter) = try fixture { _, _, _, _, id, _, _ in await calls.record(id); throw FirstRunQueryError.failed }
        await model.findFirstRunEntities(actionID: "CompleteTask", parameter: parameter)
        let id = await calls.attemptID
        XCTAssertNotNil(id); XCTAssertEqual(model.unresolvedEntityQueryAttemptID, id)
        XCTAssertFalse(model.canReviewFirstChecks); XCTAssertFalse(model.canFindFirstRunEntities(actionID: "CompleteTask", parameter: parameter))
        await model.findFirstRunEntities(actionID: "CompleteTask", parameter: parameter)
        let count = await calls.count; XCTAssertEqual(count, 1)
    }

    func testFirstRunQueryCanResetItsRetainedCurrentProcessCampaign() async throws {
        for throwsAfterReservation in [false, true] {
            let shutdowns = FirstRunQueryCalls()
            let (model, prepared, parameter) = try fixture(recoverySimulatorShutdown: { target, _, _ in
                await shutdowns.record(target.id)
            }) { prepared, entity, _, approval, attemptID, _, support in
                let owner = try AutomationDeviceLeaseManager(storeURL: support.appendingPathComponent("target-leases.json"))
                try await owner.reserveCampaign(runID: approval.runID, target: prepared.host.target)
                if throwsAfterReservation { throw FirstRunQueryError.failed }
                return try Self.result(prepared, entity: entity, approval: approval, attemptID: attemptID, released: false)
            }
            await model.ownershipRecoveryTask?.value
            await model.findFirstRunEntities(actionID: "CompleteTask", parameter: parameter)
            XCTAssertTrue(model.hasUnresolvedActiveAttempt)
            XCTAssertEqual(Array(model.retainedUnresolvedRequestTargets.values), [prepared.host.target])
            let leases = try AutomationDeviceLeaseManager(storeURL: model.support.appendingPathComponent("target-leases.json"))
            let reserved = try await leases.campaignAbsent(target: prepared.host.target)
            XCTAssertFalse(reserved)

            await model.clearUnresolvedAttempt()

            XCTAssertNil(model.recoveryError)
            let released = try await leases.campaignAbsent(target: prepared.host.target)
            XCTAssertTrue(released, "Reset must release the durable campaign, not just its UI flag")
            XCTAssertFalse(model.hasUnresolvedOwnership)
            XCTAssertTrue(model.canFindFirstRunEntities(actionID: "CompleteTask", parameter: parameter))
            let shutdownCount = await shutdowns.count
            XCTAssertEqual(shutdownCount, 1)
        }
    }

    func testChangedSelectionRetainsUnreleasedReportWithoutPublishingChoices() async throws {
        let gate = FirstRunQueryGate()
        let (model, _, parameter) = try fixture { prepared, entity, _, approval, attemptID, _, _ in
            await gate.hold()
            return try Self.result(prepared, entity: entity, approval: approval, attemptID: attemptID, released: false)
        }
        let query = Task { await model.findFirstRunEntities(actionID: "CompleteTask", parameter: parameter) }
        await gate.waitUntilEntered()
        model.selectionEpoch += 1
        await gate.release(); await query.value
        XCTAssertEqual(model.entityQueryReport?.resourcesReleased, false)
        XCTAssertNil(model.firstRunSelectedEntities()["CompleteTask"])
        XCTAssertNil(model.firstRunEntityChoices["CompleteTask"]?["task"])
        XCTAssertFalse(model.canReviewFirstChecks)
    }

    func testMacQueryUsesTheCurrentLoginSessionEnvironment() async throws {
        let calls = FirstRunQueryCalls()
        let (model, _, parameter) = try fixture(mac: true) { prepared, entity, _, approval, attemptID, _, _ in
            await calls.record(attemptID, environment: approval.environmentID)
            return try Self.result(prepared, entity: entity, approval: approval, attemptID: attemptID)
        }
        XCTAssertTrue(model.canFindFirstRunEntities(actionID: "CompleteTask", parameter: parameter))
        await model.findFirstRunEntities(actionID: "CompleteTask", parameter: parameter)
        let environment = await calls.environment
        XCTAssertEqual(environment, "selected-mac-session:synthetic-login")
    }
    func testIdentifierOnlySuggestionsRequireExplicitChoiceAndEmptySuggestionsNeverBind() async throws {
        for ids in [[], ["returned-actual-id"]] {
            let (model, original, parameter) = try fixture { prepared, entity, text, approval, attemptID, _, _ in
                XCTAssertEqual(text, "")
                return try Self.result(prepared, entity: entity, approval: approval, attemptID: attemptID, ids: ids)
            }
            var prepared = original
            prepared.catalog.entities = [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "Subject.TaskQuery", properties: [:], propertyTitles: [:], queryMode: .suggested)]
            model.prepared = prepared; model.catalog = prepared.catalog
            XCTAssertTrue(model.canFindFirstRunEntities(actionID: "CompleteTask", parameter: parameter))
            await model.findFirstRunEntities(actionID: "CompleteTask", parameter: parameter)
            XCTAssertNil(model.firstRunSelectedEntities()["CompleteTask"])
            model.selectFirstRunEntity("invented-id", actionID: "CompleteTask", parameter: "task")
            XCTAssertNil(model.firstRunSelectedEntities()["CompleteTask"])
            if let id = ids.first {
                let choice = try XCTUnwrap(model.firstRunEntityChoices["CompleteTask"]?["task"]?.first)
                XCTAssertEqual(AutomationNativeEntitySelection.label(choice, entity: prepared.catalog.entities![0]), id)
                model.selectFirstRunEntity(id, actionID: "CompleteTask", parameter: "task")
                XCTAssertEqual(model.firstRunSelectedEntities()["CompleteTask"]?["task"]?.id, id)
            }
        }
    }
}

private enum FirstRunQueryError: Error { case failed }
private actor FirstRunQueryCalls {
    var count = 0
    var attemptID: String?
    var environment: String?
    func record(_ id: String, environment: String? = nil) { count += 1; attemptID = id; self.environment = environment }
}
private actor FirstRunQueryGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; waiting?.resume(); waiting = nil; await withCheckedContinuation { pending = $0 } }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { waiting = $0 } } }
    func release() { pending?.resume(); pending = nil }
}
#endif
