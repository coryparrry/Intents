import Foundation
import MacIntentTesting
import Observation

/// Owns one app's editable scenario document, frozen runs, and local persistence.
@MainActor @Observable final class SiriStudioStore {
    var document: SiriStudioDocument?
    var selection: UUID?
    var appLaunchArgumentsText = ""
    private(set) var run: SiriStudioRunRecord?
    private(set) var diagnostic: String?
    private(set) var isBusy = false
    private(set) var progress: SiriStudioProgress?
    private(set) var catalog: MacIntentCatalog?
    @ObservationIgnored private var saved: SiriStudioDocument?
    @ObservationIgnored private var needsSave = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let runner: SiriStudioRunner
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let telemetry: TelemetryController?

    /// Uses a shared native admission session and a private app support directory.
    init(session: NativeTestSession, telemetry: TelemetryController? = nil, root: URL? = nil) {
        runner = SiriStudioRunner(session: session)
        self.telemetry = telemetry
        self.root = root ?? URL.applicationSupportDirectory.appending(path: "Intents/SiriStudio", directoryHint: .isDirectory)
    }

    /// Parses one literal argument per line without shell splitting, expansion, or quoting rules.
    var appLaunchArguments: [String] {
        appLaunchArgumentsText.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    /// Explains invalid app arguments while leaving scenario authoring and export available.
    var launchArgumentsError: String? {
        do { _ = try MacIntentRunConfiguration.validatedAppLaunchArguments(appLaunchArguments); return nil }
        catch { return error.localizedDescription }
    }

    /// Gives immediate feedback using the same rules as CLI export and execution.
    var validationError: String? {
        guard let document, let catalog else { return "Choose a built macOS app." }
        do { try SiriStudioValidation.validate(document, catalog: catalog); return nil }
        catch { return error.localizedDescription }
    }

    /// Opens the saved document for the selected bundle, retaining a draft when only its build changes.
    func load(_ catalog: MacIntentCatalog?) {
        guard !isBusy else { return }
        let previousBundle = self.catalog?.bundleIdentifier
        self.catalog = catalog
        if previousBundle != catalog?.bundleIdentifier { appLaunchArgumentsText = "" }
        guard previousBundle != catalog?.bundleIdentifier || document == nil else { return }
        document = nil; saved = nil; needsSave = false; run = nil; diagnostic = nil; selection = nil
        guard let catalog else { return }
        do {
            let url = try documentURL(catalog.bundleIdentifier)
            let opened = FileManager.default.fileExists(atPath: url.path)
                ? try SiriStudioDocument.read(from: url) : SiriStudioDocument(bundleIdentifier: catalog.bundleIdentifier)
            guard opened.bundleIdentifier == catalog.bundleIdentifier else {
                throw MacIntentTestingError("The saved document belongs to a different app.")
            }
            adopt(opened)
        } catch { report(error) }
    }

    /// Persists edits while preserving unchanged bytes and incrementing each edited scenario once.
    func save() throws {
        guard var current = document else { return }
        current.appLaunchArguments = appLaunchArguments.isEmpty ? nil : appLaunchArguments
        if let saved { current.updateRevisions(from: saved) }
        let url = try documentURL(current.bundleIdentifier)
        guard needsSave || current != saved || !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try current.write(to: url)
        document = current; saved = current; needsSave = false; diagnostic = nil
    }

    /// Saves a copy of a document for the current app without replacing the selected source file.
    func openDocument(_ url: URL) throws {
        let opened = try SiriStudioDocument.read(from: url)
        guard opened.bundleIdentifier == catalog?.bundleIdentifier else {
            throw MacIntentTestingError("Choose a scenario document for the selected app.")
        }
        // Do not overwrite the saved scenario file until the user saves this copy.
        adopt(opened); needsSave = true; diagnostic = nil
    }

    /// Writes a shareable copy of the current document or the exact generated Swift.
    func export(_ url: URL, swift: Bool, all: Bool = false) throws {
        guard let catalog else { return }
        try save()
        guard let document else { return }
        if swift {
            try Data(SiriStudioSource.tests(document: document, catalog: catalog,
                scenarioIDs: all ? nil : selection.map { Set([$0]) }).utf8).write(to: url, options: .atomic)
        } else { try document.write(to: url) }
    }

    /// Reports a missing platform, Xcode installation, or signing input without locking authoring.
    func prerequisite(developer: String, team: String, identity: String) -> String? {
        if #unavailable(macOS 27.3) { return "Live Siri evaluations require macOS 27.3 or later. You can still author and export Swift." }
        let framework = URL(filePath: developer).appending(path: "Platforms/MacOSX.platform/Developer/Library/Frameworks/SiriEvaluations.framework")
        guard developer.hasPrefix("/"), FileManager.default.fileExists(atPath: framework.path) else {
            return "Choose an Xcode 27.3 or later developer directory in Xcode and signing."
        }
        guard !team.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter the app’s development team and signing identity."
        }
        return nil
    }

