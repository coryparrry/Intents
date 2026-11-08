import Foundation
import Darwin
import MacIntentTesting

@main
struct NativeTestsMain {
    /// Runs help, off-actor catalog discovery, or native tests; preserves issued-case mappings and emits structured JSON.
    /// Uses exit 1 for a failed/cancelled native attempt and exit 2 for invalid arguments or setup failures.
    @MainActor static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "siri" {
                try await siri(Array(arguments.dropFirst()))
                return
            }
            let options = try NativeTestsOptions(arguments)
            if options.command == .help { print(NativeTestsOptions.help); return }
            let catalog = try await MacIntentCatalog.loadAsync(appURL: options.url("app"))
            if options.command == .catalog { try emit(catalog); return }
            let cases = try NativeTestsManifest.load(options.url("cases"))
            let issued = cases.map(NativeTestsIssuedCase.init)
            let configuration = options.configuration
            try FileManager.default.createDirectory(at: configuration.outputDirectory, withIntermediateDirectories: true)
            let mapping = configuration.outputDirectory.appendingPathComponent("issued-cases-\(UUID().uuidString).json")
            try encoder().encode(issued).write(to: mapping, options: [.atomic])
            let runner = MacIntentRunner()
            let result = try await NativeTestsSignals.whileRunning(cancel: { runner.cancel() }) {
                try await runner.run(catalog: catalog, cases: cases, configuration: configuration)
            }
            try emit(NativeTestsRunOutput(result: result, caseManifestURL: mapping, cases: issued))
            if !result.succeeded {
                // A result bundle records a native execution attempt. Earlier
                // project/signing/launch failures are setup failures.
                exit(result.resultBundleURL != nil || result.summary.hasPrefix("Run cancelled.") ? 1 : 2)
            }
        } catch {
            let output = ["error": error.localizedDescription]
            if let data = try? encoder().encode(output) {
                FileHandle.standardError.write(data + Data("\n".utf8))
            }
            exit(2)
        }
    }

    /// Validates, exports, runs, or reopens a Siri Studio scenario document.
    @MainActor private static func siri(_ arguments: [String]) async throws {
        if arguments.isEmpty || arguments.contains("--help") { print(SiriStudioOptions.help); return }
        let options = try SiriStudioOptions(arguments)
        if options.command == .show {
            let record = try SiriStudioRunRecord.read(from: options.url("run"))
            try emit(SiriStudioCLIOutput(record))
            if record.state != .passed { exit(1) }
            return
        }
        let document = try SiriStudioDocument.read(from: options.url("scenarios"))
        let catalog = try await MacIntentCatalog.loadAsync(appURL: options.url("app"))
        switch options.command {
        case .validate:
            try SiriStudioValidation.validate(document, catalog: catalog)
            try emit(["scenarios": document.scenarios.count])
        case .export:
            let source = try SiriStudioSource.tests(document: document, catalog: catalog,
                scenarioIDs: options.scenarioIDs.isEmpty ? nil : options.scenarioIDs)
            try Data(source.utf8).write(to: options.url("output"), options: .atomic)
        case .run:
            let runner = SiriStudioRunner()
            let record = try await NativeTestsSignals.whileRunning(cancel: { runner.cancel() }) {
                try await runner.run(document: document, catalog: catalog, configuration: options.configuration,
                                     scenarioIDs: options.scenarioIDs.isEmpty ? nil : options.scenarioIDs,
                                     allowance: options.allowance, timeout: options.timeout)
            }
            try emit(SiriStudioCLIOutput(record))
            if record.state != .passed { exit(1) }
        case .show: break
        }
    }

    /// Creates the pretty, sorted-key JSON encoder shared by CLI output and issued-case evidence.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    /// Writes one JSON value followed by a newline to standard output and propagates encoding failures.
    private static func emit(_ value: some Encodable) throws {
        FileHandle.standardOutput.write(try encoder().encode(value) + Data("\n".utf8))
    }
}
