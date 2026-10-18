#if os(macOS)
import Foundation
import IntentsAutomationCore
import IntentsAutomationCLIResources

struct AutomationCLICommand: Equatable {
    enum Operation: String { case prepare, actions, run, show, compare }
    let operation: Operation
    var options: [String: String]
    var attemptID: String?

    static func parse(_ arguments: [String]) throws -> Self {
        guard let first = arguments.first, let operation = Operation(rawValue: first) else {
            throw AutomationContractError.invalidPlan("Use prepare, actions, run --plan <file>, show <attempt>, or compare --baseline-support <root> --baseline-attempt <ID> --support-root <candidate-root> [--attempts 3]")
        }
        let allowed: Set<String>
        switch operation {
        case .prepare: allowed = ["--project", "--scheme", "--target", "--destination", "--xcode", "--support-root"]
        case .run: allowed = ["--plan", "--support-root"]
        case .actions, .show: allowed = ["--support-root"]
        case .compare: allowed = ["--baseline-support", "--baseline-attempt", "--support-root", "--attempts"]
        }
        var options: [String: String] = [:], attempt: String?, index = 1
        while index < arguments.count {
            let key = arguments[index]
            if allowed.contains(key) {
                guard options[key] == nil, index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--"), !arguments[index + 1].isEmpty else {
                    throw AutomationContractError.invalidPlan("Missing or duplicate option: " + key)
                }
                options[key] = arguments[index + 1]; index += 2
            } else if operation == .show, attempt == nil, !key.hasPrefix("--") {
                attempt = key; index += 1
            } else { throw AutomationContractError.invalidPlan("Unexpected argument: " + key) }
        }
        switch operation {
        case .prepare:
            guard options["--project"] != nil, options["--destination"] != nil,
                  (options["--scheme"] != nil) != (options["--target"] != nil) else {
                throw AutomationContractError.invalidPlan("Preparation needs --project, one of --scheme/--target, and --destination")
            }
        case .run:
            guard options["--plan"] != nil else { throw AutomationContractError.invalidPlan("Run needs --plan") }
        case .show:
            guard let attempt else { throw AutomationContractError.invalidPlan("Show needs an attempt ID") }
            try AutomationCLI.validateAttemptID(attempt)
        case .actions: break
        case .compare:
            guard options["--baseline-support"] != nil, let attempt = options["--baseline-attempt"],
                  options["--support-root"] != nil else {
                throw AutomationContractError.invalidPlan("Compare needs --baseline-support, --baseline-attempt and --support-root")
            }
            try AutomationCLI.validateAttemptID(attempt)
            _ = try AutomationCLI.comparisonAttempts(options["--attempts"])
        }
        return .init(operation: operation, options: options, attemptID: attempt)
    }
}

struct AutomationCLIRunEnvelope: Decodable {
    let schemaVersion: Int
    let attemptID: String
    let allowBootAndInstall: Bool
    let disposable: Bool
    var plan: AutomationCase

    static func decode(_ data: Data) throws -> Self {
        try AutomationCLI.rejectCapabilityRecords(data)
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1 else { throw AutomationContractError.invalidPlan("Unsupported run envelope schema") }
        try AutomationCLI.validateAttemptID(value.attemptID)
        return value
    }
}

