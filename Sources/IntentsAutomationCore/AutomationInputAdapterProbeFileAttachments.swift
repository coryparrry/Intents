#if os(macOS)
import Foundation
import IntentsAutomationDateCodec

/// Fixed synthetic file canary. A JSON echo alone cannot prove the binary channel.
enum AutomationInputAdapterProbeFileAttachments {
    static func importExport(root: URL, plan: AutomationInputAdapterProbePlan, scope: AutomationScope,
                             artifacts: AutomationArtifactRegistry) async throws -> (Data, AutomationInputAdapterProbeObservation) {
        let entries = try AutomationHostFileAttachments.exportEntries(root: root, testIdentifier: "InputAdapterProbeTests/testParameterRoundTrip()")
        guard let filename = entries["intents-input-adapter-probe"] else { throw AutomationContractError.missingEvidence("Unique input probe receipt required") }
        let data = try AutomationReadOnlyFile.read(root: root, relativePath: filename, maximumBytes: 1_048_576, requirePrivateOwnership: true)
        guard let fields = try JSONDecoder().decode(AutomationJSON.self, from: data).object,
              case .array(let parameters) = fields["parameters"], parameters.count == plan.parameters.count else { throw AutomationContractError.invalidIdentity }
        var claims: [(name: String, operationID: String, metadata: AutomationIntentFileMetadata, data: Data)] = []
        var placeholders: [String: [AutomationValue]] = [:], allowed: Set<String> = ["intents-input-adapter-probe"]
        for (parameter, field) in zip(plan.parameters, parameters) where parameter.family == "intentFile" {
            guard case .array(let samples) = field.object?["samples"], samples.count == parameter.samples.count else { throw AutomationContractError.invalidIdentity }
            for (index, value) in samples.enumerated() {
                let operationID = parameter.name + ":" + String(index), descriptor = try AutomationHostFileDescriptor(value, operationID: operationID)
                guard descriptor.metadata == (try AutomationIntentFileCalibration.metadata()), let exported = entries[descriptor.attachmentName] else {
                    throw AutomationContractError.missingEvidence("Exact file calibration attachment required")
                }
                let bytes = try AutomationReadOnlyFile.read(root: root, relativePath: exported, maximumBytes: 8192, requirePrivateOwnership: true)
                try descriptor.metadata.verify(bytes)
                guard bytes == AutomationIntentFileCalibration.data else { throw AutomationContractError.conflictingOperation }
                claims.append((parameter.name, operationID, descriptor.metadata, bytes)); allowed.insert(descriptor.attachmentName)
                placeholders[parameter.name, default: []].append(.artifact(handle: "validated-calibration-file", sha256: descriptor.metadata.sha256))
            }
        }
        guard !claims.isEmpty, Set(entries.keys) == allowed else { throw AutomationContractError.missingEvidence("Unclaimed file calibration attachment") }
        _ = try AutomationInputAdapterProbeObservation.readValidated(data, plan: plan, scope: scope, fileValues: placeholders)
        var outputs: [String: [AutomationValue]] = [:]
        for claim in claims {
            let artifact = try await artifacts.storeNativeEvidence(data: claim.data, scope: scope, metadata: claim.metadata,
                provenance: .init(planDigest: plan.digest, operationID: claim.operationID, receiptDigest: AutomationArtifactRegistry.digest(data)))
            outputs[claim.name, default: []].append(.artifact(handle: artifact.handle, sha256: artifact.sha256))
        }
        return (data, try AutomationInputAdapterProbeObservation.readValidated(data, plan: plan, scope: scope, fileValues: outputs))
    }
}
#endif
