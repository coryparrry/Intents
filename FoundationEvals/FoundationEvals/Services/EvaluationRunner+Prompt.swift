import Foundation
import FoundationModels

struct EvaluationInputTokenEstimate: Sendable {
    var count: Int
    var imageTokenCountAvailable: Bool
}

protocol EvaluationPromptInputTokenCounting: Sendable {
    /// Estimates a text prompt using an exact source-text key when the counter supports caching.
    func tokenCount(for prompt: Prompt, cacheKey: String) async throws -> Int
    /// Estimates frozen instructions using an exact source-text key when caching is available.
    func tokenCount(for instructions: Instructions, cacheKey: String) async throws -> Int
    /// Counts prompt input using the implementation's tokenizer or admission policy.
    func tokenCount(for prompt: Prompt) async throws -> Int
    /// Counts session instructions separately from the prompt.
    func tokenCount(for instructions: Instructions) async throws -> Int
    /// Counts the response schema included in input budgeting.
    func tokenCount(for schema: GenerationSchema) async throws -> Int
    /// Counts the model-facing transcript history used by admission.
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int
    /// Counts enabled tool definitions included in the request.
    func tokenCount(for tools: [any Tool]) async throws -> Int
    /// Counts text without requiring image attachment tokenization.
    func tokenCount(forText text: String) async throws -> Int
}

struct EvaluationSystemPromptInputTokenCounter: EvaluationPromptInputTokenCounting {
    /// Uses the default system model tokenizer for a prompt, propagating tokenizer failures.
    func tokenCount(for prompt: Prompt) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: prompt)
    }

    /// Uses the default system model tokenizer for session instructions.
    func tokenCount(for instructions: Instructions) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: instructions)
    }

    /// Uses the default system model tokenizer for a generation schema.
    func tokenCount(for schema: GenerationSchema) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: schema)
    }

    /// Uses the default system model tokenizer for transcript history.
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: history)
    }

    /// Uses the default system model tokenizer for enabled tool definitions.
    func tokenCount(for tools: [any Tool]) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: tools)
    }

    /// Wraps text in a prompt for the default system model tokenizer.
    func tokenCount(forText text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: Prompt(text))
    }
}

/// Custom HTTP providers declare their context size but do not expose the
/// Foundation Models tokenizer. Keep admission checks portable and conservative
/// instead of requiring Apple Intelligence just to estimate a request.
struct EvaluationPortablePromptInputTokenCounter: EvaluationPromptInputTokenCounting,
    EvaluationToolOutputTokenCounting,
    EvaluationCustomToolTokenCounting {
    /// Estimates representable tool output from the UTF-8 size of its description.
    func tokenCount<Output: PromptRepresentable>(for output: Output) async throws -> Int {
        Self.estimate(String(describing: output))
    }

    /// Estimates prompt input from the UTF-8 size of its description.
    func tokenCount(for prompt: Prompt) async throws -> Int {
        Self.estimate(String(describing: prompt))
    }

    /// Estimates instruction input from the UTF-8 size of its description.
    func tokenCount(for instructions: Instructions) async throws -> Int {
        Self.estimate(String(describing: instructions))
    }

    /// Estimates schema input from the UTF-8 size of its description.
    func tokenCount(for schema: GenerationSchema) async throws -> Int {
        Self.estimate(String(describing: schema))
    }

    /// Estimates history input from the UTF-8 size of its description.
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int {
        Self.estimate(String(describing: history))
    }

    /// Estimates tool-definition input from the UTF-8 size of the tool array description.
    func tokenCount(for tools: [any Tool]) async throws -> Int {
        Self.estimate(String(describing: tools))
    }

    /// Uses UTF-8 byte length as a portable text-token estimate.
    func tokenCount(forText text: String) async throws -> Int {
        Self.estimate(text)
    }

    /// Uses UTF-8 byte length to budget custom-tool argument or output text.
    func tokenCount(for text: String) async throws -> Int {
        Self.estimate(text)
    }

    /// Returns at least one token, using one token per UTF-8 byte as the conservative estimate.
    private static func estimate(_ text: String) -> Int {
        // Byte-derived tokenizers cannot emit more than one token per input byte.
        max(1, text.utf8.count)
    }
}

