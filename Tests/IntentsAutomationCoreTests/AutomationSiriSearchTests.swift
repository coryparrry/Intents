import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationSiriSearchTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (AutomationCase, RunApproval, CapabilityProfile, AutomationPreparedApplication) {
        let app = AppIdentity(logicalID: "subject", bundleID: "example.Subject", platform: "ios", productDigest: String(repeating: "a", count: 64))
        let target = TargetIdentity(id: "00008140-001049013EF3401C", kind: .physical)
        let reset = ApplicationSurfaceCatalog.SystemAction(id: "SetStateIntent", typeName: "SetStateIntent", title: "Set task state",
            parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity"), .init(name: "completed", family: "bool", optional: false)],
            parametersComplete: true, compiled: true, registered: true, executed: false, resultFamily: "noValue")
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [reset], systemDiscoveryComplete: false,
            uiDiscoveryComplete: false, gaps: [], entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery",
                properties: ["title": "text", "completed": "bool"], propertyTitles: [:])])
        var approval = RunApproval(runID: "run", app: app, target: target, environmentID: "physical:disposable-account",
            effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true)
        let capabilities = CapabilityProfile(records: Dictionary(uniqueKeysWithValues: ["apple.entity.query", "apple.intent.invoke", "apple.codec.bool", "apple.codec.entity", "siri.recognizedText.api"].map {
            ($0, CapabilityProfile.Record(state: .available, reason: "synthetic test", probeVersion: "test", evidence: []))
        }))
        let original = try AutomationSiriEntityPlanner.compile(catalog: catalog, entityType: "TaskEntity", nameProperty: "title",
            recordName: "Approved task", stateProperty: "completed", initialState: false, expectedState: true,
            request: "Complete Approved task in Example", approval: approval, capabilities: capabilities)
        let plan = try AutomationSiriRepeatableQualification.restoring(original, catalog: catalog, actionID: reset.id, approval: approval, capabilities: capabilities)
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        let host = AutomationPreparedAppleHost(app: app, target: target, xctestrunPath: "synthetic",
            xctestrunDigest: String(repeating: "b", count: 64), subjectProductPath: "synthetic", hostBundlePath: "synthetic",
            hostProductDigest: String(repeating: "c", count: 64), hostBundleID: "example.Host.xctrunner", testTarget: "Host")
        let prepared = AutomationPreparedApplication(source: .init(sourceRoot: "synthetic", files: [], directories: [], excludedPaths: []),
            generatedHost: .init(projectPath: "synthetic", scheme: "Host", targetID: "HOST", bundleID: host.hostBundleID,
                configuration: "Debug", templateDigest: String(repeating: "d", count: 64), includesSiri: true), host: host, catalog: catalog,
            buildLogPath: "synthetic", buildLogTruncated: false)
        return (plan, approval, capabilities, prepared)
    }
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        func now() -> ContinuousClock.Instant { lock.withLock { instant } }
        func expire() { lock.withLock { instant = instant.advanced(by: .seconds(1801)) } }
    }
    func testRepeatableReviewNeverGrantsAuthorityAndImportsCannotAdmitSearch() throws {
        let (plan, approval, capabilities, _) = try fixture()
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, purpose: .review)
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities))
        let historical = try JSONDecoder().decode(AutomationCase.self, from: JSONEncoder().encode(plan))
        XCTAssertThrowsError(try AutomationSiriRepeatableQualification.validate(plan: historical, approval: approval, authority: nil))
        let onePass = try AutomationSiriRouteAuthority(plan: plan, approval: approval, osBuild: "24B5028f", evidenceDigest: String(repeating: "e", count: 64))
        XCTAssertThrowsError(try AutomationSiriRepeatableQualification.validate(plan: historical, approval: approval, authority: onePass))
    }
    func testResetDeclaresRequiredConversionsAndCannotExecuteWithoutPhysicalQualification() throws {
        let (plan, approval, capabilities, _) = try fixture()
        XCTAssertEqual(Set(plan.setup[1].requiredCapabilities), ["apple.intent.invoke", "apple.codec.bool", "apple.codec.entity"])
        let authority = try AutomationSiriRouteAuthority(plan: plan, approval: approval)
        for capability in ["apple.intent.invoke", "apple.codec.bool", "apple.codec.entity"] {
            var unqualified = capabilities; unqualified.records.removeValue(forKey: capability)
            if capability.hasPrefix("apple.codec.") {
                try PlanValidator.validate(plan, approval: approval, capabilities: unqualified, purpose: .review)
            } else {
                XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: unqualified, purpose: .review))
            }
            XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: unqualified, siriAuthority: authority))
        }
    }
    func testExactAuthorityRejectsForeignCaseTargetEnvironmentPhraseAndExpiredClock() throws {
        let (plan, approval, capabilities, _) = try fixture()
        let clock = TestClock()
        let authority = try AutomationSiriRouteAuthority(plan: plan, approval: approval, osBuild: "24B5028f",
            evidenceDigest: String(repeating: "e", count: 64), repeatable: true, now: { clock.now() })
        try AutomationSiriRepeatableQualification.validate(plan: plan, approval: approval, authority: authority)
        try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, siriAuthority: authority)
        for index in 0..<4 {
            var changed = plan; var changedApproval = approval
            switch index {
            case 0: changed.execution.siriProgram = .init(request: "Finish Approved task in Example")
            case 1: changed.target = .init(id: "00008140-001049013EF3401D", kind: .physical); changedApproval.target = changed.target
            case 2: changed.environmentID = "another-account"; changedApproval.environmentID = changed.environmentID
            default: changed.app.bundleID = "example.Foreign"; changedApproval.app = changed.app
            }
            changedApproval.approvedCaseDigest = try AutomationFrozenCase.planDigest(changed)
            XCTAssertThrowsError(try PlanValidator.validate(changed, approval: changedApproval, capabilities: capabilities, siriAuthority: authority))
        }
        clock.expire()
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: capabilities, siriAuthority: authority))
    }
    func testRestorationCannotSwapEntityOrWidenResetEffectsOrState() throws {
        let (plan, approval, _, _) = try fixture()
        for index in 0..<5 {
            var changed = plan
            switch index {
            case 0: changed.setup[1].effects.insert(.externalWrite)
            case 1: changed.setup[1].hostProgram?.operations[0].parameters["completed"] = .bool(true)
            case 2: changed.setup[1].inputBindings = nil
            case 3: changed.setup[2].inputBindings = nil
            default: changed.setup[0].hostProgram?.operations[0].queryText = "Foreign record"
            }
            XCTAssertThrowsError(try AutomationSiriRepeatableQualification.validateStructure(plan: changed, approval: approval))
        }
    }
    #if os(macOS)
    private actor StopExecutor: AutomationCampaignAttemptExecutor {
        var count = 0
        func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String,
                     budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
            count += 1; throw AutomationContractError.missingEvidence("synthetic stop before dispatch")
        }
    }
    func testActualSearchAdmissionRequiresEachFrozenPhraseAuthority() async throws {
        let (plan, approval, capabilities, _) = try fixture()
        let baseline = try AutomationFrozenCase(plan: plan)
        let variant = try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .siriRecognizedText,
            request: "Finish Approved task in Example", semanticJustification: "Same operation on the same record")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = try AutomationCaseStore(root: root)
        let executor = StopExecutor()
        var search = AutomationSearchApproval(run: approval, approvedDigests: [baseline.digest, variant.frozen.digest], limits: .firstCampaign)
        search.qualifiedSiriAuthorities[baseline.digest] = try AutomationSiriRouteAuthority(plan: plan, approval: approval,
            osBuild: "24B5028f", evidenceDigest: String(repeating: "e", count: 64), repeatable: true)
        do { _ = try await AutomationFailureSearch(cases: cases).run(baseline: baseline, mutations: [variant], approval: search, capabilities: capabilities, executor: executor); XCTFail("Missing variant authority") } catch {}
        let before = await executor.count; XCTAssertEqual(before, 0)
        var scoped = approval; scoped.approvedCaseDigest = variant.frozen.digest
        search.qualifiedSiriAuthorities[variant.frozen.digest] = try AutomationSiriRouteAuthority(plan: variant.frozen.plan, approval: scoped,
            osBuild: "24B5028f", evidenceDigest: String(repeating: "f", count: 64), repeatable: true)
        let result = try await AutomationFailureSearch(cases: cases).run(baseline: baseline, mutations: [variant], approval: search, capabilities: capabilities, executor: executor)
        let after = await executor.count; XCTAssertEqual(after, 1)
        XCTAssertNotNil(result.stopReason); XCTAssertEqual(result.interruptions.count, 1)
    }
    func testEarlyOwnedQualificationInterruptionKeepsEveryDefinitionArchivable() async throws {
        let (plan, approval, capabilities, prepared) = try fixture()
        let baseline = try AutomationFrozenCase(plan: plan)
        let variant = try AutomationSubjectPhraseVariation.propose(baseline: baseline, slot: .siriRecognizedText,
            request: "Finish Approved task in Example", semanticJustification: "Same approved operation")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = try AutomationCaseStore(root: root.appendingPathComponent("Cases"))
        let runner = try AutomationApplicationRunner(supportRoot: root, developerDirectory: root)
        let search = AutomationSearchApproval(run: approval, approvedDigests: [baseline.digest, variant.frozen.digest], limits: .firstCampaign)
        // A synthetic unprepared host is denied by runtime-only codec authority before installation or device commands.
        let result = try await AutomationSiriSearchCampaign.run(baseline: baseline, mutations: [variant], approval: search,
            prepared: prepared, capabilities: capabilities, runner: runner, cases: cases)
        XCTAssertNotNil(result.stopReason); XCTAssertTrue(result.attempts.isEmpty)
        XCTAssertEqual(result.interruptions.count, 1); XCTAssertEqual(result.usage.attempts, 1)
        let savedVariant = try await cases.load(id: variant.frozen.plan.id, revision: variant.frozen.plan.revision, digest: variant.frozen.digest)
        XCTAssertEqual(savedVariant.plan, variant.frozen.plan)
        let archive = try AutomationUIFailureSearchArchive(caseStoreRoot: root.appendingPathComponent("Cases"))
        let record = AutomationUIFailureSearchRecord(id: "early-stop", runID: approval.runID, baseline: baseline, mutations: [variant], report: result)
        XCTAssertEqual(record.schemaVersion, 4)
        try await archive.save(record)
        let restored = try await archive.load(id: record.id); XCTAssertEqual(restored, record)
        XCTAssertThrowsError(try AutomationSiriRepeatableQualification.validate(plan: restored.baseline.plan, approval: approval, authority: nil))
    }
    func testTwoOwnedLiveQualificationsRequireKnownTextDistinctAttemptsAndSameDeviceState() async throws {
        let (plan, approval, _, prepared) = try fixture()
        func records(_ state: Bool) -> AutomationValue { .array([.object(["entity": .entity(typeID: "TaskEntity", value: "real-id"),
            "properties": .object(["title": .text("Approved task"), "completed": .bool(state)])])]) }
        func report(_ attemptID: String) -> AutomationAttemptReport {
            let observation = AutomationObservation(id: plan.observations[0].id, app: plan.app, target: plan.target,
                environmentID: plan.environmentID, attemptID: attemptID, stepID: plan.observations[0].id,
                route: .systemQuery, proof: .appState, value: records(true))
            let receipts = (plan.setup + [plan.execution] + plan.observations).enumerated().map { index, segment in
                AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: attemptID, segmentID: segment.id, leaseGeneration: index + 1),
                    app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind, dispatched: true, completed: true,
                    observations: segment.phase == .observe ? [observation] : [], artifact: segment.kind == .siriText ? "synthetic-artifact" : nil,
                    verifiedOutputs: segment.kind == .systemQuery ? ["record": records(segment.phase == .observe)] : nil, environmentID: plan.environmentID)
            }
            let result = AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: true, subjectCompleted: true,
                observations: [observation], receipts: receipts, runID: approval.runID)
            return .init(attemptID: attemptID, result: result, receipts: receipts, resourcesReleased: true)
        }
        let registry = AutomationSiriQualificationAuthority()
        var submission = AutomationImportedSiriSubmission(runner: .init(pid: 42, startIdentity: "1:2"), executablePath: "/synthetic",
            requestDigest: plan.execution.siriProgram!.requestDigest, osBuild: "24B5028f")
        do { try await registry.record(prepared: prepared, plan: plan, approval: approval, report: report("one"), submission: submission); XCTFail("Unknown text") } catch {}
        submission.submittedRecognizedText = plan.execution.siriProgram!.request
        try await registry.record(prepared: prepared, plan: plan, approval: approval, report: report("one"), submission: submission)
        let first = await registry.admission(prepared: prepared, plan: plan, approval: approval)
        XCTAssertFalse(try XCTUnwrap(first).isRepeatableQualification)
        do { try await registry.record(prepared: prepared, plan: plan, approval: approval, report: report("one"), submission: submission); XCTFail("Replayed attempt") } catch {}
        try await registry.record(prepared: prepared, plan: plan, approval: approval, report: report("two"), submission: submission)
        let second = await registry.admission(prepared: prepared, plan: plan, approval: approval)
        try AutomationSiriRepeatableQualification.validate(plan: plan, approval: approval, authority: second)
        await registry.revoke(prepared: prepared, plan: plan)
        let revoked = await registry.admission(prepared: prepared, plan: plan, approval: approval); XCTAssertNil(revoked)
    }
    #endif
}
