import Foundation
#if canImport(IntentsAutomationDateCodec)
import IntentsAutomationDateCodec
#endif

struct HostInputAdapterProbePlan: Codable {
    struct Parameter: Codable { let name: String; let family: String; let samples: [HostInput] }
    let schemaVersion: Int, purpose: String
    let runID: String, attemptID: String, segmentID: String, leaseGeneration: Int
    let bundleID: String, actionID: String, productDigest: String, productDigestVersion: Int
    let hostProductDigest: String, xctestrunDigest: String, catalogDigest: String, sourceDigest: String, templateDigest: String
    let parameters: [Parameter]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32_768 else { throw invalid() }
        let plan = try JSONDecoder().decode(Self.self, from: data)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(plan)
        let raw = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys, .withoutEscapingSlashes])
        guard canonical == raw, plan.schemaVersion == 1, plan.purpose == "inputAdapterRoundTrip", plan.productDigestVersion == 2,
              plan.leaseGeneration > 0, (1...10).contains(plan.parameters.count), Set(plan.parameters.map(\.name)).count == plan.parameters.count,
              [plan.runID, plan.attemptID, plan.segmentID, plan.bundleID, plan.actionID].allSatisfy({
                  $0.range(of: #"^[A-Za-z0-9_.:-]{1,256}$"#, options: .regularExpression) != nil
              }), [plan.productDigest, plan.hostProductDigest, plan.xctestrunDigest, plan.catalogDigest, plan.sourceDigest, plan.templateDigest].allSatisfy({
                  $0.count == 64 && $0.allSatisfy { $0.isASCII && "0123456789abcdef".contains($0) }
              }) else { throw invalid() }
        for parameter in plan.parameters {
            guard parameter.name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil,
                  parameter.samples == (try samples(family: parameter.family)) else { throw invalid() }
        }
        return plan
    }
    static func samples(family: String) throws -> [HostInput] {
        func input(_ kind: String, value: String? = nil, bool: Bool? = nil, items: [HostInput]? = nil,
                   properties: [String: HostInput]? = nil, zone: String? = nil) -> HostInput {
            .init(timeZone: zone, items: items, kind: kind, value: value, boolValue: bool, typeId: nil, properties: properties)
        }
        if family.hasSuffix("Array") {
            let element = String(family.dropLast(5))
            guard ["text", "bool", "integer", "decimal", "date"].contains(element) else { throw invalid() }
            return [input("array", items: []), input("array", items: try samples(family: element))]
        }
        switch family {
        case "intentFile":
            return [.init(timeZone: nil, items: nil, kind: "intentFile", value: AutomationIntentFileCalibration.data.base64EncodedString(),
                boolValue: nil, typeId: nil, properties: nil, file: try AutomationIntentFileCalibration.metadata())]
        case "text": return [input("text", value: "Intents adapter probe")]
        case "bool": return [input("bool", bool: true)]
        case "integer": return [input("integer", value: "42")]
        case "decimal": return [input("decimal", value: "1.25")]
        case "date": return [input("date", value: try AutomationDateCodec.encode(Date(timeIntervalSince1970: 978_307_200)), zone: "UTC")]
        case "url": return [input("object", properties: ["url": input("text", value: "https://example.invalid/intents-adapter-probe")])]
        case "duration": return [input("object", properties: ["seconds": input("integer", value: "1"), "attoseconds": input("integer", value: "0")])]
        case "calendarComponents": return [input("object", properties: ["components": input("object", properties: [
            "year": input("integer", value: "2001"), "month": input("integer", value: "1"), "day": input("integer", value: "1")])])]
        default: throw invalid()
        }
    }
    private static func invalid() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Input adapter probe requires its exact scope and fixed supported samples"))
    }
}

enum HostIntentIdentity {
    static func validate(bundle: String, action: String, definitionsBundle: String, definitionBundle: String,
                         definitionID: String, intentBundle: String, intentID: String) throws {
        guard definitionsBundle == bundle, definitionBundle == bundle, intentBundle == bundle,
              definitionID == action, intentID == action else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Intent definition identity does not match the selected bundle and action"))
        }
    }
}
