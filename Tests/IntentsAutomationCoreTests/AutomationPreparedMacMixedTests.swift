#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

extension AutomationPrivateMacAppleRouteDriverTests {
    struct MixedHarness: Sendable {
        let base: Harness, prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval
        let leases: AutomationDeviceLeaseManager, budget: AutomationCampaignBudget, commands: AutomationResolutionCommands
        let trace: AutomationMacUIQualificationTests.Trace
    }
    func mixedHarness(systemOnly: Bool = false) async throws -> MixedHarness {
        let h = try await fixture()
        let source = AutomationSourceManifest(sourceRoot: h.root.path, files: [], directories: [], excludedPaths: [])
        var host = h.host; host.app.sourceManifestDigest = try source.digest
        let prepared = AutomationPreparedApplication(source: source,
            generatedHost: .init(projectPath: "synthetic", scheme: "OwnedHost", targetID: "HOST", bundleID: host.hostBundleID, configuration: "Debug", templateDigest: String(repeating: "a", count: 64)),
            host: host, catalog: .init(app: host.app, systemActions: [.init(id: "HostProbeIntent", typeName: "HostProbeIntent", title: "Probe", parameters: [], parametersComplete: true, compiled: true, registered: false, executed: false, resultFamily: "noValue")], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []), buildLogPath: "synthetic", buildLogTruncated: false)
        var plan = h.plan; plan.app = host.app
        plan.provenance["apple.macHostProductDigest"] = host.hostProductDigest
        plan.provenance["apple.macXctestrunDigest"] = host.xctestrunDigest
        if !systemOnly {
            var setup = AutomationSegment(id: "setup", kind: .ui, phase: .setup, operation: "Open", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
            setup.uiProgram = .init(operations: [.init(id: "tap", kind: .tap, locator: .init(.label, "Ready"))])
            var observer = setup; observer.id = "observer"; observer.phase = .observe
            observer.uiProgram = .init(operations: [.init(id: "status", kind: .observeProperty, locator: .init(.testId, "status"), property: "text")])
            plan.setup = [setup]; plan.observations = [observer]
            plan.provenance["ui.privateMacReceiptSHA256"] = AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256
        }
        var approval = h.approval; approval.app = host.app; approval.effects.insert(.navigate); approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        return try .init(base: h, prepared: prepared, plan: plan, approval: approval, leases: .init(), budget: AutomationCampaignBudget(limits: .firstCampaign),
                         commands: AutomationResolutionCommands(host: host), trace: AutomationMacUIQualificationTests.Trace())
    }
    private final class MixedLeaseWitness: @unchecked Sendable {
        private let lock = NSLock()
        private var manager: ObjectIdentifier?
        init(expected: AutomationDeviceLeaseManager?) { manager = expected.map(ObjectIdentifier.init) }
        func accepts(_ value: AutomationDeviceLeaseManager) -> Bool {
            lock.withLock {
                let identity = ObjectIdentifier(value)
                if let manager { return manager == identity }
                manager = identity; return true
            }
        }
    }
    func mixedDependencies(_ h: MixedHarness, includeApple: Bool = true, systemOnly: Bool = false, runnerLeases: Bool = false) -> AutomationMacUIQualification.Dependencies {
        let witness = MixedLeaseWitness(expected: runnerLeases ? nil : h.leases)
        var dependencies = AutomationMacUIQualification.Dependencies(runtimeRoot: h.base.root, verifyRuntime: { _ in
            XCTAssertFalse(systemOnly, "System-only execution read a UI runtime")
            return AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256
        }, driver: { context in
            XCTAssertTrue(witness.accepts(context.leases)); XCTAssertTrue(context.campaignBudget === h.budget)
            return try AutomationMacUIRouteDriver(state: context.state, approval: context.approval, leases: context.leases, artifacts: context.artifacts,
                subject: Subject(app: h.prepared.host.app, target: h.prepared.host.target), campaignBudget: context.campaignBudget, inputCapabilities: context.inputCapabilities,
                factory: { selected in
                    await h.trace.record("factory")
                    return AutomationMacUIQualificationTests.Session(selected, trace: h.trace, mode: .normal)
                })
        })
        if includeApple {
            dependencies.appleDriver = { context in
                XCTAssertEqual(context.host, h.prepared.host); XCTAssertTrue(witness.accepts(context.leases)); XCTAssertTrue(context.campaignBudget === h.budget)
                return try AutomationPrivateMacAppleRouteDriver(prepared: context.host, approval: context.approval,
                    developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"), stateDirectory: context.state,
                    leases: context.leases, artifacts: context.artifacts, subjectVerifier: Subject(app: context.host.app, target: context.host.target),
                    releaseVerifier: h.base.release, campaignBudget: context.campaignBudget, capabilities: context.capabilities, validateTarget: { _ in },
                    commands: .init(run: { try await h.commands.run($0, root: $1, timeout: $2) }, stop: { await h.commands.stop() }))
            }
        }
        return dependencies
    }
    func testPreparedMacMixedRouteUsesSharedOwnersJournalArtifactsAndBudget() async throws {
        let h = try await mixedHarness(), owner = AutomationMacUIQualification(root: h.base.root.appendingPathComponent("mixed"), leases: h.leases, dependencies: mixedDependencies(h))
        let report = try await owner.run(prepared: h.prepared, plan: h.plan, approval: h.approval, capabilities: .init(), attemptID: "attempt", campaignBudget: h.budget)
        XCTAssertTrue(report.resourcesReleased); XCTAssertTrue(report.result.subjectCompleted)
        XCTAssertEqual(report.receipts.map(\.route), [.ui, .systemIntent, .ui])
        XCTAssertEqual(report.receipts.last?.verifiedOutputs?["status"], .text("Ready"))
        let usage = await h.budget.snapshot(); XCTAssertEqual(usage.reservedSubjectOperations, 1); XCTAssertEqual(usage.reservedSetupOperations, 2); XCTAssertEqual(usage.reservedObserverOperations, 2)
        let absent = try await h.leases.campaignAbsent(target: h.plan.target); XCTAssertTrue(absent)
        let state = h.base.root.appendingPathComponent("mixed/attempt")
        for path in ["journal.json", "report.json", "artifacts"] { XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent(path).path)) }
        let saved = try JSONDecoder().decode(AutomationAttemptReport.self, from: Data(contentsOf: state.appendingPathComponent("report.json")))
        XCTAssertEqual(saved, report)
        let calls = await h.trace.values(); XCTAssertEqual(calls.filter { $0 == "close" }.count, 2)
    }
    func testUnprovedAppleReleaseStopsMacUIHandoffAndRetainsLease() async throws {
        let h = try await mixedHarness(); await h.base.release.deny()
        let owner = AutomationMacUIQualification(root: h.base.root.appendingPathComponent("mixed"), leases: h.leases, dependencies: mixedDependencies(h))
        let report = try await owner.run(prepared: h.prepared, plan: h.plan, approval: h.approval, capabilities: .init(), attemptID: "attempt", campaignBudget: h.budget)
        XCTAssertFalse(report.resourcesReleased); XCTAssertEqual(report.receipts.count, 2)
        let absent = try await h.leases.campaignAbsent(target: h.plan.target); XCTAssertFalse(absent)
        let usage = await h.budget.snapshot(); XCTAssertEqual(usage.reservedObserverOperations, 0)
        let calls = await h.trace.values(); XCTAssertEqual(calls.filter { $0 == "factory" }.count, 1)
    }
    func testUnqualifiedPreparedMacFactoryFailsBeforeReservationOrUIInput() async throws {
        let h = try await mixedHarness(), owner = AutomationMacUIQualification(root: h.base.root.appendingPathComponent("mixed"), leases: h.leases, dependencies: mixedDependencies(h, includeApple: false))
        do { _ = try await owner.run(prepared: h.prepared, plan: h.plan, approval: h.approval, capabilities: .init(), attemptID: "attempt", campaignBudget: h.budget); XCTFail("Unqualified system owner admitted") }
        catch let error as AutomationContractError { XCTAssertEqual(error, .missingEvidence("Prepared Mac system execution requires qualified associated-host child closure")) }
        let absent = try await h.leases.campaignAbsent(target: h.plan.target); XCTAssertTrue(absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.base.root.appendingPathComponent("mixed/attempt").path))
        let calls = await h.trace.values(); XCTAssertTrue(calls.isEmpty)
    }
    func testChangedPreparedMacHostProvenanceOrSourceFailsBeforeOwnership() async throws {
        for mode in 0...2 {
            let h = try await mixedHarness(); var prepared = h.prepared, plan = h.plan, approval = h.approval
            if mode == 0 { plan.provenance["apple.macHostProductDigest"] = String(repeating: "b", count: 64) }
            if mode == 1 { plan.provenance["apple.macXctestrunDigest"] = String(repeating: "b", count: 64) }
            if mode == 2 { prepared.source.directories = ["foreign"] }
            approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
            let owner = AutomationMacUIQualification(root: h.base.root.appendingPathComponent("mixed"), leases: h.leases, dependencies: mixedDependencies(h))
            do { _ = try await owner.run(prepared: prepared, plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", campaignBudget: h.budget); XCTFail("Changed preparation provenance admitted") } catch {}
            let absent = try await h.leases.campaignAbsent(target: h.plan.target); XCTAssertTrue(absent)
            let calls = await h.trace.values(); XCTAssertTrue(calls.isEmpty)
        }
    }
    func testPreparedMacReviewMismatchCannotReachAnyInputOrOwnership() async throws {
        for mode in 0...2 {
            let h = try await mixedHarness(); var plan = h.plan, approval = h.approval
            if mode == 0 { approval.approvedCaseDigest = nil }
            if mode == 1 { approval.approvedCaseDigest = String(repeating: "b", count: 64) }
            if mode == 2 {
                plan.setup[0].uiProgram = .init(operations: [.init(id: "fill", kind: .fillBinding, locator: .init(.label, "Name"), binding: "input")], bindings: ["input": "approved"])
                plan.provenance["ui.privateMacReceiptSHA256"] = AutomationPrivateMacDaemonUnit.pinnedFillProgramReceiptSHA256
                approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
                plan.setup[0].uiProgram?.bindings["input"] = "changed"
            }
            let owner = AutomationMacUIQualification(root: h.base.root.appendingPathComponent("mixed"), leases: h.leases, dependencies: mixedDependencies(h))
            do { _ = try await owner.run(prepared: h.prepared, plan: plan, approval: approval, capabilities: .init(), attemptID: "attempt", campaignBudget: h.budget); XCTFail("Changed review admitted") }
            catch let error as AutomationContractError { XCTAssertEqual(error, .invalidPlan("Prepared Mac execution requires this exact reviewed case")) }
            let calls = await h.trace.values(); XCTAssertTrue(calls.isEmpty)
            let absent = try await h.leases.campaignAbsent(target: h.plan.target); XCTAssertTrue(absent)
            XCTAssertFalse(FileManager.default.fileExists(atPath: h.base.root.appendingPathComponent("mixed/attempt").path))
        }
    }
    func testPreparedMacTamperedProductOrTestFileCannotActivateUISetup() async throws {
        for product in [false, true] {
            let h = try await mixedHarness()
            let file = URL(fileURLWithPath: product ? h.prepared.host.subjectProductPath + "/Contents/MacOS/Subject" : h.prepared.host.xctestrunPath)
            try Data("changed bytes".utf8).write(to: file)
            let owner = AutomationMacUIQualification(root: h.base.root.appendingPathComponent("mixed"), leases: h.leases, dependencies: mixedDependencies(h))
            do { _ = try await owner.run(prepared: h.prepared, plan: h.plan, approval: h.approval, capabilities: .init(), attemptID: "attempt", campaignBudget: h.budget); XCTFail("Tampered prepared bytes activated UI") } catch {}
            let calls = await h.trace.values(); XCTAssertTrue(calls.isEmpty)
            let absent = try await h.leases.campaignAbsent(target: h.plan.target); XCTAssertTrue(absent)
        }
    }
    func testPreparedMacSystemOnlyRouteDoesNotRequireUIRuntime() async throws {
        let h = try await mixedHarness(systemOnly: true), owner = AutomationMacUIQualification(root: h.base.root.appendingPathComponent("mixed"), leases: h.leases, dependencies: mixedDependencies(h, systemOnly: true))
        let report = try await owner.run(prepared: h.prepared, plan: h.plan, approval: h.approval, capabilities: .init(), attemptID: "attempt", campaignBudget: h.budget)
        XCTAssertTrue(report.resourcesReleased); XCTAssertTrue(report.result.subjectCompleted); XCTAssertEqual(report.receipts.map(\.route), [.systemIntent])
        let calls = await h.trace.values(); XCTAssertTrue(calls.isEmpty)
    }
    func testRunnerDispatchesPreparedMacMixedRouteOnlyThroughInjectedQualification() async throws {
        for subjectEntry in [false, true] {
            let h = try await mixedHarness(), root = h.base.root.appendingPathComponent("runner")
            let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: h.base.root,
                simulatorInventory: { _, _ in XCTFail("Mac qualification read simulator inventory"); throw AutomationContractError.invalidIdentity },
                macQualification: mixedDependencies(h, runnerLeases: true))
            let report: AutomationAttemptReport
            if subjectEntry {
                report = try await runner.run(subject: .prepared(h.prepared), plan: h.plan, approval: h.approval, capabilities: .init(),
                    attemptID: "attempt", allowBootAndInstall: false, campaignBudget: h.budget)
            } else {
                report = try await runner.run(prepared: h.prepared, plan: h.plan, approval: h.approval, capabilities: .init(),
                    attemptID: "attempt", allowBootAndInstall: false, campaignBudget: h.budget)
            }
            XCTAssertTrue(report.resourcesReleased); XCTAssertTrue(report.result.subjectCompleted)
            XCTAssertEqual(report.receipts.map(\.route), [.ui, .systemIntent, .ui])
            XCTAssertEqual(report.receipts.last?.verifiedOutputs?["status"], .text("Ready"))
            let cases = try AutomationCaseStore(root: root.appendingPathComponent("Cases"))
            let frozen = try await cases.freeze(h.plan), saved = try await cases.loadAttempt(id: "attempt", frozen: frozen)
            XCTAssertEqual(saved, report)
            let leases = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
            let absent = try await leases.campaignAbsent(target: h.plan.target); XCTAssertTrue(absent)
            let usage = await h.budget.snapshot(); XCTAssertEqual(usage.reservedSubjectOperations, 1)
        }
    }
    func testPublicRunnerAndMissingAppleFactoryDenyPreparedMacBeforeAnyController() async throws {
        for injected in [false, true] {
            let h = try await mixedHarness(), root = h.base.root.appendingPathComponent("runner")
            let runner: AutomationApplicationRunner
            if injected {
                runner = try .init(supportRoot: root, developerDirectory: h.base.root,
                    simulatorInventory: { _, _ in XCTFail("Mac denial read simulator inventory"); return [] },
                    macQualification: mixedDependencies(h, includeApple: false, runnerLeases: true))
            } else { runner = try .init(supportRoot: root, developerDirectory: h.base.root) }
            do {
                _ = try await runner.run(prepared: h.prepared, plan: h.plan, approval: h.approval, capabilities: .init(), attemptID: "attempt", allowBootAndInstall: false)
                XCTFail("Unqualified prepared Mac executed")
            } catch let error as AutomationContractError {
                XCTAssertEqual(error, .missingEvidence(injected ? "Prepared Mac system execution requires qualified associated-host child closure" :
                    "Prepared Mac system and mixed execution require a qualified associated-host route"))
            }
            let calls = await h.trace.values(); XCTAssertTrue(calls.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attempt").path))
        }
    }
    func testPreparedMacRunnerRejectsInstallAndSimulatorRuntime() async throws {
        for mode in 0..<2 {
            let h = try await mixedHarness(), root = h.base.root.appendingPathComponent("runner")
            let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: h.base.root,
                simulatorInventory: { _, _ in XCTFail("Mac denial read simulator inventory"); return [] }, macQualification: mixedDependencies(h, runnerLeases: true))
            do {
                _ = try await runner.run(prepared: h.prepared, plan: h.plan, approval: h.approval, capabilities: .init(), attemptID: "attempt",
                    allowBootAndInstall: mode == 0, campaignBudget: h.budget,
                    uiRuntime: mode == 1 ? .init(bundleURL: h.base.root, expectedTeamID: "AAAAAAAAAA") : nil)
                XCTFail("Unsupported Mac authority admitted")
            } catch let error as AutomationContractError {
                XCTAssertEqual(error, .missingEvidence("Prepared Mac qualification does not accept installation or simulator runtime"))
            }
            let calls = await h.trace.values(); XCTAssertTrue(calls.isEmpty)
            let usage = await h.budget.snapshot(); XCTAssertEqual(usage.reservedSubjectOperations, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attempt").path))
        }
    }
    func testPreparedMacRunnerRechecksProductAndXctestrunBeforeInput() async throws {
        for product in [false, true] {
            let h = try await mixedHarness(), root = h.base.root.appendingPathComponent("runner")
            if product {
                let resources = URL(fileURLWithPath: h.prepared.host.subjectProductPath).appendingPathComponent("Contents/Resources")
                try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
                try Data("changed".utf8).write(to: resources.appendingPathComponent("changed.txt"))
            } else { try Data("changed".utf8).write(to: URL(fileURLWithPath: h.prepared.host.xctestrunPath)) }
            let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: h.base.root,
                simulatorInventory: { _, _ in XCTFail("Mac denial read simulator inventory"); return [] }, macQualification: mixedDependencies(h, runnerLeases: true))
            do {
                _ = try await runner.run(prepared: h.prepared, plan: h.plan, approval: h.approval, capabilities: .init(), attemptID: "attempt", allowBootAndInstall: false)
                XCTFail("Changed product/provenance admitted")
            } catch {}
            let calls = await h.trace.values(); XCTAssertTrue(calls.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attempt").path))
        }
    }

}
#endif
