#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

@MainActor final class InstalledUIStoreTests: XCTestCase {
    func fixture(runtime: RuntimeIdentity = RuntimeIdentity(), executor: AutomationNativeRunExecutor? = nil, searchExecutor: AutomationNativeSearchExecutor? = nil, comparisonExecutor: AutomationNativeFixComparisonExecutor? = nil, reproductionExecutor: AutomationNativeReproductionExecutor? = nil, reproductionPreflightReader: (@Sendable (AutomationFrozenCase, String, URL) async throws -> (AutomationFrozenCase, AutomationAttemptReport))? = nil, evidenceImporter: (@Sendable (AutomationCase, AutomationAttemptReport, URL, AutomationEvidenceExposure) async throws -> AutomationNativeEvidenceDocument)? = nil, simulatorInventoryReader: AutomationNativeSimulatorInventoryReader? = nil) throws -> (AppAutomationStore, URL, URL) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("native-ui-test-" + UUID().uuidString)
        let bundle = root.appendingPathComponent("Subject.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "example.Selected", "CFBundleExecutable": "Subject", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        // Intake fixture, never executable or signed-runtime/device evidence.
        try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,0,0,0,0]).write(to: bundle.appendingPathComponent("Subject"))
        let model = AppAutomationStore(supportDirectory: root.appendingPathComponent("support"), savedCasesReader: { [] },
            runExecutor: executor ?? { _, _, _, _, _, _ in throw NativeTestError.unexpectedExecution },
            uiRuntimeProvider: { .init(runtime: .init(bundleURL: root, expectedTeamID: "AAAAAAAAAA"), manifestDigest: runtime.read()) }, searchExecutor: searchExecutor, comparisonExecutor: comparisonExecutor, reproductionExecutor: reproductionExecutor, reproductionPreflightReader: reproductionPreflightReader, evidenceImporter: evidenceImporter, simulatorInventoryReader: simulatorInventoryReader ?? { try await AutomationSimulatorInventory.read(developerDirectory: $0, workspace: $1) })
        model.select(bundle); model.simulatorID = UUID().uuidString
        model.uiInstruction = "Open the tasks screen"; model.uiEndpoint = "Tasks"; model.uiApprovedText = "Approved input"
        model.effectChoice = "navigation"; model.effectsConfirmed = true
        return (model, root, bundle)
    }
    func selectPreparedSource(model: AppAutomationStore, root: URL) throws {
        var app = try XCTUnwrap(model.candidate?.app)
        let sourceID = root.appendingPathComponent("Source.xcodeproj").path + "#SOURCE"
        app.logicalID = sourceID; app.configuration = "Debug"
        let target = TargetIdentity(id: model.simulatorID, kind: .simulator)
        // Source preview fixture only. It does not represent a built or signed host.
        model.intake = .init(candidates: [.init(id: sourceID, name: "Source", kind: .sourceTarget, containerPath: root.path,
            targetID: "SOURCE", bundleID: app.bundleID, platform: "ios", architectures: ["arm64"], configurations: ["Debug"], app: nil)],
            gaps: [], requiresBuildApproval: true)
        model.candidateID = sourceID; model.configuration = "Debug"
        let source = AutomationSourceManifest(sourceRoot: root.path, files: [], directories: [], excludedPaths: [])
        app.sourceManifestDigest = try source.digest
        let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false,
            gaps: ["System-action discovery is unavailable"])
        model.prepared = .init(source: source,
            generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "HOST", bundleID: "unused", configuration: "Debug", templateDigest: String(repeating: "c", count: 64)),
            host: .init(app: app, target: target, xctestrunPath: "unused", xctestrunDigest: String(repeating: "d", count: 64), subjectProductPath: try XCTUnwrap(app.canonicalBundlePath), hostBundlePath: "unused", hostProductDigest: String(repeating: "e", count: 64), hostBundleID: "unused", testTarget: "unused"),
            catalog: catalog, buildLogPath: "unused", buildLogTruncated: false)
        model.catalog = catalog
    }
    private func selectFreshSource(model: AppAutomationStore, root: URL) throws {
        try selectPreparedSource(model: model, root: root)
        var prepared = try XCTUnwrap(model.prepared)
        prepared.catalog.systemActions = [.init(id: "Complete", typeName: "Complete", title: "Complete task",
            parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity")], parametersComplete: true,
            compiled: true, registered: false, executed: false)]
        prepared.catalog.entities = [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery",
            properties: ["title": "text", "completed": "bool"], propertyTitles: ["title": "Title", "completed": "Completed"])]
        model.prepared = prepared; model.catalog = prepared.catalog; model.workflowRoute = "fresh"; model.actionID = "Complete"
        model.uiInstruction = "Create a new task with approvedText and save it"; model.uiEndpoint = "Tasks"
        model.freshNamePrefix = "Invoice"; model.freshNameProperty = "title"; model.freshStateProperty = "completed"
        model.freshInitialState = "false"; model.freshExpectedState = "true"
        model.effectChoice = "fixture"; model.disposable = true; model.effectsConfirmed = true
    }
    private func learnedCapture(_ request: AutomationNativeRunRequest, prepared: AutomationPreparedApplication, id: String) throws -> AutomationCapturedSetupAttempt {
        let report = nativeFreshFact(plan: request.plan, approval: request.approval, attemptID: id, completed: true)
        let context = AutomationRecipeContext(app: request.plan.app, target: request.plan.target, environmentID: request.plan.environmentID,
            catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog), hostDigest: prepared.host.hostProductDigest,
            localeIdentifier: request.plan.provenance["ui.locale"]!, uiRuntimeManifestDigest: request.plan.provenance["ui.runtimeManifestDigest"])
        let capture = AutomationControllerSetupCapture(scope: report.receipts[0].scope, operations: [
            .init(id: "learned.0", kind: .fillBinding, locator: .init(.testId, "task.title"), binding: "approvedText"),
            .init(id: "learned.endpoint", kind: .assertEndpoint, locator: .init(.label, "Tasks"))])
        return try .init(live: .init(context: context, plan: request.plan, approval: request.approval, report: report), capture: capture,
            bindings: AutomationFreshEntityPlanner.bindings(plan: request.plan))
    }
    func testCapsuleSelectionRetainsTrustedCampaignFenceAndDeniesAfterTaint() async throws {
        let (model, _, _) = try fixture()
        let cases = try AutomationCaseStore(root: model.support.appendingPathComponent("Cases"))
        let plan = AutomationCase(id: "private-capsule", app: .init(logicalID: "synthetic", bundleID: "example.Fixture", platform: "ios"),
            target: .init(id: "fixture", kind: .simulator), environmentID: "synthetic",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Echo"))
        let frozen = try await cases.freeze(plan)
        let scope = AutomationScope(runID: "private-run", attemptID: "recorded", segmentID: "subject", leaseGeneration: 1)
        let receipt = AutomationSegmentReceipt(scope: scope, app: plan.app, target: plan.target, segmentID: "subject", route: .systemIntent, dispatched: false, completed: false, environmentID: plan.environmentID)
        let result = AutomationAssessment.assess(plan: plan, attemptID: "recorded", subjectDispatched: false, subjectCompleted: false, observations: [], termination: .unresolved)
        let report = AutomationAttemptReport(attemptID: "recorded", result: result, receipts: [receipt], resourcesReleased: true)
        try await cases.saveAttempt(report, for: frozen); model.savedCases = [frozen]
        var selection: (AutomationFrozenCase, [AutomationAttemptReport], AutomationEvidenceExposure)? = try await model.capsuleExportSelection(frozen)
        let fence = try AutomationSecretEvidenceFence(root: model.support.appendingPathComponent("secret-evidence"))
        XCTAssertThrowsError(try fence.restrict(scope))
        withExtendedLifetime(selection) {}; selection = nil
        try fence.restrict(scope)
        do { _ = try await model.capsuleExportSelection(frozen); XCTFail("Exposed secret-tainted preview") } catch {}
        XCTAssertNil(model.canonicalEvidence); XCTAssertNil(model.savedViewedReport)
    }
    func testCapsuleExportReadsExactSavedSelectionWithoutChangingApprovalOrEvidence() async throws {
        let (model, root, _) = try fixture()
        let cases = try AutomationCaseStore(root: model.support.appendingPathComponent("Cases"))
        let plan = AutomationCase(id: "capsule", app: .init(logicalID: "synthetic", bundleID: "example.Fixture", platform: "ios"),
            target: .init(id: "fixture", kind: .simulator), environmentID: "synthetic",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "Echo"))
        let frozen = try await cases.freeze(plan)
        let result = AutomationAssessment.assess(plan: plan, attemptID: "recorded", subjectDispatched: false, subjectCompleted: false, observations: [], termination: .unresolved)
        let report = AutomationAttemptReport(attemptID: "recorded", result: result, receipts: [], resourcesReleased: true)
        try await cases.saveAttempt(report, for: frozen)
        model.savedCases = [frozen]; model.effectsConfirmed = false
        let selection = try await model.capsuleExportSelection(frozen)
        XCTAssertEqual(selection.0, frozen); XCTAssertEqual(selection.1, [report])
        XCTAssertFalse(model.effectsConfirmed); XCTAssertNil(model.report); XCTAssertNil(model.savedViewedReport)
        XCTAssertNil(model.canonicalEvidence); XCTAssertNil(model.pendingCommandStatus)
        model.progress = "Running"
        do { _ = try await model.capsuleExportSelection(frozen); XCTFail("Exported during a run") } catch {}
        model.progress = nil; model.savedCases = []
        do { _ = try await model.capsuleExportSelection(frozen); XCTFail("Exported an unselected case") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }
    func testLearnedRetentionAndNewProposalInvalidateApprovalAndChangedContext() throws {
        let (model, root, _) = try fixture(); try selectFreshSource(model: model, root: root)
        let original = try model.makeNativeRunRequest(runID: "source"), prepared = try XCTUnwrap(model.prepared)
        model.retainLearnedSetup(try learnedCapture(original, prepared: prepared, id: "one"))
        XCTAssertNil(model.learnedSetupRecipe)
        model.retainLearnedSetup(try learnedCapture(original, prepared: prepared, id: "two"))
        XCTAssertEqual(model.learnedSetupRecipe?.qualificationAttemptIDs, ["one", "two"])
        model.retainLearnedSetup(try learnedCapture(original, prepared: prepared, id: "three"))
        XCTAssertEqual(model.learnedSetupAttempts.count, 2)
        XCTAssertEqual(model.learnedSetupRecipe?.qualificationAttemptIDs, ["two", "three"])
        let preview = try model.previewCommand(), command = UUID()
        _ = try model.requestCommand(id: command, digest: preview.digest)
        model.useLearnedSetup = true; model.workflowSelectionChanged()
        XCTAssertFalse(model.effectsConfirmed); XCTAssertEqual(try model.commandStatus(id: command).state, "invalidated")
        model.effectsConfirmed = true
        let learned = try model.makeNativeRunRequest(runID: "proposal")
        XCTAssertEqual(learned.plan.setup[0].uiProgram?.operations.first?.kind, .fillBinding)
        XCTAssertEqual(learned.plan.setup[0].attemptTextBindings, original.plan.setup[0].attemptTextBindings)
        XCTAssertEqual(learned.plan.execution, original.plan.execution)
        XCTAssertNotEqual(learned.caseDigest, original.caseDigest)
        model.uiEndpoint = "Different endpoint"
        XCTAssertThrowsError(try model.makeNativeRunRequest(runID: "changed-contract"))
        model.uiEndpoint = "Tasks"
        var changed = prepared; changed.catalog.gaps.append("changed catalog")
        model.prepared = changed
        XCTAssertThrowsError(try model.makeNativeRunRequest(runID: "changed-context"))
    }
    func testFakeExecutorAndImportedFreshReportCannotLearnSetup() async throws {
        let (model, root, _) = try fixture(executor: { _, plan, approval, _, id, _ in
            nativeFreshFact(plan: plan, approval: approval, attemptID: id, completed: true)
        })
        try selectFreshSource(model: model, root: root)
        let preview = try model.previewCommand(), command = UUID()
        _ = try model.requestCommand(id: command, digest: preview.digest); model.run()
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertFalse(model.busy); XCTAssertTrue(model.report?.result.subjectCompleted == true)
        XCTAssertTrue(model.learnedSetupAttempts.isEmpty); XCTAssertNil(model.learnedSetupRecipe)
        let request = try model.makeNativeRunRequest(runID: "import")
        await model.importEvidence(plan: request.plan, report: nativeFreshFact(plan: request.plan, approval: request.approval, attemptID: "imported", completed: true))
        XCTAssertTrue(model.learnedSetupAttempts.isEmpty); XCTAssertNil(model.learnedSetupRecipe)
    }
    func testFreshRecordPreviewBindsPreparedRuntimeAndExplicitBusinessChoices() throws {
        let (model, root, _) = try fixture(); try selectFreshSource(model: model, root: root)
        XCTAssertTrue(model.canRun)
        let request = try model.makeNativeRunRequest(runID: "preview")
        XCTAssertNotNil(request.uiRuntime); XCTAssertEqual(request.plan.setup.map(\.kind), [.ui, .systemQuery])
        XCTAssertEqual(request.plan.execution.kind, .systemIntent)
        XCTAssertEqual(request.plan.observations[0].inputBindings?[0].destination, .hostQueryIDs)
        XCTAssertEqual(request.approval.effects, [.observe, .navigate, .fixtureWrite])
        XCTAssertEqual(request.plan.requirements[0].expected, .bool(true))
        model.freshExpectedState = "false"
        XCTAssertNotEqual(try model.previewCommand().digest, request.digest)
        model.freshExpectedState = ""; XCTAssertFalse(model.canRun)
        model.freshExpectedState = "true"; model.disposable = false; XCTAssertFalse(model.canRun)
        model.disposable = true; model.freshNamePrefix = "line\nbreak"; XCTAssertFalse(model.canRun)
        model.freshNamePrefix = "Invoice"; model.uiInstruction = String(repeating: "x", count: 4097); XCTAssertFalse(model.canRun)
        model.selectCandidate()
        XCTAssertEqual(model.freshNamePrefix, ""); XCTAssertEqual(model.freshNameProperty, "")
        XCTAssertEqual(model.freshStateProperty, ""); XCTAssertEqual(model.freshInitialState, ""); XCTAssertEqual(model.freshExpectedState, "")
    }
    func testProtectedRecordChoicesAreFrozenAndRequireDeclaredDistinctOwnership() throws {
        let (model, root, _) = try fixture(); try selectFreshSource(model: model, root: root)
        var prepared = try XCTUnwrap(model.prepared)
        prepared.catalog.entities?[0].properties["owner"] = "text"
        model.prepared = prepared; model.catalog = prepared.catalog
        let single = try model.previewCommand().digest
        model.freshProtectOtherRecord = true; XCTAssertFalse(model.canRun)
        model.freshContextProperty = "owner"; model.freshSelectedContext = "Work"; model.freshProtectedContext = "Personal"
        XCTAssertTrue(model.canRun)
        let request = try model.makeNativeRunRequest(runID: "preview")
        XCTAssertNotEqual(request.digest, single)
        XCTAssertEqual(request.plan.requirements.count, 2); XCTAssertEqual(try AutomationFreshEntityPlanner.bindings(plan: request.plan).count, 2)
        XCTAssertEqual(request.plan.execution.inputBindings?.first?.uniqueEntity?.matchingProperties, ["owner": .text("Work")])
        model.freshProtectedContext = "Work"; XCTAssertFalse(model.canRun)
        XCTAssertThrowsError(try model.makeNativeRunRequest(runID: "preview"))
        model.freshProtectedContext = "Personal"; model.freshContextProperty = "title"; XCTAssertFalse(model.canRun)
        model.freshContextProperty = "owner"; model.uiInstruction = String(repeating: "x", count: 4090)
        XCTAssertFalse(model.canRun); XCTAssertThrowsError(try model.makeNativeRunRequest(runID: "preview"))
        model.selectAction(); XCTAssertFalse(model.freshProtectOtherRecord)
        XCTAssertEqual(model.freshContextProperty, ""); XCTAssertEqual(model.freshSelectedContext, ""); XCTAssertEqual(model.freshProtectedContext, "")
    }
    func testSavedFreshFailureRequiresMatchingRouteAndFixtureApproval() async throws {
        let (model, root, _) = try fixture(); try selectFreshSource(model: model, root: root)
        let request = try model.makeNativeRunRequest(runID: "original-run"), cases = try AutomationCaseStore(root: root.appendingPathComponent("support/Cases"))
        let frozen = try await cases.freeze(request.plan)
        try await cases.saveAttempt(nativeFreshFact(plan: request.plan, approval: request.approval, attemptID: "original", completed: false), for: frozen)
        await model.showSavedCase(frozen)
        XCTAssertEqual(model.savedViewedReport?.result.summary, .assertionFailed)
        XCTAssertTrue(model.canPrepareSourceFix)
        XCTAssertTrue(model.canReproduceSavedFailure)
        model.workflowRoute = "ui"; model.effectChoice = "navigation"; model.effectsConfirmed = true
        XCTAssertFalse(model.canReproduceSavedFailure); XCTAssertFalse(model.canCheckFix)
        do { _ = try await model.previewReproductionCommand(); XCTFail("Fresh failure accepted under navigation approval") } catch { }
        model.workflowRoute = "fresh"; model.effectChoice = "fixture"; model.disposable = false
        XCTAssertFalse(model.canReproduceSavedFailure)
        model.disposable = true; XCTAssertTrue(model.canReproduceSavedFailure)
    }
    func testFreshNativeCampaignDelegationPreservesCapabilitiesAndFrozenChecks() async throws {
        let (model, root, _) = try fixture(); try selectFreshSource(model: model, root: root)
        let request = try model.makeNativeRunRequest(runID: "original-run"), before = try XCTUnwrap(model.prepared)
        let cases = try AutomationCaseStore(root: root.appendingPathComponent("support/Cases")), frozen = try await cases.freeze(request.plan)
        let original = nativeFreshFact(plan: request.plan, approval: request.approval, attemptID: "original", completed: false)
        try await cases.saveAttempt(original, for: frozen)
        let runtime = AutomationNativeUIRuntime(runtime: try XCTUnwrap(request.uiRuntime), manifestDigest: String(repeating: "a", count: 64))
        var reproduction = try AutomationNativeUIReproductionProposal.compile(frozen: frozen, original: original, subject: .prepared(before), runtime: runtime, runID: "reproduce", disposable: true)
        XCTAssertTrue(reproduction.usesFreshFixture)
        let beforeToken = try nativeFreshToken(plan: frozen.plan, approval: reproduction.approval, prepared: before, prefix: "before-qualification")
        // This executor is synthetic. Structural review deliberately leaves real conversion unknown.
        XCTAssertNotEqual(reproduction.capabilities.records["apple.codec.entity"]?.state, .available)
        do {
            _ = try await reproduction.runCampaign(cases: cases, executor: NativeFreshFactExecutor(completed: false), fixture: beforeToken)
            XCTFail("Unqualified entity conversion entered a campaign")
        } catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Input and result conversion has not been verified for this app and target")) }
        let syntheticConversion = CapabilityProfile.Record(state: .available, reason: "Synthetic executor fixture only", probeVersion: "test-v1", evidence: ["synthetic"])
        reproduction.capabilities.records["apple.codec.entity"] = syntheticConversion
        let report = try await reproduction.runCampaign(cases: cases, executor: NativeFreshFactExecutor(completed: false), fixture: beforeToken)
        XCTAssertTrue(report.complete); XCTAssertEqual(report.matchingFailures, 5)
        let after = try changedPreparedSource(before)
        var comparison = try AutomationNativeUIFixComparisonProposal.compile(frozen: frozen, original: original, before: .prepared(before), after: .prepared(after), runtime: runtime, runID: "compare", disposable: true)
        comparison.beforeCapabilities.records["apple.codec.entity"] = syntheticConversion
        comparison.afterCapabilities.records["apple.codec.entity"] = syntheticConversion
        XCTAssertEqual(comparison.baseline.oracleDigest, comparison.candidate.oracleDigest)
        XCTAssertEqual(comparison.baseline.plan.requirements, comparison.candidate.plan.requirements)
        let tokenA = try nativeFreshToken(plan: comparison.baseline.plan, approval: comparison.beforeApproval, prepared: before, prefix: "compare-before")
        let tokenB = try nativeFreshToken(plan: comparison.candidate.plan, approval: comparison.afterApproval, prepared: after, prefix: "compare-after")
        let result = try await comparison.runCampaign(cases: cases, beforeExecutor: NativeFreshFactExecutor(completed: false), afterExecutor: NativeFreshFactExecutor(completed: true), beforeFixture: tokenA, afterFixture: tokenB)
        XCTAssertEqual(result.before.count, 30); XCTAssertEqual(result.after.count, 30)
        XCTAssertEqual(result.beforeCounters.failed, 30); XCTAssertEqual(result.afterCounters.failed, 0)
    }
    private func freshQualificationInputs() async throws -> FreshQualificationInputs {
        let (model, root, _) = try fixture(); try selectFreshSource(model: model, root: root)
        let request = try model.makeNativeRunRequest(runID: "original-run"), prepared = try XCTUnwrap(model.prepared)
        let cases = try AutomationCaseStore(root: root.appendingPathComponent("support/Cases")), frozen = try await cases.freeze(request.plan)
        let original = nativeFreshFact(plan: request.plan, approval: request.approval, attemptID: "original", completed: false)
        try await cases.saveAttempt(original, for: frozen)
        let uiRuntime = try XCTUnwrap(request.uiRuntime)
        let runtime = AutomationNativeUIRuntime(runtime: uiRuntime, manifestDigest: String(repeating: "a", count: 64))
        var reproduction = try AutomationNativeUIReproductionProposal.compile(frozen: frozen, original: original, subject: .prepared(prepared), runtime: runtime, runID: "reproduce", disposable: true)
        XCTAssertTrue(reproduction.usesFreshFixture)
        reproduction.capabilities.records["apple.codec.entity"] = .init(state: .available, reason: "Synthetic executor fixture only", probeVersion: "test-v1", evidence: ["synthetic"])
        let token = try nativeFreshToken(plan: reproduction.frozen.plan, approval: reproduction.approval, prepared: prepared, prefix: "qualified")
        return .init(frozen: reproduction.frozen, approval: reproduction.approval, capabilities: reproduction.capabilities, prepared: prepared, runtime: uiRuntime, token: token)
    }
    private func qualify(_ inputs: FreshQualificationInputs, runner: FreshQualificationRunner, capabilities: CapabilityProfile? = nil,
                         installApproved: Bool = true) async throws -> AutomationQualifiedFreshFixture {
        try await AutomationNativeFreshFixtures.qualify(frozen: inputs.frozen, prepared: inputs.prepared, approval: inputs.approval,
            capabilities: capabilities ?? inputs.capabilities, runner: runner, runtime: inputs.runtime, installApproved: installApproved)
    }
    func testFreshFixtureQualificationRunsTwoReleasedAttemptsUnderItsOwnBudgetBeforeMintingFixture() async throws {
        let inputs = try await freshQualificationInputs(), bindings = try AutomationFreshEntityPlanner.bindings(plan: inputs.frozen.plan)
        var expectedLimits = AutomationCampaignLimits.firstCampaign
        expectedLimits.attempts = 2; expectedLimits.subjectOperations = 2; expectedLimits.uiActions = 60
        expectedLimits.controllerCalls = 24; expectedLimits.wallClockSeconds = 1200
        for installApproved in [false, true] {
            let runner = FreshQualificationRunner(token: inputs.token)
            let fixture = try await qualify(inputs, runner: runner, installApproved: installApproved)
            XCTAssertEqual(fixture.fixtureDigest, inputs.token.fixtureDigest)
            XCTAssertEqual(fixture.qualificationAttemptIDs, inputs.token.qualificationAttemptIDs)
            let capabilityCalls = await runner.capabilityCalls, runs = await runner.runs
            let validations = await runner.validations, qualifications = await runner.qualifications
            XCTAssertEqual(capabilityCalls, 1); XCTAssertEqual(runs.count, 2)
            XCTAssertEqual(validations, 2); XCTAssertEqual(qualifications, 1)
            XCTAssertEqual(Set(runs.map(\.attemptID)).count, 2)
            for (index, run) in runs.enumerated() {
                XCTAssertTrue(run.preparedSubjectChecked)
                XCTAssertEqual(run.plan, inputs.frozen.plan); XCTAssertEqual(run.approval, inputs.approval)
                XCTAssertEqual(run.allowBootAndInstall, installApproved)
                XCTAssertTrue(run.receivedVerifiedCapabilities, "Run must use the capabilities verified by this runner")
                XCTAssertEqual(run.uiRuntimeBundle, inputs.runtime.bundleURL)
                XCTAssertFalse(run.hadFixtureTracker)
                XCTAssertEqual(run.qualifyingBindings, bindings)
                XCTAssertEqual(run.limits, expectedLimits)
                XCTAssertEqual(run.usage?.attempts, index + 1, "Each attempt reserves budget before it runs")
            }
        }
    }
    func testFreshFixtureQualificationRejectsUnreleasedIncompleteUncertainOrUnassessableAttempts() async throws {
        let inputs = try await freshQualificationInputs()
        let defects: [(String, @Sendable (inout AutomationAttemptReport) -> Void)] = [
            ("resources not released", { $0.resourcesReleased = false }),
            ("subject incomplete", { $0.result.subjectCompleted = false }),
            ("dispatch uncertain", { $0.result.subjectDispatchUncertain = true }),
            ("unresolved", { $0.result.summary = .unresolved }),
            ("needs review", { $0.result.summary = .needsReview }),
            ("infrastructure failed", { $0.result.summary = .infrastructureFailed })]
        for (label, defect) in defects {
            for failingAttempt in 0..<2 {
                let runner = FreshQualificationRunner(token: inputs.token, alter: { index, report in if index == failingAttempt { defect(&report) } })
                do {
                    _ = try await qualify(inputs, runner: runner)
                    XCTFail("Qualification accepted attempt \(failingAttempt) with \(label)")
                } catch {
                    XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Fresh fixture qualification did not complete and release; inspect its saved attempt before continuing"), label)
                }
                let runs = await runner.runs.count, validations = await runner.validations, qualifications = await runner.qualifications
                XCTAssertEqual(runs, failingAttempt + 1, label)
                XCTAssertEqual(validations, failingAttempt, "\(label): a rejected attempt must not be validated")
                XCTAssertEqual(qualifications, 0, "\(label): no fixture may be minted")
            }
        }
    }
    func testFreshFixtureQualificationStopsWhenLiveAttemptValidationFails() async throws {
        let inputs = try await freshQualificationInputs()
        for failingValidation in 1...2 {
            let runner = FreshQualificationRunner(token: inputs.token, validationFailure: failingValidation)
            do { _ = try await qualify(inputs, runner: runner); XCTFail("Qualification ignored a failed live validation") }
            catch { XCTAssertEqual(error as? AutomationContractError, FreshQualificationRunner.validationError) }
            let runs = await runner.runs.count, validations = await runner.validations, qualifications = await runner.qualifications
            XCTAssertEqual(runs, failingValidation); XCTAssertEqual(validations, failingValidation); XCTAssertEqual(qualifications, 0)
        }
    }
    func testFreshFixtureQualificationRejectsUnverifiedProposalBeforeAnyAttempt() async throws {
        let inputs = try await freshQualificationInputs(), runner = FreshQualificationRunner(token: inputs.token)
        var unverified = inputs.capabilities; unverified.records["apple.codec.entity"] = nil
        do { _ = try await qualify(inputs, runner: runner, capabilities: unverified); XCTFail("Unverified conversion entered qualification") }
        catch { XCTAssertEqual(error as? AutomationContractError, .missingEvidence("Input and result conversion has not been verified for this app and target")) }
        let capabilityCalls = await runner.capabilityCalls, runs = await runner.runs.count, qualifications = await runner.qualifications
        XCTAssertEqual(capabilityCalls, 1); XCTAssertEqual(runs, 0); XCTAssertEqual(qualifications, 0)
    }
    func testFreshFixtureQualificationCancelledAfterFirstAttemptDoesNotRunSecond() async throws {
        let inputs = try await freshQualificationInputs(), runner = FreshQualificationRunner(token: inputs.token, cancelAfterRun: 0)
        let task = Task { try await self.qualify(inputs, runner: runner) }
        switch await task.result {
        case .success: XCTFail("Cancelled qualification minted a fixture")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let runs = await runner.runs.count, validations = await runner.validations, qualifications = await runner.qualifications
        XCTAssertEqual(runs, 1); XCTAssertEqual(validations, 1); XCTAssertEqual(qualifications, 0)
    }
    func changedPreparedSource(_ before: AutomationPreparedApplication) throws -> AutomationPreparedApplication {
        var after = before
        after.source.files = [.init(inputPath: before.source.sourceRoot + "/Changed.swift", relativePath: "Changed.swift", bytes: 1,
                                    sha256: String(repeating: "1", count: 64), symbolicLink: nil, frozenSymbolicLink: nil, permissions: 420)]
        after.host.app.sourceManifestDigest = try after.source.digest
        after.host.app.productDigest = String(repeating: "2", count: 64)
        after.host.hostProductDigest = String(repeating: "3", count: 64)
        after.host.xctestrunDigest = String(repeating: "4", count: 64)
        after.catalog.app = after.host.app
        return after
    }
    func testPreparedSourceComparisonRetainsOriginalBuildAndFrozenChecks() async throws {
        let (model, root, _) = try fixture(comparisonExecutor: { proposal, before, after, _, _ in
            guard case .prepared(let retained) = before, case .prepared(let candidate) = after else { throw NativeTestError.unexpectedExecution }
            XCTAssertEqual(retained.host.app, proposal.baseline.plan.app)
            XCTAssertEqual(candidate.host.app, proposal.candidate.plan.app)
            XCTAssertNotEqual(retained.host.app.sourceManifestDigest, candidate.host.app.sourceManifestDigest)
            let cases = try AutomationCaseStore(root: URL(fileURLWithPath: String(proposal.baseline.plan.app.logicalID.split(separator: "#")[0])).deletingLastPathComponent().appendingPathComponent("fake-comparison-cases"))
            return try await AutomationFixComparison(cases: cases).run(baseline: proposal.baseline, candidate: proposal.candidate,
                attemptsPerBuild: proposal.attemptsPerBuild, beforeApproval: proposal.beforeApproval, afterApproval: proposal.afterApproval,
                limits: proposal.limits, beforeExecutor: NativeSearchFactExecutor(fails: true), afterExecutor: NativeSearchFactExecutor(fails: false))
        })
        try selectPreparedSource(model: model, root: root)
        let original = try await saveFailure(model: model, root: root, legacyPreparedEvidence: true), baseline = try XCTUnwrap(model.prepared)
        XCTAssertTrue(model.canPrepareSourceFix); XCTAssertFalse(model.canCheckFix)
        model.prepared = try changedPreparedSource(baseline); model.catalog = model.prepared?.catalog; model.installApproved = true
        XCTAssertTrue(model.canReproduceSavedFailure); XCTAssertTrue(model.canCheckFix)
        let preview = try await model.previewComparisonCommand(), id = UUID()
        _ = try await model.requestComparisonCommand(id: id, digest: preview.digest)
        await model.checkFix()
        let result = try XCTUnwrap(model.comparisonReport)
        XCTAssertTrue(result.complete); XCTAssertEqual(result.before.count, 30); XCTAssertEqual(result.after.count, 30)
        XCTAssertNotEqual(result.baseline.plan.id, original.plan.id)
        XCTAssertEqual(result.baseline.plan.provenance["comparison.sourceCaseDigest"], original.digest)
        XCTAssertEqual(result.baseline.plan.preparedSimulatorBuildArtifacts, try .init(prepared: baseline))
        XCTAssertEqual(result.candidate.plan.preparedSimulatorBuildArtifacts, try .init(prepared: XCTUnwrap(model.prepared)))
        XCTAssertEqual(result.candidate.plan.requirements, original.plan.requirements)
        XCTAssertEqual(result.candidate.plan.observations, original.plan.observations)
        XCTAssertEqual(result.candidate.plan.provenance, result.baseline.plan.provenance)
        XCTAssertEqual(result.candidate.contractDigest, result.baseline.contractDigest)
        try original.validate()
        XCTAssertEqual(result.candidate.oracleDigest, original.oracleDigest)
        XCTAssertEqual(try model.commandStatus(id: id).state, "completed")
    }
    func testSourceComparisonRestoresRetainedBaselineAfterStoreRestart() async throws {
        let (model, root, bundle) = try fixture(); try selectPreparedSource(model: model, root: root)
        var baseline = try XCTUnwrap(model.prepared)
        let support = root.appendingPathComponent("support"), session = support.appendingPathComponent("prepare-" + UUID().uuidString)
        let product = session.appendingPathComponent("DerivedData/Subject.app")
        try FileManager.default.createDirectory(at: product.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: bundle, to: product)
        baseline.host.app.canonicalBundlePath = product.path; baseline.host.subjectProductPath = product.path
        baseline.catalog.app = baseline.host.app; model.prepared = baseline
        let record = session.appendingPathComponent("prepared-application.json")
        try JSONEncoder().encode(baseline).write(to: record)
        let frozen = try await saveFailure(model: model, root: root)
        let restored = AppAutomationStore(supportDirectory: support, uiRuntimeProvider: {
            .init(runtime: .init(bundleURL: root, expectedTeamID: "AAAAAAAAAA"), manifestDigest: String(repeating: "a", count: 64))
        })
        restored.intake = model.intake; restored.candidateID = model.candidateID; restored.configuration = model.configuration
        restored.simulatorID = model.simulatorID; restored.effectChoice = "navigation"; restored.effectsConfirmed = true
        restored.prepared = try changedPreparedSource(baseline); restored.installApproved = true
        await restored.showSavedCase(frozen)
        XCTAssertTrue(restored.canReproduceSavedFailure); XCTAssertTrue(restored.canCheckFix)
        let preview = try await restored.previewComparisonCommand()
        XCTAssertEqual(preview.beforeProductDigest, baseline.host.app.productDigest)
        XCTAssertEqual(preview.afterProductDigest, restored.prepared?.host.app.productDigest)
        try FileManager.default.removeItem(at: record)
        let absent = AppAutomationStore(supportDirectory: support)
        absent.intake = model.intake; absent.candidateID = model.candidateID; absent.configuration = model.configuration
        absent.simulatorID = model.simulatorID; absent.effectChoice = "navigation"; absent.effectsConfirmed = true
        absent.prepared = restored.prepared; absent.installApproved = true
        await absent.showSavedCase(frozen)
        XCTAssertFalse(absent.canCheckFix); XCTAssertFalse(absent.canReproduceSavedFailure)
    }
    func testPreparedSourceFixRejectsIdentitySourceTemplateAndTargetChanges() async throws {
        let (model, root, _) = try fixture(); try selectPreparedSource(model: model, root: root)
        _ = try await saveFailure(model: model, root: root)
        let baseline = try XCTUnwrap(model.prepared), valid = try changedPreparedSource(baseline)
        for field in 0..<9 {
            var invalid = valid
            switch field {
            case 0: invalid.host.app.logicalID += "different"
            case 1: invalid.host.app.configuration = "Release"
            case 2: invalid.host.app.architecture = "x86_64"
            case 3: invalid.host.app.owningModule = "Other"
            case 4: invalid.host.target.id = UUID().uuidString
            case 5: invalid.generatedHost.templateDigest = String(repeating: "9", count: 64)
            case 6: invalid.host.app.productDigest = baseline.host.app.productDigest
            case 7: invalid.source = baseline.source; invalid.host.app.sourceManifestDigest = baseline.host.app.sourceManifestDigest
            default: invalid.host.app.sourceManifestDigest = String(repeating: "0", count: 64)
            }
            model.prepared = invalid; model.installApproved = true
            XCTAssertFalse(model.canCheckFix, "field \(field)")
            do { _ = try await model.previewComparisonCommand(); XCTFail("Accepted mismatch \(field)") } catch {}
        }
        model.prepared = valid; XCTAssertTrue(model.canCheckFix)
        model.simulatorID = UUID().uuidString; XCTAssertFalse(model.canCheckFix)
    }
    func testQueuedPreparedSourceCandidateDriftNeverDispatches() async throws {
        let calls = NativeDispatchCount()
        let (model, root, _) = try fixture(comparisonExecutor: { _, _, _, _, _ in await calls.increment(); throw NativeTestError.unexpectedExecution })
        try selectPreparedSource(model: model, root: root); _ = try await saveFailure(model: model, root: root)
        model.prepared = try changedPreparedSource(XCTUnwrap(model.prepared)); model.installApproved = true
        let preview = try await model.previewComparisonCommand(), id = UUID()
        _ = try await model.requestComparisonCommand(id: id, digest: preview.digest)
        model.prepared?.host.hostProductDigest = String(repeating: "5", count: 64)
        await model.checkFix()
        let count = await calls.value; XCTAssertEqual(count, 0)
        XCTAssertEqual(try model.commandStatus(id: id).state, "invalidated"); XCTAssertNil(model.comparisonReport)
    }
    func testRemoteAppSelectionUsesOnlyCurrentAdmittedPopulationAndClearsAuthority() throws {
        let (model, root, _) = try fixture(); try selectPreparedSource(model: model, root: root)
        let current = try XCTUnwrap(model.intake?.candidates.first)
        var other = current; other.id += "-other"; other.name = "Other target"
        model.intake?.candidates.append(other)
        let listing = try model.listApplications()
        XCTAssertEqual(listing.applications.count, 2); XCTAssertEqual(listing.selectedID, current.id)
        XCTAssertThrowsError(try model.selectApplication(id: root.appendingPathComponent("arbitrary.app").path, snapshotDigest: listing.snapshotDigest))
        XCTAssertThrowsError(try model.selectApplication(id: other.id, snapshotDigest: String(repeating: "b", count: 64)))
        XCTAssertNotNil(model.prepared)
        _ = try model.selectApplication(id: current.id, snapshotDigest: listing.snapshotDigest)
        XCTAssertNotNil(model.prepared, "Idempotent selection must retain the reviewed preparation")
        let selected = try model.selectApplication(id: other.id, snapshotDigest: listing.snapshotDigest)
        XCTAssertEqual(selected.selectedID, other.id); XCTAssertEqual(selected.snapshotDigest, listing.snapshotDigest)
        XCTAssertNil(model.prepared); XCTAssertFalse(model.effectsConfirmed); XCTAssertFalse(model.canRun)
        var newer = other; newer.name = "Changed source metadata"; model.intake?.candidates[1] = newer
        XCTAssertThrowsError(try model.selectApplication(id: current.id, snapshotDigest: listing.snapshotDigest))
    }
    func testEmptyAppListingDoesNotTouchFilesystemAndPendingRunBlocksSelection() throws {
        let absent = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("native-list-" + UUID().uuidString)
        let empty = AppAutomationStore(supportDirectory: absent)
        let listing = try empty.listApplications(); XCTAssertTrue(listing.applications.isEmpty); XCTAssertNil(listing.selectedID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        let (model, _, _) = try fixture()
        let preview = try model.previewCommand()
        _ = try model.requestCommand(id: UUID(), digest: preview.digest)
        let current = try model.listApplications()
        XCTAssertThrowsError(try model.selectApplication(id: model.candidateID, snapshotDigest: current.snapshotDigest))
        XCTAssertNotNil(model.pendingCommandStatus); XCTAssertFalse(model.busy)
    }
    func testPreparedSourceUIIgnoresMissingIntentCatalogAndRejectsStaleSelection() throws {
        let (model, root, _) = try fixture(); try selectPreparedSource(model: model, root: root)
        XCTAssertTrue(model.isUIWorkflow); XCTAssertFalse(model.isInstalledUI); XCTAssertTrue(model.canRun)
        let preview = try model.previewCommand(); XCTAssertEqual(preview.action, model.uiInstruction)
        model.workflowRoute = "system"; XCTAssertFalse(model.canRun)
        model.workflowRoute = "ui"; model.configuration = "Release"; XCTAssertFalse(model.canRun)
        model.configuration = "Debug"; model.simulatorID = UUID().uuidString; XCTAssertFalse(model.canRun)
    }
    func testPreparedSourceHostChangeInvalidatesQueuedUIApproval() throws {
        let (model, root, _) = try fixture(); try selectPreparedSource(model: model, root: root)
        let preview = try model.previewCommand(), requestID = UUID()
        _ = try model.requestCommand(id: requestID, digest: preview.digest)
        model.prepared?.host.hostProductDigest = String(repeating: "f", count: 64)
        model.run()
        XCTAssertEqual(try model.commandStatus(id: requestID).state, "invalidated")
        XCTAssertFalse(model.busy); XCTAssertNil(model.report)
    }
    @discardableResult func saveFailure(model: AppAutomationStore, root: URL, legacyPreparedEvidence: Bool = false) async throws -> AutomationFrozenCase {
        let app = try XCTUnwrap(model.candidate?.app ?? model.prepared?.host.app), target = TargetIdentity(id: model.simulatorID, kind: .simulator)
        var approval = RunApproval(runID: "original", app: app, target: target, environmentID: "selected-simulator:" + target.id,
            effects: [.observe, .navigate], maximumActions: 30, disposable: false)
        var plan = try AutomationUIOnlyPlanner.compile(app: app, target: target, instruction: "Open tasks", endpoint: "Tasks",
            expectedVisibleText: "Complete", approval: approval, localeIdentifier: Locale.current.identifier)
        plan.provenance["ui.runtimeManifestDigest"] = String(repeating: "a", count: 64)
        plan.provenance["ui.runtimeTeamID"] = "AAAAAAAAAA"
        if let prepared = model.prepared {
            if legacyPreparedEvidence { plan.provenance.merge(try AutomationNativeUIRuntime.preparedProvenance(prepared)) { _, new in new } }
            else { try AutomationNativeUIRuntime.attachPreparedEvidence(to: &plan, prepared: prepared) }
        }
        let cases = try AutomationCaseStore(root: root.appendingPathComponent("support/Cases"))
        let frozen = try await cases.freeze(plan); approval.approvedCaseDigest = frozen.digest
        let fact = try await NativeSearchFactExecutor(fails: true).execute(frozen: frozen, approval: approval, attemptID: "original",
            budget: .init(limits: .firstCampaign))
        try await cases.saveAttempt(fact, for: frozen)
        await model.showSavedCase(frozen)
        return frozen
    }
    func testDelayedSavedImportFailureCannotPublishAgainstNewSelection() async throws {
        let gate = NativeExecutionGate()
        let (model, root, _) = try fixture(evidenceImporter: { _, _, _, _ in await gate.enter(); throw NativeTestError.unexpectedExecution })
        let viewing = Task { try await self.saveFailure(model: model, root: root) }
        await gate.waitUntilEntered()
        XCTAssertNotNil(model.savedViewedReport)
        model.selectCandidate(); model.message = "New selection"
        await gate.release(); _ = try await viewing.value
        XCTAssertEqual(model.message, "New selection"); XCTAssertNil(model.evidenceImportMessage)
        XCTAssertNil(model.savedViewedReport); XCTAssertNil(model.canonicalSavedEvidence)
    }
    func testNativeImportFailureRetainsCompletedCommandAndUnknownRelease() async throws {
        let gate = NativeExecutionGate()
        let (model, _, _) = try fixture(executor: { _, plan, _, _, id, _ in
            var result = AutomationAssessment.assess(plan: plan, attemptID: id, subjectDispatched: false, subjectCompleted: false, observations: [], termination: .unresolved)
            result.subjectDispatchUncertain = true
            return .init(attemptID: id, result: result, receipts: [], resourcesReleased: false)
        }, evidenceImporter: { _, _, _, _ in await gate.enter(); throw NativeTestError.unexpectedExecution })
        try FileManager.default.createDirectory(at: model.support, withIntermediateDirectories: true)
        let preview = try model.previewCommand(), id = UUID()
        _ = try model.requestCommand(id: id, digest: preview.digest); model.run()
        await gate.waitUntilEntered()
        XCTAssertEqual(try model.commandStatus(id: id).state, "completed")
        XCTAssertEqual(model.report?.resourcesReleased, false)
        await gate.release()
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.evidenceImportMessage)
        XCTAssertEqual(try model.commandStatus(id: id).state, "completed")
        XCTAssertTrue(model.retainedUnresolvedNormalReport?.result.subjectDispatchUncertain == true)
        XCTAssertFalse(model.canRun)
    }
    func testSavedFailureReproductionDoesNotRetypeOrChangeTheFrozenOracle() async throws {
        let (model, root, _) = try fixture(reproductionExecutor: { proposal, _, _, support, _ in
            try await AutomationReproduction(cases: .init(root: support.appendingPathComponent("Cases"))).run(
                frozen: proposal.frozen, originalAttemptID: proposal.originalAttemptID, approval: proposal.approval,
                limits: proposal.limits, executor: NativeSearchFactExecutor(fails: true))
        })
        try await saveFailure(model: model, root: root)
        model.uiInstruction = ""; model.uiEndpoint = ""; model.uiExpectedText = "changed expectation ignored"
        XCTAssertFalse(model.canRun); XCTAssertTrue(model.canReproduceSavedFailure)
        await model.reproduceSavedFailure()
        XCTAssertNil(model.message); XCTAssertFalse(model.busy)
        let result = try XCTUnwrap(model.reproductionReport)
        XCTAssertTrue(result.complete); XCTAssertEqual(result.matchingFailures, 5)
        XCTAssertEqual(result.frozen.plan.requirements.first?.expected, .text("Complete"))
        XCTAssertEqual(model.savedReproductions.count, 1)
        XCTAssertFalse(result.attempts.contains { $0.attemptID == "original" })
    }
    func testQueuedReproductionRequiresItsOwnNativeConfirmationAndReturnsAllFiveOutcomes() async throws {
        let calls = NativeDispatchCount()
        let (model, root, _) = try fixture(reproductionExecutor: { proposal, _, _, support, _ in
            await calls.increment()
            return try await AutomationReproduction(cases: .init(root: support.appendingPathComponent("Cases"))).run(
                frozen: proposal.frozen, originalAttemptID: proposal.originalAttemptID, approval: proposal.approval,
                limits: proposal.limits, executor: NativeSearchAlternatingExecutor())
        })
        try await saveFailure(model: model, root: root)
        let preview = try await model.previewReproductionCommand(), id = UUID()
        let pending = try await model.requestReproductionCommand(id: id, digest: preview.digest)
        XCTAssertEqual(pending.kind, .reproduction); XCTAssertEqual(pending.state, "awaitingApproval")
        model.run(); XCTAssertFalse(model.busy); XCTAssertNil(model.report)
        let before = await calls.value; XCTAssertEqual(before, 0)
        await model.reproduceSavedFailure()
        let status = try model.commandStatus(id: id), outcome = try XCTUnwrap(status.reproduction)
        XCTAssertEqual(status.state, "completed"); XCTAssertNil(status.result); XCTAssertNil(status.attemptID)
        XCTAssertEqual(outcome.attempts.count, 5); XCTAssertTrue(outcome.complete); XCTAssertTrue(outcome.reproduced)
        XCTAssertEqual(outcome.matchingFailures, 2); XCTAssertEqual(outcome.assessedPasses, 3)
        XCTAssertEqual(outcome.attempts.last?.result.summary, .passed)
        let repeated = try await model.requestReproductionCommand(id: id, digest: preview.digest)
        XCTAssertEqual(repeated.state, "completed")
        let after = await calls.value; XCTAssertEqual(after, 1)
        XCTAssertThrowsError(try model.requestCommand(id: id, digest: preview.digest))
    }
    func testConcurrentIdenticalReproductionRequestsReturnTheSamePendingRequest() async throws {
        let gate = NativeDualReadGate(), reads = NativeDispatchCount()
        let (model, root, _) = try fixture(reproductionPreflightReader: { frozen, id, root in
            let cases = try AutomationCaseStore(root: root)
            let saved = try await cases.load(id: frozen.plan.id, revision: frozen.plan.revision, digest: frozen.digest)
            let original = try await cases.loadAttempt(id: id, frozen: saved)
            await reads.increment()
            if await reads.value >= 2 { await gate.enter() }
            return (saved, original)
        })
        try await saveFailure(model: model, root: root)
        let preview = try await model.previewReproductionCommand(), id = UUID()
        let first = Task { try await model.requestReproductionCommand(id: id, digest: preview.digest) }
        let second = Task { try await model.requestReproductionCommand(id: id, digest: preview.digest) }
        await gate.waitUntilTwo(); await gate.release()
        let one = try await first.value, two = try await second.value
        XCTAssertEqual(one.requestID, two.requestID); XCTAssertEqual(one.digest, two.digest)
        XCTAssertEqual(one.state, "awaitingApproval"); XCTAssertEqual(two.state, "awaitingApproval")
        XCTAssertFalse(model.busy); XCTAssertNil(model.reproductionReport)
    }
    func testQueuedReproductionInvalidatesChangedInstallConsentBeforeDispatch() async throws {
        let calls = NativeDispatchCount()
        let (model, root, _) = try fixture(reproductionExecutor: { _, _, _, _, _ in await calls.increment(); throw NativeTestError.unexpectedExecution })
        try await saveFailure(model: model, root: root)
        let preview = try await model.previewReproductionCommand(), id = UUID()
        _ = try await model.requestReproductionCommand(id: id, digest: preview.digest)
        model.installApproved.toggle()
        await model.reproduceSavedFailure()
        XCTAssertEqual(try model.commandStatus(id: id).state, "invalidated")
        let count = await calls.value; XCTAssertEqual(count, 0)
    }
    func testCommandCancellationDrainsHeldReproductionPreflightWithoutDispatch() async throws {
        let gate = NativeExecutionGate(), reads = NativeDispatchCount(), calls = NativeDispatchCount()
        let (model, root, _) = try fixture(reproductionExecutor: { _, _, _, _, _ in await calls.increment(); throw NativeTestError.unexpectedExecution },
            reproductionPreflightReader: { frozen, id, root in
                let cases = try AutomationCaseStore(root: root)
                let saved = try await cases.load(id: frozen.plan.id, revision: frozen.plan.revision, digest: frozen.digest)
                let original = try await cases.loadAttempt(id: id, frozen: saved)
                await reads.increment()
                if await reads.value >= 3 { await gate.enter() }
                return (saved, original)
            })
        try await saveFailure(model: model, root: root)
        let preview = try await model.previewReproductionCommand(), id = UUID()
        _ = try await model.requestReproductionCommand(id: id, digest: preview.digest)
        let execution = Task { await model.reproduceSavedFailure() }
        await gate.waitUntilEntered()
        XCTAssertEqual(try model.cancelCommand(id: id).state, "cancelling")
        XCTAssertTrue(model.busy)
        await gate.release(); await execution.value
        XCTAssertEqual(try model.commandStatus(id: id).state, "cancelled")
        XCTAssertFalse(model.busy); let count = await calls.value; XCTAssertEqual(count, 0)
    }
    private func fixedBundle(root: URL, baseline: URL) throws -> URL {
        let fixed = root.appendingPathComponent("Fixed.app")
        try FileManager.default.copyItem(at: baseline, to: fixed)
        try Data("actual changed product fixture".utf8).write(to: fixed.appendingPathComponent("changed-resource"))
        return fixed
    }
    func testNativeCheckFixKeepsOracleAndUsesThirtyFreshAttemptsOnBothRetainedProducts() async throws {
        let (model, root, bundle) = try fixture(comparisonExecutor: { proposal, before, after, _, support in
            guard case .installedUI(let beforeProduct) = before, case .installedUI(let afterProduct) = after else { throw NativeTestError.unexpectedExecution }
            XCTAssertNotEqual(beforeProduct.bundleURL, afterProduct.bundleURL)
            XCTAssertNotEqual(before.app.productDigest, after.app.productDigest)
            XCTAssertEqual(before.app.logicalID, after.app.logicalID)
            return try await AutomationFixComparison(cases: .init(root: support.appendingPathComponent("Cases"))).run(
                baseline: proposal.baseline, candidate: proposal.candidate, attemptsPerBuild: proposal.attemptsPerBuild,
                beforeApproval: proposal.beforeApproval, afterApproval: proposal.afterApproval, limits: proposal.limits,
                beforeExecutor: NativeSearchFactExecutor(fails: true), afterExecutor: NativeSearchFactExecutor())
        })
        let original = try await saveFailure(model: model, root: root)
        model.selectFixedBundle(try fixedBundle(root: root, baseline: bundle))
        XCTAssertTrue(model.canCheckFix)
        model.uiExpectedText = "ignore edited expectation"
        let preview = try await model.previewComparisonCommand(), commandID = UUID()
        XCTAssertEqual(preview.requestedAttemptsPerBuild, 30)
        let queued = try await model.requestComparisonCommand(id: commandID, digest: preview.digest)
        XCTAssertEqual(queued.state, "awaitingApproval")
        model.run(); await model.reproduceSavedFailure()
        XCTAssertNil(model.comparisonReport); XCTAssertFalse(model.busy)
        XCTAssertTrue(model.canCheckFix)
        await model.checkFix()
        let result = try XCTUnwrap(model.comparisonReport)
        XCTAssertTrue(result.complete); XCTAssertEqual(result.before.count, 30); XCTAssertEqual(result.after.count, 30)
        XCTAssertEqual(result.beforeCounters.failed, 30); XCTAssertEqual(result.afterCounters.failed, 0)
        XCTAssertEqual(result.baseline.digest, original.digest); XCTAssertEqual(result.candidate.oracleDigest, original.oracleDigest)
        XCTAssertEqual(model.savedComparisons.count, 1); XCTAssertNil(model.message); XCTAssertNil(model.fixedAppName)
        let status = try model.commandStatus(id: commandID)
        XCTAssertEqual(status.kind, .fixComparison); XCTAssertEqual(status.state, "completed")
        XCTAssertEqual(status.comparison?.before.count, 30); XCTAssertEqual(status.comparison?.after.count, 30)
        XCTAssertEqual(status.resourcesReleased, true); XCTAssertNil(status.result); XCTAssertNil(status.attemptID)
        let repeated = try await model.requestComparisonCommand(id: commandID, digest: preview.digest)
        XCTAssertEqual(repeated.state, "completed")
    }
    func testQueuedComparisonRuntimeDriftNeverDispatchesAndRetainsOriginal() async throws {
        let runtime = RuntimeIdentity(), calls = NativeDispatchCount()
        let (model, root, bundle) = try fixture(runtime: runtime, comparisonExecutor: { _, _, _, _, _ in await calls.increment(); throw NativeTestError.unexpectedExecution })
        let original = try await saveFailure(model: model, root: root)
        model.selectFixedBundle(try fixedBundle(root: root, baseline: bundle))
        let preview = try await model.previewComparisonCommand(), id = UUID()
        _ = try await model.requestComparisonCommand(id: id, digest: preview.digest)
        runtime.change(); await model.checkFix()
        let count = await calls.value; XCTAssertEqual(count, 0)
        XCTAssertEqual(try model.commandStatus(id: id).state, "failed")
        XCTAssertNil(model.comparisonReport); XCTAssertEqual(model.savedViewedReport?.attemptID, "original")
        let stored = try await AutomationCaseStore(root: root.appendingPathComponent("support/Cases")).load(id: original.plan.id, revision: original.plan.revision, digest: original.digest)
        XCTAssertEqual(stored, original)
    }
    func testCancelComparisonDuringHeldPreflightNeverDispatches() async throws {
        let gate = NativeExecutionGate(), reads = NativeDispatchCount(), calls = NativeDispatchCount()
        let (model, root, bundle) = try fixture(comparisonExecutor: { _, _, _, _, _ in await calls.increment(); throw NativeTestError.unexpectedExecution }, reproductionPreflightReader: { frozen, attemptID, root in
            let cases = try AutomationCaseStore(root: root)
            let stored = try await cases.load(id: frozen.plan.id, revision: frozen.plan.revision, digest: frozen.digest)
            let report = try await cases.loadAttempt(id: attemptID, frozen: stored)
            await reads.increment()
            if await reads.value > 2 { await gate.enter() }
            return (stored, report)
        })
        try await saveFailure(model: model, root: root)
        model.selectFixedBundle(try fixedBundle(root: root, baseline: bundle))
        let preview = try await model.previewComparisonCommand(), id = UUID()
        _ = try await model.requestComparisonCommand(id: id, digest: preview.digest)
        let check = Task { await model.checkFix() }
        await gate.waitUntilEntered()
        XCTAssertEqual(try model.cancelCommand(id: id).state, "cancelling")
        await gate.release(); await check.value
        let count = await calls.value; XCTAssertEqual(count, 0)
        XCTAssertEqual(try model.commandStatus(id: id).state, "cancelled"); XCTAssertNil(model.comparisonReport)
        XCTAssertFalse(model.busy)
    }
    func testNativeFixProductAndInstallDriftCannotDispatch() async throws {
        let calls = NativeDispatchCount()
        let (model, root, bundle) = try fixture(comparisonExecutor: { _, _, _, _, _ in await calls.increment(); throw NativeTestError.unexpectedExecution })
        try await saveFailure(model: model, root: root)
        let fixed = try fixedBundle(root: root, baseline: bundle)
        model.selectFixedBundle(fixed); model.installApproved = false
        XCTAssertFalse(model.canCheckFix); await model.checkFix()
        model.installApproved = true
        try Data("changed after selection".utf8).write(to: fixed.appendingPathComponent("changed-resource"))
        await model.checkFix()
        XCTAssertNotNil(model.message); XCTAssertNil(model.comparisonReport)
        let count = await calls.value; XCTAssertEqual(count, 0)
        model.selectFixedBundle(bundle); XCTAssertFalse(model.canCheckFix)
    }
    func testComparisonArchiveFailureRetainsUnresolvedPopulationAndBlocksNewRuns() async throws {
        let (model, root, bundle) = try fixture(comparisonExecutor: { proposal, _, _, _, support in
            let casesRoot = support.appendingPathComponent("Cases")
            let result = try await AutomationFixComparison(cases: .init(root: casesRoot)).run(
                baseline: proposal.baseline, candidate: proposal.candidate, attemptsPerBuild: proposal.attemptsPerBuild,
                beforeApproval: proposal.beforeApproval, afterApproval: proposal.afterApproval, limits: proposal.limits,
                beforeExecutor: NativeSearchInterruptedExecutor(), afterExecutor: NativeSearchFactExecutor())
            try Data("archive unavailable".utf8).write(to: casesRoot.appendingPathComponent("FixComparisons"))
            return result
        })
        try await saveFailure(model: model, root: root)
        model.selectFixedBundle(try fixedBundle(root: root, baseline: bundle))
        await model.checkFix()
        XCTAssertEqual(model.comparisonReport?.interruption?.dispatchMayHaveOccurred, true)
        XCTAssertNotNil(model.message); XCTAssertFalse(model.canRun); XCTAssertFalse(model.canReproduceSavedFailure)
    }
    func testSavedSelectionChangeDuringHeldReproductionPreflightNeverDispatches() async throws {
        let gate = NativeExecutionGate(), calls = NativeDispatchCount()
        let (model, root, _) = try fixture(reproductionExecutor: { _, _, _, _, _ in
            await calls.increment(); throw NativeTestError.unexpectedExecution
        }, reproductionPreflightReader: { frozen, attemptID, root in
            let cases = try AutomationCaseStore(root: root)
            let stored = try await cases.load(id: frozen.plan.id, revision: frozen.plan.revision, digest: frozen.digest)
            let original = try await cases.loadAttempt(id: attemptID, frozen: stored)
            await gate.enter()
            return (stored, original)
        })
        try await saveFailure(model: model, root: root)
        let before = try XCTUnwrap(model.savedViewedReport)
        let reproduction = Task { await model.reproduceSavedFailure() }
        await gate.waitUntilEntered()
        XCTAssertTrue(model.busy)
        // Saved-result navigation is disabled while preflight owns the operation.
        model.clearSavedView(); model.savedViewedReport = before
        await gate.release(); await reproduction.value
        let dispatches = await calls.value
        XCTAssertEqual(dispatches, 0); XCTAssertFalse(model.busy); XCTAssertNil(model.reproductionReport)
        XCTAssertNotNil(model.message)
    }
    func testPreparedSourceReproductionKeepsExactHostContextAndRejectsHostDrift() async throws {
        let (model, root, _) = try fixture(reproductionExecutor: { proposal, subject, _, support, _ in
            guard case .prepared = subject else { throw NativeTestError.unexpectedExecution }
            return try await AutomationReproduction(cases: .init(root: support.appendingPathComponent("Cases"))).run(
                frozen: proposal.frozen, originalAttemptID: proposal.originalAttemptID, approval: proposal.approval,
                limits: proposal.limits, executor: NativeSearchFactExecutor(fails: true))
        })
        try selectPreparedSource(model: model, root: root)
        let frozen = try await saveFailure(model: model, root: root)
        XCTAssertTrue(model.canReproduceSavedFailure)
        await model.reproduceSavedFailure()
        XCTAssertTrue(model.reproductionReport?.complete == true); XCTAssertEqual(model.reproductionReport?.matchingFailures, 5)
        XCTAssertNil(model.message)
        let previousRun = model.reproductionReport?.runID
        await model.showSavedCase(frozen)
        model.prepared?.host.hostProductDigest = String(repeating: "f", count: 64)
        await model.reproduceSavedFailure()
        XCTAssertFalse(model.canReproduceSavedFailure); XCTAssertEqual(model.reproductionReport?.runID, previousRun)
    }
    func testSavedReproductionRejectsRuntimeDriftBeforeExecution() async throws {
        let identity = RuntimeIdentity(), (model, root, _) = try fixture(runtime: identity,
            reproductionExecutor: { _, _, _, _, _ in throw NativeTestError.unexpectedExecution })
        try await saveFailure(model: model, root: root); identity.change()
        await model.reproduceSavedFailure()
        XCTAssertNil(model.reproductionReport); XCTAssertFalse(model.busy)
        XCTAssertTrue(model.message?.contains("runtime and locale") == true)
    }
    func testCloseDrainsReproductionAndArchiveFailureRetainsUncertainty() async throws {
        let gate = NativeExecutionGate()
        let (model, root, _) = try fixture(reproductionExecutor: { proposal, _, _, support, _ in
            let casesRoot = support.appendingPathComponent("Cases")
            let result = try await AutomationReproduction(cases: .init(root: casesRoot)).run(
                frozen: proposal.frozen, originalAttemptID: proposal.originalAttemptID, approval: proposal.approval,
                limits: proposal.limits, executor: NativeSearchInterruptedExecutor(gate: gate))
            try Data("archive unavailable".utf8).write(to: casesRoot.appendingPathComponent("Reproductions"))
            return result
        })
        try await saveFailure(model: model, root: root)
        let reproduction = Task { await model.reproduceSavedFailure() }
        await gate.waitUntilEntered()
        let closing = Task { await model.closeAndWait() }
        await Task.yield(); XCTAssertTrue(model.busy)
        await gate.release(); await closing.value; await reproduction.value
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.message)
        XCTAssertEqual(model.reproductionReport?.interruption?.dispatchMayHaveOccurred, true)
        XCTAssertTrue(model.savedReproductions.isEmpty)
        XCTAssertFalse(model.canRun); XCTAssertFalse(model.canReproduceSavedFailure)
    }
    func testUISelectionPreviewNeedsNoSystemCatalogAndKeepsOracleSeparate() throws {
        let (model, _, _) = try fixture()
        XCTAssertTrue(model.isInstalledUI); XCTAssertNil(model.prepared); XCTAssertNil(model.action)
        let navigation = try model.previewCommand()
        model.uiExpectedText = "Personal task complete"
        let assessed = try model.previewCommand()
        XCTAssertNotEqual(navigation.digest, assessed.digest)
        XCTAssertEqual(assessed.maximumActions, 30); XCTAssertEqual(assessed.bundleID, "example.Selected")
        let id = UUID(); XCTAssertEqual(try model.requestCommand(id: id, digest: assessed.digest).state, "awaitingApproval")
        XCTAssertFalse(model.busy); XCTAssertNil(model.report)
    }
    func testChangedWorkflowOracleRuntimeOrInstallChoiceInvalidatesQueuedApproval() throws {
        for change in 0..<7 {
            let identity = RuntimeIdentity(), (model, _, _) = try fixture(runtime: identity)
            let id = UUID(), preview = try model.previewCommand()
            _ = try model.requestCommand(id: id, digest: preview.digest)
            switch change {
            case 0: model.uiInstruction = "Open another screen"
            case 1: model.uiEndpoint = "Different destination"
            case 2: model.uiApprovedText = "Changed input"
            case 3: model.uiExpectedText = "Changed requirement"
            case 4: model.installApproved.toggle()
            case 5: model.disposable.toggle()
            default: identity.change()
            }
            model.run()
            XCTAssertEqual(try model.commandStatus(id: id).state, "invalidated")
            XCTAssertFalse(model.busy); XCTAssertNil(model.report)
        }
    }
    func testNativeReadonlyPhraseSearchUsesFixedOracleAndSavesRevalidatedHistory() async throws {
        let (model, _, _) = try fixture(searchExecutor: { proposal, subject, _, support, _ in
            guard case .installedUI = subject else { throw NativeTestError.unexpectedExecution }
            let cases = try AutomationCaseStore(root: support.appendingPathComponent("Cases"))
            return try await AutomationFailureSearch(cases: cases).run(baseline: proposal.baseline, mutations: proposal.mutations,
                approval: proposal.approval, capabilities: .init(), executor: NativeSearchFactExecutor())
        })
        model.uiObservationLabel = "Volume"; model.uiObservationProperty = "value"; model.uiExpectedText = "50%"
        model.uiAlternatePhrases = "Show the task list"
        XCTAssertTrue(model.canFindFailures)
        await model.findFailures()
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.searchReport?.attempts.count, 4); XCTAssertEqual(model.searchReport?.counters.assessed, 4)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.savedSearches.count, 1)
        let saved = try XCTUnwrap(model.savedSearches.first)
        XCTAssertEqual(saved.baseline.plan.requirements[0].expected, .text("50%"))
        XCTAssertEqual(saved.mutations[0].frozen.plan.requirements, saved.baseline.plan.requirements)
    }
    func testPhraseSearchCannotEnterFixtureOrExternalWritesOrUnassessedWorkflow() throws {
        let (model, _, _) = try fixture()
        model.uiAlternatePhrases = "Show tasks"; XCTAssertFalse(model.canFindFailures)
        model.uiExpectedText = "Complete"; XCTAssertTrue(model.canFindFailures)
        for effects in ["fixture", "external"] {
            model.effectChoice = effects; model.disposable = true
            XCTAssertFalse(model.canFindFailures)
        }
        model.effectChoice = "navigation"; model.uiAlternatePhrases = "A\nB\nC"; XCTAssertFalse(model.canFindFailures)
        model.uiAlternatePhrases = "A\nA"; XCTAssertFalse(model.canFindFailures)
    }
    func testPropertyChecksRequireAVisibleLocatorAndTextIgnoresHiddenPreviousLabel() throws {
        let (model, _, _) = try fixture()
        model.uiExpectedText = "50%"; model.uiObservationProperty = "value"
        XCTAssertFalse(model.canRun)
        model.uiObservationLabel = "Volume"; XCTAssertTrue(model.canRun)
        model.uiObservationProperty = "text"; model.uiExpectedText = "Complete"
        let preview = try model.previewCommand()
        model.uiObservationLabel = ""
        XCTAssertEqual(try model.previewCommand().digest, preview.digest)
    }
    func testArchiveFailureRetainsUncertainSearchAndBlocksNewExecution() async throws {
        let (model, _, _) = try fixture(searchExecutor: { proposal, _, _, support, _ in
            let casesRoot = support.appendingPathComponent("Cases")
            let cases = try AutomationCaseStore(root: casesRoot)
            let result = try await AutomationFailureSearch(cases: cases).run(baseline: proposal.baseline, mutations: proposal.mutations,
                approval: proposal.approval, capabilities: .init(), executor: NativeSearchInterruptedExecutor())
            try Data("archive path unavailable".utf8).write(to: casesRoot.appendingPathComponent("Searches"))
            return result
        })
        model.uiExpectedText = "Complete"; model.uiAlternatePhrases = "Show tasks"
        await model.findFailures()
        XCTAssertEqual(model.searchReport?.interruptions.count, 1)
        XCTAssertEqual(model.searchReport?.interruptions.first?.dispatchMayHaveOccurred, true)
        XCTAssertNotNil(model.message); XCTAssertTrue(model.savedSearches.isEmpty)
        XCTAssertFalse(model.canRun); XCTAssertFalse(model.canFindFailures)
    }
    func testCloseAndWaitDrainsSearchAndRetainsItsInterruptedHistory() async throws {
        let gate = NativeExecutionGate()
        let (model, _, _) = try fixture(searchExecutor: { proposal, _, _, support, _ in
            try await AutomationFailureSearch(cases: .init(root: support.appendingPathComponent("Cases"))).run(
                baseline: proposal.baseline, mutations: proposal.mutations, approval: proposal.approval, capabilities: .init(),
                executor: NativeSearchInterruptedExecutor(gate: gate))
        })
        model.uiExpectedText = "Complete"; model.uiAlternatePhrases = "Show tasks"
        let searching = Task { await model.findFailures() }
        await gate.waitUntilEntered(); model.close()
        let closing = Task { await model.closeAndWait() }
        await gate.release(); await closing.value; await searching.value
        XCTAssertFalse(model.busy); XCTAssertFalse(model.canRun); XCTAssertFalse(model.canFindFailures)
        XCTAssertEqual(model.searchReport?.interruptions.count, 1)
        await model.findFailures()
        let calls = await gate.calls; XCTAssertEqual(calls, 1)
    }
    func testChangedProductCannotBeSilentlyAdoptedByPreview() throws {
        let (model, _, bundle) = try fixture()
        _ = try model.previewCommand()
        try Data("changed".utf8).write(to: bundle.appendingPathComponent("resource.txt"))
        XCTAssertThrowsError(try model.previewCommand())
        XCTAssertFalse(model.busy)
    }
    func testCloseAndWaitDrainsCapturedTaskAndRejectsNewWorkAfterDrain() async throws {
        let gate = NativeExecutionGate()
        let (model, _, _) = try fixture(executor: { subject, plan, approval, _, attemptID, _ in
            guard case .installedUI = subject else { throw NativeTestError.unexpectedExecution }
            await gate.enter()
            return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan, attemptID: attemptID,
                subjectDispatched: true, subjectCompleted: true, observations: []), receipts: [], resourcesReleased: true)
        })
        let preview = try model.previewCommand()
        model.run(); await gate.waitUntilEntered()
        model.close()
        let closing = Task { await model.closeAndWait() }
        await gate.release(); await closing.value
        XCTAssertFalse(model.busy); XCTAssertFalse(model.canRun); XCTAssertFalse(model.canPrepare)
        XCTAssertThrowsError(try model.previewCommand())
        XCTAssertThrowsError(try model.requestCommand(id: UUID(), digest: preview.digest))
        model.run(); model.prepare()
        let calls = await gate.calls; XCTAssertEqual(calls, 1)
        XCTAssertFalse(model.busy)
    }
}
private actor NativeSearchAlternatingExecutor: AutomationCampaignAttemptExecutor {
    var count = 0
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        count += 1
        return await NativeSearchFactExecutor(fails: count % 2 == 0).execute(frozen: frozen, approval: approval, attemptID: attemptID, budget: budget)
    }
}
private actor NativeSearchInterruptedExecutor: AutomationCampaignAttemptExecutor {
    let gate: NativeExecutionGate?
    init(gate: NativeExecutionGate? = nil) { self.gate = gate }
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        if let gate { await gate.enter() }
        throw CancellationError()
    }
}
actor NativeSearchFactExecutor: AutomationCampaignAttemptExecutor {
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) -> AutomationAttemptReport {
        // Source contract fixture; not a device or accessibility proof.
        let plan = frozen.plan, observer = plan.observations[0]
        let fact = AutomationObservation(id: observer.id, app: plan.app, target: plan.target, environmentID: plan.environmentID,
            attemptID: attemptID, stepID: observer.id, route: .ui, proof: .visibleState, value: fails ? .text("unexpected observed value") : plan.requirements[0].expected)
        let receipts = [plan.execution, observer].enumerated().map { index, segment in
            AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: attemptID, segmentID: segment.id, leaseGeneration: index + 1),
                app: plan.app, target: plan.target, segmentID: segment.id, route: .ui, dispatched: true, completed: true,
                observations: segment.phase == .observe ? [fact] : [])
        }
        return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan, attemptID: attemptID,
            subjectDispatched: true, subjectCompleted: true, observations: [fact]), receipts: receipts, resourcesReleased: true)
    }
}
private enum NativeTestError: Error { case unexpectedExecution }
final class RuntimeIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var value = String(repeating: "a", count: 64)
    func read() -> String { lock.withLock { value } }
    func change() { lock.withLock { value = String(repeating: "b", count: 64) } }
}
private actor NativeDispatchCount {
    var value = 0
    func increment() { value += 1 }
}
private actor NativeDualReadGate {
    private var entered = 0
    private var waiting: CheckedContinuation<Void, Never>?
    private var exits: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered += 1
        if entered == 2 { waiting?.resume(); waiting = nil }
        await withCheckedContinuation { exits.append($0) }
    }
    func waitUntilTwo() async { if entered < 2 { await withCheckedContinuation { waiting = $0 } } }
    func release() { for exit in exits { exit.resume() }; exits.removeAll() }
}
private actor NativeExecutionGate {
    var calls = 0
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var exitWaiter: CheckedContinuation<Void, Never>?
    func enter() async {
        calls += 1; entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { exitWaiter = $0 }
    }
    func waitUntilEntered() async {
        if calls > 0 { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { exitWaiter?.resume(); exitWaiter = nil }
}
// Synthetic contract facts only; these helpers do not represent device execution.
private func nativeFreshFact(plan: AutomationCase, approval: RunApproval, attemptID: String, completed: Bool) -> AutomationAttemptReport {
    let prefix = plan.setup[0].attemptTextBindings!["approvedText"]!
    let name = try! AutomationAttemptText.value(prefix: prefix, attemptID: attemptID)
    let record: (Bool) -> AutomationValue = { state in .array([.object(["entity": .entity(typeID: "TaskEntity", value: "entity-" + attemptID),
        "properties": .object(["title": .text(name), "completed": .bool(state)])])]) }
    let observer = plan.observations[0]
    let fact = AutomationObservation(id: observer.id, app: plan.app, target: plan.target, environmentID: plan.environmentID,
        attemptID: attemptID, stepID: observer.id, route: .systemQuery, proof: .appState, value: record(completed))
    let receipts = (plan.setup + [plan.execution] + plan.observations).enumerated().map { index, segment in
        AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: attemptID, segmentID: segment.id, leaseGeneration: index + 1),
            app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind, dispatched: true, completed: true,
            observations: segment.phase == .observe ? [fact] : [], verifiedOutputs: segment.kind == .systemQuery ? ["record": record(segment.phase == .observe && completed)] : nil, environmentID: plan.environmentID)
    }
    return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan, attemptID: attemptID, subjectDispatched: true,
        subjectCompleted: true, observations: [fact], receipts: receipts, runID: approval.runID), receipts: receipts, resourcesReleased: true)
}
private func nativeFreshToken(plan: AutomationCase, approval: RunApproval, prepared: AutomationPreparedApplication, prefix: String) throws -> AutomationQualifiedFreshFixture {
    let context = AutomationRecipeContext(app: plan.app, target: plan.target, environmentID: plan.environmentID,
        catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog), hostDigest: prepared.host.hostProductDigest,
        localeIdentifier: plan.provenance["ui.locale"]!, uiRuntimeManifestDigest: plan.provenance["ui.runtimeManifestDigest"])
    return try .init(bindings: AutomationFreshEntityPlanner.bindings(plan: plan), evidence: [1, 2].map { index in
        .init(context: context, plan: plan, approval: approval, report: nativeFreshFact(plan: plan, approval: approval, attemptID: prefix + String(index), completed: false))
    })
}
private struct FreshQualificationInputs: Sendable {
    let frozen: AutomationFrozenCase
    let approval: RunApproval
    let capabilities: CapabilityProfile
    let prepared: AutomationPreparedApplication
    let runtime: AutomationUIRuntime
    let token: AutomationQualifiedFreshFixture
}
// Records the qualification gate's calls; reports are synthetic contract facts, not device execution.
private actor FreshQualificationRunner: AutomationFreshFixtureQualifyingRunner {
    struct Run: Sendable {
        let attemptID: String
        let preparedSubjectChecked: Bool
        let plan: AutomationCase
        let approval: RunApproval
        let allowBootAndInstall: Bool
        let receivedVerifiedCapabilities: Bool
        let uiRuntimeBundle: URL?
        let hadFixtureTracker: Bool
        let qualifyingBindings: [AutomationFreshFixtureBinding]?
        let limits: AutomationCampaignLimits?
        let usage: AutomationCampaignUsage?
    }
    static let validationError = AutomationContractError.missingEvidence("Fake live attempt validation failed")
    private static let marker = "test.freshQualification.verified"
    let token: AutomationQualifiedFreshFixture
    let alter: @Sendable (Int, inout AutomationAttemptReport) -> Void
    let validationFailure: Int?
    let cancelAfterRun: Int?
    private(set) var capabilityCalls = 0
    private(set) var runs: [Run] = []
    private(set) var validations = 0
    private(set) var qualifications = 0
    private var capabilitySubjectWasPrepared = false
    init(token: AutomationQualifiedFreshFixture, alter: @escaping @Sendable (Int, inout AutomationAttemptReport) -> Void = { _, _ in },
         validationFailure: Int? = nil, cancelAfterRun: Int? = nil) {
        self.token = token; self.alter = alter; self.validationFailure = validationFailure; self.cancelAfterRun = cancelAfterRun
    }
    func capabilitiesForExecution(subject: AutomationApplicationSubject, plan: AutomationCase, capabilities: CapabilityProfile) -> CapabilityProfile {
        capabilityCalls += 1
        if case .prepared = subject { capabilitySubjectWasPrepared = true }
        var verified = capabilities
        verified.records[Self.marker] = .init(state: .available, reason: "Fake runner verification", probeVersion: "test-v1", evidence: ["fake"])
        return verified
    }
    func run(prepared: AutomationPreparedApplication, plan: AutomationCase, approval: RunApproval, capabilities: CapabilityProfile,
             attemptID: String, allowBootAndInstall: Bool, campaignBudget: AutomationCampaignBudget?, uiRuntime: AutomationUIRuntime?,
             fixtureTracker: AutomationFreshFixtureTracker?, qualifyingFreshBindings: [AutomationFreshFixtureBinding]?) async throws -> AutomationAttemptReport {
        let index = runs.count
        let limits = await campaignBudget?.limits, usage = await campaignBudget?.snapshot()
        runs.append(.init(attemptID: attemptID, preparedSubjectChecked: capabilitySubjectWasPrepared, plan: plan, approval: approval,
            allowBootAndInstall: allowBootAndInstall, receivedVerifiedCapabilities: capabilities.records[Self.marker] != nil,
            uiRuntimeBundle: uiRuntime?.bundleURL, hadFixtureTracker: fixtureTracker != nil, qualifyingBindings: qualifyingFreshBindings,
            limits: limits, usage: usage))
        var report = nativeFreshFact(plan: plan, approval: approval, attemptID: attemptID, completed: false)
        alter(index, &report)
        if cancelAfterRun == index { withUnsafeCurrentTask { $0?.cancel() } }
        return report
    }
    func validateFreshFixtureAttempt(bindings: [AutomationFreshFixtureBinding]) throws {
        validations += 1
        if validations == validationFailure { throw Self.validationError }
    }
    func qualifyFreshFixture(bindings: [AutomationFreshFixtureBinding]) -> AutomationQualifiedFreshFixture {
        qualifications += 1
        return token
    }
}
private struct NativeFreshFactExecutor: AutomationFreshFixtureAttemptExecutor {
    let completed: Bool
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
        XCTFail("Mutating repetition skipped fresh fixture authority"); throw NativeTestError.unexpectedExecution
    }
    func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget, fixtureTracker: AutomationFreshFixtureTracker) async throws -> AutomationAttemptReport {
        let report = nativeFreshFact(plan: frozen.plan, approval: approval, attemptID: attemptID, completed: completed)
        try await fixtureTracker.reserveBeforeSubject(receipts: Array(report.receipts.prefix(2)), plan: frozen.plan, approval: approval, attemptID: attemptID)
        try await budget.reserveOperations(id: attemptID + ".subject", phase: .subject, count: 1)
        return report
    }
}
#endif
