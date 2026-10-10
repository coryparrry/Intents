#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

@MainActor final class SourcePreparationStoreTests: XCTestCase {
    private final class TargetBox: @unchecked Sendable {
        private let lock = NSLock()
        private var target = TargetIdentity(id: "host-macos-local", kind: .nativeMac, loginSession: "source-session-A")
        func read() -> TargetIdentity { lock.withLock { target } }
        func change() { lock.withLock { target.loginSession = "source-session-B" } }
    }
    private func model(executor: @escaping AutomationNativePreparationExecutor,
                       reader: @escaping @Sendable () throws -> TargetIdentity,
                       grants: AutomationNativeSourceGrants? = nil,
                       developerDirectory: URL = AutomationNativeToolchain.developerDirectory(),
                       inventory: @escaping AutomationNativeSimulatorInventoryReader = { _, _ in throw AutomationContractError.invalidIdentity }) throws -> AppAutomationStore {
        let root = URL(fileURLWithPath: "/private/tmp/source-preparation-" + UUID().uuidString)
        let project = root.appendingPathComponent("Subject.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let objects: [String: Any] = ["APP": ["isa": "PBXNativeTarget", "name": "Subject", "productType": "com.apple.product-type.application", "buildConfigurationList": "LIST"],
            "LIST": ["buildConfigurations": ["DEBUG"]], "DEBUG": ["name": "Debug"]]
        try PropertyListSerialization.data(fromPropertyList: ["objects": objects], format: .xml, options: 0).write(to: project.appendingPathComponent("project.pbxproj"))
        let model = AppAutomationStore(supportDirectory: root.appendingPathComponent("support"), developerDirectory: developerDirectory, nativeMacTargetReader: reader,
                                       preparationExecutor: executor, sourceGrants: grants, simulatorInventoryReader: inventory)
        model.select(project)
        return model
    }
    func testDeveloperDirectoryHonorsLaunchOverrideAndXcodeBundlePath() {
        let fallback = "/Applications/Xcode.app/Contents/Developer"
        XCTAssertEqual(AutomationNativeToolchain.developerDirectory(environment: [:]).path, fallback)
        XCTAssertEqual(AutomationNativeToolchain.developerDirectory(environment: ["DEVELOPER_DIR": ""]).path, fallback)
        let selected = "/Applications/Xcode Compatible.app/Contents/Developer"
        XCTAssertEqual(AutomationNativeToolchain.developerDirectory(environment: ["DEVELOPER_DIR": selected]).path, selected)
        XCTAssertEqual(AutomationNativeToolchain.developerDirectory(environment: ["DEVELOPER_DIR": "/Applications/Xcode Compatible.app"]).path, selected)
    }
    func testPhysicalSourceSelectionAndSiriSubmissionApprovalStayExactAndUnassessed() async throws {
        let box = TargetBox()
        let model = try model(executor: { candidate, approval, session in
            var value = preparedFixture(candidate, approval, session); value.generatedHost.includesSiri = true; return value
        }, reader: { box.read() })
        model.preparationDestination = .physical; model.physicalDeviceID = "iPhone"
        model.preparationSelectionChanged(); XCTAssertFalse(model.canPrepare)
        model.physicalDeviceID = "00008140-001049013EF3401C"; model.preparationSelectionChanged()
        XCTAssertTrue(model.canPrepare); XCTAssertFalse(model.needsSimulatorInventory)
        await model.prepareAndWait(); XCTAssertEqual(model.prepared?.host.target.kind, .physical)
        model.workflowRoute = "siri"; model.siriRequest = "Open the approved fixture"
        model.effectChoice = "navigation"; model.effectsConfirmed = true; model.disposable = true; model.installApproved = true
        XCTAssertFalse(model.canRun, "A synthetic preparation cannot grant submission capability")
        model.siriCapabilities.records["siri.recognizedText.api"] = .init(state: .available, reason: "test-only grammar", probeVersion: "test", evidence: [])
        XCTAssertTrue(model.canRun)
        let first = try model.makeSiriRunRequest(runID: "preview"), second = try model.makeSiriRunRequest(runID: UUID().uuidString)
        XCTAssertEqual(first.digest, second.digest); XCTAssertEqual(first.caseDigest, second.caseDigest)
        XCTAssertEqual(first.plan.execution.kind, .siriText); XCTAssertEqual(first.plan.execution.siriProgram?.request, model.siriRequest)
        XCTAssertTrue(first.plan.requirements.isEmpty); XCTAssertTrue(first.plan.observations.isEmpty); XCTAssertNil(first.uiRuntime)
        XCTAssertEqual(first.plan.provenance["physical.installedBytesVerified"], "false")
        let cases = try AutomationCaseStore(root: model.support.appendingPathComponent("siri-cases"))
        _ = try await cases.freeze(first.plan)
        model.effectChoice = "fixture"
        let variant = try model.makeSiriRunRequest(runID: UUID().uuidString)
        XCTAssertNotEqual(first.plan.id, variant.plan.id); _ = try await cases.freeze(variant.plan)
        model.effectChoice = "navigation"
        let review = try await model.prepareNativeConfirmation(.run)
        XCTAssertTrue(review.message.contains(model.siriRequest)); XCTAssertTrue(review.message.contains("exact physical device"))
        XCTAssertTrue(review.message.contains("Submission remains unassessed")); XCTAssertFalse(review.message.contains("start this simulator"))
        _ = try model.cancelCommand(id: review.id)
        model.installApproved = false; XCTAssertFalse(model.canRun); model.installApproved = true
        model.siriRequest = "bad\0request"; XCTAssertFalse(model.canRun)
        model.siriRequest = "Open fixture"; model.physicalDeviceID = "00008140-001049013EF3402C"; model.preparationSelectionChanged()
        XCTAssertNil(model.prepared); XCTAssertTrue(model.siriCapabilities.records.isEmpty); XCTAssertTrue(model.siriRequest.isEmpty)
        model.close()
    }
    func testControlledSiriRecordCheckFreezesOracleAndCannotExecuteFromCachedProfile() async throws {
        let box = TargetBox()
        let model = try model(executor: { candidate, approval, session in
            var value = preparedFixture(candidate, approval, session); value.generatedHost.includesSiri = true
            value.catalog.entities = [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery",
                properties: ["title": "text", "completed": "bool"], propertyTitles: [:])]
            return value
        }, reader: { box.read() })
        model.preparationDestination = .physical; model.physicalDeviceID = "00008140-001049013EF3401C"
        model.preparationSelectionChanged(); await model.prepareAndWait()
        model.workflowRoute = "siri"; model.siriRequest = "Complete Approved test task in Example"
        model.effectChoice = "fixture"; model.effectsConfirmed = true; model.disposable = true; model.installApproved = true
        model.siriCapabilities.records["siri.recognizedText.api"] = .init(state: .available, reason: "test-only grammar", probeVersion: "test", evidence: [])
        model.siriOracle = .init(enabled: true, entityType: "TaskEntity", nameProperty: "title", recordName: "Approved test task",
            stateProperty: "completed", initialState: "false", expectedState: "true")
        XCTAssertTrue(model.canRun)
        let preview = try model.makeSiriRunRequest(runID: "preview"), actual = try model.makeSiriRunRequest(runID: UUID().uuidString)
        XCTAssertEqual(preview.digest, actual.digest); XCTAssertTrue(preview.siriQualification)
        XCTAssertEqual(preview.plan.setup.count, 1); XCTAssertEqual(preview.plan.observations.count, 1)
        XCTAssertEqual(preview.plan.requirements.first?.expected, .bool(true)); XCTAssertEqual(preview.plan.setupChecks?.first?.expected, .bool(false))
        XCTAssertThrowsError(try PlanValidator.validate(actual.plan, approval: actual.approval, capabilities: actual.capabilities))
        let review = try await model.prepareNativeConfirmation(.run)
        XCTAssertTrue(review.message.contains("same real record")); XCTAssertFalse(review.message.contains("Submission remains unassessed"))
        _ = try model.cancelCommand(id: review.id)
        model.siriOracle.recordName = "Another test task"
        XCTAssertNotEqual(try model.makeSiriRunRequest(runID: "preview").plan.id, preview.plan.id)
        model.siriOracle.expectedState = "false"; XCTAssertFalse(model.canRun)
        model.siriOracle.expectedState = "true"; model.effectChoice = "external"; XCTAssertFalse(model.canRun)
        model.physicalDeviceID = "00008140-001049013EF3402C"; model.preparationSelectionChanged()
        XCTAssertFalse(model.siriOracle.enabled); model.close()
    }
    func testInventoryUsesStoreToolchainAndReportsItsFailureWithoutFallback() async throws {
        let box = TargetBox(), developer = URL(fileURLWithPath: "/private/tmp/Selected Xcode.app/Contents/Developer")
        let model = try model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity }, reader: { box.read() },
                              developerDirectory: developer, inventory: { selected, _ in
            XCTAssertEqual(selected, developer)
            throw AutomationContractError.missingEvidence("Selected Xcode unavailable")
        })
        await model.refreshTargets()
        XCTAssertTrue(model.message?.contains("Selected Xcode unavailable") == true)
        XCTAssertTrue(model.simulators.isEmpty)
        XCTAssertFalse(model.canPrepare)
        model.close()
    }
    private func folder(_ name: String = "source-extra") throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/" + name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testFolderGrantsRollbackInvalidSelectionsAndRetainExactScopes() throws {
        let primary = try folder(), extra = try folder(), ledger = SourceScopeLedger()
        let grants = ledger.grants()
        try grants.add(extra, primary: primary)
        XCTAssertThrowsError(try grants.add(extra, primary: primary))
        let child = extra.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        XCTAssertThrowsError(try grants.add(child, primary: primary))
        XCTAssertEqual(ledger.stopped, [child]); XCTAssertEqual(grants.urls, [extra])
        let alias = primary.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: extra)
        XCTAssertThrowsError(try grants.add(alias, primary: primary))
        XCTAssertEqual(ledger.stopped, [child, alias])
        grants.remove(extra); grants.clear()
        XCTAssertEqual(ledger.stopped, [child, alias, extra]); XCTAssertTrue(grants.urls.isEmpty)
        let failed = AutomationNativeSourceGrants(start: { _ in throw AutomationContractError.missingEvidence("Scope unavailable") }, stop: { _ in XCTFail("Unacquired scope released") })
        XCTAssertThrowsError(try failed.add(extra, primary: primary)); XCTAssertTrue(failed.urls.isEmpty)
    }
    func testFolderGrantLimitAndUnscopedReadableFolders() throws {
        let primary = try folder(), ledger = SourceScopeLedger(), grants = ledger.grants()
        for _ in 0..<8 { try grants.add(folder(), primary: primary) }
        XCTAssertThrowsError(try grants.add(folder(), primary: primary)); XCTAssertEqual(ledger.started.count, 8)
        grants.clear(); XCTAssertEqual(ledger.stopped.count, 8)
        let unscoped = AutomationNativeSourceGrants(start: { _ in false }, stop: { _ in XCTFail("Ordinary readable URL has no scope to release") })
        try unscoped.add(folder(), primary: primary); unscoped.clear()
    }
    func testFolderReviewBindsExactGrantsAndRejectsABAAndPrimaryChanges() throws {
        let box = TargetBox(), ledger = SourceScopeLedger()
        let model = try model(executor: { _, _, _ in XCTFail("Stale folder review built"); throw AutomationContractError.invalidIdentity }, reader: { box.read() }, grants: ledger.grants())
        model.preparationDestination = .macOS
        let extra = try folder(), before = try model.reviewNativePreparation()
        try model.selectAdditionalSourceFolder(extra)
        XCTAssertThrowsError(try model.confirmNativePreparation(before))
        let review = try model.reviewNativePreparation()
        XCTAssertEqual(review.additionalSourceRoots, [extra.path]); XCTAssertTrue(review.message.contains(extra.path))
        model.removeAdditionalSourceFolder(extra); try model.selectAdditionalSourceFolder(extra)
        XCTAssertThrowsError(try model.confirmNativePreparation(review))
        model.select(URL(fileURLWithPath: try XCTUnwrap(model.candidate).containerPath))
        XCTAssertTrue(model.sourceGrants.urls.isEmpty); XCTAssertEqual(ledger.stopped, [extra, extra])
    }
    func testAdditionalFolderApprovalAndCloseHoldScopesUntilPreparationDrains() async throws {
        let box = TargetBox(), gate = PreparationGate(), ledger = SourceScopeLedger()
        let model = try model(executor: { candidate, approval, session in
            await gate.suspend(approval)
            var value = preparedFixture(candidate, approval, session)
            value.source = try AutomationSourceCaptureLayout.aggregate([value.source] + (approval.additionalSourceRoots ?? []).map {
                AutomationSourceManifest(sourceRoot: $0, files: [], directories: [], excludedPaths: [])
            })
            return value
        }, reader: { box.read() }, grants: ledger.grants())
        model.preparationDestination = .macOS
        let extra = try folder(); try model.selectAdditionalSourceFolder(extra)
        let review = try model.reviewNativePreparation(); try model.confirmNativePreparation(review)
        let approval = await gate.waitForApproval(); XCTAssertEqual(approval.additionalSourceRoots, [extra.path])
        XCTAssertThrowsError(try model.selectAdditionalSourceFolder(folder()))
        model.removeAdditionalSourceFolder(extra); XCTAssertEqual(model.sourceGrants.urls, [extra])
        model.close(); XCTAssertTrue(ledger.stopped.isEmpty); XCTAssertEqual(model.sourceGrants.urls, [extra])
        await gate.release(); await model.waitForPreparation()
        XCTAssertEqual(ledger.stopped, [extra]); XCTAssertTrue(model.sourceGrants.urls.isEmpty)
        XCTAssertNil(model.prepared); XCTAssertFalse(model.busy)
    }
    func testAdditionalFolderPreparationPublishesExactCaptureAndRemovalInvalidatesIt() async throws {
        let box = TargetBox(), ledger = SourceScopeLedger()
        let model = try model(executor: { candidate, approval, session in
            var value = preparedFixture(candidate, approval, session)
            value.source = try AutomationSourceCaptureLayout.aggregate([value.source] + (approval.additionalSourceRoots ?? []).map {
                AutomationSourceManifest(sourceRoot: $0, files: [], directories: [], excludedPaths: [])
            })
            return value
        }, reader: { box.read() }, grants: ledger.grants())
        model.preparationDestination = .macOS
        let extra = try folder(); try model.selectAdditionalSourceFolder(extra)
        model.selectCandidate(); XCTAssertEqual(model.sourceGrants.urls, [extra])
        await model.prepareAndWait()
        XCTAssertEqual(model.prepared?.source.capturedRoots?.map(\.inputPath), [model.selectedSourceRoot!.path, extra.path])
        XCTAssertNotNil(model.catalog); XCTAssertTrue(ledger.stopped.isEmpty)
        model.removeAdditionalSourceFolder(extra)
        XCTAssertNil(model.prepared); XCTAssertNil(model.catalog); XCTAssertEqual(ledger.stopped, [extra])
        model.close(); XCTAssertEqual(ledger.stopped, [extra])
    }
    func testMacPreparationNeedsNoSimulatorAndRetainsExactSessionWithoutRunPermission() async throws {
        let box = TargetBox(), gate = PreparationGate()
        let model = try model(executor: { candidate, approval, session in
            await gate.suspend(approval); return preparedFixture(candidate, approval, session)
        }, reader: { box.read() })
        XCTAssertFalse(model.canPrepare)
        model.preparationDestination = .macOS; model.preparationSelectionChanged()
        XCTAssertTrue(model.canPrepare); XCTAssertFalse(model.needsSimulatorInventory)
        await model.refreshTargets()
        XCTAssertTrue(model.simulators.isEmpty); XCTAssertTrue(model.simulatorID.isEmpty); XCTAssertNil(model.message)
        let task = Task { await model.prepareAndWait() }
        let approval = await gate.waitForApproval()
        XCTAssertEqual(approval.target, box.read()); XCTAssertEqual(approval.configuration, "Debug")
        await gate.release(); await task.value
        XCTAssertEqual(model.prepared?.host.target, box.read()); XCTAssertFalse(model.busy)
        model.uiInstruction = "Open Settings"; model.uiEndpoint = "Settings"; model.effectChoice = "navigation"; model.effectsConfirmed = true
        model.simulatorID = "host-macos-local"
        for route in ["ui", "system", "fresh"] {
            model.workflowRoute = route; XCTAssertFalse(model.canRun)
            XCTAssertThrowsError(try model.previewCommand())
        }
        XCTAssertNil(model.report)
    }
    func testReturnedPreparationCannotAddRootGrantsOrChangeTheApprovedPrimaryRoot() async throws {
        for extra in [false, true] {
            let box = TargetBox()
            let model = try model(executor: { candidate, approval, session in
                var value = preparedFixture(candidate, approval, session)
                if extra {
                    let unapproved = AutomationSourceManifest(sourceRoot: approval.sourceRoot + "-extra", files: [], directories: [], excludedPaths: [])
                    value.source = try AutomationSourceCaptureLayout.aggregate([value.source, unapproved])
                } else { value.source.sourceRoot += "-other" }
                return value
            }, reader: { box.read() })
            model.preparationDestination = .macOS; model.preparationSelectionChanged()
            await model.prepareAndWait()
            XCTAssertNil(model.prepared); XCTAssertNil(model.catalog); XCTAssertNotNil(model.message); XCTAssertFalse(model.busy)
        }
    }
    func testSessionDriftDestinationChangeAndSelectionABARejectBuildCompletion() async throws {
        for mutation in 0..<3 {
            let box = TargetBox(), gate = PreparationGate()
            let model = try model(executor: { candidate, approval, session in
                await gate.suspend(approval); return preparedFixture(candidate, approval, session)
            }, reader: { box.read() })
            model.preparationDestination = .macOS; model.preparationSelectionChanged()
            let task = Task { await model.prepareAndWait() }
            _ = await gate.waitForApproval()
            if mutation == 0 { box.change() }
            else {
                model.preparationDestination = .simulator; model.preparationSelectionChanged()
                if mutation == 2 { model.preparationDestination = .macOS; model.preparationSelectionChanged() }
            }
            await gate.release(); await task.value
            XCTAssertNil(model.prepared); XCTAssertNil(model.catalog); XCTAssertFalse(model.busy); XCTAssertNotNil(model.message)
        }
    }
    func testSimulatorSelectionAndForeignPreparedTargetFailClosed() async throws {
        let box = TargetBox()
        let model = try model(executor: { candidate, approval, session in
            var result = preparedFixture(candidate, approval, session)
            result.host.target.loginSession = "foreign-session"; return result
        }, reader: { box.read() })
        model.simulatorID = "invalid"; XCTAssertFalse(model.canPrepare)
        model.simulatorID = UUID().uuidString
        XCTAssertTrue(model.canPrepare); XCTAssertTrue(model.needsSimulatorInventory)
        XCTAssertEqual(model.sourcePreparationTarget, .init(id: model.simulatorID, kind: .simulator))
        model.preparationDestination = .macOS; model.preparationSelectionChanged()
        await model.prepareAndWait()
        XCTAssertNil(model.prepared); XCTAssertNotNil(model.message)
        box.change()
        model.prepared = preparedFixture(try XCTUnwrap(model.candidate),
            .init(sourceRoot: "unused", candidateID: model.candidateID, configuration: "Debug", target: .init(id: "host-macos-local", kind: .nativeMac, loginSession: "source-session-A")), model.support)
        model.preparationSelectionChanged(); XCTAssertNil(model.prepared)
    }
    func testUnavailableNativeSessionCannotPrepare() throws {
        let model = try model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity },
                              reader: { throw AutomationContractError.missingEvidence("No GUI session") })
        model.preparationDestination = .macOS
        XCTAssertFalse(model.canPrepare); XCTAssertNil(model.sourcePreparationTarget)
        model.prepare(); XCTAssertFalse(model.busy)
    }
    func testConfigurationChangeDuringInventoryStillPopulatesSimulatorSelection() async throws {
        let box = TargetBox(), gate = InventoryGate()
        let simulator = AutomationSimulator(id: UUID().uuidString, name: "Synthetic", runtime: "iOS", state: "Shutdown")
        let model = try model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity }, reader: { box.read() },
                              inventory: { _, _ in await gate.suspend(); return [simulator] })
        let task = Task { await model.refreshTargets() }
        await gate.waitForEntry()
        model.configuration = "Release"; model.preparationSelectionChanged()
        await gate.release(); await task.value
        XCTAssertEqual(model.simulators, [simulator]); XCTAssertEqual(model.simulatorID, simulator.id)
        XCTAssertNil(model.message)
    }
    func testObsoleteAndCancelledInventoryErrorsCannotOverwriteCurrentMessage() async throws {
        for mutation in 0..<2 {
            let box = TargetBox(), gate = InventoryGate()
            let model = try model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity }, reader: { box.read() },
                inventory: { _, _ in await gate.suspend(); throw AutomationContractError.missingEvidence("Old inventory failure") })
            let task = Task { await model.refreshTargets() }
            await gate.waitForEntry()
            if mutation == 0 { model.preparationDestination = .macOS; model.preparationSelectionChanged() }
            else { task.cancel() }
            model.message = "Current selection"
            await gate.release(); await task.value
            XCTAssertEqual(model.message, "Current selection"); XCTAssertTrue(model.simulators.isEmpty)
        }
    }
    func testNewerInventoryRequestSupersedesAnOlderSuccessfulResult() async throws {
        let box = TargetBox(), first = InventoryGate(), second = InventoryGate()
        let sequence = InventorySequence(first, second)
        let model = try model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity }, reader: { box.read() },
                              inventory: { _, _ in try await sequence.read() })
        let old = Task { await model.refreshTargets() }; await first.waitForEntry()
        let current = Task { await model.refreshTargets() }; await second.waitForEntry()
        await second.release(); await current.value
        XCTAssertEqual(model.simulators.first?.name, "Current")
        await first.release(); await old.value
        XCTAssertEqual(model.simulators.first?.name, "Current")
    }
    func testCancelledAndClosedPreparationCannotPublishAfterAnIgnoringExecutorReturns() async throws {
        for close in [false, true] {
            let box = TargetBox(), gate = PreparationGate()
            let model = try model(executor: { candidate, approval, session in
                await gate.suspend(approval); return preparedFixture(candidate, approval, session)
            }, reader: { box.read() })
            model.preparationDestination = .macOS
            let task = Task { await model.prepareAndWait() }; _ = await gate.waitForApproval()
            if close { model.close() } else { model.cancel() }
            await gate.release(); await task.value
            XCTAssertNil(model.prepared); XCTAssertNil(model.catalog); XCTAssertFalse(model.busy)
        }
    }
    func testNativePreparationReviewRejectsConfigurationDestinationSessionAndABADrift() throws {
        for mutation in 0..<4 {
            let box = TargetBox()
            let model = try model(executor: { _, _, _ in XCTFail("Stale preparation started"); throw AutomationContractError.invalidIdentity }, reader: { box.read() })
            model.preparationDestination = .macOS; model.preparationSelectionChanged()
            let review = try model.reviewNativePreparation()
            switch mutation {
            case 0: model.configuration = "Release"
            case 1: model.preparationDestination = .simulator; model.simulatorID = UUID().uuidString
            case 2: box.change()
            default:
                model.preparationDestination = .simulator; model.preparationSelectionChanged()
                model.preparationDestination = .macOS; model.preparationSelectionChanged()
            }
            XCTAssertThrowsError(try model.confirmNativePreparation(review))
            XCTAssertFalse(model.busy); XCTAssertNil(model.prepared)
        }
    }
    func testNativePreparationReviewIsConsumedOnceAndKeepsExactTarget() async throws {
        let box = TargetBox(), gate = PreparationGate()
        let model = try model(executor: { candidate, approval, session in
            await gate.suspend(approval); return preparedFixture(candidate, approval, session)
        }, reader: { box.read() })
        model.preparationDestination = .macOS; model.preparationSelectionChanged()
        let review = try model.reviewNativePreparation()
        XCTAssertTrue(review.message.contains("Configuration: Debug")); XCTAssertTrue(review.message.contains("Destination: This Mac"))
        try model.confirmNativePreparation(review)
        let approval = await gate.waitForApproval(); XCTAssertEqual(approval.target, review.target)
        await gate.release(); await model.waitForPreparation()
        XCTAssertEqual(model.prepared?.host.target, review.target)
        XCTAssertThrowsError(try model.confirmNativePreparation(review)); XCTAssertFalse(model.busy)
    }
    func testNativePreparationExpectedTargetRejectsSessionDriftBeforeBuild() throws {
        let box = TargetBox()
        let model = try model(executor: { _, _, _ in XCTFail("Changed target built"); throw AutomationContractError.invalidIdentity }, reader: { box.read() })
        model.preparationDestination = .macOS
        let target = try XCTUnwrap(model.sourcePreparationTarget)
        box.change(); XCTAssertTrue(model.canPrepare)
        model.prepare(expectedTarget: target)
        XCTAssertFalse(model.busy); XCTAssertNil(model.prepared)
        XCTAssertEqual(model.message, "The build destination changed. Review it again.")
    }

}
@MainActor private final class SourceScopeLedger {
    var started: [URL] = [], stopped: [URL] = []
    func grants() -> AutomationNativeSourceGrants {
        AutomationNativeSourceGrants(start: { self.started.append($0); return true }, stop: { self.stopped.append($0) })
    }
}
private actor InventoryGate {
    private var didEnter = false
    private var entered: CheckedContinuation<Void, Never>?
    private var released: CheckedContinuation<Void, Never>?
    func suspend() async {
        didEnter = true; entered?.resume(); entered = nil
        await withCheckedContinuation { released = $0 }
    }
    func waitForEntry() async { if !didEnter { await withCheckedContinuation { entered = $0 } } }
    func release() { released?.resume(); released = nil }
}
private actor InventorySequence {
    private var calls = 0
    private let gates: [InventoryGate]
    init(_ first: InventoryGate, _ second: InventoryGate) { gates = [first, second] }
    func read() async throws -> [AutomationSimulator] {
        let index = calls; calls += 1
        guard index < gates.count else { throw AutomationContractError.invalidIdentity }
        await gates[index].suspend()
        return [.init(id: index == 0 ? "00000000-0000-0000-0000-000000000001" : "00000000-0000-0000-0000-000000000002",
                      name: index == 0 ? "Old" : "Current", runtime: "iOS", state: "Shutdown")]
    }
}
private actor PreparationGate {
    private var approval: AutomationBuildApproval?
    private var entered: CheckedContinuation<AutomationBuildApproval, Never>?
    private var released: CheckedContinuation<Void, Never>?
    func suspend(_ value: AutomationBuildApproval) async {
        approval = value; entered?.resume(returning: value); entered = nil
        await withCheckedContinuation { released = $0 }
    }
    func waitForApproval() async -> AutomationBuildApproval {
        if let approval { return approval }
        return await withCheckedContinuation { entered = $0 }
    }
    func release() { released?.resume(); released = nil }
}
private func preparedFixture(_ candidate: AutomationApplicationCandidate, _ approval: AutomationBuildApproval, _ session: URL) -> AutomationPreparedApplication {
    var app = AppIdentity(logicalID: candidate.id, bundleID: "example.Subject", platform: approval.target.kind == .nativeMac ? "macos" : "ios",
                          productDigest: String(repeating: "a", count: 64))
    app.configuration = approval.configuration
    return .init(source: .init(sourceRoot: approval.sourceRoot, files: [], directories: [], excludedPaths: []),
        generatedHost: .init(projectPath: "unused", scheme: "unused", targetID: "HOST", bundleID: "example.Host", configuration: approval.configuration, templateDigest: "unused"),
        host: .init(app: app, target: approval.target, xctestrunPath: "unused", xctestrunDigest: "unused", subjectProductPath: session.path,
                    hostBundlePath: "unused", hostProductDigest: "unused", hostBundleID: "example.Host", testTarget: "Host"),
        catalog: .init(app: app, systemActions: [], systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: []), buildLogPath: "unused", buildLogTruncated: false)
}
#endif
