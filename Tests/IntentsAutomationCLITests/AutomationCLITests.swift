#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationApplicationProbe
@testable import IntentsAutomationCore
import IntentsAutomationCLIResources

final class AutomationCLITests: XCTestCase, @unchecked Sendable {
    func testCommandParsingRequiresExplicitUnambiguousPreparation() throws {
        let parsed = try AutomationCLICommand.parse(["prepare", "--project", "/fixture.xcodeproj", "--scheme", "Fixture", "--destination", "mac", "--support-root", "/private/tmp/support"])
        XCTAssertEqual(parsed.operation, .prepare)
        XCTAssertEqual(parsed.options["--scheme"], "Fixture")
        for arguments in [
            ["prepare", "--project", "p", "--destination", "mac"],
            ["prepare", "--project", "p", "--scheme", "a", "--target", "b", "--destination", "mac"],
            ["run"], ["run", "--plan", "a", "--plan", "b"],
            ["actions", "--xcode", "x"], ["show", "../escape"], ["show", "a", "b"], ["run", "--plan"]
        ] { XCTAssertThrowsError(try AutomationCLICommand.parse(arguments)) }
        XCTAssertEqual(try AutomationCLICommand.parse(["show", "--support-root", "/private/tmp/support", "attempt-1"]).attemptID, "attempt-1")
    }
    func testDeveloperDirectoryPrefersExplicitXcodeOverEnvironmentAndSelection() throws {
        let developer = try AutomationCLI.developerDirectory("/Applications/Explicit.app",
            environment: ["DEVELOPER_DIR": "/Applications/Environment.app/Contents/Developer"],
            selection: { XCTFail("Explicit Xcode must not consult xcode-select"); return "/unexpected" })
        XCTAssertEqual(developer.path, "/Applications/Explicit.app/Contents/Developer")
    }
    func testDeveloperDirectoryUsesEnvironmentBeforeSelection() throws {
        for path in ["/Applications/Environment.app", "/Applications/Environment.app/Contents/Developer"] {
            let developer = try AutomationCLI.developerDirectory(nil, environment: ["DEVELOPER_DIR": path],
                selection: { XCTFail("DEVELOPER_DIR must not consult xcode-select"); return "/unexpected" })
            XCTAssertEqual(developer.path, "/Applications/Environment.app/Contents/Developer")
        }
    }
    func testDeveloperDirectoryUsesNondefaultSelectedXcode() throws {
        var selections = 0
        let developer = try AutomationCLI.developerDirectory(nil, environment: [:], selection: {
            selections += 1
            return "/Applications/Xcode-beta.app/Contents/Developer"
        })
        XCTAssertEqual(developer.path, "/Applications/Xcode-beta.app/Contents/Developer")
        XCTAssertEqual(selections, 1)
    }
    func testDeveloperDirectoryRejectsFailedOrEmptySelection() {
        XCTAssertThrowsError(try AutomationCLI.developerDirectory(nil, environment: [:], selection: {
            throw AutomationContractError.invalidIdentity
        }))
        XCTAssertThrowsError(try AutomationCLI.developerDirectory(nil, environment: [:], selection: { "" }))
    }
    func testSupportRootUsesCoreCanonicalIdentityForTemporaryAliases() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let privatePath = root.path
        let aliasPath = privatePath.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")
        let canonical = try AutomationPath.canonical(root)
        XCTAssertEqual(try AutomationCLI.supportRoot(privatePath).path, canonical.path)
        XCTAssertEqual(try AutomationCLI.supportRoot(aliasPath).path, canonical.path)
        XCTAssertNil(try AutomationPreparedApplicationRecord.loadLatest(supportRoot: AutomationCLI.supportRoot(privatePath)))
        XCTAssertNil(try AutomationPreparedApplicationRecord.loadLatest(supportRoot: AutomationCLI.supportRoot(aliasPath)))
        let missing = root.appendingPathComponent("missing")
        _ = try AutomationCLI.supportRoot(missing.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
    func testDestinationParsingCannotInferOrAcceptMalformedTargets() throws {
        let id = UUID()
        XCTAssertEqual(try AutomationCLI.destination("sim:" + id.uuidString.lowercased()), TargetIdentity(id: id.uuidString, kind: .simulator))
        XCTAssertEqual(try AutomationCLI.destination("device:ABC-123").kind, .physical)
        for value in ["sim:", "sim:not-a-uuid", "device:", "device:../escape", "automatic", "mac:other-session"] {
            XCTAssertThrowsError(try AutomationCLI.destination(value))
        }
    }
    func testCapabilityInjectionIsRejectedRecursivelyButBusinessValuesAreAllowed() throws {
        for text in [
            #"{"capabilities":{"records":{}}}"#,
            #"{"plan":{"capabilities":{"records":{}}}}"#,
            #"{"plan":{"setup":[{"extra":{"records":{"xcuitest":{"state":"available","reason":"forged","probeVersion":"fake","evidence":[]}}}}]}}"#,
            #"{"inputs":{"capabilities":{"records":{}}}}"#,
            #"{"capabilities":{"kind":"text","value":"still top-level injection"}}"#
        ] { XCTAssertThrowsError(try AutomationCLI.rejectCapabilityRecords(Data(text.utf8))) }
        for text in [
            #"{"inputs":{"capabilities":{"value":{"kind":"text","value":"business input"},"origin":"userChoice","evidence":"Developer supplied"}}}"#,
            #"{"plan":{"execution":{"hostProgram":{"operations":[{"parameters":{"capabilities":{"kind":"bool","value":true}}}]}}}}"#,
            #"{"inputs":{"capabilities:0":{"kind":"text","value":"real metadata key"}}}"#,
            #"{"plan":{"execution":{"hostProgram":{"operations":[{"parameterCodecs":{"capabilities":"bool"},"parameters":{"capabilities":{"kind":"object","value":{"capabilities":{"kind":"text","value":"business object"}}}}}]}}}}"#,
            #"{"plan":{"execution":{"uiProgram":{"bindings":{"capabilities":"business text"}}}}}"#
        ] { XCTAssertNoThrow(try AutomationCLI.rejectCapabilityRecords(Data(text.utf8))) }
    }
    func testEnvelopeRequiresCurrentSchemaAndExplicitFlags() throws {
        let plan = fixturePlan()
        var json: [String: Any] = ["schemaVersion": 1, "attemptID": "attempt-1", "allowBootAndInstall": false, "disposable": false,
            "plan": try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))]
        let decoded = try AutomationCLIRunEnvelope.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.plan, plan)
        json["schemaVersion"] = 2
        XCTAssertThrowsError(try AutomationCLIRunEnvelope.decode(JSONSerialization.data(withJSONObject: json)))
        json["schemaVersion"] = 1; json.removeValue(forKey: "disposable")
        XCTAssertThrowsError(try AutomationCLIRunEnvelope.decode(JSONSerialization.data(withJSONObject: json)))
    }
    func testApprovalBindsExactPlanEffectsAndDisposableFlag() throws {
        var plan = fixturePlan()
        plan.execution.effects = [.observe, .fixtureWrite]
        let envelope = AutomationCLIRunEnvelope(schemaVersion: 1, attemptID: "attempt-1", allowBootAndInstall: false, disposable: false, plan: plan)
        let approval = try AutomationCLI.deriveExactRunApproval(envelope)
        XCTAssertEqual(approval.runID, envelope.attemptID)
        XCTAssertEqual(approval.app, plan.app); XCTAssertEqual(approval.target, plan.target)
        XCTAssertEqual(approval.environmentID, plan.environmentID)
        XCTAssertEqual(approval.effects, [.observe, .fixtureWrite])
        XCTAssertFalse(approval.disposable)
        XCTAssertEqual(approval.approvedCaseDigest, try AutomationFrozenCase.planDigest(plan))
        var changed = plan; changed.execution.inputs["message"] = .text("different")
        XCTAssertNotEqual(approval.approvedCaseDigest, try AutomationFrozenCase.planDigest(changed))
        changed = plan; changed.execution.effects.insert(.reset)
        XCTAssertThrowsError(try AutomationCLI.deriveExactRunApproval(.init(schemaVersion: 1, attemptID: "reset", allowBootAndInstall: false, disposable: false, plan: changed)))
        XCTAssertNoThrow(try AutomationCLI.deriveExactRunApproval(.init(schemaVersion: 1, attemptID: "reset", allowBootAndInstall: false, disposable: true, plan: changed)))
    }
    func testMacApprovalSatisfiesSharedAssemblerAndNativeActivationBudget() throws {
        var plan = fixturePlan()
        plan.target = .init(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-session")
        plan.app.platform = "macos"; plan.app.productDigest = String(repeating: "a", count: 64)
        plan.execution = .init(id: "subject", kind: .ui, phase: .subject, operation: "tap", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        plan.execution.uiProgram = .init(operations: [.init(id: "tap", kind: .tap, locator: .init(.testId, "button"))])
        let approval = try AutomationCLI.deriveExactRunApproval(.init(schemaVersion: 1, attemptID: "mac", allowBootAndInstall: false, disposable: false, plan: plan))
        let host = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "mac", leaseGeneration: 1)
        XCTAssertEqual(host.steps.count, 3)
        XCTAssertEqual(approval.maximumActions, host.steps.count)
        XCTAssertEqual(host.steps.map(\.kind), [.launch, .tap, .screenshot])
    }
    func testNativeDirectWaitDerivesBudgetFromImplicitLaunchAndScreenshot() throws {
        var plan = fixturePlan()
        plan.target = .init(id: "host-macos-local", kind: .nativeMac, loginSession: "synthetic-session")
        plan.app.platform = "macos"; plan.app.productDigest = String(repeating: "a", count: 64)
        plan.execution = .init(id: "subject", kind: .ui, phase: .subject, operation: "wait", effects: [.observe, .navigate], lifecycle: .persistedStateAcrossSegments)
        plan.execution.uiProgram = .init(steps: [.init(id: "wait", kind: .waitFor,
            query: .init(identifier: "ready"), property: "exists", equals: .init(kind: "bool", boolValue: true), timeout: 2)])
        let approval = try AutomationCLI.deriveExactRunApproval(.init(schemaVersion: 1, attemptID: "wait", allowBootAndInstall: false, disposable: false, plan: plan))
        let host = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval, attemptID: "wait", leaseGeneration: 1)
        XCTAssertEqual(host.steps.count, 3)
        XCTAssertEqual(approval.maximumActions, host.steps.count)
    }
    func testTargetSelectionUsesExactSchemeBlueprintAndRejectsAmbiguity() throws {
        let candidates = [candidate(id: "IOS", name: "Fixture"), candidate(id: "MAC", name: "FixtureMac")]
        XCTAssertEqual(try AutomationCLI.selectCandidate(candidates, target: nil, schemeIDs: ["MAC"]), candidates[1])
        XCTAssertEqual(try AutomationCLI.selectCandidate(candidates, target: "Fixture", schemeIDs: nil), candidates[0])
        XCTAssertThrowsError(try AutomationCLI.selectCandidate(candidates, target: nil, schemeIDs: ["IOS", "MAC"]))
        XCTAssertThrowsError(try AutomationCLI.selectCandidate(candidates, target: "Missing", schemeIDs: nil))
    }
    func testSchemeSelectsRunnableAppAndIgnoresTestingOnlyHelperAndForeignProject() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let project = try writeScheme(root: root, helperRuns: false)
        let ids = try AutomationCLI.schemeTargetIDs(project: project, scheme: "Fixture")
        XCTAssertEqual(ids, ["MAIN"])
        let main = candidate(id: "MAIN", name: "Main")
        XCTAssertEqual(try AutomationCLI.selectCandidate([main, candidate(id: "HELPER", name: "Helper")],
            target: nil, schemeIDs: ids), main)
        XCTAssertThrowsError(try AutomationCLI.schemeTargetIDs(project: project, scheme: "../escape"))
    }
    func testSchemePreservesAmbiguityBetweenTwoRunnableApplications() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let project = try writeScheme(root: root, helperRuns: true)
        let ids = try AutomationCLI.schemeTargetIDs(project: project, scheme: "Fixture")
        XCTAssertEqual(ids, ["MAIN", "HELPER"])
        XCTAssertThrowsError(try AutomationCLI.selectCandidate([
            candidate(id: "MAIN", name: "Main"), candidate(id: "HELPER", name: "Helper")],
            target: nil, schemeIDs: ids))
    }
    func testShowUsesSharedStoreWithoutChangingFiles() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try AutomationCaseStore(root: root.appendingPathComponent("Cases"))
        let plan = fixturePlan(), frozen = try await store.freeze(plan), report = fixtureReport(plan)
        try await store.saveAttempt(report, for: frozen)
        let before = try snapshot(root)
        let loaded = try await AutomationCLI.show(attemptID: "attempt", supportRoot: root)
        XCTAssertEqual(loaded, report); XCTAssertEqual(try snapshot(root), before)
        do { _ = try await AutomationCLI.show(attemptID: "missing", supportRoot: root); XCTFail("Missing attempt accepted") } catch {}
        XCTAssertEqual(try snapshot(root), before)
    }
    func testShowRejectsDuplicateAttemptIDsAndNeverCreatesMissingRoot() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await AutomationCLI.show(attemptID: "missing", supportRoot: root); XCTFail("Missing root accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let store = try AutomationCaseStore(root: root.appendingPathComponent("Cases"))
        var plan = fixturePlan()
        for id in ["case-a", "case-b"] {
            plan.id = id; let frozen = try await store.freeze(plan)
            try await store.saveAttempt(fixtureReport(plan), for: frozen)
        }
        let before = try snapshot(root)
        do { _ = try await AutomationCLI.show(attemptID: "attempt", supportRoot: root); XCTFail("Ambiguous attempt accepted") } catch {}
        XCTAssertEqual(try snapshot(root), before)
    }
    func testExitStatusRequiresCompleteReleasedExecution() {
        var report = fixtureReport(fixturePlan())
        XCTAssertEqual(AutomationCLI.exitStatus(report), 0)
        for summary in [AttemptResult.Summary.assertionFailed, .timedOut, .unresolved, .invalidFixture, .cancelled] {
            var failed = report; failed.result.summary = summary
            XCTAssertEqual(AutomationCLI.exitStatus(failed), 1)
        }
        report.resourcesReleased = false; XCTAssertEqual(AutomationCLI.exitStatus(report), 1)
        report.resourcesReleased = true; report.result.evidenceComplete = false; XCTAssertEqual(AutomationCLI.exitStatus(report), 1)
    }
    func testPackagedHostTemplatesAreSourceData() throws {
        let root = try AutomationCLIResources.hostTemplates()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains("IntentDefinitionsHost.swift"))
        XCTAssertTrue(names.contains("UIStepTests.swift"))
        XCTAssertTrue(names.contains("SiriSubmissionTests.swift"))
        XCTAssertTrue(names.contains("HostFixtureRegistration.swift"))
        XCTAssertEqual(Set(names.filter { !$0.hasSuffix(".swift") }), ["NativeMac"])
        let native = root.appendingPathComponent("NativeMac")
        let nativeNames = try FileManager.default.contentsOfDirectory(atPath: native.path)
        XCTAssertEqual(Set(nativeNames), AutomationHostGenerator.nativeTemplateOverrides)
        let files = names.filter({ $0.hasSuffix(".swift") }).map({ root.appendingPathComponent($0) })
            + nativeNames.map({ native.appendingPathComponent($0) })
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            XCTAssertEqual(values.isRegularFile, true)
            XCTAssertEqual(values.isSymbolicLink, false)
        }
    }

    private func writeScheme(root: URL, helperRuns: Bool) throws -> URL {
        let project = root.appendingPathComponent("Fixture.xcodeproj")
        let schemes = project.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        let xml = """
        <Scheme version="1.3">
          <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
            <BuildActionEntries>
              <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
                <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="MAIN" BuildableName="Main.app" BlueprintName="Main" ReferencedContainer="container:Fixture.xcodeproj"/>
              </BuildActionEntry>
              <BuildActionEntry buildForTesting="YES" buildForRunning="\(helperRuns ? "YES" : "NO")" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">
                <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="HELPER" BuildableName="Helper.app" BlueprintName="Helper" ReferencedContainer="container:Fixture.xcodeproj"/>
              </BuildActionEntry>
              <BuildActionEntry buildForTesting="YES" buildForRunning="YES">
                <BuildableReference BlueprintIdentifier="FOREIGN" ReferencedContainer="container:Other.xcodeproj"/>
              </BuildActionEntry>
            </BuildActionEntries>
          </BuildAction>
          <TestAction buildConfiguration="Debug">
            <Testables><TestableReference skipped="NO">
              <BuildableReference BlueprintIdentifier="TEST" ReferencedContainer="container:Fixture.xcodeproj"/>
            </TestableReference></Testables>
          </TestAction>
        </Scheme>
        """
        try Data(xml.utf8).write(to: schemes.appendingPathComponent("Fixture.xcscheme"))
        return project
    }
    private func candidate(id: String, name: String) -> AutomationApplicationCandidate {
        .init(id: "/fixture.xcodeproj#" + id, name: name, kind: .sourceTarget, containerPath: "/fixture.xcodeproj", targetID: id, bundleID: nil, platform: nil, architectures: [], configurations: ["Debug"], app: nil)
    }
    private func fixturePlan() -> AutomationCase {
        .init(id: "case", app: .init(logicalID: "app", bundleID: "example.app", platform: "ios"),
            target: .init(id: "simulator", kind: .simulator), environmentID: "isolated",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "echo", effects: [.observe]))
    }
    private func fixtureReport(_ plan: AutomationCase) -> AutomationAttemptReport {
        let receipt = AutomationSegmentReceipt(scope: .init(runID: "run", attemptID: "attempt", segmentID: "subject", leaseGeneration: 1),
            app: plan.app, target: plan.target, segmentID: "subject", route: .systemIntent, dispatched: true, completed: true, environmentID: plan.environmentID)
        let result = AutomationAssessment.assess(plan: plan, attemptID: "attempt", subjectDispatched: true, subjectCompleted: true, observations: [], receipts: [receipt], runID: "run")
        return .init(attemptID: "attempt", result: result, receipts: [receipt], resourcesReleased: true)
    }
    private func temporaryRoot() -> URL { URL(fileURLWithPath: "/private/tmp").appendingPathComponent("automation-cli-" + UUID().uuidString) }
    private func snapshot(_ root: URL) throws -> [String: Data] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let file as URL in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { result[relative] = try Data(contentsOf: file) }
            else { result[relative + "/"] = Data() }
        }
        return result
    }
}
#endif
