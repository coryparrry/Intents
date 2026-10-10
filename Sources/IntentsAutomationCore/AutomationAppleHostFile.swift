import Foundation

/// The only test target in a prepared host is bound to its exact product and current native lease.
enum AutomationAppleHostFile {
    enum Purpose { case segment, inputAdapterProbe, siriSubmission }
    static func freeze(_ value: Any, testRoot: URL, expectedHost: URL, expectedSubject: URL, testTarget: String, payload: Data,
                       platform: AutomationAssociatedHostPlatform = .iosSimulator, purpose: Purpose = .segment) throws -> [String: Any] {
        guard purpose == .segment || (purpose == .inputAdapterProbe && platform == .macOS)
            || (purpose == .siriSubmission && platform == .physicalIOS) else { throw AutomationContractError.invalidIdentity }
        func paths(_ value: Any) -> Any {
            if let value = value as? String { return value.replacingOccurrences(of: "__TESTROOT__", with: testRoot.path).replacingOccurrences(of: "__TESTHOST__", with: expectedHost.path) }
            if let values = value as? [Any] { return values.map(paths) }
            if let fields = value as? [String: Any] { return fields.mapValues(paths) }
            return value
        }
        guard var plist = paths(value) as? [String: Any], payload.count <= 32768 else { throw AutomationContractError.invalidIdentity }
        func frozenTarget(_ input: [String: Any]) throws -> [String: Any] {
            guard input["BlueprintName"] as? String == testTarget, let hostPath = input["TestHostPath"] as? String,
                  try AutomationPath.canonical(URL(fileURLWithPath: hostPath)).path == expectedHost.path,
                  input["IsUITestBundle"] as? Bool == true, let bundlePath = input["TestBundlePath"] as? String,
                  bundlePath == expectedHost.path + "/" + platform.plugInsPath + testTarget + ".xctest",
                  try AutomationPath.canonical(URL(fileURLWithPath: bundlePath)).path == bundlePath,
                  try URL(fileURLWithPath: bundlePath).resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                  let subjectPath = input["UITargetAppPath"] as? String,
                  try AutomationPath.canonical(URL(fileURLWithPath: subjectPath)).path == expectedSubject.path else {
                throw AutomationContractError.invalidPlan("Prepared XCTest target does not match the approved host")
            }
            var target = input
            var environment = target["EnvironmentVariables"] as? [String: String] ?? [:]
            environment.removeValue(forKey: "INTENTS_AUTOMATION_HOST_PLAN_B64")
            environment.removeValue(forKey: "INTENTS_AUTOMATION_INPUT_PROBE_B64")
            environment.removeValue(forKey: "INTENTS_AUTOMATION_SIRI_PLAN_B64")
            let key: String
            switch purpose {
            case .segment: key = "INTENTS_AUTOMATION_HOST_PLAN_B64"
            case .inputAdapterProbe: key = "INTENTS_AUTOMATION_INPUT_PROBE_B64"
            case .siriSubmission: key = "INTENTS_AUTOMATION_SIRI_PLAN_B64"
            }
            environment[key] = payload.base64EncodedString()
            target["EnvironmentVariables"] = environment
            return target
        }
        if var configurations = plist["TestConfigurations"] as? [[String: Any]] {
            guard configurations.count == 1, let targets = configurations[0]["TestTargets"] as? [[String: Any]], targets.count == 1 else { throw AutomationContractError.invalidIdentity }
            configurations[0]["TestTargets"] = [try frozenTarget(targets[0])]; plist["TestConfigurations"] = configurations
        } else {
            let keys = plist.keys.filter { $0 != "__xctestrun_metadata__" }
            guard keys == [testTarget], let target = plist[testTarget] as? [String: Any] else { throw AutomationContractError.invalidIdentity }
            plist[testTarget] = try frozenTarget(target)
        }
        return plist
    }
}

/// Both controllers use the same native lease; unsupported routes remain explicit capability gaps.
public struct AutomationCompositeRouteDriver: AutomationRouteDriver {
    public var ui: any AutomationRouteDriver
    public var apple: any AutomationRouteDriver
    public init(ui: any AutomationRouteDriver, apple: any AutomationRouteDriver) { self.ui = ui; self.apple = apple }
    private func route(_ kind: AutomationSegment.Kind) throws -> any AutomationRouteDriver {
        switch kind {
        case .ui: return ui
        case .systemIntent, .systemQuery: return apple
        default: throw AutomationContractError.missingEvidence("No qualified controller for this route")
        }
    }
    public func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws {
        try await route(segment.kind).acquire(plan: plan, segment: segment, scope: scope, lease: lease)
    }
    public func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        try await route(segment.kind).execute(plan: plan, segment: segment, scope: scope, lease: lease)
    }
    public func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
        await (lease.control == .ui ? ui : apple).release(scope: scope, lease: lease)
    }
}
