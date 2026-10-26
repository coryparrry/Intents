import Foundation

@available(macOS 27.0, *)
struct EvaluationFeatureConfiguration: Codable, Equatable, Sendable {
    static let maximumTools = 4
    static let maximumOutputFields = 8
    static let maximumSchemaDepth = 4
    static let maximumSchemaNodes = 32

    var tools: [EvaluationCustomToolDefinition]
    var spotlightSearch: EvaluationSpotlightSearchConfiguration
    var profile: EvaluationProfileConfiguration
    var outputFields: [EvaluationSchemaField]
    var outputSchemaDefinitions: [EvaluationSchemaField]
    var outputRepresentNilExplicitlyInGeneratedContent: Bool
    var prewarm: Bool
    var streamResponse: Bool

    /// Creates suite feature settings with no tools, schemas, profile activation, prewarming, or streaming unless supplied.
    /// Values are retained as entered; validation is performed separately.
    init(
        tools: [EvaluationCustomToolDefinition] = [],
        spotlightSearch: EvaluationSpotlightSearchConfiguration = .init(),
        profile: EvaluationProfileConfiguration = .init(),
        outputFields: [EvaluationSchemaField] = [],
        outputSchemaDefinitions: [EvaluationSchemaField] = [],
        outputRepresentNilExplicitlyInGeneratedContent: Bool = false,
        prewarm: Bool = false,
        streamResponse: Bool = false
    ) {
        self.tools = tools
        self.spotlightSearch = spotlightSearch
        self.profile = profile
        self.outputFields = outputFields
        self.outputSchemaDefinitions = outputSchemaDefinitions
        self.outputRepresentNilExplicitlyInGeneratedContent = outputRepresentNilExplicitlyInGeneratedContent
        self.prewarm = prewarm
        self.streamResponse = streamResponse
    }

    private enum CodingKeys: String, CodingKey {
        case tools, spotlightSearch, profile, outputFields, outputSchemaDefinitions
        case outputRepresentNilExplicitlyInGeneratedContent, prewarm, streamResponse
    }

