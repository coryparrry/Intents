import Foundation

/// A bounded subset of Swift conditional compilation, bound to the exact resolved
/// selected-target settings. Unobserved compiler dimensions remain unknown.
public struct AutomationSourceCompilationConditions: Codable, Equatable, Sendable {
    public let owner: String
    public let configuration: String
    public let settingsSHA256: String
    public let activeConditions: [String]?
    public var platformPredicates: AutomationSourcePlatformPredicates? = nil

    static func read(_ data: Data, graph: AutomationSourceGraph, platform: AutomationBuildPlatform) throws -> Self {
        guard data.count <= 1_048_576, graph.configuration == platform.configuration,
              case .array(let rows) = try JSONDecoder().decode(AutomationJSON.self, from: data) else { throw AutomationContractError.invalidIdentity }
        let candidates = rows.compactMap(\.object).filter { $0["target"] == .string(platform.targetName) }
        guard candidates.count == 1, let settings = candidates[0]["buildSettings"]?.object,
              settings["TARGET_NAME"] == .string(platform.targetName), settings["CONFIGURATION"] == .string(platform.configuration),
              case .string(let project) = settings["PROJECT_FILE_PATH"], project.utf16.count <= 4096, !project.contains("\0"),
              AutomationBuildPlatform.sameProject(project, URL(fileURLWithPath: platform.projectPath)),
              settings["PLATFORM_NAME"] == .string(platform.platformName), settings["SDKROOT"] == .string(platform.sdkRoot) else { throw AutomationContractError.conflictingOperation }
        func words(_ key: String) -> [String]? {
            guard let value = settings[key] else { return nil }
            guard case .string(let text) = value, text.utf8.count <= 16384 else { return nil }
            return text.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        var active: [String]?
        if let conditions = words("SWIFT_ACTIVE_COMPILATION_CONDITIONS"), let flags = words("OTHER_SWIFT_FLAGS"), conditions.allSatisfy(Self.identifier) {
            var names = conditions, position = 0, complete = true
            while position < flags.count {
                let flag = flags[position]; position += 1
                if flag == "-D", position < flags.count, Self.identifier(flags[position]) {
                    names.append(flags[position]); position += 1
                } else if flag.hasPrefix("-D"), Self.identifier(String(flag.dropFirst(2))) {
                    names.append(String(flag.dropFirst(2)))
                } else { complete = false; break }
            }
            if complete, names.count <= 256 { active = Array(Set(names)).sorted() }
        }
        var facts = Self(owner: graph.projectRelativePath + "#" + graph.targetID, configuration: graph.configuration,
                     settingsSHA256: AutomationArtifactRegistry.digest(data), activeConditions: active)
        facts.platformPredicates = AutomationSourcePlatformPredicates.read(settings, platform: platform)
        return facts
    }

    func validateDerived(settings: Data, graph: AutomationSourceGraph) throws {
        try validate(graph: graph)
        guard settingsSHA256 == AutomationArtifactRegistry.digest(settings) else { throw AutomationContractError.conflictingOperation }
        if platformPredicates != nil {
            guard let platform = graph.platformContext?.selected,
                  try Self.read(settings, graph: graph, platform: platform) == self else { throw AutomationContractError.conflictingOperation }
        }
    }

    func validate(graph: AutomationSourceGraph) throws {
        try platformPredicates?.validate()
        guard owner == graph.projectRelativePath + "#" + graph.targetID, configuration == graph.configuration,
              settingsSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              activeConditions.map({ $0.count <= 256 && $0 == Array(Set($0)).sorted() && $0.allSatisfy(Self.identifier) }) ?? true else { throw AutomationContractError.conflictingOperation }
    }

    static func identifier(_ value: String) -> Bool {
        value.utf8.count <= 256 && value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil && value != "true" && value != "false"
    }

    static func resolve(_ declaration: AutomationSourceDeclaration, facts: Self?) -> Bool? {
        guard let expressions = declaration.compilationConditions, expressions.count <= 64 else { return nil }
        var outcome: Bool? = true
        for expression in expressions {
            let owned = facts?.owner == declaration.owner
            let value = evaluate(expression, active: owned ? facts?.activeConditions : nil, platform: owned ? facts?.platformPredicates : nil)
            outcome = and(outcome, value)
        }
        return outcome
    }

    static func evaluate(_ expression: String, active: [String]?, platform: AutomationSourcePlatformPredicates? = nil) -> Bool? {
        guard expression.utf8.count <= 4096 else { return nil }
        var parser = Parser(expression, active: active, platform: platform)
        let value = parser.disjunction(depth: 0)
        return parser.valid && parser.position == parser.tokens.count ? value : nil
    }
    private static func and(_ a: Bool?, _ b: Bool?) -> Bool? { a == false || b == false ? false : a == true && b == true ? true : nil }
    private static func or(_ a: Bool?, _ b: Bool?) -> Bool? { a == true || b == true ? true : a == false && b == false ? false : nil }

    private struct Parser {
        var tokens: [String] = [], position = 0, valid = true
        let active: Set<String>?
        let platform: AutomationSourcePlatformPredicates?
        init(_ text: String, active: [String]?, platform: AutomationSourcePlatformPredicates?) {
            self.active = active.map(Set.init); self.platform = platform
            let bytes = Array(text.utf8); var cursor = 0
            while cursor < bytes.count, tokens.count <= 512 {
                let start = cursor, byte = bytes[cursor]; cursor += 1
                if [9,10,13,32].contains(byte) { continue }
                if (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 {
                    while cursor < bytes.count, (65...90).contains(bytes[cursor]) || (97...122).contains(bytes[cursor]) || (48...57).contains(bytes[cursor]) || bytes[cursor] == 95 { cursor += 1 }
                } else if (byte == 38 || byte == 124), cursor < bytes.count, bytes[cursor] == byte { cursor += 1 }
                tokens.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
            }
            if cursor != bytes.count || tokens.count > 512 { valid = false }
        }
        mutating func take(_ token: String) -> Bool {
            guard position < tokens.count, tokens[position] == token else { return false }
            position += 1; return true
        }
        mutating func disjunction(depth: Int) -> Bool? {
            var value = conjunction(depth: depth)
            while take("||") { value = SelfValue.or(value, conjunction(depth: depth)) }
            return value
        }
        mutating func conjunction(depth: Int) -> Bool? {
            var value = atom(depth: depth)
            while take("&&") { value = SelfValue.and(value, atom(depth: depth)) }
            return value
        }
        mutating func atom(depth: Int) -> Bool? {
            guard depth < 64, position < tokens.count else { valid = false; return nil }
            if take("!") { return atom(depth: depth + 1).map { !$0 } }
            if take("(") {
                let value = disjunction(depth: depth + 1)
                if !take(")") { valid = false }
                return value
            }
            let token = tokens[position]; position += 1
            if token == "true" { return true }; if token == "false" { return false }
            guard SelfValue.identifier(token) else { valid = false; return nil }
            if take("(") {
                // Consume unknown predicates without treating them as custom flags.
                let start = position
                var nesting = 1
                while position < tokens.count, nesting > 0 {
                    if tokens[position] == "(" { nesting += 1 }
                    if tokens[position] == ")" { nesting -= 1 }
                    position += 1
                }
                if nesting != 0 { valid = false; return nil }
                guard position == start + 2 else { return nil }
                return platform?.resolve(predicate: token, argument: tokens[start])
            }
            return active.map { $0.contains(token) }
        }
        private typealias SelfValue = AutomationSourceCompilationConditions
    }
}