/// Exact prompt admission is performed by a configured custom-provider tokenizer
/// endpoint after Foundation Models has assembled the complete generation request.
struct EvaluationDeferredPromptInputTokenCounter: EvaluationPromptInputTokenCounting {
    /// Returns zero because prompt admission is deferred to the provider tokenizer endpoint.
    func tokenCount(for prompt: Prompt) async throws -> Int { 0 }
    /// Returns zero because the provider tokenizer will count instructions in the assembled request.
    func tokenCount(for instructions: Instructions) async throws -> Int { 0 }
    /// Returns zero because the provider tokenizer will count the schema in the assembled request.
    func tokenCount(for schema: GenerationSchema) async throws -> Int { 0 }
    /// Returns zero because the provider tokenizer will count history in the assembled request.
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int { 0 }
    /// Returns zero because the provider tokenizer will count tool definitions in the assembled request.
    func tokenCount(for tools: [any Tool]) async throws -> Int { 0 }
    /// Returns zero because text admission is deferred to the provider tokenizer endpoint.
    func tokenCount(forText text: String) async throws -> Int { 0 }
}

enum EvaluationInputTokenCounter {
    /// Counts the full prompt when it has no images, otherwise counting only its text.
    ///
    /// Image-bearing input is marked incomplete because attachment tokens are not measured here.
    static func promptEstimate<Counter: EvaluationPromptInputTokenCounting>(
        text: String,
        prompt: Prompt,
        hasImages: Bool,
        using tokenCounter: Counter
    ) async throws -> EvaluationInputTokenEstimate {
        if hasImages {
            return EvaluationInputTokenEstimate(
                count: try await tokenCounter.tokenCount(forText: text),
                imageTokenCountAvailable: false
            )
        }
        return EvaluationInputTokenEstimate(
            count: try await tokenCounter.tokenCount(for: prompt, cacheKey: text),
            imageTokenCountAvailable: true
        )
    }

    /// Counts history after removing image attachments when present and marks that estimate as missing image tokens.
    static func historyEstimate<Counter: EvaluationPromptInputTokenCounting>(
        _ history: [Transcript.Entry],
        using tokenCounter: Counter
    ) async throws -> EvaluationInputTokenEstimate {
        guard historyContainsImage(history) else {
            return EvaluationInputTokenEstimate(
                count: try await tokenCounter.tokenCount(for: history),
                imageTokenCountAvailable: true
            )
        }
        return EvaluationInputTokenEstimate(
            count: try await tokenCounter.tokenCount(for: historyWithoutImages(history)),
            imageTokenCountAvailable: false
        )
    }

    /// Detects attachment segments in supported transcript entry kinds.
    static func historyContainsImage(_ history: [Transcript.Entry]) -> Bool {
        history.contains { entry in
            segments(in: entry).contains {
                if case .attachment = $0 { return true }
                return false
            }
        }
    }

    /// Copies history with attachment segments removed, preserving tool-call entries and other segment content.
    static func historyWithoutImages(_ history: [Transcript.Entry]) -> [Transcript.Entry] {
        history.map { entry in
            switch entry {
            case .instructions(var instructions):
                instructions.segments = segmentsWithoutImages(instructions.segments)
                return .instructions(instructions)
            case .prompt(var prompt):
                prompt.segments = segmentsWithoutImages(prompt.segments)
                return .prompt(prompt)
            case .toolCalls, .data:
                return entry
            case .toolOutput(var output):
                output.segments = segmentsWithoutImages(output.segments)
                return .toolOutput(output)
            case .response(var response):
                response.segments = segmentsWithoutImages(response.segments)
                return .response(response)
            case .reasoning(var reasoning):
                reasoning.segments = segmentsWithoutImages(reasoning.segments)
                return .reasoning(reasoning)
            @unknown default:
                return entry
            }
        }
    }

