import Foundation
import Testing
@testable import FoundationEvals

struct XcodeSyntheticReadinessTests {
    @Test func cancelledReadinessTestPersistsRecoveryAndBlocksReuse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IntentLabConnectionCancel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        configuration.xcodebuildPath = "/bin/sleep"
        let testConfiguration = configuration
        let task = Task {
            try await executor.runJournaledConnectionTest(
                definition: definition, configuration: testConfiguration,
                methodName: "testIntentLabReadiness", derivedData: root.appending(path: "DerivedData"),
                resultBundle: root.appending(path: "Readiness.xcresult"), arguments: ["30"],
                logURL: root.appending(path: "readiness.log"), appendLog: false,
                deadline: .seconds(35)
            )
        }
        let deadline = Date().addingTimeInterval(3)
        while !(await executor.connectionDeviceTestIsRunning()), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await executor.connectionDeviceTestIsRunning() else {
            _ = await executor.cancelConnectionCheck()
            task.cancel()
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
