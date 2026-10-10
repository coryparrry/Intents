import Foundation
import IntentsAutomationCore
import IntentLabContracts
import Testing
@testable import FoundationEvals

struct ScenarioPhysicalLeaseTests {
    @Test func oldHarnessCanReleaseOnlyAfterIndependentAbsentRunnerInventory() async throws {
        try await withDirectory { root in
            let script = InspectionScript([true, true])
            let manager = try manager(root, script)
            let invocation = invocation()
            var record = try await manager.acquire(invocation: invocation, runner: runner(), workspace: root)
            try await manager.prepare(record)
            let other = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
            await #expect(throws: AutomationContractError.self) { try await other.acquire(runID: "other", target: record.lease.target, control: .ui) }
            record = try await manager.recordDispatch(record, invocation: invocation)
            record = try await manager.recordHost(record, process: absentHost(), executable: "/usr/bin/xcodebuild")
            #expect(record.receipt == nil)
            record = try await manager.finish(record, invocation: invocation, workspace: root)
            #expect(record.released && record.releaseObservation?.runnerAbsent == true)
            let available = try await other.acquire(runID: "other", target: record.lease.target, control: .ui)
            try await other.release(available, commandsDrained: true, ownedRunnerTerminated: true)
            try await other.releaseCampaign(runID: "other", target: record.lease.target)
        }
    }

    @Test func presentRunnerAndUndrainedHostRetainSharedExclusion() async throws {
        try await withDirectory { root in
            let script = InspectionScript([true, false, true])
            let manager = try manager(root, script), invocation = invocation()
            var record = try await manager.acquire(invocation: invocation, runner: runner(), workspace: root)
            try await manager.prepare(record)
            record = try await manager.recordDispatch(record, invocation: invocation)
            let unknown = record
            await #expect(throws: AutomationContractError.self) { try await manager.finish(unknown, invocation: invocation, workspace: root) }
            record = try await manager.recordHost(record, process: absentHost(), executable: "/usr/bin/xcodebuild")
            let held = record
            await #expect(throws: AutomationContractError.self) { try await manager.finish(held, invocation: invocation, workspace: root) }
            let other = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
            await #expect(throws: AutomationContractError.self) { try await other.acquire(runID: "other", target: held.lease.target, control: .ui) }
            let released = try await manager.finish(record, invocation: invocation, workspace: root)
            #expect(released.released)
        }
    }

    @Test func preparationFailureCanAbortWithoutLaunchingOrPermanentlyHoldingLease() async throws {
        try await withDirectory { root in
            let manager = try manager(root, InspectionScript([false])), invocation = invocation()
            let record = try await manager.acquire(invocation: invocation, runner: runner(), workspace: root)
            await #expect(throws: AutomationContractError.self) { try await manager.prepare(record) }
            let released = try await manager.finish(record, invocation: invocation, workspace: root)
            #expect(released.released && released.releaseObservation == nil && !released.dispatched)
            let other = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"))
            _ = try await other.acquire(runID: "other", target: record.lease.target, control: .ui)
        }
    }

    @Test func changedFrozenRunnerCannotClearCurrentLease() async throws {
        try await withDirectory { root in
            let manager = try manager(root, InspectionScript([true, true])), invocation = invocation()
            var record = try await manager.acquire(invocation: invocation, runner: runner(), workspace: root)
            try await manager.prepare(record)
            record = try await manager.recordDispatch(record, invocation: invocation)
            record = try await manager.recordHost(record, process: absentHost(), executable: "/usr/bin/xcodebuild")
            record.runnerProduct.executableName = "Foreign-Runner"
            let changed = record
            await #expect(throws: AutomationContractError.self) { try await manager.finish(changed, invocation: invocation, workspace: root) }
        }
    }

