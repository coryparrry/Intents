#if os(macOS)
import Foundation

public struct AutomationNativeInputAdapterReport: Codable, Equatable, Sendable {
    public let probeDigest: String
    public let receiptDigest: String?
    public let artifact: String?
    public let resourcesReleased: Bool
    public let qualifiedCapabilities: [String]
    public let failure: String?
}

/// Frozen workflow consent includes each read-only calibration. The native app
/// can present ordinary Run approval without asking users for technical digests.
public enum AutomationNativeInputAdapterPlanning {
    public static func attachReviews(to plan: AutomationCase, prepared: AutomationPreparedApplication,
                                     capabilities: CapabilityProfile) throws -> AutomationCase {
        guard plan.app == prepared.host.app, plan.target == prepared.host.target else { throw AutomationContractError.conflictingOperation }
        guard plan.target.kind == .nativeMac else { return plan }
        var result = plan
        let bound = try reviews(plan: plan, prepared: prepared, capabilities: capabilities)
        result.nativeInputAdapterReviews = bound.isEmpty ? nil : bound
        return result
    }
    public static func reviews(plan: AutomationCase, prepared: AutomationPreparedApplication,
                               capabilities: CapabilityProfile) throws -> [AutomationNativeInputAdapterReview] {
        guard plan.target.kind == .nativeMac, plan.app == prepared.host.app, plan.target == prepared.host.target else {
            throw AutomationContractError.conflictingOperation
        }
        try AutomationPreparedProgramContract.validate(plan, catalog: prepared.catalog)
        let stripped = AutomationNativeCodecQualification.strippingGrants(capabilities)
        let supported = Set(["entity", "text", "bool", "integer", "decimal", "date", "url", "duration", "calendarComponents",
            "textArray", "boolArray", "integerArray", "decimalArray", "dateArray", "intentFile"])
        var selected: [String: Set<String>] = [:]
        for segment in plan.setup + [plan.execution] + plan.observations + plan.cleanup {
            for operation in segment.hostProgram?.operations ?? [] where operation.kind == .invoke {
                guard let action = prepared.catalog.systemActions.first(where: { $0.id == operation.typeID }) else { continue }
                let bound = Set((segment.inputBindings ?? []).filter { $0.destination == .hostParameter && $0.operationID == operation.id }.map(\.name))
                for parameter in action.parameters {
                    guard let family = parameter.family, supported.contains(family),
                          operation.parameters[parameter.name].map({ $0 != .null && $0 != .omission }) ?? bound.contains(parameter.name),
                          stripped.records["apple.codec." + family] == nil || stripped.records["apple.codec." + family]?.state == .unknown else { continue }
                    selected[action.id, default: []].insert(parameter.name)
                }
            }
        }
        guard selected.count <= 10 else { throw AutomationContractError.invalidPlan("Native workflows support at most ten read-only adapter checks") }
        return try selected.keys.sorted().map { action in
            try AutomationNativeCodecQualification.review(.init(prepared: prepared, actionID: action, parameterNames: selected[action]!.sorted()))
        }
    }
}

/// Only this owned live round trip can create native input-adapter authority.
/// Prepared records, simulator evidence and imported receipts cannot register it.
enum AutomationNativeCodecQualification {
    static let probeVersion = "native-input-adapter-1"

    struct Context: Equatable, Sendable {
        let snapshot: AutomationMacAppleRuntimeSnapshot
        let signatures: [String]
        func validate(prepared: AutomationPreparedApplication, developer: URL, workspace: URL) async throws {
            guard snapshot.developerDirectory == developer else { throw AutomationContractError.conflictingOperation }
            try snapshot.validate(host: prepared.host)
            guard try await AutomationNativeCodecQualification.signatures(prepared, developer: developer, workspace: workspace) == signatures else {
                throw AutomationContractError.conflictingOperation
            }
        }
    }

