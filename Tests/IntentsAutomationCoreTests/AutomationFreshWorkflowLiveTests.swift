#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationFreshWorkflowLiveTests: XCTestCase {
    /// Opt-in real simulator UI -> owned App Intent -> independent entity readback.
    /// This bypasses only the unavailable Mac UI test driver, not product execution.
    func testApprovedFreshDuplicateRecordsThroughProductionRunner() async throws {
        guard let profilePath = ProcessInfo.processInfo.environment["INTENTS_FRESH_WORKFLOW_LIVE_PROFILE"],
              let appPath = ProcessInfo.processInfo.environment["INTENTS_FRESH_WORKFLOW_RUNTIME_APP"] else {
            throw XCTSkip("Requires the approved disposable fixture/simulator profile and sealed native runtime")
        }
        struct Profile: Decodable {
            let sourceProject: String, sourceDigest: String, simulatorID: String, developerDirectory: String
        }
        let profile = try JSONDecoder().decode(Profile.self, from: AutomationReadOnlyFile.read(URL(fileURLWithPath: profilePath), maximumBytes: 16_384))
        let project = try AutomationPath.canonical(URL(fileURLWithPath: profile.sourceProject))
        guard project.path.hasPrefix("/private/tmp/foundation-evals-ui-tests/"), project.lastPathComponent == "DuplicateTasks.xcodeproj",
              UUID(uuidString: profile.simulatorID) != nil else { throw AutomationContractError.invalidIdentity }
        let source = project.deletingLastPathComponent().appendingPathComponent("App/TaskIntents.swift")
        let before = AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(source, maximumBytes: 4_194_304))
        guard before == profile.sourceDigest else { throw AutomationContractError.conflictingOperation }
        let app = try AutomationPath.canonical(URL(fileURLWithPath: appPath))
        let developer = try AutomationPath.canonical(URL(fileURLWithPath: profile.developerDirectory))
        let root = URL(fileURLWithPath: "/private/tmp/intents-v3-independent-fresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        print("INDEPENDENT_FRESH_ROOT=\(root.path)")
        let intake = try AutomationApplicationIntake.assess(project)
        let candidate = try XCTUnwrap(intake.candidates.first { $0.kind == .sourceTarget && $0.name == "DuplicateTasks" })
        let target = TargetIdentity(id: profile.simulatorID, kind: .simulator)
        let build = AutomationBuildApproval(sourceRoot: project.deletingLastPathComponent().path,
            candidateID: candidate.id, configuration: "Debug", target: target)
        let prepared = try await AutomationPreparation().prepare(candidate: candidate, approval: build,
            sessionRoot: root.appendingPathComponent("prepare"), templates: app.appendingPathComponent("Contents/Resources/AutomationHost"), developerDirectory: developer)
        XCTAssertNotEqual(prepared.generatedHost.includesSiri, true, "A simulator host must exclude the physical Siri template")
        XCTAssertEqual(prepared.generatedHost.templateDigest, AutomationSimulatorCodecQualification.qualified.context.hostTemplate)
        var capabilities = AutomationEntityQuery.capabilities(prepared)
        capabilities.records["apple.intent.invoke"] = .init(state: .available, reason: "Invocation checks registration", probeVersion: "host-v2", evidence: [prepared.host.xctestrunDigest])
        var approval = RunApproval(runID: UUID().uuidString, app: prepared.host.app, target: prepared.host.target,
            environmentID: "selected-simulator:" + target.id, effects: [.observe, .navigate, .fixtureWrite], maximumActions: 30, disposable: true)
        var plan = try AutomationFreshEntityPlanner.compile(catalog: prepared.catalog, actionID: "CompleteTaskIntent",
            instruction: "Create and save a task using the approved test record name and the specified account. Enter the name in Task title, select the specified Account if needed, and press Add task once. Finish when the new task row is visible.",
            endpoint: "Duplicate Tasks", namePrefix: "Intents v3 record", nameProperty: "title", stateProperty: "completed",
            initialState: false, expectedState: true, approval: approval, capabilities: capabilities, localeIdentifier: Locale.current.identifier,
            context: .init(property: "owner", selectedValue: "Personal", protectedValue: "Work"), purpose: .simulatorDraft,
            saveControl: .init(.label, "Add task"))
        let manifest = try AutomationReadOnlyFile.read(root: app.appendingPathComponent("Contents/Resources/Automation"), relativePath: "runtime-manifest.json", maximumBytes: 4_194_304)
        plan.provenance["ui.runtimeManifestDigest"] = AutomationArtifactRegistry.digest(manifest)
        plan.provenance["ui.runtimeTeamID"] = "3Z3955EFRE"
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let runner = try AutomationApplicationRunner(supportRoot: root.appendingPathComponent("run"), developerDirectory: developer)
        capabilities = try await runner.capabilitiesForExecution(subject: .prepared(prepared), plan: plan, capabilities: capabilities)
        let attempt = UUID().uuidString
        let report = try await runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: capabilities,
            attemptID: attempt, allowBootAndInstall: true, uiRuntime: .init(bundleURL: app, expectedTeamID: "3Z3955EFRE"))
        print("INDEPENDENT_FRESH_REPORT=\(root.appendingPathComponent("run/" + attempt + "/report.json").path)")
        XCTAssertTrue(report.resourcesReleased)
        XCTAssertEqual(report.result.summary, .passed, String(describing: report.result))
        XCTAssertTrue(report.result.subjectCompleted); XCTAssertFalse(report.result.subjectDispatchUncertain)
        XCTAssertTrue(report.result.assessed); XCTAssertEqual(report.receipts.count, 6)
        XCTAssertEqual(AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(source, maximumBytes: 4_194_304)), before)
    }
}
#endif
