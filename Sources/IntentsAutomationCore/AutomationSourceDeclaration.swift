import Foundation

/// A lexical declaration candidate, not a compiled or registered interface.
public struct AutomationSourceDeclaration: Codable, Equatable, Sendable {
    public var name: String
    public var protocols: [String]
    public var relativePath: String
    public var owner: String
    public var line: Int
    public var qualifiedName: String? = nil
    public var column: Int? = nil
    public var kind: String? = nil
    /// Every enclosing branch predicate must resolve true for a syntax match.
    /// Nil is legacy evidence without conditional-compilation tracking.
    public var compilationConditions: [String]? = nil
}

enum AutomationSourceDeclarationReader {
    private struct Token { let text: String; let line: Int }
    private static let interfaces: Set<String> = ["AppIntent", "AppEntity", "AppEnum", "EntityQuery", "EntityStringQuery", "EntityPropertyQuery", "AppShortcutsProvider", "DynamicOptionsProvider"]

    static func read(_ data: Data, path: String, owner: String) throws -> [AutomationSourceDeclaration] {
        guard String(data: data, encoding: .utf8) != nil else { throw AutomationContractError.invalidIdentity }
        // The lexical fallback cannot assign nested conditional branches. Keep
        // the file in the graph, but leave all declaration matches unresolved.
        let tokens = try lex(Array(data))
        for index in tokens.indices where tokens[index].text == "#" && index + 1 < tokens.count {
            if ["if", "elseif", "else", "endif"].contains(tokens[index + 1].text) { return [] }
        }
        var result: [AutomationSourceDeclaration] = []
        for index in tokens.indices where ["struct", "class", "enum", "actor"].contains(tokens[index].text) {
            guard index + 1 < tokens.count, identifier(tokens[index + 1].text) else { continue }
            var end = index + 2, genericDepth = 0, colon: Int?
            while end < tokens.count, end - index <= 256 {
                let text = tokens[end].text
                if text == "{" || text == ";" || text == "where" { break }
                if text == "<" { genericDepth += 1 }
                if text == ">" { genericDepth -= 1 }
                if text == ":", genericDepth == 0 { colon = end; break }
                end += 1
            }
            guard let colon else { continue }
            var inherited: [String] = [], name = "", cursor = colon + 1
            while cursor < tokens.count, cursor - index <= 256 {
                let text = tokens[cursor].text
                if ["{", "where", ";"].contains(text) { break }
                if text == "," { if !name.isEmpty { inherited.append(name) }; name = "" }
                else if identifier(text) || text == "." { name += text }
                else { name = ""; break } // Generic/composed inheritance requires a real syntax/index reader.
                cursor += 1
            }
            if !name.isEmpty { inherited.append(name) }
            let supported = inherited.filter { interfaces.contains($0) || ($0.hasPrefix("AppIntents.") && interfaces.contains(String($0.dropFirst(11)))) }
            if !supported.isEmpty {
                result.append(.init(name: tokens[index + 1].text, protocols: supported.sorted(), relativePath: path, owner: owner, line: tokens[index + 1].line))
            }
        }
        return result
    }
    private static func identifier(_ text: String) -> Bool {
        guard let first = text.utf8.first, letter(first) || first == 95 else { return false }
        return text.utf8.allSatisfy { letter($0) || (48...57).contains($0) || $0 == 95 }
    }
    private static func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }

    /// Comments and all quoted bodies are skipped, including raw and multiline
    /// strings. Interpolation is deliberately not parsed into declaration candidates.
    private static func lex(_ bytes: [UInt8]) throws -> [Token] {
        var cursor = 0, line = 1, result: [Token] = []
        func at(_ index: Int) -> UInt8? { index < bytes.count ? bytes[index] : nil }
        func advance(_ count: Int = 1) {
            for _ in 0..<count { if bytes[cursor] == 10 { line += 1 }; cursor += 1 }
        }
        func comment() -> Bool {
            if at(cursor) == 47, at(cursor + 1) == 47 {
                while cursor < bytes.count, bytes[cursor] != 10 { advance() }; return true
            }
            if at(cursor) == 47, at(cursor + 1) == 42 {
                advance(2); var depth = 1
                while cursor < bytes.count, depth > 0 {
                    if at(cursor) == 47, at(cursor + 1) == 42 { depth += 1; advance(2) }
                    else if at(cursor) == 42, at(cursor + 1) == 47 { depth -= 1; advance(2) }
                    else { advance() }
                }
                return true
            }
            return false
        }
        func literal(depth: Int) throws -> Bool {
            guard depth <= 64 else { throw AutomationContractError.invalidIdentity }
            var delimiter = cursor, hashes = 0
            while at(delimiter) == 35 {
                hashes += 1; delimiter += 1
                guard hashes <= 64 else { throw AutomationContractError.invalidIdentity }
            }
            if at(delimiter) == 47 {
                // Bare-slash division is ambiguous without SwiftSyntax. Only skip
                // a same-line closed pair; raw regex delimiters are unambiguous.
                if hashes == 0 {
                    var end = delimiter + 1, escaped = false, closed = false
                    while end < bytes.count, bytes[end] != 10 {
                        if !escaped, bytes[end] == 47 { closed = true; break }
                        escaped = !escaped && bytes[end] == 92; end += 1
                    }
                    if !closed { return false }
                }
                advance(hashes + 1)
                while cursor < bytes.count {
                    if at(cursor) == 47, (0..<hashes).allSatisfy({ at(cursor + 1 + $0) == 35 }) { advance(1 + hashes); break }
                    if at(cursor) == 92 { advance(min(2, bytes.count - cursor)) } else { advance() }
                }
                return true
            }
            guard at(delimiter) == 34 else { return false }
            let width = at(delimiter + 1) == 34 && at(delimiter + 2) == 34 ? 3 : 1
            advance(hashes + width)
            while cursor < bytes.count {
                let close = (0..<width).allSatisfy { at(cursor + $0) == 34 } && (0..<hashes).allSatisfy { at(cursor + width + $0) == 35 }
                if close { advance(width + hashes); break }
                let escape = at(cursor) == 92 && (0..<hashes).allSatisfy { at(cursor + 1 + $0) == 35 }
                if escape, at(cursor + 1 + hashes) == 40 {
                    advance(hashes + 2); try interpolation(depth: depth + 1)
                } else if escape { advance(min(bytes.count - cursor, 2 + hashes)) }
                else { advance() }
            }
            return true
        }
        func interpolation(depth: Int) throws {
            guard depth <= 64 else { throw AutomationContractError.invalidIdentity }
            var parentheses = 1
            while cursor < bytes.count, parentheses > 0 {
                if comment() { continue }
                if try literal(depth: depth) { continue }
                if bytes[cursor] == 40 { parentheses += 1 }
                if bytes[cursor] == 41 { parentheses -= 1 }
                advance()
            }
        }
        while cursor < bytes.count {
            if cursor % 1024 == 0 { try Task.checkCancellation() }
            guard result.count < 250_000 else { throw AutomationContractError.invalidIdentity }
            let byte = bytes[cursor]
            if comment() { continue }
            if try literal(depth: 0) { continue }
            if byte == 96 {
                advance(); let start = cursor, startLine = line
                while cursor < bytes.count, bytes[cursor] != 96 { advance() }
                if cursor < bytes.count { result.append(.init(text: String(decoding: bytes[start..<cursor], as: UTF8.self), line: startLine)); advance() }
                continue
            }
            if letter(byte) || byte == 95 {
                let start = cursor, startLine = line
                repeat { advance() } while cursor < bytes.count && (letter(bytes[cursor]) || (48...57).contains(bytes[cursor]) || bytes[cursor] == 95)
                result.append(.init(text: String(decoding: bytes[start..<cursor], as: UTF8.self), line: startLine))
            } else if ![9, 10, 13, 32].contains(byte) { result.append(.init(text: String(decoding: [byte], as: UTF8.self), line: line)); advance() }
            else { advance() }
        }
        return result
    }

}

