import Foundation
import FoundationModels

extension EvaluationPromptInputTokenCounting {
    func tokenCount(for prompt: Prompt, cacheKey: String) async throws -> Int {
        try await tokenCount(for: prompt)
    }

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

    init(base: any EvaluationPromptInputTokenCounting = EvaluationSystemPromptInputTokenCounter(), capacity: Int = 128) {
        self.base = base
        self.capacity = max(1, capacity)
    }

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

    func tokenCount(for prompt: Prompt, cacheKey: String) async throws -> Int {
        try await count(key: "prompt\0" + cacheKey) { try await base.tokenCount(for: prompt) }
    }

    func tokenCount(for instructions: Instructions, cacheKey: String) async throws -> Int {
        try await count(key: "instructions\0" + cacheKey) { try await base.tokenCount(for: instructions) }
    }

    func tokenCount(for prompt: Prompt) async throws -> Int { try await base.tokenCount(for: prompt) }
    func tokenCount(for instructions: Instructions) async throws -> Int { try await base.tokenCount(for: instructions) }
    func tokenCount(for schema: GenerationSchema) async throws -> Int { try await base.tokenCount(for: schema) }
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int {
        guard history.isEmpty else { return try await base.tokenCount(for: history) }
        return try await count(key: "history\0empty") { try await base.tokenCount(for: history) }
    }
    func tokenCount(for tools: [any Tool]) async throws -> Int { try await base.tokenCount(for: tools) }
    func tokenCount(forText text: String) async throws -> Int { try await base.tokenCount(forText: text) }
}