    /// Runs the selected snapshot using shared admission and records only fixed telemetry outcomes.
    func start(all: Bool, developer: String, team: String, identity: String, allowance: Int?) {
        guard !isBusy, let catalog, all || selection != nil else { return }
        do {
            try save()
            guard let document else { return }
            let configuration = MacIntentRunConfiguration(developerDirectory: URL(filePath: developer),
                signingIdentity: identity, teamIdentifier: team, outputDirectory: newRunDirectory(),
                appLaunchArguments: try MacIntentRunConfiguration.validatedAppLaunchArguments(appLaunchArguments))
            let selection = all ? nil : self.selection.map { Set([$0]) }
            let span = telemetry?.begin(.siriStudioRun)
            begin {
                var failure: TelemetryFailure?
                defer { self.telemetry?.end(span, failure: failure) }
                let progress = Task { await self.trackProgress(in: configuration.outputDirectory) }
                defer { progress.cancel() }
                do {
                    let record = try await self.runner.run(document: document, catalog: catalog,
                        configuration: configuration, scenarioIDs: selection, allowance: allowance)
                    self.run = record
                    failure = switch record.state {
                    case .passed: nil
                    case .cancelled: .cancelled
                    case .blocked: .deviceUnavailable
                    case .failed, .incomplete: .testFailure
                    }
                } catch {
                    failure = Task.isCancelled ? .cancelled : .storage
                    self.report(error)
                }
            }
        } catch { report(error) }
    }

    /// Imports a developer's result bundle with the current saved scenario identity.
    func importResult(_ url: URL, developer: String) {
        guard !isBusy, let document else { return }
        begin {
            self.run = try await self.runner.importResult(url, document: document, developerDirectory: URL(filePath: developer),
                                                          outputDirectory: self.newRunDirectory())
        }
    }

    /// Reopens a persisted run without contacting Xcode or Siri.
    func openRun(_ directory: URL) throws {
        let opened = try SiriStudioRunRecord.read(from: directory)
        guard opened.document.bundleIdentifier == catalog?.bundleIdentifier else {
            throw MacIntentTestingError("This run belongs to a different app.")
        }
        run = opened; selection = opened.scenarios.first?.id ?? selection; diagnostic = nil
    }

    /// Keeps authored expectations tied to the revision that actually ran.
    func isStale(_ result: SiriStudioScenarioResult) -> Bool {
        let frozen = run?.document.scenarios.first { $0.id == result.id }
        let current = document?.scenarios.first { $0.id == result.id }
        let argumentsChanged = run?.appLaunchArguments.map { $0 != appLaunchArguments } ?? false
        return argumentsChanged || current?.revision != result.revision || frozen != current
    }

    /// Displays a local diagnostic without sending it to telemetry.
    func report(_ error: any Error) { diagnostic = error.localizedDescription }

    /// Cancels only Studio's own task and waits for its native cleanup before closing.
    func closeAndWait() async {
        cancel()
        await task?.value
    }

    /// Requests cancellation only when this store owns an operation.
    func cancel() {
        guard let task else { return }
        task.cancel()
        // The task's cancellation reaches the owned command without cancelling the other mode.
    }

    /// Adopts an on-disk document as the saved revision baseline.
    private func adopt(_ document: SiriStudioDocument) {
        self.document = document; saved = document; selection = document.scenarios.first?.id
        appLaunchArgumentsText = document.appLaunchArguments?.joined(separator: "\n") ?? ""
    }

    /// Reserves store admission before creating the cancellable asynchronous operation.
    private func begin(_ operation: @escaping @MainActor () async throws -> Void) {
        isBusy = true; diagnostic = nil; progress = nil
        task = Task {
            defer { isBusy = false; task = nil; progress = nil }
            do { try await operation() }
            catch { report(error) }
        }
    }

    /// Reads local, content-free progress snapshots written by the test runner.
    private func trackProgress(in directory: URL) async {
        while !Task.isCancelled {
            if let current = try? SiriStudioProgress.read(from: directory) { progress = current }
            do { try await Task.sleep(for: .milliseconds(450)) }
            catch { return }
        }
    }

    /// Places documents only at a bundle-identifier filename within the local scenario directory.
    private func documentURL(_ bundle: String) throws -> URL {
        guard !bundle.isEmpty, bundle.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }) else { throw MacIntentTestingError("This bundle identifier cannot be used as a local scenario filename.") }
        return root.appending(path: "Scenarios/\(bundle).json")
    }

    /// Allocates a unique path so a run or import cannot overwrite earlier evidence.
    private func newRunDirectory() -> URL { root.appending(path: "Runs/\(UUID().uuidString)", directoryHint: .isDirectory) }
}
