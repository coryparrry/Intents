#if os(macOS)
import AppIntentsTesting
import AppIntents
import Foundation
import Darwin
import XCTest

/// Separate calibration entrypoint. It never calls run or emits business-dispatch receipts.
@MainActor
final class InputAdapterProbeTests: XCTestCase {
    private struct ParameterReceipt: Codable { let name: String; let family: String; let samples: [HostValue] }
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
            results.append(.init(name: parameter.name, family: parameter.family, samples: echoes))
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
        if let context = HostReceipt.RuntimeContext.observe() { receipt["runtimeContext"] = try JSONSerialization.jsonObject(with: encoder.encode(context)) }
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
