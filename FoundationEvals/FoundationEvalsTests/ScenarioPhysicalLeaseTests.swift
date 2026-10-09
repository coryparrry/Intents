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