enum AutomationCLI {
    static var defaultSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FoundationEvals/Automation", isDirectory: true)
    }
    static func execute(_ arguments: [String]) async throws -> Bool {
        let command = try AutomationCLICommand.parse(arguments)
        var support = try supportRoot(command.options["--support-root"])
        switch command.operation {
        case .prepare:
            let project = try AutomationPath.canonical(URL(fileURLWithPath: command.options["--project"]!))
            guard project.pathExtension == "xcodeproj" else { throw AutomationContractError.invalidPlan("Select an .xcodeproj") }
            let assessment = try AutomationApplicationIntake.assess(project)
            let ids = try command.options["--scheme"].map { try schemeTargetIDs(project: project, scheme: $0) }
            let candidate = try selectCandidate(assessment.candidates, target: command.options["--target"], schemeIDs: ids)
            let developer = try developerDirectory(command.options["--xcode"])
            var target = try destination(command.options["--destination"]!)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            support = try AutomationPath.canonical(support)
            if target.kind == .physical {
                target = try await AutomationPhysicalDeviceInventory.canonicalTarget(target, developerDirectory: developer, workspace: support)
            }
            let approval = AutomationBuildApproval(sourceRoot: project.deletingLastPathComponent().path,
                candidateID: candidate.id, configuration: "Debug", target: target)
            let prepared = try await AutomationPreparation().prepare(candidate: candidate, approval: approval,
                sessionRoot: support.appendingPathComponent("prepare-" + UUID().uuidString),
                templates: AutomationCLIResources.hostTemplates(), developerDirectory: developer,
                requireConfiguredDeveloperDirectory: command.options["--xcode"] != nil)
            try writeJSON(prepared)
        case .actions:
            try writeJSON(loadPrepared(support).catalog)
        case .run:
            var envelope = try AutomationCLIRunEnvelope.decode(read(command.options["--plan"]!, maximumBytes: 2_097_152))
            let prepared = try loadPrepared(support)
            try attachPreparedEvidence(to: &envelope.plan, prepared: prepared)
            let approval = try deriveExactRunApproval(envelope)
            let developer = try prepared.sourceGraph?.platformContext.map { URL(fileURLWithPath: $0.developerDirectory) }
                ?? developerDirectory(nil)
            let runner = try AutomationApplicationRunner(supportRoot: support, developerDirectory: developer)
            let base = AutomationPreparedCapabilities.base(prepared)
            let capabilities = try await runner.capabilitiesForExecution(subject: .prepared(prepared), plan: envelope.plan, capabilities: base)
            let report = try await runner.run(prepared: prepared, plan: envelope.plan, approval: approval,
                capabilities: capabilities, attemptID: envelope.attemptID, allowBootAndInstall: envelope.allowBootAndInstall)
            try writeJSON(report)
            return exitStatus(report) == 0
        case .show:
            try writeJSON(await show(attemptID: command.attemptID!, supportRoot: support))
        case .compare:
            let baselineSupport = try supportRoot(command.options["--baseline-support"]!)
            let result = try await compare(baselineSupport: baselineSupport,
                originalAttemptID: command.options["--baseline-attempt"]!, support: support,
                attempts: comparisonAttempts(command.options["--attempts"]))
            try writeJSON(result)
            // A completed comparison is a successful command, including an observed unfixed case.
            return result.report.complete
        }
        return true
    }

    static func supportRoot(_ path: String?) throws -> URL {
        let selected = path.map { URL(fileURLWithPath: $0) } ?? defaultSupportRoot
        // Share Core's realpath identity. Foundation resolves /private/tmp
        // to /tmp on macOS, which is not the retained preparation identity.
        if FileManager.default.fileExists(atPath: selected.path) { return try AutomationPath.canonical(selected) }
        return selected
    }
    static func loadPrepared(_ support: URL) throws -> AutomationPreparedApplication {
        guard let prepared = try AutomationPreparedApplicationRecord.loadLatest(supportRoot: support) else {
            throw AutomationContractError.missingEvidence("Prepare an app before listing actions or running a plan")
        }
        return prepared
    }
    static func developerDirectory(_ path: String?,
                                   environment: [String: String] = ProcessInfo.processInfo.environment,
                                   selection: () throws -> String = selectedDeveloperDirectory) throws -> URL {
        let selected = try path ?? environment["DEVELOPER_DIR"] ?? selection()
        guard !selected.isEmpty else { throw AutomationContractError.invalidPlan("No Xcode developer directory is selected") }
        let url = URL(fileURLWithPath: selected)
        return url.pathExtension == "app" ? url.appendingPathComponent("Contents/Developer") : url
    }
    private static func selectedDeveloperDirectory() throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8) else {
            throw AutomationContractError.invalidPlan("Cannot read the selected Xcode developer directory; use --xcode")
        }
        return path.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func destination(_ value: String) throws -> TargetIdentity {
        if value == "mac" { return try AutomationMacGUIIdentity.currentTarget() }
        if value.hasPrefix("sim:"), let id = UUID(uuidString: String(value.dropFirst(4))) {
            return .init(id: id.uuidString, kind: .simulator)
        }
        if value.hasPrefix("device:") {
            let id = String(value.dropFirst(7))
            guard id.range(of: #"^[A-Za-z0-9-]{1,128}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
            return .init(id: id, kind: .physical)
        }
        throw AutomationContractError.invalidPlan("Use sim:<UUID>, device:<ID>, or mac")
    }
    static func selectCandidate(_ candidates: [AutomationApplicationCandidate], target: String?, schemeIDs: Set<String>?) throws -> AutomationApplicationCandidate {
        let matches = candidates.filter { candidate in
            if let target { return candidate.kind == .sourceTarget && [candidate.id, candidate.targetID, candidate.name].contains(target) }
            return candidate.kind == .sourceTarget && candidate.targetID.map { schemeIDs?.contains($0) == true } == true
        }
        guard matches.count == 1 else { throw AutomationContractError.invalidPlan("Selection must identify exactly one application target") }
        return matches[0]
    }
    static func validateAttemptID(_ value: String) throws {
        guard value.range(of: #"^[A-Za-z0-9-]{1,128}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
    }
    static func rejectCapabilityRecords(_ data: Data) throws {
        func visit(_ value: Any, parentKey: String? = nil) throws {
            if let object = value as? [String: Any] {
                if let encoded = try? JSONSerialization.data(withJSONObject: object),
                   (try? JSONDecoder().decode(AutomationValue.self, from: encoded)) != nil { return }
                if let encoded = try? JSONSerialization.data(withJSONObject: object),
                   (try? JSONDecoder().decode(CapabilityProfile.Record.self, from: encoded)) != nil {
                    throw AutomationContractError.invalidPlan("Supplied capability records cannot authorise execution")
                }
                if object["records"] != nil,
                   let encoded = try? JSONSerialization.data(withJSONObject: object),
                   (try? JSONDecoder().decode(CapabilityProfile.self, from: encoded)) != nil {
                    throw AutomationContractError.invalidPlan("Supplied capability records cannot authorise execution")
                }
                for (key, child) in object {
                    if key == "capabilities" {
                        // Business parameters may have this name, but their values
                        // must be genuine tagged values or provided action inputs.
                        let encoded = try? JSONSerialization.data(withJSONObject: child, options: [.fragmentsAllowed])
                        let typedValue = encoded.flatMap { try? JSONDecoder().decode(AutomationValue.self, from: $0) }
                        let inputObject = child as? [String: Any]
                        let typedInput = inputObject.map { Set($0.keys) == ["value", "origin", "evidence"] } == true
                            && encoded.flatMap { try? JSONDecoder().decode(AutomationActionInput.self, from: $0) } != nil
                        let typedBusinessInput = ["inputs", "parameters"].contains(parentKey ?? "") && (typedValue != nil || typedInput)
                        let stringBusinessMetadata = ["parameterCodecs", "properties", "bindings", "attemptTextBindings", "provenance"].contains(parentKey ?? "") && child is String
                        guard typedBusinessInput || stringBusinessMetadata else {
                            throw AutomationContractError.invalidPlan("Remove capabilities; the app runner resolves them from retained preparation evidence")
                        }
                    } else { try visit(child, parentKey: key) }
                }
            } else if let array = value as? [Any] { for child in array { try visit(child, parentKey: parentKey) } }
        }
        try visit(JSONSerialization.jsonObject(with: data))
    }
    static func exitStatus(_ report: AutomationAttemptReport) -> Int { report.executionSucceeded ? 0 : 1 }
    static func attachPreparedEvidence(to plan: inout AutomationCase, prepared: AutomationPreparedApplication) throws {
        guard plan.app == prepared.host.app, plan.target == prepared.host.target else { throw AutomationContractError.conflictingOperation }
        if plan.target.kind == .simulator {
            let artifacts = try AutomationPreparedSimulatorBuildArtifacts(prepared: prepared)
            guard plan.preparedSimulatorBuildArtifacts == nil || plan.preparedSimulatorBuildArtifacts == artifacts,
                  plan.preparedMacBuildArtifacts == nil else { throw AutomationContractError.conflictingOperation }
            plan.preparedSimulatorBuildArtifacts = artifacts
            for key in ["ui.preparedHostDigest", "ui.preparedXctestrunDigest", "ui.preparedCatalogDigest", "ui.hostTemplateDigest"] {
                plan.provenance.removeValue(forKey: key)
            }
        } else if plan.target.kind == .nativeMac {
            let artifacts = try AutomationPreparedMacBuildArtifacts(prepared: prepared)
            guard plan.preparedMacBuildArtifacts == nil || plan.preparedMacBuildArtifacts == artifacts,
                  plan.preparedSimulatorBuildArtifacts == nil else { throw AutomationContractError.conflictingOperation }
            plan.preparedMacBuildArtifacts = artifacts
        }
    }
    /// Authority comes only from this invocation's exact plan and flags.
    static func deriveExactRunApproval(_ envelope: AutomationCLIRunEnvelope) throws -> RunApproval {
        let plan = envelope.plan, segments = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        guard plan.schemaVersion == 3, !plan.environmentID.isEmpty else { throw AutomationContractError.invalidIdentity }
        let effects = segments.reduce(into: Set<AutomationEffect>()) { $0.formUnion($1.effects) }
        guard !effects.contains(.reset) || envelope.disposable else { throw AutomationContractError.invalidPlan("Reset requires a disposable run") }
        let count = segments.reduce(0) { result, segment in
            if plan.target.kind == .nativeMac, let program = segment.uiProgram {
                let actions: Int
                if let steps = program.steps {
                    actions = steps.filter { [.launch, .tap, .typeText, .clearAndType, .swipe].contains($0.kind) }.count
                } else {
                    actions = 1 + program.operations.filter { [.tap, .fillBinding, .scroll].contains($0.kind) }.count
                }
                return result + actions
            }
            return result + (segment.hostProgram?.operations.count ?? segment.uiProgram?.steps?.count ?? segment.uiProgram?.operations.count ?? 1)
        }
        var approval = RunApproval(runID: envelope.attemptID, app: plan.app, target: plan.target,
            environmentID: plan.environmentID, effects: effects, maximumActions: count,
            disposable: envelope.disposable, approvedCaseDigest: try AutomationFrozenCase.planDigest(plan))
        if segments.contains(where: { $0.usesUIControl }) || plan.target.kind != .simulator {
            // Include the generator's launch, freshness and final screenshot steps.
            approval.maximumActions = 1000
            let assembledCount = try AutomationXCUITestPlan.assemble(plan: plan, approval: approval,
                attemptID: envelope.attemptID, leaseGeneration: 1).steps.count
            approval.maximumActions = max(count, assembledCount)
        }
        guard approval.maximumActions > 0, approval.maximumActions <= 1000 else {
            throw AutomationContractError.invalidPlan("Plan action count is out of bounds")
        }
        return approval
    }
    static func show(attemptID: String, supportRoot: URL) async throws -> AutomationAttemptReport {
        try await savedAttempt(attemptID: attemptID, supportRoot: supportRoot).1
    }
    static func savedAttempt(attemptID: String, supportRoot: URL) async throws -> (AutomationFrozenCase, AutomationAttemptReport) {
        try validateAttemptID(attemptID)
        let root = supportRoot.appendingPathComponent("Cases")
        let store = try AutomationCaseStore(readOnlyRoot: root)
        var matches: [(AutomationFrozenCase, AutomationAttemptReport)] = []
        for frozen in try await store.definitions() {
            let path = root.appendingPathComponent("Attempts/" + frozen.digest + "/" + attemptID + ".json")
            if FileManager.default.fileExists(atPath: path.path) {
                matches.append((frozen, try await store.loadAttempt(id: attemptID, frozen: frozen)))
            }
        }
        guard matches.count == 1 else { throw AutomationContractError.missingEvidence("Attempt must identify exactly one saved report") }
        return matches[0]
    }
    static func read(_ path: String, maximumBytes: Int) throws -> Data {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard maximumBytes > 0, maximumBytes < Int.max, values.isRegularFile == true,
              let size = values.fileSize, size <= maximumBytes else { throw AutomationContractError.invalidIdentity }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count == size, data.count <= maximumBytes else { throw AutomationContractError.conflictingOperation }
        return data
    }
    static func writeJSON<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(value) + Data([10]))
    }
    static func writeError(_ error: Error) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let bytes = try? encoder.encode(["error": String(describing: error)]) {
            try? FileHandle.standardError.write(contentsOf: bytes + Data([10]))
        }
    }
}
#endif