public enum AutomationSourceCatalogReconciliation {
    public static func apply(_ graph: AutomationSourceGraph, to catalog: ApplicationSurfaceCatalog) throws -> ApplicationSurfaceCatalog {
        guard graph.schemaVersion == AutomationSourceGraph.currentSchemaVersion, graph.sourceManifestDigest == catalog.app.sourceManifestDigest, graph.coverage == "partial" else { throw AutomationContractError.conflictingOperation }
        var result = catalog
        result.sourceGraphDigest = try graph.digest
        for index in result.systemActions.indices {
            let type = result.systemActions[index].typeName
            let candidates = graph.declarations.filter { declaration in
                guard declaration.owner == graph.projectRelativePath + "#" + graph.targetID else { return false }
                let moduleMatch = catalog.app.owningModule.map { type == $0 + "." + declaration.name } ?? false
                return (type == declaration.name || moduleMatch) && declaration.protocols.contains(where: { $0 == "AppIntent" || $0 == "AppIntents.AppIntent" })
            }
            result.systemActions[index].sourceCandidates = candidates
            result.systemActions[index].sourceReconciliation = candidates.isEmpty ? "unresolved" : candidates.count == 1 ? "lexicalCandidate" : "ambiguous"
        }
        result.gaps = Array(Set(result.gaps + graph.gaps + ["Lexical source matches do not establish active compilation, module identity, runtime registration or execution."])).sorted()
        result.systemDiscoveryComplete = false
        return result
    }
}
