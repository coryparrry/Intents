#if os(macOS)
import Foundation

/// Read-only release evidence. It never starts or stops an application on the device.
public actor AutomationPhysicalDeviceReleaseVerifier: AutomationDeviceReleaseVerifier {
    public typealias Inspector = @Sendable (TargetIdentity, [AutomationPhysicalRunnerVerifier.Controller]) async throws -> AutomationPhysicalRunnerVerifier.BatchObservation
    public typealias Drain = @Sendable () async -> Bool
    private let controllers: [AutomationPhysicalRunnerVerifier.Controller]
    private let inspect: Inspector
    private let drain: Drain
    private var prepared: (target: TargetIdentity, deviceIdentifier: String)?
    private var busy = false
    private var inspectorUnproved = false
    private var expectedDeviceIdentifier: String?

    /// Bind positive subject/install presence to the same actual CoreDevice UUID.
    func bindDevice(_ identifier: String) throws {
        guard !busy, !inspectorUnproved, UUID(uuidString: identifier) != nil,
              expectedDeviceIdentifier == nil || expectedDeviceIdentifier == identifier,
              prepared == nil || prepared?.deviceIdentifier == identifier else { throw AutomationContractError.invalidIdentity }
        expectedDeviceIdentifier = identifier
    }
    func preparedDevice(target: TargetIdentity) throws -> String {
        guard !busy, !inspectorUnproved, let prepared, prepared.target == target else { throw AutomationContractError.terminationUnverified }
        return prepared.deviceIdentifier
    }

    public init(controllers: [AutomationPhysicalRunnerVerifier.Controller], inspect: @escaping Inspector, drain: @escaping Drain) throws {
        guard (1...10).contains(controllers.count), Set(controllers.map(\.bundleID)).count == controllers.count else {
            throw AutomationContractError.invalidIdentity
        }
        for controller in controllers { try controller.validate() }
        self.controllers = controllers; self.inspect = inspect; self.drain = drain
    }

    public init(workspace: URL, developerDirectory: URL, controllers: [AutomationPhysicalRunnerVerifier.Controller],
                didStart: @escaping @Sendable (AutomationProcessIdentity) async throws -> Void = { _ in }) throws {
        guard (1...10).contains(controllers.count), Set(controllers.map(\.bundleID)).count == controllers.count else {
            throw AutomationContractError.invalidIdentity
        }
        for controller in controllers { try controller.validate() }
        let verifier = try AutomationPhysicalRunnerVerifier(workspace: workspace, developerDirectory: developerDirectory)
        self.controllers = controllers
        inspect = { target, controllers in try await verifier.inspect(target: target, controllers: controllers, didStart: didStart) }
        drain = { await verifier.drainInspector() }
    }

    public func prepare(target: TargetIdentity, controllerBundleIDs: [String]) async throws {
        guard !busy, !inspectorUnproved else { throw AutomationContractError.terminationUnverified }
        busy = true; defer { busy = false }
        prepared = nil
        try validateScope(target, controllerBundleIDs)
        do {
            let observation = try await inspect(target, controllers)
            guard await drain() else { inspectorUnproved = true; throw AutomationContractError.terminationUnverified }
            try validateObservation(observation, target: target)
            prepared = (target, observation.deviceIdentifier)
        } catch {
            if !(await drain()) { inspectorUnproved = true }
            throw error
        }
    }

    public func verifyReleased(target: TargetIdentity, controllerBundleIDs: [String]) async -> Bool {
        guard !busy, !inspectorUnproved, let prepared, prepared.target == target else { return false }
        busy = true; defer { busy = false }
        do {
            try validateScope(target, controllerBundleIDs)
            let observation = try await inspect(target, controllers)
            guard await drain() else { inspectorUnproved = true; return false }
            try validateObservation(observation, target: target)
            return observation.deviceIdentifier == prepared.deviceIdentifier
        } catch {
            if !(await drain()) { inspectorUnproved = true }
            return false
        }
    }

    private func validateScope(_ target: TargetIdentity, _ bundleIDs: [String]) throws {
        guard target.kind == .physical, target.id.range(of: #"^[A-Za-z0-9-]{1,128}$"#, options: .regularExpression) != nil,
              bundleIDs.count == controllers.count, Set(bundleIDs) == Set(controllers.map(\.bundleID)) else {
            throw AutomationContractError.invalidIdentity
        }
    }
    private func validateObservation(_ observation: AutomationPhysicalRunnerVerifier.BatchObservation, target: TargetIdentity) throws {
        guard observation.targetID == target.id, UUID(uuidString: observation.deviceIdentifier) != nil,
              expectedDeviceIdentifier == nil || expectedDeviceIdentifier == observation.deviceIdentifier,
              observation.appsSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              observation.processesSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              observation.controllers.map(\.controller) == controllers, observation.controllers.allSatisfy(\.absent) else {
            throw AutomationContractError.terminationUnverified
        }
    }
}
#endif
