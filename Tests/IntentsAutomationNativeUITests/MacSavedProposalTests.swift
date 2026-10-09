#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore
@testable import IntentsAutomationNativeUI

final class MacSavedProposalTests: XCTestCase, @unchecked Sendable {
    struct Fixture: Sendable {
        let root: URL, selected: AutomationInstalledMacUIApplication, frozen: AutomationFrozenCase, original: AutomationAttemptReport
        let evidence: AutomationPrivateMacDaemonUnit.Evidence
        var dependencies: AutomationMacSavedWorkflowContract.Dependencies {
            .init(currentTarget: { selected.target }, runtime: { _ in evidence }, locale: { "en_GB" })
        }
    }
    func product(_ root: URL, name: String, bundleID: String = "example.SavedMac", version: String = "1") throws -> URL {
        let bundle = root.appendingPathComponent(name + ".app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
            "CFBundleSupportedPlatforms": ["MacOSX"], "CFBundleVersion": version], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try binary().write(to: bundle.appendingPathComponent("Contents/MacOS/Fixture")); return bundle
    }
    func fixture(environment: String? = nil, locale: String = "en_GB", receipt: String = AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256,
                 mutating: Bool = false, unsupported: Bool = false) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/saved-mac-contract-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let selected = try AutomationInstalledMacUIApplication(bundleURL: product(root, name: "Before"), target: .init(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-login"))
        var subject = AutomationSegment(id: "subject", kind: .ui, phase: .subject, operation: "Open", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        subject.uiProgram = .init(operations: [.init(id: "tap", kind: .tap, locator: .init(.label, "Ready"))])
        if mutating { subject.effects.insert(.fixtureWrite) }
        if unsupported { subject.uiProgram = .init(operations: [.init(id: "fill", kind: .fillBinding, locator: .init(.label, "Name"), binding: "name")], bindings: ["name": "value"]) }
        var observer = subject; observer.id = "observer"; observer.phase = .observe; observer.effects = [.observe, .navigate]
        observer.uiProgram = .init(operations: [.init(id: "status", kind: .observeProperty, locator: .init(.testId, "status"), property: "text")])
        var plan = AutomationCase(id: "saved-mac", app: selected.app, target: selected.target, environmentID: environment ?? "selected-mac-session:synthetic-login",
            execution: subject, observations: [observer], requirements: [.init(observationID: "observer", expected: .text("Expected"), proof: .visibleState, justification: "Independent UI state")])
        plan.provenance["ui.locale"] = locale; plan.provenance["ui.privateMacReceiptSHA256"] = receipt
        let frozen = try AutomationFrozenCase(plan: plan)
        let observation = AutomationObservation(id: "observer", app: plan.app, target: plan.target, environmentID: plan.environmentID,
            attemptID: "original", stepID: "observer", route: .ui, proof: .visibleState, value: .text("Different"))
        let receipts = [subject, observer].enumerated().map { index, segment in
            AutomationSegmentReceipt(scope: .init(runID: "original-run", attemptID: "original", segmentID: segment.id, leaseGeneration: index + 1),
                app: plan.app, target: plan.target, segmentID: segment.id, route: .ui, dispatched: true, completed: true,
                observations: segment.phase == .observe ? [observation] : [], environmentID: plan.environmentID)
        }
        let original = AutomationAttemptReport(attemptID: "original", result: AutomationAssessment.assess(plan: plan, attemptID: "original", subjectDispatched: true,
            subjectCompleted: true, observations: [observation], receipts: receipts, runID: "original-run"), receipts: receipts, resourcesReleased: true)
        let evidence = AutomationPrivateMacDaemonUnit.Evidence(receiptSHA256: AutomationPrivateMacDaemonUnit.pinnedProgramReceiptSHA256,
            checkpointSHA256: String(repeating: "b", count: 64), fileCount: 5473, customerRuntimeEnabled: false, hardwareQualified: false, developerIDSigned: false)
        return .init(root: root, selected: selected, frozen: frozen, original: original, evidence: evidence)
    }
    private func binary() -> Data {
        var bytes = Data(repeating: 0, count: 56)
        for (offset, value) in [(0, UInt32(0xfeedfacf)), (4, 0x0100000c), (12, 2), (16, 1), (20, 24), (32, 0x32), (36, 24), (40, 1)] {
            for byte in 0..<4 { bytes[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
        }
        return bytes
    }
    func testMacReproductionProposalRetainsReviewedCaseAndRunsFiveCanonicalAttempts() async throws {
        let f = try fixture()
        let review = try AutomationMacSavedWorkflowContract.reproduction(frozen: f.frozen, original: f.original,
            selected: f.selected, runtimeRoot: f.root, runID: "reproduce", dependencies: f.dependencies)
        let proposal = AutomationNativeUIReproductionProposal.fromMacReview(review)
        XCTAssertEqual(proposal.frozen, f.frozen); XCTAssertEqual(proposal.approval, review.approval)
        XCTAssertFalse(proposal.usesFreshFixture); XCTAssertFalse(proposal.approval.disposable)
        let cases = try AutomationCaseStore(root: f.root.appendingPathComponent("Cases"))
        _ = try await cases.freeze(f.frozen.plan); try await cases.saveAttempt(f.original, for: f.frozen)
        let report = try await proposal.runCampaign(cases: cases, executor: Facts(pass: false), fixture: nil)
        XCTAssertTrue(report.complete); XCTAssertEqual(report.matchingFailures, 5)
        XCTAssertEqual(report.frozen, f.frozen); XCTAssertEqual(report.originalFailure, f.original)
    }
    func testMacComparisonRetainsOriginalOracleAndRunsBothCanonicalPopulations() async throws {
        let f = try fixture(), afterURL = try product(f.root, name: "After", version: "2")
        let after = try AutomationInstalledMacUIApplication.comparisonCandidate(bundleURL: afterURL, target: f.selected.target, baseline: f.selected.app)
        let review = try AutomationMacSavedWorkflowContract.comparison(frozen: f.frozen, original: f.original,
            before: f.selected, after: after, runtimeRoot: f.root, runID: "compare", dependencies: f.dependencies)
        let proposal = AutomationNativeUIFixComparisonProposal.fromMacReview(review)
        XCTAssertEqual(proposal.baseline, f.frozen); XCTAssertEqual(proposal.candidate.plan.app, after.app)
        XCTAssertEqual(proposal.baseline.oracleDigest, proposal.candidate.oracleDigest)
        XCTAssertEqual(proposal.baseline.contractDigest, proposal.candidate.contractDigest)
        let cases = try AutomationCaseStore(root: f.root.appendingPathComponent("Cases"))
        let report = try await proposal.runCampaign(cases: cases, beforeExecutor: Facts(pass: false), afterExecutor: Facts(pass: true),
            beforeFixture: nil, afterFixture: nil)
        XCTAssertEqual(report.before.count, 30); XCTAssertEqual(report.after.count, 30)
        XCTAssertEqual(report.beforeCounters.failed, 30); XCTAssertEqual(report.afterCounters.failed, 0)
    }
    func testMacProposalDefaultExecutionStopsWithoutCanonicalAttempts() async throws {
        let f = try fixture()
        let review = try AutomationMacSavedWorkflowContract.reproduction(frozen: f.frozen, original: f.original,
            selected: f.selected, runtimeRoot: f.root, runID: "reproduce", dependencies: f.dependencies)
        let proposal = AutomationNativeUIReproductionProposal.fromMacReview(review)
        let cases = try AutomationCaseStore(root: f.root.appendingPathComponent("support/Cases"))
        _ = try await cases.freeze(f.frozen.plan); try await cases.saveAttempt(f.original, for: f.frozen)
        let report = try await proposal.execute(subject: .installedMacUI(f.selected), runtime: nil,
            support: f.root.appendingPathComponent("support"), developerDirectory: AutomationNativeToolchain.developerDirectory(), allowBootAndInstall: false)
        XCTAssertFalse(report.complete); XCTAssertTrue(report.attempts.isEmpty)
        XCTAssertEqual(report.stopReason, "Reproduction stopped before canonical evidence could be verified")
        XCTAssertEqual(report.interruption?.dispatchMayHaveOccurred, true)
    }
    func testMacComparisonAdapterForwardsSelectionWithoutSimulatorInstallation() async throws {
        let f = try fixture()
        let runner = try AutomationApplicationRunner(supportRoot: f.root.appendingPathComponent("support"),
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"))
        let selected = f.selected
        let executor = try AutomationNativeUIFixComparisonProposal.executor(subject: .installedMacUI(selected), runner: runner,
            runtime: nil, capabilities: .init(), factory: { subject, _, install, runtime in
                XCTAssertEqual(subject.app, selected.app); XCTAssertEqual(subject.target, selected.target)
                XCTAssertFalse(install); XCTAssertNil(runtime)
                return Facts(pass: false)
            })
        let review = try AutomationMacSavedWorkflowContract.reproduction(frozen: f.frozen, original: f.original,
            selected: selected, runtimeRoot: f.root, runID: "compare.before", dependencies: f.dependencies)
        let result = try await executor.execute(frozen: f.frozen, approval: review.approval, attemptID: "adapter",
            budget: .init(limits: .firstCampaign))
        XCTAssertEqual(result.result.summary, .assertionFailed)
    }
    func testProductionMacCompileRejectsUnverifiedRuntimeTree() throws {
        let f = try fixture()
        XCTAssertThrowsError(try AutomationNativeUIReproductionProposal.compileMac(frozen: f.frozen, original: f.original,
            selected: f.selected, runtimeRoot: f.root, runID: "reproduce"))
    }
    private final class RuntimeFacts: @unchecked Sendable {
        private let lock = NSLock()
        private var evidence: AutomationPrivateMacDaemonUnit.Evidence
        init(_ evidence: AutomationPrivateMacDaemonUnit.Evidence) { self.evidence = evidence }
        func read() -> AutomationPrivateMacDaemonUnit.Evidence { lock.withLock { evidence } }
        func change() { lock.withLock {
            evidence = .init(receiptSHA256: evidence.receiptSHA256, checkpointSHA256: String(repeating: "c", count: 64),
                fileCount: evidence.fileCount, customerRuntimeEnabled: evidence.customerRuntimeEnabled,
                hardwareQualified: evidence.hardwareQualified, developerIDSigned: evidence.developerIDSigned)
        } }
    }
    private actor Gate {
        var entered = false
        var entryWaiter: CheckedContinuation<Void, Never>?
        var releaseWaiter: CheckedContinuation<Void, Never>?
        func block() async {
            entered = true; entryWaiter?.resume(); entryWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        func waitUntilEntered() async { if !entered { await withCheckedContinuation { entryWaiter = $0 } } }
        func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    }
    private actor Calls { var value = 0; func increment() { value += 1 } }
    @MainActor private func store(_ f: Fixture, runtimeFacts: RuntimeFacts? = nil, enabled: Bool = true,
                                 gate: Gate? = nil, calls: Calls? = nil) async throws -> AppAutomationStore {
        let selected = f.selected, evidence = f.evidence
        let dependencies = AutomationMacSavedWorkflowContract.Dependencies(currentTarget: { selected.target },
            runtime: { _ in runtimeFacts?.read() ?? evidence }, locale: { "en_GB" })
        let runtime = AutomationNativeMacSavedRuntime(root: f.root,
            reproductionReviewer: { try AutomationMacSavedWorkflowContract.reproduction(frozen: $0, original: $1, selected: $2,
                runtimeRoot: $3, runID: $4, dependencies: dependencies) },
            comparisonReviewer: { try AutomationMacSavedWorkflowContract.comparison(frozen: $0, original: $1, before: $2, after: $3,
                runtimeRoot: $4, runID: $5, dependencies: dependencies) })
        let provider: (@Sendable () throws -> AutomationNativeMacSavedRuntime)? = enabled ? { @Sendable in runtime } : nil
        let model = AppAutomationStore(supportDirectory: f.root.appendingPathComponent("support"),
            macSavedRuntimeProvider: provider,
            comparisonExecutor: { proposal, before, after, runtime, support in
                XCTAssertEqual(before.target.kind, .nativeMac); XCTAssertEqual(after.target.kind, .nativeMac); XCTAssertNil(runtime)
                return try await proposal.runCampaign(cases: .init(root: support.appendingPathComponent("Cases")),
                    beforeExecutor: Facts(pass: false), afterExecutor: Facts(pass: true), beforeFixture: nil, afterFixture: nil)
            }, reproductionExecutor: { proposal, subject, runtime, support, install in
                await calls?.increment()
                XCTAssertEqual(subject.target.kind, .nativeMac); XCTAssertFalse(install); XCTAssertNil(runtime)
                return try await proposal.runCampaign(cases: .init(root: support.appendingPathComponent("Cases")), executor: Facts(pass: false), fixture: nil)
            }, reproductionPreflightReader: { frozen, _, _ in
                await gate?.block(); return (frozen, f.original)
            }, nativeMacTargetReader: { selected.target })
        model.select(selected.bundleURL); model.effectChoice = "navigation"; model.effectsConfirmed = true; model.installApproved = false
        let cases = try AutomationCaseStore(root: f.root.appendingPathComponent("support/Cases"))
        _ = try await cases.freeze(f.frozen.plan); try await cases.saveAttempt(f.original, for: f.frozen)
        await model.showSavedCase(f.frozen)
        return model
    }
    @MainActor func testStoreMacSavedRequestKeepsSessionAndNeedsOwnConfirmation() async throws {
        let f = try fixture(), model = try await store(f)
        XCTAssertTrue(model.canReproduceSavedFailure)
        let preview = try await model.previewReproductionCommand(), id = UUID()
        XCTAssertEqual(preview.environmentID, f.frozen.plan.environmentID); XCTAssertFalse(preview.installApproved)
        XCTAssertFalse(preview.disposable)
        let pending = try await model.requestReproductionCommand(id: id, digest: preview.digest)
        XCTAssertEqual(pending.state, "awaitingApproval"); XCTAssertNil(model.reproductionReport)
        await model.reproduceSavedFailure()
        XCTAssertEqual(try model.commandStatus(id: id).state, "completed")
        XCTAssertEqual(model.reproductionReport?.matchingFailures, 5); XCTAssertEqual(model.savedReproductions.count, 1)
    }
    @MainActor func testStoreMacComparisonRetainsChangedBuildAndUnchangedOracle() async throws {
        let f = try fixture(), model = try await store(f), afterURL = try product(f.root, name: "After", version: "2")
        XCTAssertTrue(model.canSelectFix); XCTAssertFalse(model.installApproved)
        model.selectFixedBundle(afterURL); XCTAssertTrue(model.canCheckFix)
        let preview = try await model.previewComparisonCommand(), id = UUID()
        XCTAssertFalse(preview.installApproved); XCTAssertFalse(preview.disposable)
        XCTAssertNotEqual(preview.beforeProductDigest, preview.afterProductDigest)
        _ = try await model.requestComparisonCommand(id: id, digest: preview.digest)
        await model.checkFix()
        XCTAssertEqual(try model.commandStatus(id: id).state, "completed")
        XCTAssertEqual(model.comparisonReport?.before.count, 30); XCTAssertEqual(model.comparisonReport?.after.count, 30)
        XCTAssertEqual(model.comparisonReport?.baseline.oracleDigest, f.frozen.oracleDigest)
        XCTAssertEqual(model.comparisonReport?.candidate.oracleDigest, f.frozen.oracleDigest)
        XCTAssertEqual(model.comparisonReport?.candidate.plan.app.canonicalBundlePath, afterURL.path)
    }
    @MainActor func testStoreMacQualificationDependencyIsAbsentByDefault() async throws {
        let f = try fixture(), model = try await store(f, enabled: false)
        XCTAssertFalse(model.canReproduceSavedFailure); XCTAssertFalse(model.canSelectFix)
        do { _ = try await model.previewReproductionCommand(); XCTFail() } catch {}
    }
    @MainActor func testQueuedMacRuntimeChangeNeverDispatches() async throws {
        let f = try fixture(), runtime = RuntimeFacts(f.evidence), calls = Calls()
        let model = try await store(f, runtimeFacts: runtime, calls: calls)
        let preview = try await model.previewReproductionCommand(), id = UUID()
        _ = try await model.requestReproductionCommand(id: id, digest: preview.digest)
        runtime.change(); await model.reproduceSavedFailure()
        XCTAssertEqual(try model.commandStatus(id: id).state, "invalidated"); XCTAssertNil(model.reproductionReport)
        let count = await calls.value; XCTAssertEqual(count, 0)
    }
    @MainActor func testSavedMacTargetChangeAcrossDurableReadRejectsPreview() async throws {
        let f = try fixture(), gate = Gate(), model = try await store(f, gate: gate)
        let preview = Task { try await model.previewReproductionCommand() }
        await gate.waitUntilEntered()
        model.selectedMacTarget?.loginSession = "changed-session"
        await gate.release()
        do { _ = try await preview.value; XCTFail() } catch {}
        XCTAssertNil(model.pendingCommandStatus)
    }
    private struct Facts: AutomationCampaignAttemptExecutor {
        let pass: Bool
        func execute(frozen: AutomationFrozenCase, approval: RunApproval, attemptID: String, budget: AutomationCampaignBudget) async throws -> AutomationAttemptReport {
            let plan = frozen.plan
            let observation = AutomationObservation(id: "observer", app: plan.app, target: plan.target, environmentID: plan.environmentID,
                attemptID: attemptID, stepID: "observer", route: .ui, proof: .visibleState, value: .text(pass ? "Expected" : "Different"))
            let receipts = ([plan.execution] + plan.observations).enumerated().map { index, segment in
                AutomationSegmentReceipt(scope: .init(runID: approval.runID, attemptID: attemptID, segmentID: segment.id, leaseGeneration: index + 1),
                    app: plan.app, target: plan.target, segmentID: segment.id, route: .ui, dispatched: true, completed: true,
                    observations: segment.phase == .observe ? [observation] : [], environmentID: plan.environmentID)
            }
            return .init(attemptID: attemptID, result: AutomationAssessment.assess(plan: plan, attemptID: attemptID,
                subjectDispatched: true, subjectCompleted: true, observations: [observation], receipts: receipts, runID: approval.runID),
                receipts: receipts, resourcesReleased: true)
        }
    }
}
#endif