    /// Decodes required feature settings while defaulting absent Spotlight search, reusable definitions, and explicit-nil policy for older saved suites.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tools = try container.decode([EvaluationCustomToolDefinition].self, forKey: .tools)
        spotlightSearch = try container.decodeIfPresent(
            EvaluationSpotlightSearchConfiguration.self,
            forKey: .spotlightSearch
        ) ?? .init()
        profile = try container.decode(EvaluationProfileConfiguration.self, forKey: .profile)
        outputFields = try container.decode([EvaluationSchemaField].self, forKey: .outputFields)
        outputSchemaDefinitions = try container.decodeIfPresent(
            [EvaluationSchemaField].self,
            forKey: .outputSchemaDefinitions
        ) ?? []
        outputRepresentNilExplicitlyInGeneratedContent = try container.decodeIfPresent(
            Bool.self,
            forKey: .outputRepresentNilExplicitlyInGeneratedContent
        ) ?? false
        prewarm = try container.decode(Bool.self, forKey: .prewarm)
        streamResponse = try container.decode(Bool.self, forKey: .streamResponse)
    }

    var validationIssue: String? {
        if tools.count > Self.maximumTools {
            return "A suite can define at most \(Self.maximumTools) custom tools."
        }
        if outputFields.count > Self.maximumOutputFields {
            return "An output schema can define at most \(Self.maximumOutputFields) fields."
        }
        if let issue = profile.validationIssue {
            return issue
        }
        if let issue = spotlightSearch.validationIssue {
            return issue
        }

        var toolIDs = Set<UUID>()
        var toolNames = Set<String>()
        for tool in tools {
            if let issue = tool.validationIssue {
                return issue
            }
            if !toolIDs.insert(tool.id).inserted {
                return "Custom tool IDs must be unique."
            }
            if !toolNames.insert(tool.name).inserted {
                return "Custom tool names must be unique."
            }
        }

        return Self.schemaValidationIssue(
            fields: outputFields,
            definitions: outputSchemaDefinitions,
            context: "Output schema"
        )
    }

    /// Checks schema structure and reusable definitions against shared size, identity, optionality, reference, and cycle constraints.
    /// Returns the first issue with its schema context, or nil when the complete definition set is valid.
    static func schemaValidationIssue(
        fields: [EvaluationSchemaField],
        definitions: [EvaluationSchemaField] = [],
        context: String
    ) -> String? {
        var fieldIDs = Set<UUID>()
        var nodeCount = 0
        let definitionNames = Set(definitions.map(\.name))
        if definitions.count > EvaluationCustomToolDefinition.maximumParameters {
            return "\(context) can define at most \(EvaluationCustomToolDefinition.maximumParameters) reusable definitions."
        }
        if definitionNames.count != definitions.count {
            return "\(context) reusable definition names must be unique."
        }
        if let issue = schemaValidationIssue(
            fields: fields,
            context: context,
            depth: 1,
            allowsOptional: true,
            definitionNames: definitionNames,
            fieldIDs: &fieldIDs,
            nodeCount: &nodeCount
        ) {
            return issue
        }
        for definition in definitions {
            if let issue = schemaValidationIssue(
                fields: [definition],
                context: "\(context) definition \(definition.name)",
                depth: 1,
                allowsOptional: false,
                definitionNames: definitionNames,
                fieldIDs: &fieldIDs,
                nodeCount: &nodeCount
            ) {
                return issue
            }
        }
        if let cycle = referenceCycle(in: definitions) {
            return "\(context) reusable definitions contain a reference cycle through \(cycle)."
        }
        return nil
    }

    /// Recursively validates fields while sharing node counts and IDs across roots and definitions.
    /// Enforces sibling-name uniqueness, allowed optionality, known references, and bounded depth.
    private static func schemaValidationIssue(
        fields: [EvaluationSchemaField],
        context: String,
        depth: Int,
        allowsOptional: Bool,
        definitionNames: Set<String>,
        fieldIDs: inout Set<UUID>,
        nodeCount: inout Int
    ) -> String? {
        if fields.count > EvaluationCustomToolDefinition.maximumParameters {
            return "\(context) can define at most \(EvaluationCustomToolDefinition.maximumParameters) fields at one level."
        }

        var fieldNames = Set<String>()
        for field in fields {
            nodeCount += 1
            if nodeCount > Self.maximumSchemaNodes {
                return "\(context) can contain at most \(Self.maximumSchemaNodes) fields across all levels."
            }
            if let issue = field.validationIssue {
                return "\(context): \(issue)"
            }
            if !fieldIDs.insert(field.id).inserted {
                return "\(context) field IDs must be unique."
            }
            if !fieldNames.insert(field.name).inserted {
                return "\(context) field names must be unique."
            }
            if field.isOptional, !allowsOptional {
                return "\(context).\(field.name) cannot be optional because only object properties support optionality."
            }
            if field.type == .reference, !definitionNames.contains(field.referenceName) {
                return "\(context).\(field.name) references undefined schema \(field.referenceName)."
            }

            guard !field.children.isEmpty else { continue }
            if depth >= Self.maximumSchemaDepth {
                return "\(context).\(field.name) exceeds the maximum schema depth of \(Self.maximumSchemaDepth)."
            }
            if let issue = schemaValidationIssue(
                fields: field.children,
                context: "\(context).\(field.name)",
                depth: depth + 1,
                allowsOptional: field.type == .object,
                definitionNames: definitionNames,
                fieldIDs: &fieldIDs,
                nodeCount: &nodeCount
            ) {
                return issue
            }
        }
        return nil
    }

    /// Detects cycles among reusable definitions and returns one definition name on a cycle, or nil for an acyclic graph.
    private static func referenceCycle(in definitions: [EvaluationSchemaField]) -> String? {
        let references = Dictionary(uniqueKeysWithValues: definitions.map { definition in
            (definition.name, referencedDefinitionNames(in: definition))
        })
        var visited = Set<String>()
        var active = Set<String>()

        /// Traverses definition references with an active-path set to distinguish a cycle from an already-visited branch.
        func visit(_ name: String) -> String? {
            if active.contains(name) { return name }
            guard visited.insert(name).inserted else { return nil }
            active.insert(name)
            for reference in references[name, default: []] where references[reference] != nil {
                if let cycle = visit(reference) { return cycle }
            }
            active.remove(name)
            return nil
        }

        for name in references.keys {
            if let cycle = visit(name) { return cycle }
        }
        return nil
    }

    /// Collects reusable-definition references from a field and every nested child.
    private static func referencedDefinitionNames(in field: EvaluationSchemaField) -> Set<String> {
        var names = Set<String>()
        if field.type == .reference {
            names.insert(field.referenceName)
        }
        for child in field.children {
            names.formUnion(referencedDefinitionNames(in: child))
        }
        return names
    }
}

@available(macOS 27.0, *)
struct EvaluationProfileConfiguration: Codable, Equatable, Sendable {
    static let maximumNameCharacters = 80
    static let maximumInstructionsBytes = 4_096
    static let maximumCustomReasoningBytes = 128

