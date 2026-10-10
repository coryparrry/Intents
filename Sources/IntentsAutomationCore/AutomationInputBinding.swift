import Foundation

public struct AutomationInputBinding: Codable, Equatable, Sendable {
    public enum Destination: String, Codable, Sendable { case uiBinding, hostParameter, hostQueryIDs }
    public var producerSegmentID: String
    public var outputID: String
    public var destination: Destination
    public var operationID: String?
    public var name: String
    public var uniqueEntity: AutomationEntitySelection?
    public var parameterCodec: String?
    public init(producerSegmentID: String, outputID: String, destination: Destination, operationID: String? = nil, name: String, uniqueEntity: AutomationEntitySelection? = nil, parameterCodec: String? = nil) {
        self.producerSegmentID = producerSegmentID; self.outputID = outputID; self.destination = destination; self.operationID = operationID; self.name = name
        self.uniqueEntity = uniqueEntity; self.parameterCodec = parameterCodec
    }
}
public enum AutomationInputBindingError: Error, Equatable, Sendable { case inputUnavailable }
struct AutomationFileDestination: Hashable, Sendable { let operationID: String, parameterName: String }
/// Minted only from correlated producer receipts; never decoded from a frozen/model plan.
struct AutomationFileTransferPermit: Sendable {
    let producerScope: AutomationScope
    let handle: String, sha256: String, planDigest: String, outputID: String, receiptDigest: String
    let destination: AutomationFileDestination
    fileprivate init(producerScope: AutomationScope, handle: String, sha256: String, planDigest: String, outputID: String, receiptDigest: String, destination: AutomationFileDestination) {
        self.producerScope = producerScope; self.handle = handle; self.sha256 = sha256; self.planDigest = planDigest; self.outputID = outputID; self.receiptDigest = receiptDigest; self.destination = destination
    }
}
/// In-memory evidence produced only by the resolver from the reviewed template and correlated receipts.
/// It cannot be decoded from a model program or persisted as input authority.
struct AutomationSegmentResolutionAuthority: Sendable {
    fileprivate let fileTransfers: [AutomationFileTransferPermit]
    fileprivate let planDigest: String, segmentData: Data, runID: String, attemptID: String
    func fileInputs(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, artifacts: AutomationArtifactRegistry) async throws -> [AutomationFileDestination: AutomationJSON] {
        try scope.validate()
        guard try matches(plan: plan, segment: segment, scope: scope) else { throw AutomationContractError.unknownLease }
        var inputs: [AutomationFileDestination: AutomationJSON] = [:]
        for permit in fileTransfers {
            guard permit.producerScope.leaseGeneration < scope.leaseGeneration, inputs[permit.destination] == nil,
                  segment.hostProgram?.operations.first(where: { $0.id == permit.destination.operationID })?.parameters[permit.destination.parameterName] == .artifact(handle: permit.handle, sha256: permit.sha256) else { throw AutomationInputBindingError.inputUnavailable }
            inputs[permit.destination] = try await artifacts.fileInput(permit)
        }
        return inputs
    }
    func matches(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try planDigest == AutomationFrozenCase.planDigest(plan) && segmentData == encoder.encode(segment)
            && runID == scope.runId && attemptID == scope.attemptId && segment.id == scope.segmentId
    }
}
protocol AutomationResolvedRouteDriver: AutomationRouteDriver {
    func acquireResolved(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope,
                         lease: AutomationDeviceLeaseManager.Lease, authority: AutomationSegmentResolutionAuthority) async throws
}
public enum AutomationInputResolver {
    static let deferredParameterCodecs: Set<String> = ["textArray", "boolArray", "integerArray", "decimalArray", "dateArray", "duration", "calendarComponents", "intentFile"]
    static func resolveForExecution(segment: AutomationSegment, receipts: [AutomationSegmentReceipt], plan: AutomationCase,
                                    runID: String, attemptID: String) throws -> (segment: AutomationSegment, authority: AutomationSegmentResolutionAuthority) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let reviewedData = try encoder.encode(segment)
        guard try (plan.setup + [plan.execution] + plan.observations + plan.cleanup).contains(where: { try encoder.encode($0) == reviewedData }) else {
            throw AutomationContractError.conflictingOperation
        }
        try validate(plan: plan)
        let resolved = try resolve(segment: segment, receipts: receipts, plan: plan, runID: runID, attemptID: attemptID)
        let transfers = try (segment.inputBindings ?? []).filter { $0.parameterCodec == "intentFile" }.map { binding in
            guard let receipt = receipts.first(where: { $0.segmentID == binding.producerSegmentID }),
                  case .artifact(let handle, let digest) = receipt.verifiedOutputs?[binding.outputID], let operationID = binding.operationID,
                  let receiptDigest = receipt.hostReceiptDigest, receiptDigest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw AutomationInputBindingError.inputUnavailable }
            return AutomationFileTransferPermit(producerScope: receipt.scope, handle: handle, sha256: digest, planDigest: try AutomationFrozenCase.planDigest(plan), outputID: binding.outputID, receiptDigest: receiptDigest,
                destination: .init(operationID: operationID, parameterName: binding.name))
        }
        return (resolved, try .init(fileTransfers: transfers, planDigest: AutomationFrozenCase.planDigest(plan), segmentData: encoder.encode(resolved), runID: runID, attemptID: attemptID))
    }
    public static func validate(plan: AutomationCase) throws {
        let ordered = plan.setup + [plan.execution] + plan.observations + plan.cleanup
        var seen = Set<String>()
        let producers = Set(plan.setup.map(\.id))
        for segment in ordered {
            let bindings = segment.inputBindings ?? []
            guard bindings.count <= 30, Set(bindings.map { "\($0.destination.rawValue):\($0.operationID ?? ""):\($0.name)" }).count == bindings.count else {
                throw AutomationContractError.invalidPlan("Duplicate input binding destination")
            }
            for binding in bindings {
                guard seen.contains(binding.producerSegmentID), producers.contains(binding.producerSegmentID),
                      [binding.producerSegmentID, binding.outputID, binding.name].allSatisfy(identifier) else { throw AutomationContractError.invalidPlan("Binding requires a preceding setup producer") }
                if let codec = binding.parameterCodec {
                    guard binding.destination == .hostParameter, binding.uniqueEntity == nil,
                          deferredParameterCodecs.contains(codec) else { throw AutomationContractError.invalidPlan("Unsupported deferred parameter codec") }
                }
                let producer = plan.setup.first { $0.id == binding.producerSegmentID }!
                let declared = producer.uiProgram?.operations.contains { $0.kind == .observeProperty && $0.id == binding.outputID } == true
                    || producer.hostProgram?.operations.contains { $0.id == binding.outputID } == true
                guard declared else { throw AutomationContractError.invalidPlan("Producer has no verified output declaration") }
                if let selection = binding.uniqueEntity {
                    guard [AutomationInputBinding.Destination.hostParameter, .hostQueryIDs].contains(binding.destination), producer.kind == .systemQuery,
                          let query = producer.hostProgram?.operations.first(where: { $0.id == binding.outputID }) else {
                        throw AutomationContractError.invalidPlan("Entity selection requires a preceding real query")
                    }
                    try selection.validate(query: query)
                }
                switch binding.destination {
                case .uiBinding:
                    guard binding.operationID == nil, segment.phase != .observe, let program = segment.uiProgram,
                          program.bindings[binding.name] == nil,
                          program.operations.contains(where: { $0.binding == binding.name }) || program.operations.contains(where: { $0.kind == .navigateGoal }) else {
                        throw AutomationContractError.invalidPlan("Invalid UI input destination or literal replacement")
                    }
                case .hostQueryIDs:
                    guard binding.name == "queryIDs", binding.uniqueEntity != nil, segment.kind == .systemQuery, segment.effects.isSubset(of: [.observe]),
                          let operationID = binding.operationID, identifier(operationID),
                          let operation = segment.hostProgram?.operations.first(where: { $0.id == operationID }), operation.kind == .query,
                          operation.queryIDs == nil, operation.queryText == nil, operation.attemptQueryPrefix == nil else {
                        throw AutomationContractError.invalidPlan("Query identity binding cannot replace a selector")
                    }
                case .hostParameter:
                    guard let operationID = binding.operationID, identifier(operationID),
                          let operation = segment.hostProgram?.operations.first(where: { $0.id == operationID }), operation.kind == .invoke,
                          operation.parameters[binding.name] == nil, operation.parameterCodecs?[binding.name] == nil else { throw AutomationContractError.invalidPlan("Invalid host input destination or literal replacement") }
                    if let codec = binding.parameterCodec {
                        guard producer.hostProgram?.operations.contains(where: {
                            $0.id == binding.outputID && $0.kind == .invoke && $0.resultCodec == codec
                        }) == true else { throw AutomationContractError.invalidPlan("Deferred codec requires a matching typed host producer") }
                    }
                }
            }
            seen.insert(segment.id)
        }
    }
    public static func resolve(segment: AutomationSegment, receipts: [AutomationSegmentReceipt], plan: AutomationCase, runID: String, attemptID: String) throws -> AutomationSegment {
        var resolved = segment
        for (name, prefix) in segment.attemptTextBindings ?? [:] {
            guard resolved.uiProgram?.bindings[name] == nil else { throw AutomationInputBindingError.inputUnavailable }
            resolved.uiProgram?.bindings[name] = try AutomationAttemptText.value(prefix: prefix, attemptID: attemptID)
        }
        resolved.attemptTextBindings = nil
        for index in 0..<(resolved.hostProgram?.operations.count ?? 0) {
            if let prefix = resolved.hostProgram?.operations[index].attemptQueryPrefix {
                guard resolved.hostProgram?.operations[index].queryText == nil, resolved.hostProgram?.operations[index].queryIDs == nil else { throw AutomationInputBindingError.inputUnavailable }
                resolved.hostProgram?.operations[index].queryText = try AutomationAttemptText.value(prefix: prefix, attemptID: attemptID)
                resolved.hostProgram?.operations[index].attemptQueryPrefix = nil
            }
        }
        for binding in segment.inputBindings ?? [] {
            let candidates = receipts.filter { $0.segmentID == binding.producerSegmentID }
            guard candidates.count == 1, let receipt = candidates.first,
                  receipt.completed, receipt.dispatched, receipt.app == plan.app, receipt.target == plan.target, receipt.environmentID == nil || receipt.environmentID == plan.environmentID,
                  receipt.scope.runId == runID, receipt.scope.attemptId == attemptID, receipt.scope.segmentId == binding.producerSegmentID,
                  receipt.route == plan.setup.first(where: { $0.id == binding.producerSegmentID })?.kind,
                  let output = receipt.verifiedOutputs?[binding.outputID] else { throw AutomationInputBindingError.inputUnavailable }
            let value: AutomationValue
            if let selection = binding.uniqueEntity {
                guard receipt.environmentID == plan.environmentID,
                      let query = plan.setup.first(where: { $0.id == binding.producerSegmentID })?.hostProgram?.operations.first(where: { $0.id == binding.outputID }) else {
                    throw AutomationInputBindingError.inputUnavailable
                }
                value = try selection.resolve(output, query: query, attemptID: attemptID)
            } else { value = output }
            if binding.parameterCodec != nil {
                guard receipt.environmentID == plan.environmentID, value != .null, value != .omission else { throw AutomationInputBindingError.inputUnavailable }
                do { try value.validate() } catch { throw AutomationInputBindingError.inputUnavailable }
            } else { try value.validate() }
            switch binding.destination {
            case .uiBinding:
                guard case .text(let text) = value, resolved.uiProgram?.bindings[binding.name] == nil else { throw AutomationContractError.invalidPlan("UI binding requires observed text") }
                resolved.uiProgram?.bindings[binding.name] = text
            case .hostQueryIDs:
                guard case .entity(let type, let id) = value,
                      let index = resolved.hostProgram?.operations.firstIndex(where: { $0.id == binding.operationID }),
                      resolved.hostProgram?.operations[index].typeID == type, resolved.hostProgram?.operations[index].queryIDs == nil,
                      resolved.hostProgram?.operations[index].queryText == nil else { throw AutomationInputBindingError.inputUnavailable }
                resolved.hostProgram?.operations[index].queryIDs = [id]
            case .hostParameter:
                guard let index = resolved.hostProgram?.operations.firstIndex(where: { $0.id == binding.operationID }), resolved.hostProgram?.operations[index].parameters[binding.name] == nil else { throw AutomationContractError.invalidPlan("Missing host binding destination") }
                var operation = resolved.hostProgram!.operations[index]
                guard operation.parameterCodecs?[binding.name] == nil else { throw AutomationContractError.invalidPlan("Binding cannot replace a frozen parameter codec") }
                if let codec = binding.parameterCodec {
                    guard deferredParameterCodecs.contains(codec) else { throw AutomationInputBindingError.inputUnavailable }
                    operation.parameterCodecs = operation.parameterCodecs ?? [:]
                    operation.parameterCodecs?[binding.name] = codec
                }
                operation.parameters[binding.name] = value
                do {
                    _ = try AutomationHostProgram.hostInput(value, parameterCodec: binding.parameterCodec)
                    try AutomationHostProgram(operations: [operation]).validate(route: resolved.kind, phase: resolved.phase)
                } catch { throw AutomationInputBindingError.inputUnavailable }
                resolved.hostProgram?.operations[index] = operation
            }
        }
        return resolved
    }
    private static func identifier(_ value: String) -> Bool {
        value.utf16.count <= 256 && value.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil
    }
}
