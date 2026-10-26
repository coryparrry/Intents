import Foundation

/// Captures only requests dispatched by this app's HTTP implementations. No
/// request/response contents, headers, URL credentials, query or fragment persist.
@available(macOS 27.0, *)
struct EvaluationWorkflowHTTPRequest {
    private let recorder: EvaluationWorkflowRecorder
    private let spanID: UUID
    var statusCode: Int?
    var responseBytes = 0

    /// Begins a child HTTP span only when a recorder and parent span are available, retaining a sanitized endpoint and byte count.
    init?(recorder: EvaluationWorkflowRecorder?, parentID: UUID?, endpoint: URL, requestBytes: Int) {
        guard let recorder, let parentID else { return nil }
        self.recorder = recorder
        let safeEndpoint = Self.sanitizedEndpoint(endpoint)
        spanID = recorder.begin(kind: .httpRequest, title: "POST \(endpoint.path.isEmpty ? "/" : endpoint.path)",
            parentID: parentID, metadata: [
                "method": "POST", "endpoint": safeEndpoint, "requestBytes": String(requestBytes),
                "timingScope": "Request dispatch through response consumption"
            ])
    }

    /// Finishes the HTTP span with response size, optional status, and a diagnostic that excludes URL credentials and response bodies.
    /// The supplied error determines failure or cancellation status; a non-2xx code supplies a message without independently changing status.
    func finish(error: Error? = nil) {
        var metadata = ["responseBytes": String(responseBytes)]
        if let statusCode { metadata["statusCode"] = String(statusCode) }
        let status = error.map(EvaluationWorkflowRecorder.status(for:)) ?? .succeeded
        let message: String?
        if status == .cancelled {
            message = "The HTTP request was cancelled."
        } else if let statusCode, !(200...299).contains(statusCode) {
            message = "The endpoint returned HTTP \(statusCode)."
        } else if let error {
            // NSError descriptions can contain a credential-bearing failing URL or
            // backend body. Keep the error code; sample/tool detail retains its policy.
            let failure = error as NSError
            message = "Request or response processing failed (\(failure.domain), code \(failure.code))."
        } else {
            message = nil
        }
        recorder.finish(spanID, status: status, errorMessage: message, metadata: metadata)
    }

    /// Removes URL user information, query, and fragment before recording an endpoint, returning an unavailable marker if reconstruction fails.
    static func sanitizedEndpoint(_ endpoint: URL) -> String {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return "Unavailable" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "Unavailable"
    }
}
