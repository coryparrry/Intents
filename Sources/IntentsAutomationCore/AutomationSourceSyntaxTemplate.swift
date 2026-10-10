import Foundation

/// Known helper source. Compiler host libraries stay in the selected Xcode;
/// neither the subject nor the associated XCTest host links them.
enum AutomationSourceSyntaxTemplate {
    static let source = #"""
import Foundation
import CryptoKit
import SwiftSyntax
import SwiftParser
import SwiftParserDiagnostics
struct Input: Codable { let relativePath: String; let owner: String; let sha256: String; let source: String }
struct Request: Codable { let graphDigest: String; let inputs: [Input] }
struct ParsedInput: Codable { let relativePath: String; let owner: String; let sha256: String }
struct Declaration: Codable {
    let name: String; let protocols: [String]; let relativePath: String; let owner: String; let line: Int
    let qualifiedName: String; let column: Int; let kind: String; let compilationConditions: [String]
}
struct Response: Codable { let graphDigest: String; let inputs: [ParsedInput]; let declarations: [Declaration]; let parseRecoveryFiles: [String] }
let interfaces: Set<String> = ["AppIntent", "AppEntity", "AppEnum", "EntityQuery", "EntityStringQuery", "EntityPropertyQuery", "AppShortcutsProvider", "DynamicOptionsProvider"]
final class Collector: SyntaxVisitor {
    let input: Input; let converter: SourceLocationConverter
    var names: [String] = []; var declarations: [Declaration] = []
    var conditions: [String] = []
    init(_ input: Input, tree: SourceFileSyntax) {
        self.input = input; converter = SourceLocationConverter(fileName: input.relativePath, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }
    func enter(_ name: String, kind: String, inheritance: InheritanceClauseSyntax?, position: AbsolutePosition) {
        let protocols = inheritance?.inheritedTypes.map { $0.type.tokens(viewMode: .sourceAccurate).map(\.text).joined() }.filter {
            interfaces.contains($0) || ($0.hasPrefix("AppIntents.") && interfaces.contains(String($0.dropFirst(11))))
        }.sorted() ?? []
        names.append(name)
        if !protocols.isEmpty {
            let location = converter.location(for: position)
            declarations.append(.init(name: name.split(separator: ".").last.map(String.init) ?? name,
                protocols: protocols, relativePath: input.relativePath, owner: input.owner, line: location.line,
                qualifiedName: names.joined(separator: "."), column: location.column, kind: kind, compilationConditions: conditions))
        }
    }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, kind: "struct", inheritance: node.inheritanceClause, position: node.name.positionAfterSkippingLeadingTrivia); return .visitChildren }
    override func visitPost(_ node: StructDeclSyntax) { names.removeLast() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, kind: "class", inheritance: node.inheritanceClause, position: node.name.positionAfterSkippingLeadingTrivia); return .visitChildren }
    override func visitPost(_ node: ClassDeclSyntax) { names.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, kind: "enum", inheritance: node.inheritanceClause, position: node.name.positionAfterSkippingLeadingTrivia); return .visitChildren }
    override func visitPost(_ node: EnumDeclSyntax) { names.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, kind: "actor", inheritance: node.inheritanceClause, position: node.name.positionAfterSkippingLeadingTrivia); return .visitChildren }
    override func visitPost(_ node: ActorDeclSyntax) { names.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.extendedType.tokens(viewMode: .sourceAccurate).map(\.text).joined(), kind: "extension", inheritance: node.inheritanceClause, position: node.extendedType.positionAfterSkippingLeadingTrivia); return .visitChildren }
    override func visitPost(_ node: ExtensionDeclSyntax) { names.removeLast() }
    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        let enclosing = conditions
        var previous: [String] = []
        for clause in node.clauses {
            conditions = enclosing + previous.map { "!(" + $0 + ")" }
            if let condition = clause.condition {
                let text = condition.tokens(viewMode: .sourceAccurate).map(\.text).joined(separator: " ")
                conditions.append(text); previous.append(text)
            }
            if let elements = clause.elements { walk(elements._syntaxNode) }
        }
        conditions = enclosing
        return .skipChildren
    }
}
do {
    guard CommandLine.arguments.count == 2 else { throw NSError(domain: "scanner", code: 1) }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard data.count <= 24 * 1024 * 1024 else { throw NSError(domain: "scanner", code: 2) }
    let request = try JSONDecoder().decode(Request.self, from: data)
    guard request.inputs.count <= 1000 else { throw NSError(domain: "scanner", code: 3) }
    var declarations: [Declaration] = [], recovery: [String] = [], parsed: [ParsedInput] = []
    for input in request.inputs {
        guard input.source.utf8.count <= 512 * 1024 else { throw NSError(domain: "scanner", code: 4) }
        let digest = SHA256.hash(data: Data(input.source.utf8)).map { String(format: "%02x", $0) }.joined()
        guard digest == input.sha256 else { throw NSError(domain: "scanner", code: 7) }
        parsed.append(.init(relativePath: input.relativePath, owner: input.owner, sha256: digest))
        let tree = Parser.parse(source: input.source)
        if !ParseDiagnosticsGenerator.diagnostics(for: tree).isEmpty { recovery.append(input.relativePath) }
        let collector = Collector(input, tree: tree); collector.walk(tree)
        declarations += collector.declarations
        guard declarations.count <= 5000 else { throw NSError(domain: "scanner", code: 5) }
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let output = try encoder.encode(Response(graphDigest: request.graphDigest, inputs: parsed, declarations: declarations, parseRecoveryFiles: recovery.sorted()))
    guard output.count <= 1_000_000 else { throw NSError(domain: "scanner", code: 6) }
    FileHandle.standardOutput.write(output)
} catch {
    FileHandle.standardError.write(Data("Source syntax scan unavailable\n".utf8)); exit(1)
}
"""#
}