    struct Evidence: Sendable {
        let prepared: AutomationPreparedApplication
        let actionID: String
        let parameters: [AutomationInputAdapterProbePlan.Parameter]
        let context: Context
        let report: AutomationInputAdapterProbeReport
        let expires: ContinuousClock.Instant
    }

    static func review(_ plan: AutomationInputAdapterProbePlan) throws -> AutomationNativeInputAdapterReview {
        .init(probeDigest: try plan.digest, app: plan.prepared.host.app, target: plan.prepared.host.target,
              actionID: plan.actionID, parameterNames: plan.parameters.map(\.name), purpose: "Construct, assign and read intent parameters; never perform the action",
              fixedSamples: Dictionary(uniqueKeysWithValues: plan.parameters.map { ($0.name, $0.samples) }))
    }

    static func qualify(plan: AutomationInputAdapterProbePlan, reviewedProbeDigest: String, runID: String, attemptID: String,
                        developer: URL, root: URL, leases: AutomationDeviceLeaseManager) async throws -> AutomationNativeInputAdapterReport {
        guard reviewedProbeDigest == (try plan.digest) else { throw AutomationContractError.conflictingOperation }
        let state = root.appendingPathComponent("native-input-adapter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let signed = try await signatures(plan.prepared, developer: developer, workspace: state)
        let artifacts = try AutomationArtifactRegistry(root: state.appendingPathComponent("artifacts"))
        let installed = AutomationInstalledSubjectVerifier(developerDirectory: developer, workspace: state)
        let subject = NativeCodecSubjectVerifier(subject: installed)
        let runner = try AutomationInputAdapterProbeRunner(plan: plan,
            approval: .init(runID: runID, probeDigest: reviewedProbeDigest, app: plan.prepared.host.app, target: plan.prepared.host.target),
            developerDirectory: developer, state: state.appendingPathComponent("owner"), leases: leases, artifacts: artifacts,
            subject: subject, release: AutomationMacAssociatedHostReleaseVerifier(host: plan.prepared.host))
        let report = try await withTaskCancellationHandler(operation: { try await runner.run(attemptID: attemptID) }, onCancel: {
            Task { _ = await runner.cancel() }
        })
        var failure = report.failure
        var granted: [String] = []
        if report.resourcesReleased, failure == nil, let observation = report.observation {
            do {
                try Task.checkCancellation()
                guard let runtime = observation.runtimeObservation else {
                    throw AutomationContractError.missingEvidence("Native adapter receipt has no loaded Apple runtime identity")
                }
                let snapshot = try AutomationMacAppleRuntimeSnapshot.observe(host: plan.prepared.host, developerDirectory: developer, observation: runtime)
                let context = Context(snapshot: snapshot, signatures: signed)
                try await context.validate(prepared: plan.prepared, developer: developer, workspace: state)
                let evidence = Evidence(prepared: plan.prepared, actionID: plan.actionID, parameters: plan.parameters,
                    context: context, report: report, expires: ContinuousClock.now.advanced(by: .seconds(600)))
                try await AutomationNativeCodecAuthority.shared.register(evidence)
                granted = Set(plan.parameters.map { "apple.codec." + $0.family }).sorted()
            } catch { failure = String(String(describing: error).prefix(4096)) }
        }
        return .init(probeDigest: reviewedProbeDigest, receiptDigest: report.observation?.receiptDigest,
            artifact: report.artifact, resourcesReleased: report.resourcesReleased, qualifiedCapabilities: granted, failure: failure)
    }

    /// Expiry must be checked after awaited validation, never just before it.
    static func validateBeforeExpiry<Value: Sendable>(_ value: Value, expires: ContinuousClock.Instant,
        now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        validation: @Sendable () async throws -> Void) async throws -> Value? {
        guard expires > now() else { return nil }
        try await validation(); try Task.checkCancellation()
        return expires > now() ? value : nil
    }

    static func strippingGrants(_ profile: CapabilityProfile) -> CapabilityProfile {
        var result = profile
        // Positive Codable declarations are never native conversion authority,
        // regardless of the caller's chosen probe version or evidence labels.
        for (key, record) in profile.records where key.hasPrefix("apple.codec.") && record.state == .available {
            result.records.removeValue(forKey: key)
        }
        return result
    }

    /// Require every selected parameter in a family to have its own live readback.
    /// This is input conversion authority; it does not qualify result-only codecs.
    static func members(plan: AutomationCase, catalog: ApplicationSurfaceCatalog, family: String) -> Set<String> {
        var result: Set<String> = []
        for segment in plan.setup + [plan.execution] + plan.observations + plan.cleanup {
            for operation in segment.hostProgram?.operations ?? [] where operation.kind == .invoke {
                guard let action = catalog.systemActions.first(where: { $0.id == operation.typeID }) else { continue }
                let bound = Set((segment.inputBindings ?? []).filter { $0.destination == .hostParameter && $0.operationID == operation.id }.map(\.name))
                for parameter in action.parameters where parameter.family == family && (operation.parameters[parameter.name] != nil || bound.contains(parameter.name)) {
                    result.insert(operation.typeID + ":" + parameter.name)
                }
            }
        }
        return result
    }

    static func applying(_ profile: CapabilityProfile, required: Set<String>, members: [String: Set<String>], evidence: [String]) -> CapabilityProfile {
        var result = profile
        for (family, qualifiedMembers) in members {
            let key = "apple.codec." + family
            guard required.contains(key), !qualifiedMembers.isEmpty,
                  result.records[key] == nil || result.records[key]?.state == .unknown else { continue }
            result.records[key] = .init(state: .available, reason: "Exact native intent input members passed read-only round trips and released their owned host",
                probeVersion: probeVersion, evidence: evidence)
        }
        return result
    }

    private static func signatures(_ prepared: AutomationPreparedApplication, developer: URL, workspace: URL) async throws -> [String] {
        try AutomationMacAppleRuntimeSnapshot.validatePreparedArtifacts(prepared.host)
        let host = URL(fileURLWithPath: prepared.host.hostBundlePath)
        let products = [URL(fileURLWithPath: prepared.host.subjectProductPath), host,
            host.appendingPathComponent("Contents/PlugIns/" + prepared.host.testTarget + ".xctest")]
        var result: [String] = []
        for product in products {
            for arguments in [["--verify", "--strict", product.path], ["-dv", "--verbose=4", product.path]] {
                let output = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: arguments,
                    directory: workspace, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": developer.path], timeout: .seconds(15))
                guard output.exitStatus == 0, !output.logsTruncated else { throw AutomationContractError.missingEvidence("Native adapter requires verified signed subject and host products") }
                if arguments.first == "-dv" {
                    let lines = String(decoding: output.stderr, as: UTF8.self).split(separator: "\n").map(String.init)
                        .filter { $0.hasPrefix("Identifier=") || $0.hasPrefix("CDHash=") || $0.hasPrefix("TeamIdentifier=") || $0.hasPrefix("Signature=") }
                    guard lines.contains(where: { $0.hasPrefix("CDHash=") }), lines.contains(where: { $0.hasPrefix("Identifier=") }) else {
                        throw AutomationContractError.missingEvidence("Native adapter code identity is unavailable")
                    }
                    result.append(lines.sorted().joined(separator: "\n"))
                }
            }
        }
        return result
    }
}

actor AutomationNativeCodecAuthority {
    static let shared = AutomationNativeCodecAuthority()
    private var evidence: [AutomationNativeCodecQualification.Evidence] = []
    func register(_ value: AutomationNativeCodecQualification.Evidence) throws {
        guard value.report.resourcesReleased, value.report.failure == nil, value.report.artifact != nil,
              let observation = value.report.observation, observation.runtimeObservation == value.context.snapshot.observation,
              value.parameters.allSatisfy({ parameter in
                  guard let actual = observation.echoedSamples[parameter.name], actual.count == parameter.samples.count else { return false }
                  if parameter.family == "intentFile" {
                      return zip(actual, parameter.samples).allSatisfy { actual, expected in
                          guard case .artifact(_, let actualDigest) = actual, case .artifact(_, let expectedDigest) = expected else { return false }
                          return actualDigest == expectedDigest
                      }
                  }
                  return actual == parameter.samples
              }), value.expires > ContinuousClock.now else {
            throw AutomationContractError.missingEvidence("Only an exact released live native round trip can qualify inputs")
        }
        evidence.append(value)
        if evidence.count > 32 { evidence.removeFirst() }
    }
    func enrich(_ profile: CapabilityProfile, host: AutomationPreparedAppleHost, plan: AutomationCase,
                developer: URL, workspace: URL) async throws -> CapabilityProfile {
        guard let prepared = evidence.last(where: { $0.prepared.host == host && $0.expires > ContinuousClock.now })?.prepared else {
            return AutomationNativeCodecQualification.strippingGrants(profile)
        }
        return try await enrich(profile, prepared: prepared, plan: plan, developer: developer, workspace: workspace)
    }
    func enrich(_ profile: CapabilityProfile, prepared: AutomationPreparedApplication, plan: AutomationCase,
                developer: URL, workspace: URL) async throws -> CapabilityProfile {
        let stripped = AutomationNativeCodecQualification.strippingGrants(profile)
        guard prepared.host.target.kind == .nativeMac else { return stripped }
        try AutomationPreparedProgramContract.validate(plan, catalog: prepared.catalog)
        evidence.removeAll { $0.expires <= ContinuousClock.now }
        let matches = evidence.filter { $0.prepared == prepared }
        var valid: [AutomationNativeCodecQualification.Evidence] = []
        for entry in matches {
            do {
                if let current = try await AutomationNativeCodecQualification.validateBeforeExpiry(entry, expires: entry.expires,
                    validation: { try await entry.context.validate(prepared: prepared, developer: developer, workspace: workspace) }) {
                    valid.append(current)
                }
            } catch { continue }
        }
        try Task.checkCancellation()
        let required = Set((plan.setup + [plan.execution] + plan.observations + plan.cleanup).flatMap(\.requiredCapabilities))
        valid.removeAll { $0.expires <= ContinuousClock.now }
        var admitted: [String: Set<String>] = [:]
        let families = Set(valid.flatMap { $0.parameters.map(\.family) })
        for family in families {
            let needed = AutomationNativeCodecQualification.members(plan: plan, catalog: prepared.catalog, family: family)
            let qualified = Set(valid.flatMap { entry in entry.parameters.filter { $0.family == family }.map { entry.actionID + ":" + $0.name } })
            let unsupported = (plan.setup + [plan.execution] + plan.observations + plan.cleanup).contains { segment in
                (segment.hostProgram?.operations ?? []).contains { operation in
                    if operation.resultCodec == family { return true }
                    let action = prepared.catalog.systemActions.first { $0.id == operation.typeID }
                    return action?.parameters.contains { $0.family == family && operation.parameters[$0.name] == .null } == true
                }
            }
            if !unsupported, !needed.isEmpty, needed.isSubset(of: qualified) { admitted[family] = needed }
        }
        guard valid.allSatisfy({ $0.expires > ContinuousClock.now }) else { return stripped }
        return AutomationNativeCodecQualification.applying(stripped, required: required, members: admitted,
            evidence: valid.compactMap { $0.report.observation?.receiptDigest }.sorted())
    }
}

private struct NativeCodecSubjectVerifier: AutomationSubjectVerifier {
    let subject: AutomationInstalledSubjectVerifier
    func verify(app: AppIdentity, target: TargetIdentity) async throws {
        try AutomationMacGUIIdentity.validate(target)
        try await subject.verify(app: app, target: target)
        try AutomationMacGUIIdentity.validate(target)
    }
}

#endif
