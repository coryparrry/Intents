import Foundation
import IntentsAutomationDateCodec

/// A terminal error returned by one hosted operation. It does not assert that
/// the action had no side effects or that a business requirement was assessed.
public struct AutomationHostOperationFailure: Codable, Equatable, Sendable {
    public let operationID: String
    public let message: String

    func validate(receipt: AutomationSegmentReceipt, segment: AutomationSegment) throws {
        guard [.systemIntent, .systemQuery].contains(receipt.route), receipt.dispatched, !receipt.completed,
              receipt.observations.isEmpty, receipt.terminalUIAssertionFailure == nil,
              segment.hostProgram?.operations.contains(where: { $0.id == operationID }) == true,
              message.utf16.count <= 4096 else { throw AutomationContractError.conflictingOperation }
    }
}

public struct AutomationImportedHostReceipt: Sendable {
    public var runner: AutomationProcessIdentity
    public var executablePath: String
    public var values: [String: AutomationValue]
    var runtimeObservation: AutomationAppleRuntimeObservation? = nil
    public var terminalFailure: AutomationHostOperationFailure? = nil
}

/// Correlates the unique completed receipt with the exact frozen program. XCTest exit is insufficient.
public enum AutomationHostReceiptImporter {
    public static func importReceipt(_ data: Data, scope: AutomationScope, app: AppIdentity,
                                     program: AutomationHostProgram, allowTerminalFailure: Bool = false) throws -> AutomationImportedHostReceipt {
        try importValidatedReceipt(data, scope: scope, app: app, program: program, fileValues: [:], allowTerminalFailure: allowTerminalFailure)
    }
    static func importValidatedReceipt(_ data: Data, scope: AutomationScope, app: AppIdentity,
                                       program: AutomationHostProgram, fileValues: [String: AutomationValue], allowTerminalFailure: Bool = false) throws -> AutomationImportedHostReceipt {
        guard data.count <= 1_048_576 else { throw AutomationContractError.missingEvidence("Host receipt exceeds budget") }
        let receipt = try JSONDecoder().decode(AutomationJSON.self, from: data)
        guard let root = receipt.object else { throw AutomationContractError.invalidIdentity }
        let version = root["schemaVersion"]
        guard version == .number(2) || (version == .number(3) && app.platform == "macos") else {
            throw AutomationContractError.invalidIdentity
        }
        let observation: AutomationAppleRuntimeObservation?
        if version == .number(3), let raw = root["runtimeContext"] {
            observation = try AutomationAppleRuntimeObservation.parse(raw)
        } else { observation = nil }
        var keys: Set<String> = ["schemaVersion", "runner", "runID", "attemptID", "segmentID", "leaseGeneration", "bundleID", "productDigest", "operations", "complete"]
        if observation != nil { keys.insert("runtimeContext") }
        if app.productDigestVersion != nil { keys.insert("productDigestVersion") }
        let complete = root["complete"] == .bool(true)
        guard app.productDigestVersion == nil || app.productDigestVersion == 1 || app.productDigestVersion == 2,
              let fields = receipt.object, Set(fields.keys) == keys,
              fields["productDigestVersion"] == app.productDigestVersion.map({ .number(Double($0)) }),
              (complete || (allowTerminalFailure && fields["complete"] == .bool(false))), fields["runID"] == .string(scope.runId),
              fields["attemptID"] == .string(scope.attemptId), fields["segmentID"] == .string(scope.segmentId),
              fields["leaseGeneration"] == .number(Double(scope.leaseGeneration)), fields["bundleID"] == .string(app.bundleID),
              fields["productDigest"] == app.productDigest.map(AutomationJSON.string), let runner = fields["runner"]?.object,
              Set(runner.keys) == ["pid", "startIdentity", "executablePath"], case .number(let pid) = runner["pid"],
              pid > 0, pid <= Double(Int32.max), pid.rounded() == pid, case .string(let start) = runner["startIdentity"],
              start.range(of: #"^[0-9]{1,20}:[0-9]{1,6}$"#, options: .regularExpression) != nil,
              case .string(let path) = runner["executablePath"], path.hasPrefix("/"), path.utf16.count <= 4096,
              case .array(let operations) = fields["operations"], !operations.isEmpty,
              (complete ? operations.count == program.operations.count : operations.count <= program.operations.count) else {
            throw AutomationContractError.missingEvidence("Host receipt scope or runner mismatch")
        }
        var values: [String: AutomationValue] = [:]
        var failure: AutomationHostOperationFailure?
        for (index, pair) in zip(operations, program.operations).enumerated() {
            let (operation, expected) = pair
            guard let fields = operation.object, Set(fields.keys).isSubset(of: ["operationID", "dispatched", "value", "error"]),
                  fields["operationID"] == .string(expected.id), fields["dispatched"] == .bool(true) else {
                throw AutomationContractError.missingEvidence("Host operation does not match the frozen program")
            }
            if let error = fields["error"], error != .null {
                guard allowTerminalFailure, !complete, index == operations.count - 1,
                      case .string(let message) = error, message.utf16.count <= 4096,
                      fields["value"] == nil || fields["value"] == .null else {
                    throw AutomationContractError.missingEvidence("Host failure is not an exact terminal operation")
                }
                failure = .init(operationID: expected.id, message: message)
                continue
            }
            guard let value = fields["value"] else { throw AutomationContractError.missingEvidence("Host operation did not complete") }
            let decoded: AutomationValue
            if expected.resultCodec == "intentFile" {
                let descriptor = try AutomationHostFileDescriptor(value, operationID: expected.id)
                guard case .artifact(_, let digest) = fileValues[expected.id], digest == descriptor.metadata.sha256,
                      let fileValue = fileValues[expected.id] else { throw AutomationContractError.missingEvidence("File result lacks validated binary attachment") }
                decoded = fileValue
            } else { decoded = try decodeValue(value, depth: 0) }
            if expected.kind == .query { try AutomationEntitySelection.validateQueryOutput(decoded, query: expected) }
            else { guard matchesResult(decoded, codec: expected.resultCodec ?? "noValue") else { throw AutomationContractError.invalidPlan("Host result does not match the frozen codec") } }
            values[expected.id] = decoded
        }
        guard complete || failure != nil else { throw AutomationContractError.missingEvidence("Host progress has no terminal outcome") }
        return .init(runner: .init(pid: Int32(pid), startIdentity: start), executablePath: path, values: values,
            runtimeObservation: observation, terminalFailure: failure)
    }
    private static func matchesResult(_ value: AutomationValue, codec: String) -> Bool {
        switch (codec, value) {
        case ("intentFile", .artifact): return true
        case ("noValue", .omission), ("text", .text), ("bool", .bool): return true
        case ("integer", .integer(let number)): return Int64(number) != nil
        case ("decimal", .decimal(let number)): return Double(number)?.isFinite == true
        case ("date", .date): return matchesDateResult(value)
        case ("calendarComponents", .object): return (try? AutomationCalendarInput(taggedValue: value)) != nil
        case ("duration", .object): return (try? AutomationDurationInput(taggedValue: value)) != nil
        case ("url", .object): return (try? AutomationURLReference(taggedValue: value)) != nil
        case (let family, .array(let items)): return AutomationCodecRegistry.matchesArray(items, family: family) && (family != "dateArray" || items.allSatisfy(matchesDateResult))
        default: return false
        }
    }
    private static func matchesDateResult(_ value: AutomationValue) -> Bool {
        guard case .date(let text, let zone) = value, zone == "UTC",
              let date = try? AutomationDateCodec.decode(value: text, timeZone: zone),
              let canonical = try? AutomationDateCodec.encode(date) else { return false }
        return canonical == text
    }
    static func decodeValue(_ value: AutomationJSON, depth: Int) throws -> AutomationValue {
        guard depth <= 16, let fields = value.object, Set(fields.keys).isSubset(of: ["kind", "value", "boolValue", "typeId", "properties", "items", "timeZone"]),
              case .string(let kind) = fields["kind"] else { throw AutomationContractError.invalidIdentity }
        let result: AutomationValue
        switch kind {
        case "noValue": guard fields.count == 1 else { throw AutomationContractError.invalidIdentity }; result = .omission
        case "text", "integer", "decimal":
            guard Set(fields.keys) == ["kind", "value"], case .string(let text) = fields["value"] else { throw AutomationContractError.invalidIdentity }
            result = kind == "text" ? .text(text) : kind == "integer" ? .integer(text) : .decimal(text)
        case "date":
            guard Set(fields.keys) == ["kind", "value", "timeZone"], case .string(let text) = fields["value"], case .string(let zone) = fields["timeZone"] else { throw AutomationContractError.invalidIdentity }
            _ = try AutomationDateCodec.decode(value: text, timeZone: zone); result = .date(text, timeZone: zone)
        case "bool":
            guard Set(fields.keys) == ["kind", "boolValue"], case .bool(let bool) = fields["boolValue"] else { throw AutomationContractError.invalidIdentity }; result = .bool(bool)
        case "array":
            guard Set(fields.keys) == ["kind", "items"], case .array(let items) = fields["items"], items.count <= 1000 else { throw AutomationContractError.invalidIdentity }
            result = .array(try items.map { try decodeValue($0, depth: depth + 1) })
        case "object":
            guard Set(fields.keys) == ["kind", "properties"], let properties = fields["properties"]?.object, properties.count <= 50 else { throw AutomationContractError.invalidIdentity }
            result = .object(try properties.mapValues { try decodeValue($0, depth: depth + 1) })
        case "entity":
            guard Set(fields.keys) == ["kind", "value", "typeId", "properties"], case .string(let id) = fields["value"], case .string(let type) = fields["typeId"],
                  let properties = fields["properties"]?.object, properties.count <= 50 else { throw AutomationContractError.invalidIdentity }
            result = .object(["entity": .entity(typeID: type, value: id), "properties": .object(try properties.mapValues { try decodeValue($0, depth: depth + 1) })])
        default: throw AutomationContractError.invalidPlan("Unqualified host result codec")
        }
        try result.validate(); return result
    }
}