    var enabled: Bool
    var name: String
    var afterToolInstructions: String
    var requireToolFirst: Bool
    var afterToolSamplingMode: EvaluationSamplingMode
    var afterToolTemperatureEnabled: Bool
    var afterToolTemperature: Double
    var afterToolSeedEnabled: Bool
    var afterToolSeed: UInt64
    var afterToolTopK: Int
    var afterToolProbabilityThreshold: Double
    var afterToolMaximumResponseTokens: Int?
    var afterToolReasoningLevel: EvaluationReasoningLevel
    var afterToolCustomReasoning: String
    var afterToolTranscriptErrorPolicy: EvaluationTranscriptErrorPolicy

    /// Creates a disabled two-phase tool profile by default, retaining optional after-tool generation overrides for later validation.
    init(
        enabled: Bool = false,
        name: String = "Tool workflow",
        afterToolInstructions: String = "",
        requireToolFirst: Bool = false,
        afterToolSamplingMode: EvaluationSamplingMode = .automatic,
        afterToolTemperatureEnabled: Bool = false,
        afterToolTemperature: Double = 0.7,
        afterToolSeedEnabled: Bool = false,
        afterToolSeed: UInt64 = 42,
        afterToolTopK: Int = 40,
        afterToolProbabilityThreshold: Double = 0.9,
        afterToolMaximumResponseTokens: Int? = nil,
        afterToolReasoningLevel: EvaluationReasoningLevel = .automatic,
        afterToolCustomReasoning: String = "",
        afterToolTranscriptErrorPolicy: EvaluationTranscriptErrorPolicy = .automatic
    ) {
        self.enabled = enabled
        self.name = name
        self.afterToolInstructions = afterToolInstructions
        self.requireToolFirst = requireToolFirst
        self.afterToolSamplingMode = afterToolSamplingMode
        self.afterToolTemperatureEnabled = afterToolTemperatureEnabled
        self.afterToolTemperature = afterToolTemperature
        self.afterToolSeedEnabled = afterToolSeedEnabled
        self.afterToolSeed = afterToolSeed
        self.afterToolTopK = afterToolTopK
        self.afterToolProbabilityThreshold = afterToolProbabilityThreshold
        self.afterToolMaximumResponseTokens = afterToolMaximumResponseTokens
        self.afterToolReasoningLevel = afterToolReasoningLevel
        self.afterToolCustomReasoning = afterToolCustomReasoning
        self.afterToolTranscriptErrorPolicy = afterToolTranscriptErrorPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, name, afterToolInstructions, requireToolFirst
        case afterToolSamplingMode, afterToolTemperatureEnabled, afterToolTemperature
        case afterToolSeedEnabled, afterToolSeed, afterToolTopK, afterToolProbabilityThreshold
        case afterToolMaximumResponseTokens, afterToolReasoningLevel, afterToolCustomReasoning
        case afterToolTranscriptErrorPolicy
    }

