import Foundation
import FoundationModels

extension EvaluationPromptInputTokenCounting {
    /// Forwards keyed prompt estimates when a counter does not implement caching.
    func tokenCount(for prompt: Prompt, cacheKey: String) async throws -> Int {
        try await tokenCount(for: prompt)
    }

    /// Forwards keyed instruction estimates without changing the default counting behavior.
    func tokenCount(for instructions: Instructions, cacheKey: String) async throws -> Int {
        try await tokenCount(for: instructions)
    }
}

/// Owned by one frozen native job. Only exact text and empty-history counts are
/// reused; sessions, nonempty transcripts, images, tools and results stay independent.
actor EvaluationCachedPromptInputTokenCounter: EvaluationPromptInputTokenCounting {
    let base: any EvaluationPromptInputTokenCounting
    private let capacity: Int
    private var counts: [Data: Int] = [:]

    /// Creates a cache owned by one frozen job and clamps its entry capacity to at least one.
    init(base: any EvaluationPromptInputTokenCounting = EvaluationSystemPromptInputTokenCounter(), capacity: Int = 128) {
        self.base = base
        self.capacity = max(1, capacity)
    }

    /// Reuses exact UTF-8 keys; oversized inputs bypass storage and failed or cancelled counts are never retained.
    private func count(key: String, compute: () async throws -> Int) async throws -> Int {
        try Task.checkCancellation()
        // Bound retained text as well as entry count (at most 2 MiB by default).
        guard key.utf8.count <= 16_384 else { return try await compute() }
        // Swift String equality folds canonically equivalent Unicode spellings;
        // a tokenizer may distinguish their bytes, so cache exact UTF-8 instead.
        let bytes = Data(key.utf8)
        if let count = counts[bytes] { return count }
        let count = try await compute()
        try Task.checkCancellation()
        if counts.count >= capacity { counts.removeAll(keepingCapacity: true) }
        counts[bytes] = count
        return count
    }

    /// Reuses successful text-prompt estimates in a namespace separate from instructions.
    func tokenCount(for prompt: Prompt, cacheKey: String) async throws -> Int {
        try await count(key: "prompt\0" + cacheKey) { try await base.tokenCount(for: prompt) }
    }

    /// Reuses successful instruction estimates without sharing entries with prompt text.
    func tokenCount(for instructions: Instructions, cacheKey: String) async throws -> Int {
        try await count(key: "instructions\0" + cacheKey) { try await base.tokenCount(for: instructions) }
    }

    /// Counts unkeyed prompts directly, preserving image-aware and opaque prompt behavior.
    func tokenCount(for prompt: Prompt) async throws -> Int { try await base.tokenCount(for: prompt) }
    /// Counts unkeyed instructions directly when the caller cannot supply stable source text.
    func tokenCount(for instructions: Instructions) async throws -> Int { try await base.tokenCount(for: instructions) }
    /// Counts each schema through the underlying model counter without retaining schema identity.
    func tokenCount(for schema: GenerationSchema) async throws -> Int { try await base.tokenCount(for: schema) }
    /// Reuses the real empty-transcript count; every nonempty history is counted independently.
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int {
        guard history.isEmpty else { return try await base.tokenCount(for: history) }
        return try await count(key: "history\0empty") { try await base.tokenCount(for: history) }
    }
    /// Counts tools directly so mutable tool definitions cannot reuse stale estimates.
    func tokenCount(for tools: [any Tool]) async throws -> Int { try await base.tokenCount(for: tools) }
    /// Delegates portable text estimation without introducing a second text cache.
    func tokenCount(forText text: String) async throws -> Int { try await base.tokenCount(forText: text) }
}
