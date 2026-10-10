#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

@MainActor final class MacFreshDraftStoreTests: XCTestCase {
    private final class Session: @unchecked Sendable {
        let lock = NSLock()
        var target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "draft-session-A")
        func read() -> TargetIdentity { lock.withLock { target } }
        func change() { lock.withLock { target.loginSession = "draft-session-B" } }
    }
    private func fixture() async throws -> (AppAutomationStore, Session) {
        let root = URL(fileURLWithPath: "/private/tmp/mac-fresh-draft-" + UUID().uuidString)
        let project = root.appendingPathComponent("Subject.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let objects: [String: Any] = ["APP": ["isa": "PBXNativeTarget", "name": "Subject", "productType": "com.apple.product-type.application", "buildConfigurationList": "LIST"],
            "LIST": ["buildConfigurations": ["DEBUG"]], "DEBUG": ["name": "Debug"]]
        try PropertyListSerialization.data(fromPropertyList: ["objects": objects], format: .xml, options: 0).write(to: project.appendingPathComponent("project.pbxproj"))
        let session = Session()
        let model = AppAutomationStore(supportDirectory: root.appendingPathComponent("support"),
            uiRuntimeProvider: { XCTFail("Draft must not request a runtime"); throw AutomationContractError.invalidIdentity },
            nativeMacTargetReader: { session.read() }, preparationExecutor: { candidate, approval, directory in
                var app = AppIdentity(logicalID: candidate.id, bundleID: "test.Subject", platform: "macos", productDigest: String(repeating: "a", count: 64))
                app.productDigestVersion = 2; app.configuration = approval.configuration
                app.canonicalBundlePath = directory.appendingPathComponent("Subject.app").path
                let catalog = ApplicationSurfaceCatalog(app: app, systemActions: [.init(id: "Complete", typeName: "Complete", title: "Complete task",
                    parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity")], parametersComplete: true, compiled: true, registered: false, executed: false)],
                    systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [], entities: [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery",
                        properties: ["title": "text", "completed": "bool", "owner": "text"], propertyTitles: [:])])
                return .init(source: .init(sourceRoot: approval.sourceRoot, files: [], directories: [], excludedPaths: []),
                    generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "HOST", bundleID: "test.Host", configuration: approval.configuration, templateDigest: String(repeating: "b", count: 64)),
                    host: .init(app: app, target: approval.target, xctestrunPath: "unused", xctestrunDigest: String(repeating: "c", count: 64), subjectProductPath: app.canonicalBundlePath!,
                                hostBundlePath: "unused", hostProductDigest: String(repeating: "d", count: 64), hostBundleID: "test.Host", testTarget: "Host"),
                    catalog: catalog, buildLogPath: "unused", buildLogTruncated: false)
            })
        model.select(project); model.preparationDestination = .macOS; model.preparationSelectionChanged()
        await model.prepareAndWait()
        model.workflowRoute = "fresh"; model.actionID = "Complete"
        model.uiInstruction = "Create and save a task using approvedText"; model.uiEndpoint = "Tasks"
        model.freshNamePrefix = "Invoice"; model.freshNameProperty = "title"; model.freshStateProperty = "completed"
        model.freshInitialState = "false"; model.freshExpectedState = "true"
        model.freshProtectOtherRecord = true; model.freshContextProperty = "owner"
        model.freshSelectedContext = "Work"; model.freshProtectedContext = "Personal"
        model.effectChoice = "fixture"; model.effectsConfirmed = true; model.disposable = true
        return (model, session)
    }
    func testMixedDraftFreezesRealIdentityBindingBothOraclesAndBuildProvenanceWithoutExecution() async throws {
        let (model, session) = try await fixture()
        XCTAssertTrue(model.canReviewPreparedMacFreshWorkflow); XCTAssertFalse(model.canRun)
        let review = try model.reviewPreparedMacFreshWorkflow()
        XCTAssertEqual(review.plan.target, session.read())
        XCTAssertEqual(review.plan.environmentID, "selected-mac-session:draft-session-A")
        XCTAssertEqual(review.plan.setup.map(\.kind), [.ui, .ui, .systemQuery])
        XCTAssertEqual(review.plan.execution.kind, .systemIntent)
        XCTAssertEqual(review.plan.observations.map(\.kind), [.systemQuery, .systemQuery])
        XCTAssertEqual(try AutomationFreshEntityPlanner.bindings(plan: review.plan).count, 2)
        XCTAssertEqual(review.plan.requirements.map(\.expected), [.bool(true), .bool(false)])
        XCTAssertEqual(review.plan.provenance["ui.executionAvailability"], "unqualified")
        XCTAssertEqual(review.plan.preparedMacBuildArtifacts?.hostProductDigest, String(repeating: "d", count: 64))
        XCTAssertNil(review.plan.provenance["ui.runtimeManifestDigest"])
        try await model.saveMacWorkflowDraft(review)
        let cases = try AutomationCaseStore(root: model.support.appendingPathComponent("Cases"))
        let definitions = try await cases.definitions(); XCTAssertEqual(definitions.count, 1)
        XCTAssertEqual(definitions.first?.plan, review.plan)
        let attempts = try await cases.attempts(for: XCTUnwrap(definitions.first)); XCTAssertTrue(attempts.isEmpty)
        XCTAssertNil(model.report); XCTAssertNil(model.pendingCommandStatus)
        XCTAssertThrowsError(try model.makeNativeRunRequest(runID: "forbidden"))
        XCTAssertThrowsError(try model.makeFreshRecordRequest(runID: "forbidden"))
    }
    func testSessionInputDestinationAndConfigurationChangesInvalidateReviewedDraft() async throws {
        for mutation in 0..<5 {
            let (model, session) = try await fixture(); let review = try model.reviewPreparedMacFreshWorkflow()
            switch mutation {
            case 0: session.change()
            case 1: model.freshExpectedState = "false"
            case 2: model.preparationDestination = .simulator
            case 3: model.configuration = "Release"
            default: model.freshProtectedContext = "Other"
            }
            do { try await model.saveMacWorkflowDraft(review); XCTFail("Changed draft was saved") } catch {}
            XCTAssertTrue(model.savedCases.isEmpty)
        }
    }
    func testPermissionOrUnsupportedLearnedSetupCannotProduceMacDraft() async throws {
        let (model, _) = try await fixture()
        model.disposable = false; XCTAssertFalse(model.canReviewPreparedMacFreshWorkflow)
        XCTAssertThrowsError(try model.reviewPreparedMacFreshWorkflow())
        model.disposable = true; model.effectsConfirmed = false; XCTAssertFalse(model.canReviewPreparedMacFreshWorkflow)
        model.effectsConfirmed = true; model.useLearnedSetup = true; XCTAssertFalse(model.canReviewPreparedMacFreshWorkflow)
        model.useLearnedSetup = false; model.effectChoice = "external"; XCTAssertFalse(model.canReviewPreparedMacFreshWorkflow)
    }
    func testDefaultCompilerRejectsMacAndDraftRejectsForeignPlatformSessionAndCapability() async throws {
        let (model, _) = try await fixture(); let prepared = try XCTUnwrap(model.prepared)
        let review = try model.reviewPreparedMacFreshWorkflow()
        func compile(_ catalog: ApplicationSurfaceCatalog, _ approval: RunApproval, _ capabilities: CapabilityProfile,
                     purpose: AutomationFreshEntityPlanner.Purpose = .nativeMacDraft) throws -> AutomationCase {
            try AutomationFreshEntityPlanner.compile(catalog: catalog, actionID: "Complete", instruction: "Create using approvedText", endpoint: "Tasks",
                namePrefix: "Invoice", nameProperty: "title", stateProperty: "completed", initialState: false, expectedState: true,
                approval: approval, capabilities: capabilities, localeIdentifier: "en_GB", purpose: purpose)
        }
        let capabilities = AutomationNativeFreshFixtures.capabilities(prepared)
        XCTAssertThrowsError(try compile(prepared.catalog, review.approval, capabilities, purpose: .execution))
        var catalog = prepared.catalog; catalog.app.platform = "ios"
        var approval = review.approval; approval.app = catalog.app
        XCTAssertThrowsError(try compile(catalog, approval, capabilities))
        for session in [nil, "", "bad\nvalue", String(repeating: "x", count: 257)] as [String?] {
            approval = review.approval; approval.target.loginSession = session
            XCTAssertThrowsError(try compile(prepared.catalog, approval, capabilities))
        }
        approval = review.approval; approval.target = .init(id: UUID().uuidString, kind: .simulator)
        XCTAssertThrowsError(try compile(prepared.catalog, approval, capabilities))
        for capability in ["apple.entity.query", "apple.intent.invoke"] {
            var absent = capabilities; absent.records.removeValue(forKey: capability)
            XCTAssertThrowsError(try compile(prepared.catalog, review.approval, absent))
        }
    }
    func testPreparedMacUIOnlyDraftSavesIndependentCheckAndPreparedProvenanceWithoutExecution() async throws {
        let (model, session) = try await fixture()
        model.workflowRoute = "ui"; model.effectChoice = "navigation"; model.uiExpectedText = "Ready"
        XCTAssertTrue(model.isMacUIReview); XCTAssertTrue(model.canReviewMacWorkflow); XCTAssertFalse(model.canRun)
        let review = try model.reviewMacWorkflow()
        XCTAssertEqual(review.plan.target, session.read()); XCTAssertEqual(review.plan.app, model.prepared?.host.app)
        XCTAssertEqual(review.plan.execution.kind, .ui); XCTAssertTrue(review.plan.setup.isEmpty)
        XCTAssertEqual(review.plan.requirements.first?.expected, .text("Ready"))
        XCTAssertEqual(review.plan.provenance["ui.executionAvailability"], "unqualified")
        XCTAssertEqual(review.plan.preparedMacBuildArtifacts?.hostProductDigest, String(repeating: "d", count: 64))
        XCTAssertNil(review.plan.provenance["ui.runtimeManifestDigest"])
        try await model.saveMacWorkflowDraft(review)
        let cases = try AutomationCaseStore(root: model.support.appendingPathComponent("Cases"))
        let definitions = try await cases.definitions(); XCTAssertEqual(definitions.first?.plan, review.plan)
        let attempts = try await cases.attempts(for: XCTUnwrap(definitions.first)); XCTAssertTrue(attempts.isEmpty)
        XCTAssertNil(model.report); XCTAssertNil(model.pendingCommandStatus)
        XCTAssertThrowsError(try model.makeNativeRunRequest(runID: "forbidden"))
    }
    func testPreparedMacUIOnlyDraftRejectsStaleSessionConfigurationAndUnsupportedText() async throws {
        for mutation in 0..<4 {
            let (model, session) = try await fixture(); model.workflowRoute = "ui"; model.effectChoice = "navigation"
            let review = try model.reviewMacWorkflow()
            switch mutation {
            case 0: session.change()
            case 1: model.configuration = "Release"
            case 2: model.preparationDestination = .simulator
            default: model.uiApprovedText = "Unsupported input"
            }
            XCTAssertFalse(model.canReviewMacWorkflow)
            do { try await model.saveMacWorkflowDraft(review); XCTFail("Stale or unsupported UI draft saved") } catch {}
            XCTAssertTrue(model.savedCases.isEmpty)
        }
        let (model, _) = try await fixture(); model.workflowRoute = "ui"; model.effectChoice = "navigation"
        model.uiApprovedText = "Old simulator text"; XCTAssertFalse(model.canReviewMacWorkflow)
        model.uiApprovedText = ""; XCTAssertTrue(model.canReviewMacWorkflow)
    }
    func testMacDraftSaveRejectsChangedPlanBodyEvenWithCopiedReviewID() async throws {
        let (model, _) = try await fixture(); model.workflowRoute = "ui"; model.effectChoice = "navigation"
        let review = try model.reviewMacWorkflow(); var changed = review.plan
        changed.execution.operation = "Other workflow"
        let forged = AutomationNativeMacWorkflowReview(plan: changed, approval: review.approval, bundlePath: review.bundlePath,
            visibleCheck: review.visibleCheck, id: review.id)
        do { try await model.saveMacWorkflowDraft(forged); XCTFail("Unreviewed plan body saved") } catch {}
        XCTAssertTrue(model.savedCases.isEmpty)
    }

    func testMacDraftSaveRejectsCanonicallyEquivalentTextWithDifferentFrozenBytes() async throws {
        let (model, _) = try await fixture(); model.workflowRoute = "ui"; model.effectChoice = "navigation"
        model.uiInstruction = "Open Cafe\u{301}"
        let review = try model.reviewMacWorkflow(); var changed = review.plan
        changed.execution.operation = "Open Caf\u{e9}"
        XCTAssertEqual(changed, review.plan)
        XCTAssertNotEqual(try AutomationFrozenCase.planDigest(changed), review.id)
        let forged = AutomationNativeMacWorkflowReview(plan: changed, approval: review.approval, bundlePath: review.bundlePath,
            visibleCheck: review.visibleCheck, id: review.id)
        do { try await model.saveMacWorkflowDraft(forged); XCTFail("Unreviewed bytes saved") } catch {}
        XCTAssertTrue(model.savedCases.isEmpty)
    }

    func testPreparedMacEvidenceMatcherSupportsTypedAndLegacyCasesWithExactArtifacts() async throws {
        let (model, _) = try await fixture(); let prepared = try XCTUnwrap(model.prepared)
        let review = try model.reviewPreparedMacFreshWorkflow()
        XCTAssertTrue(AutomationNativeUIRuntime.preparedEvidenceMatches(plan: review.plan, prepared: prepared))
        for mode in 0..<3 {
            var changed = prepared
            if mode == 0 { changed.host.hostProductDigest = String(repeating: "f", count: 64) }
            if mode == 1 { changed.host.xctestrunDigest = String(repeating: "f", count: 64) }
            if mode == 2 { changed.catalog.gaps.append("changed") }
            XCTAssertFalse(AutomationNativeUIRuntime.preparedEvidenceMatches(plan: review.plan, prepared: changed))
        }
        var legacy = review.plan; legacy.preparedMacBuildArtifacts = nil
        legacy.provenance.merge(try AutomationNativeUIRuntime.preparedProvenance(prepared)) { _, value in value }
        XCTAssertTrue(AutomationNativeUIRuntime.preparedEvidenceMatches(plan: legacy, prepared: prepared))
    }

}
#endif
