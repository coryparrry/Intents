import Foundation
import IntentLabContracts

/// Typed result from the payload-free app readiness intent. The source marker
/// describes the transport; app state and action receipts remain separate.
public struct IntentLabReadinessTestIntentResult {
    public static let observationSource = "testOnlyIntentTransport"

    public let observations: [String: IntentLabValue]
    public let source: String

    init(observations: [String: IntentLabValue]) {
        self.observations = observations
        source = Self.observationSource
    }
}

/// Invokes only the fixed, declared readiness intent. It has no feature control,
/// business input, or operation dispatch path.
@available(macOS 27.0, iOS 27.0, *)
@MainActor
public enum IntentLabReadinessTestIntentTransport {
    public static func invoke(
        bundleIdentifier: String,
        declaration: IntentLabIntegrationDeclaration,
        context: String
    ) async throws -> IntentLabReadinessTestIntentResult {
        try await invoke(
            bundleIdentifier: bundleIdentifier,
            declaration: declaration,
            context: context,
            intentInvoker: { bundleIdentifier, intentIdentifier, parameters, projections in
                try await IntentProbe.invokeTestIntent(
                    bundleIdentifier: bundleIdentifier,
                    intentIdentifier: intentIdentifier,
                    parameters: parameters,
                    outputProjections: projections
                )
            }
        )
    }

    typealias IntentInvoker = @MainActor (
        String,
        String,
        [IntentLabParameter],
        [IntentLabIntegrationDeclaration.Projection]
    ) async throws -> [String: IntentLabValue]

    static func invoke(
        bundleIdentifier: String,
        declaration: IntentLabIntegrationDeclaration,
        context: String,
        intentInvoker: IntentInvoker
    ) async throws -> IntentLabReadinessTestIntentResult {
        guard !bundleIdentifier.isEmpty, !context.isEmpty else {
            throw IntentLabReadinessTestIntentTransportError.invalidContext
        }
        try declaration.validate()
        let control = try declaration.declaredReadinessControl()
        let stringType = IntentLabValueType.primitive(.string)
        let parameters = [IntentLabParameter(
            name: "context", type: stringType, isOptional: false,
            presence: .value(.string(context))
        )]
        let contextProjection = IntentLabIntegrationDeclaration.Projection(
            id: "readiness.context",
            type: stringType,
            path: [
                .init(kind: .property, name: "value"),
                .init(kind: .property, name: "context"),
            ]
        )
        let values = try await intentInvoker(
            bundleIdentifier,
            control.testIntentIdentifier,
            parameters,
            [control.response, contextProjection]
        )
        guard values[contextProjection.id] == .string(context),
              let ready = values[control.response.id], case .boolean(_) = ready else {
            throw IntentLabReadinessTestIntentTransportError.invalidResponse
        }
        return IntentLabReadinessTestIntentResult(
            observations: [control.response.id: ready]
        )
    }
}

public enum IntentLabReadinessTestIntentTransportError: LocalizedError {
    case invalidContext
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidContext:
            "The app readiness test intent needs a bundle identifier and unique context."
        case .invalidResponse:
            "The app readiness test intent returned a mismatched context or invalid typed response."
        }
    }
}
