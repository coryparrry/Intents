import XCTest
@testable import IntentsAutomationCore

final class AutomationFreshFixtureTests: XCTestCase, @unchecked Sendable {
    func testFixtureQualificationRejectsExplicitCodecVetoAndConsentBeforeMutation() throws {
        let fixture = try FreshFixtureTestData()
        for state in [CapabilityProfile.State.unavailable, .consentRequired] {
            var capabilities = syntheticEntityCodecCapabilities
            capabilities.records["apple.codec.entity"] = .init(state: state, reason: "Explicit campaign restriction",
                probeVersion: "test", evidence: [])
            XCTAssertThrowsError(try AutomationQualifiedFreshFixture.validateProposal(bindings: fixture.bindings,
                plan: fixture.plan, approval: fixture.approval, capabilities: capabilities))
        }
    }
    func testTwoFreshLiveAttemptsQualifyDespiteAnActualBusinessFailure() throws {
        let fixture = try FreshFixtureTestData()
        let token = try fixture.qualify()
        XCTAssertEqual(token.qualificationAttemptIDs.count, 2)
        XCTAssertEqual(token.qualificationReportDigests.count, 2)
        try token.validate(plan: fixture.plan, approval: fixture.approval)
        var plan = fixture.plan; plan.setup[0].uiProgram?.bindings["title"] = "Other title"
        XCTAssertThrowsError(try token.validate(plan: plan, approval: fixture.approval))
        plan = fixture.plan; plan.app.productDigest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try token.validate(plan: plan, approval: fixture.approval))
    }
    func testChangedHostCatalogAndRuntimeFailPreflightBeforeAnyFreshnessReservation() async throws {
        let fixture = try FreshFixtureTestData(), token = try fixture.qualify()
        let tracker = AutomationFreshFixtureTracker(fixture: token)
        for flag in 0..<3 {
            let context = AutomationRecipeContext(app: token.context.app, target: token.context.target, environmentID: token.context.environmentID,
                catalogDigest: flag == 0 ? String(repeating: "f", count: 64) : token.context.catalogDigest,
                hostDigest: flag == 1 ? String(repeating: "f", count: 64) : token.context.hostDigest,
                localeIdentifier: token.context.localeIdentifier,
                uiRuntimeManifestDigest: flag == 2 ? String(repeating: "f", count: 64) : token.context.uiRuntimeManifestDigest)
            do { try await tracker.preflight(context: context, plan: fixture.plan, approval: fixture.approval); XCTFail("Changed execution context accepted") } catch { }
        }
        try await tracker.preflight(context: token.context, plan: fixture.plan, approval: fixture.approval)
        let report = fixture.report(id: "fresh", prefix: "fresh", completed: false)
        try await tracker.reserveBeforeSubject(receipts: Array(report.receipts.prefix(2)), plan: fixture.plan, approval: fixture.approval, attemptID: report.attemptID)
    }
    func testRepeatedIdentitiesIncompleteForeignAndUnapprovedEvidenceNeverQualify() throws {
        let fixture = try FreshFixtureTestData()
        for flag in 0..<7 {
            let originalFirst = fixture.evidence(id: "first", prefix: "one"), originalSecond = fixture.evidence(id: "second", prefix: flag == 0 ? "one" : "two")
            var firstApproval = originalFirst.approval, secondApproval = originalSecond.approval
            var secondReport = originalSecond.report
            switch flag {
            case 0: break
            case 1: secondReport.resourcesReleased = false
            case 2: secondReport.receipts[1].environmentID = "foreign"
            case 3: secondApproval.approvedCaseDigest = nil
            case 4: secondReport.result.subjectDispatchUncertain = true
            case 5: firstApproval.disposable = false
            default: secondReport.receipts[1].verifiedOutputs = ["tasks": .array([])]
            }
            let first = AutomationLiveRecipeEvidence(context: originalFirst.context, plan: originalFirst.plan, approval: firstApproval, report: originalFirst.report)
            let second = AutomationLiveRecipeEvidence(context: originalSecond.context, plan: originalSecond.plan, approval: secondApproval, report: secondReport)
            XCTAssertThrowsError(try AutomationQualifiedFreshFixture(bindings: fixture.bindings, evidence: [first, second]))
        }
        XCTAssertThrowsError(try AutomationQualifiedFreshFixture(bindings: Array(fixture.bindings.prefix(1)), evidence: [fixture.evidence(id: "first", prefix: "one"), fixture.evidence(id: "second", prefix: "two")]))
    }
    func testUnboundAdditionalMutationAndMutatingSetupIntentCannotBeQualified() throws {
        let original = try FreshFixtureTestData()
        for flag in 0..<3 {
            var plan = original.plan
            if flag == 0 { plan.execution.hostProgram?.operations.append(.init(id: "reset-all", kind: .invoke, typeID: "ResetAllTasks", resultCodec: "noValue")) }
            else if flag == 1 {
                var mutation = AutomationSegment(id: "unbound-reset", kind: .systemIntent, phase: .setup, operation: "ResetAllTasks", effects: [.fixtureWrite], lifecycle: .persistedStateAcrossSegments)
                mutation.hostProgram = .init(operations: [.init(id: "reset", kind: .invoke, typeID: "ResetAllTasks", resultCodec: "noValue")])
                plan.setup.insert(mutation, at: 1)
            }
            else { plan.execution.hostProgram?.operations[0].parameters["task"] = .entity(typeID: "TaskEntity", value: "old-id") }
            let fixture = try FreshFixtureTestData(plan: plan)
            XCTAssertThrowsError(try fixture.qualify())
            XCTAssertThrowsError(try AutomationQualifiedFreshFixture.validateProposal(bindings: fixture.bindings, plan: fixture.plan, approval: fixture.approval, capabilities: syntheticEntityCodecCapabilities))
        }
    }
    func testQualificationProposalRejectsEmptyBindingsExternalWritesAndMissingDisposableApproval() throws {
        let fixture = try FreshFixtureTestData()
        try AutomationQualifiedFreshFixture.validateProposal(bindings: fixture.bindings, plan: fixture.plan, approval: fixture.approval, capabilities: syntheticEntityCodecCapabilities)
        XCTAssertThrowsError(try AutomationQualifiedFreshFixture.validateProposal(bindings: [], plan: fixture.plan, approval: fixture.approval, capabilities: syntheticEntityCodecCapabilities))
        XCTAssertThrowsError(try AutomationQualifiedFreshFixture.validateProposal(bindings: fixture.bindings + [fixture.bindings[0]], plan: fixture.plan, approval: fixture.approval, capabilities: syntheticEntityCodecCapabilities))
        var approval = fixture.approval; approval.disposable = false
        XCTAssertThrowsError(try AutomationQualifiedFreshFixture.validateProposal(bindings: fixture.bindings, plan: fixture.plan, approval: approval, capabilities: syntheticEntityCodecCapabilities))
        var plan = fixture.plan; plan.execution.effects.insert(.externalWrite)
        approval = fixture.approval; approval.effects.insert(.externalWrite); approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertThrowsError(try AutomationQualifiedFreshFixture.validateProposal(bindings: fixture.bindings, plan: plan, approval: approval, capabilities: syntheticEntityCodecCapabilities))
        plan = fixture.plan; plan.provenance["ui.locale"] = String(repeating: "x", count: 129)
        approval = fixture.approval; approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        XCTAssertThrowsError(try AutomationQualifiedFreshFixture.validateProposal(bindings: fixture.bindings, plan: plan, approval: approval, capabilities: syntheticEntityCodecCapabilities))
        var first = fixture.evidence(id: "first", prefix: "first").report
        first.receipts[1].environmentID = "foreign"
        let original = fixture.evidence(id: "first", prefix: "first")
        XCTAssertThrowsError(try AutomationQualifiedFreshFixture.validateLiveAttempt(bindings: fixture.bindings,
            evidence: .init(context: original.context, plan: original.plan, approval: original.approval, report: first)))
    }
    func testFreshnessReservationsRejectPriorAndDuplicateRecordsBeforeSubjectAcquisition() async throws {
        let fixture = try FreshFixtureTestData(), token = try fixture.qualify()
        let tracker = AutomationFreshFixtureTracker(fixture: token)
        let first = fixture.report(id: "new-first", prefix: "new", completed: false)
        try await tracker.reserveBeforeSubject(receipts: Array(first.receipts.prefix(2)), plan: fixture.plan, approval: fixture.approval, attemptID: first.attemptID)
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let leases = AutomationDeviceLeaseManager()
        let coordinator = AutomationCoordinator(leases: leases, journal: try AutomationJournal(url: directory.appendingPathComponent("journal.json")))
        let driver = FreshFixtureTestDriver(data: fixture, prefix: "new")
        let report = try await coordinator.run(plan: fixture.plan, approval: fixture.approval, capabilities: syntheticEntityCodecCapabilities, attemptID: "repeated", driver: driver, fixtureTracker: tracker)
        XCTAssertEqual(report.result.summary, .invalidFixture)
        XCTAssertFalse(report.result.subjectDispatched); XCTAssertTrue(report.resourcesReleased)
        let subjects = await driver.subjectAcquisitions; XCTAssertEqual(subjects, 0)
        XCTAssertEqual(report.receipts.count, 2)
    }
    func testReproductionRejectsOriginalFailureIdentitiesBeforeSubjectAcquisition() async throws {
        let fixture = try FreshFixtureTestData(), token = try fixture.qualify(prefix: "new-qualification")
        let original = fixture.report(id: "original-failure", prefix: "historical", completed: false)
        let originalIDs = try token.identities(receipts: Array(original.receipts.prefix(2)), plan: fixture.plan,
            approval: fixture.approval, attemptID: original.attemptID)
        XCTAssertTrue(token.qualifiedEntityIDs.isDisjoint(with: originalIDs))
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let frozen = try AutomationFrozenCase(plan: fixture.plan), cases = try AutomationCaseStore(root: root)
        _ = try await cases.freeze(fixture.plan); try await cases.saveAttempt(original, for: frozen)
        let driver = FreshFixtureTestDriver(data: fixture, prefix: "historical")
        let executor = ReproductionGuardedFixtureExecutor(driver: driver,
            coordinator: AutomationCoordinator(leases: .init(), journal: try .init(url: root.appendingPathComponent("journal.json"))))
        let result = try await AutomationReproduction(cases: cases).run(frozen: frozen, originalAttemptID: original.attemptID,
            approval: fixture.approval, capabilities: syntheticEntityCodecCapabilities, limits: .firstCampaign, executor: executor, fixture: token)
        XCTAssertEqual(result.attempts.count, 1); XCTAssertEqual(result.attempts.first?.result.summary, .invalidFixture)
        XCTAssertFalse(result.attempts.first?.result.subjectDispatched ?? true)
        XCTAssertTrue(result.attempts.first?.resourcesReleased ?? false)
        XCTAssertFalse(result.complete); XCTAssertFalse(result.reproduced)
        let subjects = await driver.subjectAcquisitions; XCTAssertEqual(subjects, 0)
    }
    func testHistoricalReproductionArchiveRejectsOriginalAndPopulationFixtureReuse() async throws {
        for reuseOriginal in [true, false] {
            let fixture = try FreshFixtureTestData()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let cases = try AutomationCaseStore(root: root), frozen = try await cases.freeze(fixture.plan)
            let original = fixture.report(id: "original", prefix: "original", completed: false)
            try await cases.saveAttempt(original, for: frozen)
            var report = AutomationReproductionReport(frozen: frozen, runID: fixture.approval.runID, originalFailure: original)
            for index in 0..<5 {
                let prefix = index == 4 ? (reuseOriginal ? "original" : "fresh-0") : "fresh-" + String(index)
                let attempt = fixture.report(id: "attempt-" + String(index), prefix: prefix, completed: false)
                try await cases.saveAttempt(attempt, for: frozen); report.record(attempt)
            }
            report.usage.attempts = 5
            XCTAssertThrowsError(try report.validate())
            let archive = try AutomationReproductionArchive(caseStoreRoot: root)
            do { try await archive.save(report); XCTFail("Repeated fixture identities were archived as fresh reproduction") } catch {}
        }
    }
    func testMutatingComparisonRequiresBothBuildQualificationsAndRetainsFreshPopulations() async throws {
        let before = try FreshFixtureTestData()
        let baseline = try AutomationFrozenCase(plan: before.plan)
        var app = before.plan.app; app.productDigest = String(repeating: "b", count: 64)
        let candidate = try AutomationFixContract.candidate(from: baseline, app: app)
        let after = try FreshFixtureTestData(plan: candidate.plan, runID: "after")
        let beforeToken = try before.qualify(), afterToken = try after.qualify(prefix: "after")
        let store = try AutomationCaseStore(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
        let comparison = AutomationFixComparison(cases: store)
        let beforeExecutor = FreshFixtureTestExecutor(completed: false), afterExecutor = FreshFixtureTestExecutor(completed: true)
        do {
            _ = try await comparison.run(baseline: baseline, candidate: candidate, attemptsPerBuild: 2,
                beforeApproval: before.approval, afterApproval: after.approval, beforeCapabilities: syntheticEntityCodecCapabilities, afterCapabilities: syntheticEntityCodecCapabilities, limits: .init(),
                beforeExecutor: beforeExecutor, afterExecutor: afterExecutor, beforeFixture: beforeToken, afterFixture: beforeToken)
            XCTFail("Borrowed before-build qualification accepted")
        } catch { }
        let result = try await comparison.run(baseline: baseline, candidate: candidate, attemptsPerBuild: 2,
            beforeApproval: before.approval, afterApproval: after.approval, beforeCapabilities: syntheticEntityCodecCapabilities, afterCapabilities: syntheticEntityCodecCapabilities, limits: .init(),
            beforeExecutor: beforeExecutor, afterExecutor: afterExecutor, beforeFixture: beforeToken, afterFixture: afterToken)
        XCTAssertEqual(result.beforeCounters.failed, 2); XCTAssertEqual(result.afterCounters.assessed, 2)
        XCTAssertEqual(result.afterCounters.failed, 0); XCTAssertNil(result.stopReason)
        XCTAssertFalse(result.environmentQualificationComplete)
    }
    func testMutationSearchCannotUseAnAdvertisedCapabilityInsteadOfLiveQualification() async throws {
        let data = try FreshFixtureTestData(), frozen = try AutomationFrozenCase(plan: data.plan)
        let approval = AutomationSearchApproval(run: data.approval, approvedDigests: [frozen.digest], freshFixtureCapability: "fixture.fresh")
        let capabilities = CapabilityProfile(records: ["fixture.fresh": .init(state: .available, reason: "Test declaration alone", probeVersion: "test", evidence: [])])
        let store = try AutomationCaseStore(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
        do { _ = try await AutomationFailureSearch(cases: store).run(baseline: frozen, mutations: [], approval: approval, capabilities: capabilities, executor: FreshFixtureTestExecutor(completed: true)); XCTFail("Unqualified capability accepted") } catch { }
    }
    func testLiveQualifiedSearchConfirmsAllFiveFailuresAndRetainsFinalReproduction() async throws {
        let data = try FreshFixtureTestData(), frozen = try AutomationFrozenCase(plan: data.plan), token = try data.qualify()
        let approval = AutomationSearchApproval(run: data.approval, approvedDigests: [frozen.digest], qualifiedFixtures: [frozen.digest: token])
        let store = try AutomationCaseStore(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
        let report = try await AutomationFailureSearch(cases: store).run(baseline: frozen, mutations: [], approval: approval, capabilities: syntheticEntityCodecCapabilities, executor: FreshFixtureTestExecutor(completed: false))
        XCTAssertEqual(report.attempts.count, 13)
        XCTAssertEqual(report.confirmations.first?.matchingFailures, 5)
        XCTAssertEqual(report.finalReproduction?.matchingFailures, 5)
        XCTAssertEqual(report.usage.reservedSubjectOperations, 13)
        XCTAssertTrue(report.interruptions.isEmpty)
    }
}

extension AutomationFreshFixtureTests {
    private func learnedFixture() throws -> FreshFixtureTestData {
        var plan = try FreshFixtureTestData().plan
        plan.setup[0].uiProgram = .init(operations: [.init(id: "create", kind: .navigateGoal,
            goal: .init(id: "create", instruction: "Create", endpoint: .init(.testId, "done")))], bindings: ["title": "Send invoice"])
        return try .init(plan: plan)
    }
    private func learnedAttempt(_ fixture: FreshFixtureTestData, id: String, prefix: String,
                                locator: String = "task.title") throws -> AutomationCapturedSetupAttempt {
        let live = fixture.evidence(id: id, prefix: prefix)
        let capture = AutomationControllerSetupCapture(scope: live.report.receipts[0].scope, operations: [
            .init(id: "learned.0", kind: .fillBinding, locator: .init(.testId, locator), binding: "title"),
            .init(id: "learned.endpoint", kind: .assertEndpoint, locator: .init(.testId, "done"))])
        return try .init(live: live, capture: capture, bindings: fixture.bindings)
    }
    private func learnedOwnerFixture() throws -> FreshFixtureTestData {
        var plan = try learnedFixture().plan
        plan.setup[0].uiProgram?.operations[0].goal?.allowedFillBindings = ["title"]
        plan.setup[0].uiProgram?.bindings["ownerChoice"] = "Work"
        return try .init(plan: plan)
    }
    private func learnedOwnerAttempt(_ fixture: FreshFixtureTestData, id: String,
                                     locator: AutomationUIProgram.Locator = .init(.label, "Work", role: .button)) throws -> AutomationCapturedSetupAttempt {
        let original = try learnedAttempt(fixture, id: id, prefix: id)
        var operations = original.capture.operations
        operations.insert(.init(id: "learned.1", kind: .tap, locator: locator), at: 1)
        return try .init(live: original.live, capture: .init(scope: original.capture.scope, operations: operations), bindings: original.bindings)
    }
    func testLearnedOwnerButtonUsesCheckedNonFillContextWithoutChangingOracle() throws {
        let fixture = try learnedOwnerFixture()
        let attempts = try ["one", "two"].map { try learnedOwnerAttempt(fixture, id: $0) }
        let recipe = try AutomationQualifiedNavigationSetupRecipe(attempts: attempts)
        let proposal = try recipe.propose(plan: fixture.plan, context: attempts[0].live.context)
        XCTAssertEqual(proposal.setup[0].uiProgram?.operations[1].locator, .init(.label, "Work", role: .button))
        XCTAssertEqual(proposal.execution, fixture.plan.execution)
        XCTAssertEqual(proposal.setupChecks, fixture.plan.setupChecks)
        XCTAssertEqual(proposal.observations, fixture.plan.observations)
        XCTAssertEqual(proposal.requirements, fixture.plan.requirements)
        XCTAssertThrowsError(try PlanValidator.validate(proposal, approval: fixture.approval, capabilities: syntheticEntityCodecCapabilities))
        var changed = fixture.plan; changed.setup[0].uiProgram?.bindings["ownerChoice"] = "Personal"
        XCTAssertThrowsError(try recipe.propose(plan: changed, context: attempts[0].live.context))
    }
    func testLearningLastGoalPreservesEarlierGoalAndWholeFixtureApproval() throws {
        var plan = try learnedOwnerFixture().plan
        var second = plan.setup[0]; second.id = "create-protected"
        plan.setup[0].uiProgram?.bindings["ownerChoice"] = "Personal"
        plan.setup.insert(second, at: 1)
        let fixture = try FreshFixtureTestData(plan: plan)
        let attempts = try ["one", "two"].map { id -> AutomationCapturedSetupAttempt in
            let original = try learnedOwnerAttempt(fixture, id: id)
            let scope = try XCTUnwrap(original.live.report.receipts.first { $0.segmentID == second.id }?.scope)
            return try .init(live: original.live,
                capture: .init(scope: scope, operations: original.capture.operations), bindings: original.bindings)
        }
        let recipe = try AutomationQualifiedNavigationSetupRecipe(attempts: attempts)
        let proposal = try recipe.propose(plan: plan, context: attempts[0].live.context)
        XCTAssertEqual(proposal.setup[0], plan.setup[0])
        XCTAssertEqual(proposal.execution, plan.execution)
        XCTAssertEqual(proposal.setupChecks, plan.setupChecks)
        XCTAssertEqual(proposal.requirements, plan.requirements)
        XCTAssertEqual(proposal.observations, plan.observations)
        XCTAssertNotEqual(proposal.setup[1].uiProgram, plan.setup[1].uiProgram)
        XCTAssertThrowsError(try PlanValidator.validate(proposal, approval: fixture.approval, capabilities: syntheticEntityCodecCapabilities))
        var changed = plan; changed.setup[0].uiProgram?.bindings["ownerChoice"] = "Other"
        XCTAssertThrowsError(try recipe.propose(plan: changed, context: attempts[0].live.context))
    }
    func testReleasedCaptureSelectionRequiresOneExactScope() {
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "second", leaseGeneration: 2)
        let other = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "first", leaseGeneration: 1)
        let capture = AutomationControllerSetupCapture(scope: scope, operations: [])
        let earlier = AutomationControllerSetupCapture(scope: other, operations: [])
        XCTAssertEqual(AutomationControllerSetupCapture.unique([earlier, capture], scope: scope)?.scope, scope)
        XCTAssertNil(AutomationControllerSetupCapture.unique([earlier], scope: scope))
        XCTAssertNil(AutomationControllerSetupCapture.unique([capture, capture], scope: scope))
        let foreign = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "second", leaseGeneration: 3)
        XCTAssertNil(AutomationControllerSetupCapture.unique([capture], scope: foreign))
    }
    func testLearnedOwnerContextCannotBecomeAnIdentifierPartialLabelOrUnqualifiedTap() throws {
        let fixture = try learnedOwnerFixture()
        for locator in [AutomationUIProgram.Locator(.testId, "Work"), .init(.label, "Work folder", role: .button), .init(.label, "Work")] {
            let attempts = try ["one", "two"].map { try learnedOwnerAttempt(fixture, id: $0, locator: locator) }
            XCTAssertThrowsError(try AutomationQualifiedNavigationSetupRecipe(attempts: attempts))
        }
    }
    func testLearnedOwnerContextStillRejectsFillableLegacyAndUnrelatedLiteralInputs() throws {
        for variant in 0..<3 {
            var plan = try learnedOwnerFixture().plan
            switch variant {
            case 0: plan.setup[0].uiProgram?.operations[0].goal?.allowedFillBindings = nil
            case 1: plan.setup[0].uiProgram?.operations[0].goal?.allowedFillBindings = ["title", "ownerChoice"]
            default: plan.setup[0].uiProgram?.bindings["ownerChoice"] = "Private project"
            }
            let fixture = try FreshFixtureTestData(plan: plan)
            let label = variant == 2 ? "Private project" : "Work"
            let attempts = try ["one", "two"].map { try learnedOwnerAttempt(fixture, id: $0, locator: .init(.label, label, role: .button)) }
            XCTAssertThrowsError(try AutomationQualifiedNavigationSetupRecipe(attempts: attempts))
        }
    }
    func testLearnedOwnerLabelCannotExemptAQueriedInstanceIdentifier() throws {
        let fixture = try learnedOwnerFixture()
        let attempts = try ["one", "two"].map { id -> AutomationCapturedSetupAttempt in
            let original = try learnedOwnerAttempt(fixture, id: id)
            var report = original.live.report
            if case .array(var records) = report.receipts[1].verifiedOutputs?["tasks"] {
                records.append(.object(["entity": .entity(typeID: "TaskEntity", value: "Work"),
                    "properties": .object(["title": .text("Another record"), "owner": .text("Other"), "completed": .bool(false)])]))
                report.receipts[1].verifiedOutputs?["tasks"] = .array(records)
            }
            return try .init(live: .init(context: original.live.context, plan: original.live.plan, approval: original.live.approval, report: report), capture: original.capture, bindings: original.bindings)
        }
        XCTAssertThrowsError(try AutomationQualifiedNavigationSetupRecipe(attempts: attempts))
    }
    func testLearnedOwnerLabelCannotExemptDeferredOrOtherSegmentBindings() throws {
        for variant in 0..<2 {
            var plan = try learnedOwnerFixture().plan
            if variant == 0 {
                plan.setup[0].attemptTextBindings = ["ownerChoice": "Owner"]
            } else {
                var other = AutomationSegment(id: "other-navigation", kind: .ui, phase: .setup,
                    operation: "other-navigation", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
                other.uiProgram = .init(operations: [.init(id: "open", kind: .tap,
                    locator: .init(.testId, "other.navigation"))], bindings: ["privateValue": "Work"])
                plan.setup.insert(other, at: 1)
            }
            let fixture = try FreshFixtureTestData(plan: plan)
            if variant == 0 {
                // Static and deferred values cannot occupy the same binding.
                XCTAssertThrowsError(try learnedOwnerAttempt(fixture, id: "one"))
                continue
            }
            let attempts = try ["one", "two"].map { try learnedOwnerAttempt(fixture, id: $0) }
            XCTAssertThrowsError(try AutomationQualifiedNavigationSetupRecipe(attempts: attempts))
        }
    }
    func testLearnedProposalPreservesOracleAndNeedsNewApprovalAndFreshQualification() throws {
        let fixture = try learnedFixture()
        let attempts = try [learnedAttempt(fixture, id: "one", prefix: "one"), learnedAttempt(fixture, id: "two", prefix: "two")]
        let recipe = try AutomationQualifiedNavigationSetupRecipe(attempts: attempts)
        let proposal = try recipe.propose(plan: fixture.plan, context: attempts[0].live.context)
        XCTAssertEqual(proposal.setup[1], fixture.plan.setup[1]); XCTAssertEqual(proposal.execution, fixture.plan.execution)
        XCTAssertEqual(proposal.setupChecks, fixture.plan.setupChecks); XCTAssertEqual(proposal.requirements, fixture.plan.requirements)
        XCTAssertEqual(proposal.observations, fixture.plan.observations)
        XCTAssertNotEqual(try AutomationFrozenCase.planDigest(proposal), fixture.approval.approvedCaseDigest)
        XCTAssertThrowsError(try PlanValidator.validate(proposal, approval: fixture.approval, capabilities: syntheticEntityCodecCapabilities))
        let oldFixture = try fixture.qualify()
        XCTAssertThrowsError(try oldFixture.validate(plan: proposal, approval: fixture.approval))
    }
    func testLearnedProposalRejectsAPlanWithForeignIdentityEvenWithOriginalContext() throws {
        let fixture = try learnedFixture()
        let attempts = try [learnedAttempt(fixture, id: "one", prefix: "one"), learnedAttempt(fixture, id: "two", prefix: "two")]
        let recipe = try AutomationQualifiedNavigationSetupRecipe(attempts: attempts)
        for variant in 0..<4 {
            var foreign = fixture.plan
            switch variant {
            case 0: foreign.app.bundleID = "example.Foreign"
            case 1: foreign.target.id = "foreign-target"
            case 2: foreign.environmentID = "foreign-environment"
            default: foreign.provenance["ui.locale"] = "foreign-locale"
            }
            XCTAssertThrowsError(try recipe.propose(plan: foreign, context: attempts[0].live.context))
        }
    }
    func testLearnedSelectorsCannotCaptureUnselectedNestedQueryEntity() throws {
        let fixture = try learnedFixture()
        let attempts = try ["one", "two"].map { id -> AutomationCapturedSetupAttempt in
            let original = try learnedAttempt(fixture, id: id, prefix: id, locator: "task-row-existing-42")
            var report = original.live.report
            if case .array(var records) = report.receipts[1].verifiedOutputs?["tasks"] {
                records.append(.object(["entity": .entity(typeID: "TaskEntity", value: "existing-42"),
                    "properties": .object(["title": .text("Another record"), "owner": .text("Other"), "completed": .bool(false)])]))
                report.receipts[1].verifiedOutputs?["tasks"] = .array(records)
            }
            return try .init(live: .init(context: original.live.context, plan: original.live.plan, approval: original.live.approval, report: report), capture: original.capture, bindings: original.bindings)
        }
        XCTAssertThrowsError(try AutomationQualifiedNavigationSetupRecipe(attempts: attempts))
    }
    func testLearnedQualificationRejectsOneAttemptReusedEntitiesDifferentPathAndInstanceSelectors() throws {
        let fixture = try learnedFixture(), first = try learnedAttempt(fixture, id: "one", prefix: "one")
        XCTAssertThrowsError(try AutomationQualifiedNavigationSetupRecipe(attempts: [first]))
        XCTAssertThrowsError(try AutomationQualifiedNavigationSetupRecipe(attempts: [first, first]))
        XCTAssertThrowsError(try AutomationQualifiedNavigationSetupRecipe(attempts: [first, learnedAttempt(fixture, id: "two", prefix: "one")]))
        XCTAssertThrowsError(try AutomationQualifiedNavigationSetupRecipe(attempts: [first, learnedAttempt(fixture, id: "two", prefix: "two", locator: "other.title")]))
        for locator in ["Send invoice", "one-Personal", "element-12345678-1234-1234-1234-123456789abc"] {
            let attempts = try [learnedAttempt(fixture, id: "one", prefix: "one", locator: locator), learnedAttempt(fixture, id: "two", prefix: "two", locator: locator)]
            XCTAssertThrowsError(try AutomationQualifiedNavigationSetupRecipe(attempts: attempts))
        }
        var live = first.live.report; live.resourcesReleased = false
        XCTAssertThrowsError(try AutomationCapturedSetupAttempt(live: .init(context: first.live.context, plan: first.live.plan, approval: first.live.approval, report: live), capture: first.capture, bindings: first.bindings))
        let foreign = AutomationControllerSetupCapture(scope: .init(runID: "foreign", attemptID: "one", segmentID: "create", leaseGeneration: 1), operations: first.capture.operations)
        XCTAssertThrowsError(try AutomationCapturedSetupAttempt(live: first.live, capture: foreign, bindings: first.bindings))
    }
}

