import Foundation
import FoundationModels
import Testing
@testable import FoundationEvals

struct SchemaCustomizationTests {
    @Test func unsupportedGenerationGuidePreservesSDKContextWithoutArbitraryMetadata() {
        let context = LanguageModelError.UnsupportedGenerationGuide(
            schemaName: "EvaluationOutput",
            debugDescription: "A generation guide with an unsupported pattern was used.",
            metadata: ["internalProviderDetail": "not persisted"]
        )

        let result = EvaluationRunner.traceError(
            LanguageModelError.unsupportedGenerationGuide(context)
        )

        #expect(result.category == "unsupportedGenerationGuide")
        #expect(result.message.contains("An unsupported generation guide was used."))
        #expect(result.message.contains("Schema: EvaluationOutput."))
        #expect(result.message.contains("unsupported pattern"))
        #expect(!result.message.contains("internalProviderDetail"))
        #expect(!result.message.contains("not persisted"))
    }

    @Test func legacyPrimitiveSchemaFieldsDecodeWithNewDefaults() throws {
        let fieldID = UUID()
        let toolID = UUID()
        let json = """
        {
          "tools": [{
            "id": "\(toolID.uuidString)",
            "name": "lookup",
            "description": "Looks up a value.",
            "parameters": [{
              "id": "\(fieldID.uuidString)",
              "name": "query",
              "description": "Search query",
              "type": "string",
              "isOptional": false
            }],
            "mode": "fixture",
            "fixtureResponse": "ok",
            "endpoint": ""
          }],
          "profile": {
            "enabled": false,
            "name": "Tool workflow",
            "afterToolInstructions": "",
            "requireToolFirst": false
          },
          "outputFields": [{
            "id": "\(UUID().uuidString)",
            "name": "answer",
            "description": "Answer",
            "type": "string",
            "isOptional": false
          }],
          "prewarm": false,
          "streamResponse": false
        }
        """

        let configuration = try JSONDecoder().decode(
            EvaluationFeatureConfiguration.self,
            from: Data(json.utf8)
        )

        #expect(configuration.spotlightSearch == .init())
        #expect(!configuration.outputRepresentNilExplicitlyInGeneratedContent)
        #expect(configuration.outputSchemaDefinitions.isEmpty)
        #expect(configuration.tools[0].schemaDefinitions.isEmpty)
        #expect(!configuration.tools[0].representNilExplicitlyInGeneratedContent)
        #expect(configuration.tools[0].parameters[0].children.isEmpty)
        #expect(configuration.tools[0].parameters[0].enumValues.isEmpty)
        #expect(configuration.tools[0].parameters[0].constraints == .init())
        #expect(configuration.tools[0].parameters[0].referenceName.isEmpty)
        #expect(!configuration.tools[0].parameters[0].representNilExplicitlyInGeneratedContent)
    }

    @Test func nestedConstrainedSchemaBuildsWithUnionReferencesAndImages() throws {
        let reusableLocation = EvaluationSchemaField(
            name: "Location",
            description: "A reusable location schema.",
            type: .object,
            children: [
                EvaluationSchemaField(
                    name: "city",
                    type: .string,
                    constraints: .init(stringPattern: #"^[A-Za-z ]+$"#)
                ),
                EvaluationSchemaField(
                    name: "coordinates",
                    type: .array,
                    children: [
                        EvaluationSchemaField(
                            name: "coordinate",
                            type: .number,
                            constraints: .init(numberMinimum: -180, numberMaximum: 180)
                        )
                    ],
                    constraints: .init(arrayMinimumCount: 2, arrayMaximumCount: 2)
                )
            ],
            representNilExplicitlyInGeneratedContent: true
        )
        let fields = [
            EvaluationSchemaField(
                name: "status",
                type: .enumeration,
                enumValues: [
                    EvaluationSchemaEnumValue(value: "ready"),
                    EvaluationSchemaEnumValue(value: "blocked")
                ]
            ),
            EvaluationSchemaField(
                name: "payload",
                type: .union,
                children: [
                    EvaluationSchemaField(name: "none", type: .null),
                    EvaluationSchemaField(
                        name: "location",
                        type: .reference,
                        referenceName: "Location"
                    )
                ]
            ),
            EvaluationSchemaField(name: "sourceImage", type: .imageReference, isOptional: true)
        ]

        #expect(
            EvaluationFeatureConfiguration.schemaValidationIssue(
                fields: fields,
                definitions: [reusableLocation],
                context: "Test schema"
            ) == nil
        )
        _ = try EvaluationSchemaBuilder.schema(
            fields: fields,
            name: "TestSchema",
            definitions: [reusableLocation],
            representNilExplicitlyInGeneratedContent: true
        )
    }

