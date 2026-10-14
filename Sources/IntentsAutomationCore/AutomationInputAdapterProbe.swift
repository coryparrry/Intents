#if os(macOS)
import Foundation
import IntentsAutomationDateCodec

/// A calibration payload, never an AutomationCase or a business-action receipt.
/// Launch ownership/release qualification must precede execution; no customer route calls this yet.
struct AutomationInputAdapterProbePlan: Sendable {
    struct Parameter: Sendable { let name: String; let family: String; let samples: [AutomationValue] }
    let prepared: AutomationPreparedApplication
    let actionID: String
    let parameters: [Parameter]
    let catalogDigest: String
    let sourceDigest: String
    var digest: String {
        get throws { AutomationArtifactRegistry.digest(try payload(scope: .init(runID: "probe-review", attemptID: "probe-review", segmentID: "input-adapter", leaseGeneration: 1))) }
    }

    init(prepared: AutomationPreparedApplication, actionID: String, parameterNames: [String]) throws {
        guard prepared.host.app == prepared.catalog.app, prepared.host.target.kind == .nativeMac,
              prepared.host.app.platform == "macos", prepared.host.app.productDigestVersion == 2,
              prepared.host.hostProductDigestVersion == 2,
              (1...10).contains(parameterNames.count), Set(parameterNames).count == parameterNames.count,
              prepared.catalog.systemActions.filter({ $0.id == actionID }).count == 1,
              let action = prepared.catalog.systemActions.first(where: { $0.id == actionID }), action.parametersComplete else {
            throw AutomationContractError.conflictingOperation
        }
        self.prepared = prepared; self.actionID = actionID
        catalogDigest = try AutomationRecipeContext.catalogDigest(prepared.catalog); sourceDigest = try prepared.source.digest
        parameters = try parameterNames.sorted().map { name in
            guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil,
                  action.parameters.filter({ $0.name == name }).count == 1,
                  let parameter = action.parameters.first(where: { $0.name == name }), let family = parameter.family else {
                throw AutomationContractError.conflictingOperation
            }
            return .init(name: name, family: family, samples: try Self.samples(family: family))
        }
        guard [prepared.host.app.productDigest, prepared.host.hostProductDigest, prepared.host.xctestrunDigest,
               prepared.generatedHost.templateDigest].allSatisfy({ value in
                   value?.count == 64 && value?.allSatisfy { $0.isASCII && "0123456789abcdef".contains($0) } == true
               }) else { throw AutomationContractError.invalidIdentity }
    }
    static func samples(family: String) throws -> [AutomationValue] {
        if family.hasSuffix("Array") {
            let element = String(family.dropLast(5))
            guard ["text", "bool", "integer", "decimal", "date"].contains(element) else { throw AutomationContractError.invalidIdentity }
            return [.array([]), .array(try samples(family: element))]
        }
        switch family {
        case "intentFile": return [.artifact(handle: "file-calibration", sha256: AutomationIntentFileMetadata.digest(AutomationIntentFileCalibration.data))]
        case "text": return [.text("Intents adapter probe")]
        case "bool": return [.bool(true)]
        case "integer": return [.integer("42")]
        case "decimal": return [.decimal("1.25")]
        case "date": return [.date(try AutomationDateCodec.encode(Date(timeIntervalSince1970: 978_307_200)), timeZone: "UTC")]
        case "url": return [.object(["url": .text("https://example.invalid/intents-adapter-probe")])]
        case "duration": return [.object(["seconds": .integer("1"), "attoseconds": .integer("0")])]
        case "calendarComponents": return [.object(["components": .object(["year": .integer("2001"), "month": .integer("1"), "day": .integer("1")])])]
        default: throw AutomationContractError.invalidPlan("Input adapter probe excludes entities, enums, null, omission and unsupported families")
        }
    }
    func payload(scope: AutomationScope) throws -> Data {
        try scope.validate()
        let host = prepared.host
        let wire = AutomationJSON.object(["schemaVersion": .number(1), "purpose": .string("inputAdapterRoundTrip"),
            "runID": .string(scope.runId), "attemptID": .string(scope.attemptId), "segmentID": .string(scope.segmentId), "leaseGeneration": .number(Double(scope.leaseGeneration)),
            "bundleID": .string(host.app.bundleID), "actionID": .string(actionID), "productDigest": .string(host.app.productDigest!), "productDigestVersion": .number(2),
            "hostProductDigest": .string(host.hostProductDigest), "xctestrunDigest": .string(host.xctestrunDigest),
            "catalogDigest": .string(catalogDigest), "sourceDigest": .string(sourceDigest), "templateDigest": .string(prepared.generatedHost.templateDigest),
            "parameters": .array(try parameters.map { parameter in
                .object(["name": .string(parameter.name), "family": .string(parameter.family),
                         "samples": .array(try parameter.samples.map { sample in
                             if parameter.family == "intentFile" {
                                 let metadata = try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(AutomationIntentFileCalibration.metadata()))
                                 return .object(["kind": .string("intentFile"), "value": .string(AutomationIntentFileCalibration.data.base64EncodedString()), "file": metadata])
                             }
                             return try AutomationHostProgram.hostInput(sample, parameterCodec: parameter.family)
                         })])
            })])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(wire)
        guard data.count <= 32_768 else { throw AutomationContractError.invalidIdentity }
        return data
    }
}

