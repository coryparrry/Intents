import Foundation

/// Only fixed categories and generated correlation IDs may enter diagnostics.
/// Never accept an error description, document name, URL, or model response.
enum TelemetryOperation: String, Codable, Sendable {
    case workspaceLoad = "workspace_load", suiteSave = "suite_save"
    case evaluation, runSave = "run_save", runCheckpoint = "run_checkpoint"
    case modelLoad = "model_load", cloudMetadata = "cloud_metadata"
    case mcpStart = "mcp_start", mcpInstall = "mcp_install", mcpStop = "mcp_stop"
    case documentGenerate = "document_generate", suiteImport = "suite_import", suiteExport = "suite_export"
    case reviewSave = "review_save", batchRun = "batch_run", appIntentRun = "app_intent_run"
    case documentImport = "document_import", referenceImport = "reference_import"
    case datasetImport = "dataset_import", resultExport = "results_export"
}

/// Fixed diagnostic categories that avoid carrying free-form failure messages.
enum TelemetryFailure: String, Codable, Sendable {
    case unexpected, cancelled, timeout, network, permission, storage, validation
    case modelUnavailable = "model_unavailable", generation, provider, judge, build
    case deviceUnavailable = "device_unavailable", evidence, testFailure = "test_failure"

    /// Maps cancellation and known storage/network error domains to fixed categories without inspecting error descriptions.
    static func classify(_ error: any Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let error = error as? EvaluationStoreError {
            switch error {
            case .persistence: return .storage
            default: return .validation
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorTimedOut: return .timeout
            default: return .network
            }
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .permission
            default: return .storage
            }
        }
        return .unexpected
    }

    /// Classifies runtime failure evidence with cancellation taking precedence; failed assertions alone do not count as runtime failures.
    static func evaluationFailure(results: [EvaluationSampleResult], cancelled: Bool) -> Self? {
        if cancelled { return .cancelled }
        if let category = results.compactMap(\.errorCategory).first { return evaluationCategory(category) }
        if results.contains(where: { $0.errorMessage != nil }) { return .generation }
        if results.contains(where: { $0.judgeErrorCategory != nil || $0.judgeErrorMessage != nil }) { return .judge }
        // A failed assertion is evaluation evidence, not an app runtime failure.
        return nil
    }

    /// Maps runner-produced categories and legacy aliases to content-free diagnostic groups; unknown strings remain unexpected.
    static func evaluationCategory(_ category: String) -> Self {
        switch category {
        case "cancelled": .cancelled
        case "modelUnavailable", "modelAssetsUnavailable": .modelUnavailable
        case "invalidConfiguration", "inputTooLarge", "invalidRestoredTranscript", "unsupportedCapability", "unsupportedTranscriptContent",
             "unsupportedGenerationGuide", "unsupportedLanguageOrLocale": .validation
        case "generation", "contextWindowExceeded", "contextSizeExceeded", "guardrailViolation", "refusal",
             "toolCallFailed", "concurrentRequests", "transcriptMutationWhileResponding", "sessionError",
             "languageModelError": .generation
        case "network", "http", "transport", "networkFailure": .network
        case "customProviderError", "rateLimited", "quotaLimitReached", "serviceUnavailable",
             "privateCloudComputeError": .provider
        case "timeout": .timeout
        case "judgeInputTooLarge": .judge
        default: .unexpected
        }
    }
}

enum TelemetryOutcome: String, Codable, Sendable { case succeeded, failed, cancelled }

struct TelemetrySpan: Sendable {
    let id: UUID
    let operation: TelemetryOperation
    let started: ContinuousClock.Instant
    /// Captures the consent generation, so enabling sharing cannot upload an earlier operation.
    let consentGeneration: UUID
}

enum TelemetryScreen: String, Sendable, CaseIterable {
    case overview, evaluations, batchRuns = "batch_runs", traces, appIntentTesting = "app_intent_testing", suite, run
    case mcpSettings = "mcp_settings", judgeSettings = "judge_settings", privacySettings = "privacy_settings"

    /// Maps navigation destinations to fixed screen categories without including selected run IDs.
    init(selection: SidebarSelection) {
        switch selection {
        case .overview: self = .overview
        case .evaluations: self = .evaluations
        case .batchRuns: self = .batchRuns
        case .traces: self = .traces
        case .appIntentTesting: self = .appIntentTesting
        case .suite: self = .suite
        case .run: self = .run
        }
    }
}

enum TelemetryFeature: String, Sendable, CaseIterable {
    case evaluation
    case suiteSaved = "suite_saved", mcpStarted = "mcp_started", mcpInstalled = "mcp_installed"
    case documentGenerated = "document_generated", suiteImported = "suite_imported", suiteExported = "suite_exported"
    case reviewSaved = "review_saved", batchRun = "batch_run", appIntentRun = "app_intent_run"
    case mcpConnected = "mcp_connected"
    case documentImported = "document_imported", referencesImported = "references_imported"
    case datasetImported = "dataset_imported", resultsExported = "results_exported"

