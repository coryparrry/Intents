import AppIntents
import Foundation
import UniformTypeIdentifiers

// Persisted raw values and entity identifiers are stable fixture contracts.
enum FixtureChoice: String, AppEnum {
    case first = "first"
    case second = "second"
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Fixture choice"
    static let caseDisplayRepresentations: [FixtureChoice: DisplayRepresentation] = [
        .first: "First", .second: "Second"
    ]
}

struct FixtureReference: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Fixture reference"
    static let defaultQuery = FixtureReferenceQuery()
    let id: String
    @Property(title: "Name") var name: String
    init(id: String) {
        self.id = id
        self.name = "Reference one"
    }
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}

struct FixtureReferenceQuery: EntityStringQuery {
    private let reference = FixtureReference(id: "reference-1")
    func entities(for identifiers: [String]) async throws -> [FixtureReference] {
        identifiers.contains(reference.id) ? [reference] : []
    }
    func entities(matching string: String) async throws -> [FixtureReference] {
        "Reference one".localizedCaseInsensitiveContains(string) || reference.id == string ? [reference] : []
    }
    func suggestedEntities() async throws -> [FixtureReference] { [reference] }
}

struct EchoTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo text"
    @Parameter(title: "Value") var value: String
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> { .result(value: value) }
}

struct EchoBoolIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo bool"
    @Parameter(title: "Value") var value: Bool
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> { .result(value: value) }
}

struct EchoIntegerIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo integer"
    @Parameter(title: "Value") var value: Int
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<Int> { .result(value: value) }
}

struct EchoDecimalIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo decimal"
    @Parameter(title: "Value") var value: Double
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<Double> { .result(value: value) }
}

struct EchoDateIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo date"
    @Parameter(title: "Value") var value: Date
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<Date> { .result(value: value) }
}

struct EchoEnumIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo enum"
    @Parameter(title: "Value") var value: FixtureChoice
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> { .result(value: value.rawValue) }
}

struct EchoEntityIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo entity"
    @Parameter(title: "Value") var value: FixtureReference
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> { .result(value: value.id) }
}

struct EchoDurationIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo duration"
    @Parameter(title: "Value") var value: Duration
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<Duration> { .result(value: value) }
}

struct EchoCalendarComponentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo calendar components"
    @Parameter(title: "Value") var value: DateComponents
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<DateComponents> { .result(value: value) }
}

struct EchoURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo URL"
    @Parameter(title: "Value") var value: URL
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<URL> { .result(value: value) }
}

struct EchoIntentFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo file"
    @Parameter(title: "Value") var value: IntentFile
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> { .result(value: value) }
}

struct EchoTextArrayIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo text array"
    @Parameter(title: "Value") var value: [String]
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> { .result(value: value) }
}

struct EchoBoolArrayIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo bool array"
    @Parameter(title: "Value") var value: [Bool]
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<[Bool]> { .result(value: value) }
}

struct EchoIntegerArrayIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo integer array"
    @Parameter(title: "Value") var value: [Int]
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<[Int]> { .result(value: value) }
}

struct EchoDecimalArrayIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo decimal array"
    @Parameter(title: "Value") var value: [Double]
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<[Double]> { .result(value: value) }
}

struct EchoDateArrayIntent: AppIntent {
    static let title: LocalizedStringResource = "Echo date array"
    @Parameter(title: "Value") var value: [Date]
    static var parameterSummary: some ParameterSummary { Summary("Echo \(\.$value)") }
    func perform() async throws -> some IntentResult & ReturnsValue<[Date]> { .result(value: value) }
}

struct MakeFixtureFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Make fixture file"
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        .result(value: IntentFile(data: Data("phase3 fixture".utf8), filename: "fixture.txt", type: .plainText))
    }
}
