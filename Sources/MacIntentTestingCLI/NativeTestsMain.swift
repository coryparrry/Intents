import Foundation
import Dispatch
import Darwin
import MacIntentTesting

@main
struct NativeTestsMain {
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
            signal(SIGINT, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            interrupt.setEventHandler { Task { @MainActor in runner.cancel() } }
            interrupt.resume()
            defer { interrupt.cancel(); signal(SIGINT, SIG_DFL) }
            let result = try await runner.run(catalog: catalog, cases: cases, configuration: configuration)
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

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    private static func emit(_ value: some Encodable) throws {
        FileHandle.standardOutput.write(try encoder().encode(value) + Data("\n".utf8))
    }
}