    @Test func provenPreventedHostLaunchCanReleaseButCannotHideRecordedLiveHost() async throws {
        try await withDirectory { root in
            let manager = try manager(root, InspectionScript([true, true])), invocation = invocation()
            var record = try await manager.acquire(invocation: invocation, runner: runner(), workspace: root)
            try await manager.prepare(record)
            record = try await manager.recordDispatch(record, invocation: invocation)
            record.hostLaunchPrevented = true
            #expect(try await manager.finish(record, invocation: invocation, workspace: root).released)

            let second = self.invocation()
            var live = try await manager.acquire(invocation: second, runner: runner(), workspace: root)
            live = try await manager.recordDispatch(live, invocation: second)
            live = try await manager.recordHost(live, process: .current(), executable: "/usr/bin/xcodebuild")
            live.hostProcess = nil; live.hostLaunchPrevented = true
            let forged = live
            await #expect(throws: AutomationContractError.self) { try await manager.finish(forged, invocation: second, workspace: root) }
        }
    }

    @Test func receiptImportIsAdditiveAndRejectsForeignDuplicateAliasedEvidence() async throws {
        try await withDirectory { root in
            let invocation = invocation(), product = runner()
            let manifest = root.appendingPathComponent("manifest.json")
            try Data("[]".utf8).write(to: manifest)
            #expect(try ScenarioRunnerReceiptImporter.load(directory: root, invocation: invocation, runner: product) == nil)
            let receipt = AutomationLegacyRunnerReceipt(invocationID: invocation.id, nonce: invocation.nonce,
                destinationIdentifier: invocation.destinationIdentifier, scenarioDigest: invocation.scenarioDigest,
                testBundleIdentifier: invocation.testProduct!.bundleIdentifier, testProductSHA256: invocation.testProduct!.sha256,
                processIdentifier: 42, kernelStartIdentity: "1791302400:123456", executableName: product.executableName)
            let file = root.appendingPathComponent("receipt.json")
            try JSONEncoder().encode(receipt).write(to: file)
            let item = ["suggestedHumanReadableName": "IntentLabRunnerReceipt-" + invocation.id.uuidString + ".json", "exportedFileName": "receipt.json"]
            func writeManifest(_ items: [[String: String]]) throws {
                try JSONSerialization.data(withJSONObject: [["testIdentifier": "IntentLabScenarioTests/testIntentLabScenario()", "attachments": items]]).write(to: manifest)
            }
            try writeManifest([item])
            #expect(try ScenarioRunnerReceiptImporter.load(directory: root, invocation: invocation, runner: product) == receipt)
            try writeManifest([item, item])
            #expect(throws: Error.self) { try ScenarioRunnerReceiptImporter.load(directory: root, invocation: invocation, runner: product) }
            try writeManifest([item])
            var foreign = receipt; foreign.nonce = "foreign"
            try JSONEncoder().encode(foreign).write(to: file)
            #expect(throws: Error.self) { try ScenarioRunnerReceiptImporter.load(directory: root, invocation: invocation, runner: product) }
            let alias = root.appendingPathComponent("alias.json")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
            var aliased = item; aliased["exportedFileName"] = "alias.json"
            try writeManifest([aliased])
            #expect(throws: Error.self) { try ScenarioRunnerReceiptImporter.load(directory: root, invocation: invocation, runner: product) }
        }
    }

    @Test func receiptImportEnforcesRootManifestFilenameSizeAndPermissionGuards() async throws {
        try await withDirectory { root in
            let invocation = invocation(), product = runner()
            let attachments = root.appendingPathComponent("Attachments")
            try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: false)
            let manifest = attachments.appendingPathComponent("manifest.json")
            let receipt = receipt(invocation, product)
            let encoded = try JSONEncoder().encode(receipt)
            func write(_ data: Data, to url: URL, mode: Int = 0o600) throws {
                try data.write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            }
            func writeManifest(_ filename: String, testIdentifier: String = "IntentLabScenarioTests/testIntentLabScenario()") throws {
                let item = ["suggestedHumanReadableName": "IntentLabRunnerReceipt-" + invocation.id.uuidString + ".json", "exportedFileName": filename]
                try write(JSONSerialization.data(withJSONObject: [["testIdentifier": testIdentifier, "attachments": [item]]]), to: manifest)
            }
            func load(_ directory: URL? = nil) throws -> AutomationLegacyRunnerReceipt? {
                try ScenarioRunnerReceiptImporter.load(directory: directory ?? attachments, invocation: invocation, runner: product)
            }

            #expect(throws: Error.self) { try load() }
            let file = attachments.appendingPathComponent("receipt.json")
            try write(encoded, to: file)
            try writeManifest("receipt.json")
            #expect(try load() == receipt)

            let link = root.appendingPathComponent("AttachmentsLink")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: attachments)
            #expect(throws: Error.self) { try load(link) }