struct FreshFixtureTestData: Sendable {
    var plan: AutomationCase
    var approval: RunApproval
    var bindings: [AutomationFreshFixtureBinding]
    init(plan existing: AutomationCase? = nil, runID: String = "before") throws {
        let selection: (String) -> AutomationEntitySelection = { .init(typeID: "TaskEntity", matchingProperties: ["title": .text("Send invoice"), "owner": .text($0)]) }
        bindings = ["Personal", "Work"].map { .init(producerSegmentID: "lookup", outputID: "tasks", selection: selection($0)) }
        if let existing { plan = existing }
        else {
            let app = AppIdentity(logicalID: "fixture", bundleID: "example.Fixture", platform: "ios", productDigest: String(repeating: "a", count: 64))
            var ui = AutomationSegment(id: "create", kind: .ui, phase: .setup, operation: "create", effects: [.observe, .navigate, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
            ui.uiProgram = .init(operations: [.init(id: "fill", kind: .fillBinding, locator: .init(.testId, "title"), binding: "title")], bindings: ["title": "Send invoice"])
            var lookup = AutomationSegment(id: "lookup", kind: .systemQuery, phase: .setup, operation: "lookup", lifecycle: .persistedStateAcrossSegments)
            lookup.hostProgram = .init(operations: [.init(id: "tasks", kind: .query, typeID: "TaskEntity", queryText: "Send invoice", properties: ["title": "text", "owner": "text", "completed": "bool"])])
            var subject = AutomationSegment(id: "subject", kind: .systemIntent, phase: .subject, operation: "CompleteTaskIntent", effects: [.observe, .fixtureWrite], lifecycle: .persistedStateAcrossSegments)
            subject.hostProgram = .init(operations: [.init(id: "complete", kind: .invoke, typeID: "CompleteTaskIntent", resultCodec: "noValue")])
            subject.inputBindings = [.init(producerSegmentID: "lookup", outputID: "tasks", destination: .hostParameter, operationID: "complete", name: "task", uniqueEntity: selection("Personal"))]
            var observer = lookup; observer.id = "state"; observer.phase = .observe
            let check: (String, String, Bool) -> AutomationRequirement = { owner, source, value in
                .init(observationID: source, expected: .bool(value), proof: .appState, justification: "Unit positive owned record", checkID: source + "." + owner,
                      entityProperty: .init(operationID: "tasks", selection: selection(owner), property: "completed"))
            }
            plan = .init(id: "fresh-fixture", app: app, target: .init(id: "owned", kind: .simulator), environmentID: "unit",
                execution: subject, setup: [ui, lookup], observations: [observer], requirements: [check("Personal", "state", true), check("Work", "state", false)],
                setupChecks: [check("Personal", "lookup", false), check("Work", "lookup", false)])
            plan.provenance["ui.locale"] = "en_GB"
        }
        if !plan.execution.requiredCapabilities.contains("apple.codec.entity") { plan.execution.requiredCapabilities.append("apple.codec.entity") }
        approval = .init(runID: runID, app: plan.app, target: plan.target, environmentID: plan.environmentID,
            effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true, approvedCaseDigest: try AutomationFrozenCase.planDigest(plan))
    }
    func records(prefix: String, completed: Bool) -> AutomationValue {
        .array(["Personal", "Work"].map { owner in .object(["entity": .entity(typeID: "TaskEntity", value: prefix + "-" + owner),
            "properties": .object(["title": .text("Send invoice"), "owner": .text(owner), "completed": .bool(owner == "Personal" && completed)])]) })
    }
    func report(id: String, prefix: String, completed: Bool) -> AutomationAttemptReport {
        let observation = AutomationObservation(id: "state", app: plan.app, target: plan.target, environmentID: plan.environmentID, attemptID: id, stepID: "state", route: .systemQuery, proof: .appState, value: records(prefix: prefix, completed: completed))
        let segments = plan.setup + [plan.execution] + plan.observations
        let receipts = segments.enumerated().map { index, segment in AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: id, segmentID: segment.id, leaseGeneration: index + 1),
            app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind, dispatched: true, completed: true,
            observations: segment.id == "state" ? [observation] : [], verifiedOutputs: segment.id == "lookup" ? ["tasks": records(prefix: prefix, completed: false)] : nil, environmentID: plan.environmentID) }
        return .init(attemptID: id, result: AutomationAssessment.assess(plan: plan, attemptID: id, subjectDispatched: true, subjectCompleted: true, observations: [observation]), receipts: receipts, resourcesReleased: true)
    }
    func evidence(id: String, prefix: String) -> AutomationLiveRecipeEvidence {
        .init(context: .init(app: plan.app, target: plan.target, environmentID: plan.environmentID, catalogDigest: String(repeating: "c", count: 64), hostDigest: String(repeating: "d", count: 64), localeIdentifier: "en_GB", uiRuntimeManifestDigest: String(repeating: "e", count: 64)),
              plan: plan, approval: approval, report: report(id: id, prefix: prefix, completed: false))
    }
    func qualify(prefix: String = "qualification") throws -> AutomationQualifiedFreshFixture {
        try .init(bindings: bindings, evidence: [evidence(id: prefix + "1", prefix: prefix + "1"), evidence(id: prefix + "2", prefix: prefix + "2")])
    }
}