    /// Decodes profile settings with initializer defaults for missing or null keys, keeping a missing after-tool token cap unset.
    /// Malformed present values still throw.
    init(from decoder: any Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        afterToolInstructions = try container.decodeIfPresent(
            String.self,
            forKey: .afterToolInstructions
        ) ?? defaults.afterToolInstructions
        requireToolFirst = try container.decodeIfPresent(
            Bool.self,
            forKey: .requireToolFirst
        ) ?? defaults.requireToolFirst
        afterToolSamplingMode = try container.decodeIfPresent(
            EvaluationSamplingMode.self,
            forKey: .afterToolSamplingMode
        ) ?? defaults.afterToolSamplingMode
        afterToolTemperatureEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .afterToolTemperatureEnabled
        ) ?? defaults.afterToolTemperatureEnabled
        afterToolTemperature = try container.decodeIfPresent(
            Double.self,
            forKey: .afterToolTemperature
        ) ?? defaults.afterToolTemperature
        afterToolSeedEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .afterToolSeedEnabled
        ) ?? defaults.afterToolSeedEnabled
        afterToolSeed = try container.decodeIfPresent(
            UInt64.self,
            forKey: .afterToolSeed
        ) ?? defaults.afterToolSeed
        afterToolTopK = try container.decodeIfPresent(
            Int.self,
            forKey: .afterToolTopK
        ) ?? defaults.afterToolTopK
        afterToolProbabilityThreshold = try container.decodeIfPresent(
            Double.self,
            forKey: .afterToolProbabilityThreshold
        ) ?? defaults.afterToolProbabilityThreshold
        afterToolMaximumResponseTokens = try container.decodeIfPresent(
            Int.self,
            forKey: .afterToolMaximumResponseTokens
        )
        afterToolReasoningLevel = try container.decodeIfPresent(
            EvaluationReasoningLevel.self,
            forKey: .afterToolReasoningLevel
        ) ?? defaults.afterToolReasoningLevel
        afterToolCustomReasoning = try container.decodeIfPresent(
            String.self,
            forKey: .afterToolCustomReasoning
        ) ?? defaults.afterToolCustomReasoning
        afterToolTranscriptErrorPolicy = try container.decodeIfPresent(
            EvaluationTranscriptErrorPolicy.self,
            forKey: .afterToolTranscriptErrorPolicy
        ) ?? defaults.afterToolTranscriptErrorPolicy
    }

    var validationIssue: String? {
        if name.isEmpty {
            return "Profile name cannot be empty."
        }
        if name.count > Self.maximumNameCharacters {
            return "Profile name must be \(Self.maximumNameCharacters) characters or fewer."
        }
        if afterToolInstructions.utf8.count > Self.maximumInstructionsBytes {
            return "Profile instructions must be \(Self.maximumInstructionsBytes) UTF-8 bytes or fewer."
        }
        guard enabled else { return nil }
        if afterToolTemperatureEnabled,
           !afterToolTemperature.isFinite || !(0...1).contains(afterToolTemperature) {
            return "After-tool temperature must be between 0 and 1."
        }
        if afterToolSamplingMode == .topK, !(1...1_000).contains(afterToolTopK) {
            return "After-tool Top K must be between 1 and 1,000."
        }
        if afterToolSamplingMode == .probability,
           !afterToolProbabilityThreshold.isFinite
            || !(0.01...1).contains(afterToolProbabilityThreshold) {
            return "After-tool probability threshold must be between 0.01 and 1."
        }
        if let afterToolMaximumResponseTokens,
           !(128...4_096).contains(afterToolMaximumResponseTokens) {
            return "After-tool response length must be between 128 and 4,096 tokens."
        }
        if afterToolReasoningLevel == .custom,
           afterToolCustomReasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a custom after-tool reasoning value."
        }
        if afterToolCustomReasoning.utf8.count > Self.maximumCustomReasoningBytes {
            return "Custom after-tool reasoning must be \(Self.maximumCustomReasoningBytes) UTF-8 bytes or fewer."
        }
        return nil
    }
}

@available(macOS 27.0, *)
enum EvaluationSchemaFieldType: String, Codable, CaseIterable, Identifiable, Sendable {
    case string
    case integer
    case number
    case boolean
    case enumeration
    case object
    case array
    case null
    case union
    case reference
    case imageReference

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .string: "Text"
        case .integer: "Integer"
        case .number: "Number"
        case .boolean: "True or false"
        case .enumeration: "Choice"
        case .object: "Object"
        case .array: "Array"
        case .null: "Null"
        case .union: "One of"
        case .reference: "Reference"
        case .imageReference: "Image reference"
        }
    }

    var supportsChildren: Bool {
        self == .object || self == .array || self == .union
    }
}

@available(macOS 27.0, *)
struct EvaluationSchemaField: Identifiable, Codable, Equatable, Sendable {
    static let maximumNameCharacters = 64
    static let maximumDescriptionCharacters = 256
    static let maximumPatternCharacters = 256
    static let maximumEnumValues = 16
    static let maximumEnumValueCharacters = 128
    static let maximumArrayElements = 32

    var id: UUID
    var name: String
    var description: String
    var type: EvaluationSchemaFieldType
    var isOptional: Bool
    var children: [EvaluationSchemaField]
    var enumValues: [EvaluationSchemaEnumValue]
    var constraints: EvaluationSchemaConstraints
    var referenceName: String
    var representNilExplicitlyInGeneratedContent: Bool

    /// Creates an identified schema node with optional children, choices, constraints, and reusable-reference settings.
    /// Type-specific consistency is checked separately rather than normalized during construction.
    init(
        id: UUID = UUID(),
        name: String = "",
        description: String = "",
        type: EvaluationSchemaFieldType = .string,
        isOptional: Bool = false,
        children: [EvaluationSchemaField] = [],
        enumValues: [EvaluationSchemaEnumValue] = [],
        constraints: EvaluationSchemaConstraints = .init(),
        referenceName: String = "",
        representNilExplicitlyInGeneratedContent: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
        self.isOptional = isOptional
        self.children = children
        self.enumValues = enumValues
        self.constraints = constraints
        self.referenceName = referenceName
        self.representNilExplicitlyInGeneratedContent = representNilExplicitlyInGeneratedContent
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, type, isOptional, children, enumValues, constraints, referenceName
        case representNilExplicitlyInGeneratedContent
    }

