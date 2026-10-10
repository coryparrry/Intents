import Foundation

/// JSON transport vocabulary. Exact business numbers remain tagged strings in AutomationValue.
public indirect enum AutomationJSON: Codable, Equatable, Sendable {
    case object([String: AutomationJSON]), array([AutomationJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count < 40 else { throw AutomationRPCError.invalidFrame }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? container.decode([AutomationJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: AutomationJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): guard value.isFinite else { throw AutomationRPCError.invalidFrame }; try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    public var object: [String: AutomationJSON]? { if case .object(let value) = self { value } else { nil } }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
}

public enum AutomationRPCError: Error, Equatable, Sendable {
    case invalidFrame, requestLimit, disconnected, timedOut, dispatchedOutcomeUnknown, cancelled
    case remote(code: Int, message: String)
}

/// A continuously draining, bounded endpoint: reverse requests never block the reply reader.
public actor AutomationRPC {
    public typealias Sender = @Sendable (Data) async throws -> Void
    public typealias ReverseHandler = @Sendable (String, AutomationJSON) async throws -> AutomationJSON
    public enum Method: String, Sendable {
        case hello, inventory, probe, acquire = "ui.acquire", runSegment = "ui.runSegment", secretRunProgram = "secret.runProgram", release = "ui.release", cancel, status, shutdown
        var mutating: Bool { self == .acquire || self == .runSegment || self == .secretRunProgram || self == .release || self == .cancel || self == .shutdown }
    }
    private struct Pending {
        var continuation: CheckedContinuation<AutomationJSON, any Error>
        var method: Method
        var timeout: Task<Void, Never>
    }
    private var buffer = Data()
    private var pending: [String: Pending] = [:]
    private var reverseIDs: Set<String> = []
    private var reverseTasks: [String: Task<Void, Never>] = [:]
    private var sequence = 0
    private var closed = false
    private let send: Sender
    private let reverse: ReverseHandler
    public init(send: @escaping Sender, reverse: @escaping ReverseHandler) { self.send = send; self.reverse = reverse }

    public func request(_ method: Method, params: AutomationJSON, timeout: Duration = .seconds(30)) async throws -> AutomationJSON {
        guard !closed else { throw AutomationRPCError.disconnected }
        guard pending.count < 64 else { throw AutomationRPCError.requestLimit }
        try Task.checkCancellation()
        sequence += 1; let id = "host-\(sequence)"
        let frame = try Self.frame(.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method.rawValue), "params": params]))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.expire(id)
                }
                pending[id] = Pending(continuation: continuation, method: method, timeout: timer)
                Task {
                    do { try await send(frame) }
                    catch { fail(id, error: method.mutating ? AutomationRPCError.dispatchedOutcomeUnknown : .disconnected) }
                }
            }
        } onCancel: { Task { await self.cancelPending(id) } }
    }
    public func receive(_ bytes: Data) throws {
        guard !closed else { return }
        buffer.append(bytes)
        do {
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard line.count <= 1_048_576, String(data: line, encoding: .utf8) != nil else { throw AutomationRPCError.invalidFrame }
                let value = try JSONDecoder().decode(AutomationJSON.self, from: line)
                try accept(value)
            }
            guard buffer.count <= 1_048_576 else { throw AutomationRPCError.invalidFrame }
        } catch { close(); throw error }
    }
    private func accept(_ value: AutomationJSON) throws {
        guard let fields = value.object, fields["jsonrpc"] == .string("2.0"), let id = fields["id"]?.string,
              !id.isEmpty, id.utf8.count <= 128 else { throw AutomationRPCError.invalidFrame }
        if let method = fields["method"]?.string {
            guard Set(fields.keys) == ["jsonrpc", "id", "method", "params"],
                  ["policy.reviewAction", "controller.decide", "mac.helper.run", "mac.helper.stop", "ui.workerStarted", "secret.fillBinding"].contains(method), let params = fields["params"],
                  reverseIDs.count < 16, reverseIDs.insert(id).inserted else { throw AutomationRPCError.invalidFrame }
            reverseTasks[id] = Task {
                let response: AutomationJSON
                do { response = .object(["jsonrpc": .string("2.0"), "id": .string(id), "result": try await reverse(method, params)]) }
                catch { response = .object(["jsonrpc": .string("2.0"), "id": .string(id), "error": .object(["code": .number(-32000), "message": .string("Host request was denied")])]) }
                guard !closed, !Task.isCancelled else { return }
                do { try await send(Self.frame(response)) } catch { close() }
                reverseIDs.remove(id); reverseTasks.removeValue(forKey: id)
            }
        } else {
            let isResult = fields["result"] != nil, isError = fields["error"] != nil
            guard isResult != isError, Set(fields.keys) == ["jsonrpc", "id", isResult ? "result" : "error"] else { throw AutomationRPCError.invalidFrame }
            // A late response after timeout is discarded, never applied to another operation.
            guard let operation = pending.removeValue(forKey: id) else {
                guard id.hasPrefix("host-"), let issued = Int(id.dropFirst(5)), issued > 0, issued <= sequence else { throw AutomationRPCError.invalidFrame }
                return
            }
            operation.timeout.cancel()
            if let result = fields["result"] { operation.continuation.resume(returning: result) }
            else if let error = fields["error"]?.object, case .number(let code) = error["code"], code.rounded() == code,
                    code >= Double(Int32.min), code <= Double(Int32.max), let message = error["message"]?.string,
                    message.utf8.count <= 4096, Set(error.keys) == ["code", "message"] {
                operation.continuation.resume(throwing: AutomationRPCError.remote(code: Int(code), message: message))
            } else { operation.continuation.resume(throwing: AutomationRPCError.invalidFrame); throw AutomationRPCError.invalidFrame }
        }
    }
    private func expire(_ id: String) {
        guard let item = pending[id] else { return }
        fail(id, error: item.method.mutating ? .dispatchedOutcomeUnknown : .timedOut)
    }
    private func cancelPending(_ id: String) {
        guard let item = pending[id] else { return }
        fail(id, error: item.method.mutating ? .dispatchedOutcomeUnknown : .cancelled)
    }
    private func fail(_ id: String, error: AutomationRPCError) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.timeout.cancel(); item.continuation.resume(throwing: error)
    }
    public func close() {
        closed = true; buffer.removeAll()
        for task in reverseTasks.values { task.cancel() }
        reverseTasks.removeAll(); reverseIDs.removeAll()
        for id in Array(pending.keys) { fail(id, error: pending[id]!.method.mutating ? .dispatchedOutcomeUnknown : .disconnected) }
    }
    private static func frame(_ value: AutomationJSON) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_048_576 else { throw AutomationRPCError.invalidFrame }
        return data + Data([10])
    }
}