private actor FreshFixtureTestDriver: AutomationRouteDriver {
    var data: FreshFixtureTestData
    var prefix: String
    var subjectAcquisitions = 0
    init(data: FreshFixtureTestData, prefix: String) { self.data = data; self.prefix = prefix }
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws {
        if segment.phase == .subject { subjectAcquisitions += 1 }
    }
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        var receipt = data.report(id: scope.attemptId, prefix: prefix, completed: false).receipts.first { $0.segmentID == segment.id }!
        receipt.scope = scope; return receipt
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof { .init(commandsDrained: true, runnerTerminated: true) }
}

private struct ReproductionGuardedFixtureExecutor: AutomationFreshFixtureAttemptExecutor {
    let driver: FreshFixtureTestDriver
    let coordinator: AutomationCoordinator
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        throw AutomationContractError.missingEvidence("Fresh fixture path required")
    }
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget, fixtureTracker: AutomationFreshFixtureTracker) async throws -> AutomationAttemptReport {
        try await coordinator.run(plan: frozen.plan, approval: approval, capabilities: syntheticEntityCodecCapabilities, attemptID: attemptID,
            driver: driver, fixtureTracker: fixtureTracker)
    }
}
private struct FreshFixtureTestExecutor: AutomationFreshFixtureAttemptExecutor {
    let completed: Bool
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        XCTFail("Mutating campaign skipped the fresh-fixture path"); throw AutomationContractError.invalidIdentity
    }
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget, fixtureTracker: AutomationFreshFixtureTracker) async throws -> AutomationAttemptReport {
        let data = try FreshFixtureTestData(plan: frozen.plan, runID: approval.runID)
        let report = data.report(id: attemptID, prefix: attemptID, completed: completed)
        try await fixtureTracker.reserveBeforeSubject(receipts: Array(report.receipts.prefix(2)), plan: frozen.plan, approval: approval, attemptID: attemptID)
        try await budget.reserveOperations(id: attemptID + ".subject", phase: .subject, count: 1)
        return report
    }
}

private let syntheticEntityCodecCapabilities: CapabilityProfile = .init(records: ["apple.codec.entity": .init(state: .available, reason: "Synthetic driver conversion contract", probeVersion: "test", evidence: [])])