    /// Decodes required field identity and type settings while defaulting newer nested schemas, choices, constraints, references, and explicit-nil policy.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        type = try container.decode(EvaluationSchemaFieldType.self, forKey: .type)
        isOptional = try container.decode(Bool.self, forKey: .isOptional)
        children = try container.decodeIfPresent([EvaluationSchemaField].self, forKey: .children) ?? []
        enumValues = try container.decodeIfPresent([EvaluationSchemaEnumValue].self, forKey: .enumValues) ?? []
        constraints = try container.decodeIfPresent(EvaluationSchemaConstraints.self, forKey: .constraints) ?? .init()
        referenceName = try container.decodeIfPresent(String.self, forKey: .referenceName) ?? ""
        representNilExplicitlyInGeneratedContent = try container.decodeIfPresent(
            Bool.self,
            forKey: .representNilExplicitlyInGeneratedContent
        ) ?? false
    }

    var validationIssue: String? {
        if !EvaluationIdentifier.isValid(name, maximumCharacters: Self.maximumNameCharacters) {
            return "Field names must be identifiers of \(Self.maximumNameCharacters) characters or fewer."
        }
        if description.count > Self.maximumDescriptionCharacters {
            return "Field descriptions must be \(Self.maximumDescriptionCharacters) characters or fewer."
        }
        if !type.supportsChildren, !children.isEmpty {
            return "Field \(name) cannot keep nested schemas when its type is \(type.rawValue)."
        }
        if type != .enumeration, !enumValues.isEmpty {
            return "Field \(name) cannot keep choice values when its type is \(type.rawValue)."
        }
        if type != .reference, !referenceName.isEmpty {
            return "Field \(name) cannot keep a reference name when its type is \(type.rawValue)."
        }
        if type != .object, representNilExplicitlyInGeneratedContent {
            return "Field \(name) cannot represent nil explicitly when its type is \(type.rawValue)."
        }
        if let issue = constraints.inapplicableConfigurationIssue(for: type, fieldName: name) {
            return issue
        }

        switch type {
        case .string:
            if constraints.stringPattern.count > Self.maximumPatternCharacters {
                return "String patterns must be \(Self.maximumPatternCharacters) characters or fewer."
            }
            if !constraints.stringPattern.isEmpty,
               (try? Regex(constraints.stringPattern)) == nil {
                return "Field \(name) has an invalid regular-expression pattern."
            }
        case .integer:
            if let minimum = constraints.integerMinimum,
               let maximum = constraints.integerMaximum,
               minimum > maximum {
                return "Field \(name) has an integer minimum greater than its maximum."
            }
        case .number:
            if let minimum = constraints.numberMinimum, !minimum.isFinite {
                return "Field \(name) needs a finite number minimum."
            }
            if let maximum = constraints.numberMaximum, !maximum.isFinite {
                return "Field \(name) needs a finite number maximum."
            }
            if let minimum = constraints.numberMinimum,
               let maximum = constraints.numberMaximum,
               minimum > maximum {
                return "Field \(name) has a number minimum greater than its maximum."
            }
        case .boolean:
            break
        case .enumeration:
            if enumValues.isEmpty {
                return "Choice field \(name) needs at least one value."
            }
            if enumValues.count > Self.maximumEnumValues {
                return "Choice field \(name) can define at most \(Self.maximumEnumValues) values."
            }
            var values = Set<String>()
            var valueIDs = Set<UUID>()
            for value in enumValues {
                if !valueIDs.insert(value.id).inserted {
                    return "Choice field \(name) value IDs must be unique."
                }
                if value.value.isEmpty {
                    return "Choice field \(name) cannot contain an empty value."
                }
                if value.value.count > Self.maximumEnumValueCharacters {
                    return "Choice values must be \(Self.maximumEnumValueCharacters) characters or fewer."
                }
                if !values.insert(value.value).inserted {
                    return "Choice field \(name) values must be unique."
                }
            }
        case .object:
            if children.count > EvaluationCustomToolDefinition.maximumParameters {
                return "Object field \(name) can define at most \(EvaluationCustomToolDefinition.maximumParameters) properties."
            }
        case .array:
            if children.count != 1 {
                return "Array field \(name) needs exactly one item schema."
            }
            if let minimum = constraints.arrayMinimumCount,
               !(0...Self.maximumArrayElements).contains(minimum) {
                return "Array minimum counts must be between 0 and \(Self.maximumArrayElements)."
            }
            if let maximum = constraints.arrayMaximumCount,
               !(0...Self.maximumArrayElements).contains(maximum) {
                return "Array maximum counts must be between 0 and \(Self.maximumArrayElements)."
            }
            if let minimum = constraints.arrayMinimumCount,
               let maximum = constraints.arrayMaximumCount,
               minimum > maximum {
                return "Field \(name) has an array minimum count greater than its maximum."
            }
        case .null:
            break
        case .union:
            if !(2...EvaluationCustomToolDefinition.maximumParameters).contains(children.count) {
                return "One-of field \(name) needs between 2 and \(EvaluationCustomToolDefinition.maximumParameters) choices."
            }
        case .reference:
            if !EvaluationIdentifier.isValid(
                referenceName,
                maximumCharacters: Self.maximumNameCharacters
            ) {
                return "Reference field \(name) needs a reusable definition name."
            }
        case .imageReference:
            break
        }
        return nil
    }

    /// Supplies starter item, choice, or union children when the selected type lacks the required editable structure.
    mutating func prepareForSelectedType() {
        if type == .array, children.isEmpty {
            children = [EvaluationSchemaField(name: "item")]
        }
        if type == .enumeration, enumValues.isEmpty {
            enumValues = [EvaluationSchemaEnumValue(value: "value")]
        }
        if type == .union, children.count < 2 {
            children = [
                EvaluationSchemaField(name: "first"),
                EvaluationSchemaField(name: "second")
            ]
        }
    }

    /// Clears configuration inherited from the old type, then supplies the new type's starter schema values.
    mutating func normalizeAfterTypeChange() {
        children = []
        enumValues = []
        constraints = .init()
        referenceName = ""
        representNilExplicitlyInGeneratedContent = false
        prepareForSelectedType()
    }
}

