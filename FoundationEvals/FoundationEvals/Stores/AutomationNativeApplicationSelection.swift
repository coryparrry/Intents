#if os(macOS)
import Foundation
import IntentsAutomationCore

struct AutomationNativeApplicationListing: Codable, Equatable, Sendable {
    struct Application: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let kind: AutomationApplicationCandidate.Kind
        let bundleID: String?
        let platform: String?
        let configurations: [String]
    }
    let applications: [Application]
    let snapshotDigest: String
    let selectedID: String?
    let total: Int
    let truncated: Bool
}
extension AppAutomationStore {
    var isInstalledMacUI: Bool { candidate?.kind == .installedProduct && candidate?.app?.platform == "macos" }
    var isMacWorkflowUnavailable: Bool {
        isInstalledMacUI || (candidate?.kind == .sourceTarget && preparationDestination == .macOS)
    }

    /// Only the population already admitted through the native file picker is visible.
    /// A remote path cannot create a candidate or a new security scope.
    func listApplications() throws -> AutomationNativeApplicationListing {
        let candidates = intake?.candidates ?? []
        let applications = candidates.prefix(200).map {
            AutomationNativeApplicationListing.Application(id: $0.id, name: $0.name, kind: $0.kind,
                bundleID: $0.bundleID, platform: $0.platform, configurations: $0.configurations)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = AutomationArtifactRegistry.digest(try encoder.encode(candidates))
        return .init(applications: applications, snapshotDigest: digest,
            selectedID: candidates.contains(where: { $0.id == candidateID }) ? candidateID : nil,
            total: candidates.count, truncated: candidates.count > applications.count)
    }
    func selectApplication(id: String, snapshotDigest: String) throws -> AutomationNativeApplicationListing {
        guard canSelectApplicationFromCommand else { throw AutomationContractError.targetBusy }
        let listing = try listApplications()
        guard snapshotDigest == listing.snapshotDigest, listing.applications.contains(where: { $0.id == id }) else {
            throw AutomationContractError.conflictingOperation
        }
        if candidateID != id { candidateID = id; selectCandidate() }
        return try listApplications()
    }
}
#endif
