#if os(macOS)
import Foundation
import IntentsAutomationCore

@main struct PreparationProbe {
    struct Profile: Decodable {
        var inputPath: String
        var approval: AutomationBuildApproval
        var sessionRoot: String
        var templates: String
        var developerDirectory: String
    }
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--profile" else { throw AutomationContractError.invalidIdentity }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            guard bytes.count <= 1_048_576 else { throw AutomationContractError.invalidIdentity }
            let profile = try JSONDecoder().decode(Profile.self, from: bytes)
            let intake = try AutomationApplicationIntake.assess(URL(fileURLWithPath: profile.inputPath))
            guard let candidate = intake.candidates.first(where: { $0.id == profile.approval.candidateID }) else { throw AutomationContractError.invalidIdentity }
            let value = try await AutomationPreparation().prepare(candidate: candidate, approval: profile.approval,
                sessionRoot: URL(fileURLWithPath: profile.sessionRoot), templates: URL(fileURLWithPath: profile.templates),
                developerDirectory: URL(fileURLWithPath: profile.developerDirectory))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try FileHandle.standardOutput.write(contentsOf: encoder.encode(value) + Data([10]))
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Preparation failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
#else
@main struct PreparationProbe { static func main() {} }
#endif
