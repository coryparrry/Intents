import Foundation
import IntentsAutomationCore
import IntentLabContracts
import Testing
@testable import FoundationEvals

struct ScenarioPhysicalFailureTests {
    private let fixture = ScenarioPhysicalLeaseTests()

    @Test func lateDiscoveryFailureCannotSkipThePhysicalFence() async throws {
        try await fixture.withDirectory { root in
            let initiallyPhysical = try XcodeTestExecutor.physicalLeaseRequired(ready: true, platform: .iOS, detail: "available")
            #expect(initiallyPhysical)
            let sentinel = root.appendingPathComponent("unfenced-launch")
            let executor = XcodeTestExecutor(workDirectory: root.appendingPathComponent("Executor"), persistence: ScenarioPersistence(rootDirectory: root))
            for platform: IntentLabDestinationPlatform? in [nil, .iOS] {
                await #expect(throws: XcodeTestExecutorError.self) {
                    if try XcodeTestExecutor.physicalLeaseRequired(ready: false, platform: platform, detail: "late discovery failed") {
                        let invocation = fixture.invocation()
                        var check = journal(root, invocation: invocation)
                        check.intendedExecutable = "/usr/bin/touch"; check.intendedArguments = [sentinel.path]
                        _ = try await executor.runPhysicalConnectionCommand(journal: check, runner: fixture.runner(), workspace: root, deadline: .seconds(2))
                    }
                }
            }
            #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        }
    }

