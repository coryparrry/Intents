import XCTest
@testable import IntentsAutomationCore

final class AutomationCaseStoreTests: XCTestCase, @unchecked Sendable {
    private func terminalUIAssertionFacts() throws -> (AutomationCase, AutomationAttemptReport, UIHostStepReceipt) {
        var plan = plan()
        plan.execution.kind = .ui; plan.execution.effects = [.navigate, .fixtureWrite]
        plan.execution.lifecycle = .persistedStateAcrossSegments
        plan.execution.uiProgram = .init(steps: [
            .init(id: "save", kind: .tap, query: .init(identifier: "save")),
            .init(id: "wrong-label", kind: .assert, query: .init(identifier: "title"), property: "label", equals: .init(kind: "text", value: "Wrong"))
        ])
        plan.observations[0].kind = .observeOnly
        plan.observations[0].uiProgram = .init(steps: [.init(id: "ready", kind: .readProperty, query: .init(identifier: "ready"), property: "exists")])
        plan.requirements[0].expected = .object(["ready": .bool(true)])
        let approval = RunApproval(runID: "run", app: plan.app, target: plan.target, environmentID: plan.environmentID,
            effects: [.observe, .navigate, .fixtureWrite], maximumActions: 20, disposable: true, approvedCaseDigest: try AutomationFrozenCase.planDigest(plan))
        let wire = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "attempt", leaseGeneration: 1)
        let failedIndex = try XCTUnwrap(wire.steps.firstIndex { $0.id == "wrong-label" })
        var data = try wire.steps.indices.prefix(failedIndex).map { index in
            try JSONEncoder().encode(UIHostStepReceipt(plan: wire, index: index, dispatched: true, completed: true))
        }
        let failed = UIHostStepReceipt(plan: wire, index: failedIndex, dispatched: true, completed: false, error: "assertionFailed")
        data.append(try JSONEncoder().encode(failed))
        let receipts = try AutomationXCUITestReceiptImporter.importReceipts(data, uiPlan: wire, plan: plan, allowPartial: true)
        var result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: false,
            observations: [], receipts: receipts, runID: "run", termination: .assertionFailed)
        result.subjectDispatchUncertain = true
        return (plan, .init(attemptID: "attempt", result: result, receipts: receipts, resourcesReleased: true), failed)
    }

    func testTerminalUIAssertionFailureSavesAndLoadsWithoutClaimingCompletedOracle() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/ui-assertion-case-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AutomationCaseStore(root: root)
        let (plan, facts, failed) = try terminalUIAssertionFacts()
        XCTAssertEqual(AutomationXCUITestRouteDriver.failureReason(error: nil, receipts: facts.receipts, stepReceipts: [failed], plan: plan), .assertionFailed)
        XCTAssertNotNil(facts.receipts.last?.terminalUIAssertionFailure)
        XCTAssertTrue(facts.result.subjectDispatchUncertain)
        XCTAssertFalse(facts.result.assessed); XCTAssertFalse(facts.result.evidenceComplete)
        XCTAssertFalse(facts.result.subjectCompleted)
        let frozen = try await store.freeze(plan)
        try await store.saveAttempt(facts, for: frozen)
        let loaded = try await store.loadAttempt(id: facts.attemptID, frozen: frozen)
        XCTAssertEqual(loaded, facts)
    }

    func testTerminalUIAssertionProofRejectsWrongStepDigestRouteTypeAndSummaryForgeries() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/ui-assertion-forgery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AutomationCaseStore(root: root)
        let (plan, facts, _) = try terminalUIAssertionFacts()
        let frozen = try await store.freeze(plan)
        var forgeries: [AutomationAttemptReport] = []
        var changed = facts; changed.receipts[0].terminalUIAssertionFailure?.stepID = "save"; forgeries.append(changed)
        changed = facts; changed.receipts[0].terminalUIAssertionFailure?.planDigest = String(repeating: "b", count: 64); forgeries.append(changed)
        changed = facts; changed.receipts[0].route = .systemIntent; forgeries.append(changed)
        changed = facts; changed.receipts[0].terminalUIAssertionFailure?.expected = .bool(false); forgeries.append(changed)
        changed = facts; changed.receipts[0].terminalUIAssertionFailure?.app.bundleID = "foreign.App"; forgeries.append(changed)
        changed = facts; changed.receipts[0].terminalUIAssertionFailure?.scope.leaseGeneration += 1; forgeries.append(changed)
        changed = facts
        var terminal = try JSONDecoder().decode(UIHostStepReceipt.self, from: changed.receipts[0].terminalUIAssertionFailure!.terminalReceipt)
        terminal.kind = .invokeIntent
        let altered = try JSONEncoder().encode(terminal)
        changed.receipts[0].terminalUIAssertionFailure?.terminalReceipt = altered
        changed.receipts[0].terminalUIAssertionFailure?.terminalReceiptDigest = AutomationArtifactRegistry.digest(altered)
        forgeries.append(changed)
        changed = facts; changed.receipts[0].terminalUIAssertionFailure = nil; forgeries.append(changed)
        changed = facts; changed.result.summary = .passed; forgeries.append(changed)
        changed = facts; changed.result.assessed = true; changed.result.evidenceComplete = true; forgeries.append(changed)
        for forged in forgeries {
            XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: forged, plan: plan))
            do { try await store.saveAttempt(forged, for: frozen); XCTFail("Forged terminal UI proof was stored") } catch { }
        }
        let attempts = try await store.attempts(for: frozen)
        XCTAssertTrue(attempts.isEmpty)
    }
    private func plan() -> AutomationCase {
        .init(id: "business-case", app: .init(logicalID: "app", bundleID: "example.App", platform: "ios", productDigest: String(repeating: "a", count: 64)),
            target: .init(id: "owned", kind: .simulator), environmentID: "synthetic",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "ActualAction"),
            observations: [.init(id: "observe", kind: .ui, phase: .observe, operation: "Read")],
            requirements: [.init(observationID: "observe", expected: .bool(true), proof: .visibleState, justification: "Developer-selected business requirement")])
    }
    private func report(_ plan: AutomationCase) -> AutomationAttemptReport {
        let observation = AutomationObservation(id: "observe", app: plan.app, target: plan.target, environmentID: plan.environmentID,
            attemptID: "attempt", stepID: "observe", route: .ui, proof: .visibleState, value: .bool(true))
        let receipts: [AutomationSegmentReceipt] = [
            .init(scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 1), app: plan.app, target: plan.target,
                  segmentID: "subject", route: .systemIntent, dispatched: true, completed: true),
            .init(scope: .init(runID: "run", attemptID: "attempt", segmentID: "observe", leaseGeneration: 2), app: plan.app, target: plan.target,
                  segmentID: "observe", route: .ui, dispatched: true, completed: true, observations: [observation])]
        let assessment = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [observation])
        return .init(attemptID: "attempt", result: assessment, receipts: receipts, resourcesReleased: true)
    }
    func testDefinitionsAndAttemptsAreImmutableAndLoadWithoutExecution() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let store = try AutomationCaseStore(root: root), plan = plan()
        let first = try await store.freeze(plan), same = try await store.freeze(plan)
        XCTAssertEqual(first, same)
        let loaded = try await store.load(id: plan.id, revision: plan.revision, digest: first.digest)
        XCTAssertEqual(loaded, first)
        let facts = report(plan); try await store.saveAttempt(facts, for: first)
        let stored = try await store.loadAttempt(id: "attempt", frozen: first); XCTAssertEqual(stored, facts)
        let definitions = try await store.definitions(); XCTAssertEqual(definitions, [first])
        let attempts = try await store.attempts(for: first); XCTAssertEqual(attempts, [facts])
        do { try await store.saveAttempt(facts, for: first); XCTFail("Attempt overwrite accepted") } catch { }
        var changed = plan; changed.requirements[0].expected = .bool(false)
        do { _ = try await store.freeze(changed); XCTFail("Same revision overwrite accepted") } catch { }
        changed.revision += 1; _ = try await store.freeze(changed)
    }
    func testReadOnlyPreparedCaseWithoutAttemptsIsEmptyAndDoesNotCreateHistory() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try AutomationCaseStore(root: root)
        let frozen = try await writer.freeze(plan())
        let reader = try AutomationCaseStore(readOnlyRoot: root)
        let attempts = try await reader.attempts(for: frozen)
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Attempts").path))
        do { _ = try await reader.loadAttempt(id: "missing", frozen: frozen); XCTFail("Invented a missing attempt") } catch {}
        let originalReport = report(frozen.plan)
        try await writer.saveAttempt(originalReport, for: frozen)
        var next = frozen.plan; next.revision += 1
        let unused = try await writer.freeze(next)
        let unusedAttempts = try await reader.attempts(for: unused)
        XCTAssertTrue(unusedAttempts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Attempts/" + unused.digest).path))
        let originalAttempts = try await reader.attempts(for: frozen)
        XCTAssertEqual(originalAttempts, [originalReport])
    }
    func testReadOnlyAttemptListingRejectsSymlinksAndFilesInsteadOfTreatingThemAsEmpty() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try AutomationCaseStore(root: root)
        let frozen = try await writer.freeze(plan())
        let reader = try AutomationCaseStore(readOnlyRoot: root)
        let attempts = root.appendingPathComponent("Attempts")
        for destination in [root.appendingPathComponent("Definitions"), root.appendingPathComponent("absent")] {
            try FileManager.default.createSymbolicLink(at: attempts, withDestinationURL: destination)
            do { _ = try await reader.attempts(for: frozen); XCTFail("Accepted a history directory alias") } catch {}
            try FileManager.default.removeItem(at: attempts)
        }
        try Data().write(to: attempts)
        do { _ = try await reader.attempts(for: frozen); XCTFail("Accepted a file as history") } catch {}
    }
    func testCaseApprovalBindsInputsRouteObserversAndOracleExactly() throws {
        let plan = plan()
        var approval = RunApproval(runID: "run", app: plan.app, target: plan.target, environmentID: plan.environmentID, effects: [.observe], maximumActions: 10, disposable: true)
        XCTAssertThrowsError(try PlanValidator.validate(plan, approval: approval, capabilities: .init()))
        approval.approvedCaseDigest = try AutomationFrozenCase.planDigest(plan)
        try PlanValidator.validate(plan, approval: approval, capabilities: .init())
        var changed = plan; changed.requirements[0].expected = .bool(false)
        XCTAssertThrowsError(try PlanValidator.validate(changed, approval: approval, capabilities: .init()))
        changed = plan; changed.execution.inputs["text"] = .text("different request")
        XCTAssertThrowsError(try PlanValidator.validate(changed, approval: approval, capabilities: .init()))
    }
    func testComparisonContractPermitsNewBuildButNotChangedOracleOrHarness() throws {
        let base = try AutomationFrozenCase(plan: plan()); var changed = base.plan
        changed.revision += 1; changed.app.productDigest = String(repeating: "b", count: 64); changed.app.sourceManifestDigest = String(repeating: "c", count: 64)
        let candidate = try AutomationFrozenCase(plan: changed)
        XCTAssertEqual(candidate.contractDigest, base.contractDigest); XCTAssertNotEqual(candidate.digest, base.digest)
        changed.requirements[0].expected = .bool(false)
        XCTAssertNotEqual(try AutomationFrozenCase(plan: changed).contractDigest, base.contractDigest)
        changed = candidate.plan; changed.provenance["harnessDigest"] = "different"
        XCTAssertNotEqual(try AutomationFrozenCase(plan: changed).contractDigest, base.contractDigest)
    }
    func testSymlinkedDefinitionDirectoryCannotRedirectWrites() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString), outside = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let store = try AutomationCaseStore(root: root)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Definitions"), withDestinationURL: outside)
        do { _ = try await store.freeze(plan()); XCTFail("Symlink write redirected") } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testForgedSummaryMissingReceiptsStaleFactsAndDuplicateReceiptsAreRejected() throws {
        let plan = plan(); var facts = report(plan)
        try AutomationRecordedEvidence.validate(report: facts, plan: plan)
        facts.receipts.removeAll()
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: facts, plan: plan))
        facts = report(plan); facts.receipts[1].observations[0].value = .bool(false)
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: facts, plan: plan))
        facts = report(plan); facts.receipts[1].scope.attemptId = "old"
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: facts, plan: plan))
        facts = report(plan); facts.resourcesReleased = false
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: facts, plan: plan))
        facts = report(plan); facts.receipts.append(facts.receipts[0])
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: facts, plan: plan))
    }
    func testMultiEffectDigestIsStableAcrossEncodingAndProcesses() throws {
        var plan = plan(); plan.execution.effects = [.observe, .navigate, .fixtureWrite, .reset]
        let expected = try AutomationFrozenCase.planDigest(plan)
        let decoded = try JSONDecoder().decode(AutomationCase.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(try AutomationFrozenCase.planDigest(decoded), expected)
        plan.execution.effects = Set([.reset, .fixtureWrite, .navigate, .observe])
        XCTAssertEqual(try AutomationFrozenCase.planDigest(plan), expected)
        #if os(macOS)
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 {
            let result = root.appendingPathComponent("digest-" + String(index))
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["-XCTest", "IntentsAutomationCoreTests.AutomationCaseStoreTests/testDigestChildProbe", Bundle(for: Self.self).bundlePath]
            var environment = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "SDKROOT"].contains($0.key) }
            environment["INTENTS_CASE_DIGEST_TEST_OUTPUT"] = result.path
            child.environment = environment; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run()
            let deadline = Date().addingTimeInterval(10)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning { child.terminate(); XCTFail("Digest subprocess did not finish"); return }
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0)
            XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), expected)
        }
        #endif
    }
    func testDigestChildProbe() throws {
        guard let output = ProcessInfo.processInfo.environment["INTENTS_CASE_DIGEST_TEST_OUTPUT"] else { return }
        guard output.hasPrefix("/private/tmp/") else { throw AutomationContractError.invalidIdentity }
        var plan = plan(); plan.execution.effects = [.observe, .navigate, .fixtureWrite, .reset]
        try AutomationFrozenCase.planDigest(plan).write(toFile: output, atomically: true, encoding: .utf8)
    }
    func testUntrustedPermissionsAndHardLinksCannotBeLoaded() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AutomationCaseStore(root: root), frozen = try await store.freeze(plan())
        let file = root.appendingPathComponent("Definitions/business-case/v1-" + frozen.digest + ".json")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        do { _ = try await store.load(id: "business-case", revision: 1, digest: frozen.digest); XCTFail("Writable definition accepted") } catch { }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("linked.json"))
        do { _ = try await store.load(id: "business-case", revision: 1, digest: frozen.digest); XCTFail("Hardlinked definition accepted") } catch { }
        try FileManager.default.removeItem(at: root.appendingPathComponent("linked.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        do { _ = try await store.load(id: "business-case", revision: 1, digest: frozen.digest); XCTFail("Writable root accepted") } catch { }
        XCTAssertThrowsError(try AutomationCaseStore(root: root))
    }
    func testSuccessRequiresCompleteOrderedExecutionIncludingSetupAndCleanup() throws {
        var plan = plan(); var facts = report(plan)
        facts.receipts[1].completed = false; facts.receipts[1].dispatched = false
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: facts, plan: plan))
        facts = report(plan); facts.receipts.reverse()
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: facts, plan: plan))
        plan.setup = [.init(id: "setup", kind: .ui, phase: .setup, operation: "Prepare")]
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: report(plan), plan: plan))
        plan.setup = []; plan.cleanup = [.init(id: "cleanup", kind: .ui, phase: .cleanup, operation: "Cleanup")]
        XCTAssertThrowsError(try AutomationRecordedEvidence.validate(report: report(plan), plan: plan))
    }

    func testEnumerationChargesRawWhitespaceBeforeDecodingBeyondAggregateCap() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AutomationCaseStore(root: root)
        for index in 0..<9 {
            var plan = plan(); plan.id = "padded-" + String(index)
            let frozen = try await store.freeze(plan)
            let file = root.appendingPathComponent("Definitions/" + plan.id + "/v1-" + frozen.digest + ".json")
            var bytes = try Data(contentsOf: file); bytes.append(Data(repeating: 32, count: 2_097_152 - bytes.count))
            try bytes.write(to: file)
        }
        do { _ = try await store.definitions(); XCTFail("Raw aggregate byte cap bypassed by whitespace") } catch { }
    }

}
