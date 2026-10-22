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

    static func validationIssue(for feature: DeveloperFeatureDescriptor) -> String? {
        if feature.subjectInputSchema != nil
            || feature.capabilityNames.contains(DeveloperSubjectInputSchema.capabilityName) {
            return "\(feature.displayName) requires business inputs. Choose a text feature for this suite."
        }
        // Historical text registrations have no capability/schema metadata.
        // Their declared input type is sufficient; arbitrary typed registrations
        // need their own mapping instead of receiving a text payload by accident.
        // The desktop embeds the SDK sources in its own module; app runners
        // normally import the FoundationEvalsDeveloper package instead.
        let textTypes = [
            "FoundationEvalsDeveloper.DeveloperTextFeatureInput",
            String(reflecting: DeveloperTextFeatureInput.self),
            String(describing: DeveloperTextFeatureInput.self)
        ]
        guard textTypes.contains(feature.inputTypeName) else {
            return "\(feature.displayName) uses a different input format. Choose a feature registered with registerTextFeature to run text cases."
        }
        return nil
    }

    static func validate(_ feature: DeveloperFeatureDescriptor) throws {
        if let issue = validationIssue(for: feature) {
            throw DeveloperExecutionFailure(code: .unsupportedInputContract, message: issue)
        }
    }

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
        try Self.validate(feature)
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