/// Strictly correlated readback data. Import and equality alone never establish a released live run.
struct AutomationInputAdapterProbeObservation: Sendable {
    let runner: AutomationProcessIdentity
    let receiptDigest: String
    let runtimeObservation: AutomationAppleRuntimeObservation?
    let echoedSamples: [String: [AutomationValue]]

    static func read(_ data: Data, plan: AutomationInputAdapterProbePlan, scope: AutomationScope) throws -> Self {
        try readValidated(data, plan: plan, scope: scope, fileValues: [:])
    }
    static func readValidated(_ data: Data, plan: AutomationInputAdapterProbePlan, scope: AutomationScope,
                              fileValues: [String: [AutomationValue]]) throws -> Self {
        guard data.count <= 1_048_576,
              var fields = try JSONDecoder().decode(AutomationJSON.self, from: data).object,
              let expected = try JSONDecoder().decode(AutomationJSON.self, from: plan.payload(scope: scope)).object else {
            throw AutomationContractError.invalidIdentity
        }
        let context = try fields.removeValue(forKey: "runtimeContext").map(AutomationAppleRuntimeObservation.parse)
        guard Set(fields.keys) == Set(expected.keys).union(["runner", "complete"]), fields["complete"] == .bool(true),
              expected.filter({ $0.key != "parameters" }).allSatisfy({ fields[$0.key] == $0.value }),
              let runner = fields["runner"]?.object, Set(runner.keys) == ["pid", "startIdentity", "executablePath"],
              case .number(let pid) = runner["pid"], pid > 0, pid <= Double(Int32.max), pid.rounded() == pid,
              case .string(let start) = runner["startIdentity"], start.range(of: #"^[0-9]{1,20}:[0-9]{1,6}$"#, options: .regularExpression) != nil,
              runner["executablePath"] == .string(plan.prepared.host.hostBundlePath + "/Contents/MacOS/" + plan.prepared.host.testTarget + "-Runner"),
              case .array(let parameters) = fields["parameters"], parameters.count == plan.parameters.count else { throw AutomationContractError.conflictingOperation }
        var echoes: [String: [AutomationValue]] = [:]
        for (field, parameter) in zip(parameters, plan.parameters) {
            guard let object = field.object, Set(object.keys) == ["name", "family", "samples"],
                  object["name"] == .string(parameter.name), object["family"] == .string(parameter.family),
                  case .array(let samples) = object["samples"], samples.count == parameter.samples.count else { throw AutomationContractError.conflictingOperation }
            let values: [AutomationValue]
            if parameter.family == "intentFile" {
                guard let imported = fileValues[parameter.name], imported.count == samples.count else { throw AutomationContractError.missingEvidence("File calibration requires binary readback") }
                for (index, value) in samples.enumerated() {
                    let descriptor = try AutomationHostFileDescriptor(value, operationID: parameter.name + ":" + String(index))
                    guard descriptor.metadata == (try AutomationIntentFileCalibration.metadata()),
                          case .artifact(_, let digest) = imported[index], digest == descriptor.metadata.sha256 else { throw AutomationContractError.conflictingOperation }
                }
                values = imported
            } else {
                values = try samples.map { try AutomationHostReceiptImporter.decodeValue($0, depth: 0) }
                guard values == parameter.samples else { throw AutomationContractError.conflictingOperation }
            }
            echoes[parameter.name] = values
        }
        return .init(runner: .init(pid: Int32(pid), startIdentity: start), receiptDigest: AutomationArtifactRegistry.digest(data), runtimeObservation: context, echoedSamples: echoes)
    }
}
#endif
