import Foundation
import FoundationModels

@available(macOS 27.0, *)
enum AppEngineValidation {

    static let maximumCases = 100
    static let maximumPlannedSamples = EvaluationDevelopmentLimits.maximumPlannedSamples
    static let maximumAttachments = 20
    static let maximumImages = 4
    static let maximumFieldCharacters = 32_000
    static let maximumCombinedSuiteCharacters = 256_000
    static let maximumRubricRequirementCharacters = 4_000
    static let maximumExtractedTextCharacters = 16_000
    static let maximumTextFileBytes = 5_000_000
    static let maximumImageBytes = 10_000_000

    /// Returns the first suite validation issue, or nil when standalone on-device execution and same-model judging are admissible.
    /// Set `includeModelReadiness` to false to validate saved configuration without requiring the model to be ready.
    static func validationIssue(
        for candidate: EvaluationSuite,
        includeModelReadiness: Bool = true
    ) -> String? {
        let configuration = candidate.modelConfiguration
        let capabilities = configuration.systemModel.capabilities
        let validateCapabilities = true
        guard configuration.provider == .onDevice else { return "Only the on-device Apple Foundation Model is supported." }
        guard !candidate.judgeConfiguration.usesExternalConnection else { return "Only same-model rubric judging is supported." }
        if let issue = configuration.customizationSettings.validationIssue { return issue }
        if configuration.reasoningLevel == .custom,
           configuration.customizationSettings.reasoningName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the reasoning value supported by the selected provider."
        }
        if let issue = candidate.features.validationIssue { return issue }
        if candidate.features.profile.enabled, candidate.features.profile.requireToolFirst,
           !candidate.hasConfiguredTools {
            return "A profile that requires a tool call must enable at least one tool."
        }
        if candidate.hasConfiguredTools, validateCapabilities, !capabilities.contains(.toolCalling) {
            return "The selected model does not support tool calling."
        }
        if candidate.features.tools.contains(where: { $0.name == ReferenceLookupTool.toolName }) {
            return "Custom tools must not use the reserved reference lookup name."
        }
        let vision = configuration.customizationSettings.visionSettings
        if !vision.isEmpty {
            if validateCapabilities && !capabilities.contains(.toolCalling) { return "Image tools require a model that supports tool calling." }
            if !candidate.attachments.contains(where: { $0.kind == .image }) {
                return "Attach an image before enabling OCR or barcode tools."
            }
        }
        if candidate.features.tools.contains(where: { vision.enabledToolNames.contains($0.name) }) {
            return "Custom tool names must differ from the enabled image tool names."
        }
        if candidate.features.tools.contains(where: {
            candidate.features.spotlightSearch.enabledToolNames.contains($0.name)
        }) {
            return "Custom tool names must differ from the enabled Spotlight tool name."
        }
        if !candidate.features.tools.isEmpty, validateCapabilities && !capabilities.contains(.toolCalling) {
            return "The current model does not support custom tool calls."
        }
        if !candidate.features.outputFields.isEmpty, validateCapabilities && !capabilities.contains(.guidedGeneration) {
            return "The current model does not support guided output."
        }
        if configuration.provider == .customHTTP, let issue = configuration.customProviderSettings.validationIssue {
            return issue
        }
        if !candidate.features.profile.enabled,
           configuration.customizationSettings.toolCalling == .required,
           !candidate.hasConfiguredTools {
            return "Required tool calling needs at least one enabled tool."
        }
        if candidate.cases.isEmpty {
            return "Add at least one evaluation case."
        }
        if candidate.cases.count > Self.maximumCases {
            return "Keep the suite to \(Self.maximumCases) cases or fewer."
        }
        if !(1...5).contains(candidate.repetitions) {
            return "Choose between one and five repetitions."
        }
        let (plannedSamples, overflowed) = candidate.cases.count.multipliedReportingOverflow(by: candidate.repetitions)
        if overflowed || plannedSamples > Self.maximumPlannedSamples {
            return "Keep the run to \(Self.maximumPlannedSamples) planned samples or fewer."
        }
        let releasePolicy = candidate.releasePolicy
        if !(0...(Self.maximumPlannedSamples * 2)).contains(releasePolicy.maximumErrorCount) {
            return "Keep the release error limit between 0 and \(Self.maximumPlannedSamples * 2)."
        }
        if let latency = releasePolicy.maximumAverageLatencyMilliseconds,
           !latency.isFinite || latency < 0 {
            return "The release latency limit must be a finite nonnegative number."
        }
        if !releasePolicy.maximumPassRateRegression.isFinite
            || !(0...1).contains(releasePolicy.maximumPassRateRegression) {
            return "The allowed pass-rate regression must be between 0 and 1."
        }
        if Set(releasePolicy.criticalCaseIDs).count != releasePolicy.criticalCaseIDs.count
            || !Set(releasePolicy.criticalCaseIDs).isSubset(of: Set(candidate.cases.map(\.id))) {
            return "Every critical release case must uniquely identify a case in this suite."
        }
        if Set(candidate.cases.map(\.id)).count != candidate.cases.count {
            return "Every case needs a unique ID."
        }
        if candidate.cases.contains(where: { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Every case needs a prompt."
        }
        if let issue = candidate.cases.lazy.compactMap(\.conversation.validationIssue).first {
            return issue
        }
        if let issue = candidate.cases.lazy.compactMap({ evaluationCase in
            EvaluationFieldAssertions.validationIssue(
                assertions: evaluationCase.fieldAssertions ?? [],
                scoringMode: candidate.scoringMode
            )
        }).first {
            return issue
        }
        if candidate.instructions.count > Self.maximumFieldCharacters
            || candidate.cases.contains(where: {
                $0.prompt.count > Self.maximumFieldCharacters
                    || $0.expected.count > Self.maximumFieldCharacters
                    || $0.conversation.setupTurns.contains(where: {
                        $0.prompt.count > Self.maximumFieldCharacters
                    })
            }) {
            return "Instructions, prompts, and expected responses must each contain \(Self.maximumFieldCharacters) characters or fewer."
        }
        let suiteCharacterCount = candidate.name.count
            + candidate.version.count
            + candidate.instructions.count
            + candidate.criteria.count
            + candidate.cases.reduce(0) {
                $0 + $1.name.count + $1.prompt.count + $1.expected.count + $1.conversation.textCharacterCount
                    + ($1.fieldAssertions ?? []).reduce(0) { $0 + $1.pointer.count + $1.expectedValue.count }
            }
        if suiteCharacterCount > Self.maximumCombinedSuiteCharacters {
            return "Keep the suite text to \(Self.maximumCombinedSuiteCharacters) characters or fewer."
        }
        if candidate.scoringMode.needsExpected,
           candidate.cases.contains(where: { $0.expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Every case needs expected text for the selected deterministic metric."
        }
        if candidate.scoringMode == .modelJudge {
            if candidate.rubricCriteria.isEmpty {
                return "Add at least one requirement for the AI rubric."
            }
            if candidate.rubricCriteria.count > 4 {
                return "Keep the AI rubric to four requirements or fewer so the judge can evaluate each one reliably."
            }
            if candidate.rubricCriteria.contains(where: { $0.count > Self.maximumRubricRequirementCharacters }) {
                return "Keep each rubric requirement to \(Self.maximumRubricRequirementCharacters) characters or fewer."
            }
            if validateCapabilities && !capabilities.contains(.guidedGeneration) {
                return "The selected subject model does not support the guided output required for same-model judging. Choose an independent judge or another subject model."
            }
        }
        if !(128...4_096).contains(configuration.maximumResponseTokens) {
            return "Choose a maximum response length between 128 and 4,096 tokens."
        }
        if let maximumInputTokens = configuration.maximumInputTokens,
           !(512...32_768).contains(maximumInputTokens) {
            return "Choose an input ceiling between 512 and 32,768 tokens."
        }
        if configuration.temperatureEnabled,
           !configuration.temperature.isFinite || !(0...1).contains(configuration.temperature) {
            return "Temperature must be between 0 and 1."
        }
        if configuration.samplingMode == .topK, !(1...1_000).contains(configuration.topK) {
            return "Top K must be between 1 and 1,000."
        }
        if configuration.samplingMode == .probability,
           !configuration.probabilityThreshold.isFinite || !(0.01...1).contains(configuration.probabilityThreshold) {
            return "Probability threshold must be between 0.01 and 1."
        }
        if configuration.reasoningLevel != .automatic,
           validateCapabilities && !capabilities.contains(.reasoning) {
            return "The selected model does not support explicit reasoning levels. Choose Automatic."
        }
        if candidate.features.profile.enabled,
           candidate.features.profile.afterToolReasoningLevel != .automatic,
           validateCapabilities && !capabilities.contains(.reasoning) {
            return "The selected model does not support explicit reasoning levels in the active profile. Choose Automatic."
        }
        if candidate.hasConfiguredTools, !(1...4).contains(configuration.maximumToolCalls) {
            return "The tool call limit must be between one and four calls per sample."
        }
        if configuration.referenceMode == .lookupTool {
            if validateCapabilities && !capabilities.contains(.toolCalling) {
                return "The selected model does not support tool calling."
            }
            if !candidate.attachments.contains(where: { $0.kind == .text }) {
                return "Import at least one text reference before enabling reference search."
            }
            if !(1...4).contains(configuration.maximumToolCalls) {
                return "The reference tool limit must be between one and four calls per response."
            }
        }
        let reportedSize = configuration.systemModel.contextSize
        let modelContextSize = ModelContextSizeCache.resolvedOnDeviceContextSize(reportedSize)
        let allocation = configuration.contextAllocation(
            contextSize: modelContextSize,
            includesModelJudge: candidate.needsModelJudge,
            sharedToolOutputReserve: candidate.sharedToolOutputReserve
        )
        let contextSizeIsAuthoritative = reportedSize > 0
        if contextSizeIsAuthoritative, modelContextSize > 0, allocation.effectiveInputLimit < 512 {
            return "Reduce the response limit or reference-tool call limit so at least 512 input tokens remain."
        }
        if candidate.attachments.count > Self.maximumAttachments {
            return "A suite can attach up to \(Self.maximumAttachments) files."
        }
        if candidate.attachments.count(where: { $0.kind == .image }) > Self.maximumImages {
            return "A suite can attach up to \(Self.maximumImages) images."
        }
        if Set(candidate.attachments.map(\.id)).count != candidate.attachments.count {
            return "Every attachment needs a unique ID."
        }
        if candidate.attachments.contains(where: { $0.kind == .image }),
           validateCapabilities && !capabilities.contains(.vision) {
            return "The selected model does not support image input."
        }
        return includeModelReadiness ? EvaluationRunner.unavailableMessage(for: configuration.systemModel.availability) : nil
    }

}
