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
    private(set) var result: MacIntentRunResult?
    private(set) var diagnostic: String?
    @ObservationIgnored private let runner = MacIntentRunner()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let runOverride: (@MainActor (MacIntentCatalog, [MacIntentTestCase], MacIntentRunConfiguration) async throws -> MacIntentRunResult)?
    @ObservationIgnored private var draftRevision = 0

    /// Creates a main-actor intent test session with an optional async runner override for controlled execution.
    init(runOverride: (@MainActor (MacIntentCatalog, [MacIntentTestCase], MacIntentRunConfiguration) async throws -> MacIntentRunResult)? = nil) {
        self.runOverride = runOverride
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

    /// Loads a compiled app's intent catalog while idle and selects its first action.
    /// Clears previous catalog/results first and publishes load or empty-catalog diagnostics.
    func load(appURL: URL) {
        guard !isRunning else { return }
        catalog = nil
        selectedActionID = ""
        result = nil
        diagnostic = nil
        do {
            let loaded = try MacIntentCatalog.load(appURL: appURL)
            catalog = loaded
            selectedActionID = loaded.actions.first?.id ?? ""
            if loaded.actions.isEmpty { diagnostic = "The compiled catalog contains no supported actions." }
        } catch { diagnostic = error.localizedDescription }
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
        guard !isRunning, let catalog else { return }
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

    /// Requests runner cancellation and waits for its retained task to finish before closing.
    func closeAndWait() async {
        cancel()
        await task?.value
    }

    /// Waits for the currently retained test-run task without requesting cancellation.
    func waitForRun() async { await task?.value }

    /// Requests cancellation of both the store task and underlying intent runner.
    func cancel() {
        task?.cancel()
        runner.cancel()
    }
}
