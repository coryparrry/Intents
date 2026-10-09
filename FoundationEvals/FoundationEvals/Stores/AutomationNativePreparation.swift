#if os(macOS)
import Foundation
import Observation
import IntentsAutomationCore

enum AutomationNativeToolchain {
    static func developerDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let path = environment["DEVELOPER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/Applications/Xcode.app/Contents/Developer"
        let url = URL(fileURLWithPath: path)
        return url.pathExtension == "app" ? url.appendingPathComponent("Contents/Developer") : url
    }
}

enum AutomationNativePreparationDestination: String, CaseIterable, Identifiable {
    case simulator, physical, macOS
    var id: String { rawValue }
    var title: String { switch self { case .simulator: "iOS Simulator"; case .physical: "Physical iPhone or iPad"; case .macOS: "This Mac" } }
}

typealias AutomationNativePreparationExecutor = @Sendable (AutomationApplicationCandidate, AutomationBuildApproval, URL) async throws -> AutomationPreparedApplication
typealias AutomationNativeSimulatorInventoryReader = @Sendable (URL, URL) async throws -> [AutomationSimulator]

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
            let target = TargetIdentity(id: physicalDeviceID, kind: .physical)
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
