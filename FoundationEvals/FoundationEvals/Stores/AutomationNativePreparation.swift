#if os(macOS)
import Foundation
import Observation
import IntentsAutomationCore

struct AutomationNativeToolchainChoice: Equatable, Sendable, Identifiable {
    let directory: URL
    let version: String
    let build: String
    let metadataDigest: String
    var id: String { directory.path }
    var label: String { "Xcode \(version) (\(build))" }
}

enum AutomationNativeToolchain {
    static func installedChoices(configured: URL, applications: [URL] = AutomationInstalledToolchain.applicationDirectories,
                                 selected: URL? = AutomationInstalledToolchain.selectedDirectory) -> [AutomationNativeToolchainChoice] {
        AutomationInstalledToolchain.candidates(configured: configured, selected: selected, applications: applications).prefix(32).compactMap { candidate in
            guard AutomationInstalledToolchain.diskEligible(candidate.directory, sdk: "macosx"),
                  let metadata = try? AutomationInstalledToolchain.metadata(directory: candidate.directory) else { return nil }
            return .init(directory: candidate.directory, version: metadata.version, build: metadata.build, metadataDigest: metadata.digest)
        }
    }
    static func developerDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   applications: [URL] = AutomationInstalledToolchain.applicationDirectories,
                                   selected: URL? = AutomationInstalledToolchain.selectedDirectory,
                                   probe: (URL, String) throws -> Bool = { AutomationInstalledToolchain.diskEligible($0, sdk: $1) }) -> URL {
        let configured = environment["DEVELOPER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let candidates = AutomationInstalledToolchain.candidates(configured: configured, selected: selected, applications: applications)
        if let eligible = try? AutomationInstalledToolchain.select(candidates: candidates, requiredSDK: "macosx", probe: probe) { return eligible }
        // Keep read-only inspection available. Preparation performs SDK-specific command probes and
        // reports the exact install/licence action if no eligible installed Xcode exists.
        return URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")
    }
}

enum AutomationNativePreparationDestination: String, CaseIterable, Identifiable {
    case simulator, physical, macOS
    var id: String { rawValue }
    var title: String { switch self { case .simulator: "iOS Simulator"; case .physical: "Physical iPhone or iPad"; case .macOS: "This Mac" } }
}

/// Saved defaults are destination-specific; a run override never changes those defaults.
@MainActor @Observable final class AutomationNativeXcodeSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "automation.xcodePathsByDestination"
    private var paths: [String: String]
    var runOverride = ""

    init(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? Self.applicationDefaults()
        self.defaults = defaults
        paths = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
    private static func applicationDefaults() -> UserDefaults {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--automation-xcode-settings-suite"), arguments.indices.contains(index + 1),
           let suite = UserDefaults(suiteName: arguments[index + 1]) { return suite }
        #endif
        return .standard
    }
    func path(for destination: AutomationNativePreparationDestination) -> String {
        paths[destination.rawValue] ?? ""
    }
    func setPath(_ path: String, for destination: AutomationNativePreparationDestination) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { paths.removeValue(forKey: destination.rawValue) }
        else { paths[destination.rawValue] = trimmed }
        defaults.set(paths, forKey: key)
    }
    func developerDirectory(for destination: AutomationNativePreparationDestination, fallback: URL) -> URL {
        let override = runOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = override.isEmpty ? path(for: destination) : override
        guard !selected.isEmpty else { return fallback }
        let url = URL(fileURLWithPath: selected)
        return url.pathExtension == "app" ? url.appendingPathComponent("Contents/Developer") : url
    }
}

typealias AutomationNativePreparationExecutor = @Sendable (AutomationApplicationCandidate, AutomationBuildApproval, URL) async throws -> AutomationPreparedApplication
typealias AutomationNativeSimulatorInventoryReader = @Sendable (URL, URL) async throws -> [AutomationSimulator]
typealias AutomationNativePhysicalInventoryReader = @Sendable (URL, URL) async throws -> [AutomationPhysicalDevice]

/// Retains only picker-selected folder scopes; a failed selection releases its temporary scope.
@MainActor @Observable final class AutomationNativeSourceGrants {
    private(set) var urls: [URL] = []
    @ObservationIgnored private var scoped: Set<URL> = []
    @ObservationIgnored private let start: (URL) throws -> Bool
    @ObservationIgnored private let stop: (URL) -> Void
    init(start: @escaping (URL) throws -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.start = start; self.stop = stop
    }
    func add(_ url: URL, primary: URL) throws {
        guard urls.count < 8, !urls.contains(url) else { throw AutomationContractError.invalidIdentity }
        let active = try start(url)
        do {
            _ = try AutomationSourceSnapshot.validateRoots(source: primary, additionalRoots: urls + [url])
        } catch {
            if active { stop(url) }; throw error
        }
        urls.append(url); urls.sort { $0.path < $1.path }
        if active { scoped.insert(url) }
    }
    func remove(_ url: URL) {
        guard urls.contains(url) else { return }
        urls.removeAll { $0 == url }; if scoped.remove(url) != nil { stop(url) }
    }
    func clear() { for url in urls { if scoped.contains(url) { stop(url) } }; urls = []; scoped = [] }
}

extension AppAutomationStore {
    var sourcePreparationTarget: TargetIdentity? {
        guard candidate?.kind == .sourceTarget else { return nil }
        switch preparationDestination {
        case .simulator:
            guard UUID(uuidString: simulatorID) != nil else { return nil }
            return .init(id: simulatorID, kind: .simulator)
        case .physical:
            var target = TargetIdentity(id: physicalDeviceID, kind: .physical)
            target.physicalDeviceIdentifier = physicalDevices.first(where: { $0.id == physicalDeviceID })?.coreDeviceIdentifier
                ?? resolvedPhysicalDeviceIdentifiers[physicalDeviceID.lowercased()]
            guard (try? AutomationPhysicalExecutable.validateTarget(target)) != nil else { return nil }
            return target
        case .macOS:
            guard let target = try? nativeMacTargetReader(), target.kind == .nativeMac, target.id == "host-macos-local",
                  let login = target.loginSession, !login.isEmpty, login.utf8.count <= 256,
                  !login.contains("\0"), !login.contains("\n") else { return nil }
            return target
        }
    }
    var needsSimulatorInventory: Bool {
        isInstalledUI || (candidate?.kind == .sourceTarget && preparationDestination == .simulator)
    }
    var needsPhysicalInventory: Bool { candidate?.kind == .sourceTarget && preparationDestination == .physical }
    var simulatorInventorySelection: String { candidateID + "|" + preparationDestination.rawValue }
    func validatePreparedSelection(_ value: AutomationPreparedApplication, candidate: AutomationApplicationCandidate,
                                   approval: AutomationBuildApproval) throws {
        try approval.validateSourceManifest(value.source)
        let platform = approval.target.kind == .nativeMac ? "macos" : "ios"
        guard value.host.target == approval.target, value.host.app.logicalID == candidate.id,
              value.host.app.platform == platform, value.host.app.configuration == approval.configuration,
              value.generatedHost.configuration == approval.configuration else { throw AutomationContractError.conflictingOperation }
    }
}
#endif
