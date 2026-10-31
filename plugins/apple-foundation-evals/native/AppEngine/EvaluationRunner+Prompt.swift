import Foundation
import FoundationModels

@available(macOS 27.0, *)
struct EvaluationInputTokenEstimate: Sendable {
    var count: Int
    var imageTokenCountAvailable: Bool
}

@available(macOS 27.0, *)
protocol EvaluationPromptInputTokenCounting: Sendable {
    /// Counts prompt tokens for input admission, propagating tokenizer failures.
    func tokenCount(for prompt: Prompt) async throws -> Int
    /// Counts instruction tokens for input admission, propagating tokenizer failures.
    func tokenCount(for instructions: Instructions) async throws -> Int
    /// Counts generation-schema tokens for input admission, propagating tokenizer failures.
    func tokenCount(for schema: GenerationSchema) async throws -> Int
    /// Counts conversation-history tokens for input admission, propagating tokenizer failures.
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int
    /// Counts tool-definition tokens for input admission, propagating tokenizer failures.
    func tokenCount(for tools: [any Tool]) async throws -> Int
    /// Counts raw prompt text when full prompt counting is unavailable, propagating tokenizer failures.
    func tokenCount(forText text: String) async throws -> Int
}

@available(macOS 27.0, *)
struct EvaluationSystemPromptInputTokenCounter: EvaluationPromptInputTokenCounting {
    /// Counts prompt tokens with the default system model tokenizer.
    func tokenCount(for prompt: Prompt) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: prompt)
    }

    /// Counts instruction tokens with the default system model tokenizer.
    func tokenCount(for instructions: Instructions) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: instructions)
    }

    /// Counts schema tokens with the default system model tokenizer.
    func tokenCount(for schema: GenerationSchema) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: schema)
    }

    /// Counts transcript history tokens with the default system model tokenizer.
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: history)
    }

    /// Counts tool-definition tokens with the default system model tokenizer.
    func tokenCount(for tools: [any Tool]) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: tools)
    }

    /// Wraps text as a prompt and counts its tokens with the default system model tokenizer.
    func tokenCount(forText text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: Prompt(text))
    }
}

@available(macOS 27.0, *)
enum EvaluationInputTokenCounter {
    /// Counts a complete text-only prompt or only its supplied text when images are present, preserving whether image token counting was possible.
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
            count: try await tokenCounter.tokenCount(for: prompt),
            imageTokenCountAvailable: true
        )
    }

    /// Counts history through the supplied counter, removing attachments and marking image counts unavailable when history contains images.
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

    /// Reports whether any supported history entry contains an attachment segment.
    static func historyContainsImage(_ history: [Transcript.Entry]) -> Bool {
        history.contains { entry in
            segments(in: entry).contains {
                if case .attachment = $0 { return true }
                return false
            }
        }
    }

    /// Returns history with attachment segments removed from supported entry kinds, preserving tool-call entries and unknown entry kinds.
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

    /// Returns segments from supported transcript entry kinds, with no segments for tool calls or unknown entries.
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

    /// Removes attachment segments while preserving the order of all other segments.
    private static func segmentsWithoutImages(
        _ segments: [Transcript.Segment]
    ) -> [Transcript.Segment] {
        segments.filter {
            if case .attachment = $0 { return false }
            return true
        }
    }
}

@available(macOS 27.0, *)
extension EvaluationRunner {
    /// Builds and admits the scored prompt after reserving instructions, history, schema, tools, output, and reachable profile and judge overhead.
    /// Inline references may shrink under the fit policy; insufficient subject or judge budget and invalid saved judge evidence throw before generation.
    /// The returned count excludes unavailable image tokens, as indicated by its availability flag.
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
        let afterToolProfileIsReachable = suite.features.profile.enabled
            && (profileHasTransitioned || !tools.isEmpty)
        let instructionTokens = suite.instructions.isEmpty
            ? 0
            : try await tokenCounter.tokenCount(for: Instructions(suite.instructions))
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
            for: Instructions(suite.features.profile.afterToolInstructions)) : 0
        let allocation = suite.modelConfiguration.contextAllocation(
            contextSize: contextSize,
            includesModelJudge: suite.needsModelJudge,
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
        if suite.needsModelJudge {
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
            let minimumJudgeText = Self.judgePrompt(
                response: "",
                evaluationCase: evaluationCase,
                effectivePrompt: effectiveText,
                suite: judgeAdmissionSuite,
                toolEvidence: nil,
                subjectContext: admissionContext
            )
            let minimumJudgePrompt = Self.prompt(text: minimumJudgeText, images: images)
            let judgeInstructionTokens = try await tokenCounter.tokenCount(for: Instructions(Self.judgeInstructions))
            let judgePromptTokens = try await EvaluationInputTokenCounter.promptEstimate(
                text: minimumJudgeText,
                prompt: minimumJudgePrompt,
                hasImages: !images.isEmpty,
                using: tokenCounter
            ).count
            let judgeSchema = try EvaluationJudge.schema(criterionCount: judgeAdmissionSuite.rubricCriteria.count)
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
        return (
            prompt,
            effectiveText,
            promptEstimate.count + instructionTokens + toolTokens + schemaTokens + profileTokens + historyTokenCount,
            promptEstimate.imageTokenCountAvailable && historyImageTokenCountAvailable
        )
    }

    /// Combines text with file-backed image attachments carrying their configured labels.
    static func prompt(text: String, images: [ImageEvaluationInput]) -> Prompt {
        Prompt {
            text
            for image in images {
                Attachment(imageURL: image.url).label(image.label)
            }
        }
    }

    /// Composes case text with bounded inline references or lookup-tool filenames and image labels, escaping filenames and marking truncated reference text.
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