    @Test func nestedSchemaRoundTripsWithoutLosingConstraintsOrDefinitions() throws {
        let definition = EvaluationSchemaField(
            name: "Score",
            type: .integer,
            constraints: .init(integerMinimum: 1, integerMaximum: 5)
        )
        let configuration = EvaluationFeatureConfiguration(
            tools: [
                EvaluationCustomToolDefinition(
                    name: "rate",
                    description: "Rates a nested payload.",
                    parameters: [
                        EvaluationSchemaField(
                            name: "items",
                            type: .array,
                            children: [
                                EvaluationSchemaField(
                                    name: "item",
                                    type: .reference,
                                    referenceName: "Score"
                                )
                            ],
                            constraints: .init(arrayMinimumCount: 1, arrayMaximumCount: 4)
                        )
                    ],
                    schemaDefinitions: [definition],
                    representNilExplicitlyInGeneratedContent: true,
                    fixtureResponse: "rated"
                )
            ],
            outputFields: [
                EvaluationSchemaField(
                    name: "result",
                    type: .reference,
                    referenceName: "Score"
                )
            ],
            outputSchemaDefinitions: [definition],
            outputRepresentNilExplicitlyInGeneratedContent: true
        )

        let decoded = try JSONDecoder().decode(
            EvaluationFeatureConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )

        #expect(decoded == configuration)
        #expect(decoded.validationIssue == nil)
        #expect(decoded.tools[0].representNilExplicitlyInGeneratedContent)
        #expect(decoded.outputRepresentNilExplicitlyInGeneratedContent)
    }

    @Test func validationRejectsInvalidBoundsDepthReferencesAndCycles() {
        let invalidBounds = EvaluationSchemaField(
            name: "count",
            type: .integer,
            constraints: .init(integerMinimum: 10, integerMaximum: 2)
        )
        #expect(invalidBounds.validationIssue?.contains("minimum") == true)

        let invalidPattern = EvaluationSchemaField(
            name: "code",
            type: .string,
            constraints: .init(stringPattern: "[")
        )
        #expect(invalidPattern.validationIssue?.contains("regular-expression") == true)

        let undefinedReference = EvaluationSchemaField(
            name: "missing",
            type: .reference,
            referenceName: "Unknown"
        )
        #expect(
            EvaluationFeatureConfiguration.schemaValidationIssue(
                fields: [undefinedReference],
                context: "Test schema"
            )?.contains("undefined") == true
        )

