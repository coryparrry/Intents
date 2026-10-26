import Foundation

public struct DeveloperFeatureContext: Sendable {
    public var requestID: UUID
    public var runID: UUID
    public var deadline: Date

    /// Creates execution correlation and a wall-clock deadline for a feature invocation.
    /// - Parameters:
    ///   - requestID: Identity of this invocation, also used to route cancellation.
    ///   - runID: Host run that owns the invocation.
    ///   - deadline: Deadline cutoff checked by ``checkCancellation()``.
    public init(requestID: UUID, runID: UUID, deadline: Date) {
        self.requestID = requestID
        self.runID = runID
        self.deadline = deadline
    }

    /// Checks cooperative task cancellation and then the execution deadline.
    /// - Throws: `CancellationError` if the task is cancelled, or a
    ///   ``DeveloperExecutionFailure`` with `deadlineExceeded` if the deadline has elapsed.
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
    var inputContract: DeveloperFeatureInputContract
    var invoke: @Sendable (Data, DeveloperFeatureContext) async throws -> DeveloperFeatureOutput
}

public actor DeveloperFeatureRegistry {
    private var features: [String: AnyDeveloperFeature] = [:]
    private var tasks: [UUID: Task<DeveloperFeatureOutput, Error>] = [:]

    /// Creates an empty registry with no registered features or active executions.
    public init() {}

    public var descriptors: [DeveloperFeatureDescriptor] {
        features.values.map(\.descriptor).sorted { $0.displayName < $1.displayName }
    }

    /// Registers or replaces a feature that decodes typed JSON input and encodes typed output.
    /// The registration uses the legacy input contract and removes any subject-input capability
    /// and schema from the supplied descriptor. Cancellation and deadlines are checked before
    /// and after the operation; they do not interrupt an operation that ignores cancellation.
    /// - Parameters:
    ///   - descriptor: Feature identity, version and declared input/output names advertised to hosts.
    ///   - input: Type used to decode the request's JSON input.
    ///   - output: Type returned by the operation and encoded into the result.
    ///   - operation: App-owned work invoked after input decoding succeeds.
    ///   - response: Produces the human-readable response from the operation's output.
    ///   - usage: Extracts token counts from the output.
    ///   - metadata: Extracts app-defined result metadata.
    public func register<Input: Decodable & Sendable, Output: Encodable & Sendable>(
        _ descriptor: DeveloperFeatureDescriptor,
        input: Input.Type = Input.self,
        output: Output.Type = Output.self,
        operation: @escaping @Sendable (Input, DeveloperFeatureContext) async throws -> Output,
        response: @escaping @Sendable (Output) -> String,
        usage: @escaping @Sendable (Output) -> DeveloperFeatureUsage = { _ in .init() },
        metadata: @escaping @Sendable (Output) -> [String: String] = { _ in [:] }
    ) {
        var legacyDescriptor = descriptor
        legacyDescriptor.subjectInputSchema = nil
        legacyDescriptor.capabilityNames.removeAll { $0 == DeveloperSubjectInputSchema.capabilityName }
        features[descriptor.id] = AnyDeveloperFeature(descriptor: legacyDescriptor, inputContract: .legacyTypedV1) { data, context in
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

    /// Registers or replaces a legacy text feature using ``DeveloperTextFeatureInput``.
    /// Invalid JSON becomes an `invalidInput` failure. The operation's output is returned
    /// unchanged, with cancellation and deadline checks before and after invocation.
    /// - Parameters:
    ///   - id: Stable registry key; an existing registration at this key is replaced.
    ///   - displayName: Label advertised to the desktop.
    ///   - version: Exact version required by execution requests.
    ///   - capabilityNames: Additional capabilities advertised with this feature.
    ///   - operation: App-owned text operation, including its output and usage metadata.
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
        features[id] = AnyDeveloperFeature(descriptor: descriptor, inputContract: .legacyTypedV1) { data, context in
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

    /// Registers an app-owned mapping for the expectation-free combined workflow.
    /// This is separate from the historical typed and text registration paths.
    ///
    /// The schema validates business inputs before the operation runs; decoding rejects unknown
    /// top-level fields. Cancellation and deadlines are checked around the operation.
    /// - Parameters:
    ///   - id: Stable registry key; an existing registration at this key is replaced.
    ///   - displayName: Label advertised to the desktop.
    ///   - version: Exact version required by execution requests.
    ///   - outputTypeName: App-declared name of the output represented by the result.
    ///   - inputSchema: Allowed business fields and types, excluding assessment inputs.
    ///   - capabilityNames: Additional capabilities; the subject-input capability is added automatically.
    ///   - operation: App-owned mapping from validated subject input to feature output.
    public func registerSubjectFeature(
        id: String,
        displayName: String,
        version: String,
        outputTypeName: String,
        inputSchema: DeveloperSubjectInputSchema,
        capabilityNames: [String] = [],
        operation: @escaping @Sendable (DeveloperSubjectInput, DeveloperFeatureContext) async throws -> DeveloperFeatureOutput
    ) {
        let descriptor = DeveloperFeatureDescriptor(
            id: id,
            displayName: displayName,
            version: version,
            inputTypeName: String(reflecting: DeveloperSubjectInput.self),
            outputTypeName: outputTypeName,
            capabilityNames: Array(Set(capabilityNames + [DeveloperSubjectInputSchema.capabilityName])).sorted(),
            subjectInputSchema: inputSchema
        )
        features[id] = AnyDeveloperFeature(descriptor: descriptor, inputContract: .subjectV1) { data, context in
            let input: DeveloperSubjectInput
            do {
                input = try JSONDecoder().decode(DeveloperSubjectInput.self, from: data)
            } catch {
                throw DeveloperExecutionFailure(code: .invalidInput, message: "The expectation-free subject input is invalid or contains unsupported fields.")
            }
            try inputSchema.validate(input)
            try context.checkCancellation()
            let output = try await operation(input, context)
            try context.checkCancellation()
            return output
        }
    }

    /// Removes a feature registration without cancelling invocations already started.
    /// - Parameter featureID: Registry key to remove; unknown keys have no effect.
    public func unregister(featureID: String) {
        features[featureID] = nil
    }

    /// Runs a request and returns its terminal output or structured failure.
    /// Admission validates request identity, feature/version, input contract and deadline.
    /// Operation errors and cooperative cancellation are represented in the result's `failure`.
    /// - Parameter request: JSON input and execution identity for a registered feature.
    /// - Returns: A result preserving the request, run and feature identifiers.
    public func execute(_ request: DeveloperFeatureExecutionRequest) async -> DeveloperFeatureExecutionResult {
        await start(request).value
    }

    /// Validates admission and records the operation task before returning its result task.
    /// Duplicate active request IDs and incompatible registrations return immediate failures;
    /// accepted operations retain their registration even if the feature is later replaced.
    func start(_ request: DeveloperFeatureExecutionRequest) -> Task<DeveloperFeatureExecutionResult, Never> {
        let startedAt = Date()
        guard tasks[request.id] == nil else {
            let result = failure(request, startedAt: startedAt, code: .invalidInput,
                                 message: "An execution with this request ID is already active.")
            return Task { result }
        }
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
        guard (request.inputContract ?? .legacyTypedV1) == feature.inputContract else {
            let result = failure(request, startedAt: startedAt, code: .unsupportedInputContract,
                                 message: "This feature does not support the requested input contract. Rebuild the app with expectation-free subject input support, or use a legacy standalone feature run.")
            return Task { result }
        }
        if feature.inputContract == .subjectV1 {
            guard feature.descriptor.inputTypeName == request.inputTypeName,
                  feature.descriptor.subjectInputSchema != nil,
                  feature.descriptor.capabilityNames.contains(DeveloperSubjectInputSchema.capabilityName) else {
                let result = failure(request, startedAt: startedAt, code: .unsupportedInputContract,
                                     message: "The app has not declared a compatible subject input schema and capability.")
                return Task { result }
            }
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

    /// Awaits an admitted operation, maps its error to a wire failure and releases its request ID.
    /// Cancellation becomes `cancelled`; declared execution failures retain their code, while
    /// other errors become `executionFailed` with their localized description.
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

    /// Requests cooperative cancellation of the active operation with this request ID.
    /// Unknown or completed IDs have no effect; the operation must observe cancellation to stop.
    /// - Parameter requestID: Identity from the execution request, rather than its run ID.
    public func cancel(requestID: UUID) {
        tasks[requestID]?.cancel()
    }

    /// Requests cooperative cancellation of every active operation without unregistering features.
    public func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
    }

    /// Builds a terminal failure with the original execution identifiers and a completion timestamp.
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
