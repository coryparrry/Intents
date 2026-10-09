import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationSiriQualificationTests: XCTestCase, @unchecked Sendable {
    func proposal() throws -> (AutomationCase, RunApproval, CapabilityProfile) {
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [], systemDiscoveryComplete: false,
            uiDiscoveryComplete: false, gaps: [], entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery",
                properties: ["title": "text", "completed": "bool"], propertyTitles: [:])])
        var approval = RunApproval(runID: "run", app: app, target: target, environmentID: "test",
            effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true)
        let capabilities = CapabilityProfile(records: ["apple.entity.query": .init(state: .available, reason: "test", probeVersion: "test", evidence: []),
            "siri.recognizedText.api": .init(state: .available, reason: "test", probeVersion: "test", evidence: []),
            "siri.actualRoute": .init(state: .unknown, reason: "unqualified", probeVersion: "test", evidence: [])])
        let plan = try AutomationSiriEntityPlanner.compile(catalog: catalog, entityType: "TaskEntity", nameProperty: "title",
            recordName: "Approved disposable task", stateProperty: "completed", initialState: false, expectedState: true,
            request: "Complete Approved disposable task in Example", approval: approval, capabilities: capabilities)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        return (plan, approval, capabilities)
    }
    func testControlledReviewCannotExecuteFromSerializedAvailability() throws {
        let (plan, approval, capabilities) = try proposal()
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, purpose: .review)
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities))
        var forged = capabilities
        forged.records["siri.actualRoute"]?.state = .available
        let restored = try JSONDecoder().decode(CapabilityProfile.self, from: JSONEncoder().encode(forged))
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: restored))
        let authority = try AutomationSiriRouteAuthority(plan: plan, approval: approval)
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, siriAuthority: authority)
        var otherApproval = approval; otherApproval.runID = "other"
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: otherApproval, capabilities: capabilities, siriAuthority: authority))
        var changed = plan; changed.execution.siriProgram = .init(request: "Another request")
        var changedApproval = approval; changedApproval.approvedCaseDigest = try AutomationFrozenCase.planDigest(changed)
        XCTAssertThrowsError(try PlanValidator.validate(changed, approval: changedApproval, capabilities: capabilities, siriAuthority: authority))
    }
    func testCalibrationCannotWidenEffectsRepairOrSwapRecord() throws {
        let (plan, approval, _) = try proposal()
        for mutation in 0..<6 {
            var changed = plan
            switch mutation {
            case 0: changed.execution.effects.insert(.externalWrite)
            case 1: changed.setup[0].effects.insert(.fixtureWrite)
            case 2: changed.requirements[0].expected = changed.setupChecks![0].expected
            case 3: changed.observations[0].inputBindings = nil
            case 4: changed.observations[0].hostProgram?.operations[0].queryIDs = ["invented"]
            default: changed.observations[0].hostProgram?.operations[0].properties?["completed"] = "text"
            }
            XCTAssertThrowsError(try AutomationSiriQualificationProposal.validate(plan: changed, approval: approval), "mutation \(mutation)")
        }
    }
    func testConsentAndUnavailableVetoApplyToOwnedCalibration() throws {
        let (plan, approval, capabilities) = try proposal()
        let authority = try AutomationSiriRouteAuthority(plan: plan, approval: approval)
        for state in [CapabilityProfile.State.unavailable, .consentRequired] {
            var veto = capabilities; veto.records["siri.actualRoute"]?.state = state
            XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: veto, siriAuthority: authority))
        }
    }
    #if os(macOS)
    func testQualificationRecordNeedsReturnedSubmissionSameRecordAndRelease() async throws {
        let (plan, approval, _) = try proposal()
        let host = AutomationPreparedAppleHost(app: plan.app, target: plan.target, xctestrunPath: "synthetic",
            xctestrunDigest: String(repeating: "b", count: 64), subjectProductPath: "synthetic", hostBundlePath: "synthetic",
            hostProductDigest: String(repeating: "c", count: 64), hostBundleID: "example.Host.xctrunner", testTarget: "Host")
        let prepared = AutomationPreparedApplication(source: .init(sourceRoot: "synthetic", files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "synthetic", scheme: "Host", targetID: "HOST", bundleID: host.hostBundleID,
                configuration: "Debug", templateDigest: String(repeating: "d", count: 64), includesSiri: true), host: host,
            catalog: .init(app: plan.app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []),
            buildLogPath: "synthetic-" + UUID().uuidString, buildLogTruncated: false)
        func records(_ id: String, _ completed: Bool) -> AutomationValue {
            .array([.object(["entity": .entity(typeID: "TaskEntity", value: id),
                "properties": .object(["title": .text("Approved disposable task"), "completed": .bool(completed)])])])
        }
        let observation = AutomationObservation(id: plan.observations[0].id, app: plan.app, target: plan.target,
            environmentID: plan.environmentID, attemptID: "attempt", stepID: plan.observations[0].id,
            route: .systemQuery, proof: .appState, value: records("real-id", true))
        let segments = plan.setup + [plan.execution] + plan.observations
        let receipts = segments.enumerated().map { index, segment in
            AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: "attempt", segmentID: segment.id,
                leaseGeneration: index + 1), app: plan.app, target: plan.target, segmentID: segment.id,
                route: segment.kind, dispatched: true, completed: true,
                observations: segment.phase == .observe ? [observation] : [],
                artifact: segment.kind == .siriText ? "synthetic-submission-artifact" : nil,
                verifiedOutputs: segment.kind == .systemQuery ? ["record": records("real-id", segment.phase == .observe)] : nil,
                environmentID: plan.environmentID)
        }
        let result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true,
            subjectCompleted: true, observations: [observation], receipts: receipts, runID: approval.runID)
        XCTAssertEqual(result.summary, .passed)
        let report = AutomationAttemptReport(attemptID: "attempt", result: result, receipts: receipts, resourcesReleased: true)
        let submission = AutomationImportedSiriSubmission(runner: .init(pid: 42, startIdentity: "1:2"), executablePath: "/synthetic",
            requestDigest: plan.execution.siriProgram!.requestDigest, osBuild: "24B5028f")
        let registry = AutomationSiriQualificationAuthority()
        for mutation in 0..<5 {
            var changed = report
            switch mutation {
            case 0: changed.resourcesReleased = false
            case 1: changed.result.subjectDispatchUncertain = true
            case 2: changed.receipts[1].artifact = nil
            case 3: changed.receipts[2].verifiedOutputs = ["record": records("wrong-id", true)]
            default: changed.receipts[2].verifiedOutputs = ["record": records("real-id", false)]
            }
            do { try await registry.record(prepared: prepared, plan: plan, approval: approval, report: changed, submission: submission); XCTFail("mutation \(mutation)") } catch {}
        }
        let historical = AutomationImportedSiriSubmission(runner: submission.runner, executablePath: submission.executablePath,
            requestDigest: submission.requestDigest, osBuild: nil)
        do { try await registry.record(prepared: prepared, plan: plan, approval: approval, report: report, submission: historical); XCTFail("Historical API receipt cannot qualify a current environment") } catch {}
        try await registry.record(prepared: prepared, plan: plan, approval: approval, report: report, submission: submission)
        var nextApproval = approval; nextApproval.runID = "next-run"
        let recorded = await registry.admission(prepared: prepared, plan: plan, approval: nextApproval)
        let authority = try XCTUnwrap(recorded)
        XCTAssertFalse(authority.isQualification); XCTAssertEqual(authority.expectedOSBuild, "24B5028f")
        try authority.validate(plan: plan, approval: nextApproval)
        var changed = plan; changed.execution.siriProgram = .init(request: "Different request")
        let unavailable = await registry.admission(prepared: prepared, plan: changed, approval: nextApproval); XCTAssertNil(unavailable)
        await registry.revoke(prepared: prepared, plan: plan)
        let revoked = await registry.admission(prepared: prepared, plan: plan, approval: nextApproval); XCTAssertNil(revoked)
    }
    #endif
    #if os(macOS)
    private actor InventoryGate {
        private var entered = false
        private var listeners: [CheckedContinuation<Void, Never>] = []
        private var release: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true; listeners.forEach { $0.resume() }; listeners.removeAll()
            await withCheckedContinuation { release = $0 }
        }
        func wait() async { if !entered { await withCheckedContinuation { listeners.append($0) } } }
        func resume() { release?.resume(); release = nil }
    }
    private func physicalHost(for plan: AutomationCase) -> AutomationPreparedApplication {
        let host = AutomationPreparedAppleHost(app: plan.app, target: plan.target, xctestrunPath: "synthetic",
            xctestrunDigest: String(repeating: "b", count: 64), subjectProductPath: "synthetic", hostBundlePath: "synthetic",
            hostProductDigest: String(repeating: "c", count: 64), hostBundleID: "example.Host.xctrunner", testTarget: "Host")
        return AutomationPreparedApplication(source: .init(sourceRoot: "synthetic", files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "synthetic", scheme: "Host", targetID: "HOST", bundleID: host.hostBundleID,
                configuration: "Debug", templateDigest: String(repeating: "d", count: 64), includesSiri: true), host: host,
            catalog: .init(app: plan.app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []),
            buildLogPath: "synthetic-" + UUID().uuidString, buildLogTruncated: false)
    }
    private func assertUntouched(_ root: URL, target: TargetIdentity, attemptID: String = "attempt", casesExpected: Bool = false,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let observer = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
        let absent = try await observer.campaignAbsent(target: target)
        XCTAssertTrue(absent, "Rejected calibration reserved the device campaign", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(attemptID).path), file: file, line: line)
        if !casesExpected {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Cases").path), file: file, line: line)
        }
    }
    private func assertReachesPhysicalCampaign(_ runner: AutomationApplicationRunner, prepared: AutomationPreparedApplication,
                                               plan: AutomationCase, approval: RunApproval, capabilities: CapabilityProfile,
                                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await runner.qualifySiriWorkflow(prepared: prepared, plan: plan, approval: approval,
                capabilities: capabilities, attemptID: "attempt", allowInstall: true)
            XCTFail("Synthetic host cannot complete a physical campaign", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AutomationContractError,
                .missingEvidence("Prepare the exact physical host in this process before running"), file: file, line: line)
        }
    }
    func testQualifySiriWorkflowWithoutInstallApprovalStopsBeforeAuthorityOrDevice() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (plan, approval, capabilities) = try proposal()
        let prepared = physicalHost(for: plan)
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            simulatorInventory: { _, _ in XCTFail("Siri calibration read simulator inventory"); return [] })
        var foreign = approval; foreign.disposable = false
        for candidate in [approval, foreign] {
            do {
                _ = try await runner.qualifySiriWorkflow(prepared: prepared, plan: plan, approval: candidate,
                    capabilities: capabilities, attemptID: "attempt", allowInstall: false)
                XCTFail("Calibration ran without explicit install approval")
            } catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
        }
        try await assertUntouched(root, target: plan.target)
        await assertReachesPhysicalCampaign(runner, prepared: prepared, plan: plan, approval: approval, capabilities: capabilities)
    }
    func testQualifySiriWorkflowRejectsMismatchedApprovalWithoutLeavingRunnerBusy() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (plan, approval, capabilities) = try proposal()
        let prepared = physicalHost(for: plan)
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            simulatorInventory: { _, _ in XCTFail("Siri calibration read simulator inventory"); return [] })
        var otherEnvironment = approval; otherEnvironment.environmentID = "other"
        var retained = approval; retained.disposable = false
        var otherTarget = approval; otherTarget.target = .init(id: "00008140-0000000000000000", kind: .physical)
        var widened = plan; widened.execution.effects.insert(.externalWrite)
        for (candidatePlan, candidateApproval) in [(plan, otherEnvironment), (plan, retained), (plan, otherTarget), (widened, approval)] {
            do {
                _ = try await runner.qualifySiriWorkflow(prepared: prepared, plan: candidatePlan, approval: candidateApproval,
                    capabilities: capabilities, attemptID: "attempt", allowInstall: true)
                XCTFail("Calibration accepted an approval that does not match its frozen proposal")
            } catch {
                guard case .invalidPlan = error as? AutomationContractError else { return XCTFail("Unexpected error \(error)") }
            }
            try await assertUntouched(root, target: plan.target)
        }
        // Authority failure precedes `running = true`, so the next admitted call is not reported busy.
        await assertReachesPhysicalCampaign(runner, prepared: prepared, plan: plan, approval: approval, capabilities: capabilities)
        try await assertUntouched(root, target: plan.target)
    }
    func testQualifySiriWorkflowIsRejectedWhileAnotherRunOwnsTheRunner() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (plan, approval, capabilities) = try proposal()
        let prepared = physicalHost(for: plan)
        let gate = InventoryGate()
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            simulatorInventory: { _, _ in
                await gate.hold()
                throw AutomationContractError.missingEvidence("fixture unavailable")
            })
        let app = AppIdentity(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let simulator = TargetIdentity(id: "nonexistent-simulator", kind: .simulator)
        let simulatorPlan = AutomationCase(id: "busy", app: app, target: simulator, environmentID: "disposable",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Actual subject"))
        let simulatorApp = AutomationPreparedApplication(source: .init(sourceRoot: root.path, files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "unused", bundleID: "unused", configuration: "Debug", templateDigest: "unused"),
            host: .init(app: app, target: simulator, xctestrunPath: "unused", xctestrunDigest: "unused", subjectProductPath: "unused",
                hostBundlePath: "unused", hostProductDigest: "unused", hostBundleID: "unused", testTarget: "unused"),
            catalog: .init(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []),
            buildLogPath: "unused", buildLogTruncated: false)
        let simulatorApproval = RunApproval(runID: "simulator-run", app: app, target: simulator, environmentID: simulatorPlan.environmentID,
            effects: [.observe], maximumActions: 10, disposable: true)
        let active = Task {
            try await runner.run(prepared: simulatorApp, plan: simulatorPlan, approval: simulatorApproval, capabilities: .init(),
                attemptID: "simulator-attempt", allowBootAndInstall: true)
        }
        await gate.wait()
        do {
            _ = try await runner.qualifySiriWorkflow(prepared: prepared, plan: plan, approval: approval,
                capabilities: capabilities, attemptID: "attempt", allowInstall: true)
            XCTFail("Calibration ran concurrently with another campaign")
        } catch { XCTAssertEqual(error as? AutomationContractError, .conflictingOperation) }
        // The active simulator run has frozen its own case; only the physical device must stay untouched.
        try await assertUntouched(root, target: plan.target, casesExpected: true)
        await gate.resume()
        do { _ = try await active.value; XCTFail("Synthetic inventory failure") }
        catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("fixture unavailable")) }
        await assertReachesPhysicalCampaign(runner, prepared: prepared, plan: plan, approval: approval, capabilities: capabilities)
    }
    #endif
}