@available(macOS 27.0, *)
struct EvaluationSchemaEnumValue: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var value: String

    /// Creates a choice value with a stable supplied identity or a newly generated editing identity.
    init(id: UUID = UUID(), value: String = "") {
        self.id = id
        self.value = value
    }
}

@available(macOS 27.0, *)
struct EvaluationSchemaConstraints: Codable, Equatable, Sendable {
    var stringPattern: String
    var integerMinimum: Int?
    var integerMaximum: Int?
    var numberMinimum: Double?
    var numberMaximum: Double?
    var arrayMinimumCount: Int?
    var arrayMaximumCount: Int?

    /// Creates optional type-specific constraints; absent bounds and an empty pattern impose no such constraint.
    init(
        stringPattern: String = "",
        integerMinimum: Int? = nil,
        integerMaximum: Int? = nil,
        numberMinimum: Double? = nil,
        numberMaximum: Double? = nil,
        arrayMinimumCount: Int? = nil,
        arrayMaximumCount: Int? = nil
    ) {
        self.stringPattern = stringPattern
        self.integerMinimum = integerMinimum
        self.integerMaximum = integerMaximum
        self.numberMinimum = numberMinimum
        self.numberMaximum = numberMaximum
        self.arrayMinimumCount = arrayMinimumCount
        self.arrayMaximumCount = arrayMaximumCount
    }

    private enum CodingKeys: String, CodingKey {
        case stringPattern, integerMinimum, integerMaximum, numberMinimum, numberMaximum
        case arrayMinimumCount, arrayMaximumCount
    }