    @Test func cancelDuringConnectionBuildPreventsPhysicalDispatch() async throws {
        try await fixture.withDirectory { root in
            let manager = try ScenarioPhysicalRunnerLeaseManager(storeURL: root.appendingPathComponent("leases.json"),
                inspectorFactory: { _ in .init(inspect: { target, _, _, _, _ in observation(target.id) }, drain: { true }) })
            let executor = XcodeTestExecutor(workDirectory: root.appendingPathComponent("Executor"), persistence: ScenarioPersistence(rootDirectory: root), physicalLeaseManager: manager)
            let started = root.appendingPathComponent("build-started"), host = root.appendingPathComponent("held-build")
            try Data("#!/bin/sh\ntrap 'exit 0' INT TERM\ntouch '\(started.path)'\nwhile :; do :; done\n".utf8).write(to: host)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.path)
            var invocation = fixture.invocation(); invocation.testIdentity.methodName = "testIntentLabConnection"
            var check = journal(root, invocation: invocation); check.phase = .preparing
            try await executor.beginPendingInvocation(check)
            let buildJournal = check, buildID = invocation.id, buildDestination = invocation.destinationIdentifier
            let build = Task { try await executor.runProcess(executable: host.path, arguments: ["build-for-testing"],
                logURL: URL(fileURLWithPath: buildJournal.buildLogPath), invocationID: buildID,
                destinationIdentifier: buildDestination, journal: buildJournal, appendLog: false, deadline: .seconds(10)) }
            let until = ContinuousClock.now.advanced(by: .seconds(2))
            while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
            #expect(FileManager.default.fileExists(atPath: started.path))
            #expect(await executor.cancelActiveExecution(grace: .zero)?.id == invocation.id)
            _ = try? await build.value
            let sentinel = root.appendingPathComponent("device-launch")
            check.intendedExecutable = "/usr/bin/touch"; check.intendedArguments = [sentinel.path]
            await #expect(throws: XcodeTestExecutorError.self) {
                try await executor.runPhysicalConnectionCommand(journal: check, runner: fixture.runner(), workspace: root, deadline: .seconds(2))
            }
            #expect(!FileManager.default.fileExists(atPath: sentinel.path))
            let other = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
            _ = try await other.acquire(runID: "new", target: .init(id: invocation.destinationIdentifier, kind: .physical), control: .system)
        }
    }

    @Test func connectionCheckRequiresIndependentRunnerAbsenceBeforeRelease() async throws {
        for runnerAbsent in [true, false] {
            try await fixture.withDirectory { root in
                let inspections = InspectionScript([true, runnerAbsent])
                let manager = try ScenarioPhysicalRunnerLeaseManager(storeURL: root.appendingPathComponent("leases.json"),
                    inspectorFactory: { _ in .init(inspect: { target, _, _, _, _ in await inspections.next(target.id) }, drain: { true }) })
                let persistence = ScenarioPersistence(rootDirectory: root)
                let executor = XcodeTestExecutor(workDirectory: root.appendingPathComponent("Executor"), persistence: persistence,
                    physicalLeaseManager: manager)
                var invocation = fixture.invocation(); invocation.testIdentity.methodName = "testIntentLabConnection"
                var check = journal(root, invocation: invocation)
                let host = root.appendingPathComponent("connection-host")
                try Data("#!/bin/sh\nsleep 0.1\nexit 0\n".utf8).write(to: host)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.path)
                check.phase = .preparing; check.intendedExecutable = host.path
                check.intendedArguments = ["test-without-building"]
                if runnerAbsent {
                    #expect(try await executor.runPhysicalConnectionCommand(journal: check, runner: fixture.runner(), workspace: root, deadline: .seconds(2)) == 0)
                } else {
                    await #expect(throws: AutomationContractError.self) {
                        try await executor.runPhysicalConnectionCommand(journal: check, runner: fixture.runner(), workspace: root, deadline: .seconds(2))
                    }
                }
                let saved = try #require(try await persistence.loadJournals().first)
                #expect(saved.physicalRunner?.released == runnerAbsent)
                #expect(saved.physicalRunner?.hostProcess != nil)
                #expect(saved.phase == (runnerAbsent ? .stopped : .recoveryRequired))
                let second = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
                if runnerAbsent {
                    _ = try await second.acquire(runID: "next", target: .init(id: invocation.destinationIdentifier, kind: .physical), control: .system)
                } else {
                    await #expect(throws: AutomationContractError.self) {
                        try await second.acquire(runID: "next", target: .init(id: invocation.destinationIdentifier, kind: .physical), control: .system)
                    }
                }
            }
        }
    }

    @Test func equalGenerationsOnDifferentTargetsNeverShareInspectorDrain() async throws {
        try await fixture.withDirectory { root in
            let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
            for path in [a, b] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
            let drain = InspectorDrainControl()
            let manager = try ScenarioPhysicalRunnerLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"), inspectorFactory: { workspace in
                .init(inspect: { target, _, _, _, _ in observation(target.id) }, drain: {
                    if workspace.lastPathComponent == "b" { return true }
                    return await drain.value()
                })
            })
            let first = fixture.invocation()
            var second = fixture.invocation(); second.destinationIdentifier = "second-physical-device"
            let held = try await manager.acquire(invocation: first, runner: fixture.runner(), workspace: a)
            await #expect(throws: AutomationContractError.self) { try await manager.acquire(invocation: second, runner: fixture.runner(), workspace: b) }
            await #expect(throws: AutomationContractError.self) { try await manager.finish(held, invocation: first, workspace: a) }
            await drain.enable()
            #expect(try await manager.finish(held, invocation: first, workspace: a).released)
            let healthy = try await manager.acquire(invocation: second, runner: fixture.runner(), workspace: b)
            #expect(held.lease.generation == healthy.lease.generation)
            await #expect(throws: AutomationContractError.self) { try await manager.finish(held, invocation: first, workspace: a) }
            #expect(try await manager.finish(healthy, invocation: second, workspace: b).released)
        }
    }

    @Test func cancelDuringHeldPhysicalPreparationPreventsHostLaunch() async throws {
        try await fixture.withDirectory { root in
            let gate = PreparationGate(), invocation = fixture.invocation()
            let manager = try ScenarioPhysicalRunnerLeaseManager(storeURL: root.appendingPathComponent("target-leases.json"), inspectorFactory: { _ in
                .init(inspect: { target, _, _, _, _ in await gate.hold(); return observation(target.id) }, drain: { true })
            })
            let record = try await manager.acquire(invocation: invocation, runner: fixture.runner(), workspace: root)
            let journal = journal(root, invocation: invocation, record: record)
            let executor = XcodeTestExecutor(workDirectory: root.appendingPathComponent("Executor"), persistence: ScenarioPersistence(rootDirectory: root))
            try await executor.beginPendingInvocation(journal)
            let preparation = Task { try await manager.prepare(record) }
            await gate.waitUntilEntered()
            #expect(await executor.cancelActiveExecution(grace: .zero)?.id == invocation.id)
            await gate.release(); try await preparation.value
            let sentinel = root.appendingPathComponent("must-not-launch")
            await #expect(throws: XcodeTestExecutorError.self) {
                try await executor.runProcess(executable: "/usr/bin/touch", arguments: [sentinel.path],
                    logURL: URL(fileURLWithPath: journal.buildLogPath), invocationID: invocation.id,
                    destinationIdentifier: invocation.destinationIdentifier, journal: journal, appendLog: false, deadline: .seconds(2))
            }
            #expect(!FileManager.default.fileExists(atPath: sentinel.path))
            #expect(try await manager.finish(record, invocation: invocation, workspace: root).released)
        }
    }

    @Test func hostIgnoringInterruptAndTerminateIsBoundedlyDrainedOnDeadline() async throws {
        try await hostileHost(persistenceFailure: false)
    }
    @Test func persistenceFailureDoesNotLoseTheOwnedHostHandle() async throws {
        try await hostileHost(persistenceFailure: true)
    }

    @Test func malformedOwnershipReceiptPreservesBusinessRunWithoutAcceptance() async throws {
        try await fixture.withDirectory { root in
            var definition = ScenarioDefinition.starter()
            definition.target.destinationIdentifier = fixture.invocation().destinationIdentifier
            definition = try definition.frozen()
            var invocation = fixture.invocation()
            invocation.scenarioDigest = definition.definitionDigest
            invocation.appProduct?.bundleIdentifier = definition.target.bundleIdentifier
            let manager = try fixture.manager(root, InspectionScript([true]))
            var record = try await manager.acquire(invocation: invocation, runner: fixture.runner(), workspace: root)
            let item = ["suggestedHumanReadableName": "IntentLabRunnerReceipt-" + invocation.id.uuidString, "exportedFileName": "ownership.json"]
            try JSONSerialization.data(withJSONObject: [["testIdentifier": "IntentLabScenarioTests/testIntentLabScenario()", "attachments": [item]]]).write(to: root.appendingPathComponent("manifest.json"))
            try Data("{broken".utf8).write(to: root.appendingPathComponent("ownership.json"))
            let ownership = ScenarioRunnerReceiptImporter.loadForOwnership(directory: root, invocation: invocation, runner: fixture.runner())
            #expect(ownership.receipt == nil && ownership.error != nil)
            record.receiptError = ownership.error
            var execution = journal(root, invocation: invocation, record: record)
            execution.scenarioID = definition.id; execution.scenarioVersion = definition.version; execution.phase = .stopped
            let envelope = businessEnvelope(definition, invocation: invocation)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var ledger = ScenarioImportLedger()
            let imported = try XCTestEvidenceImporter().importEvidence(data: encoder.encode(envelope), definition: definition,
                journal: execution, artifactRoot: root, ledger: &ledger)
            let persistence = ScenarioPersistence(rootDirectory: root.appendingPathComponent("results"))
            let saved = try await persistence.saveRun(imported, artifactRoot: root)
            let executor = XcodeTestExecutor(workDirectory: root.appendingPathComponent("Executor"), persistence: persistence)
            try await executor.finishEvidenceValidation(journal: execution, accepted: false)
            let loaded = try await persistence.loadRuns()
            #expect(loaded.count == 1 && loaded[0].id == saved.id && loaded[0].outcome == imported.outcome)
            #expect(loaded[0].acceptanceStatus == .pending)
            #expect(try await executor.currentRecoveryJournals().first?.physicalRunner?.receiptError != nil)
            await #expect(throws: ScenarioPersistenceError.self) { try await persistence.acceptRun(saved, journal: execution) }
        }
    }

    @Test func acceptedEvidenceKeepsAnUnreleasedPhysicalRunnerQuarantined() async throws {
        for receiptError in [nil, "unbound receipt"] as [String?] {
            try await fixture.withDirectory { root in
                let persistence = ScenarioPersistence(rootDirectory: root)
                let manager = try ScenarioPhysicalRunnerLeaseManager(storeURL: root.appendingPathComponent("leases.json"),
                    inspectorFactory: { _ in .init(inspect: { target, _, _, _, _ in observation(target.id) }, drain: { true }) })
                let invocation = fixture.invocation()
                var record = try await manager.acquire(invocation: invocation, runner: fixture.runner(), workspace: root)
                record.receiptError = receiptError
                let captured = journal(root, invocation: invocation, record: record)
                let executor = XcodeTestExecutor(workDirectory: root.appendingPathComponent("Executor"), persistence: persistence,
                    physicalLeaseManager: manager)
                try await executor.finishEvidenceValidation(journal: captured, accepted: true, deviceReady: true)
                let saved = try #require(try await executor.currentRecoveryJournals().first)
                #expect(saved.phase == .recoveryRequired)
                #expect(saved.evidenceAccepted == (receiptError == nil))
                #expect(saved.physicalRunner?.released == false)
                await #expect(throws: AutomationContractError.self) {
                    try await manager.acquire(invocation: invocation, runner: fixture.runner(), workspace: root)
                }
            }
        }
    }

    private func hostileHost(persistenceFailure: Bool) async throws {
        try await fixture.withDirectory { root in
            let invocation = fixture.invocation(), execution = journal(root, invocation: invocation)
            let storage = root.appendingPathComponent("storage")
            if persistenceFailure { try Data("not a directory".utf8).write(to: storage) }
            let executor = XcodeTestExecutor(workDirectory: root.appendingPathComponent("Executor"), persistence: ScenarioPersistence(rootDirectory: storage))
            let pidFile = root.appendingPathComponent("owned-host.pid")
            let script = "trap '' INT TERM; echo $$ > '" + pidFile.path + "'; exec /bin/sleep 30"
            await #expect(throws: Error.self) {
                try await executor.runProcess(executable: "/bin/sh", arguments: ["-c", script],
                    logURL: URL(fileURLWithPath: execution.buildLogPath), invocationID: invocation.id,
                    destinationIdentifier: invocation.destinationIdentifier, journal: execution,
                    appendLog: false, deadline: .seconds(1))
            }
            if !persistenceFailure { #expect(FileManager.default.fileExists(atPath: pidFile.path)) }
            #expect(await executor.cancelActiveExecution(grace: .zero) == nil)
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                #expect(AutomationProcessIdentity(pid: pid, startIdentity: "test-only").presence() == .absent)
            }
        }
    }
    @Test func delayedCancellationPublicationPreservesNewHostAndReleaseFacts() async throws {
        try await fixture.withDirectory { root in
            let persistence = ScenarioPersistence(rootDirectory: root), invocation = fixture.invocation()
            let manager = try ScenarioPhysicalRunnerLeaseManager(storeURL: root.appendingPathComponent("leases.json"),
                inspectorFactory: { _ in .init(inspect: { target, _, _, _, _ in observation(target.id) }, drain: { true }) })
            var record = try await manager.acquire(invocation: invocation, runner: fixture.runner(), workspace: root)
            record.dispatched = true
            let captured = journal(root, invocation: invocation, record: record)
            try await persistence.saveJournal(captured)
            let gate = PreparationGate()
            let publication = Task {
                await gate.hold()
                var cancellation = captured; cancellation.phase = .recoveryRequired
                return try await persistence.saveCancellationJournal(cancellation)
            }
            await gate.waitUntilEntered()
            var latest = captured
            record.hostProcess = try AutomationProcessIdentity.current()
            record.released = true; record.releaseObservation = observation(invocation.destinationIdentifier)
            latest.physicalRunner = record; latest.phase = .stopped
            try await persistence.saveJournal(latest)
            await gate.release()
            let published = try await publication.value
            #expect(published.physicalRunner == record)
            #expect(try await persistence.loadJournals().first?.physicalRunner == record)
            var conflicting = captured
            conflicting.physicalRunner?.lease.generation = 2
            await #expect(throws: ScenarioPersistenceError.self) { try await persistence.saveCancellationJournal(conflicting) }
        }
    }
    private func journal(_ root: URL, invocation: ScenarioInvocationIdentity, record: ScenarioPhysicalRunnerRecord? = nil) -> ScenarioExecutionJournal {
        .init(phase: .running, invocation: invocation, scenarioID: UUID(), scenarioVersion: 1,
              resultBundlePath: root.appendingPathComponent("test.xcresult").path, derivedDataPath: root.path,
              buildLogPath: root.appendingPathComponent("host.log").path, intendedExecutable: "/usr/bin/xcodebuild",
              intendedArguments: [], processIdentifier: nil, processStartedAt: nil, updatedAt: Date(), recoveryReason: nil, physicalRunner: record)
    }
    private func businessEnvelope(_ definition: ScenarioDefinition, invocation: ScenarioInvocationIdentity) -> ScenarioEvidenceEnvelope {
        let now = Date(), values = Dictionary(uniqueKeysWithValues: definition.assertions.compactMap { assertion in assertion.expectedValue.map { (assertion.observationKey, $0) } })
        let assertions = definition.assertions.map { ScenarioAssertionResult(assertionID: $0.id, passed: true, observedValue: $0.expectedValue, message: "fixture") }
        var lanes = [ScenarioLaneResult(caseID: definition.id, attempt: 1, lane: .intentIntegration, executionStatus: .completed,
            outcome: .passed, startedAt: now, completedAt: now, observations: values, assertionResults: assertions)]
        for attempt in 1...(definition.coverage.siriAttemptCount ?? 3) {
            lanes.append(.init(caseID: definition.id, attempt: attempt, lane: .siri, executionStatus: .completed,
                outcome: .passed, startedAt: now, completedAt: now, observations: values, assertionResults: assertions))
        }
        return .init(invocation: invocation, sourceBundleIdentifier: definition.target.bundleIdentifier,
            observedAppProduct: invocation.appProduct!, observedTestProduct: invocation.testProduct!,
            environment: .init(xcodeVersion: "27.0", sdkVersion: "27.0", deviceModel: "test fixture", operatingSystem: "iOS 27",
                operatingSystemBuild: "fixture", languageCode: "en-GB", regionCode: "GB", timeZoneIdentifier: "Europe/London",
                siriConfiguration: "enabled", siriConfigurationSource: .manuallySupplied, executedAt: now), testCount: 1, results: lanes)
    }
}

private func observation(_ target: String) -> AutomationPhysicalRunnerVerifier.Observation {
    .init(targetID: target, deviceIdentifier: "1AD4F755-6F58-58E5-AC71-B1EDFECADA93", runnerAbsent: true,
          appsSHA256: String(repeating: "a", count: 64), processesSHA256: String(repeating: "b", count: 64))
}

private actor PreparationGate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; for observer in observers { observer.resume() }; observers = []
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor InspectorDrainControl {
    private var ready = false
    func enable() { ready = true }
    func value() -> Bool { ready }
}
