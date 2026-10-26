import Foundation
import Darwin
import MacIntentTesting

@main
struct NativeTestsMain {
    /// Runs help, catalog discovery, or native tests; emits structured JSON and preserves issued-case mappings before execution.
    /// Uses exit 1 for a failed/cancelled native attempt and exit 2 for invalid arguments or setup failures.
    @MainActor static func main() async {
        do {
            let options = try NativeTestsOptions(Array(CommandLine.arguments.dropFirst()))
            if options.command == .help { print(NativeTestsOptions.help); return }
            let catalog = try MacIntentCatalog.load(appURL: options.url("app"))
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
