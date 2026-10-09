#if os(macOS)
import Foundation
import Darwin

/// Exact prepared-host live executable absence in a path-scoped observation.
/// The route must separately drain owned commands and terminate any attested runner.
/// This ingredient does not qualify an unobserved XCTest child-process closure.
actor AutomationMacAssociatedHostReleaseVerifier: AutomationDeviceReleaseVerifier {
    struct Observation: Codable, Sendable {
        let target: TargetIdentity
        let stage: String
        let inventory: AutomationMacProcessInventory?
        let accepted: Bool
        let failure: AutomationMacProcessInventory.KernelObservationFailure?
    }
    typealias Inspector = @Sendable () async throws -> AutomationMacProcessInventory
    typealias Drain = @Sendable () async -> Bool
    typealias TargetValidator = @Sendable (TargetIdentity) throws -> Void
    private let host: AutomationPreparedAppleHost
    private let userID: UInt32
    private let executable: URL
    private let executableDigest: String
    private let inspector: Inspector
    private let drain: Drain
    private let validateTarget: TargetValidator
    private var prepared: TargetIdentity?
    private var busy = false
    private var inspectorUnproved = false
    private var inspections = 0
    private var evidence: [Observation] = []

    init(host: AutomationPreparedAppleHost) throws {
        let profile = try Self.profile(host)
        try AutomationMacGUIIdentity.validate(host.target)
        self.host = host; userID = getuid(); executable = profile.executable; executableDigest = profile.digest
        inspector = { try AutomationMacProcessInventory.currentUser(watchedExecutablePaths: [profile.executable.path]) }
        drain = { true }; validateTarget = { try AutomationMacGUIIdentity.validate($0) }
    }
    init(host: AutomationPreparedAppleHost, userID: UInt32, inspector: @escaping Inspector,
         drain: @escaping Drain, validateTarget: @escaping TargetValidator) throws {
        let profile = try Self.profile(host)
        self.host = host; self.userID = userID; executable = profile.executable; executableDigest = profile.digest
        self.inspector = inspector; self.drain = drain; self.validateTarget = validateTarget
    }
    func retainedObservations() -> [Observation] { evidence }
    func prepare(target: TargetIdentity, controllerBundleIDs: [String]) async throws {
        guard !busy, !inspectorUnproved else { throw AutomationContractError.terminationUnverified }
        busy = true; defer { busy = false }; prepared = nil
        try validateScope(target, controllerBundleIDs)
        guard try await observe(target, stage: "prepare") else { throw AutomationContractError.targetBusy }
        prepared = target
    }
    func verifyReleased(target: TargetIdentity, controllerBundleIDs: [String]) async -> Bool {
        guard !busy, !inspectorUnproved, prepared == target else { return false }
        busy = true; defer { busy = false }
        do { try validateScope(target, controllerBundleIDs); return try await observe(target, stage: "release") }
        catch { return false }
    }
    private func validateScope(_ target: TargetIdentity, _ bundleIDs: [String]) throws {
        guard target == host.target, bundleIDs == [host.hostBundleID] else { throw AutomationContractError.invalidIdentity }
    }
    private func validateHost() throws {
        let current = try Self.profile(host)
        guard current.executable == executable, current.digest == executableDigest else { throw AutomationContractError.conflictingOperation }
    }
    private func observe(_ target: TargetIdentity, stage: String) async throws -> Bool {
        guard inspections < 64 else { throw AutomationContractError.terminationUnverified }
        inspections += 1
        var observed: AutomationMacProcessInventory?
        do {
            try Task.checkCancellation(); try validateTarget(target); try validateHost()
            let inventory = try await inspector(); observed = inventory
            guard await drain() else { inspectorUnproved = true; throw AutomationContractError.terminationUnverified }
            try Task.checkCancellation(); try inventory.validate(expectedUserID: userID, matchingExecutablePaths: [executable.path])
            try validateHost(); try validateTarget(target)
            let absent = !inventory.processes.contains { $0.executablePath == executable.path }
            evidence.append(.init(target: target, stage: stage, inventory: inventory, accepted: absent, failure: nil))
            return absent
        } catch {
            if !(await drain()) { inspectorUnproved = true }
            evidence.append(.init(target: target, stage: stage, inventory: observed, accepted: false,
                                  failure: error as? AutomationMacProcessInventory.KernelObservationFailure))
            throw error
        }
    }
    static func profile(_ host: AutomationPreparedAppleHost) throws -> (executable: URL, digest: String) {
        guard try AutomationAssociatedHostPlatform(target: host.target) == .macOS,
              host.app.platform == "macos", host.app.productDigestVersion == 2, host.hostProductDigestVersion == 2,
              host.testTarget.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil,
              host.hostBundleID.range(of: #"^[A-Za-z0-9.-]{1,256}$"#, options: .regularExpression) != nil else {
            throw AutomationContractError.invalidIdentity
        }
        let bundle = URL(fileURLWithPath: host.hostBundlePath)
        guard try AutomationPath.canonical(bundle) == bundle,
              bundle.lastPathComponent == host.testTarget + "-Runner.app",
              try AutomationProductDigest.compute(bundle: bundle, version: 2) == host.hostProductDigest,
              let info = try PropertyListSerialization.propertyList(from: AutomationProductDigest.readFile(bundle: bundle,
                relativePath: "Contents/Info.plist", maximumBytes: 1_048_576, version: 2, expectedDigest: host.hostProductDigest), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == host.hostBundleID, info["CFBundlePackageType"] as? String == "APPL",
              info["CFBundleSupportedPlatforms"] as? [String] == ["MacOSX"],
              let name = info["CFBundleExecutable"] as? String, name == host.testTarget + "-Runner" else {
            throw AutomationContractError.conflictingOperation
        }
        let executable = bundle.appendingPathComponent("Contents/MacOS/" + name)
        guard try AutomationPath.canonical(executable) == executable else { throw AutomationContractError.invalidIdentity }
        let data = try AutomationProductDigest.readFile(bundle: bundle, relativePath: "Contents/MacOS/" + name,
            maximumBytes: 16_777_216, version: 2, expectedDigest: host.hostProductDigest)
        _ = try AutomationMachOIdentity.architectures(data)
        return (executable, AutomationArtifactRegistry.digest(data))
    }
}
#endif
