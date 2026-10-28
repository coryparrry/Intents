import Foundation
import Dispatch
import Testing
@testable import MacIntentTesting

struct MacIntentProductIdentityTests {
    /// Keeps the main actor responsive while paused inspection joins either explicit runner or caller cancellation.
    @MainActor @Test(arguments: [true, false]) func offActorInspectionJoinsCancellation(cancelRunner: Bool) async throws {
        let (started, continuation) = AsyncStream<Void>.makeStream()
        var events = started.makeAsyncIterator()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); continuation.finish() }
        let runner = MacIntentRunner()
        let inspection = Task {
            try await runner.inspect {
                #expect(!Thread.isMainThread)
                continuation.yield(())
                guard release.wait(timeout: .now() + 5) == .success else {
                    throw MacIntentTestingError("The main actor did not release the paused inspection.")
                }
                try Task.checkCancellation()
            }
        }
        _ = await events.next()
        // Reaching this actor while inspection is paused is the UI heartbeat.
        if cancelRunner { runner.cancel() } else { inspection.cancel() }
        release.signal()
        await #expect(throws: CancellationError.self) { try await inspection.value }
    }

    /// Rejects cancelled bundle inspection before filesystem enumeration instead of treating it as a load failure.
    @Test func cancelledCaptureStopsBeforeReadingBundleBytes() async {
        let inspection = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MacIntentProductIdentity.capture(URL(fileURLWithPath: "/nonexistent-cancelled-fixture.app"))
        }
        await #expect(throws: CancellationError.self) { try await inspection.value }
    }

    @Test func publicDynamicCodeValidationRejectsADifferentExecutingBuild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["10"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let selected = try MacIntentCodeIdentity(appURL: URL(fileURLWithPath: "/bin/sleep"))
        try selected.validate(processIdentifier: child.processIdentifier)
        let different = try MacIntentCodeIdentity(appURL: URL(fileURLWithPath: "/bin/echo"))
        #expect(throws: MacIntentTestingError.self) { try different.validate(processIdentifier: child.processIdentifier) }
    }

    @Test func unchangedMetadataDoesNotHideExecutableOrResourceReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-intent-product-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("executable")
        let metadata = root.appendingPathComponent("extract.actionsdata")
        try Data("first build".utf8).write(to: executable)
        try Data("unchanged declarations".utf8).write(to: metadata)
        let selected = try MacIntentProductIdentity.capture(root)
        try selected.validate()
        try Data("fixed build".utf8).write(to: executable, options: .atomic)
        #expect(try MacIntentProductIdentity.capture(root) != selected)
        #expect(throws: MacIntentTestingError.self) { try selected.validate() }
        let fixed = try MacIntentProductIdentity.capture(root)
        try Data("new resource".utf8).write(to: root.appendingPathComponent("resource"))
        #expect(throws: MacIntentTestingError.self) { try fixed.validate() }
    }

    @Test func externalBundleLinksCannotSupplyUnfrozenCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-intent-link-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        #expect(throws: MacIntentTestingError.self) { try MacIntentProductIdentity.capture(root) }
    }
}
