import Foundation
import AppKit
import Darwin

@MainActor
public final class MacIntentRunner {
    private let command = MacIntentOwnedCommand()
    private var unresolvedHostBundleIDs: [String] = []
    private var unresolvedSubject: NSRunningApplication?
    private var running = false
    private var cancelled = false
    private var cancelInspection: (@Sendable () -> Void)?
    /// Creates a serial native runner that retains unresolved process ownership between runs.
    public init() {}

    /// Requests cancellation of the active run and owned command while allowing resource cleanup to finish.
    public func cancel() {
        cancelled = true
        cancelInspection?()
        command.cancel()
    }

    /// Generates, signs, and executes native App Intents tests against the selected installed build, retaining logs and result evidence.
    /// Requires an unchanged catalog/build identity, a stopped subject app, compatible Xcode, and matching signing team.
    /// Retains admission during off-actor inspection; only the explicitly launched subject is closed.
    /// Unresolved command/host resources prevent another run.
    /// - Returns: A verdict with evidence paths, selected product identity, and frozen authored cases. Execution/setup failures after evidence setup are captured in a failed result.
    /// - Throws: Early validation, setup, cancellation, or file errors before result capture is established.
    public func run(catalog: MacIntentCatalog, cases: [MacIntentTestCase],
                    configuration: MacIntentRunConfiguration) async throws -> MacIntentRunResult {
        guard !running else { throw MacIntentTestingError("A Mac intent test run is already active.") }
        guard command.confirmReleased(), generatedHostsReleased(), unresolvedSubject?.isTerminated != false else {
            throw MacIntentTestingError("An earlier test has unresolved command or generated test-host processes. Stop that test in Xcode and wait for its runners to exit before trying again.")
        }
        unresolvedSubject = nil
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
            throw MacIntentTestingError("Apple AppIntentsTesting execution requires macOS 27 or later.")
        }
        guard !configuration.signingIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              configuration.timeoutSeconds.isFinite, (1...3600).contains(configuration.timeoutSeconds) else {
            throw MacIntentTestingError("Choose a development team and signing identity, and a timeout from 1–3600 seconds.")
        }
        let xcodebuild = configuration.developerDirectory.appendingPathComponent("usr/bin/xcodebuild")
        let framework = configuration.developerDirectory.appendingPathComponent("Platforms/MacOSX.platform/Developer/Library/Frameworks/AppIntentsTesting.framework")
        guard FileManager.default.isExecutableFile(atPath: xcodebuild.path),
              FileManager.default.fileExists(atPath: framework.path) else {
            throw MacIntentTestingError("Choose an Xcode 27 developer directory containing the macOS AppIntentsTesting framework.")
        }
        guard let xcodegen = ["/opt/homebrew/bin/xcodegen", "/usr/local/bin/xcodegen"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw MacIntentTestingError("XcodeGen is required. Install it with brew install xcodegen.") }
        running = true; cancelled = false
        defer { running = false }
        let current = try await inspect { try MacIntentCatalog.load(appURL: catalog.appURL) }
        guard current.bundleIdentifier == catalog.bundleIdentifier, current.actions == catalog.actions,
              let identity = catalog.productIdentity, current.productIdentity == identity else {
            throw MacIntentTestingError("The selected app changed. Reload its intent catalog before testing.")
        }
        try Self.requireStoppedSubject(bundleIdentifier: current.bundleIdentifier)
        guard let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: current.bundleIdentifier),
              Self.sameApplicationPath(registered, current.appURL) else {
            throw MacIntentTestingError("The selected app must be installed and registered as the active Mac application for \(current.bundleIdentifier). Move this build to Applications, open it normally, and select that installed copy. Another registered copy may be taking precedence.")
        }
        try Task.checkCancellation()
        let source = try MacIntentSource.tests(catalog: current, cases: cases)
        let fm = FileManager.default
        let identifier = UUID().uuidString.lowercased()
        unresolvedHostBundleIDs = Self.generatedHostBundleIdentifiers(identifier)
        let directory = configuration.outputDirectory.appendingPathComponent("MacIntentRun-\(identifier)", isDirectory: true)
        try fm.createDirectory(at: directory.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appendingPathComponent("Host"), withIntermediateDirectories: true)
        try source.write(to: directory.appendingPathComponent("Tests/MacIntentTests.swift"), atomically: true, encoding: .utf8)
        try """
        import SwiftUI
        @main struct MacIntentHost: App {
            var body: some Scene { WindowGroup { Text("App Intents Test Runner") } }
        }
        """.write(to: directory.appendingPathComponent("Host/MacIntentHost.swift"), atomically: true, encoding: .utf8)
        try MacIntentSource.project(configuration: configuration, identifier: identifier)
            .write(to: directory.appendingPathComponent("project.json"))
        let logURL = directory.appendingPathComponent("run.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let resultURL = directory.appendingPathComponent("Tests.xcresult")
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = configuration.developerDirectory.path
        var launchedSubject: NSRunningApplication?
        var subjectLaunchDate: Date?
        var codeIdentity: MacIntentCodeIdentity?
        var subjectLifetime: MacIntentSubjectLifetime?
        defer { subjectLifetime?.stopObserving() }
        let result: MacIntentRunResult
        do {
            let signatureURL = directory.appendingPathComponent("subject-signature.log")
            fm.createFile(atPath: signatureURL.path, contents: nil)
            let signature = try FileHandle(forWritingTo: signatureURL)
            let signingStatus: Int32
            do {
                signingStatus = try await execute(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                                           arguments: ["--display", "--verbose=4", current.appURL.path], directory: directory,
                                           environment: environment, log: signature, timeout: 30)
                try signature.close()
            } catch { try? signature.close(); throw error }
            let signingData = try Data(contentsOf: signatureURL)
            log.write(signingData)
            guard signingStatus == 0, Self.signingTeam(in: String(decoding: signingData, as: UTF8.self)) == configuration.teamIdentifier else {
                throw MacIntentTestingError("The selected app must be signed by the same development team as the test runner (\(configuration.teamIdentifier)). Select that app's team and signing identity; the subject app is never re-signed.")
            }
            codeIdentity = try await inspect { try MacIntentCodeIdentity(appURL: current.appURL) }
            try await inspect { try identity.validate() }
            guard try await execute(executable: URL(fileURLWithPath: xcodegen),
                                    arguments: ["generate", "--spec", "project.json"], directory: directory,
                                    environment: environment, log: log, timeout: 60) == 0 else {
                throw MacIntentTestingError("The native test project could not be generated.")
            }
            try checkCancellation()
            try await inspect { try identity.validate() }
            try Self.requireStoppedSubject(bundleIdentifier: current.bundleIdentifier)
            let opening = NSWorkspace.OpenConfiguration()
            opening.activates = false
            opening.createsNewApplicationInstance = true
            let subject = try await NSWorkspace.shared.openApplication(at: current.appURL, configuration: opening)
            // The app was absent immediately before our explicit launch. Never
            // close or adopt an app that was already running with user work.
            launchedSubject = subject
            subjectLaunchDate = subject.launchDate
            try await validateSubject(subject, launchedAt: subjectLaunchDate, identity: identity, code: codeIdentity)
            guard let subjectLaunchDate else {
                throw MacIntentTestingError("The test app's launch identity could not be observed.")
            }
            let lifetime = MacIntentSubjectLifetime(processIdentifier: subject.processIdentifier, launchedAt: subjectLaunchDate)
            lifetime.startObserving(bundleIdentifier: current.bundleIdentifier)
            subjectLifetime = lifetime
            try checkCancellation()
            let status = try await executeBuild(executable: xcodebuild,
                                           arguments: MacIntentSource.xcodebuildArguments(project: directory.appendingPathComponent("MacIntentRun.xcodeproj"),
                                                                                          result: resultURL, derivedData: directory.appendingPathComponent("DerivedData")),
                                           directory: directory, environment: environment, log: log, timeout: configuration.timeoutSeconds)
            try checkCancellation()
            if !subject.isTerminated {
                try await validateSubject(subject, launchedAt: subjectLaunchDate, identity: identity, code: codeIdentity)
            }
            if status == 0 {
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
                try checkCancellation()
                await lifetime.deliverPendingObservations()
                try checkCancellation()
                try await lifetime.validateCompletion(
                    subjectTerminated: subject.isTerminated,
                    hasOtherRunningCopy: NSRunningApplication.runningApplications(withBundleIdentifier: current.bundleIdentifier)
                        .contains { !$0.isTerminated && $0.processIdentifier != subject.processIdentifier },
                    summary: Data(contentsOf: summaryURL), expectedCount: cases.count,
                    validateLiveSubject: {
                        try await self.validateSubject(subject, launchedAt: subjectLaunchDate, identity: identity, code: codeIdentity)
                    },
                    validateProduct: { try await self.inspect { try identity.validate() } }
                )
            }
            result = .init(succeeded: status == 0, resultBundleURL: fm.fileExists(atPath: resultURL.path) ? resultURL : nil,
                           logURL: logURL, summary: status == 0
                            ? "\(cases.count) native Mac intent test(s) passed. Cases without expected values verify execution only."
                            : "Native Mac intent testing failed (xcodebuild exit \(status)). Inspect the result bundle and run.log; compiled metadata does not guarantee runtime availability.",
                           productIdentity: identity, cases: cases)
        } catch {
            let message = cancelled || Task.isCancelled ? "Run cancelled." : error.localizedDescription
            log.write(Data(("\n" + message + "\n").utf8))
            result = .init(succeeded: false, resultBundleURL: fm.fileExists(atPath: resultURL.path) ? resultURL : nil,
                           logURL: logURL, summary: message + " See run.log.", productIdentity: identity, cases: cases)
        }
        if let launchedSubject { await close(launchedSubject) }
        if launchedSubject?.isTerminated == false { unresolvedSubject = launchedSubject }
        if !(await waitForGeneratedHosts()) || unresolvedSubject != nil || command.hasUnresolvedResources {
            return .init(succeeded: false, resultBundleURL: result.resultBundleURL, logURL: logURL,
                summary: "Test resources have not all exited. Finish the generated test in Xcode before starting another run.", productIdentity: identity, cases: cases)
        }
        discardBuildIntermediates(in: directory, log: log)
        do {
            if let subjectLifetime {
                try await subjectLifetime.finishObserving(
                    afterProductValidation: { try await self.inspect { try identity.validate() } },
                    hasOtherRunningCopy: {
                        NSRunningApplication.runningApplications(withBundleIdentifier: current.bundleIdentifier)
                            .contains { !$0.isTerminated }
                    }
                )
            } else {
                try await inspect { try identity.validate() }
            }
        }
        catch {
            let message = cancelled || Task.isCancelled || error is CancellationError
                ? "Run cancelled. See run.log." : error.localizedDescription
            return .init(succeeded: false, resultBundleURL: result.resultBundleURL, logURL: logURL,
                summary: message, productIdentity: identity, cases: cases)
        }
        return result
    }

    /// Compares application paths after standardization and symlink resolution.
    static func sameApplicationPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Extracts the first TeamIdentifier value from codesign diagnostic output.
    static func signingTeam(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
    }

    /// Throws when either the runner cancellation flag or the current task requests cancellation.
    private func checkCancellation() throws {
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
    private func close(_ app: NSRunningApplication) async {
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

    /// Rejects testing while any copy of the selected bundle identifier is running, preserving pre-existing app work.
    static func requireStoppedSubject(bundleIdentifier: String, isRunning: ((String) -> Bool)? = nil) throws {
        let present = isRunning?(bundleIdentifier) ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains { !$0.isTerminated }
        guard !present else {
            throw MacIntentTestingError("Quit the selected app before testing. An existing process may contain an older build or unsaved work; Intents will not restart it.")
        }
    }

    /// Checks the launched process timestamp, resolved bundle path, exclusive running copy, signed code identity, and unchanged bundle bytes.
    /// Checks process continuity around off-actor code and bundle inspection, observing cancellation before accepting evidence.
    private func validateSubject(_ app: NSRunningApplication, launchedAt: Date?, identity: MacIntentProductIdentity,
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
              app.bundleURL.map({ Self.sameApplicationPath($0, URL(fileURLWithPath: identity.bundlePath)) }) == true,
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
    private func waitForGeneratedHosts() async -> Bool {
        // Observe the complete settlement interval: a daemon may still be
        // completing a runner launch just after xcodebuild has exited.
        for _ in 0..<40 {
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
        }
        return generatedHostsReleased()
    }

    /// Lists the generated host, test bundle, and runner bundle identifiers associated with one run token.
    static func generatedHostBundleIdentifiers(_ identifier: String) -> [String] {
        let tests = "dev.intents.testing.tests.\(identifier)"
        return ["dev.intents.testing.host.\(identifier)", tests, tests + ".xctrunner", tests + "-Runner"]
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
    private func discardBuildIntermediates(in directory: URL, log: FileHandle) {
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

/// A final absence check cannot rule out a replacement that already exited.
/// Retain launch/termination observations for the complete execution interval.
@MainActor
final class MacIntentSubjectLifetime {
    struct ApplicationSnapshot: Sendable {
        let bundleIdentifier: String?
        let processIdentifier: Int32
        let launchedAt: Date?
    }

    private struct Observation: Sendable {
        var terminated = false
        var replaced = false
    }

    /// NotificationCenter invokes this adapter synchronously on the posting
    /// thread. The lock protects delivery from other threads and the cutoff.
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private let processIdentifier: Int32
        private let launchedAt: Date
        private var observation = Observation()
        private var sealed: Observation?

        /// Pins the observation ledger to the selected process identifier and launch timestamp.
        init(processIdentifier: Int32, launchedAt: Date) {
            self.processIdentifier = processIdentifier
            self.launchedAt = launchedAt
        }

        /// Records a process event under the ledger lock unless observation has already been sealed.
        func record(processIdentifier: Int32, launchedAt: Date?, terminated: Bool) {
            lock.withLock {
                recordUnlocked(processIdentifier: processIdentifier, launchedAt: launchedAt, terminated: terminated)
            }
        }

        /// Snapshots a matching bundle notification under the ledger lock and ignores unrelated or post-cutoff events.
        func record(_ notification: Notification, bundleIdentifier: String, terminated: Bool,
                    snapshot: @Sendable (Notification) -> ApplicationSnapshot?) {
            lock.withLock {
                guard sealed == nil, let app = snapshot(notification),
                      app.bundleIdentifier == bundleIdentifier else { return }
                recordUnlocked(processIdentifier: app.processIdentifier, launchedAt: app.launchedAt, terminated: terminated)
            }
        }

        /// Marks a different process/launch timestamp as replacement, or records termination of the selected lifetime.
        private func recordUnlocked(processIdentifier: Int32, launchedAt: Date?, terminated: Bool) {
            guard sealed == nil else { return }
            if processIdentifier != self.processIdentifier || launchedAt != self.launchedAt {
                observation.replaced = true
            } else if terminated {
                observation.terminated = true
            }
        }

        /// Returns the sealed observation when available, otherwise the current synchronized lifetime evidence.
        func snapshot() -> Observation { lock.withLock { sealed ?? observation } }
        /// Freezes and returns the current observation once so events after the local cutoff cannot change the verdict.
        func seal() -> Observation {
            lock.withLock {
                if sealed == nil { sealed = observation }
                return sealed!
            }
        }
    }

    private let ledger: Ledger
    private var observers: [NSObjectProtocol] = []
    private var observationCenter: NotificationCenter?

    /// Creates lifetime tracking tied to the explicitly launched subject process and its observed launch date.
    init(processIdentifier: Int32, launchedAt: Date) {
        ledger = Ledger(processIdentifier: processIdentifier, launchedAt: launchedAt)
    }

    /// Installs synchronous launch/termination observers for the subject bundle and records currently live copies.
    /// Optional notification and snapshot adapters support controlled observation sources.
    func startObserving(bundleIdentifier: String, center: NotificationCenter? = nil,
                        applicationSnapshot: (@Sendable (Notification) -> ApplicationSnapshot?)? = nil) {
        let center = center ?? NSWorkspace.shared.notificationCenter
        observationCenter = center
        let snapshot = applicationSnapshot ?? Self.applicationSnapshot
        let ledger = ledger
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { notification in
                ledger.record(notification, bundleIdentifier: bundleIdentifier,
                    terminated: name == NSWorkspace.didTerminateApplicationNotification, snapshot: snapshot)
            })
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) where !app.isTerminated {
            observeLaunch(processIdentifier: app.processIdentifier, launchedAt: app.launchDate)
        }
    }

    /// Copies bundle, process, and launch identity from the application carried by a workspace notification.
    nonisolated private static func applicationSnapshot(_ notification: Notification) -> ApplicationSnapshot? {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return nil }
        return .init(bundleIdentifier: app.bundleIdentifier, processIdentifier: app.processIdentifier, launchedAt: app.launchDate)
    }

    /// Removes installed notification observers and releases the observation center.
    func stopObserving() {
        for observer in observers { observationCenter?.removeObserver(observer) }
        observers.removeAll()
        observationCenter = nil
    }

    /// Records a launch identity so another process or launch timestamp invalidates subject continuity.
    func observeLaunch(processIdentifier: Int32, launchedAt: Date?) {
        ledger.record(processIdentifier: processIdentifier, launchedAt: launchedAt, terminated: false)
    }

    /// Records termination evidence for the selected process lifetime or detects a different lifetime.
    func observeTermination(processIdentifier: Int32, launchedAt: Date?) {
        ledger.record(processIdentifier: processIdentifier, launchedAt: launchedAt, terminated: true)
    }

    /// Rejects a report when accumulated notifications or current process state show another copy of the subject.
    func validateNoReplacement(hasOtherRunningCopy: Bool) throws {
        try Self.validateNoReplacement(ledger.snapshot(), hasOtherRunningCopy: hasOtherRunningCopy)
    }

    /// Throws if the supplied observation saw replacement or the final running-copy check found another subject.
    private static func validateNoReplacement(_ observation: Observation, hasOtherRunningCopy: Bool) throws {
        guard !observation.replaced, !hasOtherRunningCopy else {
            throw MacIntentTestingError("Another copy of the test app ran during this test. Its result cannot be bound to the selected process.")
        }
    }

    /// Yields through the main queue so already queued workspace events can contribute to completion evidence.
    func deliverPendingObservations() async {
        // isTerminated can update before the corresponding workspace event is
        // delivered. Give already queued events a delivery turn before reading
        // process state for the completion verdict; keep observing until cleanup.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Keeps observation active while the caller joins asynchronous product validation, then seals evidence and removes observers.
    /// Throws if hashing fails or accumulated/final state detects a replacement; the cutoff describes local delivery only.
    func finishObserving(afterProductValidation: @MainActor () async throws -> Void,
                         hasOtherRunningCopy: @escaping @MainActor @Sendable () -> Bool) async throws {
        // Keep the main run loop available to receive workspace events during
        // expensive hashing. Then drain already queued main-queue delivery and
        // seal a snapshot before removing observers. This is a local delivery
        // cutoff, not proof that no application can launch in the future.
        try await afterProductValidation()
        let final: (Observation, Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let final = (self.ledger.seal(), hasOtherRunningCopy())
                self.stopObserving()
                continuation.resume(returning: final)
            }
        }
        try Self.validateNoReplacement(final.0, hasOtherRunningCopy: final.1)
    }

    /// Validates authored-test counts, unchanged product, and subject continuity before accepting completion.
    /// A terminated subject needs its own observed termination; asynchronous inspections keep notification delivery available.
    func validateCompletion(subjectTerminated: Bool, hasOtherRunningCopy: Bool,
                            summary: Data, expectedCount: Int,
                            validateLiveSubject: () async throws -> Void,
                            validateProduct: () async throws -> Void) async throws {
        try MacIntentSummary.validate(summary, expectedCount: expectedCount)
        try validateNoReplacement(hasOtherRunningCopy: hasOtherRunningCopy)
        if subjectTerminated {
            guard ledger.snapshot().terminated else {
                throw MacIntentTestingError("The test app ended without an observed termination of its verified process. Native test success could not be bound to that process.")
            }
        }
        try await validateProduct()
        if !subjectTerminated {
            try await validateLiveSubject()
        }
        try validateNoReplacement(hasOtherRunningCopy: hasOtherRunningCopy)
    }
}
