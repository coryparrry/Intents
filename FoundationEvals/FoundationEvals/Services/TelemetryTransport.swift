import Foundation
import OSLog
import zlib

/// A per-consent transport: remote config and all non-event endpoints never reach the network.
/// Revocation invalidates its session, including requests already queued by the SDK.
enum TelemetryForwardingResult {
    case forwarded(URLSessionDataTask)
    case discarded
    case blocked
}

final class TelemetryTransport: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var transports: [String: TelemetryTransport] = [:]
    private let logger = Logger(subsystem: "com.coryparry.FoundationEvals", category: "TelemetryDelivery")
    private let id = UUID().uuidString
    private let host: String?
    private let port: Int
    private let allowsUsage: Bool
    private let allowsDiagnostics: Bool
    private let consentEpoch: UUID?
    private let session: URLSession
    private var stopped = false
    private var deliveryHandler: (@Sendable (TelemetryDelivery) -> Void)?
    private let lock = NSLock()

    /// Creates and registers a transport bound to one HTTPS host, port and optional consent epoch.
    /// The injected session configuration controls the forwarding session; redirects are refused.
    init(host: String, sessionConfiguration: URLSessionConfiguration = .ephemeral,
         allowsUsage: Bool = true, allowsDiagnostics: Bool = false, consentEpoch: UUID? = nil) {
        session = URLSession(configuration: sessionConfiguration, delegate: EvaluationNoRedirectDelegate(), delegateQueue: nil)
        self.host = URL(string: host)?.host
        port = URL(string: host)?.port ?? 443
        self.allowsUsage = allowsUsage
        self.allowsDiagnostics = allowsDiagnostics
        self.consentEpoch = consentEpoch
        Self.lock.withLock { Self.transports[id] = self }
    }

    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Foundation-Telemetry-Session": id]
        return configuration
    }

    /// Resolves the transport named by the private SDK session header, returning nil after it has been unregistered.
    static func lookup(_ request: URLRequest) -> TelemetryTransport? {
        guard let id = request.value(forHTTPHeaderField: "X-Foundation-Telemetry-Session") else { return nil }
        return lock.withLock { transports[id] }
    }

    /// Replaces the delivery callback under the transport lock.
    func setDeliveryHandler(_ handler: @escaping @Sendable (TelemetryDelivery) -> Void) {
        lock.withLock { deliveryHandler = handler }
    }

    /// Forwards only approved HTTPS batch POSTs to the configured host after final payload filtering.
    /// Returns discarded for fully revoked batches and blocked for invalid requests; completion runs only for forwarded network tasks.
    func send(_ request: URLRequest, completion: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> TelemetryForwardingResult {
        lock.withLock {
            guard !stopped, request.url?.host == host, request.url?.scheme == "https",
                  request.url?.path == "/batch", request.httpMethod == "POST",
                  (request.url?.port ?? 443) == port, request.url?.user == nil, request.url?.password == nil,
                  // The SDK serializes an empty queryItems array as a trailing '?'.
                  (request.url?.query?.isEmpty ?? true),
                  let safeBody = sanitizedBody(of: request) else {
                if request.url?.path == "/batch" { deliveryHandler?(.failed) }
                return .blocked
            }
            // Acknowledge revoked events locally so the SDK removes them instead
            // of retrying them ahead of newly authorized events forever.
            guard !safeBody.isEmpty else { return .discarded }
            var request = request
            request.httpBodyStream = nil
            request.httpBody = safeBody
            request.setValue(nil, forHTTPHeaderField: "Content-Length")
            request.setValue(nil, forHTTPHeaderField: "Content-Encoding")
            request.setValue(nil, forHTTPHeaderField: "X-Foundation-Telemetry-Session")
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let accepted = error == nil && (200..<300).contains(status)
                let handler = self?.lock.withLock { self?.stopped == false ? self?.deliveryHandler : nil }
                handler?(accepted ? .accepted : .failed)
                completion(data, response, error)
            }
            task.resume()
            return .forwarded(task)
        }
    }

    /// Final egress gate also covers persisted SDK batches, which bypass beforeSend on replay.
    private func sanitizedBody(of request: URLRequest) -> Data? {
        let encoding = request.value(forHTTPHeaderField: "Content-Encoding")
        guard encoding == nil || encoding == "gzip" else { return nil }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { return nil }
                if count == 0 { break }
                body.append(buffer, count: count)
                guard body.count <= 262_144 else { return nil }
            }
        }
        guard body.count <= 262_144 else { return nil }
        if encoding == "gzip" {
            guard let decompressed = Self.decompress(body) else {
                logger.error("Rejected invalid compressed telemetry batch")
                return nil
            }
            body = decompressed
        }
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let batch = payload["batch"] as? [[String: Any]], batch.count <= 50 else {
            logger.error("Rejected telemetry batch without a bounded JSON batch array")
            return nil
        }
        let safeBatch: [[String: Any]] = batch.compactMap { event in
            guard let name = event["event"] as? String,
                  TelemetryEvent.isDiagnostic(name: name) ? allowsDiagnostics : allowsUsage,
                  TelemetryEvent.allowedProperties(for: name) != nil else { return nil }
            let originalProperties = event["properties"] as? [String: Any] ?? [:]
            if let consentEpoch,
               originalProperties["_intents_consent_epoch"] as? String != consentEpoch.uuidString { return nil }
            guard let properties = TelemetryPayloadFilter.properties(originalProperties, event: name) else { return nil }
            var safe: [String: Any] = ["event": name, "properties": properties.merging([
                "$process_person_profile": false, "$geoip_disable": true
            ]) { _, new in new }]
            for key in ["distinct_id", "uuid"] {
                if let value = event[key] as? String, UUID(uuidString: value) != nil { safe[key] = value }
            }
            if let timestamp = event["timestamp"] as? String, timestamp.count <= 40,
               timestamp.allSatisfy({ $0.isNumber || "-:.TZ+".contains($0) }) {
                safe["timestamp"] = timestamp
            }
            return safe
        }
        guard !safeBatch.isEmpty else { return Data() }
        var safePayload: [String: Any] = ["batch": safeBatch]
        if let key = payload["api_key"] as? String, key.hasPrefix("phc_"), key.count <= 200,
           key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { safePayload["api_key"] = key }
        return try? JSONSerialization.data(withJSONObject: safePayload, options: [.sortedKeys])
    }

    /// Inflates one complete gzip or zlib payload within 256 KiB, rejecting malformed streams, trailing bytes and expansion beyond the limit.
    private static func decompress(_ data: Data) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        return data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            var status: Int32 = Z_OK
            repeat {
                status = buffer.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { return nil }
                result.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
                guard result.count <= 262_144 else { return nil }
            } while status != Z_STREAM_END
            return stream.avail_in == 0 ? result : nil
        }
    }

    /// Revokes this transport, cancels its session and removes it from the request-routing registry.
    func stop() {
        lock.withLock {
            stopped = true
            session.invalidateAndCancel()
        }
        Self.lock.withLock { _ = Self.transports.removeValue(forKey: id) }
    }
}

private final class TelemetryURLProtocol: URLProtocol, @unchecked Sendable {
    private var forwardingTask: URLSessionDataTask?
    /// Intercepts every request on the SDK session so all destinations pass through the transport gate.
    override class func canInit(with request: URLRequest) -> Bool { true }
    /// Preserves the original request for consent and endpoint validation by the registered transport.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// Routes a request through its registered transport and reports forwarded responses without caching.
    /// Locally acknowledges fully revoked batches to drain the SDK queue; that acknowledgment does not report server acceptance.
    override func startLoading() {
        guard let transport = TelemetryTransport.lookup(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let result = transport.send(request) { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            guard let response else { self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        switch result {
        case .forwarded(let task): forwardingTask = task
        case .discarded:
            // This success only drains a revoked queue; it never reports server acceptance.
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .blocked: client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
    }
    /// Cancels the forwarded network task when URL loading stops.
    override func stopLoading() { forwardingTask?.cancel() }
}
