#if os(macOS)
import Foundation
import Darwin

/// Independent exact-path helper absence; ingredients of release, not a GUI qualification.
public actor AutomationMacHelperReleaseVerifier: AutomationDeviceReleaseVerifier {
    public struct Helper: Codable, Equatable, Sendable {
        public var executable: URL
        public var sha256: String
        public init(executable: URL, sha256: String) { self.executable = executable; self.sha256 = sha256 }
    }
    public struct Observation: Codable, Sendable {
        public var target: TargetIdentity
        public var stage: String
        public var inventory: AutomationMacProcessInventory?
        public var accepted: Bool
        public var failure: AutomationMacProcessInventory.KernelObservationFailure? = nil
    }
    public typealias Inspector = @Sendable () async throws -> AutomationMacProcessInventory
    public typealias Drain = @Sendable () async -> Bool
    private let helpers: [Helper]
    private let userID: UInt32
    private let loginSession: String
    private let inspector: Inspector
    private let drain: Drain
    private var prepared: TargetIdentity?
    private var busy = false
    private var inspectorUnproved = false
    private var inspections = 0
    private var evidence: [Observation] = []

    public init(helpers: [Helper], loginSession: String, userID: UInt32 = getuid()) throws {
        try Self.validateConfiguration(helpers, loginSession)
        self.helpers = helpers; self.loginSession = loginSession; self.userID = userID
        let paths = Set(helpers.map(\.executable.path))
        inspector = { try AutomationMacProcessInventory.currentUser(helperExecutablePaths: paths) }; drain = { true }
    }
    public init(helpers: [Helper], loginSession: String, userID: UInt32,
                inspector: @escaping Inspector, drain: @escaping Drain) throws {
        try Self.validateConfiguration(helpers, loginSession)
        self.helpers = helpers; self.loginSession = loginSession; self.userID = userID
        self.inspector = inspector; self.drain = drain
    }
    private static func validateConfiguration(_ helpers: [Helper], _ loginSession: String) throws {
        guard (1...10).contains(helpers.count), Set(helpers.map(\.executable.path)).count == helpers.count,
              !loginSession.isEmpty, loginSession.utf8.count <= 256, !loginSession.contains("\0") else {
            throw AutomationContractError.invalidIdentity
        }
        for helper in helpers { try Self.validateHelper(helper) }
    }
    public func retainedObservations() -> [Observation] { evidence }
    public func prepare(target: TargetIdentity, controllerBundleIDs: [String]) async throws {
        guard !busy, !inspectorUnproved else { throw AutomationContractError.terminationUnverified }
        busy = true; defer { busy = false }; prepared = nil
        try validateScope(target, controllerBundleIDs)
        guard try await observe(target, stage: "prepare") else { throw AutomationContractError.targetBusy }
        prepared = target
    }
    public func verifyReleased(target: TargetIdentity, controllerBundleIDs: [String]) async -> Bool {
        guard !busy, !inspectorUnproved, prepared == target else { return false }
        busy = true; defer { busy = false }
        do { try validateScope(target, controllerBundleIDs); return try await observe(target, stage: "release") }
        catch { return false }
    }
    private func validateScope(_ target: TargetIdentity, _ bundleIDs: [String]) throws {
        // Mac helper executables have no bundle ID; never silently ignore a bundle controller scope.
        guard target.kind == .nativeMac, target.id == "host-macos-local", target.loginSession == loginSession,
              bundleIDs.isEmpty else { throw AutomationContractError.invalidIdentity }
    }
    private func observe(_ target: TargetIdentity, stage: String) async throws -> Bool {
        guard inspections < 64 else { throw AutomationContractError.terminationUnverified }
        inspections += 1
        var observation: AutomationMacProcessInventory?
        do {
            for helper in helpers { try Self.validateHelper(helper) }
            let inventory = try await inspector(); observation = inventory
            guard await drain() else { inspectorUnproved = true; throw AutomationContractError.terminationUnverified }
            try inventory.validate(expectedUserID: userID, matchingExecutablePaths: Set(helpers.map(\.executable.path)))
            for helper in helpers { try Self.validateHelper(helper) }
            let paths = Set(helpers.map(\.executable.path))
            let absent = !inventory.processes.contains { paths.contains($0.executablePath) }
            evidence.append(.init(target: target, stage: stage, inventory: inventory, accepted: absent))
            return absent
        } catch {
            if !(await drain()) { inspectorUnproved = true }
            evidence.append(.init(target: target, stage: stage, inventory: observation, accepted: false,
                failure: error as? AutomationMacProcessInventory.KernelObservationFailure))
            throw error
        }
    }
    private static func validateHelper(_ helper: Helper) throws {
        guard helper.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              helper.executable.isFileURL, helper.executable.path.hasPrefix("/"),
              try AutomationPath.canonical(helper.executable) == helper.executable else {
            throw AutomationContractError.invalidIdentity
        }
        let data = try AutomationReadOnlyFile.read(root: helper.executable.deletingLastPathComponent(),
            relativePath: helper.executable.lastPathComponent, maximumBytes: 16_777_216)
        guard AutomationArtifactRegistry.digest(data) == helper.sha256 else { throw AutomationContractError.conflictingOperation }
    }
}
#endif
