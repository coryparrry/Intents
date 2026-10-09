import Foundation

/// Observed lockfile metadata. It grants no checkout, resolver, cache or execution authority.
public struct AutomationPackagePin: Codable, Equatable, Sendable {
    public var referenceID: String
    public var identity: String
    public var location: String
    public var revision: String
    public var version: String?
    public var branch: String?
    public var originHash: String?
    public var resolutionPath: String
    public var resolutionDigest: String
    public var requirementState: String
}

enum AutomationPackageResolution {
    struct Pin: Decodable {
        struct State: Decodable { let revision: String; let version: String?; let branch: String? }
        let identity: String; let kind: String; let location: String; let state: State
    }
    struct Record: Decodable { let version: Int; let originHash: String?; let pins: [Pin] }
    struct Index { let record: Record; let pinsByIdentity: [String: Pin] }
    static func read(_ data: Data) throws -> Index? {
        guard data.count <= 1_048_576 else { return nil }
        do {
            var keys = UniqueKeys(bytes: Array(data)); try keys.value(depth: 0)
            keys.whitespace(); guard keys.index == data.count else { return nil }
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard [2, 3].contains(record.version), record.pins.count <= 1000,
                  record.version != 3 || record.originHash.map({ hex($0, sizes: [64]) }) == true,
                  record.originHash == nil || hex(record.originHash!, sizes: [64]),
                  Set(record.pins.map(\.identity)).count == record.pins.count else { return nil }
            for pin in record.pins {
                guard pin.kind == "remoteSourceControl", identity(pin.location) == pin.identity,
                      hex(pin.state.revision, sizes: [40, 64]),
                      pin.state.version == nil || validVersion(pin.state.version!),
                      pin.state.branch == nil || safeBranch(pin.state.branch!),
                      pin.state.version == nil || pin.state.branch == nil else { return nil }
            }
            return .init(record: record, pinsByIdentity: Dictionary(uniqueKeysWithValues: record.pins.map { ($0.identity, $0) }))
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }
    static func identity(_ location: String) -> String? {
        guard location.utf8.count <= 2048, !location.contains("%"), !location.contains(where: \.isWhitespace),
              let url = URLComponents(string: location), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, !url.path.hasSuffix("/") else { return nil }
        var name = url.path.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 256, name.range(of: #"^[a-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
        return name
    }
    static func requirementState(_ requirement: [String: Any]?, pin: Pin) -> String {
        guard let requirement, let kind = requirement["kind"] as? String else { return "unresolved" }
        switch kind {
        case "revision":
            guard let value = requirement["revision"] as? String, hex(value, sizes: [40, 64]) else { return "unresolved" }
            return value.lowercased() == pin.state.revision.lowercased() ? "satisfied" : "mismatch"
        case "exactVersion":
            guard let value = requirement["version"] as? String, validVersion(value) else { return "unresolved" }
            return value == pin.state.version ? "satisfied" : "mismatch"
        case "branch":
            guard let value = requirement["branch"] as? String, safeBranch(value) else { return "unresolved" }
            return value == pin.state.branch ? "satisfied" : "mismatch"
        default: return "unresolved"
        }
    }
    private static func hex(_ text: String, sizes: [Int]) -> Bool {
        sizes.contains(text.utf8.count) && text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    private static func validVersion(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 128 else { return false }
        func numeric(_ part: Substring) -> Bool {
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) } && (part.count == 1 || part.first != "0")
        }
        func identifiers(_ part: Substring, prerelease: Bool) -> Bool {
            part.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { identifier in
                !identifier.isEmpty && identifier.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
                    && (!prerelease || !identifier.utf8.allSatisfy({ (48...57).contains($0) }) || numeric(identifier))
            }
        }
        let build = text.split(separator: "+", omittingEmptySubsequences: false)
        guard !build.isEmpty, build.count <= 2, !build[0].isEmpty, build.count == 1 || identifiers(build[1], prerelease: false) else { return false }
        let version = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = version[0].split(separator: ".", omittingEmptySubsequences: false)
        return numbers.count == 3 && numbers.allSatisfy(numeric) && (version.count == 1 || identifiers(version[1], prerelease: true))
    }
    private static func safeBranch(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 256 && !text.hasPrefix("-") && !text.hasSuffix(".") && !text.contains("..")
            && text.range(of: #"^[A-Za-z0-9/._-]+$"#, options: .regularExpression) != nil
            && text.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }
    /// JSONDecoder accepts duplicate keys; reject ambiguous metadata before decoding.
    private struct UniqueKeys {
        let bytes: [UInt8]; var index = 0; var count = 0
        private struct Invalid: Error {}
        mutating func whitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) -> Bool { whitespace(); if index < bytes.count, bytes[index] == byte { index += 1; return true }; return false }
        mutating func string() throws -> String {
            whitespace(); let start = index
            guard take(34) else { throw Invalid() }
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    guard index - start <= 4096 else { throw Invalid() }
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                }
                if byte == 92 { guard index < bytes.count else { throw Invalid() }; index += 1 }
            }
            throw Invalid()
        }
        mutating func value(depth: Int) throws {
            try Task.checkCancellation(); count += 1
            guard depth < 40, count <= 50_000 else { throw Invalid() }
            if take(123) {
                var keys: Set<String> = []
                if take(125) { return }
                while true {
                    guard keys.insert(try string()).inserted, take(58) else { throw Invalid() }
                    try value(depth: depth + 1)
                    if take(125) { return }
                    guard take(44) else { throw Invalid() }
                }
            }
            if take(91) {
                if take(93) { return }
                while true {
                    try value(depth: depth + 1)
                    if take(93) { return }
                    guard take(44) else { throw Invalid() }
                }
            }
            whitespace()
            guard index < bytes.count else { throw Invalid() }
            if bytes[index] == 34 { _ = try string(); return }
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start, index - start <= 128 else { throw Invalid() }
        }
    }
}
