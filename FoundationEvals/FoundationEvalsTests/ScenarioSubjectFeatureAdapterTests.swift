import Foundation
import CryptoKit
import Testing
@testable import FoundationEvals

struct ScenarioSubjectFeatureAdapterTests {
    @Test func featureImplementationVersionDoesNotChangeDeclaredInterface() throws {
        let schema = DeveloperSubjectInputSchema(version: "1", fields: [
            .init(name: "request", valueType: .string)
        ])
        var feature = DeveloperFeatureDescriptor(
            id: "notes.summary", displayName: "Summarise Note", version: "build-A",
            inputTypeName: String(reflecting: DeveloperSubjectInput.self),
            outputTypeName: "Summary.Output", subjectInputSchema: schema
        )
        let baseline = try ScenarioSubjectFeatureAdapter.interfaceDigest(feature)

        feature.version = "build-B"
        #expect(try ScenarioSubjectFeatureAdapter.interfaceDigest(feature) == baseline)

        feature.subjectInputSchema?.version = "2"
        #expect(try ScenarioSubjectFeatureAdapter.interfaceDigest(feature) != baseline)
        feature.subjectInputSchema = schema
        feature.outputTypeName = "Summary.OutputV2"
        #expect(try ScenarioSubjectFeatureAdapter.interfaceDigest(feature) != baseline)
    }

    @Test func subjectDigestTracksBusinessInputAndFixtureWithoutExecutionIDs() throws {
        let fixture = ScenarioFixture(
            id: "note-1", version: "1", digest: "fixture-A", isSynthetic: true,
            preparationOperation: "prepare", cleanupOperation: "cleanup"
        )
        var binding = ScenarioFeatureBinding(
            featureID: "notes.summary", interfaceDigest: "interface",
            inputMapping: [
                .init(featureInputName: "request", value: .string("Summarise this")),
                .init(featureInputName: "source", value: .string("Source document"))
            ],
            outputProjections: []
        )
        let baseline = try ScenarioSubjectFeatureAdapter.subjectInputDigest(binding: binding, fixture: fixture)
        #expect(baseline.count == 64)
        let isLowercaseSHA256 = baseline.range(
            of: "^[0-9a-f]{64}$", options: .regularExpression
        ) != nil
        #expect(isLowercaseSHA256)

        binding.inputMapping.reverse()
        #expect(try ScenarioSubjectFeatureAdapter.subjectInputDigest(binding: binding, fixture: fixture) == baseline)

        binding.inputMapping[0].value = .string("Changed source document")
        #expect(try ScenarioSubjectFeatureAdapter.subjectInputDigest(binding: binding, fixture: fixture) != baseline)
        binding.inputMapping[0].value = .string("Source document")
        var changedFixture = fixture
        changedFixture.digest = "fixture-B"
        #expect(try ScenarioSubjectFeatureAdapter.subjectInputDigest(binding: binding, fixture: changedFixture) != baseline)

        binding.inputMapping.append(.init(featureInputName: "request", value: .string("duplicate")))
        #expect(throws: ScenarioFeatureSubjectDigest.InputError.self) {
            _ = try ScenarioSubjectFeatureAdapter.subjectInputDigest(binding: binding, fixture: fixture)
        }
    }

    @Test func portableDigestMatchesRunnerBusinessPayloadEncoding() throws {
        let fixture = ScenarioFixture(
            id: "note-1", version: "1", digest: "fixture-A", isSynthetic: true,
            preparationOperation: "prepare", cleanupOperation: "cleanup"
        )
        let binding = ScenarioFeatureBinding(
            featureID: "notes.summary", interfaceDigest: "interface",
            inputMapping: [
                .init(featureInputName: "request", value: .string("Summarise this")),
                .init(featureInputName: "source", value: .array([.string("first"), .integer(2)]))
            ], outputProjections: []
        )
        struct RunnerPayload: Encodable {
            var businessInputs: [String: DeveloperSubjectValue]
            var fixtureReferences: [DeveloperSubjectFixtureReference]
        }
        let runnerPayload = RunnerPayload(
            businessInputs: ["request": .string("Summarise this"),
                             "source": .array([.string("first"), .integer(2)])],
            fixtureReferences: [.init(identifier: "note-1", contractDigest: "fixture-A")]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let runnerBytes = try encoder.encode(runnerPayload)
        let runnerDigest = SHA256.hash(data: runnerBytes).map { String(format: "%02x", $0) }.joined()
        #expect(try ScenarioFeatureSubjectDigest.digest(binding: binding, fixture: fixture) == runnerDigest)
        #expect(try ScenarioSubjectFeatureAdapter.subjectInputDigest(binding: binding, fixture: fixture) == runnerDigest)
    }
}