    /// Extracts segments from known entry kinds, returning none for tool-call or unknown entries.
    private static func segments(in entry: Transcript.Entry) -> [Transcript.Segment] {
        switch entry {
        case .instructions(let instructions): instructions.segments
        case .prompt(let prompt): prompt.segments
        case .toolCalls, .data: []
        case .toolOutput(let output): output.segments
        case .response(let response): response.segments
        case .reasoning(let reasoning): reasoning.segments
        @unknown default: []
        }
    }

    /// Filters attachment segments while preserving the order of all remaining segments.
    private static func segmentsWithoutImages(
        _ segments: [Transcript.Segment]
    ) -> [Transcript.Segment] {
        segments.filter {
            if case .attachment = $0 { return false }
            return true
        }
    }
}

extension EvaluationRunner {
    /// Composes a prompt and checks its input and same-model judge headroom before generation.
    ///
    /// Counts instructions, tools, schema, reachable after-tool instructions, and model-facing
    /// history. Inline reference text may be shortened in up to eight passes under `fitReferences`.
    /// Image tokens remain unavailable in the returned estimate when current or historical images
    /// were excluded. Throws when the composed input or required judge evidence cannot fit.
    func preparedPrompt(
        for evaluationCase: EvaluationCase,
        suite: EvaluationSuite,
        images: [ImageEvaluationInput],
        contextSize: Int,
        tools: [any Tool],
        historyTokenCount: Int = 0,
        historyImageTokenCountAvailable: Bool = true,
        judgeSubjectContext: EvaluationJudgeSubjectContext? = nil,
        profileHasTransitioned: Bool = false,
        tokenCounter: any EvaluationPromptInputTokenCounting = EvaluationSystemPromptInputTokenCounter()
    ) async throws -> (
        prompt: Prompt,
        text: String,
        tokenCount: Int,
        imageInputTokenCountAvailable: Bool
    ) {
        let suite = suite.effectiveSuite(for: evaluationCase)
        if evaluationCase.documentEvidence != nil,
           suite.modelConfiguration.contextPolicy != .requireFullInput || suite.modelConfiguration.referenceMode != .inline {
            throw EvaluationStoreError.invalidSuite("Document context must be supplied inline and complete; automatic reference fitting and lookup are unsupported.")
        }
        let afterToolProfileIsReachable = suite.features.profile.enabled
            && (profileHasTransitioned || !tools.isEmpty)
        let instructionTokens = suite.instructions.isEmpty
            ? 0
            : try await tokenCounter.tokenCount(for: Instructions(suite.instructions), cacheKey: suite.instructions)
        let toolTokens = tools.isEmpty ? 0 : try await tokenCounter.tokenCount(for: tools)
        let schemaTokens = suite.features.outputFields.isEmpty ? 0 : try await tokenCounter.tokenCount(
            for: EvaluationSchemaBuilder.schema(
                fields: suite.features.outputFields,
                name: "EvaluationOutput",
                definitions: suite.features.outputSchemaDefinitions,
                representNilExplicitlyInGeneratedContent:
                    suite.features.outputRepresentNilExplicitlyInGeneratedContent
            ))
        let profileTokens = afterToolProfileIsReachable ? try await tokenCounter.tokenCount(
            for: Instructions(suite.features.profile.afterToolInstructions), cacheKey: suite.features.profile.afterToolInstructions) : 0
        let allocation = suite.modelConfiguration.contextAllocation(
            contextSize: contextSize,
            includesModelJudge: suite.usesSubjectModelForJudging,
            sharedToolOutputReserve: suite.sharedToolOutputReserve,
            maximumSubjectResponseTokens: suite.responseTokenReserve(afterToolProfileIsReachable: afterToolProfileIsReachable)
        )
        let inputCeiling = allocation.effectiveInputLimit
        let promptBudget = inputCeiling - instructionTokens - toolTokens - schemaTokens - profileTokens
            - historyTokenCount
        let availableTextCharacters = suite.attachments
            .filter { $0.kind == .text }
            .compactMap(\.text)
            .map(\.count)
            .reduce(0, +)
        var textLimit = availableTextCharacters
        var effectiveText = Self.promptText(
            for: evaluationCase,
            attachments: suite.attachments,
            textCharacterLimit: textLimit,
            referenceMode: suite.modelConfiguration.referenceMode
        )
        var prompt = Self.prompt(text: effectiveText, images: images)
        var promptEstimate = try await EvaluationInputTokenCounter.promptEstimate(
            text: effectiveText,
            prompt: prompt,
            hasImages: !images.isEmpty,
            using: tokenCounter
        )

        for _ in 0..<8 where promptEstimate.count > promptBudget
            && textLimit > 0
            && suite.modelConfiguration.referenceMode == .inline
            && suite.modelConfiguration.contextPolicy == .fitReferences {
            let ratio = max(0.1, Double(promptBudget) / Double(promptEstimate.count))
            textLimit = max(0, min(textLimit - 1, Int(Double(textLimit) * ratio) - 128))
            effectiveText = Self.promptText(
                for: evaluationCase,
                attachments: suite.attachments,
                textCharacterLimit: textLimit,
                referenceMode: suite.modelConfiguration.referenceMode
            )
            prompt = Self.prompt(text: effectiveText, images: images)
            promptEstimate = try await EvaluationInputTokenCounter.promptEstimate(
                text: effectiveText,
                prompt: prompt,
                hasImages: !images.isEmpty,
                using: tokenCounter
            )
        }

        guard promptEstimate.count <= promptBudget else {
            throw EvaluationRunnerError.inputTooLarge(
                tokens: promptEstimate.count + instructionTokens + toolTokens + schemaTokens + profileTokens
                    + historyTokenCount,
                budget: inputCeiling
            )
        }
        var admissionContext = judgeSubjectContext
        if suite.needsModelJudge {
            // A tool can activate the second profile during the scored request,
            // or it may already be active after a setup turn. Admit reachable states
            // before invoking the subject, including when its judge is external.
            var instructions: [String?] = [suite.instructions]
            if afterToolProfileIsReachable {
                instructions.append([suite.instructions, suite.features.profile.afterToolInstructions]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n"))
            }
            admissionContext = try judgeSubjectContext?.admittingInstructionVariants(instructions)
        }
        if suite.usesSubjectModelForJudging {
            var judgeAdmissionSuite = suite
            judgeAdmissionSuite.criteria = suite.rubricCriteria
                .filter { EvaluationExactCriterion.expectedText(in: $0) == nil }
                .joined(separator: "\n")
            if let instructions = admissionContext?.subjectInstructions {
                judgeAdmissionSuite.instructions = instructions
            } else if afterToolProfileIsReachable {
                judgeAdmissionSuite.instructions = [suite.instructions, suite.features.profile.afterToolInstructions]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            let criterionGroups = evaluationCase.documentEvidence != nil
                ? judgeAdmissionSuite.rubricCriteria.map { [$0] } : [judgeAdmissionSuite.rubricCriteria]
            for group in criterionGroups {
                judgeAdmissionSuite.criteria = group.joined(separator: "\n")
                let minimumJudgeText = Self.judgePrompt(
                    response: "",
                    evaluationCase: evaluationCase,
                    effectivePrompt: effectiveText,
                    suite: judgeAdmissionSuite,
                    toolEvidence: nil,
                    subjectContext: admissionContext
                )
                let minimumJudgePrompt = Self.prompt(text: minimumJudgeText, images: images)
                let judgeInstructionTokens = try await tokenCounter.tokenCount(for: Instructions(
                    evaluationCase.documentEvidence != nil ? Self.documentJudgeInstructions : Self.judgeInstructions))
                let judgePromptTokens = try await EvaluationInputTokenCounter.promptEstimate(
                    text: minimumJudgeText,
                    prompt: minimumJudgePrompt,
                    hasImages: !images.isEmpty,
                    using: tokenCounter
                ).count
                let judgeSchema = try EvaluationJudge.schema(criterionCount: judgeAdmissionSuite.rubricCriteria.count, evidenceFirst: evaluationCase.documentEvidence != nil)
                let judgeSchemaTokens = try await tokenCounter.tokenCount(for: judgeSchema)
                let worstCaseJudgeInput = judgeInstructionTokens
                    + judgePromptTokens
                    + judgeSchemaTokens
                    + suite.responseTokenReserve(afterToolProfileIsReachable: afterToolProfileIsReachable)
                    + allocation.toolOutputReserve
                let judgeInputBudget = contextSize - EvaluationModelConfiguration.judgeResponseTokenReserve
                guard worstCaseJudgeInput <= judgeInputBudget else {
                    throw EvaluationRunnerError.inputTooLarge(tokens: worstCaseJudgeInput, budget: judgeInputBudget)
                }
            }
        }
        return (
            prompt,
            effectiveText,
            promptEstimate.count + instructionTokens + toolTokens + schemaTokens + profileTokens + historyTokenCount,
            promptEstimate.imageTokenCountAvailable && historyImageTokenCountAvailable
        )
    }

    /// Builds a prompt containing text followed by labeled image attachments in input order.
    static func prompt(text: String, images: [ImageEvaluationInput]) -> Prompt {
        Prompt {
            text
            for image in images {
                Attachment(imageURL: image.url).label(image.label)
            }
        }
    }

    /// Adds bounded inline references or lookup-tool guidance and image labels to the authored prompt.
    ///
    /// `textCharacterLimit` is shared across inline text files; filenames are emitted as bounded
    /// JSON literals and reference passages are explicitly delimited as untrusted data.
    static func promptText(
        for evaluationCase: EvaluationCase,
        attachments: [EvaluationAttachment],
        textCharacterLimit: Int,
        referenceMode: EvaluationReferenceMode
    ) -> String {
        let textFiles = attachments.filter { $0.kind == .text }
        let imageFiles = attachments.filter { $0.kind == .image }
        var prompt = evaluationCase.prompt

        if !textFiles.isEmpty, referenceMode == .inline {
            var remaining = textCharacterLimit
            prompt += "\n\nReference files:"
            for file in textFiles where remaining > 0 {
                let text = file.text ?? ""
                let excerpt = String(text.prefix(remaining))
                let filename = ReferenceLookupTool.filenameJSONLiteral(file.name)
                prompt += "\n\n--- BEGIN UNTRUSTED REFERENCE ---\nfilenameJSON: \(filename)\n\(excerpt)\n--- END UNTRUSTED REFERENCE ---"
                remaining -= excerpt.count
            }
            if textFiles.compactMap(\.text).map(\.count).reduce(0, +) > textCharacterLimit {
                prompt += "\n\n[Reference text truncated to preserve response headroom.]"
            }
        } else if !textFiles.isEmpty {
            prompt += "\n\nUse the search_reference_files tool when facts from the imported references are needed. Available reference files:"
            for file in textFiles {
                prompt += "\n- filenameJSON: \(ReferenceLookupTool.filenameJSONLiteral(file.name))"
            }
        }

        for (index, file) in imageFiles.enumerated() {
            prompt += "\n\nImage file-\(index + 1) filenameJSON: \(ReferenceLookupTool.filenameJSONLiteral(file.name))"
        }

        return prompt
    }
}