    /// Maps successfully completed workflows to feature use; background storage and model preparation do not count as adoption.
    init?(operation: TelemetryOperation) {
        switch operation {
        case .evaluation: self = .evaluation
        case .suiteSave: self = .suiteSaved
        case .mcpStart: self = .mcpStarted
        case .mcpInstall: self = .mcpInstalled
        case .documentGenerate: self = .documentGenerated
        case .suiteImport: self = .suiteImported
        case .suiteExport: self = .suiteExported
        case .reviewSave: self = .reviewSaved
        case .batchRun: self = .batchRun
        case .appIntentRun: self = .appIntentRun
        case .documentImport: self = .documentImported
        case .referenceImport: self = .referencesImported
        case .datasetImport: self = .datasetImported
        case .resultExport: self = .resultsExported
        default: return nil
        }
    }
}

/// Typed usage and diagnostic events whose payloads use fixed categories and generated correlation IDs.
enum TelemetryEvent: Sendable {
    case appOpened, firstUse
    case screen(TelemetryScreen)
    case featureUsed(TelemetryFeature)
    case operationStarted(TelemetryOperation, UUID)
    case operationFinished(TelemetryOperation, UUID, TelemetryOutcome, Int, TelemetryFailure?)
    case issue(TelemetryOperation, TelemetryFailure, UUID? = nil)

    var isDiagnostic: Bool { Self.isDiagnostic(name: name) }

    /// Identifies the fixed diagnostic event names that require diagnostics consent.
    nonisolated static func isDiagnostic(name: String) -> Bool {
        ["foundation_evals_operation_started", "foundation_evals_operation_finished", "foundation_evals_diagnostic_issue", "$exception"].contains(name)
    }

    var name: String {
        switch self {
        case .appOpened: "foundation_evals_app_opened"
        case .firstUse: "intents_first_use"
        case .screen: "$screen"
        case .featureUsed: "intents_feature_used"
        case .operationStarted: "foundation_evals_operation_started"
        case .operationFinished: "foundation_evals_operation_finished"
        case .issue: "foundation_evals_diagnostic_issue"
        }
    }

    var properties: [String: Any] {
        switch self {
        case .appOpened, .firstUse: return [:]
        case .screen(let screen): return ["$screen_name": screen.rawValue]
        case .featureUsed(let feature): return ["feature": feature.rawValue]
        case .operationStarted(let operation, let id):
            return ["operation": operation.rawValue, "operation_id": id.uuidString]
        case .operationFinished(let operation, let id, let outcome, let duration, let failure):
            var properties: [String: Any] = ["operation": operation.rawValue, "operation_id": id.uuidString,
                "outcome": outcome.rawValue, "duration_ms": max(0, min(duration, 86_400_000))]
            if let failure { properties["error_code"] = failure.rawValue }
            return properties
        case .issue(let operation, let failure, let id):
            var properties: [String: Any] = ["operation": operation.rawValue, "error_code": failure.rawValue]
            if let id { properties["operation_id"] = id.uuidString }
            return properties
        }
    }

    /// Checks known scalar properties against fixed categories, UUID syntax, numeric bounds, or bounded version-string characters.
    nonisolated static func isSafeProperty(_ key: String, value: Any) -> Bool {
        switch key {
        case "app": return value as? String == "intents"
        case "environment": return value as? String == "production"
        case "platform": return value as? String == "macOS"
        case "feature": return (value as? String).flatMap(TelemetryFeature.init(rawValue:)) != nil
        case "$screen_name": return (value as? String).flatMap(TelemetryScreen.init(rawValue:)) != nil
        case "operation": return (value as? String).flatMap(TelemetryOperation.init(rawValue:)) != nil
        case "outcome": return (value as? String).flatMap(TelemetryOutcome.init(rawValue:)) != nil
        case "error_code": return (value as? String).flatMap(TelemetryFailure.init(rawValue:)) != nil
        case "operation_id", "diagnostic_session_id", "$session_id": return (value as? String).flatMap(UUID.init(uuidString:)) != nil
        case "architecture": return ["arm64", "x86_64"].contains(value as? String ?? "")
        case "schema_version": return value as? Int == 2
        case "duration_ms": return (0...86_400_000).contains(value as? Int ?? -1)
        case "os_major": return (1...100).contains(value as? Int ?? -1)
        case "$lib": return value as? String == "posthog-ios"
        case "app_version", "app_build", "os_version", "$lib_version":
            guard let value = value as? String, !value.isEmpty, value.count <= 50 else { return false }
            return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
        case "$process_person_profile", "$geoip_disable": return value is Bool
        default: return false
        }
    }

    /// Returns the event-specific property allowlist, or nil for unknown event names.
    nonisolated static func allowedProperties(for name: String) -> Set<String>? {
        let common: Set<String> = ["app", "environment", "platform", "schema_version", "app_version", "app_build", "os_major", "os_version", "architecture", "$session_id", "$lib", "$lib_version", "$process_person_profile", "$geoip_disable"]
        switch name {
        case "foundation_evals_app_opened", "intents_first_use": return common
        case "$screen": return common.union(["$screen_name"])
        case "intents_feature_used": return common.union(["feature"])
        case "$exception": return common.union(["diagnostic_session_id", "$exception_level", "$exception_list", "$debug_images"])
        case "foundation_evals_operation_started":
            return common.union(["diagnostic_session_id", "operation", "operation_id"])
        case "foundation_evals_operation_finished":
            return common.union(["diagnostic_session_id", "operation", "operation_id", "outcome", "duration_ms", "error_code"])
        case "foundation_evals_diagnostic_issue":
            return common.union(["diagnostic_session_id", "operation", "operation_id", "error_code"])
        default: return nil
        }
    }
}