        let cycleA = EvaluationSchemaField(
            name: "A",
            type: .object,
            children: [EvaluationSchemaField(name: "b", type: .reference, referenceName: "B")]
        )
        let cycleB = EvaluationSchemaField(
            name: "B",
            type: .object,
            children: [EvaluationSchemaField(name: "a", type: .reference, referenceName: "A")]
        )
        #expect(
            EvaluationFeatureConfiguration.schemaValidationIssue(
                fields: [EvaluationSchemaField(name: "root", type: .reference, referenceName: "A")],
                definitions: [cycleA, cycleB],
                context: "Test schema"
            )?.contains("reference cycle") == true
        )

        let tooDeep = EvaluationSchemaField(
            name: "one",
            type: .object,
            children: [
                EvaluationSchemaField(
                    name: "two",
                    type: .object,
                    children: [
                        EvaluationSchemaField(
                            name: "three",
                            type: .object,
                            children: [
                                EvaluationSchemaField(
                                    name: "four",
                                    type: .object,
                                    children: [EvaluationSchemaField(name: "five")]
                                )
                            ]
                        )
                    ]
                )
            ]
        )
        #expect(
            EvaluationFeatureConfiguration.schemaValidationIssue(
                fields: [tooDeep],
                context: "Test schema"
            )?.contains("maximum schema depth") == true
        )
    }

    @Test func typeChangesClearInvisibleSchemaConfiguration() {
        var field = EvaluationSchemaField(
            name: "payload",
            type: .object,
            children: [EvaluationSchemaField(name: "not valid")],
            representNilExplicitlyInGeneratedContent: true
        )

        field.type = .string
        field.normalizeAfterTypeChange()
        #expect(field.children.isEmpty)
        #expect(!field.representNilExplicitlyInGeneratedContent)
        #expect(field.validationIssue == nil)

        field.type = .enumeration
        field.normalizeAfterTypeChange()
        #expect(field.enumValues.map(\.value) == ["value"])

        field.type = .reference
        field.normalizeAfterTypeChange()
        #expect(field.enumValues.isEmpty)
        #expect(field.referenceName.isEmpty)
        field.referenceName = "Payload"

        field.type = .array
        field.normalizeAfterTypeChange()
        #expect(field.referenceName.isEmpty)
        #expect(field.children.count == 1)
        field.constraints.arrayMinimumCount = 1

        field.type = .boolean
        field.normalizeAfterTypeChange()
        #expect(field.children.isEmpty)
        #expect(field.constraints == .init())
        #expect(field.validationIssue == nil)
    }

    @Test func validationRejectsHiddenConfigurationForInactiveTypes() {
        let hiddenChild = EvaluationSchemaField(
            name: "text",
            type: .string,
            children: [EvaluationSchemaField(name: "hidden")]
        )
        #expect(hiddenChild.validationIssue?.contains("nested schemas") == true)

        let hiddenEnum = EvaluationSchemaField(
            name: "count",
            type: .integer,
            enumValues: [EvaluationSchemaEnumValue(value: "one")]
        )
        #expect(hiddenEnum.validationIssue?.contains("choice values") == true)

        let hiddenReference = EvaluationSchemaField(
            name: "flag",
            type: .boolean,
            referenceName: "Hidden"
        )
        #expect(hiddenReference.validationIssue?.contains("reference name") == true)

        let hiddenBounds = EvaluationSchemaField(
            name: "label",
            type: .string,
            constraints: .init(arrayMinimumCount: 1)
        )
        #expect(hiddenBounds.validationIssue?.contains("array count bounds") == true)

        let hiddenExplicitNil = EvaluationSchemaField(
            name: "label",
            type: .string,
            representNilExplicitlyInGeneratedContent: true
        )
        #expect(hiddenExplicitNil.validationIssue?.contains("represent nil explicitly") == true)
    }

    @Test func validationRejectsDuplicateChoiceIDsAndIgnoredOptionality() {
        let duplicateID = UUID()
        let duplicateChoiceIDs = EvaluationSchemaField(
            name: "status",
            type: .enumeration,
            enumValues: [
                EvaluationSchemaEnumValue(id: duplicateID, value: "ready"),
                EvaluationSchemaEnumValue(id: duplicateID, value: "blocked")
            ]
        )
        #expect(duplicateChoiceIDs.validationIssue?.contains("value IDs") == true)

        let optionalArrayItem = EvaluationSchemaField(
            name: "items",
            type: .array,
            children: [EvaluationSchemaField(name: "item", isOptional: true)]
        )
        #expect(
            EvaluationFeatureConfiguration.schemaValidationIssue(
                fields: [optionalArrayItem],
                context: "Test schema"
            )?.contains("only object properties support optionality") == true
        )

        let optionalUnionChoice = EvaluationSchemaField(
            name: "result",
            type: .union,
            children: [
                EvaluationSchemaField(name: "text", isOptional: true),
                EvaluationSchemaField(name: "none", type: .null)
            ]
        )
        #expect(
            EvaluationFeatureConfiguration.schemaValidationIssue(
                fields: [optionalUnionChoice],
                context: "Test schema"
            )?.contains("only object properties support optionality") == true
        )

        let optionalDefinition = EvaluationSchemaField(name: "Reusable", isOptional: true)
        #expect(
            EvaluationFeatureConfiguration.schemaValidationIssue(
                fields: [],
                definitions: [optionalDefinition],
                context: "Test schema"
            )?.contains("only object properties support optionality") == true
        )
    }

    @Test func mcpCatalogPublishesRecursiveSchemaCustomizationKeys() throws {
        let replaceTool = try #require(
            MCPToolCatalog.allDefinitions.first { $0.name == "eval_replace_suite" }
        )
        let rootProperties = try #require(replaceTool.inputSchema.objectValue?["properties"]?.objectValue)
        let suite = try #require(rootProperties["suite"]?.objectValue)
        let suiteProperties = try #require(suite["properties"]?.objectValue)
        let features = try #require(suiteProperties["features"]?.objectValue)
        let featureProperties = try #require(features["properties"]?.objectValue)
        let outputFields = try #require(featureProperties["outputFields"]?.objectValue)
        let fieldSchema = try #require(outputFields["items"]?.objectValue)
        let fieldProperties = try #require(fieldSchema["properties"]?.objectValue)

        #expect(fieldProperties["children"] != nil)
        #expect(fieldProperties["enumValues"] != nil)
        #expect(fieldProperties["constraints"] != nil)
        #expect(fieldProperties["referenceName"] != nil)
        #expect(fieldProperties["representNilExplicitlyInGeneratedContent"] != nil)
        #expect(featureProperties["outputSchemaDefinitions"] != nil)
        #expect(featureProperties["outputRepresentNilExplicitlyInGeneratedContent"] != nil)
        let tools = try #require(featureProperties["tools"]?.objectValue)
        let toolSchema = try #require(tools["items"]?.objectValue)
        let toolProperties = try #require(toolSchema["properties"]?.objectValue)
        #expect(toolProperties["representNilExplicitlyInGeneratedContent"] != nil)
        let spotlight = try #require(featureProperties["spotlightSearch"]?.objectValue)
        let spotlightProperties = try #require(spotlight["properties"]?.objectValue)
        #expect(spotlight["additionalProperties"] == .bool(false))
        #expect(spotlightProperties["fileSource"] != nil)
        #expect(spotlightProperties["coreSpotlightSource"] != nil)
        #expect(spotlightProperties["guidance"] != nil)
        #expect(spotlightProperties["contactIdentity"] != nil)
        #expect(spotlightProperties["pipeline"] != nil)
        #expect(spotlightProperties["maximumResponseSize"] != nil)

        let typeSchema = try #require(fieldProperties["type"]?.objectValue)
        let typeEnum = try #require(typeSchema["enum"])
        guard case .array(let typeValues) = typeEnum else {
            Issue.record("Expected the schema type property to publish enum values.")
            return
        }
        let publishedTypes = Set(typeValues.compactMap(\.stringValue))
        #expect(publishedTypes == Set(EvaluationSchemaFieldType.allCases.map(\.rawValue)))
    }
}
