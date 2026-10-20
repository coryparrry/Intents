import Darwin
import Foundation
import Testing
@testable import FoundationEvals

struct XcodeSyntheticReadinessTests {
    @Test(.timeLimit(.minutes(2)), arguments: [Duration.zero, .seconds(4)])
    func cancelledReadinessTestPersistsRecoveryAndBlocksReuse(launchDelay: Duration) async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IntentLabConnectionCancel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "child-input")
        let pidFile = root.appending(path: "child.pid")
        try #require(mkfifo(input.path, 0o600) == 0)
        // Keep a reader/writer open so cleanup can release even a late-starting child.
        let inputDescriptor = open(input.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        try #require(inputDescriptor >= 0)
        defer { close(inputDescriptor) }
        let persistence = ScenarioPersistence(rootDirectory: root)
        let executor = XcodeTestExecutor(
            workDirectory: root.appending(path: "Executor"), persistence: persistence,
            destinationStatusReader: { identifier, _ in
                #expect(identifier == "cancelled-readiness-device")
                return (true, "Synthetic local process", .macOS)
            }
        )
        let definition = try ScenarioDefinition.starter().frozen()
        let destination = "cancelled-readiness-device"
        var configuration = XcodeTestConfiguration(
            containerPath: root.path, isWorkspace: false, scheme: "Fixture",
            testTarget: "FixtureUITests", testBundleIdentifier: "dev.example.FixtureUITests",
            destinationIdentifier: destination, generatedResourceDirectory: root.path
        )
        configuration.xcodebuildPath = "/bin/sh"
        let testConfiguration = configuration
        let task = Task {
            // Exercise scheduling beyond the former three-second observation window.
            try await Task.sleep(for: launchDelay)
            return try await executor.runJournaledConnectionTest(
                definition: definition, configuration: testConfiguration,
                methodName: "testIntentLabReadiness", derivedData: root.appending(path: "DerivedData"),
                resultBundle: root.appending(path: "Readiness.xcresult"),
                // The shell announces launch, then blocks without a timer or descendants.
                arguments: ["-c", "printf '%s' \"$$\" > \"$1\"\nIFS= read -r ignored < \"$2\"",
                            "readiness-fixture", pidFile.path, input.path],
                logURL: root.appending(path: "readiness.log"), appendLog: false,
                deadline: .seconds(90)
            )
        }

        let verification: Result<Void, any Error>
        do {
            try await verifyCancellationRecovery(
                executor: executor, persistence: persistence, task: task,
                root: root, pidFile: pidFile, destination: destination
            )
            verification = .success(())
        } catch {
            verification = .failure(error)
        }
        // Join the operation on every assertion and error path before removing its files.
        task.cancel()
        _ = await executor.cancelConnectionCheck()
        #expect("\n".withCString { Darwin.write(inputDescriptor, $0, 1) } == 1)
        _ = await task.result
        if let pid = try? Int32(String(contentsOf: pidFile, encoding: .utf8)) {
            #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
        }
        try verification.get()
    }

    private func verifyCancellationRecovery(
        executor: XcodeTestExecutor, persistence: ScenarioPersistence, task: Task<Int32, any Error>,
        root: URL, pidFile: URL, destination: String
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if (try? Int32(String(contentsOf: pidFile, encoding: .utf8))) != nil,
               await executor.connectionDeviceTestIsRunning() { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard (try? Int32(String(contentsOf: pidFile, encoding: .utf8))) != nil,
              await executor.connectionDeviceTestIsRunning() else {
            Issue.record("The simulated readiness process did not launch.")
            return
        }
        let cancellation = await executor.cancelConnectionCheck()
        guard case .recoveryRequired(let cancelledJournal) = cancellation else {
            Issue.record("Cancelling a launched readiness test did not require recovery.")
            return
        }
        #expect(cancelledJournal.invocation.testIdentity.methodName == "testIntentLabReadiness")
        #expect(cancelledJournal.phase == .recoveryRequired)
        do {
            _ = try await task.value
            Issue.record("The cancelled readiness process unexpectedly succeeded.")
        } catch XcodeTestExecutorError.cancelled {
            // The launched probe remains quarantined even after its host exits.
        } catch {
            Issue.record("Unexpected readiness cancellation error: \(error)")
        }
        let saved = try await persistence.loadJournals()
        #expect(saved.contains { $0.id == cancelledJournal.id && $0.phase == .recoveryRequired })
        #expect(await executor.reservation(for: destination) != nil)

        let recovered = XcodeTestExecutor(
            workDirectory: root.appending(path: "Executor"), persistence: persistence
        )
        #expect(try await recovered.reconcileInterruptedJournals().contains {
            $0.id == cancelledJournal.id && $0.phase == .recoveryRequired
        })
        await #expect(throws: XcodeTestExecutorError.self) {
            try await recovered.clearQuarantine(
                destinationIdentifier: destination, fixtureReadinessProven: false
            )
        }
        try await recovered.clearQuarantine(
            destinationIdentifier: destination, fixtureReadinessProven: true
        )
        #expect(await recovered.reservation(for: destination) == nil)
    }

}
