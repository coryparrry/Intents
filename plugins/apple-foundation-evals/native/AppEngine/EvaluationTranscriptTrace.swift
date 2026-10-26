import Foundation
import FoundationModels

@available(macOS 27.0, *)
enum EvaluationTranscriptCaptureOutcome: String, Codable, Equatable, Sendable {
    case success
    case failure
}

@available(macOS 27.0, *)
struct EvaluationTranscriptTrace: Codable, Equatable, Sendable {
    static let maximumEncodedBytes = 4 * 1_024 * 1_024
    static let formatIdentifier = "com.apple.FoundationModels.Transcript+json"

    var format = Self.formatIdentifier
    var outcome: EvaluationTranscriptCaptureOutcome
    var entryCount: Int
    var encodedByteCount: Int?
    var transcriptJSON: Data?
    var omissionReason: String?

    /// Encodes the transcript as bounded Foundation Models JSON, preserving the original outcome and entry count when encoding fails or capture is omitted.
    static func capture(
        _ transcript: Transcript,
        outcome: EvaluationTranscriptCaptureOutcome,
        maximumBytes: Int = Self.maximumEncodedBytes
    ) -> Self {
        do {
            let data = try JSONEncoder().encode(transcript)
            guard data.count <= maximumBytes else {
                return Self(
                    outcome: outcome,
                    entryCount: transcript.count,
                    encodedByteCount: data.count,
                    omissionReason: "The encoded transcript exceeded the \(maximumBytes)-byte capture limit."
                )
            }
            return Self(
                outcome: outcome,
                entryCount: transcript.count,
                encodedByteCount: data.count,
                transcriptJSON: data
            )
        } catch {
            return Self(
                outcome: outcome,
                entryCount: transcript.count,
                encodedByteCount: nil,
                omissionReason: "Foundation Models could not encode this transcript: \(error.localizedDescription)"
            )
        }
    }

    /// Restores a transcript only from the supported archive format with available JSON; throws for omitted data or decoding failures.
    func restoredTranscript() throws -> Transcript {
        guard format == Self.formatIdentifier else {
            throw EvaluationTranscriptArchiveError.unsupportedFormat(format)
        }
        guard let transcriptJSON else {
            throw EvaluationTranscriptArchiveError.transcriptUnavailable(omissionReason)
        }
        return try JSONDecoder().decode(Transcript.self, from: transcriptJSON)
    }

}

@available(macOS 27.0, *)
enum EvaluationTranscriptArchiveError: LocalizedError {
    case unsupportedFormat(String)
    case transcriptUnavailable(String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            "Unsupported transcript format: \(format)"
        case .transcriptUnavailable(let reason):
            reason ?? "The transcript was not captured."
        }
    }
}