            try writeManifest("receipt.json", testIdentifier: "OtherTests/testOther()")
            #expect(try load() == nil)

            try write(Data(#"{"testIdentifier":"IntentLabScenarioTests/testIntentLabScenario()","attachments":[]}"#.utf8), to: manifest)
            #expect(throws: Error.self) { try load() }
            try write(Data("[1]".utf8), to: manifest)
            #expect(throws: Error.self) { try load() }

            try write(encoded, to: root.appendingPathComponent("receipt.json"))
            try FileManager.default.createDirectory(at: attachments.appendingPathComponent("sub"), withIntermediateDirectories: false)
            try write(encoded, to: attachments.appendingPathComponent("sub/receipt.json"))
            try write(encoded, to: attachments.appendingPathComponent("receipt.txt"))
            for filename in ["../receipt.json", "sub/receipt.json", "receipt.txt", "receipt\0.json", "/receipt.json"] {
                try writeManifest(filename)
                #expect(throws: Error.self, "\(filename.debugDescription) must be rejected") { try load() }
            }

            try writeManifest("receipt.json")
            let maximumReceipt = encoded + Data(repeating: 0x20, count: 65_536 - encoded.count)
            try write(maximumReceipt, to: file)
            #expect(try load() == receipt)
            try write(maximumReceipt + Data(" ".utf8), to: file)
            #expect(throws: Error.self) { try load() }
            try write(encoded, to: file)

            let manifestData = try Data(contentsOf: manifest)
            let maximumManifest = manifestData + Data(repeating: 0x20, count: 2_097_152 - manifestData.count)
            try write(maximumManifest, to: manifest)
            #expect(try load() == receipt)
            try write(maximumManifest + Data(" ".utf8), to: manifest)
            #expect(throws: Error.self) { try load() }
            try write(manifestData, to: manifest)

            for mode in [0o664, 0o646, 0o622] {
                try write(encoded, to: file, mode: mode)
                #expect(throws: Error.self, "receipt mode \(String(mode, radix: 8)) must be rejected") { try load() }
                try write(encoded, to: file)
                try write(manifestData, to: manifest, mode: mode)
                #expect(throws: Error.self, "manifest mode \(String(mode, radix: 8)) must be rejected") { try load() }
                try write(manifestData, to: manifest)
            }
            try write(encoded, to: file, mode: 0o444)
            #expect(try load() == receipt)

            try FileManager.default.removeItem(at: file)
            #expect(mkfifo(file.path, 0o600) == 0)
            #expect(throws: Error.self) { try load() }
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: Error.self) { try load() }
        }
    }

    @Test func ownershipReceiptLoadReportsBoundedErrorInsteadOfThrowing() async throws {
        try await withDirectory { root in
            let invocation = invocation(), product = runner(), receipt = receipt(invocation, product)
            try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("receipt.json"))
            let item = ["suggestedHumanReadableName": "IntentLabRunnerReceipt-" + invocation.id.uuidString + ".json", "exportedFileName": "receipt.json"]
            let manifest = root.appendingPathComponent("manifest.json")
            try JSONSerialization.data(withJSONObject: [["testIdentifier": "IntentLabScenarioTests/testIntentLabScenario()", "attachments": [item]]]).write(to: manifest)

            let loaded = ScenarioRunnerReceiptImporter.loadForOwnership(directory: root, invocation: invocation, runner: product)
            #expect(loaded.receipt == receipt && loaded.error == nil)

            try Data("[]".utf8).write(to: manifest)
            let absent = ScenarioRunnerReceiptImporter.loadForOwnership(directory: root, invocation: invocation, runner: product)
            #expect(absent.receipt == nil && absent.error == nil)

            try JSONSerialization.data(withJSONObject: [["testIdentifier": "IntentLabScenarioTests/testIntentLabScenario()", "attachments": [item, item]]]).write(to: manifest)
            let rejected = ScenarioRunnerReceiptImporter.loadForOwnership(directory: root, invocation: invocation, runner: product)
            #expect(rejected.receipt == nil)
            let error = try #require(rejected.error)
            #expect(!error.isEmpty && error.count <= 2048)
        }
    }

    @Test func quickMacHostExitIsObservedEvenWhileJournalPersistenceAwaits() async throws {
        try await withDirectory { root in
            let persistence = ScenarioPersistence(rootDirectory: root)
            let executor = XcodeTestExecutor(workDirectory: root.appendingPathComponent("Executor"), persistence: persistence)
            let invocation = invocation()
            let journal = ScenarioExecutionJournal(phase: .running, invocation: invocation,
                scenarioID: UUID(), scenarioVersion: 1, resultBundlePath: root.appendingPathComponent("test.xcresult").path,
                derivedDataPath: root.path, buildLogPath: root.appendingPathComponent("host.log").path,
                intendedExecutable: "/usr/bin/true", intendedArguments: [], processIdentifier: nil,
                processStartedAt: nil, updatedAt: Date(), recoveryReason: nil)
            for _ in 0..<3 {
                let code = try await executor.runProcess(executable: "/usr/bin/true", arguments: [],
                    logURL: URL(fileURLWithPath: journal.buildLogPath), invocationID: invocation.id,
                    destinationIdentifier: invocation.destinationIdentifier, journal: journal,
                    appendLog: false, deadline: .seconds(2))
                #expect(code == 0)
            }
        }
    }

    func manager(_ root: URL, _ script: InspectionScript) throws -> ScenarioPhysicalRunnerLeaseManager {
        try .init(storeURL: root.appendingPathComponent("target-leases.json"), inspectorFactory: { _ in
            .init(inspect: { target, _, _, _, _ in await script.next(target.id) }, drain: { true })
        })
    }
    func receipt(_ invocation: ScenarioInvocationIdentity, _ product: ScenarioProductIdentity) -> AutomationLegacyRunnerReceipt {
        .init(invocationID: invocation.id, nonce: invocation.nonce,
              destinationIdentifier: invocation.destinationIdentifier, scenarioDigest: invocation.scenarioDigest,
              testBundleIdentifier: invocation.testProduct!.bundleIdentifier, testProductSHA256: invocation.testProduct!.sha256,
              processIdentifier: 42, kernelStartIdentity: "1791302400:123456", executableName: product.executableName)
    }
    func absentHost() -> AutomationProcessIdentity { .init(pid: 2_000_000_000, startIdentity: "prior-host:1") }
    func runner() -> ScenarioProductIdentity { .init(bundleIdentifier: "com.example.Tests.xctrunner", executableName: "Tests-Runner", sha256: String(repeating: "a", count: 64)) }
    func invocation() -> ScenarioInvocationIdentity {
        .init(id: UUID(), nonce: "random-nonce", issuedAt: Date(),
              testIdentity: .init(bundleIdentifier: "com.example.Tests", className: "IntentLabScenarioTests", methodName: "testIntentLabScenario"),
              harnessVersion: "intent-lab-v1", destinationIdentifier: "00008140-000E4D803C0B001C",
              scenarioDigest: String(repeating: "b", count: 64), resultBundleIdentity: "test.xcresult",
              appProduct: .init(bundleIdentifier: "com.example.App", executableName: "App", sha256: String(repeating: "c", count: 64)),
              testProduct: .init(bundleIdentifier: "com.example.Tests", executableName: "Tests", sha256: String(repeating: "d", count: 64)))
    }
    func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
}

actor InspectionScript {
    var values: [Bool]
    init(_ values: [Bool]) { self.values = values }
    func next(_ target: String) -> AutomationPhysicalRunnerVerifier.Observation {
        let absent = values.isEmpty ? false : values.removeFirst()
        return .init(targetID: target, deviceIdentifier: "1AD4F755-6F58-58E5-AC71-B1EDFECADA93", runnerAbsent: absent,
                     appsSHA256: String(repeating: "a", count: 64), processesSHA256: String(repeating: "b", count: 64))
    }
}
