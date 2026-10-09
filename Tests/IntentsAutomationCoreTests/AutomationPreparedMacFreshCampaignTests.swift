#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

extension AutomationPrivateMacAppleRouteDriverTests {
    struct MacFreshHarness: Sendable {
        let prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval
        let capabilities: CapabilityProfile, runner: AutomationApplicationRunner, driver: FreshRecordPlanDriver
        let root: URL
    }
    private final class MacFreshContextWitness: @unchecked Sendable {
        private let lock = NSLock()
        private var manager: ObjectIdentifier?
        private var budgets: [String: ObjectIdentifier] = [:]
        func check(state: URL, leases: AutomationDeviceLeaseManager, budget: AutomationCampaignBudget?) {
            lock.withLock {
                let identity = ObjectIdentifier(leases)
                if let manager { XCTAssertEqual(manager, identity) } else { manager = identity }
                let key = state.deletingLastPathComponent().lastPathComponent
                if let budget {
                    let value = ObjectIdentifier(budget)
                    if let expected = budgets[key] { XCTAssertEqual(expected, value) } else { budgets[key] = value }
                }
            }
        }
    }
    func macFreshHarness(mode: FreshRecordPlanDriver.Mode = .normal, changedBuild: Bool = false) async throws -> MacFreshHarness {
        let h = try await mixedHarness(); var prepared = h.prepared
        prepared.host.app.configuration = "Debug"
        prepared.host.app.sourceSyntaxIndexDigest = String(repeating: changedBuild ? "e" : "d", count: 64)
        if changedBuild {
            let executable = URL(fileURLWithPath: prepared.host.subjectProductPath).appendingPathComponent("Contents/MacOS/Subject")
            var bytes = try Data(contentsOf: executable); bytes.append(1); try bytes.write(to: executable)
            prepared.host.app.productDigest = try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: prepared.host.subjectProductPath), version: 2)
            let host = URL(fileURLWithPath: prepared.host.hostBundlePath)
            let hostExecutable = host.appendingPathComponent("Contents/MacOS/OwnedHost-Runner")
            var hostBytes = try Data(contentsOf: hostExecutable); hostBytes.append(1); try hostBytes.write(to: hostExecutable)
            prepared.host.hostProductDigest = try AutomationProductDigest.compute(bundle: host, version: 2)
            let test = URL(fileURLWithPath: prepared.host.xctestrunPath)
            var testBytes = try Data(contentsOf: test); testBytes.append(0x0a); try testBytes.write(to: test)
            prepared.host.xctestrunDigest = AutomationArtifactRegistry.digest(testBytes)
        }
        prepared.catalog = .init(app: prepared.host.app, systemActions: [.init(id: "Complete", typeName: "Complete", title: "Complete task",
            parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity")], parametersComplete: true, compiled: true, registered: false, executed: false)],
            systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [],
            entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery", properties: ["title": "text", "completed": "bool"], propertyTitles: [:])])
        prepared.catalog.sourceGraphDigest = String(repeating: changedBuild ? "b" : "a", count: 64)
        prepared.catalog.sourceSyntaxIndexDigest = prepared.host.app.sourceSyntaxIndexDigest
        let capabilities = CapabilityProfile(records: Dictionary(uniqueKeysWithValues: ["apple.entity.query", "apple.intent.invoke", "apple.codec.entity"].map {
            ($0, .init(state: .available, reason: "synthetic route", probeVersion: "test", evidence: []))
        }))
        var approval = RunApproval(runID: "qualify", app: prepared.host.app, target: prepared.host.target,
            environmentID: "selected-mac-session:synthetic-login", effects: [.observe, .navigate, .fixtureWrite], maximumActions: 30, disposable: true)
        var plan = try AutomationFreshEntityPlanner.compile(catalog: prepared.catalog, actionID: "Complete",
            instruction: "Create using approvedText", endpoint: "Tasks", namePrefix: "Invoice", nameProperty: "title", stateProperty: "completed",
            initialState: false, expectedState: true, approval: approval, capabilities: capabilities, localeIdentifier: "en_GB", purpose: .nativeMacDraft)
        plan.preparedMacBuildArtifacts = try .init(prepared: prepared)
        plan.provenance["ui.privateMacReceiptSHA256"] = AutomationPrivateMacDaemonUnit.pinnedFillProgramReceiptSHA256
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let driver = FreshRecordPlanDriver(mode: mode), witness = MacFreshContextWitness()
        var dependencies = AutomationMacUIQualification.Dependencies(runtimeRoot: h.base.root,
            verifyRuntime: { _ in AutomationPrivateMacDaemonUnit.pinnedFillProgramReceiptSHA256 }, driver: { context in
                witness.check(state: context.state, leases: context.leases, budget: context.campaignBudget); return driver
            })
        dependencies.appleDriver = { context in
            witness.check(state: context.state, leases: context.leases, budget: context.campaignBudget); return driver
        }
        let root = h.base.root.appendingPathComponent("fresh-runner")
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: h.base.root,
            simulatorInventory: { _, _ in XCTFail("Mac fixture read simulator inventory"); return [] }, macQualification: dependencies)
        return .init(prepared: prepared, plan: plan, approval: approval, capabilities: capabilities, runner: runner, driver: driver, root: root)
    }
    func qualifyMacFresh(_ h: MacFreshHarness, plan: AutomationCase? = nil) async throws -> AutomationQualifiedFreshFixture {
        let plan = plan ?? h.plan; var approval = h.approval
        approval.app = plan.app; approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let bindings = try AutomationFreshEntityPlanner.bindings(plan: plan), budget = try AutomationCampaignBudget(limits: .firstCampaign)
        for id in ["first", "second"] {
            try await budget.reserveAttempt(id: id)
            let report = try await h.runner.run(prepared: h.prepared, plan: plan, approval: approval, capabilities: h.capabilities,
                attemptID: id, allowBootAndInstall: false, campaignBudget: budget, qualifyingFreshBindings: bindings)
            XCTAssertTrue(report.resourcesReleased); XCTAssertTrue(report.result.subjectCompleted)
            try await h.runner.validateFreshFixtureAttempt(bindings: bindings)
        }
        return try await h.runner.qualifyFreshFixture(bindings: bindings)
    }
    func testPreparedMacFreshQualificationAndCampaignUseLiveRuntimeBoundFixtures() async throws {
        let h = try await macFreshHarness(), token = try await qualifyMacFresh(h)
        XCTAssertEqual(token.qualificationAttemptIDs, ["first", "second"])
        XCTAssertEqual(token.context.target, h.prepared.host.target)
        XCTAssertEqual(token.context.uiRuntimeManifestDigest, AutomationPrivateMacDaemonUnit.pinnedFillProgramReceiptSHA256)
        let tracker = AutomationFreshFixtureTracker(fixture: token), frozen = try AutomationFrozenCase(plan: h.plan)
        let executor = AutomationApplicationCampaignExecutor(runner: h.runner, prepared: h.prepared, capabilities: h.capabilities, allowBootAndInstall: false)
        let report = try await executor.execute(frozen: frozen, approval: h.approval, attemptID: "campaign",
            budget: AutomationCampaignBudget(limits: .firstCampaign), fixtureTracker: tracker)
        XCTAssertEqual(report.result.summary, .passed); XCTAssertTrue(report.resourcesReleased)
        let leases = try AutomationDeviceLeaseManager(storeURL: h.root.appendingPathComponent("target-leases.json"))
        let absent = try await leases.campaignAbsent(target: h.plan.target); XCTAssertTrue(absent)
        let names = await h.driver.names; XCTAssertEqual(Set(names).count, 3)
    }
    func testMacFreshQualificationRejectsDuplicateAndCannotReusePriorAuthorityAfterFailure() async throws {
        let h = try await macFreshHarness(), bindings = try AutomationFreshEntityPlanner.bindings(plan: h.plan)
        _ = try await qualifyMacFresh(h)
        await h.driver.setReusedID("id-first")
        let rejected = try await h.runner.run(prepared: h.prepared, plan: h.plan, approval: h.approval, capabilities: h.capabilities,
            attemptID: "duplicate", allowBootAndInstall: false, qualifyingFreshBindings: bindings)
        XCTAssertEqual(rejected.result.summary, .invalidFixture); XCTAssertFalse(rejected.result.subjectDispatched)
        let invocations = await h.driver.invocations; XCTAssertEqual(invocations, 2)
        do { _ = try await h.runner.qualifyFreshFixture(bindings: bindings); XCTFail("Stale live attempts minted authority") } catch {}
    }
    func testMacFreshCampaignRejectsChangedHostCatalogRuntimeAndSessionBeforeInput() async throws {
        for mode in 0..<4 {
            let h = try await macFreshHarness(), token = try await qualifyMacFresh(h)
            var prepared = h.prepared, plan = h.plan, approval = h.approval
            switch mode {
            case 0: prepared.host.hostProductDigest = String(repeating: "f", count: 64); plan.provenance["apple.macHostProductDigest"] = prepared.host.hostProductDigest
            case 1: prepared.catalog.gaps.append("changed catalog")
            case 2: plan.provenance["ui.privateMacReceiptSHA256"] = AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256
            default: prepared.host.target.loginSession = "other-login"; plan.target = prepared.host.target; approval.target = plan.target
            }
            approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
            do {
                _ = try await h.runner.run(prepared: prepared, plan: plan, approval: approval, capabilities: h.capabilities,
                    attemptID: "changed", allowBootAndInstall: false, fixtureTracker: AutomationFreshFixtureTracker(fixture: token))
                XCTFail("Changed fixture context reached input")
            } catch {}
            let names = await h.driver.names; XCTAssertEqual(names.count, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("changed").path))
        }
    }
    func testPublicMacRunnerStillDeniesFreshQualificationBeforeInput() async throws {
        let h = try await macFreshHarness(), runner = try AutomationApplicationRunner(supportRoot: h.root.appendingPathComponent("public"), developerDirectory: h.root)
        do {
            _ = try await runner.run(prepared: h.prepared, plan: h.plan, approval: h.approval, capabilities: h.capabilities,
                attemptID: "denied", allowBootAndInstall: false, qualifyingFreshBindings: AutomationFreshEntityPlanner.bindings(plan: h.plan))
            XCTFail("Public unqualified Mac route activated")
        } catch {}
        let names = await h.driver.names; XCTAssertTrue(names.isEmpty)
    }

    func testPreparedMacFreshReproductionUsesFiveNewFixturesAndOriginalOracle() async throws {
        let h = try await macFreshHarness(mode: .noChange), token = try await qualifyMacFresh(h)
        let frozen = try AutomationFrozenCase(plan: h.plan), cases = try AutomationCaseStore(root: h.root.appendingPathComponent("Cases"))
        var approval = h.approval; approval.runID = "reproduce"
        let result = try await AutomationReproduction(cases: cases).run(frozen: frozen, originalAttemptID: "first", approval: approval,
            capabilities: h.capabilities, limits: .firstCampaign,
            executor: AutomationApplicationCampaignExecutor(runner: h.runner, prepared: h.prepared, capabilities: h.capabilities, allowBootAndInstall: false), fixture: token)
        XCTAssertEqual(result.attempts.count, 5); XCTAssertEqual(result.matchingFailures, 5)
        XCTAssertEqual(result.frozen.oracleDigest, frozen.oracleDigest)
        XCTAssertTrue(result.attempts.allSatisfy { $0.resourcesReleased && $0.result.summary == .assertionFailed })
        let names = await h.driver.names; XCTAssertEqual(Set(names).count, 7)
        XCTAssertFalse(result.attempts.contains { token.qualificationAttemptIDs.contains($0.attemptID) })
    }

    func testPreparedMacFreshFixComparisonUsesSeparatelyQualifiedRetainedProducts() async throws {
        let before = try await macFreshHarness(mode: .noChange), after = try await macFreshHarness(changedBuild: true)
        let baseline = try AutomationFrozenCase(plan: before.plan)
        let candidate = try AutomationFixContract.candidate(from: baseline, prepared: after.prepared)
        XCTAssertNotEqual(before.prepared.host.hostProductDigest, after.prepared.host.hostProductDigest)
        XCTAssertNotEqual(before.prepared.host.xctestrunDigest, after.prepared.host.xctestrunDigest)
        XCTAssertNotEqual(before.prepared.host.app.sourceSyntaxIndexDigest, after.prepared.host.app.sourceSyntaxIndexDigest)
        XCTAssertNotEqual(before.prepared.catalog.sourceGraphDigest, after.prepared.catalog.sourceGraphDigest)
        XCTAssertEqual(candidate.plan.preparedMacBuildArtifacts, try .init(prepared: after.prepared))
        let beforeFixture = try await qualifyMacFresh(before), afterFixture = try await qualifyMacFresh(after, plan: candidate.plan)
        var beforeApproval = before.approval; beforeApproval.runID = "before"
        var afterApproval = after.approval; afterApproval.runID = "after"; afterApproval.approvedCaseDigest = candidate.digest
        let cases = try AutomationCaseStore(root: before.root.appendingPathComponent("comparison"))
        let result = try await AutomationFixComparison(cases: cases).run(baseline: baseline, candidate: candidate, attemptsPerBuild: 2,
            beforeApproval: beforeApproval, afterApproval: afterApproval, beforeCapabilities: before.capabilities, afterCapabilities: after.capabilities,
            limits: .firstCampaign,
            beforeExecutor: AutomationApplicationCampaignExecutor(runner: before.runner, prepared: before.prepared, capabilities: before.capabilities, allowBootAndInstall: false),
            afterExecutor: AutomationApplicationCampaignExecutor(runner: after.runner, prepared: after.prepared, capabilities: after.capabilities, allowBootAndInstall: false),
            beforeFixture: beforeFixture, afterFixture: afterFixture)
        XCTAssertNil(result.stopReason); XCTAssertEqual(result.before.count, 2); XCTAssertEqual(result.after.count, 2)
        XCTAssertTrue(result.before.allSatisfy { $0.result.summary == .assertionFailed && $0.resourcesReleased })
        XCTAssertTrue(result.after.allSatisfy { $0.result.summary == .passed && $0.resourcesReleased })
        XCTAssertEqual(baseline.oracleDigest, candidate.oracleDigest)
        let beforeNames = await before.driver.names, afterNames = await after.driver.names
        XCTAssertEqual(Set(beforeNames).count, 4); XCTAssertEqual(Set(afterNames).count, 4)
    }

    func testVersionedMacComparisonRejectsChangedTemplateSchemaOracleAndConflictingEvidence() async throws {
        let before = try await macFreshHarness(), after = try await macFreshHarness(changedBuild: true)
        let baseline = try AutomationFrozenCase(plan: before.plan)
        for mode in 0..<3 {
            var prepared = after.prepared
            if mode == 0 { prepared.generatedHost.templateDigest = String(repeating: "f", count: 64) }
            if mode == 1 { prepared.catalog.entities?[0].properties["completed"] = "text" }
            if mode == 2 { prepared.catalog.systemActions[0].parameters[0].name = "other" }
            XCTAssertThrowsError(try AutomationFixContract.candidate(from: baseline, prepared: prepared))
        }
        let candidate = try AutomationFixContract.candidate(from: baseline, prepared: after.prepared)
        var changed = candidate.plan; changed.requirements[0].expected = .bool(false)
        XCTAssertThrowsError(try AutomationFixContract.validate(baseline: baseline, candidate: AutomationFrozenCase(plan: changed)))
        changed = candidate.plan; changed.provenance["apple.macHostProductDigest"] = after.prepared.host.hostProductDigest
        XCTAssertThrowsError(try AutomationFrozenCase(plan: changed))
        changed = candidate.plan; changed.preparedMacBuildArtifacts?.schemaVersion = 2
        XCTAssertThrowsError(try AutomationFrozenCase(plan: changed))
    }

    func testVersionedMacCandidateRejectsMismatchedArtifactBeforeAnyRouteInput() async throws {
        let before = try await macFreshHarness(), after = try await macFreshHarness(changedBuild: true)
        let baseline = try AutomationFrozenCase(plan: before.plan)
        let candidate = try AutomationFixContract.candidate(from: baseline, prepared: after.prepared)
        for mode in 0..<3 {
            var plan = candidate.plan, approval = after.approval
            switch mode {
            case 0: plan.preparedMacBuildArtifacts?.hostProductDigest = String(repeating: "f", count: 64)
            case 1: plan.preparedMacBuildArtifacts?.xctestrunDigest = String(repeating: "f", count: 64)
            default: plan.preparedMacBuildArtifacts?.catalogDigest = String(repeating: "f", count: 64)
            }
            approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
            do {
                _ = try await after.runner.run(prepared: after.prepared, plan: plan, approval: approval, capabilities: after.capabilities,
                    attemptID: "mismatch-" + String(mode), allowBootAndInstall: false)
                XCTFail("Mismatched artifact reached a route")
            } catch {}
        }
        let names = await after.driver.names; XCTAssertTrue(names.isEmpty)
    }

    func testLegacyMacFrozenCaseKeepsStrictProjectionAndOmitsNewOptionalField() async throws {
        let h = try await macFreshHarness(); var plan = h.plan
        plan.preparedMacBuildArtifacts = nil
        plan.provenance["apple.macHostProductDigest"] = h.prepared.host.hostProductDigest
        plan.provenance["apple.macXctestrunDigest"] = h.prepared.host.xctestrunDigest
        let frozen = try AutomationFrozenCase(plan: plan)
        let encoded = try AutomationFrozenCase.canonicalData(plan)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["preparedMacBuildArtifacts"])
        var projection = plan; projection.revision = 1
        projection.app.canonicalBundlePath = nil; projection.app.productDigest = nil; projection.app.productDigestVersion = nil
        projection.app.codeDirectoryIdentity = nil; projection.app.sourceManifestDigest = nil; projection.app.provenanceStrength = "comparisonContract"
        XCTAssertEqual(frozen.contractDigest, AutomationArtifactRegistry.digest(try AutomationFrozenCase.canonicalData(projection)))
        let decoded = try JSONDecoder().decode(AutomationFrozenCase.self, from: AutomationFrozenCase.canonicalData(frozen))
        try decoded.validate(); XCTAssertEqual(decoded.digest, frozen.digest)
        XCTAssertThrowsError(try AutomationFixContract.candidate(from: frozen, prepared: h.prepared))
    }
}
#endif
