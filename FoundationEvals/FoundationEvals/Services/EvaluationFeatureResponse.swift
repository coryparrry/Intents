import Foundation
import FoundationModels

struct EvaluationFeatureTrace: Codable, Sendable {
    var customToolCalls: [EvaluationCustomToolCallTrace] = []
    var profileEvents: [String] = []
    var firstContentMilliseconds: Double? = nil
    var transcript: EvaluationTranscriptTrace? = nil
    var conversation: EvaluationConversationTrace? = nil
    var spotlightSearch: EvaluationSpotlightSearchTrace? = nil
    var builtinToolCalls: [EvaluationBuiltinToolTrace]? = nil
}

struct EvaluationFeatureResponse {
    var content: String
    var usage: LanguageModelSession.Usage
    var transcriptEntries: [Transcript.Entry]
    var firstContentMilliseconds: Double?

    /// Generates a text or schema-constrained response using the suite's streaming and model options.
    ///
    /// Structured output is validated before returning. Streaming publishes partial snapshots and
    /// returns collected usage, transcript entries, and the earliest measured visible-content time.
    /// Model, schema, stream, and cancellation failures propagate to the caller.
    static func generate(
        session: LanguageModelSession,
        prompt: Prompt,
        suite: EvaluationSuite,
        metadata: [String: any ConvertibleToGeneratedContent],
        onPartial: @Sendable (String) async -> Void = { _ in }
    ) async throws -> Self {
        var options = suite.modelConfiguration.generationOptions
        // A dynamic profile supplies its own changing tool policy.
        options.toolCallingMode = suite.features.profile.enabled ? nil
            : suite.modelConfiguration.toolCallingMode(
                hasTools: !suite.features.tools.isEmpty || suite.modelConfiguration.referenceMode == .lookupTool
                    || !suite.modelConfiguration.customizationSettings.visionSettings.isEmpty
                    || suite.features.spotlightSearch.enabled
            )
        let context = suite.modelConfiguration.contextOptions
        let schema = suite.features.outputFields.isEmpty ? nil
            : try EvaluationSchemaBuilder.schema(
                fields: suite.features.outputFields,
                name: "EvaluationOutput",
                definitions: suite.features.outputSchemaDefinitions,
                representNilExplicitlyInGeneratedContent:
                    suite.features.outputRepresentNilExplicitlyInGeneratedContent
            )
        if suite.features.streamResponse {
            var requestMetadata = metadata
            if suite.modelConfiguration.provider == .customHTTP {
                requestMetadata[EvaluationHTTPLiveResponseObserver.generationStartedMetadataKey] =
                    Date().timeIntervalSinceReferenceDate
            }
            if let schema {
                let response = try await collect(
                    session.streamResponse(to: prompt, schema: schema, options: options,
                                           contextOptions: context, metadata: requestMetadata),
                    text: { $0.rawContent.jsonString },
                    finalText: { $0.jsonString },
                    onPartial: onPartial
                )
                try validateStructuredContent(response.content, suite: suite)
                return response
            }
            return try await collect(
                session.streamResponse(
                    to: prompt,
                    options: options,
                    contextOptions: context,
                    metadata: requestMetadata
                ),
                text: { $0.content }, finalText: { $0 }, onPartial: onPartial
            )
        }
        if let schema {
            let response = try await session.respond(to: prompt, schema: schema, options: options,
                                                     contextOptions: context, metadata: metadata)
            try EvaluationSchemaValidator.validate(response.content, fields: suite.features.outputFields,
                definitions: suite.features.outputSchemaDefinitions,
                representNilExplicitlyInGeneratedContent: suite.features.outputRepresentNilExplicitlyInGeneratedContent)
            return Self(content: response.content.jsonString, usage: response.usage,
                        transcriptEntries: Array(response.transcriptEntries))
        }
        let response = try await session.respond(to: prompt, options: options,
                                                 contextOptions: context, metadata: metadata)
        return Self(content: response.content, usage: response.usage,
                    transcriptEntries: Array(response.transcriptEntries))
    }

    /// Parses generated JSON and validates its fields, definitions, and explicit-null policy against the suite.
    private static func validateStructuredContent(_ json: String, suite: EvaluationSuite) throws {
        try EvaluationSchemaValidator.validate(GeneratedContent(json: json), fields: suite.features.outputFields,
            definitions: suite.features.outputSchemaDefinitions,
            representNilExplicitlyInGeneratedContent: suite.features.outputRepresentNilExplicitlyInGeneratedContent)
    }

    /// Collects a response stream, publishing partial text at most once per 100 ms and then the collected final text.
    ///
    /// Cancellation is checked around callbacks. First-content timing excludes empty, `{}`, and
    /// `null` snapshots and uses the earlier app or provider measurement when both are available.
    private static func collect<Content: Generable>(
        _ stream: LanguageModelSession.ResponseStream<Content>,
        text: (LanguageModelSession.ResponseStream<Content>.Snapshot) -> String,
        finalText: (Content) -> String,
        onPartial: @Sendable (String) async -> Void
    ) async throws -> Self {
        let started = ContinuousClock.now
        var firstContent: Double?
        var lastPublication = started
        for try await snapshot in stream {
            try Task.checkCancellation()
            let visible = text(snapshot).trimmingCharacters(in: .whitespacesAndNewlines)
            if firstContent == nil, !visible.isEmpty, visible != "{}", visible != "null" {
                let elapsed = started.duration(to: .now).components
                firstContent = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            }
            if lastPublication.duration(to: .now) >= .milliseconds(100) {
                await onPartial(text(snapshot))
                try Task.checkCancellation()
                lastPublication = .now
            }
        }
        let response = try await stream.collect()
        try Task.checkCancellation()
        await onPartial(finalText(response.content))
        try Task.checkCancellation()
        let providerFirstContent = response.transcriptEntries.compactMap { entry -> Double? in
            guard case .response(let response) = entry,
                  let value = response.metadata[
                    EvaluationHTTPLiveResponseObserver.firstContentMetadataKey
                  ] else {
                return nil
            }
            return try? JSONDecoder().decode(Double.self, from: Data(value.jsonString.utf8))
        }.min()
        let measuredFirstContent = [firstContent, providerFirstContent].compactMap { $0 }.min()
        return Self(content: finalText(response.content), usage: response.usage,
                    transcriptEntries: Array(response.transcriptEntries),
                    firstContentMilliseconds: measuredFirstContent)
    }
}
