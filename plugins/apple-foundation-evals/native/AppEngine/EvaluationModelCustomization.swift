import Foundation

@available(macOS 27.0, *)
enum EvaluationSystemUseCase: String, Codable, CaseIterable, Identifiable, Sendable {
    case general, contentTagging
    var id: Self { self }
    var title: String { self == .general ? "General" : "Content tagging" }
}

@available(macOS 27.0, *)
enum EvaluationGuardrails: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, permissiveContentTransformations
    var id: Self { self }
    var title: String { self == .standard ? "Default" : "Permissive text transformations" }
}

@available(macOS 27.0, *)
enum EvaluationSchemaPromptPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case included, automatic, omitted
    var id: Self { self }
    var title: String {
        switch self {
        case .included: "Include schema"
        case .automatic: "Framework default"
        case .omitted: "Omit schema"
        }
    }
    var value: Bool? {
        switch self {
        case .included: true
        case .automatic: nil
        case .omitted: false
        }
    }
}

@available(macOS 27.0, *)
enum EvaluationToolCallingPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, allowed, required, disallowed
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

@available(macOS 27.0, *)
enum EvaluationTranscriptErrorPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, preserve, revert
    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: "Framework default"
        case .preserve: "Preserve failed request"
        case .revert: "Revert failed request"
        }
    }
}

@available(macOS 27.0, *)
struct EvaluationModelCustomization: Codable, Equatable, Sendable {
    var useCase: EvaluationSystemUseCase = .general
    var guardrails: EvaluationGuardrails = .standard
    var schemaPrompt: EvaluationSchemaPromptPolicy = .included
    var toolCalling: EvaluationToolCallingPolicy = .automatic
    var customReasoning: String? = nil
    var transcriptErrorPolicy: EvaluationTranscriptErrorPolicy? = nil
    var saveFullTranscript: Bool? = nil
    var prewarmPrefix: String? = nil
    var prewarmLeadSeconds: Double? = nil
    var visionTools: EvaluationVisionToolConfiguration? = nil

    var visionSettings: EvaluationVisionToolConfiguration {
        get { visionTools ?? .init() }
        set { visionTools = newValue }
    }

    var captureTranscript: Bool {
        get { saveFullTranscript ?? false }
        set { saveFullTranscript = newValue }
    }
    var errorPolicy: EvaluationTranscriptErrorPolicy {
        get { transcriptErrorPolicy ?? .automatic }
        set { transcriptErrorPolicy = newValue }
    }
    var warmupSeconds: Double {
        get { prewarmLeadSeconds ?? 0 }
        set { prewarmLeadSeconds = newValue }
    }
    var warmupPrefix: String {
        get { prewarmPrefix ?? "" }
        set { prewarmPrefix = newValue }
    }
    var reasoningName: String {
        get { customReasoning ?? "" }
        set { customReasoning = newValue }
    }
    var validationIssue: String? {
        if !warmupSeconds.isFinite || !(0...10).contains(warmupSeconds) {
            return "Prewarm lead time must be between zero and ten seconds."
        }
        if warmupPrefix.utf8.count > 4_096 { return "Prewarm prefix must be 4,096 UTF-8 bytes or fewer." }
        if reasoningName.utf8.count > 128 { return "Custom reasoning name must be 128 UTF-8 bytes or fewer." }
        return nil
    }
}

@available(macOS 27.0, *)
extension EvaluationModelConfiguration {
    var customProviderSettings: EvaluationCustomProviderConfiguration {
        get { customProvider ?? .init() }
        set { customProvider = newValue }
    }
    var coreAISettings: EvaluationCoreAIConfiguration {
        get { coreAI ?? .init() }
        set { coreAI = newValue }
    }
    var customizationSettings: EvaluationModelCustomization {
        get { customization ?? .init() }
        set { customization = newValue }
    }
}
