#if os(macOS)
import Foundation

/// Optional readback check. Its outcome never changes execution capabilities.
public actor AutomationInputConversionDiagnostic {
    public struct Selection: Equatable, Sendable {
        public let actionID: String
        public let actionTitle: String
        public let parameterNames: [String]
    }
    public struct Result: Equatable, Sendable {
        public let resourcesReleased: Bool
        public let message: String
    }

    /// The retained canary currently supports a prepared Mac host and fixed sample types.
    public nonisolated static func selection(prepared: AutomationPreparedApplication, actionID: String) -> Selection? {
        guard prepared.host.target.kind == .nativeMac,
              let action = prepared.catalog.systemActions.first(where: { $0.id == actionID }),
              action.compiled, action.parametersComplete else { return nil }
        let names = action.parameters.filter { parameter in
            guard let family = parameter.family else { return false }
            return (try? AutomationInputAdapterProbePlan.samples(family: family)) != nil
        }.map(\.name).sorted()
        guard (1...10).contains(names.count) else { return nil }
        return .init(actionID: action.id, actionTitle: action.title, parameterNames: names)
    }

    private let runner: AutomationInputAdapterProbeRunner
    private let parameters: [String]
    /// Exact durable campaign identity, available before the diagnostic starts.
    public nonisolated let runID: String
    public init(prepared: AutomationPreparedApplication, selection: Selection, supportRoot: URL, developerDirectory: URL) throws {
        guard Self.selection(prepared: prepared, actionID: selection.actionID) == selection else {
            throw AutomationContractError.conflictingOperation
        }
        try AutomationPreparedCodecAuthority.verify(prepared)
        let plan = try AutomationInputAdapterProbePlan(prepared: prepared, actionID: selection.actionID, parameterNames: selection.parameterNames)
        let diagnosticRunID = "input-conversion-" + UUID().uuidString
        runID = diagnosticRunID
        let root = supportRoot.appendingPathComponent(diagnosticRunID)
        let leases = try AutomationDeviceLeaseManager(storeURL: supportRoot.appendingPathComponent("target-leases.json"))
        runner = try AutomationInputAdapterProbeRunner(plan: plan,
            approval: .init(runID: diagnosticRunID, probeDigest: plan.digest, app: prepared.host.app, target: prepared.host.target),
            developerDirectory: developerDirectory, state: root,
            leases: leases, artifacts: AutomationArtifactRegistry(root: root.appendingPathComponent("artifacts")),
            subject: AutomationInstalledSubjectVerifier(developerDirectory: developerDirectory, workspace: root),
            release: AutomationMacAssociatedHostReleaseVerifier(host: prepared.host))
        parameters = selection.parameterNames
    }
    public func run() async throws -> Result {
        let report = try await withTaskCancellationHandler {
            try await runner.run(attemptID: UUID().uuidString)
        } onCancel: {
            Task { _ = await self.runner.cancel() }
        }
        return Self.result(resourcesReleased: report.resourcesReleased, succeeded: report.observation != nil,
                           failure: report.failure, parameterNames: parameters)
    }
    static func result(resourcesReleased: Bool, succeeded: Bool, failure: String?, parameterNames: [String]) -> Result {
        if !resourcesReleased {
            return .init(resourcesReleased: false, message: "Input conversion check could not verify host cleanup. The target remains held. " + (failure ?? ""))
        }
        if let failure { return .init(resourcesReleased: true, message: "Input conversion check failed: " + failure) }
        guard succeeded else { return .init(resourcesReleased: true, message: "Input conversion check did not return readback evidence.") }
        return .init(resourcesReleased: true, message: "Input conversion matched the fixed samples for " + parameterNames.joined(separator: ", ") + ". Host cleanup was verified.")
    }
}
#endif
