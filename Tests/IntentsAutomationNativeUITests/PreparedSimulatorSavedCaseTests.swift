#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

extension InstalledUIStoreTests {
    func testFailedSimulatorCandidateReopensAndReproducesAfterRestart() async throws {
        let (model, root, bundle) = try fixture()
        try selectPreparedSource(model: model, root: root)
        let before = try XCTUnwrap(model.prepared)
        let legacy = try await saveFailure(model: model, root: root, legacyPreparedEvidence: true)
        let cases = try AutomationCaseStore(root: model.support.appendingPathComponent("Cases"))
        let legacyAttempts = try await cases.attempts(for: legacy)
        let original = try XCTUnwrap(legacyAttempts.first)
        let runtime = AutomationNativeUIRuntime(runtime: .init(bundleURL: root, expectedTeamID: "AAAAAAAAAA"), manifestDigest: String(repeating: "a", count: 64))
        // Retained preparation fixture; no device execution or signed-runtime claim.
        var after = try changedPreparedSource(before)
        let session = model.support.appendingPathComponent("prepare-" + UUID().uuidString)
        let product = session.appendingPathComponent("DerivedData/Subject.app")
        try FileManager.default.createDirectory(at: product.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: bundle, to: product)
        after.host.app.canonicalBundlePath = product.path; after.host.subjectProductPath = product.path
        after.catalog.app = after.host.app
        try JSONEncoder().encode(after).write(to: session.appendingPathComponent("prepared-application.json"))
        let comparison = try AutomationNativeUIFixComparisonProposal.compile(frozen: legacy, original: original,
            before: .prepared(before), after: .prepared(after), runtime: runtime, runID: "comparison", disposable: false)
        XCTAssertEqual(comparison.baseline.plan.id, "comparison." + legacy.digest)
        XCTAssertEqual(comparison.baseline.plan.revision, 1)
        XCTAssertEqual(comparison.baseline.plan.provenance["comparison.sourceCaseDigest"], legacy.digest)
        XCTAssertEqual(comparison.candidate.plan.preparedSimulatorBuildArtifacts, try .init(prepared: after))
        XCTAssertTrue(AutomationNativeUIRuntime.preparedEvidenceMatches(plan: legacy.plan, prepared: before))
        XCTAssertFalse(AutomationNativeUIRuntime.preparedEvidenceMatches(plan: legacy.plan, prepared: after))
        try legacy.validate()
        let candidate = try await cases.freeze(comparison.candidate.plan)
        let failure = try await NativeSearchFactExecutor(fails: true).execute(frozen: candidate, approval: comparison.afterApproval,
            attemptID: "after-failure", budget: .init(limits: .firstCampaign))
        try await cases.saveAttempt(failure, for: candidate)
        model.prepared = after
        await model.showSavedCase(candidate)
        XCTAssertTrue(model.canReproduceSavedFailure)
        let restarted = AppAutomationStore(supportDirectory: model.support, uiRuntimeProvider: { runtime })
        restarted.intake = model.intake; restarted.candidateID = model.candidateID; restarted.configuration = model.configuration
        restarted.simulatorID = model.simulatorID; restarted.effectChoice = "navigation"; restarted.effectsConfirmed = true
        await restarted.showSavedCase(candidate)
        let retained = try XCTUnwrap(restarted.savedPreparedBaseline)
        XCTAssertEqual(retained, after)
        let reproduction = try AutomationNativeUIReproductionProposal.compile(frozen: candidate, original: failure,
            subject: .prepared(retained), runtime: runtime, runID: "reproduce-after", disposable: false)
        XCTAssertEqual(reproduction.frozen, candidate)
        XCTAssertEqual(reproduction.approval.app, after.host.app)
        XCTAssertThrowsError(try AutomationNativeUIReproductionProposal.compile(frozen: candidate, original: failure,
            subject: .prepared(before), runtime: runtime, runID: "wrong-build", disposable: false))
        let unchangedAttempts = try await cases.attempts(for: legacy)
        XCTAssertEqual(unchangedAttempts, [original])
        let unchangedLegacy = try await cases.load(id: legacy.plan.id, revision: legacy.plan.revision, digest: legacy.digest)
        XCTAssertEqual(unchangedLegacy, legacy)
    }

