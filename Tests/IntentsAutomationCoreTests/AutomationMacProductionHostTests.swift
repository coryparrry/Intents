#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationMacProductionHostTests: XCTestCase, @unchecked Sendable {
    func testProductionMacHostExecutesAndReleasesTwiceWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["INTENTS_MAC_PRODUCTION_HOST_LIVE"] == "1" else { throw XCTSkip("Owned disposable Mac host execution is opt-in") }
        let developer = URL(fileURLWithPath: environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer")
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("intents-production-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        print("Mac production host evidence: \(root.path)")
        let source = root.appendingPathComponent("original"), fixture = try AutomationMacInputProbeFixture.write(at: source, sourceKind: .host)
        let candidate = try XCTUnwrap(AutomationApplicationIntake.assess(fixture.project).candidates.first)
        let target = try AutomationMacGUIIdentity.currentTarget()
        let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
        let prepared = try await AutomationPreparation().prepare(candidate: candidate,
            approval: .init(sourceRoot: source.path, candidateID: candidate.id, configuration: "Debug", target: target),
            sessionRoot: root.appendingPathComponent("prepare"), templates: templates, developerDirectory: developer)
        let capabilities = CapabilityProfile(records: ["apple.intent.invoke": .init(state: .available, reason: "Compiled associated-host action", probeVersion: "host-v2", evidence: [prepared.host.xctestrunDigest])])
        var approval = RunApproval(runID: UUID().uuidString, app: prepared.host.app, target: target,
            environmentID: "selected-mac-session:" + target.loginSession!, effects: [.observe], maximumActions: 1, disposable: true)
        let proposal = try AutomationFirstRunPlanner.compile(catalog: prepared.catalog, appName: "Subject", approval: approval,
            capabilities: capabilities, includeActions: true, includeUI: false, localeIdentifier: "en_GB")
        var plan = try XCTUnwrap(proposal.plans.first)
        plan.preparedMacBuildArtifacts = try .init(prepared: prepared)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let support = root.appendingPathComponent("runs"), runner = try AutomationApplicationRunner(supportRoot: support, developerDirectory: developer)
        for _ in 0..<2 {
            let report = try await runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: capabilities,
                attemptID: UUID().uuidString, allowBootAndInstall: false)
            XCTAssertTrue(report.result.subjectCompleted, String(describing: report))
            XCTAssertEqual(report.result.summary, .executedUnassessed)
            XCTAssertTrue(report.resourcesReleased)
            XCTAssertEqual(report.receipts.count, 1)
            let leases = try AutomationDeviceLeaseManager(storeURL: support.appendingPathComponent("target-leases.json"))
            let absent = try await leases.campaignAbsent(target: target)
            XCTAssertTrue(absent)
            guard report.result.subjectCompleted, report.resourcesReleased, !report.result.subjectDispatchUncertain else { return }
        }
        try AutomationSourceSnapshot.verifyOriginal(prepared.source)
    }
}
#endif
