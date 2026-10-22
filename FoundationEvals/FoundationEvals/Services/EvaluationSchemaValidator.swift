import Foundation
import FoundationModels

/// Dynamic schemas describe generation, but custom executors can return any
/// valid JSON. Check the complete value before treating it as output or input.
enum EvaluationSchemaValidator {
    static func validate(
        _ content: GeneratedContent,
        fields: [EvaluationSchemaField],
        definitions: [EvaluationSchemaField] = [],
        representNilExplicitlyInGeneratedContent: Bool = false
    ) throws {
        if let issue = EvaluationFeatureConfiguration.schemaValidationIssue(
            fields: fields, definitions: definitions, context: "Schema"
        ) {
            throw EvaluationSchemaValidationError(path: "$", issue: issue)
        }
        try validateObject(content, fields: fields,
            definitions: Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) }),
            explicitNil: representNilExplicitlyInGeneratedContent, path: "$")
    }

    private static func validateObject(
        _ content: GeneratedContent,
        fields: [EvaluationSchemaField],
        definitions: [String: EvaluationSchemaField],
        explicitNil: Bool,
        path: String
    ) throws {
        guard case .structure(let properties, _) = content.kind else {
            throw EvaluationSchemaValidationError(path: path, issue: "Expected a JSON object.")
        }
        let configuredNames = Set(fields.map(\.name))
        if let unexpected = properties.keys.first(where: { !configuredNames.contains($0) }) {
            throw EvaluationSchemaValidationError(path: "\(path).\(unexpected)",
                issue: "This property is not configured for the object.")
        }
        for field in fields {
            let fieldPath = "\(path).\(field.name)"
            guard let value = properties[field.name] else {
                if field.isOptional, !explicitNil { continue }
                if field.isOptional {
                    throw EvaluationSchemaValidationError(path: fieldPath, issue: "Represent a missing optional value explicitly as null.")
                }
                throw EvaluationSchemaValidationError(path: fieldPath, issue: "A required field is missing.")
            }
            if field.isOptional, explicitNil, case .null = value.kind { continue }
            try validate(value, field: field, definitions: definitions, path: fieldPath)
        }
    }

    private static func validate(
        _ content: GeneratedContent,
        field: EvaluationSchemaField,
        definitions: [String: EvaluationSchemaField],
        path: String
    ) throws {
        func reject(_ issue: String) -> EvaluationSchemaValidationError {
            .init(path: path, issue: issue)
        }
        switch field.type {
        case .string:
            guard case .string(let value) = content.kind else { throw reject("Expected a JSON string.") }
            // The exported JSON Schema pattern is unanchored unless the user anchors it.
            if !field.constraints.stringPattern.isEmpty,
               try value.firstMatch(of: Regex(field.constraints.stringPattern)) == nil {
                throw reject("The string does not match its configured pattern.")
            }
        case .integer:
            guard case .number(let number) = content.kind, number.isFinite,
                  let value = try? Int(content) else { throw reject("Expected a JSON integer.") }
            if let minimum = field.constraints.integerMinimum, value < minimum {
                throw reject("The integer is below its minimum of \(minimum).")
            }
            if let maximum = field.constraints.integerMaximum, value > maximum {
                throw reject("The integer exceeds its maximum of \(maximum).")
            }
        case .number:
            guard case .number(let value) = content.kind, value.isFinite else {
                throw reject("Expected a finite JSON number.")
            }
            if let minimum = field.constraints.numberMinimum, value < minimum {
                throw reject("The number is below its minimum of \(minimum).")
            }
            if let maximum = field.constraints.numberMaximum, value > maximum {
                throw reject("The number exceeds its maximum of \(maximum).")
            }
        case .boolean:
            guard case .bool = content.kind else { throw reject("Expected a JSON boolean.") }
        case .enumeration:
            guard case .string(let value) = content.kind,
                  field.enumValues.contains(where: { $0.value == value }) else {
                throw reject("Expected one of the configured string choices.")
            }
        case .object:
            try validateObject(content, fields: field.children, definitions: definitions,
                explicitNil: field.representNilExplicitlyInGeneratedContent, path: path)
        case .array:
            guard case .array(let values) = content.kind, let item = field.children.first else {
                throw reject("Expected a JSON array.")
            }
            if let minimum = field.constraints.arrayMinimumCount, values.count < minimum {
                throw reject("The array has fewer than \(minimum) elements.")
            }
            if let maximum = field.constraints.arrayMaximumCount, values.count > maximum {
                throw reject("The array has more than \(maximum) elements.")
            }
            for (index, value) in values.enumerated() {
                try validate(value, field: item, definitions: definitions, path: "\(path)[\(index)]")
            }
        case .null:
            guard case .null = content.kind else { throw reject("Expected JSON null.") }
        case .union:
            guard field.children.contains(where: {
                (try? validate(content, field: $0, definitions: definitions, path: path)) != nil
            }) else { throw reject("The value does not match any configured alternative.") }
        case .reference:
            guard let definition = definitions[field.referenceName] else {
                throw reject("The referenced schema is unavailable.")
            }
            try validate(content, field: definition, definitions: definitions, path: path)
        case .imageReference:
            // The SDK image-reference schema is a closed attachmentLabel object;
            // its GeneratedContent conversion alone silently ignores extra keys.
            try validateObject(content, fields: [.init(name: "attachmentLabel", type: .string)],
                definitions: [:], explicitNil: false, path: path)
            guard (try? ImageReference(content)) != nil else {
                throw reject("Expected an image attachment reference.")
            }
        }
    }
}

struct EvaluationSchemaValidationError: LocalizedError, Sendable {
    var path: String
    var issue: String
    var errorDescription: String? { "Schema violation at \(path): \(issue)" }
}
