#if os(macOS)
import AppIntentsTesting
import AppIntents
import Foundation
import Darwin
import XCTest

/// Separate calibration entrypoint. It never calls run or emits business-dispatch receipts.
@MainActor
final class InputAdapterProbeTests: XCTestCase {
    private struct ParameterReceipt: Codable { let name: String; let family: String; let samples: [HostValue]; let entityType: String? }
    func testParameterRoundTrip() throws {
        guard let encoded = ProcessInfo.processInfo.environment["INTENTS_AUTOMATION_INPUT_PROBE_B64"],
              encoded.utf8.count <= 43_692, let data = Data(base64Encoded: encoded) else { throw HostError.invalidPlan }
        let plan = try HostInputAdapterProbePlan.decode(data)
        let definitions = IntentDefinitions(bundleIdentifier: plan.bundleID)
        let definition = definitions.intents[plan.actionID]
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var results: [ParameterReceipt] = []
        for parameter in plan.parameters {
            var echoes: [HostValue] = []
            for (index, sample) in parameter.samples.enumerated() {
                guard ContinuousClock.now < deadline else { throw HostError.invalidPlan }
                var intent = definition.makeIntent()
                try HostIntentIdentity.validate(bundle: plan.bundleID, action: plan.actionID, definitionsBundle: definitions.bundleIdentifier,
                    definitionBundle: definition.bundleIdentifier, definitionID: definition.identifier, intentBundle: intent.bundleIdentifier, intentID: intent.identifier)
                try IntentDefinitionsHost.assign(sample, name: parameter.name, codec: parameter.family, intent: &intent, definitions: definitions)
                let echo: HostValue
                if parameter.family == "intentFile" {
                    let value: IntentFile = try intent[dynamicMember: parameter.name]
                    echo = try HostIntentFileCodec.encode(data: value.data, filename: value.filename, typeIdentifier: value.type?.identifier,
                        operationID: parameter.name + ":" + String(index))
                    let (expectedData, expectedMetadata) = try HostIntentFileCodec.decode(sample)
                    guard echo.fileData == expectedData, echo.file == expectedMetadata, let bytes = echo.fileData, let name = echo.value else {
                        throw HostError.unsupportedCodec("File adapter readback mismatch")
                    }
                    let binary = XCTAttachment(data: bytes, uniformTypeIdentifier: expectedMetadata.typeIdentifier ?? "public.data")
                    binary.name = name; binary.lifetime = .keepAlways; add(binary)
                } else {
                    echo = try read(intent, name: parameter.name, family: parameter.family)
                    guard try encoder.encode(echo) == encoder.encode(sample) else { throw HostError.unsupportedCodec("Input adapter readback mismatch") }
                }
                echoes.append(echo)
            }
            results.append(.init(name: parameter.name, family: parameter.family, samples: echoes, entityType: parameter.entityType))
        }
        try HostValueBudget.validate(results.flatMap(\.samples))
        var kernel = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &kernel, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size,
              let executablePath = Bundle.main.executableURL?.path,
              var receipt = try JSONSerialization.jsonObject(with: encoder.encode(plan)) as? [String: Any] else { throw HostError.invalidPlan }
        let runner = HostReceipt.Runner(pid: getpid(), startIdentity: "\(kernel.kp_proc.p_un.__p_starttime.tv_sec):\(kernel.kp_proc.p_un.__p_starttime.tv_usec)", executablePath: executablePath)
        receipt["runner"] = try JSONSerialization.jsonObject(with: encoder.encode(runner))
        receipt["parameters"] = try JSONSerialization.jsonObject(with: encoder.encode(results))
        if let context = HostReceipt.RuntimeContext.observe(testBundle: Bundle(for: Self.self)) { receipt["runtimeContext"] = try JSONSerialization.jsonObject(with: encoder.encode(context)) }
        receipt["complete"] = true
        let result = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .withoutEscapingSlashes])
        guard result.count <= 1_048_576 else { throw HostError.invalidPlan }
        let attachment = XCTAttachment(data: result, uniformTypeIdentifier: "public.json")
        attachment.name = "intents-input-adapter-probe"; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func boundedText(_ text: String) throws {
        guard text.utf8.count <= 128 else { throw HostError.unsupportedCodec("Probe text exceeds its fixed sample budget") }
    }
    private func boundedCollection(_ count: Int) throws {
        guard count <= 1 else { throw HostError.unsupportedCodec("Probe collection exceeds its fixed sample budget") }
    }
    private func read(_ intent: AnyAppIntent, name: String, family: String) throws -> HostValue {
        switch family {
        case "entity":
            let value: AnyAppEntity = try intent[dynamicMember: name]
            let id = value.identifier.instanceIdentifier, type = value.identifier.entityType.persistentIdentifier
            try boundedText(id); guard type.utf8.count <= 256 else { throw HostError.invalidPlan }
            return .init(kind: "entity", value: id, typeId: type)
        case "text": let value: String = try intent[dynamicMember: name]; try boundedText(value); return .init(kind: "text", value: value)
        case "bool": let value: Bool = try intent[dynamicMember: name]; return .init(kind: "bool", boolValue: value)
        case "integer": let value: Int = try intent[dynamicMember: name]; return .init(kind: "integer", value: String(value))
        case "decimal": let value: Double = try intent[dynamicMember: name]; return .init(kind: "decimal", value: try HostDecimalCodec.encode(value))
        case "date": let value: Date = try intent[dynamicMember: name]; return try HostDateCodec.encode(value)
        case "url": let value: URL = try intent[dynamicMember: name]; return try HostURLCodec.encode(value)
        case "duration": let value: Duration = try intent[dynamicMember: name]; return try HostDurationCodec.encode(value)
        case "calendarComponents": let value: DateComponents = try intent[dynamicMember: name]; return try HostCalendarCodec.encode(value)
        case "textArray": let value: [String] = try intent[dynamicMember: name]; try boundedCollection(value.count); try value.forEach(boundedText); return .init(kind: "array", items: value.map { .init(kind: "text", value: $0) })
        case "boolArray": let value: [Bool] = try intent[dynamicMember: name]; try boundedCollection(value.count); return .init(kind: "array", items: value.map { .init(kind: "bool", boolValue: $0) })
        case "integerArray": let value: [Int] = try intent[dynamicMember: name]; try boundedCollection(value.count); return .init(kind: "array", items: value.map { .init(kind: "integer", value: String($0)) })
        case "decimalArray": let value: [Double] = try intent[dynamicMember: name]; try boundedCollection(value.count); return .init(kind: "array", items: try value.map { .init(kind: "decimal", value: try HostDecimalCodec.encode($0)) })
        case "dateArray": let value: [Date] = try intent[dynamicMember: name]; try boundedCollection(value.count); return .init(kind: "array", items: try value.map(HostDateCodec.encode))
        default: throw HostError.unsupportedCodec(family)
        }
    }
}
#endif

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
