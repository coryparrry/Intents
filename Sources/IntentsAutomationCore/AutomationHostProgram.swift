import Foundation
import IntentsAutomationDateCodec

public struct AutomationHostProgram: Codable, Equatable, Sendable {
    var requiredCodecCapabilities: [String] {
        AutomationCodecRequirements.program(self).sorted()
    }
    public struct Operation: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case invoke, query }
        public var id: String
        public var kind: Kind
        public var typeID: String
        public var parameters: [String: AutomationValue]
        public var resultCodec: String?
        public var queryText: String?
        public var attemptQueryPrefix: String?
        public var queryIDs: [String]?
        public var properties: [String: String]?
        public var parameterCodecs: [String: String]?
        public init(id: String, kind: Kind, typeID: String, parameters: [String: AutomationValue] = [:], resultCodec: String? = nil,
                    queryText: String? = nil, attemptQueryPrefix: String? = nil, queryIDs: [String]? = nil, properties: [String: String]? = nil, parameterCodecs: [String: String]? = nil) {
            self.id = id; self.kind = kind; self.typeID = typeID; self.parameters = parameters; self.resultCodec = resultCodec
            self.queryText = queryText; self.attemptQueryPrefix = attemptQueryPrefix; self.queryIDs = queryIDs; self.properties = properties
            self.parameterCodecs = parameterCodecs
        }
    }
    public var operations: [Operation]
    public init(operations: [Operation]) { self.operations = operations }
    public func validate(route: AutomationSegment.Kind, phase: AutomationSegment.Phase) throws {
        guard (1...10).contains(operations.count), Set(operations.map(\.id)).count == operations.count,
              route == .systemIntent || route == .systemQuery else { throw AutomationContractError.invalidPlan("Invalid Apple program") }
        for operation in operations {
            guard Self.identifier(operation.id), Self.identifier(operation.typeID), operation.parameters.count <= 50 else { throw AutomationContractError.invalidIdentity }
            if operation.kind == .invoke {
                guard route == .systemIntent, phase != .observe, operation.queryText == nil, operation.attemptQueryPrefix == nil, operation.queryIDs == nil, operation.properties == nil,
                      operation.resultCodec.map({ ["noValue", "text", "bool", "integer", "decimal", "date", "textArray", "boolArray", "integerArray", "decimalArray", "dateArray", "duration", "calendarComponents", "url", "intentFile"].contains($0) }) ?? true,
                      Set((operation.parameterCodecs ?? [:]).keys).isSubset(of: Set(operation.parameters.keys)),
                      (operation.parameterCodecs ?? [:]).values.allSatisfy(AutomationCodecRegistry.parameterFamilies.contains) else {
                    throw AutomationContractError.invalidPlan("Unqualified invoke codec or observer invocation")
                }
                for (name, value) in operation.parameters {
                    guard Self.identifier(name) else { throw AutomationContractError.invalidIdentity }
                    let codec = operation.parameterCodecs?[name]
                    if codec != nil {
                        switch value {
                        case .artifact where codec == "intentFile": break
                        case .array where codec.map(AutomationCodecRegistry.arrayFamilies.contains) == true, .object where ["duration", "calendarComponents", "url"].contains(codec ?? ""), .null, .omission: break
                        default: throw AutomationContractError.invalidPlan("Input does not match its frozen parameter codec")
                        }
                    }
                    _ = try Self.hostInput(value, parameterCodec: codec)
                }
            } else {
                guard route == .systemQuery, operation.parameters.isEmpty, operation.resultCodec == nil, operation.parameterCodecs == nil,
                      [operation.queryText != nil, operation.queryIDs != nil, operation.attemptQueryPrefix != nil].filter { $0 }.count == 1 else { throw AutomationContractError.invalidPlan("Exactly one Apple query selector required") }
                if let prefix = operation.attemptQueryPrefix { try AutomationAttemptText.validatePrefix(prefix) }
                if let text = operation.queryText, text.utf16.count > 32768 { throw AutomationContractError.invalidIdentity }
                if let ids = operation.queryIDs, !(1...100).contains(ids.count) || ids.contains(where: { $0.isEmpty || $0.utf16.count > 1024 }) { throw AutomationContractError.invalidIdentity }
                guard (operation.properties?.count ?? 0) <= 50,
                      (operation.properties ?? [:]).allSatisfy({ Self.identifier($0.key) && ["text", "bool", "integer"].contains($0.value) }) else { throw AutomationContractError.invalidPlan("Unsupported query property codec") }
            }
        }
    }
    public func payload(scope: AutomationScope, app: AppIdentity, route: AutomationSegment.Kind, phase: AutomationSegment.Phase) throws -> Data {
        try executionPayload(scope: scope, app: app, route: route, phase: phase, fileInputs: [:])
    }
    var usesFiles: Bool { operations.contains { $0.resultCodec == "intentFile" || $0.parameterCodecs?.values.contains("intentFile") == true } }
    func executionPayload(scope: AutomationScope, app: AppIdentity, route: AutomationSegment.Kind, phase: AutomationSegment.Phase,
                          fileInputs: [AutomationFileDestination: AutomationJSON]) throws -> Data {
        try scope.validate(); try validate(route: route, phase: phase)
        guard let digest = app.productDigest, digest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw AutomationContractError.invalidIdentity }
        guard app.productDigestVersion == nil || app.productDigestVersion == 1 || app.productDigestVersion == 2 else { throw AutomationContractError.invalidIdentity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var values: [AutomationJSON] = []
        for operation in operations {
            guard operation.attemptQueryPrefix == nil else { throw AutomationInputBindingError.inputUnavailable }
            var fields: [String: AutomationJSON] = ["id": .string(operation.id), "kind": .string(operation.kind.rawValue), "typeID": .string(operation.typeID),
                "parameters": .object(try operation.parameters.reduce(into: [String: AutomationJSON]()) { result, entry in
                    if case .artifact = entry.value {
                        guard operation.parameterCodecs?[entry.key] == "intentFile",
                              let input = fileInputs[.init(operationID: operation.id, parameterName: entry.key)] else { throw AutomationInputBindingError.inputUnavailable }
                        result[entry.key] = input
                    } else { result[entry.key] = try Self.hostInput(entry.value, parameterCodec: operation.parameterCodecs?[entry.key]) }
                })]
            if let codecs = operation.parameterCodecs { fields["parameterCodecs"] = .object(codecs.mapValues(AutomationJSON.string)) }
            if let codec = operation.resultCodec { fields["resultCodec"] = .string(codec) }
            if let text = operation.queryText { fields["queryText"] = .string(text) }
            if let ids = operation.queryIDs { fields["queryIDs"] = .array(ids.map(AutomationJSON.string)) }
            if let properties = operation.properties { fields["properties"] = .object(properties.mapValues(AutomationJSON.string)) }
            values.append(.object(fields))
        }
        var fields: [String: AutomationJSON] = ["schemaVersion": .number(1), "runID": .string(scope.runId), "attemptID": .string(scope.attemptId),
            "segmentID": .string(scope.segmentId), "leaseGeneration": .number(Double(scope.leaseGeneration)), "bundleID": .string(app.bundleID),
            "productDigest": .string(digest), "operations": .array(values)]
        if let version = app.productDigestVersion { fields["productDigestVersion"] = .number(Double(version)) }
        let data = try encoder.encode(AutomationJSON.object(fields))
        guard data.count <= 32768 else { throw AutomationContractError.invalidPlan("Apple environment payload exceeds budget") }
        return data
    }
    static func hostInput(_ value: AutomationValue, parameterCodec: String? = nil) throws -> AutomationJSON {
        try value.validate()
        switch value {
        case .text(let value): return .object(["kind": .string("text"), "value": .string(value)])
        case .bool(let value): return .object(["kind": .string("bool"), "boolValue": .bool(value)])
        case .integer(let value):
            guard Int64(value) != nil else { throw AutomationContractError.invalidPlan("Host integer exceeds Int64") }
            return .object(["kind": .string("integer"), "value": .string(value)])
        case .decimal(let value):
            guard let number = Double(value), number.isFinite else { throw AutomationContractError.invalidPlan("Host decimal exceeds finite Double") }
            return .object(["kind": .string("decimal"), "value": .string(value)])
        case .date(let value, let zone):
            _ = try AutomationDateCodec.decode(value: value, timeZone: zone)
            return .object(["kind": .string("date"), "value": .string(value), "timeZone": .string(zone)])
        case .enumeration(let id, let text), .entity(let id, let text):
            guard identifier(id) else { throw AutomationContractError.invalidIdentity }
            let kind: String = if case .entity = value { "entity" } else { "enum" }
            return .object(["kind": .string(kind), "typeId": .string(id), "value": .string(text)])
        case .array(let values):
            guard AutomationCodecRegistry.matchesArray(values, family: parameterCodec ?? "textArray") else { throw AutomationContractError.invalidPlan("Collection does not match its frozen Apple codec") }
            return .object(["kind": .string("array"), "items": .array(try values.map { try Self.hostInput($0) })])
        case .object:
            switch parameterCodec {
            case "duration": _ = try AutomationDurationInput(taggedValue: value)
            case "calendarComponents": _ = try AutomationCalendarInput(taggedValue: value)
            case "url": _ = try AutomationURLReference(taggedValue: value)
            default: throw AutomationContractError.invalidPlan("Structured input requires a declared native codec")
            }
            return try structuredHostInput(value)
        case .artifact(let handle, let digest):
            guard parameterCodec == "intentFile" else { throw AutomationContractError.invalidPlan("Artifact requires native file transfer authority") }
            return .object(["kind": .string("fileReference"), "value": .string(handle), "typeId": .string(digest)])
        case .null: return .object(["kind": .string("null")])
        case .omission: return .object(["kind": .string("omission")])
        default: throw AutomationContractError.invalidPlan("Host codec has no qualified Apple setter")
        }
    }
    private static func structuredHostInput(_ value: AutomationValue) throws -> AutomationJSON {
        if case .object(let fields) = value { return .object(["kind": .string("object"), "properties": .object(try fields.mapValues(structuredHostInput))]) }
        return try hostInput(value)
    }
    static func identifier(_ value: String) -> Bool { value.utf16.count <= 256 && value.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil }
}
