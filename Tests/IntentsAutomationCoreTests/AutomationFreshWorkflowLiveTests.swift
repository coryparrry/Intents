#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore
import IntentsAutomationUIHostContracts

final class AutomationFreshWorkflowLiveTests: XCTestCase {
    /// Opt-in real simulator UI -> owned App Intent -> independent entity readback.
    /// Host templates and the approved disposable fixture are explicit local inputs.
    func testApprovedFreshDuplicateRecordsThroughProductionRunner() async throws {
        guard let profilePath = ProcessInfo.processInfo.environment["INTENTS_FRESH_WORKFLOW_LIVE_PROFILE"],
              let templatesPath = ProcessInfo.processInfo.environment["INTENTS_FRESH_WORKFLOW_HOST_TEMPLATES"] else {
            throw XCTSkip("Requires the approved disposable fixture/simulator profile and generated-host template directory")
        }
        struct Profile: Decodable {
            let sourceProject: String, sourceDigest: String, simulatorID: String, developerDirectory: String
        }
        let profile = try JSONDecoder().decode(Profile.self, from: AutomationReadOnlyFile.read(URL(fileURLWithPath: profilePath), maximumBytes: 16_384))
        let project = try AutomationPath.canonical(URL(fileURLWithPath: profile.sourceProject))
        guard project.path.hasPrefix("/private/tmp/foundation-evals-ui-tests/"), project.lastPathComponent == "AutomationFixture.xcodeproj",
              UUID(uuidString: profile.simulatorID) != nil else { throw AutomationContractError.invalidIdentity }
        let source = project.deletingLastPathComponent().appendingPathComponent("App/TaskIntents.swift")
        let before = AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(source, maximumBytes: 4_194_304))
        guard before == profile.sourceDigest else { throw AutomationContractError.conflictingOperation }
        let templates = try AutomationPath.canonical(URL(fileURLWithPath: templatesPath, isDirectory: true))
        let developer = try AutomationPath.canonical(URL(fileURLWithPath: profile.developerDirectory))
        let root = URL(fileURLWithPath: "/private/tmp/intents-xcuitest-independent-fresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        print("INDEPENDENT_FRESH_ROOT=\(root.path)")
        let intake = try AutomationApplicationIntake.assess(project)
        let candidate = try XCTUnwrap(intake.candidates.first { $0.kind == .sourceTarget && $0.name == "AutomationFixture" })
        let target = TargetIdentity(id: profile.simulatorID, kind: .simulator)
        let build = AutomationBuildApproval(sourceRoot: project.deletingLastPathComponent().path,
            candidateID: candidate.id, configuration: "Debug", target: target)
        let prepared = try await AutomationPreparation().prepare(candidate: candidate, approval: build,
            sessionRoot: root.appendingPathComponent("prepare"), templates: templates, developerDirectory: developer)
        XCTAssertNotEqual(prepared.generatedHost.includesSiri, true, "A simulator host must exclude the physical Siri template")
        XCTAssertFalse(prepared.generatedHost.templateDigest.isEmpty)
        var capabilities = AutomationPreparedCapabilities.base(prepared)
        var approval = RunApproval(runID: UUID().uuidString, app: prepared.host.app, target: prepared.host.target,
            environmentID: "selected-simulator:" + target.id, effects: [.observe, .navigate, .fixtureWrite], maximumActions: 30, disposable: true)
        let plan = try AutomationFreshEntityPlanner.compile(catalog: prepared.catalog, actionID: "CompleteTaskIntent",
            instruction: "Create and save a task using the approved test record name and the specified account. Enter the name in Task title, select the specified Account if needed, and press Add task once. Finish when the new task row is visible.",
            endpoint: "Automation Fixture", namePrefix: "Intents record", nameProperty: "title", stateProperty: "completed",
            initialState: false, expectedState: true, approval: approval, capabilities: capabilities, localeIdentifier: Locale.current.identifier,
            context: .init(property: "owner", selectedValue: "Personal", protectedValue: "Work"), purpose: .simulatorDraft,
            saveControl: .init(.testId, "task.add"), nameEntry: .init(.testId, "task.title"))
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let runner = try AutomationApplicationRunner(supportRoot: root.appendingPathComponent("run"), developerDirectory: developer)
        capabilities = try await runner.capabilitiesForExecution(subject: .prepared(prepared), plan: plan, capabilities: capabilities)
        let initialInventory = try await AutomationSimulatorInventory.read(developerDirectory: developer, workspace: root)
        guard initialInventory.first(where: { $0.id == target.id })?.state == "Shutdown" else {
            throw XCTSkip("The approved simulator must start Shutdown to verify owned cold-start cleanup")
        }
        let attempt = UUID().uuidString
        let report = try await runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: capabilities,
            attemptID: attempt, allowBootAndInstall: true)
        print("INDEPENDENT_FRESH_REPORT=\(root.appendingPathComponent("run/" + attempt + "/report.json").path)")
        XCTAssertTrue(report.resourcesReleased)
        XCTAssertEqual(report.result.summary, .passed, String(describing: report.result))
        XCTAssertTrue(report.result.subjectCompleted); XCTAssertFalse(report.result.subjectDispatchUncertain)
        XCTAssertTrue(report.result.assessed); XCTAssertEqual(report.receipts.count, 6)
        try assertSingleInvocation(root: root, attemptID: attempt)
        try await assertOwnedColdStartShutdown(root: root, attemptID: attempt, target: target, developer: developer)

