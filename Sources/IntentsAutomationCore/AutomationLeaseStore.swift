import Foundation

struct AutomationLeaseState: Codable {
    var schemaVersion = 1
    var campaigns: [String: Campaign] = [:]
    var generations: [String: Int] = [:]
    struct Campaign: Codable, Equatable, Sendable {
        var runID: String
        var target: TargetIdentity
        var owner: AutomationProcessIdentity
        var ownerToken: String
        var lease: AutomationDeviceLeaseManager.Lease?
        var privatePayload: AutomationDeviceLeaseManager.PrivatePayload?
        var lastDispatch: AutomationDeviceLeaseManager.Dispatch?
        var runners: [AutomationDeviceLeaseManager.OwnedRunner] = []
    }
    func validate() throws {
        guard schemaVersion == 1, campaigns.count <= 256, generations.count <= 256,
              generations.allSatisfy({ !$0.key.isEmpty && $0.value > 0 && $0.value < Int.max }) else {
            throw AutomationContractError.invalidIdentity
        }
        for (key, campaign) in campaigns {
            guard key == campaign.target.leaseKey, !campaign.runID.isEmpty, campaign.owner.pid > 0,
                  !campaign.owner.startIdentity.isEmpty, !campaign.ownerToken.isEmpty,
                  let generation = generations[key] else { throw AutomationContractError.invalidIdentity }
            if let lease = campaign.lease {
                guard lease.runID == campaign.runID, lease.target == campaign.target, lease.generation == generation else {
                    throw AutomationContractError.invalidIdentity
                }
            }
            if let dispatch = campaign.lastDispatch {
                try dispatch.scope.validate()
                guard dispatch.scope.runId == campaign.runID, dispatch.scope.leaseGeneration <= generation,
                      !dispatch.operationID.isEmpty, dispatch.payloadDigest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                    throw AutomationContractError.invalidIdentity
                }
            }
            if let payload = campaign.privatePayload {
                try payload.validate()
                guard let lease = campaign.lease, payload.scope.runId == campaign.runID,
                      payload.scope.leaseGeneration == lease.generation else { throw AutomationContractError.invalidIdentity }
            }
            guard campaign.runners.count <= 16 else { throw AutomationContractError.invalidIdentity }
            for runner in campaign.runners {
                try runner.scope.validate()
                guard runner.scope.runId == campaign.runID, runner.scope.leaseGeneration <= generation,
                      runner.process.pid > 0, !runner.process.startIdentity.isEmpty,
                      runner.executablePath.hasPrefix("/") else { throw AutomationContractError.invalidIdentity }
            }
        }
    }
}

struct AutomationLeaseStore: Sendable {
    let file: AutomationDurableFile
    init(url: URL) throws { file = try .init(url: url, maximumBytes: 1_048_576) }
    func transaction<T>(_ body: (inout AutomationLeaseState) throws -> T) throws -> T {
        try file.withLock {
            var state = try load()
            let result = try body(&state)
            try state.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try file.write(encoder.encode(state))
            return result
        }
    }
    func read() throws -> AutomationLeaseState { try file.withLock { try load() } }
    private func load() throws -> AutomationLeaseState {
        let state = try file.read().map { try JSONDecoder().decode(AutomationLeaseState.self, from: $0) } ?? AutomationLeaseState()
        try state.validate(); return state
    }
}
