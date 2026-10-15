#if os(macOS)
import Foundation

@main struct ApplicationProbe {
    static func main() async {
        do {
            let succeeded = try await AutomationCLI.execute(Array(CommandLine.arguments.dropFirst()))
            if !succeeded { Foundation.exit(1) }
        } catch {
            AutomationCLI.writeError(error)
            Foundation.exit(1)
        }
    }
}
#else
@main struct ApplicationProbe { static func main() {} }
#endif
