import CryptoKit
import Foundation

/// A versioned set of authored Siri scenarios for one compiled Mac app.
public struct SiriStudioDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var bundleIdentifier: String
    public var scenarios: [SiriStudioScenario]

    /// Starts a document for the given bundle.
    public init(bundleIdentifier: String, scenarios: [SiriStudioScenario] = []) {
        version = Self.currentVersion
        self.bundleIdentifier = bundleIdentifier
        self.scenarios = scenarios
    }

    /// Reads a bounded local document and rejects formats this version cannot edit.
    public static func read(from url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = 16 * 1024 * 1024
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw MacIntentTestingError("Scenario documents must be at most 16 MB.") }
        struct Header: Decodable { let version: Int }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: bytes)
        guard header.version == currentVersion else {
            throw MacIntentTestingError("Unsupported Siri Studio document version \(header.version).")
        }
        return try decoder.decode(Self.self, from: bytes)
    }

    /// Increments revisions for changed scenarios, ignoring caller edits to the revision counter.
    public mutating func updateRevisions(from saved: Self) {
        for index in scenarios.indices {
            guard let previous = saved.scenarios.first(where: { $0.id == scenarios[index].id }) else { continue }
            scenarios[index].revision = previous.revision
            if scenarios[index] != previous, previous.revision < Int.max {
                scenarios[index].revision += 1
            }
        }
    }

    /// Writes stable JSON atomically. The caller decides when draft validation is required.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(self)
        guard bytes.count <= 16 * 1024 * 1024 else {
            throw MacIntentTestingError("Scenario documents must be at most 16 MB.")
        }
        try bytes.write(to: url, options: .atomic)
    }
}

/// A conversation, optional reset action, and repeat count.
public struct SiriStudioScenario: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var revision: Int
    public var repeatCount: Int
    public var turns: [SiriStudioTurn]
    public var scenarioExpectations: SiriStudioExpectations
    public var setup: MacIntentTestCase?

    /// Starts a scenario with one editable turn by default.
    public init(id: UUID = UUID(), name: String, revision: Int = 1, repeatCount: Int = 1,
                turns: [SiriStudioTurn] = [.init()], scenarioExpectations: SiriStudioExpectations = .init(),
                setup: MacIntentTestCase? = nil) {
        self.id = id; self.name = name; self.revision = revision; self.repeatCount = repeatCount
        self.turns = turns; self.scenarioExpectations = scenarioExpectations; self.setup = setup
    }

    /// Fingerprints the full authored scenario and target app independently of JSON file formatting.
    func contentDigest(bundleIdentifier: String) throws -> String {
        struct Input: Encodable {
            let bundleIdentifier: String
            let scenario: SiriStudioScenario
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(Input(bundleIdentifier: bundleIdentifier, scenario: self))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The Apple metrics that the authored expectations actually produce.
    var metrics: [String] {
        let expectations = [scenarioExpectations] + turns.map(\.expectations)
        return (expectations.contains { !$0.calls.isEmpty || !$0.forbidden.isEmpty } ? ["intentsAllPass"] : [])
            + (expectations.contains { !$0.replyContains.isEmpty } ? ["siriResponseAllPass"] : [])
    }
}

/// One request in the conversation, with a persistent ID independent of Apple's turn ID.
public struct SiriStudioTurn: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var utterance: String
    public var expectations: SiriStudioExpectations

    /// Creates an editable turn and its optional expectations.
    public init(id: UUID = UUID(), utterance: String = "", expectations: SiriStudioExpectations = .init()) {
        self.id = id; self.utterance = utterance; self.expectations = expectations
    }
}

/// The required call group, forbidden call group, and optional reply checks.
public struct SiriStudioExpectations: Codable, Sendable, Equatable {
    /// Controls ordering inside the single required call group.
    public enum Ordering: String, Codable, Sendable, CaseIterable { case ordered, unordered }
    public var calls: [SiriStudioCall]
    public var ordering: Ordering
    public var forbidden: [SiriStudioCall]
    public var replyContains: [SiriStudioReplyCheck]

    /// Starts a group with ordered calls by default.
    public init(calls: [SiriStudioCall] = [], ordering: Ordering = .ordered,
                forbidden: [SiriStudioCall] = [], replyContains: [SiriStudioReplyCheck] = []) {
        self.calls = calls; self.ordering = ordering; self.forbidden = forbidden; self.replyContains = replyContains
    }
}

/// An action reference with optional argument and return-value constraints.
public struct SiriStudioCall: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var actionIdentifier: String
    public var arguments: [SiriStudioArgument]
    public var result: SiriStudioMatcher?

    /// Adds an expectation for a catalog action.
    public init(id: UUID = UUID(), actionIdentifier: String, arguments: [SiriStudioArgument] = [],
                result: SiriStudioMatcher? = nil) {
        self.id = id; self.actionIdentifier = actionIdentifier; self.arguments = arguments; self.result = result
    }
}

/// A typed constraint on one catalog parameter.
public struct SiriStudioArgument: Codable, Sendable, Equatable {
    public var parameterIdentifier: String
    public var matcher: SiriStudioMatcher

    /// Pairs a parameter's stable identifier with a matcher.
    public init(parameterIdentifier: String, matcher: SiriStudioMatcher) {
        self.parameterIdentifier = parameterIdentifier; self.matcher = matcher
    }
}

/// Serializable matcher choices. Authors cannot supply executable Swift or predicates.
public enum SiriStudioMatcher: Codable, Sendable, Equatable {
    case equals(String), contains(String), containsRegex(String), isNil, notNil
    case intEquals(Int), doubleEquals(Double), boolEquals(Bool), enumCase(String)
    case entityIdentifier(entityType: String, identifier: String)
}

/// A substring expected in a single Siri reply.
public struct SiriStudioReplyCheck: Codable, Sendable, Equatable {
    public var text: String
    public var caseSensitive: Bool

    /// Sets the text and its case matching rule.
    public init(text: String = "", caseSensitive: Bool = false) {
        self.text = text; self.caseSensitive = caseSensitive
    }
}
