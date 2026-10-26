import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

private actor CacheTestCounter: EvaluationPromptInputTokenCounting {
    var prompts = 0, instructions = 0, histories = 0
    var failNext = false
    /// Makes the next prompt count fail so the test can detect accidental caching of failures.
    func failOnce() { failNext = true }
    /// Returns prompt, instruction and history invocation counts for cache-hit assertions.
    func calls() -> (Int, Int, Int) { (prompts, instructions, histories) }
    /// Counts prompt requests and can fail once before returning a stable nonzero estimate.
    func tokenCount(for prompt: Prompt) async throws -> Int {
        prompts += 1
        if failNext { failNext = false; throw CancellationError() }
        return 11
    }
    /// Tracks instruction counts separately from prompts with a distinct estimate.
    func tokenCount(for instructions: Instructions) async throws -> Int { self.instructions += 1; return 7 }
    /// Provides a zero-cost schema estimate for text-only cache fixtures.
    func tokenCount(for schema: GenerationSchema) async throws -> Int { 0 }
    /// Returns distinct empty and nonempty history counts to detect lost history admission costs.
    func tokenCount(for history: [Transcript.Entry]) async throws -> Int {
        histories += 1
        return history.isEmpty ? 3 : 17
    }
    /// Provides a tool-count stub for fixtures that do not exercise tool caching.
    func tokenCount(for tools: [any Tool]) async throws -> Int { 0 }
    /// Provides a portable text estimate matching the prompt fixture.
    func tokenCount(forText text: String) async throws -> Int { 11 }
}

struct EvaluationTokenCountCacheTests {
    /// Checks that empty-history caching preserves its real cost while nonempty histories always delegate.
    @Test func emptyHistoryRetainsTheRealCountAndNonemptyHistoryAlwaysDelegates() async throws {
        let base = CacheTestCounter()
        let cached = EvaluationCachedPromptInputTokenCounter(base: base)
        for _ in 0..<1000 {
            let estimate = try await EvaluationInputTokenCounter.historyEstimate([], using: cached)
            #expect(estimate.count == 3 && estimate.imageTokenCountAvailable)
        }
        let history: [Transcript.Entry] = [.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "history"))]))]
        for _ in 0..<2 { #expect(try await cached.tokenCount(for: history) == 17) }
        #expect(await base.calls().2 == 3)
        let otherJob = EvaluationCachedPromptInputTokenCounter(base: base)
        #expect(try await otherJob.tokenCount(for: [Transcript.Entry]()) == 3)
        #expect(await base.calls().2 == 4)
    }
    /// Checks 1,000 repeated preparations reuse exact text without changing context admission.
    @Test func repeatedPreparationUsesExactTextAndKeepsAdmissionUnchanged() async throws {
        let base = CacheTestCounter()
        let cached: any EvaluationPromptInputTokenCounting = EvaluationCachedPromptInputTokenCounter(base: base)
        let runner = EvaluationRunner()
        var suite = EvaluationSuite()
        suite.scoringMode = .exactMatch
        suite.instructions = "Answer only the question."
        suite.modelConfiguration.maximumResponseTokens = 128
        for _ in 0..<20 {
            for i in 0..<50 {
                let item = EvaluationCase(name: "Case", prompt: "Question \(i)", expected: "Answer")
                let result = try await runner.preparedPrompt(for: item, suite: suite, images: [], contextSize: 8192, tools: [], tokenCounter: cached)
                #expect(result.tokenCount == 18)
                #expect(result.text == item.prompt)
            }
        }
        let calls = await base.calls()
        #expect(calls.0 == 50 && calls.1 == 1)
        suite.instructions = "Changed instructions."
        _ = try await runner.preparedPrompt(for: .init(name: "Case", prompt: "Question 0", expected: "Answer"), suite: suite, images: [], contextSize: 8192, tools: [], tokenCounter: cached)
        #expect(await base.calls().1 == 2)
    }

    /// Checks namespace and job isolation, failed-count retries, and distinct Unicode byte spellings.
    @Test func domainsFailuresAndJobsCannotShareCounts() async throws {
        let base = CacheTestCounter()
        let cached: any EvaluationPromptInputTokenCounting = EvaluationCachedPromptInputTokenCounter(base: base)
        #expect(try await cached.tokenCount(for: Prompt("same"), cacheKey: "same") == 11)
        #expect(try await cached.tokenCount(for: Instructions("same"), cacheKey: "same") == 7)
        await base.failOnce()
        await #expect(throws: CancellationError.self) {
            try await cached.tokenCount(for: Prompt("retry"), cacheKey: "retry")
        }
        #expect(try await cached.tokenCount(for: Prompt("retry"), cacheKey: "retry") == 11)
        let secondJob = EvaluationCachedPromptInputTokenCounter(base: base)
        _ = try await secondJob.tokenCount(for: Prompt("same"), cacheKey: "same")
        #expect(await base.calls().0 == 4)
        // Canonically equal Swift strings can have different tokenizer inputs.
        for text in ["\u{00E9}", "e\u{0301}"] {
            _ = try await cached.tokenCount(for: Prompt(text), cacheKey: text)
        }
        #expect(await base.calls().0 == 6)
    }

    /// Checks capacity eviction and that oversized keys are never retained.
    @Test func cacheCapacityAndLargeInputsAreBounded() async throws {
        let base = CacheTestCounter()
        let cached = EvaluationCachedPromptInputTokenCounter(base: base, capacity: 2)
        for key in ["a", "b", "c", "a"] { _ = try await cached.tokenCount(for: Prompt(key), cacheKey: key) }
        let long = String(repeating: "x", count: 16_385)
        for _ in 0..<2 { _ = try await cached.tokenCount(for: Prompt(long), cacheKey: long) }
        // Calls without an exact text key (including structured prompts) always delegate.
        for _ in 0..<2 { _ = try await cached.tokenCount(for: Prompt("a")) }
        #expect(await base.calls().0 == 8)
    }
}
