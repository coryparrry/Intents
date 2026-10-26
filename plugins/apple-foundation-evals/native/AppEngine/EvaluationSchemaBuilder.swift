import Foundation
import FoundationModels

@available(macOS 27.0, *)
enum EvaluationSchemaBuilder {
    /// Validates schema identifiers, field limits, and definitions before building a constrained generation schema.
    /// Optional values may require explicit nulls; configuration, regex, and schema construction failures propagate.
    static func schema(
        fields: [EvaluationSchemaField],
        name: String,
        definitions: [EvaluationSchemaField] = [],
        representNilExplicitlyInGeneratedContent: Bool = false
    ) throws -> GenerationSchema {
        guard EvaluationIdentifier.isValid(
            name,
            maximumCharacters: EvaluationCustomToolDefinition.maximumNameCharacters
        ) else {
            throw EvaluationFeatureConfigurationError.invalid(
                "Schema names must be identifiers of \(EvaluationCustomToolDefinition.maximumNameCharacters) characters or fewer."
            )
        }
        guard fields.count <= EvaluationCustomToolDefinition.maximumParameters else {
            throw EvaluationFeatureConfigurationError.invalid(
                "A schema can define at most \(EvaluationCustomToolDefinition.maximumParameters) fields."
            )
        }
        if let issue = EvaluationFeatureConfiguration.schemaValidationIssue(
            fields: fields,
            definitions: definitions,
            context: "Schema \(name)"
        ) {
            throw EvaluationFeatureConfigurationError.invalid(issue)
        }

        let root = DynamicGenerationSchema(
            name: name,
            representNilExplicitlyInGeneratedContent: representNilExplicitlyInGeneratedContent,
            properties: try properties(for: fields)
        )
        let dependencies = try definitions.map { definition in
            DynamicGenerationSchema(
                name: definition.name,
                description: definition.description.isEmpty ? nil : definition.description,
                anyOf: [try dynamicSchema(for: definition)]
            )
        }
        return try GenerationSchema(root: root, dependencies: dependencies)
    }

    /// Converts configured fields into named generation properties with descriptions, nested schemas, and optionality.
    private static func properties(
        for fields: [EvaluationSchemaField]
    ) throws -> [DynamicGenerationSchema.Property] {
        try fields.map { field in
            DynamicGenerationSchema.Property(
                name: field.name,
                description: field.description.isEmpty ? nil : field.description,
                schema: try dynamicSchema(for: field),
                isOptional: field.isOptional
            )
        }
    }

    /// Converts a field into its dynamic schema, recursively applying constraints, definitions, null representation, unions, and image-reference types.
    private static func dynamicSchema(
        for field: EvaluationSchemaField
    ) throws -> DynamicGenerationSchema {
        switch field.type {
        case .string:
            var guides: [GenerationGuide<String>] = []
            if !field.constraints.stringPattern.isEmpty {
                guides.append(.pattern(try Regex(field.constraints.stringPattern)))
            }
            return DynamicGenerationSchema(type: String.self, guides: guides)
        case .integer:
            var guides: [GenerationGuide<Int>] = []
            if let minimum = field.constraints.integerMinimum {
                guides.append(.minimum(minimum))
            }
            if let maximum = field.constraints.integerMaximum {
                guides.append(.maximum(maximum))
            }
            return DynamicGenerationSchema(type: Int.self, guides: guides)
        case .number:
            var guides: [GenerationGuide<Double>] = []
            if let minimum = field.constraints.numberMinimum {
                guides.append(.minimum(minimum))
            }
            if let maximum = field.constraints.numberMaximum {
                guides.append(.maximum(maximum))
            }
            return DynamicGenerationSchema(type: Double.self, guides: guides)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .enumeration:
            return DynamicGenerationSchema(
                name: generatedTypeName(for: field),
                anyOf: field.enumValues.map(\.value)
            )
        case .object:
            return DynamicGenerationSchema(
                name: generatedTypeName(for: field),
                description: field.description.isEmpty ? nil : field.description,
                representNilExplicitlyInGeneratedContent: field.representNilExplicitlyInGeneratedContent,
                properties: try properties(for: field.children)
            )
        case .array:
            guard let item = field.children.first else {
                throw EvaluationFeatureConfigurationError.invalid(
                    "Array field \(field.name) needs exactly one item schema."
                )
            }
            return DynamicGenerationSchema(
                arrayOf: try dynamicSchema(for: item),
                minimumElements: field.constraints.arrayMinimumCount,
                maximumElements: field.constraints.arrayMaximumCount
            )
        case .null:
            return .null
        case .union:
            return DynamicGenerationSchema(
                name: generatedTypeName(for: field),
                description: field.description.isEmpty ? nil : field.description,
                anyOf: try field.children.map { try dynamicSchema(for: $0) }
            )
        case .reference:
            return DynamicGenerationSchema(referenceTo: field.referenceName)
        case .imageReference:
            return DynamicGenerationSchema(type: ImageReference.self)
        }
    }

    /// Derives a unique identifier-safe generated type name from the field UUID.
    private static func generatedTypeName(for field: EvaluationSchemaField) -> String {
        "Schema_\(field.id.uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}