    /// Decodes constraints with absent or null bounds left unset and a missing pattern treated as empty.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stringPattern = try container.decodeIfPresent(String.self, forKey: .stringPattern) ?? ""
        integerMinimum = try container.decodeIfPresent(Int.self, forKey: .integerMinimum)
        integerMaximum = try container.decodeIfPresent(Int.self, forKey: .integerMaximum)
        numberMinimum = try container.decodeIfPresent(Double.self, forKey: .numberMinimum)
        numberMaximum = try container.decodeIfPresent(Double.self, forKey: .numberMaximum)
        arrayMinimumCount = try container.decodeIfPresent(Int.self, forKey: .arrayMinimumCount)
        arrayMaximumCount = try container.decodeIfPresent(Int.self, forKey: .arrayMaximumCount)
    }

    var hasIntegerMinimum: Bool {
        get { integerMinimum != nil }
        set { integerMinimum = newValue ? integerMinimum ?? 0 : nil }
    }

    var editableIntegerMinimum: Int {
        get { integerMinimum ?? 0 }
        set { integerMinimum = newValue }
    }

    var hasIntegerMaximum: Bool {
        get { integerMaximum != nil }
        set { integerMaximum = newValue ? integerMaximum ?? 0 : nil }
    }

    var editableIntegerMaximum: Int {
        get { integerMaximum ?? 0 }
        set { integerMaximum = newValue }
    }

    var hasNumberMinimum: Bool {
        get { numberMinimum != nil }
        set { numberMinimum = newValue ? numberMinimum ?? 0 : nil }
    }

    var editableNumberMinimum: Double {
        get { numberMinimum ?? 0 }
        set { numberMinimum = newValue }
    }

    var hasNumberMaximum: Bool {
        get { numberMaximum != nil }
        set { numberMaximum = newValue ? numberMaximum ?? 0 : nil }
    }

    var editableNumberMaximum: Double {
        get { numberMaximum ?? 0 }
        set { numberMaximum = newValue }
    }

    var hasArrayMinimumCount: Bool {
        get { arrayMinimumCount != nil }
        set { arrayMinimumCount = newValue ? arrayMinimumCount ?? 0 : nil }
    }

    var editableArrayMinimumCount: Int {
        get { arrayMinimumCount ?? 0 }
        set { arrayMinimumCount = newValue }
    }

    var hasArrayMaximumCount: Bool {
        get { arrayMaximumCount != nil }
        set { arrayMaximumCount = newValue ? arrayMaximumCount ?? Self.defaultMaximumArrayCount : nil }
    }

    var editableArrayMaximumCount: Int {
        get { arrayMaximumCount ?? Self.defaultMaximumArrayCount }
        set { arrayMaximumCount = newValue }
    }

    private static let defaultMaximumArrayCount = 8

    /// Finds retained constraints that do not apply to the selected field type, returning a field-specific issue.
    func inapplicableConfigurationIssue(
        for type: EvaluationSchemaFieldType,
        fieldName: String
    ) -> String? {
        let hasIntegerBounds = integerMinimum != nil || integerMaximum != nil
        let hasNumberBounds = numberMinimum != nil || numberMaximum != nil
        let hasArrayBounds = arrayMinimumCount != nil || arrayMaximumCount != nil

        if type != .string, !stringPattern.isEmpty {
            return "Field \(fieldName) cannot keep a string pattern when its type is \(type.rawValue)."
        }
        if type != .integer, hasIntegerBounds {
            return "Field \(fieldName) cannot keep integer bounds when its type is \(type.rawValue)."
        }
        if type != .number, hasNumberBounds {
            return "Field \(fieldName) cannot keep number bounds when its type is \(type.rawValue)."
        }
        if type != .array, hasArrayBounds {
            return "Field \(fieldName) cannot keep array count bounds when its type is \(type.rawValue)."
        }
        return nil
    }
}

@available(macOS 27.0, *)
enum EvaluationCustomToolMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fixture
    case localHTTP

    var id: Self { self }

    var title: String {
        switch self {
        case .fixture: "Fixture response"
        case .localHTTP: "Local HTTP bridge"
        }
    }
}

@available(macOS 27.0, *)
struct EvaluationCustomToolDefinition: Identifiable, Codable, Equatable, Sendable {
    static let maximumNameCharacters = 64
    static let maximumDescriptionCharacters = 512
    static let maximumParameters = 8
    static let maximumEndpointCharacters = 512
    static let maximumArgumentBytes = 16_384
    static let maximumOutputBytes = 4_096
    static let requestTimeoutSeconds: TimeInterval = 10

    var id: UUID
    var name: String
    var description: String
    var parameters: [EvaluationSchemaField]
    var schemaDefinitions: [EvaluationSchemaField]
    var representNilExplicitlyInGeneratedContent: Bool
    var mode: EvaluationCustomToolMode
    var fixtureResponse: String
    var endpoint: String

    /// Creates a fixture-mode tool definition by default, retaining its parameter schemas and optional local endpoint for later validation.
    init(
        id: UUID = UUID(),
        name: String = "",
        description: String = "",
        parameters: [EvaluationSchemaField] = [],
        schemaDefinitions: [EvaluationSchemaField] = [],
        representNilExplicitlyInGeneratedContent: Bool = false,
        mode: EvaluationCustomToolMode = .fixture,
        fixtureResponse: String = "",
        endpoint: String = ""
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.parameters = parameters
        self.schemaDefinitions = schemaDefinitions
        self.representNilExplicitlyInGeneratedContent = representNilExplicitlyInGeneratedContent
        self.mode = mode
        self.fixtureResponse = fixtureResponse
        self.endpoint = endpoint
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, parameters, schemaDefinitions
        case representNilExplicitlyInGeneratedContent, mode, fixtureResponse, endpoint
    }

