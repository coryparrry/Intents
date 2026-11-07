import AppKit
import Foundation

/// Shares admission, owned commands, and unresolved process tracking across native testing modes.
@MainActor
public final class NativeTestSession {
    private let command = MacIntentOwnedCommand()
    var unresolvedHostBundleIDs: [String] = []
    var unresolvedSubject: NSRunningApplication?
    private var running = false
    private(set) var cancelled = false
    private var cancelInspection: (@Sendable () -> Void)?
    /// Creates a serial native runner that retains unresolved process ownership between runs.
    public init() {}

    /// Requests cancellation of the active run and owned command while allowing resource cleanup to finish.
    public func cancel() {
        cancelled = true
        cancelInspection?()
        command.cancel()
    }

    /// Reserves execution until cleanup is complete and refuses unresolved resources from an earlier run.
    func begin() throws {
        guard !running else { throw MacIntentTestingError("A Mac intent test run is already active.") }
        guard command.confirmReleased(), generatedHostsReleased(), unresolvedSubject?.isTerminated != false else {
            throw MacIntentTestingError("An earlier test has unresolved command or generated test-host processes. Stop that test in Xcode and wait for its runners to exit before trying again.")
        }
        unresolvedSubject = nil
        running = true; cancelled = false
    }

    /// Releases admission; any unresolved processes are retained for the next attempt.
    func end() { running = false }

    var hasUnresolvedCommand: Bool { command.hasUnresolvedResources }

    /// Checks the compiled app's effective team without re-signing the app.
    func verifySigningTeam(appURL: URL, team: String, directory: URL,
                           environment: [String: String], log: FileHandle) async throws {
        let fm = FileManager.default
        let signatureURL = directory.appendingPathComponent("subject-signature.log")
        fm.createFile(atPath: signatureURL.path, contents: nil)
        let signature = try FileHandle(forWritingTo: signatureURL)
        let signingStatus: Int32
        do {
            signingStatus = try await execute(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                                       arguments: ["--display", "--verbose=4", appURL.path], directory: directory,
                                       environment: environment, log: signature, timeout: 30)
            try signature.close()
        } catch { try? signature.close(); throw error }
        let signingData = try Data(contentsOf: signatureURL)
        log.write(signingData)
        guard signingStatus == 0, MacIntentRunner.signingTeam(in: String(decoding: signingData, as: UTF8.self)) == team else {
            throw MacIntentTestingError("The selected app must be signed by the same development team as the test runner (\(team)). Select that app's team and signing identity; the subject app is never re-signed.")
        }
    }

    /// Exports the structured xcodebuild test summary and checks that the command succeeded.
    func readSummary(_ resultURL: URL, directory: URL, environment: [String: String], log: FileHandle) async throws -> URL {
        let fm = FileManager.default
        let summaryURL = directory.appendingPathComponent("test-summary.json")
        fm.createFile(atPath: summaryURL.path, contents: nil)
        let summary = try FileHandle(forWritingTo: summaryURL)
        let summaryStatus: Int32
        do {
            summaryStatus = try await execute(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                                              arguments: ["xcresulttool", "get", "test-results", "summary", "--path", resultURL.path],
                                              directory: directory, environment: environment, log: log,
                                              timeout: 30, standardOutput: summary)
            try summary.close()
        } catch { try? summary.close(); throw error }
        guard summaryStatus == 0 else {
            throw MacIntentTestingError("The result bundle summary could not be read (xcresulttool exit \(summaryStatus)). Native test success could not be verified.")
        }
        return summaryURL
    }

    /// Throws when either the runner cancellation flag or the current task requests cancellation.
    func checkCancellation() throws {
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// Retains and joins off-actor inspection so either explicit runner cancellation or caller cancellation stops scanning.
    func inspect<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try checkCancellation()
        let inspection = Task { try await MacIntentInspection.perform(operation) }
        cancelInspection = { inspection.cancel() }
        defer { cancelInspection = nil }
        let value = try await withTaskCancellationHandler {
            try await inspection.value
        } onCancel: {
            inspection.cancel()
        }
        try checkCancellation()
        return value
    }