        var assertion = AutomationSegment(id: "subject", kind: .ui, phase: .subject,
            operation: "Verify a failing assertion returns receipts", effects: [.observe, .navigate])
        assertion.uiProgram = .init(steps: [.init(id: "title-absent", kind: .assert,
            query: .init(identifier: "task.title"), property: "exists",
            equals: .init(kind: "bool", boolValue: false))])
        var failingPlan = AutomationCase(id: "live.ui.assertion-failure", app: prepared.host.app,
            target: target, environmentID: approval.environmentID, execution: assertion)
        failingPlan.budget.subjectOperations = 3
        failingPlan.budget.wallClockSeconds = 240
        var failingApproval = approval
        failingApproval.approvedCaseDigest = try AutomationFrozenCase.planDigest(failingPlan)
        let failingAttempt = UUID().uuidString
        let failed = try await runner.run(prepared: prepared, plan: failingPlan, approval: failingApproval,
            capabilities: capabilities, attemptID: failingAttempt, allowBootAndInstall: true)
        XCTAssertEqual(failed.result.summary, .assertionFailed)
        XCTAssertTrue(failed.resourcesReleased)
        XCTAssertEqual(failed.receipts.count, 1)
        XCTAssertEqual(failed.receipts.first?.dispatched, true)
        XCTAssertEqual(failed.receipts.first?.completed, false)
        try assertSingleInvocation(root: root, attemptID: failingAttempt)
        try await assertOwnedColdStartShutdown(root: root, attemptID: failingAttempt, target: target, developer: developer)
        XCTAssertEqual(AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(source, maximumBytes: 4_194_304)), before)
    }

    private func assertOwnedColdStartShutdown(root: URL, attemptID: String, target: TargetIdentity, developer: URL) async throws {
        let entries = try JSONDecoder().decode([String: AutomationJournal.Entry].self,
            from: AutomationReadOnlyFile.read(root.appendingPathComponent("run/" + attemptID + "/journal.json"), maximumBytes: 16_777_216))
        for operation in ["boot", "bootReady", "shutdown"] {
            let entry = try XCTUnwrap(entries[attemptID + ".prepare." + operation])
            XCTAssertEqual(entry.state, .completed)
            XCTAssertEqual(entry.response, .integer("0"))
        }
        let inventory = try await AutomationSimulatorInventory.read(developerDirectory: developer, workspace: root)
        XCTAssertEqual(inventory.first(where: { $0.id == target.id })?.state, "Shutdown")
    }

    private func assertSingleInvocation(root: URL, attemptID: String) throws {
        let directory = root.appendingPathComponent("run/" + attemptID + "/artifacts")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let invocations = try files.filter { $0.lastPathComponent.hasPrefix("xcuitest-log-") }.reduce(0) { count, file in
            count + String(decoding: try AutomationReadOnlyFile.read(file, maximumBytes: 4_194_304), as: UTF8.self)
                .components(separatedBy: "Command line invocation:").count - 1
        }
        XCTAssertEqual(invocations, 1)
        XCTAssertTrue(files.contains { $0.pathExtension == "png" }, "The host must retain an actual screenshot")
    }
}
#endif