    func testTypedSimulatorComparisonVariesBuildSyntaxButFreezesSchemaTemplateRuntimeAndOracle() async throws {
        let (model, root, _) = try fixture()
        try selectPreparedSource(model: model, root: root)
        model.installApproved = true; model.uiExpectedText = "Complete"
        var before = try XCTUnwrap(model.prepared)
        before.host.app.sourceSyntaxIndexDigest = String(repeating: "5", count: 64)
        before.catalog.app = before.host.app; before.catalog.sourceSyntaxIndexDigest = before.host.app.sourceSyntaxIndexDigest
        model.prepared = before
        var plan = try model.makeUIRunRequest(runID: "typed").plan
        XCTAssertNotNil(plan.preparedSimulatorBuildArtifacts)
        XCTAssertNil(plan.provenance["ui.preparedHostDigest"])
        // Fresh plans use this exact per-build catalog field; only typed comparison contracts normalize it.
        plan.provenance["catalog"] = try AutomationRecipeContext.catalogDigest(before.catalog)
        let baseline = try AutomationFrozenCase(plan: plan)
        var after = try changedPreparedSource(before)
        after.host.app.sourceSyntaxIndexDigest = String(repeating: "6", count: 64)
        after.catalog.app = after.host.app; after.catalog.sourceSyntaxIndexDigest = after.host.app.sourceSyntaxIndexDigest
        after.catalog.gaps.append("Different source reconciliation diagnostic")
        let candidate = try AutomationFixContract.candidate(from: baseline, prepared: after)
        XCTAssertEqual(baseline.contractDigest, candidate.contractDigest)
        XCTAssertNotEqual(baseline.digest, candidate.digest)
        XCTAssertEqual(candidate.plan.provenance["catalog"], try AutomationRecipeContext.catalogDigest(after.catalog))
        XCTAssertTrue(AutomationNativeUIRuntime.preparedEvidenceMatches(plan: candidate.plan, prepared: after))
        let cases = try AutomationCaseStore(root: model.support.appendingPathComponent("Cases"))
        let savedCandidate = try await cases.freeze(candidate.plan)
        let approval = RunApproval(runID: "after-syntax", app: after.host.app, target: after.host.target,
            environmentID: candidate.plan.environmentID, effects: [.observe, .navigate], maximumActions: 30,
            disposable: false, approvedCaseDigest: candidate.digest)
        let failure = try await NativeSearchFactExecutor(fails: true).execute(frozen: savedCandidate, approval: approval,
            attemptID: "after-syntax-failure", budget: .init(limits: .firstCampaign))
        try await cases.saveAttempt(failure, for: savedCandidate)
        model.prepared = after
        await model.showSavedCase(savedCandidate)
        XCTAssertTrue(model.canReproduceSavedFailure)
        let runtime = AutomationNativeUIRuntime(runtime: .init(bundleURL: root, expectedTeamID: "AAAAAAAAAA"), manifestDigest: String(repeating: "a", count: 64))
        let reproduction = try AutomationNativeUIReproductionProposal.compile(frozen: savedCandidate, original: failure,
            subject: .prepared(after), runtime: runtime, runID: "reproduce-syntax", disposable: false)
        XCTAssertEqual(reproduction.frozen.plan.app.sourceSyntaxIndexDigest, after.host.app.sourceSyntaxIndexDigest)
        XCTAssertThrowsError(try AutomationFixContract.candidate(from: baseline, app: after.host.app))
        var changed = after; changed.generatedHost.templateDigest = String(repeating: "7", count: 64)
        XCTAssertThrowsError(try AutomationFixContract.candidate(from: baseline, prepared: changed))
        changed = after
        changed.catalog.systemActions.append(.init(id: "Added", typeName: "Added", title: "Added", parameters: [], parametersComplete: true, compiled: true, registered: false, executed: false))
        XCTAssertThrowsError(try AutomationFixContract.candidate(from: baseline, prepared: changed))
        for key in ["ui.runtimeManifestDigest", "ui.runtimeTeamID", "ui.locale"] {
            var altered = candidate.plan; altered.provenance[key] = "changed"
            XCTAssertThrowsError(try AutomationFixContract.validate(baseline: baseline, candidate: AutomationFrozenCase(plan: altered)))
        }
        var altered = candidate.plan; altered.requirements[0].expected = .text("Changed oracle")
        XCTAssertThrowsError(try AutomationFixContract.validate(baseline: baseline, candidate: AutomationFrozenCase(plan: altered)))
        altered = candidate.plan; altered.provenance["catalog"] = String(repeating: "8", count: 64)
        XCTAssertThrowsError(try AutomationFrozenCase(plan: altered))
        altered = candidate.plan; altered.target.id = UUID().uuidString
        XCTAssertFalse(AutomationNativeUIRuntime.preparedEvidenceMatches(plan: altered, prepared: after))
        changed = after; changed.catalog.app.bundleID = "different.bundle"
        XCTAssertFalse(AutomationNativeUIRuntime.preparedEvidenceMatches(plan: candidate.plan, prepared: changed))
    }
}
#endif
