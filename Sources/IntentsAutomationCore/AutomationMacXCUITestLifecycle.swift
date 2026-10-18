#if os(macOS)
import Foundation
import Darwin

/// Independently observes the exact prepared subject and XCTest runner.
/// XCTest owns application termination; matching paths never authorize signalling.
/// The caller must drain its owned Xcode process group before requesting release.
actor AutomationMacXCUITestLifecycle {
    struct Observation: Codable, Sendable {
        var stage: String
        var inventory: AutomationMacProcessInventory?
        var error: String?
    }
    private var observations: [Observation] = []
    func retainedObservations() -> [Observation] { observations }
    typealias Inspector = @Sendable () async throws -> AutomationMacProcessInventory
    typealias Validator = @Sendable () throws -> Void
    private let paths: Set<String>
    private let userID: UInt32
    private let inspect: Inspector
    private let validate: Validator
    private var admitted = false
    private var preparing = false
    private var releasing = false
    private var outcome: Bool?

    init(host: AutomationPreparedAppleHost) throws {
        let paths = try Self.executables(host)
        self.paths = paths; userID = getuid()
        inspect = { try AutomationMacProcessInventory.currentUser(watchedExecutablePaths: paths) }
        validate = {
            try AutomationMacGUIIdentity.validate(host.target)
            guard try Self.executables(host) == paths else { throw AutomationContractError.conflictingOperation }
        }
    }
    init(paths: Set<String>, userID: UInt32, inspect: @escaping Inspector,
         validate: @escaping Validator) {
        self.paths = paths; self.userID = userID; self.inspect = inspect; self.validate = validate
    }
    func prepare() async throws {
        guard !admitted, !preparing, !releasing, outcome == nil else { throw AutomationContractError.targetBusy }
        preparing = true; defer { preparing = false }
        guard try await records().isEmpty else { throw AutomationContractError.targetBusy }
        admitted = true
    }
    func release() async -> Bool {
        if let outcome { return outcome }
        guard admitted, !preparing, !releasing else { return false }
        releasing = true; defer { releasing = false }
        do {
            for attempt in 0..<20 {
                if try await records().isEmpty { outcome = true; return true }
                if attempt < 19 { try await Task.sleep(for: .milliseconds(100)) }
            }
        } catch { /* An unreadable inventory or changed product never proves absence. */ }
        outcome = false
        return false
    }
    private func records() async throws -> [AutomationMacProcessInventory.Record] {
        try validate()
        for attempt in 0..<10 {
            do {
                let inventory = try await inspect()
                try inventory.validate(expectedUserID: userID, matchingExecutablePaths: paths)
                try validate()
                observations.append(.init(stage: admitted ? "release" : "prepare", inventory: inventory, error: nil))
                return inventory.processes.filter { paths.contains($0.executablePath) }
            } catch let failure as AutomationMacProcessInventory.KernelObservationFailure {
                observations.append(.init(stage: admitted ? "release" : "prepare", inventory: nil,
                    error: String(describing: failure)))
                let exiting = failure.errorNumber == ESRCH &&
                    [.metadata, .executablePath, .codeIdentity].contains(failure.stage)
                let transitioning = failure.stage == .executableSetChanged && failure.errorNumber == 0
                guard attempt < 9, exiting || transitioning else { throw failure }
                try await Task.sleep(for: .milliseconds(100))
                try validate()
            } catch {
                observations.append(.init(stage: admitted ? "release" : "prepare", inventory: nil,
                    error: String(describing: error)))
                throw error
            }
        }
        throw AutomationContractError.terminationUnverified
    }
    private static func executables(_ host: AutomationPreparedAppleHost) throws -> Set<String> {
        let runner = try AutomationMacAssociatedHostReleaseVerifier.profile(host).executable
        let subject = URL(fileURLWithPath: host.subjectProductPath)
        guard host.app.canonicalBundlePath == subject.path,
              try AutomationPath.canonical(subject) == subject,
              try AutomationProductDigest.compute(bundle: subject, version: 2) == host.app.productDigest,
              let info = try PropertyListSerialization.propertyList(from: AutomationProductDigest.readFile(bundle: subject,
                relativePath: "Contents/Info.plist", maximumBytes: 1_048_576, version: 2, expectedDigest: host.app.productDigest), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == host.app.bundleID,
              info["CFBundleSupportedPlatforms"] as? [String] == ["MacOSX"],
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty,
              !name.contains("/"), name != ".", name != ".." else { throw AutomationContractError.invalidIdentity }
        let executable = subject.appendingPathComponent("Contents/MacOS/" + name)
        guard try AutomationPath.canonical(executable) == executable else { throw AutomationContractError.invalidIdentity }
        _ = try AutomationMachOIdentity.architectures(AutomationProductDigest.readFile(bundle: subject,
            relativePath: "Contents/MacOS/" + name, maximumBytes: 16_777_216, version: 2, expectedDigest: host.app.productDigest))
        guard executable != runner else { throw AutomationContractError.invalidIdentity }
        return [executable.path, runner.path]
    }
}
#endif
