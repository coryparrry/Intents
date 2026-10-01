import AppIntentsTesting
import Foundation
import IntentLabContracts
import XCTest

public enum IntentLabQueryObservationError: LocalizedError {
    case unsupportedOperation(String)
    case invalidSelector(String)
    case ambiguousEntities(String)
    case missingEntity(String)
    case invalidValue(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperation(let id): "Unsupported query operation \(id)."
        case .invalidSelector(let selector): "Invalid query observation selector \(selector)."
        case .ambiguousEntities(let id): "Entity query returned duplicate identifier \(id)."
        case .missingEntity(let id): "Entity query did not return required identifier \(id)."
        case .invalidValue(let id): "Query observation \(id) did not match its declared type."
        case .timedOut: "The query observation exceeded its deadline."
        }
    }
}

/// Typed, read-only AppIntentsTesting query observations driven by a bundled declaration.
@available(macOS 27.0, iOS 27.0, *)
@MainActor
public enum IntentLabQueryObserver {
    public static func observe(
        bundleIdentifier: String,
        declaration: IntentLabIntegrationDeclaration,
        deadlineSeconds: TimeInterval
    ) throws -> [String: IntentLabValue] {
        try declaration.validate()
        guard declaration.targetBundleIdentifier == bundleIdentifier else {
            throw IntentLabDeclarationError.mismatchedIdentity
        }
        let operations = declaration.queryOperations ?? []
        guard !operations.isEmpty else { return [:] }
        return try runBounded(deadlineSeconds: deadlineSeconds) {
            try await runQueries(bundleIdentifier: bundleIdentifier, declaration: declaration)
        }
    }

    static func runBounded(
        deadlineSeconds: TimeInterval,
        operation: @escaping @MainActor () async throws -> [String: IntentLabValue]
    ) throws -> [String: IntentLabValue] {
        guard deadlineSeconds > 0, deadlineSeconds.isFinite else { throw IntentLabQueryObservationError.timedOut }
        let completed = XCTestExpectation(description: "Intent Lab query observation completed")
        let box = QueryResultBox()
        let task = Task { @MainActor in
            do { box.result = .success(try await operation()) }
            catch { box.result = .failure(error) }
            completed.fulfill()
        }
        defer { task.cancel() }
        guard XCTWaiter.wait(for: [completed], timeout: deadlineSeconds) == .completed,
              let result = box.result else { throw IntentLabQueryObservationError.timedOut }
        return try result.get()
    }

    static func validateEntityIdentifiers(expected: [String], actual: [String]) throws {
        guard Set(expected).count == expected.count else {
            throw IntentLabQueryObservationError.unsupportedOperation("duplicate requested entity IDs")
        }
        var seen: Set<String> = []
        for id in actual {
            guard seen.insert(id).inserted else { throw IntentLabQueryObservationError.ambiguousEntities(id) }
        }
        for id in expected where !seen.contains(id) {
            throw IntentLabQueryObservationError.missingEntity(id)
        }
        guard seen.count == expected.count else {
            throw IntentLabQueryObservationError.ambiguousEntities("unexpected entity")
        }
    }

