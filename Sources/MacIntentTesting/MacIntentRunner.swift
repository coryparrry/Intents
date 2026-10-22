import Foundation
import AppKit
import Darwin

@MainActor
public final class MacIntentRunner {
    private var process: Process?
    private var stopTask: Task<Void, Never>?
    private var running = false
    private var cancelled = false
    public init() {}

    public func cancel() {
        cancelled = true
        if let process { stop(process) }
    }

    public func run(catalog: MacIntentCatalog, cases: [MacIntentTestCase],
                    configuration: MacIntentRunConfiguration) async throws -> MacIntentRunResult {
        guard !running else { throw MacIntentTestingError("A Mac intent test run is already active.") }
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
        let current = try MacIntentCatalog.load(appURL: catalog.appURL)
        guard current.bundleIdentifier == catalog.bundleIdentifier, current.actions == catalog.actions else {
            throw MacIntentTestingError("The selected app changed. Reload its intent catalog before testing.")
        }
        guard let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: current.bundleIdentifier),
              Self.sameApplicationPath(registered, current.appURL) else {
            throw MacIntentTestingError("The selected app must be installed and registered as the active Mac application for \(current.bundleIdentifier). Move this build to Applications, open it normally, and select that installed copy. Another registered copy may be taking precedence.")
        }
        try Task.checkCancellation()
        let source = try MacIntentSource.tests(catalog: current, cases: cases)
        running = true; cancelled = false
        defer { running = false; process = nil; stopTask?.cancel(); stopTask = nil }
        let fm = FileManager.default
        let identifier = UUID().uuidString.lowercased()
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
            guard try await execute(executable: URL(fileURLWithPath: xcodegen),
                                    arguments: ["generate", "--spec", "project.json"], directory: directory,
                                    environment: environment, log: log, timeout: 60) == 0 else {
                throw MacIntentTestingError("The native test project could not be generated.")
            }
            try checkCancellation()
            let wasRunning = NSRunningApplication.runningApplications(withBundleIdentifier: current.bundleIdentifier)
                .contains { $0.bundleURL.map { Self.sameApplicationPath($0, current.appURL) } == true && !$0.isTerminated }
            let opening = NSWorkspace.OpenConfiguration()
            opening.activates = false
            let subject = try await NSWorkspace.shared.openApplication(at: current.appURL, configuration: opening)
            if !wasRunning { launchedSubject = subject }
            try checkCancellation()
            let status = try await executeBuild(executable: xcodebuild,
                                           arguments: MacIntentSource.xcodebuildArguments(project: directory.appendingPathComponent("MacIntentRun.xcodeproj"),
                                                                                          result: resultURL, derivedData: directory.appendingPathComponent("DerivedData")),
                                           directory: directory, environment: environment, log: log, timeout: configuration.timeoutSeconds)
            try checkCancellation()
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
                try MacIntentSummary.validate(Data(contentsOf: summaryURL), expectedCount: cases.count)
                try checkCancellation()
            }
            result = .init(succeeded: status == 0, resultBundleURL: fm.fileExists(atPath: resultURL.path) ? resultURL : nil,
                           logURL: logURL, summary: status == 0
                            ? "\(cases.count) native Mac intent test(s) passed. Cases without expected values verify execution only."
                            : "Native Mac intent testing failed (xcodebuild exit \(status)). Inspect the result bundle and run.log; compiled metadata does not guarantee runtime availability.")
        } catch {
            let message = cancelled || Task.isCancelled ? "Run cancelled." : error.localizedDescription
            log.write(Data(("\n" + message + "\n").utf8))
            result = .init(succeeded: false, resultBundleURL: fm.fileExists(atPath: resultURL.path) ? resultURL : nil,
                           logURL: logURL, summary: message + " See run.log.")
        }
        if let launchedSubject { await close(launchedSubject) }
        return result
    }

    static func sameApplicationPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func signingTeam(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
    }

    private func checkCancellation() throws {
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func close(_ app: NSRunningApplication) async {
        guard !app.isTerminated else { return }
        app.terminate()
        // Cleanup must also run for a cancelled caller.
        await Task.detached {
            try? await Task.sleep(for: .seconds(2))
        }.value
        if !app.isTerminated { app.forceTerminate() }
    }

    private func stop(_ child: Process) {
        guard child.isRunning, stopTask == nil else { return }
        child.interrupt()
        stopTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, child.isRunning else { return }
            child.terminate()
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, child.isRunning else { return }
            kill(child.processIdentifier, SIGKILL)
        }
    }

    /// Keep rebuildable products until the owned build process has ended; the
    /// generated project, log and result bundle remain available for inspection.
    func executeBuild(executable: URL, arguments: [String], directory: URL,
                      environment: [String: String], log: FileHandle, timeout: Double) async throws -> Int32 {
        defer {
            let derivedData = directory.appendingPathComponent("DerivedData", isDirectory: true)
            do {
                if FileManager.default.fileExists(atPath: derivedData.path) {
                    try FileManager.default.removeItem(at: derivedData)
                }
            } catch {
                log.write(Data("\nCould not remove temporary DerivedData: \(error.localizedDescription)\n".utf8))
            }
        }
        return try await execute(executable: executable, arguments: arguments, directory: directory,
                                 environment: environment, log: log, timeout: timeout)
    }

    func execute(executable: URL, arguments: [String], directory: URL,
                         environment: [String: String], log: FileHandle, timeout: Double,
                         standardOutput: FileHandle? = nil) async throws -> Int32 {
        try checkCancellation()
        let child = Process()
        child.executableURL = executable; child.arguments = arguments
        child.currentDirectoryURL = directory; child.environment = environment
        child.standardOutput = standardOutput ?? log; child.standardError = log
        process = child
        var timedOut = false
        let deadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, child.isRunning else { return }
            timedOut = true
            self.stop(child)
        }
        defer { deadline.cancel(); stopTask?.cancel(); stopTask = nil; process = nil }
        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                child.terminationHandler = { completed in continuation.resume(returning: completed.terminationStatus) }
                do { try child.run() }
                catch { child.terminationHandler = nil; continuation.resume(throwing: error) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
        if timedOut { throw MacIntentTestingError("\(executable.lastPathComponent) exceeded its \(Int(timeout))-second timeout and was stopped.") }
        return status
    }
}
