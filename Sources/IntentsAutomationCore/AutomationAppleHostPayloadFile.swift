import Foundation

/// Exact per-lease derivative. Retain this authority before writing so failed
/// acquisitions can clean their own payload after independently confirmed drain.
struct AutomationAppleHostPayloadFile: Sendable {
    private let scope: AutomationScope
    private let store: AutomationDurableFile
    private let frozenDigest: String
    private let cleanData: Data
    private let cleanDigest: String

    init(data: Data, url: URL, scope: AutomationScope) throws {
        try scope.validate()
        guard data.count <= 4_194_304, var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AutomationContractError.invalidIdentity
        }
        func clean(_ target: [String: Any]) throws -> [String: Any] {
            guard var environment = target["EnvironmentVariables"] as? [String: String] else { throw AutomationContractError.invalidIdentity }
            environment.removeValue(forKey: "INTENTS_AUTOMATION_HOST_PLAN_B64")
            environment.removeValue(forKey: "INTENTS_AUTOMATION_INPUT_PROBE_B64")
            environment.removeValue(forKey: "INTENTS_AUTOMATION_SIRI_PLAN_B64")
            var result = target; result["EnvironmentVariables"] = environment; return result
        }
        if var configurations = plist["TestConfigurations"] as? [[String: Any]] {
            guard configurations.count == 1, let targets = configurations[0]["TestTargets"] as? [[String: Any]], targets.count == 1 else { throw AutomationContractError.invalidIdentity }
            configurations[0]["TestTargets"] = [try clean(targets[0])]; plist["TestConfigurations"] = configurations
        } else {
            let targets = plist.keys.filter { $0 != "__xctestrun_metadata__" }
            guard targets.count == 1, let name = targets.first, let target = plist[name] as? [String: Any] else { throw AutomationContractError.invalidIdentity }
            plist[name] = try clean(target)
        }
        let cleanData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        guard cleanData.count <= 4_194_304 else { throw AutomationContractError.invalidIdentity }
        self.scope = scope; self.store = try AutomationDurableFile(url: url, maximumBytes: 4_194_304)
        self.frozenDigest = AutomationArtifactRegistry.digest(data); self.cleanData = cleanData
        self.cleanDigest = AutomationArtifactRegistry.digest(cleanData)
    }

    var recoveryReference: AutomationDeviceLeaseManager.PrivatePayload {
        .init(scope: scope, path: store.url.path, frozenDigest: frozenDigest, cleanDigest: cleanDigest)
    }

    func write(_ data: Data) throws {
        guard AutomationArtifactRegistry.digest(data) == frozenDigest else { throw AutomationContractError.conflictingOperation }
        try store.withLock {
            guard try store.read() == nil else { throw AutomationContractError.conflictingOperation }
            try store.write(data, stagingName: recoveryReference.stagingName)
        }
    }

    /// Call only after command/runner/target drain. Preserve unrelated fields,
    /// raw results and logs; refuse changed or linked derivative files.
    func clean(scope: AutomationScope) throws {
        guard scope == self.scope else { throw AutomationContractError.unknownLease }
        try store.withLock {
            guard let data = try store.read() else { return }
            let digest = AutomationArtifactRegistry.digest(data)
            if digest == cleanDigest { return }
            guard digest == frozenDigest else { throw AutomationContractError.conflictingOperation }
            try store.write(cleanData, stagingName: recoveryReference.stagingName)
            guard try store.read().map(AutomationArtifactRegistry.digest) == cleanDigest else { throw AutomationContractError.conflictingOperation }
        }
    }
}
