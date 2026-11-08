import AppKit
import Darwin
import Foundation

/// Preflights and runs the signed project, or imports results from an exported test.
@MainActor
public final class SiriStudioRunner {
    private let session: NativeTestSession

    /// Creates a runner with optional shared admission and cleanup tracking.
    public init(session: NativeTestSession = NativeTestSession()) { self.session = session }

    /// Cancels the active owned command without abandoning cleanup.
    public func cancel() { session.cancel() }

    /// Freezes the selected scenarios, runs the exact export, and persists local evidence even when blocked.
    public func run(document: SiriStudioDocument, catalog: MacIntentCatalog, configuration: MacIntentRunConfiguration,
                    scenarioIDs: Set<UUID>? = nil, allowance: Int? = nil, timeout: Double? = nil) async throws -> SiriStudioRunRecord {
        let launchArguments = try MacIntentRunConfiguration.validatedAppLaunchArguments(document.appLaunchArguments ?? configuration.appLaunchArguments)
        let scenarios = try SiriStudioSource.selection(in: document, scenarioIDs)
        let directory = configuration.outputDirectory
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try files.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw MacIntentTestingError("Choose an empty Siri Studio run directory.")
        }
        let logURL = directory.appendingPathComponent("run.log")
        files.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let startedAt = Date()
        let resultURL = directory.appendingPathComponent("Result.xcresult")
        let identifier = UUID()
        var build: String?
        var sourceURL: URL?
        var evidence = SiriStudioAttachments()
        var blocked: String?
        var cancelled: String?
        var admitted = false
        var launched: NSRunningApplication?
        var lifetime: MacIntentSubjectLifetime?
        var attemptedBuild = false
        defer {
            lifetime?.stopObserving()
            if admitted { session.end() }
        }
        do {
            let source = try SiriStudioSource.tests(document: document, catalog: catalog, scenarioIDs: scenarioIDs)
            let (allowance, timeout) = try SiriStudioSource.timeouts(for: scenarios, allowance: allowance, timeout: timeout)
            try session.begin()
            admitted = true
            var environment = Self.environment(for: configuration.developerDirectory)
            environment["TEST_RUNNER_INTENTS_SIRI_PROGRESS"] = directory.appendingPathComponent("progress.json").path
            let xcode = try await xcodeVersion(configuration.developerDirectory, in: directory, environment: environment, log: log)
            build = xcode.version
            try Self.requireSupportedOS(ProcessInfo.processInfo.operatingSystemVersion)
            guard !configuration.signingIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !configuration.teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MacIntentTestingError("Choose the development team and signing identity used for the selected app.")
            }
            let current = try await session.inspect { try MacIntentCatalog.load(appURL: catalog.appURL) }
            guard current.bundleIdentifier == catalog.bundleIdentifier, current.actions == catalog.actions,
                  let identity = catalog.productIdentity, current.productIdentity == identity else {
                throw MacIntentTestingError("The selected app changed. Reload its intent catalog before testing.")
            }
            try await session.verifySigningTeam(appURL: current.appURL, team: configuration.teamIdentifier,
                                                directory: directory, environment: environment, log: log)
            try MacIntentRunner.requireStoppedSubject(bundleIdentifier: current.bundleIdentifier)
            guard let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: current.bundleIdentifier),
                  MacIntentRunner.sameApplicationPath(installed, current.appURL) else {
                throw MacIntentTestingError("Install this build, open it once to register it, and quit it before running Siri Studio.")
            }
            let codeIdentity = try await session.inspect { try MacIntentCodeIdentity(appURL: current.appURL) }
            guard let xcodegen = ["/opt/homebrew/bin/xcodegen", "/usr/local/bin/xcodegen"].first(where: {
                files.isExecutableFile(atPath: $0)
            }) else { throw MacIntentTestingError("Install XcodeGen with brew install xcodegen.") }
            sourceURL = try SiriStudioSource.prepareProject(in: directory, source: source,
                                                           configuration: configuration, identifier: identifier)
            let generation = try await session.execute(executable: URL(fileURLWithPath: xcodegen),
                arguments: ["generate", "--spec", "project.json"], directory: directory, environment: environment,
                log: log, timeout: 60)
            guard generation == 0 else { throw MacIntentTestingError("The Siri Studio project could not be generated.") }
            try await session.inspect { try identity.validate() }
            try MacIntentRunner.requireStoppedSubject(bundleIdentifier: current.bundleIdentifier)
            let opening = NSWorkspace.OpenConfiguration()
            opening.activates = false
            opening.createsNewApplicationInstance = true
            opening.arguments = launchArguments
            let app = try await NSWorkspace.shared.openApplication(at: current.appURL, configuration: opening)
            launched = app
            guard let launchDate = app.launchDate else {
                throw MacIntentTestingError("The test app's launch identity could not be observed.")
            }
            let observation = MacIntentSubjectLifetime(processIdentifier: app.processIdentifier, launchedAt: launchDate)
            observation.startObserving(bundleIdentifier: current.bundleIdentifier)
            lifetime = observation
            try await session.validateSubject(app, launchedAt: launchDate, identity: identity, code: codeIdentity)
            let token = identifier.uuidString.lowercased()
            let tests = "dev.intents.siri.tests.\(token)"
            session.unresolvedHostBundleIDs = ["dev.intents.siri.host.\(token)", tests, tests + ".xctrunner", tests + "-Runner"]
            attemptedBuild = true
            let status = try await session.executeBuild(executable: xcode.executable,
                arguments: SiriStudioSource.arguments(in: directory, result: resultURL, allowance: allowance),
                directory: directory, environment: environment, log: log, timeout: timeout)
            try session.checkCancellation()
            guard files.fileExists(atPath: resultURL.path) else {
                throw MacIntentTestingError("xcodebuild did not produce a result bundle (exit \(status)). See run.log.")
            }
            guard status == 0 || status == 65 else {
                throw MacIntentTestingError("xcodebuild could not finish the Siri tests (exit \(status)). See run.log.")
            }
            let summary = try await session.readSummary(resultURL, directory: directory, environment: environment, log: log)
            try SiriStudioAttachments.verifyTests(Data(contentsOf: summary), expectedCount: scenarios.count)
            evidence = try await attachments(from: resultURL, in: directory, environment: environment, log: log)
            await observation.deliverPendingObservations()
            try await observation.validateSubjectContinuity(subjectTerminated: app.isTerminated,
                hasOtherRunningCopy: NSRunningApplication.runningApplications(withBundleIdentifier: current.bundleIdentifier)
                    .contains { !$0.isTerminated && $0.processIdentifier != app.processIdentifier },
                validateLiveSubject: {
                    try await self.session.validateSubject(app, launchedAt: launchDate, identity: identity, code: codeIdentity)
                }, validateProduct: { try await self.session.inspect { try identity.validate() } })
        } catch {
            let message = error.localizedDescription
            if error is CancellationError || (admitted && session.cancelled) || Task.isCancelled {
                cancelled = "Run cancelled."
            } else if attemptedBuild, (error as? NativeTestCommandTimeout)?.command == "xcodebuild" {
                cancelled = message
            } else { blocked = message }
            log.write(Data(("\n" + (cancelled ?? message) + "\n").utf8))
        }
        if let launched {
            await session.close(launched)
            if !launched.isTerminated { session.unresolvedSubject = launched }
        }
        if attemptedBuild {
            if await session.waitForGeneratedHosts(), !session.hasUnresolvedCommand, session.unresolvedSubject == nil {
                session.discardBuildIntermediates(in: directory, log: log)
            } else {
                blocked = "Test resources are still active. Stop the generated test in Xcode before starting another run."
            }
        }
        if let lifetime, let identity = catalog.productIdentity, blocked == nil, cancelled == nil {
            do {
                try await lifetime.finishObserving(
                    afterProductValidation: { try await self.session.inspect { try identity.validate() } },
                    hasOtherRunningCopy: {
                        NSRunningApplication.runningApplications(withBundleIdentifier: catalog.bundleIdentifier)
                            .contains { !$0.isTerminated }
                    })
            } catch { blocked = error.localizedDescription }
        }
        if admitted, session.cancelled || Task.isCancelled { cancelled = cancelled ?? "Run cancelled." }
        var record = SiriStudioRunRecord(document: document, productIdentity: catalog.productIdentity, xcodeBuild: build,
            osBuild: Self.osBuild(), startedAt: startedAt, endedAt: Date(), sourceURL: sourceURL,
            resultBundleURL: files.fileExists(atPath: resultURL.path) ? resultURL : nil, logURL: logURL,
            scenarios: scenarios.map {
                evidence.result(for: $0, bundleIdentifier: document.bundleIdentifier, blocked: blocked, cancelled: cancelled)
            })
        record.appLaunchArguments = launchArguments
        try record.write(to: directory)
        return record
    }

    /// Imports matching scenarios from an external result bundle without running Siri or requiring macOS 27.3.
    public func importResult(_ resultURL: URL, document: SiriStudioDocument, developerDirectory: URL,
                             outputDirectory: URL) async throws -> SiriStudioRunRecord {
        guard resultURL.pathExtension == "xcresult" else { throw MacIntentTestingError("Choose an .xcresult bundle.") }
        try session.begin()
        defer { session.end() }
        let files = FileManager.default
        try files.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let logURL = outputDirectory.appendingPathComponent("import.log")
        files.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let environment = Self.environment(for: developerDirectory)
        let evidence = try await attachments(from: resultURL, in: outputDirectory, environment: environment, log: log)
        let testOutput = outputDirectory.appendingPathComponent("test-tree.json")
        files.createFile(atPath: testOutput.path, contents: nil)
        let testTree = try FileHandle(forWritingTo: testOutput)
        defer { try? testTree.close() }
        let status = try await session.execute(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcresulttool", "get", "test-results", "tests", "--path", resultURL.path],
            directory: outputDirectory, environment: environment, log: log, timeout: 30, standardOutput: testTree)
        guard status == 0 else { throw MacIntentTestingError("Could not verify which Studio tests ran in this bundle.") }
        let tests = try SiriStudioAttachments.studioTests(Data(contentsOf: testOutput))
        let selected = document.scenarios.filter { tests[$0.id] != nil }
        guard !selected.isEmpty else { throw MacIntentTestingError("No generated Siri Studio tests match this document.") }
        let summary = try await session.readSummary(resultURL, directory: outputDirectory, environment: environment, log: log)
        let facts = try SiriStudioAttachments.runFacts(Data(contentsOf: summary))
        let record = SiriStudioRunRecord(document: document, productIdentity: nil, xcodeBuild: nil,
            osBuild: facts.osBuild, startedAt: facts.started, endedAt: facts.ended, sourceURL: nil, resultBundleURL: resultURL,
            logURL: logURL, scenarios: selected.map {
                evidence.result(for: $0, bundleIdentifier: document.bundleIdentifier, blocked: tests[$0.id] == true ? nil : "The Studio test did not execute exactly once.",
                                allowStale: true)
            })
        try record.write(to: outputDirectory)
        return record
    }

    /// Reads the chosen Xcode's version and checks its actual Mac developer framework.
    private func xcodeVersion(_ developer: URL, in directory: URL, environment: [String: String],
                              log: FileHandle) async throws -> (executable: URL, version: String) {
        let executable = developer.appendingPathComponent("usr/bin/xcodebuild")
        let framework = developer.appendingPathComponent("Platforms/MacOSX.platform/Developer/Library/Frameworks/SiriEvaluations.framework")
        let files = FileManager.default
        guard files.isExecutableFile(atPath: executable.path), files.fileExists(atPath: framework.path) else {
            throw MacIntentTestingError("Choose Xcode 27.3 or later with the macOS SiriEvaluations framework.")
        }
        let versionURL = directory.appendingPathComponent("xcode-version.txt")
        files.createFile(atPath: versionURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: versionURL)
        defer { try? output.close() }
        let status = try await session.execute(executable: executable, arguments: ["-version"], directory: directory,
                                              environment: environment, log: log, timeout: 30, standardOutput: output)
        let version = try String(contentsOf: versionURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, Self.supportedXcode(version) else {
            throw MacIntentTestingError("Siri Studio requires Xcode 27.3 or later. Found: \(version)")
        }
        return (executable, version)
    }

    /// Parses xcodebuild's numeric version rather than relying on the Xcode app's name.
    nonisolated static func supportedXcode(_ output: String) -> Bool {
        guard let first = output.split(whereSeparator: \.isNewline).first, first.hasPrefix("Xcode ") else { return false }
        let parts = first.dropFirst(6).split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0) }) else { return false }
        return major > 27 || (major == 27 && (parts.dropFirst().first.flatMap { Int($0) } ?? 0) >= 3)
    }

    /// Prevents any build attempt on a host that cannot run SiriEvaluations.
    nonisolated static func requireSupportedOS(_ os: OperatingSystemVersion) throws {
        guard os.majorVersion > 27 || (os.majorVersion == 27 && os.minorVersion >= 3) else {
            throw MacIntentTestingError("Siri evaluations require macOS 27.3 or later. This Mac runs \(os.majorVersion).\(os.minorVersion).")
        }
    }

    /// Exports only Studio JSON and passes the manifest to the portable attachment decoder.
    private func attachments(from result: URL, in directory: URL, environment: [String: String],
                             log: FileHandle) async throws -> SiriStudioAttachments {
        let output = directory.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let status = try await session.execute(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcresulttool", "export", "attachments", "--path", result.path, "--output-path", output.path,
                        "--filter", "siri-studio-*"],
            directory: directory, environment: environment, log: log, timeout: 60)
        guard status == 0 else { throw MacIntentTestingError("Could not export Siri Studio attachments from the result bundle.") }
        return try await session.inspect { try SiriStudioAttachments.load(from: output) }
    }

    /// Pins helper tools and xcodebuild to the same Xcode developer directory.
    private static func environment(for developer: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = developer.path
        return environment
    }

    /// Captures the host build number with the OS version for local evidence.
    private static func osBuild() -> String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}
