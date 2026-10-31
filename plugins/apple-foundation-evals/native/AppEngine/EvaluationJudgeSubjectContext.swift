import Foundation
import FoundationModels

/// Observed input to the scored generation, independent of optional transcript tracing.
/// Only semantic content belongs here; provider metadata and local attachment paths do not.
@available(macOS 27.0, *)
struct EvaluationJudgeSubjectContext: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var role: String
        var content: String
    }

    static let maximumBytes = 512 * 1_024
    var formatVersion = 1
    var entries: [Entry] = []
    var subjectInstructions: String? = nil
    var unavailableReason: String? = nil

    /// Captures semantic model-facing history and instructions within the encoded evidence byte limit.
    /// Unsupported entries, historical attachments, or oversized evidence produce an unavailable context with no retained entries.
    static func capture(_ history: [Transcript.Entry], instructions: String) -> Self {
        var context = Self(subjectInstructions: instructions)
        do {
            context.entries = try history.map { entry in
                switch entry {
                case .instructions(let value): return Entry(role: "instructions", content: try text(value.segments))
                case .prompt(let value): return Entry(role: "user", content: try text(value.segments))
                case .response(let value): return Entry(role: "assistant", content: try text(value.segments))
                case .reasoning(let value): return Entry(role: "reasoning", content: try text(value.segments))
                case .toolOutput(let value):
                    return Entry(role: "tool output", content: "\(value.toolName) [\(value.id)]: \(try text(value.segments))")
                case .toolCalls(let calls):
                    return Entry(role: "tool calls", content: calls.map {
                        "\($0.toolName) [\($0.id)]: \($0.arguments.jsonString)"
                    }.joined(separator: "\n"))
                case .data: throw ContextError.unavailable("The model-facing history contains a data entry that cannot be represented as judge text.")
                @unknown default: throw ContextError.unavailable("The model-facing history contains an unsupported entry.")
                }
            }
            guard try JSONEncoder().encode(context).count <= maximumBytes else {
                throw ContextError.unavailable("The model-facing history exceeds the judge evidence capture limit.")
            }
        } catch {
            context.entries = []
            context.unavailableReason = error.localizedDescription
        }
        return context
    }

    /// Validates the saved evidence format, availability, and encoded byte limit for its current instructions.
    func validated() throws -> Self {
        try admittingInstructionVariants([subjectInstructions])
    }

    /// Validate every reachable profile state before generation, retaining the
    /// largest encoded context for admission. JSON escaping, rather than String
    /// length, determines the evidence bound. This does not alter frozen history.
    func admittingInstructionVariants(_ instructions: [String?]) throws -> Self {
        guard formatVersion == 1 else { throw ContextError.unavailable("The saved conversation evidence format is unsupported.") }
        if let unavailableReason { throw ContextError.unavailable(unavailableReason) }
        var largest = self
        var largestBytes = 0
        for instructions in instructions.isEmpty ? [subjectInstructions] : instructions {
            var candidate = self
            candidate.subjectInstructions = instructions
            let byteCount = try JSONEncoder().encode(candidate).count
            guard byteCount <= Self.maximumBytes else {
                throw ContextError.unavailable("The saved conversation evidence exceeds its capture limit.")
            }
            if byteCount >= largestBytes {
                largest = candidate
                largestBytes = byteCount
            }
        }
        return largest
    }

    /// Old single-turn runs remain usable. Configured multi-turn inputs cannot stand
    /// in for the actual generated setup responses or their model-facing projection.
    static func resolved(_ saved: Self?, evaluationCase: EvaluationCase) throws -> Self {
        if let saved { return try saved.validated() }
        let configuration = evaluationCase.conversation
        guard configuration.setupTurns.isEmpty,
              configuration.restoredTranscriptJSON?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw ContextError.unavailable("This saved multi-turn response has no frozen model-facing history. Run the case again before reassessing it.")
        }
        return Self()
    }

    var evidenceText: String {
        // Array encoding retains entry boundaries and roles without interpreting content.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(entries)) ?? Data(), as: UTF8.self)
    }

    /// Joins text and structured transcript segments into semantic evidence, throwing for attachments or unsupported segment kinds.
    private static func text(_ segments: [Transcript.Segment]) throws -> String {
        try segments.map { segment in
            switch segment {
            case .text(let text): return text.content
            case .structure(let structure): return structure.content.jsonString
            case .attachment:
                throw ContextError.unavailable("The model-facing history contains an attachment whose historical pixels are not frozen for judging.")
            @unknown default:
                throw ContextError.unavailable("The model-facing history contains an unsupported segment.")
            }
        }.joined(separator: "\n")
    }

    enum ContextError: Error, LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let message): message }
        }
    }
}
