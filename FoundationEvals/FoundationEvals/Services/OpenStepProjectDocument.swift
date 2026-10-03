import Foundation

/// A small lossless editor for the OpenStep property list shape used by conventional
/// Xcode projects. It parses containers, then inserts only new keys and references;
/// untouched text (including comments and ordering) is retained byte for byte.
struct OpenStepProjectDocument {
    struct Node {
        let range: Range<Int>
        let dictionary: [String: Node]?
        let array: [Node]?
        let scalar: String?
        let entries: [String: Range<Int>]?
    }

    enum Error: LocalizedError {
        case malformed
        case missing(String)
        case duplicate(String)

        var errorDescription: String? {
            switch self {
            case .malformed: "The Xcode project is not a supported OpenStep property list."
            case .missing(let value): "The Xcode project is missing \(value)."
            case .duplicate(let value): "The Xcode project already contains \(value)."
            }
        }
    }

    private(set) var data: Data
    private var bytes: [UInt8] { Array(data) }

    init(_ data: Data) throws {
        self.data = data
        _ = try root()
        _ = try PropertyListSerialization.propertyList(from: data, format: nil)
    }

    func root() throws -> Node {
        var parser = Parser(bytes: bytes)
        return try parser.parse()
    }

    func object(_ id: String) throws -> Node {
        guard let node = try root().dictionary?["objects"]?.dictionary?[id] else {
            throw Error.missing("object \(id)")
        }
        return node
    }

    func containsObject(_ id: String) throws -> Bool {
        try root().dictionary?["objects"]?.dictionary?[id] != nil
    }

    mutating func addObject(id: String, value: String) throws {
        guard !((try root().dictionary?["objects"]?.dictionary?[id]) != nil) else {
            throw Error.duplicate("object \(id)")
        }
        guard let objects = try root().dictionary?["objects"] else { throw Error.missing("objects") }
        insert("\n\t\t\(id) /* Intent Lab */ = \(value);", at: objects.range.upperBound - 1)
        try validate()
    }

    mutating func addKey(_ key: String, value: String, to node: Node) throws {
        guard node.dictionary?[key] == nil else { throw Error.duplicate("key \(key)") }
        insert("\n\t\t\t\(key) = \(value);", at: node.range.upperBound - 1)
        try validate()
    }

    mutating func setKey(_ key: String, value: String, in node: Node) throws {
        if let range = node.entries?[key] {
            data.replaceSubrange(range, with: Data("\(key) = \(value);".utf8))
            try validate()
        } else {
            try addKey(key, value: value, to: node)
        }
    }

    mutating func append(_ value: String, to node: Node) throws {
        guard let array = node.array else { throw Error.malformed }
        if array.contains(where: { $0.scalar == value }) { return }
        insert("\n\t\t\t\t\(value),", at: node.range.upperBound - 1)
        try validate()
    }

    mutating func append(_ value: String, toObject id: String, key: String) throws {
        let object = try object(id)
        if let list = object.dictionary?[key] {
            try append(value, to: list)
        } else {
            try addKey(key, value: "(\(value),)", to: object)
        }
    }

    mutating func append(_ value: String, toRootKey key: String) throws {
        guard let node = try root().dictionary?[key] else { throw Error.missing(key) }
        try append(value, to: node)
    }

    func scalar(object id: String, key: String) throws -> String? {
        try object(id).dictionary?[key]?.scalar
    }

    private mutating func insert(_ text: String, at offset: Int) {
        data.insert(contentsOf: text.utf8, at: offset)
    }

    private func validate() throws {
        _ = try root()
        _ = try PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        mutating func parse() throws -> Node {
            let value = try node()
            skipTrivia()
            guard position == bytes.count else { throw Error.malformed }
            return value
        }

        private mutating func node() throws -> Node {
            skipTrivia()
            let start = position
            guard position < bytes.count else { throw Error.malformed }
            if bytes[position] == 123 { // {
                position += 1
                var values: [String: Node] = [:]
                var ranges: [String: Range<Int>] = [:]
                while true {
                    skipTrivia()
                    guard position < bytes.count else { throw Error.malformed }
                    if bytes[position] == 125 { position += 1; break }
                    let keyStart = position
                    let key = try token()
                    skipTrivia()
                    try consume(61) // =
                    let value = try node()
                    skipTrivia()
                    try consume(59) // ;
                    guard values[key] == nil else { throw Error.duplicate("key \(key)") }
                    values[key] = value
                    ranges[key] = keyStart..<position
                }
                return Node(range: start..<position, dictionary: values, array: nil,
                            scalar: nil, entries: ranges)
            }
            if bytes[position] == 40 { // (
                position += 1
                var values: [Node] = []
                while true {
                    skipTrivia()
                    guard position < bytes.count else { throw Error.malformed }
                    if bytes[position] == 41 { position += 1; break }
                    values.append(try node())
                    skipTrivia()
                    if position < bytes.count && bytes[position] == 44 { position += 1 }
                    else if position >= bytes.count || bytes[position] != 41 { throw Error.malformed }
                }
                return Node(range: start..<position, dictionary: nil, array: values,
                            scalar: nil, entries: nil)
            }
            let value = try token()
            return Node(range: start..<position, dictionary: nil, array: nil,
                        scalar: value, entries: nil)
        }

        private mutating func token() throws -> String {
            skipTrivia()
            guard position < bytes.count else { throw Error.malformed }
            if bytes[position] == 34 {
                position += 1
                var content: [UInt8] = []
                while position < bytes.count {
                    let byte = bytes[position]
                    position += 1
                    if byte == 34 { return String(decoding: content, as: UTF8.self) }
                    if byte == 92, position < bytes.count {
                        content.append(bytes[position]); position += 1
                    } else { content.append(byte) }
                }
                throw Error.malformed
            }
            let start = position
            while position < bytes.count,
                  ![9, 10, 13, 32, 40, 41, 44, 59, 61, 123, 125].contains(bytes[position]) {
                position += 1
            }
            guard position > start else { throw Error.malformed }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }

        private mutating func skipTrivia() {
            while position < bytes.count {
                if [9, 10, 13, 32].contains(bytes[position]) { position += 1; continue }
                if position + 1 < bytes.count, bytes[position] == 47, bytes[position + 1] == 47 {
                    position += 2
                    while position < bytes.count && bytes[position] != 10 { position += 1 }
                    continue
                }
                if position + 1 < bytes.count, bytes[position] == 47, bytes[position + 1] == 42 {
                    position += 2
                    while position + 1 < bytes.count && !(bytes[position] == 42 && bytes[position + 1] == 47) {
                        position += 1
                    }
                    position = min(bytes.count, position + 2)
                    continue
                }
                break
            }
        }

        private mutating func consume(_ byte: UInt8) throws {
            guard position < bytes.count, bytes[position] == byte else { throw Error.malformed }
            position += 1
        }
    }
}
