import Foundation
import CryptoKit
#if canImport(FoundationEvalsDeveloper)
import FoundationEvalsDeveloper
#endif

struct EvaluationDeveloperFeatureAdapter: EvaluationFeatureAdapter {
    let runID: UUID
    let runner: DeveloperRunnerSnapshot
    let feature: DeveloperFeatureDescriptor
    let client: DeveloperRunnerClient
    let timeout: Duration

    var displayName: String {
        "\(feature.displayName) on \(runner.identity.displayName)"
    }

    var environment: EvaluationEnvironment {
        .init(
            operatingSystem: runner.identity.operatingSystem,
            locale: runner.identity.localeIdentifier ?? "unknown",
            model: "App feature · \(feature.displayName)",
            modelContextSize: 0
        )
    }

    var developerExecution: EvaluationDeveloperExecution? {
        .init(
            runnerID: runner.id,
            runnerName: runner.identity.displayName,
            platform: runner.identity.platform.rawValue,
            operatingSystem: runner.identity.operatingSystem,
            hardwareModel: runner.identity.hardwareModel,
            appBundleIdentifier: runner.identity.appBundleIdentifier,
            appVersion: runner.identity.appVersion,
            featureID: feature.id,
            featureVersion: feature.version,
            protocolMajorVersion: runner.identity.protocolVersion.major,
            protocolMinorVersion: runner.identity.protocolVersion.minor
        )
    }

    func evaluate(_ input: EvaluationFeatureInput) async throws -> EvaluationFeatureOutput {
        try Task.checkCancellation()
        let wireInput = DeveloperTextFeatureInput(
            caseID: input.caseID,
            instructions: input.instructions,
            prompt: input.prompt,
            expected: input.expected,
            repetition: input.repetition
        )
        let request = DeveloperFeatureExecutionRequest(
            runID: runID,
            featureID: feature.id,
            featureVersion: feature.version,
            encodedInput: try JSONEncoder().encode(wireInput),
            inputTypeName: String(reflecting: DeveloperTextFeatureInput.self),
            deadline: Date().addingTimeInterval(timeout.timeInterval)
        )
        let result = try await client.execute(request, on: runner.id, timeout: timeout)
        if let failure = result.failure {
            throw failure
        }
        guard let output = result.output else {
            throw DeveloperExecutionFailure(
                code: .executionFailed,
                message: "The runner returned neither output nor an error."
            )
        }
        return EvaluationFeatureOutput(
            response: output.response,
            usage: .init(
                inputTokens: output.usage.inputTokens,
                outputTokens: output.usage.outputTokens
            ),
            structuredEvidence: .init(
                encodedValue: output.encodedValue,
                encodedValueTypeName: output.encodedValueTypeName,
                metadata: boundedMetadata(output.metadata)
            )
        )
    }

    private func boundedMetadata(_ metadata: [String: String]) -> [String: String] {
        var bounded: [String: String] = [:]
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }).prefix(64) {
            let boundedKey = String(key.prefix(256))
            guard bounded[boundedKey] == nil else { continue }
            bounded[boundedKey] = String(value.prefix(4_096))
        }
        return bounded
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

extension DeveloperExecutionFailure: EvaluationFeatureAdapterTerminalError {
    var evaluationTermination: EvaluationFeatureAdapterTermination? {
        switch code {
        case .cancelled:
            .init(reason: "developerRunner:cancelled", cancelled: true)
        case .deadlineExceeded:
            .init(reason: "developerRunner:deadlineExceeded", cancelled: false)
        case .disconnected:
            .init(reason: "developerRunner:disconnected", cancelled: false)
        default:
            nil
        }
    }
}

/// The combined scenario path deliberately ignores EvaluationFeatureInput's
/// assessment fields. The developer process receives only the frozen business
/// input, fixture reference, and per-attempt correlation.
struct ScenarioSubjectFeatureAdapter: EvaluationFeatureAdapter {
    let runID: UUID
    let caseID: UUID
    let runner: DeveloperRunnerSnapshot
    let feature: DeveloperFeatureDescriptor
    let binding: ScenarioFeatureBinding
    let fixture: ScenarioFixture
    let attemptIDs: [Int: UUID]
    let client: DeveloperRunnerClient
    let timeout: Duration

    var displayName: String { "\(feature.displayName) on \(runner.identity.displayName)" }

    var environment: EvaluationEnvironment {
        .init(operatingSystem: runner.identity.operatingSystem,
              locale: runner.identity.localeIdentifier ?? "unknown",
              model: "App feature · \(feature.displayName)", modelContextSize: 0)
    }

