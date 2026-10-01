import Foundation
import FoundationModels

struct EvaluationInputTokenEstimate: Sendable {
    var count: Int
    var imageTokenCountAvailable: Bool
}

protocol EvaluationPromptInputTokenCounting: Sendable {
    func tokenCount(for prompt: Prompt) async throws -> Int
    func tokenCount(forText text: String) async throws -> Int
}

struct EvaluationSystemPromptInputTokenCounter: EvaluationPromptInputTokenCounting {
    func tokenCount(for prompt: Prompt) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: prompt)
    }

    func tokenCount(forText text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: Prompt(text))
    }
}

enum EvaluationInputTokenCounter {
    static func promptEstimate(
        text: String,
        prompt: Prompt,
        hasImages: Bool
    ) async throws -> EvaluationInputTokenEstimate {
        try await promptEstimate(
            text: text,
            prompt: prompt,
            hasImages: hasImages,
            using: EvaluationSystemPromptInputTokenCounter()
        )
    }

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

    static func historyEstimate(
        _ history: [Transcript.Entry]
    ) async throws -> EvaluationInputTokenEstimate {
        let tokenCounter = SystemLanguageModel.default
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

    static func historyContainsImage(_ history: [Transcript.Entry]) -> Bool {
        history.contains { entry in
            segments(in: entry).contains {
                if case .attachment = $0 { return true }
                return false
            }
        }
    }

    static func historyWithoutImages(_ history: [Transcript.Entry]) -> [Transcript.Entry] {
        history.map { entry in
            switch entry {
            case .instructions(var instructions):
                instructions.segments = segmentsWithoutImages(instructions.segments)
                return .instructions(instructions)
            case .prompt(var prompt):
                prompt.segments = segmentsWithoutImages(prompt.segments)
                return .prompt(prompt)
            case .toolCalls:
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

    private static func segments(in entry: Transcript.Entry) -> [Transcript.Segment] {
        switch entry {
        case .instructions(let instructions): instructions.segments
        case .prompt(let prompt): prompt.segments
        case .toolCalls: []
        case .toolOutput(let output): output.segments
        case .response(let response): response.segments
        case .reasoning(let reasoning): reasoning.segments
        @unknown default: []
        }
    }

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
    func preparedPrompt(
        for evaluationCase: EvaluationCase,
        suite: EvaluationSuite,
        images: [ImageEvaluationInput],
        contextSize: Int,
        tools: [any Tool],
        historyTokenCount: Int = 0,
        historyImageTokenCountAvailable: Bool = true
    ) async throws -> (
        prompt: Prompt,
        text: String,
        tokenCount: Int,
        imageInputTokenCountAvailable: Bool
    ) {
        let tokenCounter = SystemLanguageModel.default
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
        let profileTokens = suite.features.profile.enabled ? try await tokenCounter.tokenCount(
            for: Instructions(suite.features.profile.afterToolInstructions)) : 0
        let allocation = suite.modelConfiguration.contextAllocation(
            contextSize: contextSize,
            includesModelJudge: suite.needsModelJudge,
            sharedToolOutputReserve: suite.sharedToolOutputReserve
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
            hasImages: !images.isEmpty
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
                hasImages: !images.isEmpty
            )
        }

        guard promptEstimate.count <= promptBudget else {
            throw EvaluationRunnerError.inputTooLarge(
                tokens: promptEstimate.count + instructionTokens + toolTokens + schemaTokens + profileTokens
                    + historyTokenCount,
                budget: inputCeiling
            )
        }
        if suite.needsModelJudge {
            var judgeAdmissionSuite = suite
            judgeAdmissionSuite.criteria = suite.rubricCriteria
                .filter { EvaluationExactCriterion.expectedText(in: $0) == nil }
                .joined(separator: "\n")
            if suite.features.profile.enabled {
                judgeAdmissionSuite.instructions = [suite.instructions, suite.features.profile.afterToolInstructions]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            let minimumJudgeText = Self.judgePrompt(
                response: "",
                evaluationCase: evaluationCase,
                effectivePrompt: effectiveText,
                suite: judgeAdmissionSuite,
                toolEvidence: nil
            )
            let minimumJudgePrompt = Self.prompt(text: minimumJudgeText, images: images)
            let judgeInstructionTokens = try await tokenCounter.tokenCount(for: Instructions(Self.judgeInstructions))
            let judgePromptTokens = try await EvaluationInputTokenCounter.promptEstimate(
                text: minimumJudgeText,
                prompt: minimumJudgePrompt,
                hasImages: !images.isEmpty
            ).count
            let judgeSchema = try EvaluationJudge.schema(criterionCount: judgeAdmissionSuite.rubricCriteria.count)
            let judgeSchemaTokens = try await tokenCounter.tokenCount(for: judgeSchema)
            let worstCaseJudgeInput = judgeInstructionTokens
                + judgePromptTokens
                + judgeSchemaTokens
                + suite.modelConfiguration.maximumResponseTokens
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

    static func prompt(text: String, images: [ImageEvaluationInput]) -> Prompt {
        Prompt {
            text
            for image in images {
                Attachment(imageURL: image.url).label(image.label)
            }
        }
    }

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
