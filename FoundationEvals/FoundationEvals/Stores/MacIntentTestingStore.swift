import Foundation
import MacIntentTesting
import Observation

@MainActor @Observable final class MacIntentTestingStore {
    private(set) var catalog: MacIntentCatalog?
    var selectedActionID = "" { didSet { if oldValue != selectedActionID { invalidateResult() } } }
    var inputsJSON = "{}" { didSet { if oldValue != inputsJSON { invalidateResult() } } }
    var checksExpectedValue = false { didSet { if oldValue != checksExpectedValue { invalidateResult() } } }
    var expectedValueJSON = "null" { didSet { if oldValue != expectedValueJSON { invalidateResult() } } }
    var developerDirectory = "/Applications/Xcode.app/Contents/Developer" { didSet { if oldValue != developerDirectory { invalidateResult() } } }
    var signingIdentity = "" { didSet { if oldValue != signingIdentity { invalidateResult() } } }
    var teamIdentifier = "" { didSet { if oldValue != teamIdentifier { invalidateResult() } } }
    private(set) var isRunning = false
    private(set) var isLoading = false
    private(set) var result: MacIntentRunResult?
    private(set) var diagnostic: String?
    @ObservationIgnored private let runner = MacIntentRunner()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var catalogLoadID: UUID?
    @ObservationIgnored private var isClosing = false
    @ObservationIgnored private let catalogLoader: @Sendable (URL) async throws -> MacIntentCatalog
    @ObservationIgnored private let runOverride: (@MainActor (MacIntentCatalog, [MacIntentTestCase], MacIntentRunConfiguration) async throws -> MacIntentRunResult)?
    @ObservationIgnored private var draftRevision = 0

    /// Creates an intent test session with injectable asynchronous execution and catalog loading for isolated checks.
    init(runOverride: (@MainActor (MacIntentCatalog, [MacIntentTestCase], MacIntentRunConfiguration) async throws -> MacIntentRunResult)? = nil,
         catalogLoader: @escaping @Sendable (URL) async throws -> MacIntentCatalog = { try await MacIntentCatalog.loadAsync(appURL: $0) }) {
        self.runOverride = runOverride
        self.catalogLoader = catalogLoader
    }

    /// Advances draft identity and clears result and diagnostic so edits cannot display an older successful result.
    private func invalidateResult() {
        draftRevision += 1
        result = nil
        diagnostic = nil
    }

    var selectedAction: MacIntentAction? {
        catalog?.actions.first { $0.id == selectedActionID }
    }

    /// Starts owned off-actor catalog loading, replacing an older selection only after its cancelled load has finished.
    /// Clears previous results immediately; only the current load may publish selection or diagnostics.
    func load(appURL: URL) {
        guard !isClosing, !isRunning else { return }
        let previous = loadTask
        previous?.cancel()
        let loadID = UUID()
        catalogLoadID = loadID
        isLoading = true
        catalog = nil
        selectedActionID = ""
        result = nil
        diagnostic = nil
        loadTask = Task {
            defer {
                if catalogLoadID == loadID {
                    isLoading = false
                    loadTask = nil
                }
            }
            await previous?.value
            do {
                try Task.checkCancellation()
                let loaded = try await catalogLoader(appURL)
                try Task.checkCancellation()
                guard catalogLoadID == loadID else { return }
                catalog = loaded
                selectedActionID = loaded.actions.first?.id ?? ""
                if loaded.actions.isEmpty { diagnostic = "The compiled catalog contains no supported actions." }
            } catch {
                guard catalogLoadID == loadID, !Task.isCancelled else { return }
                diagnostic = error.localizedDescription
            }
        }
    }

    /// Publishes a file-selection error unless it represents user cancellation.
    func reportSelectionError(_ error: any Error) {
        guard (error as NSError).code != NSUserCancelledError else { return }
        diagnostic = error.localizedDescription
    }

    /// Builds a test from the selected action and JSON object inputs, optionally validating an expected JSON value.
    /// Throws for missing actions or malformed inputs/expectations; disabling comparison leaves the expectation nil.
    func testCase() throws -> MacIntentTestCase {
        guard selectedAction != nil else { throw MacIntentTestingError("Choose an action from the compiled catalog.") }
        guard let data = inputsJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw MacIntentTestingError("Inputs must be a JSON object keyed by parameter identifier.")
        }
        if checksExpectedValue {
            guard let data = expectedValueJSON.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else {
                throw MacIntentTestingError("Expected value must be valid JSON. Disable the comparison for an execution-only smoke check.")
            }
        }
        return MacIntentTestCase(actionIdentifier: selectedActionID, inputsJSON: inputsJSON,
                                 expectedValueJSON: checksExpectedValue ? expectedValueJSON : nil)
    }

    /// Validates signing and test inputs, then launches a generated test-host run for the loaded catalog.
    /// Publishes results only if the draft revision still matches; validation/execution errors become diagnostics.
    func start() {
        guard !isClosing, !isRunning, !isLoading, let catalog else { return }
        result = nil
        diagnostic = nil
        do {
            let test = try testCase()
            guard developerDirectory.hasPrefix("/"), !signingIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MacIntentTestingError("Enter an absolute Xcode developer directory, signing identity and team identifier. The selected app and generated test host must support your signing setup.")
            }
            let output = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Intents/MacIntentTesting/Runs/\(UUID().uuidString)", directoryHint: .isDirectory)
            let configuration = MacIntentRunConfiguration(
                developerDirectory: URL(filePath: developerDirectory, directoryHint: .isDirectory),
                signingIdentity: signingIdentity, teamIdentifier: teamIdentifier, outputDirectory: output)
            let revision = draftRevision
            isRunning = true
            task = Task {
                defer { isRunning = false; task = nil }
                do {
                    let completed: MacIntentRunResult
                    if let runOverride { completed = try await runOverride(catalog, [test], configuration) }
                    else { completed = try await runner.run(catalog: catalog, cases: [test], configuration: configuration) }
                    if draftRevision == revision { result = completed }
                }
                catch { diagnostic = error.localizedDescription }
            }
        } catch { diagnostic = error.localizedDescription }
    }

    /// Closes admission, requests cancellation, and joins catalog loading and native execution before returning.
    func closeAndWait() async {
        isClosing = true
        let loading = loadTask
        let running = task
        cancel()
        await loading?.value
        await running?.value
    }

    /// Waits for the current catalog load, including any cancelled predecessor it owns.
    func waitForLoad() async { await loadTask?.value }

    /// Waits for the currently retained test-run task without requesting cancellation.
    func waitForRun() async { await task?.value }

    /// Requests cancellation of catalog inspection, the store execution task, and the underlying intent runner.
    func cancel() {
        loadTask?.cancel()
        task?.cancel()
        runner.cancel()
    }
}