    var developerExecution: EvaluationDeveloperExecution? {
        .init(runnerID: runner.id, runnerName: runner.identity.displayName,
              platform: runner.identity.platform.rawValue,
              operatingSystem: runner.identity.operatingSystem,
              hardwareModel: runner.identity.hardwareModel,
              appBundleIdentifier: runner.identity.appBundleIdentifier,
              appVersion: runner.identity.appVersion,
              featureID: feature.id, featureVersion: feature.version,
              protocolMajorVersion: runner.identity.protocolVersion.major,
              protocolMinorVersion: runner.identity.protocolVersion.minor)
    }

    func evaluate(_ input: EvaluationFeatureInput) async throws -> EvaluationFeatureOutput {
        try Task.checkCancellation()
        guard input.caseID == caseID, let attemptID = attemptIDs[input.repetition],
              feature.id == binding.featureID,
              feature.subjectInputSchema != nil,
              feature.capabilityNames.contains(DeveloperSubjectInputSchema.capabilityName),
              try Self.interfaceDigest(feature) == binding.interfaceDigest else {
            throw DeveloperExecutionFailure(
                code: .unsupportedInputContract,
                message: "Rebuild and check support for this feature's declared subject-input contract."
            )
        }
        let payload = try ScenarioFeatureSubjectDigest.payload(binding: binding, fixture: fixture)
        let wire = DeveloperSubjectInput(
            caseID: caseID, attemptID: attemptID,
            businessInputs: try payload.businessInputs.mapValues(Self.subjectValue),
            fixtureReferences: payload.fixtureReferences.map {
                .init(identifier: $0.identifier, contractDigest: $0.contractDigest)
            }
        )
        try feature.subjectInputSchema?.validate(wire)
        let request = DeveloperFeatureExecutionRequest(
            id: attemptID, runID: runID, featureID: feature.id,
            featureVersion: feature.version,
            encodedInput: try JSONEncoder().encode(wire),
            inputTypeName: String(reflecting: DeveloperSubjectInput.self),
            inputContract: .subjectV1,
            deadline: Date().addingTimeInterval(timeout.timeInterval)
        )
        let result = try await client.execute(request, on: runner.id, timeout: timeout)
        if let failure = result.failure { throw failure }
        guard result.requestID == attemptID, result.runID == runID,
              result.featureID == feature.id, let output = result.output else {
            throw DeveloperExecutionFailure(code: .executionFailed,
                                            message: "The feature result did not match its planned attempt.")
        }
        var metadata = output.metadata
        metadata["intentlab.attemptID"] = attemptID.uuidString
        metadata["intentlab.caseID"] = caseID.uuidString
        metadata["intentlab.subjectInputDigest"] = try Self.subjectInputDigest(binding: binding, fixture: fixture)
        return .init(response: output.response,
                     usage: .init(inputTokens: output.usage.inputTokens,
                                  outputTokens: output.usage.outputTokens),
                     structuredEvidence: .init(encodedValue: output.encodedValue,
                                               encodedValueTypeName: output.encodedValueTypeName,
                                               metadata: metadata))
    }

    static func interfaceDigest(_ feature: DeveloperFeatureDescriptor) throws -> String {
        guard let schema = feature.subjectInputSchema else {
            throw DeveloperExecutionFailure(code: .unsupportedInputContract,
                                            message: "The feature has no declared subject-input schema.")
        }
        struct Interface: Encodable {
            var id: String
            var input: DeveloperSubjectInputSchema
            var outputTypeName: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Interface(id: feature.id,
                                                input: schema, outputTypeName: feature.outputTypeName))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stable business-input identity for fix/retest comparison. Execution correlation
    /// is deliberately excluded so a fresh case/attempt/run ID remains comparable.
    static func subjectInputDigest(binding: ScenarioFeatureBinding, fixture: ScenarioFixture) throws -> String {
        try ScenarioFeatureSubjectDigest.digest(binding: binding, fixture: fixture)
    }

    private static func subjectValue(_ value: ScenarioValue) throws -> DeveloperSubjectValue {
        switch value {
        case .null: .null
        case .string(let value): .string(value)
        case .boolean(let value): .boolean(value)
        case .integer(let value): .integer(value)
        case .number(let value): .number(value)
        case .array(let values): .array(try values.map(subjectValue))
        case .date, .enumeration, .entity:
            throw DeveloperExecutionFailure(code: .invalidInput,
                                            message: "This feature schema cannot encode the selected date, enum, or entity input. Declare a supported mapping in the app.")
        }
    }
}
