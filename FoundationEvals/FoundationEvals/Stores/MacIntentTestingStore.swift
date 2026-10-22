import Foundation
import MacIntentTesting
import Observation

@MainActor @Observable final class MacIntentTestingStore {
    private(set) var catalog: MacIntentCatalog?
    var selectedActionID = ""
    var inputsJSON = "{}"
    var checksExpectedValue = false
    var expectedValueJSON = "null"
    var developerDirectory = "/Applications/Xcode.app/Contents/Developer"
    var signingIdentity = ""
    var teamIdentifier = ""
    private(set) var isRunning = false
    private(set) var result: MacIntentRunResult?
    private(set) var diagnostic: String?
    @ObservationIgnored private let runner = MacIntentRunner()
    @ObservationIgnored private var task: Task<Void, Never>?

    var selectedAction: MacIntentAction? {
        catalog?.actions.first { $0.id == selectedActionID }
    }

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

    func reportSelectionError(_ error: any Error) {
        guard (error as NSError).code != NSUserCancelledError else { return }
        diagnostic = error.localizedDescription
    }

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

    func start() {
        guard !isRunning, let catalog else { return }
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
            result = nil
            diagnostic = nil
            isRunning = true
            task = Task {
                defer { isRunning = false; task = nil }
                do { result = try await runner.run(catalog: catalog, cases: [test], configuration: configuration) }
                catch { diagnostic = error.localizedDescription }
            }
        } catch { diagnostic = error.localizedDescription }
    }

    func closeAndWait() async {
        cancel()
        await task?.value
    }

    func cancel() {
        task?.cancel()
        runner.cancel()
    }
}
