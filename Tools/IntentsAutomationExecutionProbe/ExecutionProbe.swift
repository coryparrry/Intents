#if os(macOS)
import Foundation
import IntentsAutomationCore

/// Engineering entry point for the actual native coordinator. Profiles are explicit, never defaults.
@main struct ExecutionProbe {
    struct Profile: Decodable {
        var plan: AutomationCase
        var approval: RunApproval
        var capabilities: CapabilityProfile
        var attemptID: String
        var bundlePath: String
        var teamID: String
        var developerDirectory: String
        var stateDirectory: String
        var preparedAppleHost: AutomationPreparedAppleHost?
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--profile" else { throw AutomationContractError.invalidIdentity }
        let profileURL = URL(fileURLWithPath: CommandLine.arguments[2])
        guard let size = try profileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576 else { throw AutomationContractError.invalidIdentity }
        let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: profileURL))
        try PlanValidator.validate(profile.plan, approval: profile.approval, capabilities: profile.capabilities)
        let root = URL(fileURLWithPath: profile.stateDirectory, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw AutomationContractError.ambiguousDispatch }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let leases = try AutomationDeviceLeaseManager(storeURL: root.appendingPathComponent("leases.json"))
        let coordinator = AutomationCoordinator(leases: leases, journal: try AutomationJournal(url: root.appendingPathComponent("journal.json")))
        let artifacts = try AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts"))
        let verifier = AutomationInstalledSubjectVerifier(developerDirectory: URL(fileURLWithPath: profile.developerDirectory), workspace: root)
        let ui = try AutomationSidecarRouteDriver(bundleURL: URL(fileURLWithPath: profile.bundlePath), expectedTeamID: profile.teamID,
            stateDirectory: root.appendingPathComponent("ui"), approval: profile.approval, leases: leases, artifacts: artifacts, subjectVerifier: verifier, releaseVerifier: AutomationSimulatorReleaseVerifier(developerDirectory: URL(fileURLWithPath: profile.developerDirectory), workspace: root))
        let driver: any AutomationRouteDriver
        if let prepared = profile.preparedAppleHost {
            let apple = try AutomationAppleRouteDriver(prepared: prepared, approval: profile.approval,
                developerDirectory: URL(fileURLWithPath: profile.developerDirectory), stateDirectory: root.appendingPathComponent("apple"),
                leases: leases, artifacts: artifacts, subjectVerifier: verifier,
                releaseVerifier: AutomationSimulatorReleaseVerifier(developerDirectory: URL(fileURLWithPath: profile.developerDirectory), workspace: root))
            driver = AutomationCompositeRouteDriver(ui: ui, apple: apple)
        } else { driver = ui }
        let report = try await coordinator.run(plan: profile.plan, approval: profile.approval, capabilities: profile.capabilities,
            attemptID: profile.attemptID, driver: driver)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        try data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        if !report.resourcesReleased || !report.result.subjectCompleted { Foundation.exit(1) }
    }
}
#else
@main struct ExecutionProbe { static func main() { fatalError("Apple execution requires macOS") } }
#endif
