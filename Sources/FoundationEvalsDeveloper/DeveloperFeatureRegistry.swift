import Foundation

public struct DeveloperFeatureContext: Sendable {
    public var requestID: UUID
    public var runID: UUID
    public var deadline: Date

    public init(requestID: UUID, runID: UUID, deadline: Date) {
        self.requestID = requestID
        self.runID = runID
        self.deadline = deadline
    }

    public func checkCancellation() throws {
        try Task.checkCancellation()
        guard Date() < deadline else {
            throw DeveloperExecutionFailure(
                code: .deadlineExceeded,
                message: "The feature execution exceeded its deadline."
            )
        }
    }
}

private struct AnyDeveloperFeature: Sendable {
    var descriptor: DeveloperFeatureDescriptor
    var invoke: @Sendable (Data, DeveloperFeatureContext) async throws -> DeveloperFeatureOutput
}

public actor DeveloperFeatureRegistry {
    private var features: [String: AnyDeveloperFeature] = [:]
    private var tasks: [UUID: Task<DeveloperFeatureOutput, Error>] = [:]

    public init() {}

    public var descriptors: [DeveloperFeatureDescriptor] {
        features.values.map(\.descriptor).sorted { $0.displayName < $1.displayName }
    }

    public func register<Input: Decodable & Sendable, Output: Encodable & Sendable>(
        _ descriptor: DeveloperFeatureDescriptor,
        input: Input.Type = Input.self,
        output: Output.Type = Output.self,
        operation: @escaping @Sendable (Input, DeveloperFeatureContext) async throws -> Output,
        response: @escaping @Sendable (Output) -> String,
        usage: @escaping @Sendable (Output) -> DeveloperFeatureUsage = { _ in .init() },
        metadata: @escaping @Sendable (Output) -> [String: String] = { _ in [:] }
    ) {
        features[descriptor.id] = AnyDeveloperFeature(descriptor: descriptor) { data, context in
            let value: Input
            do {
                value = try JSONDecoder().decode(Input.self, from: data)
            } catch {
                throw DeveloperExecutionFailure(
                    code: .invalidInput,
                    message: "The input for \(descriptor.displayName) could not be decoded as \(descriptor.inputTypeName)."
                )
            }
            try context.checkCancellation()
            let result = try await operation(value, context)
            try context.checkCancellation()
            return DeveloperFeatureOutput(
                response: response(result),
                encodedValue: try JSONEncoder().encode(result),
                encodedValueTypeName: descriptor.outputTypeName,
                usage: usage(result),
                metadata: metadata(result)
            )
        }
    }

    public func registerTextFeature(
        id: String,
        displayName: String,
        version: String,
        capabilityNames: [String] = [],
        operation: @escaping @Sendable (DeveloperTextFeatureInput, DeveloperFeatureContext) async throws -> DeveloperFeatureOutput
    ) {
        let descriptor = DeveloperFeatureDescriptor(
            id: id,
            displayName: displayName,
            version: version,
            inputTypeName: String(reflecting: DeveloperTextFeatureInput.self),
            outputTypeName: String(reflecting: DeveloperFeatureOutput.self),
            capabilityNames: capabilityNames
        )
        features[id] = AnyDeveloperFeature(descriptor: descriptor) { data, context in
            let input: DeveloperTextFeatureInput
            do {
                input = try JSONDecoder().decode(DeveloperTextFeatureInput.self, from: data)
            } catch {
                throw DeveloperExecutionFailure(code: .invalidInput, message: "The text feature input is invalid.")
            }
            try context.checkCancellation()
            let output = try await operation(input, context)
            try context.checkCancellation()
            return output
        }
    }

    public func unregister(featureID: String) {
        features[featureID] = nil
    }

    public func execute(_ request: DeveloperFeatureExecutionRequest) async -> DeveloperFeatureExecutionResult {
        await start(request).value
    }

    func start(_ request: DeveloperFeatureExecutionRequest) -> Task<DeveloperFeatureExecutionResult, Never> {
        let startedAt = Date()
        guard let feature = features[request.featureID] else {
            let result = failure(request, startedAt: startedAt, code: .featureNotFound,
                                 message: "The runner does not expose feature \(request.featureID).")
            return Task { result }
        }
        guard feature.descriptor.version == request.featureVersion else {
            let result = failure(request, startedAt: startedAt, code: .incompatibleFeatureVersion,
                                 message: "The requested feature version is not available on this runner.")
            return Task { result }
        }
        guard Date() < request.deadline else {
            let result = failure(request, startedAt: startedAt, code: .deadlineExceeded,
                                 message: "The feature execution deadline elapsed before dispatch.")
            return Task { result }
        }

        let context = DeveloperFeatureContext(
            requestID: request.id,
            runID: request.runID,
            deadline: request.deadline
        )
        let task = Task {
            try await feature.invoke(request.encodedInput, context)
        }
        tasks[request.id] = task
        return Task { await self.complete(request, startedAt: startedAt, task: task) }
    }

    private func complete(
        _ request: DeveloperFeatureExecutionRequest,
        startedAt: Date,
        task: Task<DeveloperFeatureOutput, Error>
    ) async -> DeveloperFeatureExecutionResult {
        defer { tasks[request.id] = nil }
        do {
            let output = try await task.value
            return DeveloperFeatureExecutionResult(
                requestID: request.id,
                runID: request.runID,
                featureID: request.featureID,
                startedAt: startedAt,
                completedAt: Date(),
                output: output
            )
        } catch is CancellationError {
            return failure(
                request,
                startedAt: startedAt,
                code: .cancelled,
                message: "The feature execution was cancelled."
            )
        } catch let failure as DeveloperExecutionFailure {
            return self.failure(
                request,
                startedAt: startedAt,
                code: failure.code,
                message: failure.message
            )
        } catch {
            return failure(
                request,
                startedAt: startedAt,
                code: .executionFailed,
                message: error.localizedDescription
            )
        }
    }

    public func cancel(requestID: UUID) {
        tasks[requestID]?.cancel()
    }

    public func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
    }

    private func failure(
        _ request: DeveloperFeatureExecutionRequest,
        startedAt: Date,
        code: DeveloperExecutionErrorCode,
        message: String
    ) -> DeveloperFeatureExecutionResult {
        DeveloperFeatureExecutionResult(
            requestID: request.id,
            runID: request.runID,
            featureID: request.featureID,
            startedAt: startedAt,
            completedAt: Date(),
            failure: .init(code: code, message: message)
        )
    }
}
