#if os(iOS) && !targetEnvironment(simulator)
import AppIntentsTesting
import AppIntents
import Foundation
import Darwin
import XCTest

/// Physical qualification only constructs an intent and reads its assigned members.
/// It never calls run/perform and never emits a business-operation receipt.
@MainActor
final class PhysicalInputAdapterProbeTests: XCTestCase {
    func testRecordBoolRoundTrip() throws {
        guard let encoded = ProcessInfo.processInfo.environment["INTENTS_AUTOMATION_INPUT_PROBE_B64"],
              let data = Data(base64Encoded: encoded), data.count <= 32_768,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == ["schemaVersion", "purpose", "runID", "attemptID", "segmentID", "leaseGeneration", "bundleID", "targetID", "environmentID", "productDigest", "hostProductDigest", "xctestrunDigest", "sourceDigest", "templateDigest", "catalogDigest", "baselineDigest", "actionID", "entityMember", "boolMember", "entityType", "entityID", "sdkBuild", "xcodeBuild"],
              fields["schemaVersion"] as? Int == 1, fields["purpose"] as? String == "physicalRecordBoolInputAdapter",
              let generation = fields["leaseGeneration"] as? Int, generation > 0,
              let bundle = fields["bundleID"] as? String, let action = fields["actionID"] as? String,
              let member = fields["entityMember"] as? String, let boolMember = fields["boolMember"] as? String,
              let type = fields["entityType"] as? String, let id = fields["entityID"] as? String,
              !id.isEmpty, id.utf16.count <= 1024, !id.contains("\0"), member != boolMember,
              [bundle, action, member, boolMember, type].allSatisfy({ $0.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]{0,255}$"#, options: .regularExpression) != nil }),
              let info = Bundle(for: Self.self).infoDictionary,
              info["DTPlatformName"] as? String == "iphoneos", info["DTSDKBuild"] as? String == fields["sdkBuild"] as? String,
              info["DTXcodeBuild"] as? String == fields["xcodeBuild"] as? String else { throw HostError.invalidPlan }
        let definitions = IntentDefinitions(bundleIdentifier: bundle), definition = definitions.intents[action]
        var booleans: [Bool] = [], entityID: String?, entityType: String?
        for state in [false, true] {
            var intent = definition.makeIntent()
            try HostIntentIdentity.validate(bundle: bundle, action: action, definitionsBundle: definitions.bundleIdentifier,
                definitionBundle: definition.bundleIdentifier, definitionID: definition.identifier, intentBundle: intent.bundleIdentifier, intentID: intent.identifier)
            intent[dynamicMember: member] = definitions.entities[type].makeReference(identifier: id)
            intent[dynamicMember: boolMember] = state
            let readEntity: AnyAppEntity = try intent[dynamicMember: member]
            let readBool: Bool = try intent[dynamicMember: boolMember]
            guard readEntity.identifier.instanceIdentifier == id, readEntity.identifier.entityType.persistentIdentifier == type, readBool == state else { throw HostError.invalidPlan }
            entityID = readEntity.identifier.instanceIdentifier; entityType = readEntity.identifier.entityType.persistentIdentifier
            booleans.append(readBool)
        }
        var kernel = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size, mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var buildBuffer = [CChar](repeating: 0, count: 256), buildSize = 256
        guard sysctl(&mib, 4, &kernel, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size,
              sysctlbyname("kern.osversion", &buildBuffer, &buildSize, nil, 0) == 0, buildSize > 1, buildSize <= buildBuffer.count,
              let executable = Bundle.main.executableURL?.path else { throw HostError.invalidPlan }
        var receipt = fields
        receipt["runner"] = ["pid": getpid(), "startIdentity": "\(kernel.kp_proc.p_un.__p_starttime.tv_sec):\(kernel.kp_proc.p_un.__p_starttime.tv_usec)", "executablePath": executable]
        receipt["osBuild"] = String(cString: buildBuffer); receipt["complete"] = true
        receipt["echoedEntityID"] = entityID; receipt["echoedEntityType"] = entityType; receipt["echoedBooleans"] = booleans
        let result = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .withoutEscapingSlashes])
        let attachment = XCTAttachment(data: result, uniformTypeIdentifier: "public.json")
        attachment.name = "intents-physical-input-adapter"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