    private static func runQueries(
        bundleIdentifier: String,
        declaration: IntentLabIntegrationDeclaration
    ) async throws -> [String: IntentLabValue] {
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)
        var result: [String: IntentLabValue] = [:]
        for operation in declaration.queryOperations ?? [] {
            try Task.checkCancellation()
            let observers = declaration.observers.filter { $0.operationID == operation.id }
            guard observers.allSatisfy({ $0.source == operation.source }) else {
                throw IntentLabDeclarationError.invalid
            }
            switch operation.source {
            case .entityQuery:
                guard let identifiers = operation.identifiers, !identifiers.isEmpty,
                      Set(identifiers).count == identifiers.count else {
                    throw IntentLabQueryObservationError.unsupportedOperation(operation.id)
                }
                let entities = try await definitions.entities[operation.typeIdentifier].entities(identifiers: identifiers)
                try validateEntityIdentifiers(
                    expected: identifiers,
                    actual: entities.map { $0.identifier.instanceIdentifier }
                )
                var byID: [String: AnyAppEntity] = [:]
                for entity in entities {
                    let id = entity.identifier.instanceIdentifier
                    byID[id] = entity
                }
                for observer in observers {
                    guard let selector = observer.selector,
                          let split = selector.firstIndex(of: ".") else {
                        throw IntentLabQueryObservationError.invalidSelector(observer.selector ?? "")
                    }
                    let id = String(selector[..<split])
                    let property = String(selector[selector.index(after: split)...])
                    guard identifiers.contains(id), let entity = byID[id], !property.isEmpty else {
                        throw IntentLabQueryObservationError.invalidSelector(selector)
                    }
                    let value = try project(entity: entity, property: property, type: observer.type, id: observer.id)
                    guard result.updateValue(value, forKey: observer.id) == nil else {
                        throw IntentLabQueryObservationError.ambiguousEntities(observer.id)
                    }
                }
            case .valueQuery:
                guard let input = operation.input else {
                    throw IntentLabQueryObservationError.unsupportedOperation(operation.id)
                }
                let query = definitions.valueQueries[operation.typeIdentifier]
                let values: ResolvedValueQueryResult
                switch input {
                case .string(let text): values = try await query.values(for: text)
                case .boolean(let value): values = try await query.values(for: value)
                case .integer(let value): values = try await query.values(for: value)
                case .number(let value) where value.isFinite: values = try await query.values(for: value)
                case .date(let value): values = try await query.values(for: value.resolvedInstant)
                default: throw IntentLabQueryObservationError.unsupportedOperation(operation.id)
                }
                for observer in observers {
                    guard let selector = observer.selector else {
                        throw IntentLabQueryObservationError.invalidSelector("")
                    }
                    let value: IntentLabValue
                    if selector == "count", case .primitive(.integer) = observer.type {
                        value = .integer(Int64(values.items.count))
                    } else {
                        let parts = selector.split(separator: ".", maxSplits: 1).map(String.init)
                        guard let first = parts.first, let index = Int(first),
                              index >= 0, index < values.items.count else {
                            throw IntentLabQueryObservationError.invalidSelector(selector)
                        }
                        var path: DynamicPropertyPath = values.items[index]
                        if parts.count == 2 { path = path[dynamicMember: parts[1]] }
                        value = try project(path: path, type: observer.type, id: observer.id)
                    }
                    guard result.updateValue(value, forKey: observer.id) == nil else {
                        throw IntentLabQueryObservationError.ambiguousEntities(observer.id)
                    }
                }
            default:
                throw IntentLabQueryObservationError.unsupportedOperation(operation.id)
            }
        }
        return result
    }

    private static func project(
        entity: AnyAppEntity,
        property: String,
        type: IntentLabValueType,
        id: String
    ) throws -> IntentLabValue {
        if property == "id", case .primitive(.string) = type {
            return .string(entity.identifier.instanceIdentifier)
        }
        switch type {
        case .primitive(.string):
            let value: String = try entity[dynamicMember: property]
            return .string(value)
        case .primitive(.boolean):
            let value: Bool = try entity[dynamicMember: property]
            return .boolean(value)
        case .primitive(.integer):
            let value: Int = try entity[dynamicMember: property]
            return .integer(Int64(value))
        case .primitive(.number):
            let value: Double = try entity[dynamicMember: property]
            guard value.isFinite else { throw IntentLabQueryObservationError.invalidValue(id) }
            return .number(value)
        case .primitive(.date):
            let value: Date = try entity[dynamicMember: property]
            return .date(.init(source: ISO8601DateFormatter().string(from: value), timeZoneIdentifier: "UTC", resolvedInstant: value))
        case .enumeration(let identifier, let cases):
            let value: AnyAppEnum = try entity[dynamicMember: property]
            guard value.typeIdentifier == identifier, cases.contains(value.rawValue) else {
                throw IntentLabQueryObservationError.invalidValue(id)
            }
            return .enumeration(.init(typeIdentifier: identifier, caseIdentifier: value.rawValue))
        case .entity(let identifier):
            let value: AnyAppEntity = try entity[dynamicMember: property]
            guard value.identifier.entityType.persistentIdentifier == identifier else {
                throw IntentLabQueryObservationError.invalidValue(id)
            }
            return .entity(.init(typeIdentifier: identifier, identifier: value.identifier.instanceIdentifier))
        case .array:
            throw IntentLabQueryObservationError.invalidValue(id)
        }
    }

    private static func project(path: DynamicPropertyPath, type: IntentLabValueType, id: String) throws -> IntentLabValue {
        switch type {
        case .primitive(.string): return .string(try path.as(String.self))
        case .primitive(.boolean): return .boolean(try path.as(Bool.self))
        case .primitive(.integer): return .integer(Int64(try path.as(Int.self)))
        case .primitive(.number):
            let value = try path.as(Double.self)
            guard value.isFinite else { throw IntentLabQueryObservationError.invalidValue(id) }
            return .number(value)
        case .primitive(.date):
            let value = try path.as(Date.self)
            return .date(.init(source: ISO8601DateFormatter().string(from: value), timeZoneIdentifier: "UTC", resolvedInstant: value))
        case .enumeration(let identifier, let cases):
            let value = try path.as(AnyAppEnum.self)
            guard value.typeIdentifier == identifier, cases.contains(value.rawValue) else { throw IntentLabQueryObservationError.invalidValue(id) }
            return .enumeration(.init(typeIdentifier: identifier, caseIdentifier: value.rawValue))
        case .entity(let identifier):
            let value = try path.as(AnyAppEntity.self)
            guard value.identifier.entityType.persistentIdentifier == identifier else { throw IntentLabQueryObservationError.invalidValue(id) }
            return .entity(.init(typeIdentifier: identifier, identifier: value.identifier.instanceIdentifier))
        case .array:
            throw IntentLabQueryObservationError.invalidValue(id)
        }
    }
}

@available(macOS 27.0, iOS 27.0, *)
@MainActor
private final class QueryResultBox {
    var result: Result<[String: IntentLabValue], Error>?
}
