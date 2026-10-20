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
    var firstChecksUnavailableReason: String? {
        guard candidate?.kind == .sourceTarget, preparationDestination == .physical else { return nil }
        return "Automatic checks are unavailable on physical devices. Choose iOS Simulator, or use Siri recognised-text submission on this device."
    }
    var selectedWorkflowUnavailableReason: String? {
        workflowUnavailableReason(route: workflowRoute, destination: preparationDestination)
    }
    func workflowUnavailableReason(route: String, destination: AutomationNativePreparationDestination) -> String? {
        if candidate?.kind == .installedProduct {
            return "Choose and prepare this app’s Xcode project to run a workflow. Packaged apps support inspection only."
        }
        guard candidate?.kind == .sourceTarget else { return nil }
        if destination == .physical, route != "siri" {
            return "UI workflows, system actions and new-record checks are unavailable on physical devices. Choose iOS Simulator, or select Siri recognised-text submission before preparing this device."
        }
        if destination != .physical, route == "siri" {
            return "Siri recognised-text submission requires a physical iPhone or iPad."
        }
        if destination == .macOS, route == "fresh" {
            return "New-record workflows are unavailable on Mac. Choose iOS Simulator."
        }
        if destination != .simulator, servedJavaScriptProfile != nil || automaticMetroRecipe != nil {
            return "This JavaScript server recipe requires iOS Simulator."
        }
        return nil
    }
    var isInstalledMacUI: Bool { candidate?.kind == .installedProduct && candidate?.app?.platform == "macos" }
    var isMacWorkflowUnavailable: Bool {
        isInstalledMacUI || (candidate?.kind == .sourceTarget && preparationDestination == .macOS && isFreshRecordWorkflow)
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
