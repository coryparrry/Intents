import Foundation
import FoundationModels

/// Saved settings for a developer-owned Foundation Models provider on this Mac.
///
/// The suite keeps this optional and selects it explicitly. Constructing the value does not
/// contact the endpoint; the executor performs one request only when a model response is run.
@available(macOS 27.0, *)
struct EvaluationCustomProviderConfiguration: Codable, Equatable, Hashable, Sendable {
    static let defaultEndpoint = "http://127.0.0.1:19096/generate"

    var endpoint = defaultEndpoint
    /// Optional endpoint that accepts the generation envelope and returns the
    /// provider's exact input-token count before generation.
    var tokenizerEndpoint: String? = nil
    var contextSize = 8_192
    var supportsVision = false
    var supportsGuidedGeneration = false
    var supportsReasoning = false
    var supportsToolCalling = false
    var requestTimeoutSeconds = 30.0

    var capabilities: LanguageModelCapabilities {
        var declared: [LanguageModelCapabilities.Capability] = []
        if supportsVision { declared.append(.vision) }
        if supportsGuidedGeneration { declared.append(.guidedGeneration) }
        if supportsReasoning { declared.append(.reasoning) }
        if supportsToolCalling { declared.append(.toolCalling) }
        return LanguageModelCapabilities(declared)
    }

    var capabilityNames: [String] {
        [
            supportsVision ? "vision" : nil,
            supportsGuidedGeneration ? "guided generation" : nil,
            supportsReasoning ? "reasoning" : nil,
            supportsToolCalling ? "tool calling" : nil
        ].compactMap { $0 }
    }

    var protocolCapabilityNames: [String] {
        [
            supportsVision ? "vision" : nil,
            supportsGuidedGeneration ? "guidedGeneration" : nil,
            supportsReasoning ? "reasoning" : nil,
            supportsToolCalling ? "toolCalling" : nil
        ].compactMap { $0 }
    }

    var validationIssue: String? {
        guard (1...262_144).contains(contextSize) else {
            return "Custom provider context size must be between 1 and 262,144 tokens."
        }
        guard requestTimeoutSeconds.isFinite, (0.1...60).contains(requestTimeoutSeconds) else {
            return "Custom provider timeout must be between 0.1 and 60 seconds."
        }
        guard endpoint.utf8.count <= 2_048 else {
            return "Custom provider endpoint must be 2,048 UTF-8 bytes or fewer."
        }
        guard let components = URLComponents(string: endpoint),
              components.scheme == "http",
              components.host == "127.0.0.1",
              let port = components.port,
              (1...65_535).contains(port),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return "Custom provider endpoint must use literal http://127.0.0.1:<port>/... without credentials, a query, or a fragment."
        }

        if let tokenizerEndpoint, !tokenizerEndpoint.isEmpty {
            guard tokenizerEndpoint.utf8.count <= 2_048 else {
                return "Custom provider tokenizer endpoint must be 2,048 UTF-8 bytes or fewer."
            }
            guard let tokenizerComponents = URLComponents(string: tokenizerEndpoint),
                  tokenizerComponents.scheme == "http",
                  tokenizerComponents.host == "127.0.0.1",
                  let tokenizerPort = tokenizerComponents.port,
                  (1...65_535).contains(tokenizerPort),
                  tokenizerComponents.user == nil,
                  tokenizerComponents.password == nil,
                  tokenizerComponents.query == nil,
                  tokenizerComponents.fragment == nil else {
                return "Custom provider tokenizer endpoint must use literal http://127.0.0.1:<port>/... without credentials, a query, or a fragment."
            }

        }
        return nil
    }

    var validatedEndpoint: URL? {
        guard validationIssue == nil else { return nil }
        return URL(string: endpoint)
    }

    var validatedTokenizerEndpoint: URL? {
        guard validationIssue == nil,
              let tokenizerEndpoint,
              !tokenizerEndpoint.isEmpty else { return nil }
        return URL(string: tokenizerEndpoint)
    }
}

/// A Foundation Models `LanguageModel` whose inference is supplied by a local HTTP process.
