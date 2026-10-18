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
                       inventory: @escaping AutomationNativeSimulatorInventoryReader = { _, _ in throw AutomationContractError.invalidIdentity },
                       physicalInventory: @escaping AutomationNativePhysicalInventoryReader = { _, _ in throw AutomationContractError.invalidIdentity },
                       physicalTargetResolver: (@Sendable (TargetIdentity, URL, URL) async throws -> TargetIdentity)? = nil,
                       toolchainReader: @escaping (URL) -> [AutomationNativeToolchainChoice] = { AutomationNativeToolchain.installedChoices(configured: $0) },
                       siriSearchExecutor: AutomationNativeSiriSearchExecutor? = nil) async throws -> AppAutomationStore {
        let root = URL(fileURLWithPath: "/private/tmp/source-preparation-" + UUID().uuidString)
        let project = root.appendingPathComponent("Subject.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let objects: [String: Any] = ["APP": ["isa": "PBXNativeTarget", "name": "Subject", "productType": "com.apple.product-type.application", "buildConfigurationList": "LIST"],
            "LIST": ["buildConfigurations": ["DEBUG"]], "DEBUG": ["name": "Debug"]]
        try PropertyListSerialization.data(fromPropertyList: ["objects": objects], format: .xml, options: 0).write(to: project.appendingPathComponent("project.pbxproj"))
        let suite = "source-preparation-tests." + UUID().uuidString
        let settings = AutomationNativeXcodeSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = AppAutomationStore(supportDirectory: root.appendingPathComponent("support"), developerDirectory: developerDirectory,
                                       xcodeSettings: settings, siriSearchExecutor: siriSearchExecutor, nativeMacTargetReader: reader,
                                       preparationExecutor: executor, sourceGrants: grants, physicalTargetResolver: physicalTargetResolver ?? { target, _, _ in
                                           var value = target; value.physicalDeviceIdentifier = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"; return value
                                       }, simulatorInventoryReader: inventory, physicalInventoryReader: physicalInventory, installedToolchainReader: toolchainReader)
        model.select(project); await model.task?.value
        return model
    }
    private func installedXcodeFixture(_ name: String, version: String, build: String, root: URL) throws -> URL {
        let contents = root.appendingPathComponent(name + ".app/Contents"), developer = contents.appendingPathComponent("Developer")
        let executables = [developer.appendingPathComponent("usr/bin/xcodebuild"),
            developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc")]
        for executable in executables {
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("test-only; never executed".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let sdk = developer.appendingPathComponent("Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Version": version], format: .xml, options: 0).write(to: sdk.appendingPathComponent("SDKSettings.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleShortVersionString": version], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["ProductBuildVersion": build], format: .xml, options: 0).write(to: contents.appendingPathComponent("version.plist"))
        return try AutomationPath.canonical(developer)
    }
    private final class PreparationInvocationCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    func testInstalledXcodeSelectionBindsPreparationAndInvalidatesOlderReview() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/native-xcode-picker-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try installedXcodeFixture("Xcode", version: "27.0", build: "27A266a", root: root)
        let beta = try installedXcodeFixture("Xcode-Beta", version: "27.2", build: "27B5028f", root: root)
        let box = TargetBox()
        let value = try await model(executor: { candidate, approval, session in
            var prepared = preparedFixture(candidate, approval, session); prepared.selectedDeveloperDirectoryPath = beta.path; return prepared
        }, reader: { box.read() }, developerDirectory: original,
            toolchainReader: { AutomationNativeToolchain.installedChoices(configured: $0, applications: [root], selected: nil) })
        value.preparationDestination = .macOS; value.preparationSelectionChanged()
        XCTAssertEqual(value.defaultDeveloperDirectoryPath, original.path)
        XCTAssertEqual(Set(value.installedToolchains.map(\.id)), Set([original.path, beta.path]))
        let stale = try value.reviewNativePreparation(), epoch = value.selectionEpoch
        try value.selectInstalledToolchain(beta.path)
        XCTAssertEqual(value.developerDirectory, beta); XCTAssertTrue(value.hasExplicitToolchainSelection)
        XCTAssertGreaterThan(value.selectionEpoch, epoch); XCTAssertNil(value.prepared); XCTAssertNil(value.catalog)
        XCTAssertThrowsError(try value.confirmNativePreparation(stale))
        let review = try value.reviewNativePreparation()
        XCTAssertEqual(review.developerDirectoryPath, beta.path); XCTAssertTrue(review.message.contains("Xcode 27.2 (27B5028f)"))
        try value.confirmNativePreparation(review); await value.waitForPreparation()
        XCTAssertEqual(value.prepared?.selectedDeveloperDirectoryPath, beta.path)
        XCTAssertEqual(value.developerDirectory, beta)
    }
    func testSelectedXcodeMetadataDriftAndUnexpectedBuildFallbackFailClosed() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/native-xcode-drift-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try installedXcodeFixture("Xcode", version: "27.0", build: "27A266a", root: root)
        let beta = try installedXcodeFixture("Xcode-Beta", version: "27.2", build: "27B5028f", root: root)
        let box = TargetBox(), builds = PreparationInvocationCount()
        let value = try await model(executor: { candidate, approval, session in
            builds.record()
            var prepared = preparedFixture(candidate, approval, session); prepared.selectedDeveloperDirectoryPath = original.path; return prepared
        }, reader: { box.read() }, developerDirectory: original,
            toolchainReader: { AutomationNativeToolchain.installedChoices(configured: $0, applications: [root], selected: nil) })
        value.preparationDestination = .macOS; value.preparationSelectionChanged()
        XCTAssertThrowsError(try value.selectInstalledToolchain("/unselected/Xcode.app/Contents/Developer"))
        try value.selectInstalledToolchain(beta.path)
        let stale = try value.reviewNativePreparation()
        try PropertyListSerialization.data(fromPropertyList: ["ProductBuildVersion": "27B9999"], format: .xml, options: 0)
            .write(to: beta.deletingLastPathComponent().appendingPathComponent("version.plist"))
        XCTAssertThrowsError(try value.confirmNativePreparation(stale)); XCTAssertFalse(value.busy)
        XCTAssertEqual(builds.value, 0, "Changed selected metadata must fail before private preparation starts")
        value.refreshInstalledToolchains()
        try value.selectInstalledToolchain(beta.path)
        let review = try value.reviewNativePreparation()
        try value.confirmNativePreparation(review); await value.waitForPreparation()
        XCTAssertNil(value.prepared); XCTAssertNil(value.catalog)
        XCTAssertEqual(value.developerDirectory, beta)
        XCTAssertTrue(value.message?.contains("selected Xcode could not prepare") == true)
    }
    func testReplacingSelectedXcodeAtSamePathInvalidatesPreparedAppAndReview() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/native-xcode-replacement-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let beta = try installedXcodeFixture("Xcode-Beta", version: "27.2", build: "27B5028f", root: root)
        let box = TargetBox()
        let value = try await model(executor: { candidate, approval, session in
            var prepared = preparedFixture(candidate, approval, session); prepared.selectedDeveloperDirectoryPath = beta.path; return prepared
        }, reader: { box.read() }, developerDirectory: beta,
            toolchainReader: { AutomationNativeToolchain.installedChoices(configured: $0, applications: [root], selected: nil) })
        value.preparationDestination = .macOS; value.preparationSelectionChanged()
        let defaultReview = try value.reviewNativePreparation()
        XCTAssertNil(defaultReview.toolchainMetadataDigest, "Default discovery preserves legacy approval semantics")
        try value.selectInstalledToolchain(beta.path)
        XCTAssertThrowsError(try value.confirmNativePreparation(defaultReview))
        let originalReview = try value.reviewNativePreparation()
        try value.confirmNativePreparation(originalReview); await value.waitForPreparation()
        XCTAssertNotNil(value.prepared); XCTAssertNotNil(value.catalog)
        let stale = try value.reviewNativePreparation(), epoch = value.selectionEpoch
        let originalDigest = value.selectedToolchainMetadataDigest
        _ = try installedXcodeFixture("Xcode-Beta", version: "27.2", build: "27B9999", root: root)
        value.refreshInstalledToolchains()
        XCTAssertThrowsError(try value.reviewNativePreparation(), "Refresh alone must not silently approve new metadata")
        try value.selectInstalledToolchain(beta.path)
        XCTAssertEqual(value.developerDirectory, beta)
        XCTAssertNotEqual(value.selectedToolchainMetadataDigest, originalDigest)
        XCTAssertGreaterThan(value.selectionEpoch, epoch)
        XCTAssertNil(value.prepared); XCTAssertNil(value.catalog)
        XCTAssertThrowsError(try value.confirmNativePreparation(stale))
        XCTAssertTrue(try value.reviewNativePreparation().message.contains("27B9999"))
    }
    func testSelectedXcodeReplacementDuringPreparationWithholdsPreparedApp() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/native-xcode-pending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let beta = try installedXcodeFixture("Xcode-Beta", version: "27.2", build: "27B5028f", root: root)
        let box = TargetBox(), gate = PreparationGate()
        let value = try await model(executor: { candidate, approval, session in
            await gate.suspend(approval)
            var prepared = preparedFixture(candidate, approval, session); prepared.selectedDeveloperDirectoryPath = beta.path; return prepared
        }, reader: { box.read() }, developerDirectory: beta,
            toolchainReader: { AutomationNativeToolchain.installedChoices(configured: $0, applications: [root], selected: nil) })
        value.preparationDestination = .macOS; value.preparationSelectionChanged()
        try value.selectInstalledToolchain(beta.path)
        let review = try value.reviewNativePreparation()
        try value.confirmNativePreparation(review)
        _ = await gate.waitForApproval()
        _ = try installedXcodeFixture("Xcode-Beta", version: "27.2", build: "27B9999", root: root)
        await gate.release(); await value.waitForPreparation()
        XCTAssertNil(value.prepared); XCTAssertNil(value.catalog)
        XCTAssertEqual(value.selectedToolchainMetadataDigest, review.toolchainMetadataDigest)
        XCTAssertTrue(value.message?.contains("reviewed Xcode installation changed") == true)
    }

    func testDestinationToolchainsKeepSeparateReviewedMetadataAndDetectReplacementOnReturn() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/native-xcode-destinations-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try installedXcodeFixture("Xcode", version: "27.0", build: "27A266a", root: root)
        let beta = try installedXcodeFixture("Xcode-Beta", version: "27.2", build: "27B5028f", root: root)
        let box = TargetBox()
        let value = try await model(executor: { candidate, approval, session in
            var prepared = preparedFixture(candidate, approval, session)
            prepared.selectedDeveloperDirectoryPath = approval.target.kind == .nativeMac ? beta.path : original.path
            return prepared
        }, reader: { box.read() }, developerDirectory: original,
            toolchainReader: { AutomationNativeToolchain.installedChoices(configured: $0, applications: [root], selected: nil) })
        value.simulatorID = UUID().uuidString
        value.xcodeSettings.setPath(beta.path, for: .macOS)
        try value.selectInstalledToolchain(original.path)
        let simulatorReview = try value.reviewNativePreparation()

        value.preparationDestination = .macOS; value.preparationSelectionChanged()

        let macReview = try value.reviewNativePreparation()
        XCTAssertEqual(macReview.developerDirectoryPath, beta.path)
        XCTAssertNotEqual(macReview.toolchainMetadataDigest, simulatorReview.toolchainMetadataDigest)
        XCTAssertThrowsError(try value.confirmNativePreparation(simulatorReview))
        try value.confirmNativePreparation(macReview); await value.waitForPreparation()
        XCTAssertEqual(value.prepared?.selectedDeveloperDirectoryPath, beta.path)

        _ = try installedXcodeFixture("Xcode", version: "27.0", build: "27A9999", root: root)
        value.preparationDestination = .simulator; value.preparationSelectionChanged()

        XCTAssertEqual(value.developerDirectory, original)
        XCTAssertThrowsError(try value.reviewNativePreparation(), "Returning to a path must preserve its reviewed metadata")
        value.refreshInstalledToolchains()
        try value.selectInstalledToolchain(original.path)
        let refreshed = try value.reviewNativePreparation()
        XCTAssertNotEqual(refreshed.toolchainMetadataDigest, simulatorReview.toolchainMetadataDigest)
        try value.confirmNativePreparation(refreshed); await value.waitForPreparation()
        XCTAssertEqual(value.prepared?.selectedDeveloperDirectoryPath, original.path)
    }

    func testDefaultAndOverrideEditsReviewEffectiveToolchainAndPickerUpdatesActiveOverride() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/native-xcode-overrides-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try installedXcodeFixture("Xcode", version: "27.0", build: "27A266a", root: root)
        let beta = try installedXcodeFixture("Xcode-Beta", version: "27.2", build: "27B5028f", root: root)
        let box = TargetBox()
        let value = try await model(executor: { candidate, approval, session in
            var prepared = preparedFixture(candidate, approval, session); prepared.selectedDeveloperDirectoryPath = beta.path
            return prepared
        }, reader: { box.read() }, developerDirectory: original,
            toolchainReader: { AutomationNativeToolchain.installedChoices(configured: $0, applications: [root], selected: nil) })
        value.preparationDestination = .macOS; value.preparationSelectionChanged()
        try value.selectInstalledToolchain(original.path)
        let originalReview = try value.reviewNativePreparation()
        value.selectedXcodePath = beta.path
        let defaultReview = try value.reviewNativePreparation()
        XCTAssertEqual(defaultReview.developerDirectoryPath, beta.path)
        XCTAssertNotEqual(defaultReview.toolchainMetadataDigest, originalReview.toolchainMetadataDigest)
        XCTAssertThrowsError(try value.confirmNativePreparation(originalReview))

        value.selectedXcodePath = original.path
        value.runXcodePathOverride = beta.path
        XCTAssertEqual(try value.reviewNativePreparation().developerDirectoryPath, beta.path)
        try value.selectInstalledToolchain(original.path)
        XCTAssertEqual(value.runXcodePathOverride, original.path)
        XCTAssertEqual(try value.reviewNativePreparation().developerDirectoryPath, original.path)
        try value.selectInstalledToolchain(beta.path)
        XCTAssertEqual(value.runXcodePathOverride, beta.path)
        XCTAssertEqual(value.selectedXcodePath, original.path, "A picker change during an override must preserve the destination default")
        let overrideReview = try value.reviewNativePreparation()
        try value.confirmNativePreparation(overrideReview); await value.waitForPreparation()
        XCTAssertEqual(value.prepared?.selectedDeveloperDirectoryPath, beta.path)

        value.runXcodePathOverride = ""
        XCTAssertEqual(value.developerDirectory, original)
        XCTAssertThrowsError(try value.confirmNativePreparation(overrideReview))
        XCTAssertEqual(try value.reviewNativePreparation().toolchainMetadataDigest, originalReview.toolchainMetadataDigest)
    }
    func testPhysicalInventorySelectsOnlySingleAvailableDeviceByExactIdentity() async throws {
        let phone = AutomationPhysicalDevice(id: "00008140-000E4D803C0B001C", name: "iPhone", model: "iPhone", operatingSystem: "27.2", available: true)
        let value = try await model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity },
            reader: { throw AutomationContractError.invalidIdentity }, physicalInventory: { _, _ in [phone] })
        value.preparationDestination = .physical
        await value.refreshTargets()
        XCTAssertEqual(value.physicalDevices, [phone])
        XCTAssertEqual(value.sourcePreparationTarget?.id, phone.id)
        XCTAssertTrue(value.canPrepare)
        value.physicalDeviceID = "00008140-000E4D803C0B002C"
        await value.refreshTargets()
        XCTAssertEqual(value.physicalDeviceID, "")
        XCTAssertFalse(value.canPrepare, "A disappeared selection must not silently switch to another device")
    }
    func testPhysicalInventoryRequiresChoiceForDuplicateNamesAndPreservesUnavailableDevices() async throws {
        let first = AutomationPhysicalDevice(id: "00008140-000E4D803C0B001C", name: "iPhone", model: "iPhone", operatingSystem: "27.2", available: true)
        var second = first; second.id = "00008140-000E4D803C0B002C"
        let devices = [first, second]
        let value = try await model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity },
            reader: { throw AutomationContractError.invalidIdentity }, physicalInventory: { _, _ in devices })
        value.preparationDestination = .physical
        await value.refreshTargets()
        XCTAssertEqual(value.physicalDeviceID, "")
        XCTAssertFalse(value.canPrepare)
        value.physicalDeviceID = second.id
        await value.refreshTargets()
        XCTAssertEqual(value.physicalDeviceID, second.id)
    }
    func testPhysicalInventoryCannotApplyAfterDestinationChanges() async throws {
        let gate = InventoryGate()
        let phone = AutomationPhysicalDevice(id: "00008140-000E4D803C0B001C", name: "iPhone", model: "iPhone", operatingSystem: "27.2", available: true)
        let value = try await model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity },
            reader: { throw AutomationContractError.invalidIdentity }, physicalInventory: { _, _ in await gate.suspend(); return [phone] })
        value.preparationDestination = .physical
        let refresh = Task { await value.refreshTargets() }
        await gate.waitForEntry()
        value.preparationDestination = .macOS
        await gate.release(); await refresh.value
        XCTAssertTrue(value.physicalDevices.isEmpty); XCTAssertTrue(value.physicalDeviceID.isEmpty)
    }
    func testUnavailablePhysicalDeviceCannotBecomeDefaultSelection() async throws {
        let phone = AutomationPhysicalDevice(id: "00008140-000E4D803C0B001C", name: "iPhone", model: "iPhone", operatingSystem: "27.2", available: false)
        let value = try await model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity },
            reader: { throw AutomationContractError.invalidIdentity }, physicalInventory: { _, _ in [phone] })
        value.preparationDestination = .physical
        await value.refreshTargets()
        XCTAssertEqual(value.physicalDevices, [phone]); XCTAssertTrue(value.physicalDeviceID.isEmpty); XCTAssertFalse(value.canPrepare)
    }
    func testFailedPhysicalRefreshClearsStaleSelection() async throws {
        let value = try await model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity }, reader: { throw AutomationContractError.invalidIdentity })
        value.preparationDestination = .physical
        value.physicalDeviceID = "00008140-000E4D803C0B001C"
        await value.refreshTargets()
        XCTAssertTrue(value.physicalDevices.isEmpty)
        XCTAssertTrue(value.physicalDeviceID.isEmpty)
        XCTAssertNotNil(value.message)
        XCTAssertFalse(value.canPrepare)
    }
    func testPreparedToolchainRecoveryIsRetainedForSubsequentExecution() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/native-selected-xcode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = TargetBox()
        let value = try await model(executor: { candidate, approval, session in
            var prepared = preparedFixture(candidate, approval, session)
            prepared.selectedDeveloperDirectoryPath = root.path
            return prepared
        }, reader: { box.read() }, developerDirectory: URL(fileURLWithPath: "/missing/configured/Xcode.app"))
        value.preparationDestination = .macOS; value.preparationSelectionChanged()
        XCTAssertTrue(value.canPrepare)
        await value.prepareAndWait()
        XCTAssertEqual(value.developerDirectory.path, try AutomationPath.canonical(root).path)
        XCTAssertNotNil(value.prepared)
    }
    private func siriSearchModel(executor: AutomationNativeSiriSearchExecutor? = nil) async throws -> AppAutomationStore {
        let box = TargetBox()
        let model = try await model(executor: { candidate, approval, session in
            var value = try preparedPhysicalFixture(candidate, approval, session)
            value.catalog.entities = [.init(typeID: "TaskEntity", title: "Task", queryIdentifier: "TaskQuery",
                properties: ["title": "text", "completed": "bool"], propertyTitles: [:])]
            value.catalog.systemActions = [.init(id: "SetStateIntent", typeName: "SetStateIntent", title: "Restore task state",
                parameters: [.init(name: "task", family: "entity", optional: false, typeID: "TaskEntity"),
                    .init(name: "completed", family: "bool", optional: false)], parametersComplete: true,
                compiled: true, registered: true, executed: false, resultFamily: "noValue")]
            return value
        }, reader: { box.read() }, siriSearchExecutor: executor)
        model.preparationDestination = .physical; model.physicalDeviceID = "00008140-001049013EF3401C"
        model.preparationSelectionChanged(); await model.prepareAndWait()
        model.workflowRoute = "siri"; model.siriRequest = "Complete Approved test task in Example"
        model.effectChoice = "fixture"; model.effectsConfirmed = true; model.disposable = true; model.installApproved = true
        for capability in ["siri.recognizedText.api", "apple.intent.invoke", "apple.codec.bool", "apple.codec.entity"] {
            model.siriCapabilities.records[capability] = .init(state: .available, reason: "test-only grammar", probeVersion: "test", evidence: [])
        }
        model.siriOracle = .init(enabled: true, entityType: "TaskEntity", nameProperty: "title", recordName: "Approved test task",
            stateProperty: "completed", initialState: "false", expectedState: "true")
        model.siriResetActionID = "SetStateIntent"; model.siriAccountEnvironment = "disposable/account-A"
        model.siriAlternatePhrases = "Finish Approved test task in Example"
        return model
    }
    func testSiriSearchReviewHashIsStableAndRejectsChangedPhraseAndEpochBeforeExecution() async throws {
        let model = try await siriSearchModel()
        XCTAssertTrue(model.canFindSiriFailures)
        let first = try model.reviewSiriFailureSearch(), second = try model.reviewSiriFailureSearch()
        XCTAssertEqual(first.digest, second.digest); XCTAssertEqual(first.baseline.digest, second.baseline.digest)
        XCTAssertEqual(first.baseline.plan.setup.count, 3); XCTAssertEqual(first.mutations.first?.subjectPhraseSlot, .siriRecognizedText)
        XCTAssertTrue(first.message.contains(model.siriAlternatePhrases)); XCTAssertTrue(first.message.contains("disposable/account-A"))
        model.siriAlternatePhrases = "Mark Approved test task complete in Example"
        XCTAssertNotEqual(try model.reviewSiriFailureSearch().digest, first.digest)
        await model.findSiriFailures(reviewed: first)
        XCTAssertNotNil(model.message); XCTAssertNil(model.task); XCTAssertNil(model.searchReport)
        model.siriAlternatePhrases = "Finish Approved test task in Example"
        model.advanceSelection()
        await model.findSiriFailures(reviewed: first)
        XCTAssertNotNil(model.message); XCTAssertNil(model.task); XCTAssertNil(model.searchReport)
        model.siriAccountEnvironment = "different-account"
        XCTAssertNotEqual(try model.reviewSiriFailureSearch().digest, first.digest)
        model.close()
    }
    func testSiriSearchResetsExactRetainedCampaignAfterInterruptionOrThrow() async throws {
        for throwsAfterReservation in [false, true] {
            let model = try await siriSearchModel { review, support in
                let owner = try AutomationDeviceLeaseManager(storeURL: support.appendingPathComponent("target-leases.json"))
                try await owner.reserveCampaign(runID: review.approval.run.runID, target: review.baseline.plan.target)
                if throwsAfterReservation { throw AutomationContractError.terminationUnverified }
                return .init(baselineDigest: review.baseline.digest, interruptions: [.init(attemptID: UUID().uuidString,
                    caseDigest: review.baseline.digest, stage: .baseline, dispatchMayHaveOccurred: true, reason: "Retained test campaign")])
            }
            await model.ownershipRecoveryTask?.value
            let review = try model.reviewSiriFailureSearch()
            await model.findSiriFailures(reviewed: review)
            XCTAssertEqual(model.retainedUnresolvedRequestTargets[review.approval.run.runID], review.baseline.plan.target)
            XCTAssertFalse(model.canFindSiriFailures)

            await model.clearUnresolvedAttempt()

            XCTAssertNil(model.recoveryError)
            let leases = try AutomationDeviceLeaseManager(storeURL: model.support.appendingPathComponent("target-leases.json"))
            let released = try await leases.campaignAbsent(target: review.baseline.plan.target)
            XCTAssertTrue(released)
            XCTAssertTrue(model.canFindSiriFailures)
            await model.closeAndWait()
        }
    }
    func testManualPhysicalDestinationResolvesOwnershipBeforeFreezingBuildApproval() async throws {
        let uuid = "1AD4F755-6F58-58E5-AC71-B1EDFECADA93", udid = "00008140-000E4D803C0B001C"
        let model = try await model(executor: { candidate, approval, session in
            XCTAssertEqual(approval.target.id, udid)
            XCTAssertEqual(approval.target.physicalDeviceIdentifier, uuid)
            return preparedFixture(candidate, approval, session)
        }, reader: { throw AutomationContractError.invalidIdentity }, physicalTargetResolver: { target, _, _ in
            var target = target; target.physicalDeviceIdentifier = uuid; return target
        })
        model.preparationDestination = .physical; model.physicalDeviceID = udid
        let reviewed = try XCTUnwrap(model.sourcePreparationTarget)
        XCTAssertNil(reviewed.physicalDeviceIdentifier)
        model.prepare(expectedTarget: reviewed); await model.waitForPreparation()
        XCTAssertTrue(model.message?.hasPrefix("Prepared a private copy.") == true)
        XCTAssertEqual(model.prepared?.host.target.id, udid)
        XCTAssertEqual(model.prepared?.host.target.physicalDeviceIdentifier, uuid)
        XCTAssertEqual(model.sourcePreparationTarget, model.prepared?.host.target)
    }
    func testPhysicalOwnershipDiscoveryCannotBuildAfterDestinationChanges() async throws {
        let gate = InventoryGate()
        let model = try await model(executor: { _, _, _ in
            XCTFail("A destination changed during discovery must not build"); throw AutomationContractError.invalidIdentity
        }, reader: { throw AutomationContractError.invalidIdentity }, physicalTargetResolver: { target, _, _ in
            await gate.suspend()
            var target = target; target.physicalDeviceIdentifier = "1AD4F755-6F58-58E5-AC71-B1EDFECADA93"; return target
        })
        model.preparationDestination = .physical; model.physicalDeviceID = "00008140-000E4D803C0B001C"
        model.prepare(); await gate.waitForEntry()
        model.physicalDeviceID = "00008140-000E4D803C0B002C"
        await gate.release(); await model.waitForPreparation()
        XCTAssertNil(model.prepared); XCTAssertNotNil(model.message)
        XCTAssertTrue(model.resolvedPhysicalDeviceIdentifiers.isEmpty)
    }
    func testDeveloperDirectoryHonorsLaunchOverrideAndXcodeBundlePath() throws {
        let fallback = "/Applications/Xcode.app/Contents/Developer"
        XCTAssertEqual(AutomationNativeToolchain.developerDirectory(environment: [:], applications: [], selected: nil).path, fallback)
        XCTAssertEqual(AutomationNativeToolchain.developerDirectory(environment: ["DEVELOPER_DIR": ""], applications: [], selected: nil).path, fallback)
        let root = URL(fileURLWithPath: "/private/tmp/native-toolchain-" + UUID().uuidString)
        let contents = root.appendingPathComponent("Xcode Compatible.app/Contents"), developer = contents.appendingPathComponent("Developer")
        try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleShortVersionString": "27.2"], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        for selected in [developer.path, contents.deletingLastPathComponent().path] {
            XCTAssertEqual(AutomationNativeToolchain.developerDirectory(environment: ["DEVELOPER_DIR": selected], applications: [], selected: nil, probe: { _, _ in true }).path, developer.path)
        }
        XCTAssertEqual(AutomationNativeToolchain.developerDirectory(environment: ["DEVELOPER_DIR": "/missing/Xcode.app"], applications: [root], selected: nil, probe: { _, _ in true }).path, developer.path)
    }
    func testPhysicalSourceSelectionAndSiriSubmissionApprovalStayExactAndUnassessed() async throws {
        let box = TargetBox()
        let model = try await model(executor: { candidate, approval, session in
            try preparedPhysicalFixture(candidate, approval, session)
        }, reader: { box.read() })
        model.preparationDestination = .physical; model.physicalDeviceID = "iPhone"
        model.preparationSelectionChanged(); XCTAssertFalse(model.canPrepare)
        model.physicalDeviceID = "00008140-001049013EF3401C"; model.preparationSelectionChanged()
        XCTAssertTrue(model.canPrepare); XCTAssertFalse(model.needsSimulatorInventory)
        await model.prepareAndWait(); XCTAssertEqual(model.prepared?.host.target.kind, .physical)
        model.workflowRoute = "siri"; model.siriRequest = "Open the approved fixture"
        model.effectChoice = "navigation"; model.effectsConfirmed = true; model.disposable = true; model.installApproved = true
        XCTAssertEqual(model.siriCapabilities.records["siri.recognizedText.api"]?.state, .available)
        model.siriCapabilities.records["siri.recognizedText.api"]?.state = .unknown
        XCTAssertFalse(model.canRun, "A missing submission capability must prevent running")
        model.siriCapabilities.records["siri.recognizedText.api"] = .init(state: .available, reason: "test-only grammar", probeVersion: "test", evidence: [])
        XCTAssertTrue(model.canRun)
        let first = try model.makeSiriRunRequest(runID: "preview"), second = try model.makeSiriRunRequest(runID: UUID().uuidString)
        XCTAssertEqual(first.digest, second.digest); XCTAssertEqual(first.caseDigest, second.caseDigest)
        XCTAssertEqual(first.plan.execution.kind, .siriText); XCTAssertEqual(first.plan.execution.siriProgram?.request, model.siriRequest)
        XCTAssertTrue(first.plan.requirements.isEmpty); XCTAssertTrue(first.plan.observations.isEmpty); XCTAssertNil(first.plan.provenance["ui.runtimeManifestDigest"])
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
    func testControlledSiriRecordCheckFreezesOracleAndValidatesWithoutQualificationToken() async throws {
        let box = TargetBox()
        let model = try await model(executor: { candidate, approval, session in
            var value = try preparedPhysicalFixture(candidate, approval, session)
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
        XCTAssertEqual(preview.digest, actual.digest); XCTAssertEqual(preview.plan.execution.kind, .siriText)
        XCTAssertEqual(preview.plan.setup.count, 1); XCTAssertEqual(preview.plan.observations.count, 1)
        XCTAssertEqual(preview.plan.requirements.first?.expected, .bool(true)); XCTAssertEqual(preview.plan.setupChecks?.first?.expected, .bool(false))
        XCTAssertNoThrow(try PlanValidator.validate(actual.plan, approval: actual.approval, capabilities: actual.capabilities))
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
        let model = try await model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity }, reader: { box.read() },
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
    func testFolderGrantsRollbackInvalidSelectionsAndRetainExactScopes() async throws {
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
    func testFolderGrantLimitAndUnscopedReadableFolders() async throws {
        let primary = try folder(), ledger = SourceScopeLedger(), grants = ledger.grants()
        for _ in 0..<8 { try grants.add(folder(), primary: primary) }
        XCTAssertThrowsError(try grants.add(folder(), primary: primary)); XCTAssertEqual(ledger.started.count, 8)
        grants.clear(); XCTAssertEqual(ledger.stopped.count, 8)
        let unscoped = AutomationNativeSourceGrants(start: { _ in false }, stop: { _ in XCTFail("Ordinary readable URL has no scope to release") })
        try unscoped.add(folder(), primary: primary); unscoped.clear()
    }
    func testFolderReviewBindsExactGrantsAndRejectsABAAndPrimaryChanges() async throws {
        let box = TargetBox(), ledger = SourceScopeLedger()
        let model = try await model(executor: { _, _, _ in XCTFail("Stale folder review built"); throw AutomationContractError.invalidIdentity }, reader: { box.read() }, grants: ledger.grants())
        model.preparationDestination = .macOS
        let extra = try folder(), before = try model.reviewNativePreparation()
        try model.selectAdditionalSourceFolder(extra)
        XCTAssertThrowsError(try model.confirmNativePreparation(before))
        let review = try model.reviewNativePreparation()
        XCTAssertEqual(review.additionalSourceRoots, [extra.path]); XCTAssertTrue(review.message.contains(extra.path))
        model.removeAdditionalSourceFolder(extra); try model.selectAdditionalSourceFolder(extra)
        XCTAssertThrowsError(try model.confirmNativePreparation(review))
        model.select(URL(fileURLWithPath: try XCTUnwrap(model.candidate).containerPath)); await model.task?.value
        XCTAssertTrue(model.sourceGrants.urls.isEmpty); XCTAssertEqual(ledger.stopped, [extra, extra])
    }
    func testAdditionalFolderApprovalAndCloseHoldScopesUntilPreparationDrains() async throws {
        let box = TargetBox(), gate = PreparationGate(), ledger = SourceScopeLedger()
        let model = try await model(executor: { candidate, approval, session in
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
        let model = try await model(executor: { candidate, approval, session in
            var value = preparedFixture(candidate, approval, session)
            value.source = try AutomationSourceCaptureLayout.aggregate([value.source] + (approval.additionalSourceRoots ?? []).map {
                AutomationSourceManifest(sourceRoot: $0, files: [], directories: [], excludedPaths: [])
            })
            return value
        }, reader: { box.read() }, grants: ledger.grants())
        model.preparationDestination = .macOS
        let extra = try folder(); try model.selectAdditionalSourceFolder(extra)
        model.selectCandidate(); await model.task?.value; XCTAssertEqual(model.sourceGrants.urls, [extra])
        await model.prepareAndWait()
        XCTAssertEqual(model.prepared?.source.capturedRoots?.map(\.inputPath), [model.selectedSourceRoot!.path, extra.path])
        XCTAssertNotNil(model.catalog); XCTAssertTrue(ledger.stopped.isEmpty)
        model.removeAdditionalSourceFolder(extra)
        XCTAssertNil(model.prepared); XCTAssertNil(model.catalog); XCTAssertEqual(ledger.stopped, [extra])
        model.close(); XCTAssertEqual(ledger.stopped, [extra])
    }
    func testMacPreparationNeedsNoSimulatorAndEnablesOnlyReviewedSupportedRoutes() async throws {
        let box = TargetBox(), gate = PreparationGate()
        let model = try await model(executor: { candidate, approval, session in
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
        model.workflowRoute = "ui"
        XCTAssertTrue(model.canRun, "A matching prepared Mac source supports exact UI steps without a simulator")
        XCTAssertTrue(model.simulatorID.isEmpty)
        XCTAssertNil(model.pendingCommandStatus, "Preparation does not approve or queue execution")
        XCTAssertNil(model.report)
        model.workflowRoute = "system"
        XCTAssertNil(model.action, "This preparation fixture declares no system action")
        XCTAssertFalse(model.canRun)
        XCTAssertThrowsError(try model.previewCommand())
        model.workflowRoute = "fresh"
        XCTAssertTrue(model.isMacWorkflowUnavailable, "Mac fresh-record workflows remain unavailable")
        XCTAssertFalse(model.canRun)
        XCTAssertThrowsError(try model.previewCommand())
        model.workflowRoute = "ui"
        box.change()
        XCTAssertFalse(model.canRun, "A new login session cannot reuse the prepared target approval")
        XCTAssertThrowsError(try model.previewCommand())
        XCTAssertNil(model.pendingCommandStatus)
        XCTAssertNil(model.report)
    }
    func testReturnedPreparationCannotAddRootGrantsOrChangeTheApprovedPrimaryRoot() async throws {
        for extra in [false, true] {
            let box = TargetBox()
            let model = try await model(executor: { candidate, approval, session in
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
            let model = try await model(executor: { candidate, approval, session in
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
        let model = try await model(executor: { candidate, approval, session in
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
    func testUnavailableNativeSessionCannotPrepare() async throws {
        let model = try await model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity },
                              reader: { throw AutomationContractError.missingEvidence("No GUI session") })
        model.preparationDestination = .macOS
        XCTAssertFalse(model.canPrepare); XCTAssertNil(model.sourcePreparationTarget)
        model.prepare(); XCTAssertFalse(model.busy)
    }
    func testConfigurationChangeDuringInventoryStillPopulatesSimulatorSelection() async throws {
        let box = TargetBox(), gate = InventoryGate()
        let simulator = AutomationSimulator(id: UUID().uuidString, name: "Synthetic", runtime: "iOS", state: "Shutdown")
        let model = try await model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity }, reader: { box.read() },
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
            let model = try await model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity }, reader: { box.read() },
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
        let model = try await model(executor: { _, _, _ in throw AutomationContractError.invalidIdentity }, reader: { box.read() },
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
            let model = try await model(executor: { candidate, approval, session in
                await gate.suspend(approval); return preparedFixture(candidate, approval, session)
            }, reader: { box.read() })
            model.preparationDestination = .macOS
            let task = Task { await model.prepareAndWait() }; _ = await gate.waitForApproval()
            if close { model.close() } else { model.cancel() }
            await gate.release(); await task.value
            XCTAssertNil(model.prepared); XCTAssertNil(model.catalog); XCTAssertFalse(model.busy)
        }
    }
    func testNativePreparationReviewRejectsConfigurationDestinationSessionAndABADrift() async throws {
        for mutation in 0..<4 {
            let box = TargetBox()
            let model = try await model(executor: { _, _, _ in XCTFail("Stale preparation started"); throw AutomationContractError.invalidIdentity }, reader: { box.read() })
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
        let model = try await model(executor: { candidate, approval, session in
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
    func testNativePreparationExpectedTargetRejectsSessionDriftBeforeBuild() async throws {
        let box = TargetBox()
        let model = try await model(executor: { _, _, _ in XCTFail("Changed target built"); throw AutomationContractError.invalidIdentity }, reader: { box.read() })
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
private func preparedPhysicalFixture(_ candidate: AutomationApplicationCandidate, _ approval: AutomationBuildApproval,
                                     _ session: URL) throws -> AutomationPreparedApplication {
    var prepared = preparedFixture(candidate, approval, session)
    let subject = session.appendingPathComponent("Subject.app"), host = session.appendingPathComponent("Host-Runner.app")
    for (bundle, identifier) in [(subject, prepared.host.app.bundleID), (host, prepared.host.hostBundleID)] {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleExecutable": "App"],
            format: .binary, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        try Data("unit test product".utf8).write(to: bundle.appendingPathComponent("App"))
    }
    let sources = session.appendingPathComponent("generated-host/Host/Sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let templates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Integration/AutomationHost")
    var sourceDigests: [String: String] = [:]
    for file in AutomationHostGenerator.physicalTemplateFiles {
        let bytes = try Data(contentsOf: templates.appendingPathComponent(file))
        try bytes.write(to: sources.appendingPathComponent(file))
        sourceDigests[file] = AutomationArtifactRegistry.digest(bytes)
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let xctestrun = session.appendingPathComponent("host.xctestrun"), testBytes = Data("unit test xctestrun".utf8)
    try testBytes.write(to: xctestrun)
    prepared.generatedHost.scheme = "Host"; prepared.generatedHost.includesSiri = true
    prepared.generatedHost.templateDigest = AutomationArtifactRegistry.digest(try encoder.encode(sourceDigests))
    prepared.host.subjectProductPath = subject.path; prepared.host.hostBundlePath = host.path
    prepared.host.app.productDigest = try AutomationProductDigest.compute(bundle: subject)
    prepared.host.hostProductDigest = try AutomationProductDigest.compute(bundle: host)
    prepared.host.xctestrunPath = xctestrun.path; prepared.host.xctestrunDigest = AutomationArtifactRegistry.digest(testBytes)
    prepared.catalog.app = prepared.host.app
    prepared.buildLogPath = session.appendingPathComponent("build.log").path
    return prepared
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
