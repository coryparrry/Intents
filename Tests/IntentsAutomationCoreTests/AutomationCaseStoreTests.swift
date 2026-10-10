import XCTest
@testable import IntentsAutomationCore

final class AutomationCaseStoreTests: XCTestCase, @unchecked Sendable {
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
