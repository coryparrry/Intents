#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationInstalledUICampaignExecutorTests: XCTestCase, @unchecked Sendable {
    private let readOnlyError = AutomationContractError.missingEvidence("Installed UI campaigns require a read-only workflow")
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/installed-ui-campaign-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func installed(_ root: URL) throws -> AutomationInstalledUIApplication {
        let bundle = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "example.UIOnly", "CFBundleExecutable": "Fixture", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        // Intake-only Mach-O header fixture; never executable or hardware proof.
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1, 0, 0, 0, 0]).write(to: bundle.appendingPathComponent("Fixture"))
        return try .init(bundleURL: bundle, target: .init(id: UUID().uuidString, kind: .simulator))
    }
    private func readOnlyPlan(_ installed: AutomationInstalledUIApplication) -> AutomationCase {
        var subject = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "inspect", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        subject.uiProgram = .init(operations: [.init(id: "endpoint", kind: .assertEndpoint, locator: .init(.label, "Ready"))])
        return AutomationCase(id: "installed-ui-campaign", app: installed.app, target: installed.target, environmentID: "owned", execution: subject)
    }
    private func approval(_ plan: AutomationCase) throws -> RunApproval {
        .init(runID: "run", app: plan.app, target: plan.target, environmentID: plan.environmentID, effects: [.observe, .navigate, .fixtureWrite, .externalWrite, .reset],
              maximumActions: 10, disposable: true, approvedCaseDigest: try AutomationFrozenCase.planDigest(plan))
    }
    private func executor(_ root: URL, _ installed: AutomationInstalledUIApplication) throws -> AutomationInstalledUICampaignExecutor {
        let runner = try AutomationApplicationRunner(supportRoot: root.appendingPathComponent("Support"), developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
            simulatorInventory: { _, _ in XCTFail("Installed UI campaign reached simulator infrastructure"); throw AutomationContractError.invalidIdentity })
        return .init(runner: runner, installed: installed, runtime: .init(bundleURL: root.appendingPathComponent("Runtime.app"), expectedTeamID: "TEAMID1234"), allowBootAndInstall: false)
    }
    /// An attempt ID the runner rejects at its first identity check, so a forwarded case
    /// surfaces `.invalidIdentity` and never reaches simulator or device infrastructure.
    private let runnerRejectedAttemptID = "not a valid attempt id"

    func testWritingOrResettingSegmentInEveryPhaseIsRefusedBeforeTheRunner() async throws {
        let mutations: [(String, (inout AutomationCase) -> Void)] = [
            ("setup fixture write", { $0.setup = [.init(id: "seed", kind: .ui, phase: .setup, operation: "Seed", effects: [.navigate, .fixtureWrite])] }),
            ("subject external write", { $0.execution.effects.insert(.externalWrite) }),
            ("observation reset", { $0.observations = [.init(id: "observe", kind: .ui, phase: .observe, operation: "Read", effects: [.observe, .reset])] }),
            ("cleanup fixture write", { $0.cleanup = [.init(id: "restore", kind: .ui, phase: .cleanup, operation: "Restore", effects: [.fixtureWrite])] }),
        ]
        for (name, mutate) in mutations {
            let root = try root(), installed = try installed(root); var plan = readOnlyPlan(installed); mutate(&plan)
            let frozen = try AutomationFrozenCase(plan: plan), executor = try executor(root, installed)
            do {
                _ = try await executor.execute(frozen: frozen, approval: approval(plan), attemptID: runnerRejectedAttemptID, budget: AutomationCampaignBudget(limits: .firstCampaign))
                XCTFail("Installed UI campaign admitted \(name)")
            } catch let error as AutomationContractError { XCTAssertEqual(error, readOnlyError, name) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Support/\(runnerRejectedAttemptID)").path), name)
        }
    }
    func testReadOnlyObserveAndNavigateWorkflowPassesTheGuardToTheRunner() async throws {
        let root = try root(), installed = try installed(root); var plan = readOnlyPlan(installed)
        plan.setup = [.init(id: "open", kind: .ui, phase: .setup, operation: "Open", effects: [.navigate])]
        plan.observations = [.init(id: "observe", kind: .ui, phase: .observe, operation: "Read", effects: [.observe])]
        let frozen = try AutomationFrozenCase(plan: plan), executor = try executor(root, installed)
        do {
            _ = try await executor.execute(frozen: frozen, approval: approval(plan), attemptID: runnerRejectedAttemptID, budget: AutomationCampaignBudget(limits: .firstCampaign))
            XCTFail("Runner accepted an invalid attempt ID")
        } catch let error as AutomationContractError { XCTAssertEqual(error, .invalidIdentity) }
    }
}
#endif
