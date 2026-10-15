#if os(macOS)
import Foundation

struct AutomationPhysicalInputAdapterPlan: Sendable {
    let prepared: AutomationPreparedApplication
    let baseline: AutomationCase
    let actionID: String, entityMember: String, boolMember: String, entityType: String, entityID: String
    let sdkBuild: String, xcodeBuild: String, runnerExecutable: String
    var digest: String { get throws { try AutomationFrozenCase.canonicalDigest(try payload(scope: .init(runID: "probe-review", attemptID: "probe-review", segmentID: "input-adapter", leaseGeneration: 1))) } }
    init(prepared: AutomationPreparedApplication, baseline: AutomationCase, actionID: String, entityID: String,
         sdkBuild: String, xcodeBuild: String, runnerExecutable: String) throws {
        guard prepared.host.target.kind == .physical, prepared.host.app.platform == "ios", prepared.host.app == baseline.app,
              prepared.host.target == baseline.target, prepared.generatedHost.includesSiri == true,
              prepared.catalog.systemActions.filter({ $0.id == actionID }).count == 1,
              let action = prepared.catalog.systemActions.first(where: { $0.id == actionID }),
              action.registered, action.compiled, action.parametersComplete, action.parameters.count == 2,
              action.resultFamily == nil || action.resultFamily == "noValue",
              let entity = action.parameters.first(where: { $0.family == "entity" }),
              let boolean = action.parameters.first(where: { $0.family == "bool" }), let type = entity.typeID,
              type == baseline.setupChecks?.first?.entityProperty?.selection.typeID,
              !entityID.isEmpty, entityID.utf16.count <= 1024, !entityID.contains("\0"),
              [actionID, entity.name, boolean.name, type, runnerExecutable].allSatisfy({ $0.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil }),
              [sdkBuild, xcodeBuild].allSatisfy({ $0.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil }) else { throw AutomationContractError.invalidIdentity }
        self.prepared = prepared; self.baseline = baseline; self.actionID = actionID; entityMember = entity.name; boolMember = boolean.name
        entityType = type; self.entityID = entityID; self.sdkBuild = sdkBuild; self.xcodeBuild = xcodeBuild; self.runnerExecutable = runnerExecutable
    }
    func payload(scope: AutomationScope) throws -> Data {
        try scope.validate()
        let host = prepared.host
        return try AutomationFrozenCase.canonicalData(AutomationJSON.object([
            "schemaVersion": .number(1), "purpose": .string("physicalRecordBoolInputAdapter"),
            "runID": .string(scope.runId), "attemptID": .string(scope.attemptId), "segmentID": .string(scope.segmentId), "leaseGeneration": .number(Double(scope.leaseGeneration)),
            "bundleID": .string(host.app.bundleID), "targetID": .string(host.target.id), "environmentID": .string(baseline.environmentID),
            "productDigest": .string(host.app.productDigest ?? ""), "hostProductDigest": .string(host.hostProductDigest), "xctestrunDigest": .string(host.xctestrunDigest),
            "sourceDigest": .string(try prepared.source.digest), "templateDigest": .string(prepared.generatedHost.templateDigest), "catalogDigest": .string(try AutomationRecipeContext.catalogDigest(prepared.catalog)),
            "baselineDigest": .string(try AutomationFrozenCase.planDigest(baseline)), "actionID": .string(actionID),
            "entityMember": .string(entityMember), "boolMember": .string(boolMember), "entityType": .string(entityType), "entityID": .string(entityID),
            "sdkBuild": .string(sdkBuild), "xcodeBuild": .string(xcodeBuild)
        ]))
    }
}
struct AutomationPhysicalInputAdapterObservation: Sendable {
    let osBuild: String, receiptDigest: String
    static func read(_ data: Data, plan: AutomationPhysicalInputAdapterPlan, scope: AutomationScope) throws -> Self {
        guard data.count <= 32_768, let fields = try JSONDecoder().decode(AutomationJSON.self, from: data).object,
              let expected = try JSONDecoder().decode(AutomationJSON.self, from: plan.payload(scope: scope)).object,
              Set(fields.keys) == Set(expected.keys).union(["runner", "osBuild", "complete", "echoedEntityID", "echoedEntityType", "echoedBooleans"]),
              expected.allSatisfy({ fields[$0.key] == $0.value }), fields["complete"] == .bool(true),
              fields["echoedEntityID"] == .string(plan.entityID), fields["echoedEntityType"] == .string(plan.entityType),
              fields["echoedBooleans"] == .array([.bool(false), .bool(true)]),
              case .string(let build) = fields["osBuild"], build.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil,
              plan.baseline.target.osBuild == nil || plan.baseline.target.osBuild == build,
              let runner = fields["runner"]?.object, Set(runner.keys) == ["pid", "startIdentity", "executablePath"],
              case .number(let pid) = runner["pid"], pid > 0, pid <= Double(Int32.max), pid.rounded() == pid,
              case .string(let start) = runner["startIdentity"], start.range(of: #"^[0-9]{1,20}:[0-9]{1,6}$"#, options: .regularExpression) != nil,
              case .string(let path) = runner["executablePath"],
              AutomationPhysicalControllerValidation.matchesExecutablePath(path, bundleName: URL(fileURLWithPath: plan.prepared.host.hostBundlePath).lastPathComponent, executableName: plan.runnerExecutable) else {
            throw AutomationContractError.conflictingOperation
        }
        return .init(osBuild: build, receiptDigest: AutomationArtifactRegistry.digest(data))
    }
}
public struct AutomationPhysicalInputAdapterReport: Sendable {
    public let queryReport: AutomationAttemptReport
    public let resourcesReleased: Bool
    public let qualified: Bool
    public let failure: String?
    public let artifact: String?
    public var expiresAt: ContinuousClock.Instant? = nil
}
actor AutomationPhysicalInputAdapterAuthority {
    static let shared = AutomationPhysicalInputAdapterAuthority()
    private struct Entry: Sendable {
        let prepared: AutomationPreparedApplication, actionID: String, environmentID: String, entityType: String
        let entityMember: String, boolMember: String, entityID: String, osBuild: String, evidence: String
        let selection: AutomationEntitySelection
        let deadline: ContinuousClock.Instant
    }
    private var entries: [Entry] = []
    private let now: @Sendable () -> ContinuousClock.Instant
    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) { self.now = now }
    @discardableResult
    func record(plan: AutomationPhysicalInputAdapterPlan, observation: AutomationPhysicalInputAdapterObservation, released: Bool) throws -> ContinuousClock.Instant {
        guard released else { throw AutomationContractError.terminationUnverified }
        entries.removeAll { $0.prepared == plan.prepared && $0.actionID == plan.actionID && $0.environmentID == plan.baseline.environmentID }
        let deadline = now().advanced(by: .seconds(1800))
        entries.append(.init(prepared: plan.prepared, actionID: plan.actionID, environmentID: plan.baseline.environmentID, entityType: plan.entityType,
            entityMember: plan.entityMember, boolMember: plan.boolMember, entityID: plan.entityID, osBuild: observation.osBuild, evidence: observation.receiptDigest,
            selection: plan.baseline.setupChecks!.first!.entityProperty!.selection,
            deadline: deadline))
        if entries.count > 32 { entries.removeFirst() }
        return deadline
    }
    func osBuild(prepared: AutomationPreparedApplication, plan: AutomationCase) -> String? { entry(prepared: prepared, plan: plan)?.osBuild }
    func applying(prepared: AutomationPreparedApplication, plan: AutomationCase, capabilities: CapabilityProfile) -> CapabilityProfile {
        var result = capabilities
        for key in ["apple.intent.invoke", "apple.codec.bool", "apple.codec.entity"] {
            if result.records[key]?.state == .available { result.records.removeValue(forKey: key) }
        }
        guard let entry = entry(prepared: prepared, plan: plan) else { return result }
        for key in ["apple.intent.invoke", "apple.codec.bool", "apple.codec.entity"] where result.records[key] == nil || result.records[key]?.state == .unknown {
            result.records[key] = .init(state: .available, reason: "Owned released read-only parameter roundtrip for this physical host, record type and exact reset members; no business action performed",
                probeVersion: "physical-record-bool-roundtrip-v1", evidence: [entry.evidence, prepared.host.xctestrunDigest, entry.osBuild])
        }
        return result
    }
    func validateReset(host: AutomationPreparedAppleHost, plan: AutomationCase, segment: AutomationSegment) throws -> String {
        guard let candidate = entries.last(where: { $0.prepared.host == host }),
              let entry = entry(prepared: candidate.prepared, plan: plan),
              let operation = segment.hostProgram?.operations.first,
              segment.id == "siri.restore", operation.typeID == entry.actionID,
              operation.parameters[entry.entityMember] == .entity(typeID: entry.entityType, value: entry.entityID) else {
            throw AutomationContractError.missingEvidence("The actual reset record ID or live physical conversion authority changed")
        }
        return entry.osBuild
    }
    private func entry(prepared: AutomationPreparedApplication, plan: AutomationCase) -> Entry? {
        guard plan.setup.count == 3, let reset = plan.setup[1].hostProgram?.operations.first,
              let binding = plan.setup[1].inputBindings?.first else { return nil }
        return entries.last { $0.prepared == prepared && $0.environmentID == plan.environmentID && $0.actionID == reset.typeID &&
             $0.selection == plan.setupChecks?.first?.entityProperty?.selection &&
            $0.entityType == binding.uniqueEntity?.typeID && $0.entityMember == binding.name && reset.parameters[$0.boolMember] != nil &&
            now() < $0.deadline && (plan.target.osBuild == nil || plan.target.osBuild == $0.osBuild) }
    }
}
#endif
