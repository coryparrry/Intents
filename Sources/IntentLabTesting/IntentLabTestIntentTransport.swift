import Foundation
import IntentLabContracts

/// Result from the app-owned test-only App Intent transport. Receipts and state
/// evidence must be read independently from the application integration.
public struct IntentLabTestIntentResult {
    public static let observationSource = "testOnlyIntentTransport"

    public let observations: [String: IntentLabValue]
    public let source: String

    init(observations: [String: IntentLabValue]) {
        self.observations = observations
        source = Self.observationSource
    }
}

/// Invokes the exact test-only intent selected by a negotiated app declaration.
/// The wrapper receives a bounded typed payload, operation ID, and attempt context.
@available(macOS 27.0, iOS 27.0, *)
@MainActor
public enum IntentLabTestIntentTransport {
    public static let maximumBusinessInputBytes = 256 * 1_024

    public static func invoke(
        bundleIdentifier: String,
        control: IntentLabIntegrationDeclaration.FeatureControl,
        parameters: [IntentLabParameter],
        context: String
    ) async throws -> IntentLabTestIntentResult {
        try control.validate()
        guard !bundleIdentifier.isEmpty, !context.isEmpty else {
            throw IntentLabTestIntentTransportError.invalidContext
        }

        let validatedParameters = try validate(parameters, against: control.parameters)
        let businessInput = IntentLabLocalFeatureInput(
            featureID: control.featureID,
            interfaceDigest: control.interfaceDigest,
            parameters: validatedParameters
        )
        let inputData = try JSONEncoder.intentLab.encode(businessInput)
        guard inputData.count <= maximumBusinessInputBytes,
              let inputText = String(data: inputData, encoding: .utf8) else {
            throw IntentLabTestIntentTransportError.businessInputTooLarge
        }

        let stringType = IntentLabValueType.primitive(.string)
        let wrapperParameters = [
            IntentLabParameter(
                name: "operationID", type: stringType, isOptional: false,
                presence: .value(.string(control.operationID))
            ),
            IntentLabParameter(
                name: "businessInput", type: stringType, isOptional: false,
                presence: .value(.string(inputText))
            ),
            IntentLabParameter(
                name: "context", type: stringType, isOptional: false,
                presence: .value(.string(context))
            ),
        ]
        let featureResponse = IntentLabIntegrationDeclaration.Projection(
            id: "feature.response",
            type: .primitive(.string),
            path: [
                .init(kind: .property, name: "value"),
                .init(kind: .property, name: "response"),
            ]
        )
        let observations = try await IntentProbe.invokeTestIntent(
            bundleIdentifier: bundleIdentifier,
            intentIdentifier: control.testIntentIdentifier,
            parameters: wrapperParameters,
            outputProjections: [featureResponse] + control.outputProjections
        )
        return IntentLabTestIntentResult(observations: observations)
    }

    /// Convenience for CoreTesting callers whose frozen feature binding already
    /// resolved values by name. Missing optional inputs remain missing; null is
    /// preserved as a distinct typed value.
    public static func invoke(
        bundleIdentifier: String,
        control: IntentLabIntegrationDeclaration.FeatureControl,
        parameters: [String: IntentLabValue],
        context: String
    ) async throws -> IntentLabTestIntentResult {
        let typedParameters = control.parameters.compactMap { declaration -> IntentLabParameter? in
            guard let value = parameters[declaration.name] else { return nil }
            return IntentLabParameter(
                name: declaration.name,
                type: declaration.type,
                isOptional: !declaration.required,
                presence: .value(value)
            )
        }
        guard parameters.keys.allSatisfy({ key in
            control.parameters.contains(where: { $0.name == key })
        }) else {
            throw IntentLabTestIntentTransportError.invalidBusinessInput
        }
        return try await invoke(
            bundleIdentifier: bundleIdentifier,
            control: control,
            parameters: typedParameters,
            context: context
        )
    }

    private static func validate(
        _ supplied: [IntentLabParameter],
        against declarations: [IntentLabIntegrationDeclaration.Parameter]
    ) throws -> [IntentLabParameter] {
        guard Set(supplied.map(\.name)).count == supplied.count else {
            throw IntentLabTestIntentTransportError.invalidBusinessInput
        }
        let suppliedByName = Dictionary(uniqueKeysWithValues: supplied.map { ($0.name, $0) })
        guard suppliedByName.keys.allSatisfy({ key in declarations.contains(where: { $0.name == key }) }) else {
            throw IntentLabTestIntentTransportError.invalidBusinessInput
        }

        return try declarations.map { declaration in
            let parameter = suppliedByName[declaration.name] ?? IntentLabParameter(
                name: declaration.name,
                type: declaration.type,
                isOptional: !declaration.required,
                presence: .missing
            )
            guard parameter.type == declaration.type,
                  parameter.isOptional == !declaration.required else {
                throw IntentLabTestIntentTransportError.invalidBusinessInput
            }
            switch parameter.presence {
            case .missing:
                guard !declaration.required else {
                    throw IntentLabTestIntentTransportError.invalidBusinessInput
                }
            case .value(.null):
                guard !declaration.required else {
                    throw IntentLabTestIntentTransportError.invalidBusinessInput
                }
            case .value(let value):
                guard declaration.type.accepts(value) else {
                    throw IntentLabTestIntentTransportError.invalidBusinessInput
                }
            }
            return parameter
        }
    }
}

public enum IntentLabTestIntentTransportError: LocalizedError {
    case invalidContext
    case invalidBusinessInput
    case businessInputTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidContext:
            "The local feature test intent needs an app bundle identifier and attempt context."
        case .invalidBusinessInput:
            "The local feature inputs do not match the app's declared typed interface."
        case .businessInputTooLarge:
            "The local feature inputs exceed the test intent payload limit."
        }
    }
}