    /// Decodes required tool fields while defaulting absent reusable definitions and explicit-nil policy for older tool definitions.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        parameters = try container.decode([EvaluationSchemaField].self, forKey: .parameters)
        schemaDefinitions = try container.decodeIfPresent(
            [EvaluationSchemaField].self,
            forKey: .schemaDefinitions
        ) ?? []
        representNilExplicitlyInGeneratedContent = try container.decodeIfPresent(
            Bool.self,
            forKey: .representNilExplicitlyInGeneratedContent
        ) ?? false
        mode = try container.decode(EvaluationCustomToolMode.self, forKey: .mode)
        fixtureResponse = try container.decode(String.self, forKey: .fixtureResponse)
        endpoint = try container.decode(String.self, forKey: .endpoint)
    }

    var validationIssue: String? {
        if !EvaluationIdentifier.isValid(name, maximumCharacters: Self.maximumNameCharacters) {
            return "Tool names must be identifiers of \(Self.maximumNameCharacters) characters or fewer."
        }
        if description.isEmpty {
            return "Tool \(name) needs a description."
        }
        if description.count > Self.maximumDescriptionCharacters {
            return "Tool descriptions must be \(Self.maximumDescriptionCharacters) characters or fewer."
        }
        if parameters.count > Self.maximumParameters {
            return "Tool \(name) can define at most \(Self.maximumParameters) parameters."
        }
        if let issue = EvaluationFeatureConfiguration.schemaValidationIssue(
            fields: parameters,
            definitions: schemaDefinitions,
            context: "Tool \(name)"
        ) {
            return issue
        }
        if fixtureResponse.utf8.count > Self.maximumOutputBytes {
            return "Tool fixture output must be \(Self.maximumOutputBytes) UTF-8 bytes or fewer."
        }
        if endpoint.count > Self.maximumEndpointCharacters {
            return "Local tool endpoints must be \(Self.maximumEndpointCharacters) characters or fewer."
        }

        switch mode {
        case .fixture:
            break
        case .localHTTP:
            if let issue = Self.endpointValidationIssue(endpoint) {
                return issue
            }
        }
        return nil
    }

    /// Returns the configured endpoint only after loopback HTTP validation, throwing a configuration error for rejected or invalid URLs.
    func validatedEndpointURL() throws -> URL {
        if let issue = Self.endpointValidationIssue(endpoint) {
            throw EvaluationFeatureConfigurationError.invalid(issue)
        }
        guard let url = URL(string: endpoint) else {
            throw EvaluationFeatureConfigurationError.invalid("The local tool endpoint is not a valid URL.")
        }
        return url
    }

    /// Requires HTTP on 127.0.0.1 with an explicit valid port and rejects credentials, queries, and fragments.
    private static func endpointValidationIssue(_ endpoint: String) -> String? {
        guard !endpoint.isEmpty, let components = URLComponents(string: endpoint) else {
            return "Local tools need an HTTP endpoint."
        }
        guard components.scheme == "http", components.host == "127.0.0.1" else {
            return "Local tool endpoints must use http://127.0.0.1 with an explicit port."
        }
        guard components.user == nil, components.password == nil else {
            return "Local tool endpoints cannot contain credentials."
        }
        guard components.query == nil, components.fragment == nil else {
            return "Local tool endpoints cannot contain a query or fragment."
        }
        guard let port = components.port, (1...65_535).contains(port) else {
            return "Local tool endpoints need an explicit port."
        }

        return nil
    }
}

@available(macOS 27.0, *)
enum EvaluationFeatureConfigurationError: LocalizedError, Sendable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let issue): issue
        }
    }
}

@available(macOS 27.0, *)
enum EvaluationIdentifier {
    /// Checks a bounded ASCII identifier: a letter or underscore first, followed by letters, digits, or underscores.
    static func isValid(_ value: String, maximumCharacters: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumCharacters else { return false }

        for (index, scalar) in value.unicodeScalars.enumerated() {
            let isUppercaseLetter = scalar.value >= 65 && scalar.value <= 90
            let isLowercaseLetter = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            let isUnderscore = scalar.value == 95

            if index == 0 {
                guard isUppercaseLetter || isLowercaseLetter || isUnderscore else { return false }
            } else {
                guard isUppercaseLetter || isLowercaseLetter || isDigit || isUnderscore else { return false }
            }
        }
        return true
    }
}