    /// Requests termination of the subject launched by this run, then force-terminates after a grace interval if needed.
    /// Uses detached waits so caller cancellation does not skip cleanup.
    func close(_ app: NSRunningApplication) async {
        guard !app.isTerminated else { return }
        app.terminate()
        // Cleanup must also run for a cancelled caller.
        await Task.detached {
            try? await Task.sleep(for: .seconds(2))
        }.value
        if !app.isTerminated { app.forceTerminate() }
        if !app.isTerminated {
            await Task.detached { try? await Task.sleep(for: .milliseconds(250)) }.value
        }
    }

    /// Checks the launched process timestamp, resolved bundle path, exclusive running copy, signed code identity, and unchanged bundle bytes.
    /// Checks process continuity around off-actor code and bundle inspection, observing cancellation before accepting evidence.
    func validateSubject(_ app: NSRunningApplication, launchedAt: Date?, identity: MacIntentProductIdentity,
                                 code: MacIntentCodeIdentity?) async throws {
        try requireCurrentSubject(app, launchedAt: launchedAt, identity: identity, code: code)
        guard let code else { throw MacIntentTestingError("The selected app has no verified signed identity.") }
        let processIdentifier = app.processIdentifier
        try await inspect {
            try code.validate(processIdentifier: processIdentifier)
            try identity.validate()
        }
        try requireCurrentSubject(app, launchedAt: launchedAt, identity: identity, code: code)
    }

    /// Rejects ended, replaced, unverified, or competing subject processes without scanning bundle bytes.
    private func requireCurrentSubject(_ app: NSRunningApplication, launchedAt: Date?, identity: MacIntentProductIdentity,
                                       code: MacIntentCodeIdentity?) throws {
        guard !app.isTerminated, let launchedAt, app.launchDate == launchedAt,
              app.bundleURL.map({ MacIntentRunner.sameApplicationPath($0, URL(fileURLWithPath: identity.bundlePath)) }) == true,
              code != nil,
              NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier ?? "")
                .allSatisfy({ $0.isTerminated || $0.processIdentifier == app.processIdentifier }) else {
            throw MacIntentTestingError("The test app process changed or another copy started. Its result cannot be bound to the selected build.")
        }
    }

    /// Checks that every generated host/runner identifier has no live application and clears the retained list only after release.
    private func generatedHostsReleased() -> Bool {
        let released = unresolvedHostBundleIDs.allSatisfy { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).allSatisfy(\.isTerminated)
        }
        if released { unresolvedHostBundleIDs = [] }
        return released
    }

    /// Waits the full two-second host-settlement interval before checking release, including when the caller was cancelled.
    func waitForGeneratedHosts() async -> Bool {
        // Observe the complete settlement interval: a daemon may still be
        // completing a runner launch just after xcodebuild has exited.
        for _ in 0..<40 {
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
        }
        return generatedHostsReleased()
    }

    /// Keep rebuildable products until the owned build process has ended; the
    /// generated project, log and result bundle remain available for inspection.
    func executeBuild(executable: URL, arguments: [String], directory: URL,
                      environment: [String: String], log: FileHandle, timeout: Double) async throws -> Int32 {
        defer {
            // Native runs settle generated hosts after this command returns.
            // Standalone build commands have no generated host lifetime to await.
            if unresolvedHostBundleIDs.isEmpty && !command.hasUnresolvedResources {
                discardBuildIntermediates(in: directory, log: log)
            }
        }
        return try await execute(executable: executable, arguments: arguments, directory: directory,
                                 environment: environment, log: log, timeout: timeout)
    }

    /// Removes the run-local DerivedData directory and appends cleanup errors to the retained log.
    func discardBuildIntermediates(in directory: URL, log: FileHandle) {
        let derivedData = directory.appendingPathComponent("DerivedData", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: derivedData.path) {
                try FileManager.default.removeItem(at: derivedData)
            }
        } catch {
            log.write(Data("\nCould not remove temporary DerivedData: \(error.localizedDescription)\n".utf8))
        }
    }

    /// Checks runner/task cancellation and forwards the command to the owned-session executor.
    func execute(executable: URL, arguments: [String], directory: URL,
                         environment: [String: String], log: FileHandle, timeout: Double,
                         standardOutput: FileHandle? = nil) async throws -> Int32 {
        try checkCancellation()
        return try await command.execute(executable: executable, arguments: arguments, directory: directory,
            environment: environment, log: log, timeout: timeout, standardOutput: standardOutput)
    }
}
