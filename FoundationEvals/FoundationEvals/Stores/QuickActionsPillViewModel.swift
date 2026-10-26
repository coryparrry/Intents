import Foundation
import Observation

typealias QuickActionsRewriteStreamProvider = @Sendable (
    QuickActionsPillRequest,
    String
) -> AsyncThrowingStream<String, Error>

/// Owns one prompt-revision session. The pill never knows about cases or prompts.
@MainActor
@Observable
final class QuickActionsPillViewModel {
    private(set) var originalSnapshot = ""
    private(set) var previewText: String?
    private(set) var phase: QuickActionsPillPhase = .idle
    private(set) var request: QuickActionsPillRequest?
    private(set) var errorMessage: String?
    var prompt = ""
    @ObservationIgnored private var playback: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let generate: QuickActionsRewriteStreamProvider

    struct Request: Equatable {
        let id: String
        let prompt: String?
        let busyLabel: String
    }

    /// Creates a main-actor rewrite session using the supplied streaming provider or the default rewrite service.
    init(
        generate: @escaping QuickActionsRewriteStreamProvider = QuickActionsRewriteService.stream
    ) {
        self.generate = generate
    }

    var isBusy: Bool {
        switch phase {
        case .idle, .result: false
        case .thinking, .streaming: true
        }
    }

    /// The returned handle completes after the session has published its terminal state.
    /// Callers may await it without polling UI state or assuming a scheduling deadline.
    @discardableResult
    func select(_ action: QuickActionsPillAction, source: String) -> Task<Void, Never>? {
        guard action.isEnabled, phase == .idle else { return nil }
        return begin(.init(id: action.id, prompt: nil, busyLabel: action.busyLabel), source: source)
    }

    /// Starts an idle session from a nonempty trimmed custom prompt and returns its terminal-state task.
    /// Returns nil when the prompt is empty or another session phase owns the pill.
    @discardableResult
    func submit(source: String) -> Task<Void, Never>? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .idle else { return nil }
        return begin(.init(id: "prompt", prompt: trimmed, busyLabel: "Editing"), source: source)
    }

    /// Starts another revision from a completed result's retained request using the supplied current source.
    /// Returns nil without a result/request or when source validation fails.
    @discardableResult
    func retry(source: String) -> Task<Void, Never>? {
        guard phase == .result, let request else { return nil }
        return begin(request, source: source)
    }

    /// Compare and return on the main actor, with no suspension between checking
    /// the host's current source and returning the value for its synchronous commit.
    func keep(source: String) -> String? {
        guard phase == .result, let previewText else { return nil }
        guard source == originalSnapshot else {
            errorMessage = "The prompt changed after this revision started. Your edits were kept. Retry using the current prompt, or discard this preview."
            return nil
        }
        let kept = previewText
        dismiss()
        return kept
    }

    /// The host owns the committed text; dismissal only clears session state.
    func dismiss() {
        playback?.cancel()
        playback = nil
        generation = UUID()
        previewText = nil
        request = nil
        prompt = ""
        errorMessage = nil
        phase = .idle
    }

    /// Captures nonempty source and starts a generation-bound streaming rewrite, returning its task.
    /// Publishes only for the current generation; completion enters result, while cancellation or error clears busy state.
    private func begin(_ request: QuickActionsPillRequest, source: String) -> Task<Void, Never>? {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            errorMessage = "Enter a prompt before using quick actions."
            return nil
        }
        originalSnapshot = source
        errorMessage = nil
        playback?.cancel()
        let token = UUID()
        generation = token
        self.request = request
        previewText = nil
        phase = .thinking(request.busyLabel)

        let task = Task { [weak self] in
            do {
                var didStream = false
                let emptyStream = AsyncThrowingStream<String, Error> { $0.finish() }
                let stream = self?.generate(request, source) ?? emptyStream
                for try await partial in stream {
                    try Task.checkCancellation()
                    guard self?.generation == token else { return }
                    self?.phase = .streaming(request.busyLabel)
                    self?.previewText = partial
                    didStream = true
                }
                try Task.checkCancellation()
                guard self?.generation == token else { return }
                guard didStream, self?.previewText != nil else {
                    throw QuickActionsRewriteError.emptyResponse
                }
                self?.phase = .result
                self?.playback = nil
            } catch is CancellationError {
                // A newer session owns its state; cancelling this handle must not
                // leave the current session permanently stuck in its busy phase.
                guard self?.generation == token else { return }
                self?.previewText = nil
                self?.request = nil
                self?.phase = .idle
                self?.playback = nil
            } catch {
                guard self?.generation == token else { return }
                self?.previewText = nil
                self?.request = nil
                self?.phase = .idle
                self?.errorMessage = error.localizedDescription
                self?.playback = nil
            }
        }
        playback = task
        return task
    }
}

typealias QuickActionsPillRequest = QuickActionsPillViewModel.Request
