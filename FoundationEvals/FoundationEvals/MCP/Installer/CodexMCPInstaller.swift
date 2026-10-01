import CryptoKit
import Foundation

struct CodexMCPConfiguration: Equatable, Sendable {
    static let defaultPort = 17_873

    let port: Int
    init(port: Int = Self.defaultPort) throws {
        guard (1_024...65_535).contains(port) else {
            throw CodexMCPInstallerError.invalidPort
        }
        self.port = port
    }

    var endpoint: URL {
        URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    var tomlBlock: String {
        """
        \(CodexMCPInstaller.beginMarker)
        [mcp_servers.foundation-evals]
        url = "\(endpoint.absoluteString)"
        \(CodexMCPInstaller.endMarker)
        """
    }

    var manualSnippet: String {
        tomlBlock
    }
}

enum CodexMCPInstallerError: Error, Equatable, LocalizedError {
    case invalidPort
    case invalidDirectory
    case invalidUTF8
    case configurationTooLarge
    case malformedConfiguration
    case unsupportedConfiguration
    case conflictingConfiguration
    case malformedManagedBlock
    case unsafeFile
    case concurrentModification
    case verificationFailed
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "The MCP server port is invalid."
        case .invalidDirectory:
            "The ~/.codex configuration path is not a directory."
        case .invalidUTF8:
            "Codex config.toml is not valid UTF-8. No changes were made."
        case .configurationTooLarge:
            "Codex config.toml is too large to update safely. No changes were made."
        case .malformedConfiguration:
            "Codex config.toml appears malformed. No changes were made."
        case .unsupportedConfiguration:
            "Codex config.toml uses a TOML layout this installer cannot update safely. Use the manual snippet instead."
        case .conflictingConfiguration:
            "Codex already has an unmanaged foundation-evals MCP entry. Remove or rename it, then try again."
        case .malformedManagedBlock:
            "The Foundation Evals managed block is incomplete or duplicated. No changes were made."
        case .unsafeFile:
            "The selected configuration target is not a regular file. No changes were made."
        case .concurrentModification:
            "Codex config.toml changed during the update. No changes were made; try again."
        case .verificationFailed:
            "The Codex configuration update could not be verified and was rolled back."
        case .rollbackFailed:
            "The Codex configuration could not be restored automatically. Restore it from the restricted backup before retrying."
        }
    }
}

enum CodexMCPInstallChange: Equatable, Sendable {
    case installed
    case updated
    case removed
    case unchanged
}

struct CodexMCPInstallReceipt: Equatable, Sendable {
    let change: CodexMCPInstallChange
    let configURL: URL
    let backupURL: URL?
}

struct CodexMCPInstaller {
    static let beginMarker = "# BEGIN FOUNDATION EVALS MANAGED MCP"
    static let endMarker = "# END FOUNDATION EVALS MANAGED MCP"
    static let maximumConfigBytes = 2 * 1_024 * 1_024

    private let fileManager: FileManager
    private let beforeFingerprintRecheck: (URL) throws -> Void

    init(
        fileManager: FileManager = .default,
        beforeFingerprintRecheck: @escaping (URL) throws -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.beforeFingerprintRecheck = beforeFingerprintRecheck
    }

    func isInstalled(in directory: URL) throws -> Bool {
        guard try prepare(directory, createIfMissing: false) else { return false }
        let snapshot = try readConfig(in: directory)
        guard let text = String(data: snapshot.data, encoding: .utf8) else {
            throw CodexMCPInstallerError.invalidUTF8
        }
        return try Self.managedRange(in: text) != nil
    }

    func installOrUpdate(
        in directory: URL,
        configuration: CodexMCPConfiguration
    ) throws -> CodexMCPInstallReceipt {
        _ = try prepare(directory, createIfMissing: true)
        let before = try readConfig(in: directory)
        guard let text = String(data: before.data, encoding: .utf8) else {
            throw CodexMCPInstallerError.invalidUTF8
        }
        let hadManagedBlock = try Self.managedRange(in: text) != nil
        let updatedText = try Self.installing(configuration: configuration, into: text)
        let updated = Data(updatedText.utf8)

        guard updated != before.data else {
            return CodexMCPInstallReceipt(
                change: .unchanged,
                configURL: before.url,
                backupURL: nil
            )
        }

        let backupURL = try commit(updated, replacing: before)
        return CodexMCPInstallReceipt(
            change: hadManagedBlock ? .updated : .installed,
            configURL: before.url,
            backupURL: backupURL
        )
    }

    func remove(from directory: URL) throws -> CodexMCPInstallReceipt {
        guard try prepare(directory, createIfMissing: false) else {
            return CodexMCPInstallReceipt(
                change: .unchanged,
                configURL: directory.appending(path: "config.toml", directoryHint: .notDirectory),
                backupURL: nil
            )
        }
        let before = try readConfig(in: directory)
        guard let text = String(data: before.data, encoding: .utf8) else {
            throw CodexMCPInstallerError.invalidUTF8
        }
        let updatedText = try Self.removingManagedBlock(from: text)
        let updated = Data(updatedText.utf8)

        guard updated != before.data else {
            return CodexMCPInstallReceipt(
                change: .unchanged,
                configURL: before.url,
                backupURL: nil
            )
        }

        let backupURL = try commit(updated, replacing: before)
        return CodexMCPInstallReceipt(
            change: .removed,
            configURL: before.url,
            backupURL: backupURL
        )
    }

    static func installing(
        configuration: CodexMCPConfiguration,
        into original: String
    ) throws -> String {
        let managed = try managedRange(in: original)
        let unmanaged = managed.map { original.replacingCharacters(in: $0, with: "") } ?? original
        try validateTOML(unmanaged)
        guard !containsConflictingEntry(unmanaged) else {
            throw CodexMCPInstallerError.conflictingConfiguration
        }

        if let managed {
            return original.replacingCharacters(in: managed, with: configuration.tomlBlock + "\n")
        }

        guard !original.isEmpty else {
            return configuration.tomlBlock + "\n"
        }
        let separator = original.hasSuffix("\n\n") ? "" : (original.hasSuffix("\n") ? "\n" : "\n\n")
        return original + separator + configuration.tomlBlock + "\n"
    }

    static func removingManagedBlock(from original: String) throws -> String {
        guard let managed = try managedRange(in: original) else { return original }
        var removal = managed
        if removal.lowerBound > original.startIndex {
            let prior = original.index(before: removal.lowerBound)
            if original[prior] == "\n", prior > original.startIndex {
                let beforePrior = original.index(before: prior)
                if original[beforePrior] == "\n" {
                    removal = prior..<removal.upperBound
                } else if original[beforePrior] == "\r", beforePrior > original.startIndex {
                    let beforeReturn = original.index(before: beforePrior)
                    if original[beforeReturn] == "\n" {
                        removal = beforePrior..<removal.upperBound
                    }
                }
            }
        }
        let updated = original.replacingCharacters(in: removal, with: "")
        try validateTOML(updated)
        return updated
    }

    private struct ConfigSnapshot {
        let url: URL
        let existed: Bool
        let data: Data
        let permissions: Int

        var fingerprint: SHA256.Digest {
            SHA256.hash(data: data)
        }
    }

    private func readConfig(in directory: URL) throws -> ConfigSnapshot {
        guard try prepare(directory, createIfMissing: false) else {
            throw CodexMCPInstallerError.invalidDirectory
        }

        let url = directory.appending(path: "config.toml", directoryHint: .notDirectory)
        let existed = fileManager.fileExists(atPath: url.path)
        guard existed else {
            return ConfigSnapshot(url: url, existed: false, data: Data(), permissions: 0o600)
        }
        try rejectNonRegularOrSymbolicLink(at: url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maximumConfigBytes else {
            throw CodexMCPInstallerError.configurationTooLarge
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        return ConfigSnapshot(
            url: url,
            existed: true,
            data: try Data(contentsOf: url, options: .mappedIfSafe),
            permissions: permissions
        )
    }

    private func prepare(_ directory: URL, createIfMissing: Bool) throws -> Bool {
        guard directory.isFileURL else {
            throw CodexMCPInstallerError.invalidDirectory
        }
        try rejectSymbolicLinkIfPresent(at: directory)

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CodexMCPInstallerError.invalidDirectory
            }
            return true
        }

        guard createIfMissing else { return false }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try rejectSymbolicLinkIfPresent(at: directory)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CodexMCPInstallerError.invalidDirectory
        }
        return true
    }

    private func commit(_ data: Data, replacing before: ConfigSnapshot) throws -> URL? {
        let directory = before.url.deletingLastPathComponent()
        let backupURL = before.existed
            ? directory.appending(path: "config.toml.foundation-evals.backup", directoryHint: .notDirectory)
            : nil
        if let backupURL {
            try rejectSymbolicLinkIfPresent(at: backupURL)
            try replaceAtomically(before.data, at: backupURL, permissions: 0o600)
        }

        let temporaryURL = directory.appending(
            path: ".config.toml.foundation-evals.\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try writeTemporary(data, at: temporaryURL, permissions: 0o600)
        try coordinatedReplace(temporaryURL, replacing: before)

        guard (try? Data(contentsOf: before.url)) == data else {
            do {
                try restore(before)
            } catch {
                throw CodexMCPInstallerError.rollbackFailed
            }
            throw CodexMCPInstallerError.verificationFailed
        }
        return backupURL
    }

    private func restore(_ before: ConfigSnapshot) throws {
        if before.existed {
            try replaceAtomically(before.data, at: before.url, permissions: before.permissions)
        } else if fileManager.fileExists(atPath: before.url.path) {
            try fileManager.removeItem(at: before.url)
        }
    }

    private func replaceAtomically(_ data: Data, at url: URL, permissions: Int) throws {
        try rejectSymbolicLinkIfPresent(at: url)
        let temporaryURL = url.deletingLastPathComponent().appending(
            path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try writeTemporary(data, at: temporaryURL, permissions: permissions)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }

    private func writeTemporary(_ data: Data, at url: URL, permissions: Int) throws {
        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: permissions]
        ) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    }

    private func coordinatedReplace(_ temporaryURL: URL, replacing before: ConfigSnapshot) throws {
        var coordinationError: NSError?
        var operationError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: before.url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try beforeFingerprintRecheck(coordinatedURL)
                let current = try readConfig(in: coordinatedURL.deletingLastPathComponent())
                guard current.existed == before.existed,
                      current.fingerprint == before.fingerprint else {
                    throw CodexMCPInstallerError.concurrentModification
                }
                if before.existed {
                    _ = try fileManager.replaceItemAt(
                        coordinatedURL,
                        withItemAt: temporaryURL,
                        backupItemName: nil,
                        options: []
                    )
                } else {
                    try fileManager.moveItem(at: temporaryURL, to: coordinatedURL)
                }
            } catch {
                operationError = error
            }
        }
        if let operationError { throw operationError }
        if coordinationError != nil { throw CodexMCPInstallerError.concurrentModification }
    }

    private func rejectNonRegularOrSymbolicLink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CodexMCPInstallerError.unsafeFile
        }
    }

    private func rejectSymbolicLinkIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw CodexMCPInstallerError.unsafeFile
        }
    }

    private struct ManagedLine {
        let kind: Kind
        let fullRange: Range<String.Index>

        enum Kind { case begin, end }
    }

    private static func managedRange(in text: String) throws -> Range<String.Index>? {
        var markers: [ManagedLine] = []
        var start = text.startIndex
        while start < text.endIndex {
            let newline = text[start...].firstIndex(of: "\n")
            let contentEnd = newline ?? text.endIndex
            var content = text[start..<contentEnd]
            if content.last == "\r" { content = content.dropLast() }
            let fullEnd = newline.map { text.index(after: $0) } ?? text.endIndex
            if content == beginMarker {
                markers.append(ManagedLine(kind: .begin, fullRange: start..<fullEnd))
            } else if content == endMarker {
                markers.append(ManagedLine(kind: .end, fullRange: start..<fullEnd))
            }
            start = fullEnd
        }

        guard !markers.isEmpty else { return nil }
        guard markers.count == 2,
              case .begin = markers[0].kind,
              case .end = markers[1].kind else {
            throw CodexMCPInstallerError.malformedManagedBlock
        }
        return markers[0].fullRange.lowerBound..<markers[1].fullRange.upperBound
    }

    private struct TOMLStatement {
        let text: String
        let equalsIndex: String.Index?
    }

    private static func validateTOML(_ text: String) throws {
        let statements = try statements(in: text)
        var section: [String] = []
        var sectionOccurrence = 0
        var tables = Set<String>()
        var arrayTableOccurrences: [String: Int] = [:]
        var values = Set<String>()

        for statement in statements {
            let trimmed = statement.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                let isArray = trimmed.hasPrefix("[[")
                let leading = isArray ? 2 : 1
                let trailing = isArray ? 2 : 1
                let body = String(trimmed.dropFirst(leading).dropLast(trailing))
                section = try keyPath(body)
                let identity = section.joined(separator: "\u{1F}")
                if isArray {
                    guard !tables.contains(identity) else {
                        throw CodexMCPInstallerError.malformedConfiguration
                    }
                    arrayTableOccurrences[identity, default: 0] += 1
                    sectionOccurrence = arrayTableOccurrences[identity, default: 0]
                } else if arrayTableOccurrences[identity] != nil || !tables.insert(identity).inserted {
                    throw CodexMCPInstallerError.malformedConfiguration
                } else {
                    sectionOccurrence = 0
                }
                continue
            }

            guard let equals = statement.equalsIndex else {
                throw CodexMCPInstallerError.malformedConfiguration
            }
            let path = section + (try keyPath(String(statement.text[..<equals])))
            let identity = "\(sectionOccurrence)\u{1E}" + path.joined(separator: "\u{1F}")
            guard values.insert(identity).inserted else {
                throw CodexMCPInstallerError.malformedConfiguration
            }
            let value = String(statement.text[statement.text.index(after: equals)...])
            guard isSupportedTOMLValue(value) else {
                throw CodexMCPInstallerError.malformedConfiguration
            }
        }
    }

    private static func containsConflictingEntry(_ text: String) -> Bool {
        guard let statements = try? statements(in: text) else { return true }
        var section: [String] = []
        for statement in statements {
            let trimmed = statement.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                let isArray = trimmed.hasPrefix("[[")
                let leading = isArray ? 2 : 1
                let trailing = isArray ? 2 : 1
                let body = String(trimmed.dropFirst(leading).dropLast(trailing))
                guard let path = try? keyPath(body) else { return true }
                section = path
                if path.starts(with: ["mcp_servers", "foundation-evals"]) { return true }
                continue
            }

            guard let equals = statement.equalsIndex else { return true }
            let lhs = String(statement.text[..<equals])
            guard let path = try? keyPath(lhs) else { return true }
            let effective = section + path
            if effective.starts(with: ["mcp_servers", "foundation-evals"]) { return true }
            if effective == ["mcp_servers"] {
                let value = statement.text[statement.text.index(after: equals)...]
                if inlineTableDefinesFoundationEvals(String(value)) { return true }
            }
        }
        return false
    }

    private static func statements(in text: String) throws -> [TOMLStatement] {
        var result: [TOMLStatement] = []
        var pending = ""
        var squareDepth = 0
        var braceDepth = 0
        var multilineQuote: Character?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = try uncommented(
                String(rawLine),
                squareDepth: &squareDepth,
                braceDepth: &braceDepth,
                multilineQuote: &multilineQuote
            )
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if pending.isEmpty, trimmed.isEmpty { continue }
            pending += (pending.isEmpty ? "" : "\n") + line
            guard multilineQuote == nil, squareDepth == 0, braceDepth == 0 else { continue }

            let statement = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            pending = ""
            guard !statement.isEmpty else { continue }
            if statement.hasPrefix("[") {
                let validTable = (statement.hasPrefix("[[") && statement.hasSuffix("]]"))
                    || (!statement.hasPrefix("[[") && statement.hasSuffix("]"))
                guard validTable else { throw CodexMCPInstallerError.malformedConfiguration }
                result.append(TOMLStatement(text: statement, equalsIndex: nil))
            } else {
                guard let equals = unquotedEquals(in: statement) else {
                    throw CodexMCPInstallerError.malformedConfiguration
                }
                _ = try keyPath(String(statement[..<equals]))
                guard !statement[statement.index(after: equals)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CodexMCPInstallerError.malformedConfiguration
                }
                result.append(TOMLStatement(text: statement, equalsIndex: equals))
            }
        }
        guard pending.isEmpty, multilineQuote == nil, squareDepth == 0, braceDepth == 0 else {
            throw CodexMCPInstallerError.malformedConfiguration
        }
        return result
    }

    private static func uncommented(
        _ line: String,
        squareDepth: inout Int,
        braceDepth: inout Int,
        multilineQuote: inout Character?
    ) throws -> String {
        var quote: Character?
        var escaped = false
        var output = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            let hasTripleQuote = next < line.endIndex
                && line[next] == character
                && line.index(after: next) < line.endIndex
                && line[line.index(after: next)] == character

            if let currentQuote = multilineQuote {
                if currentQuote == "\"", character == "\\" {
                    output.append(character)
                    index = next
                    if index < line.endIndex {
                        output.append(line[index])
                        index = line.index(after: index)
                    }
                    continue
                }
                if character == currentQuote, hasTripleQuote {
                    var end = index
                    var count = 0
                    while end < line.endIndex, line[end] == currentQuote {
                        output.append(currentQuote)
                        count += 1
                        end = line.index(after: end)
                    }
                    guard count <= 5 else {
                        throw CodexMCPInstallerError.malformedConfiguration
                    }
                    index = end
                    multilineQuote = nil
                } else {
                    output.append(character)
                    index = next
                }
                continue
            }
            if let currentQuote = quote {
                output.append(character)
                if currentQuote == "\"", escaped {
                    escaped = false
                } else if currentQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == currentQuote {
                    quote = nil
                }
                index = next
                continue
            }
            if character == "#" { break }
            if character == "\"" || character == "'" {
                output.append(character)
                if hasTripleQuote {
                    output.append(character)
                    output.append(character)
                    index = line.index(index, offsetBy: 3)
                    multilineQuote = character
                } else {
                    quote = character
                    index = next
                }
            } else {
                switch character {
                case "[": squareDepth += 1
                case "]": squareDepth -= 1
                case "{": braceDepth += 1
                case "}": braceDepth -= 1
                default: break
                }
                guard squareDepth >= 0, braceDepth >= 0 else {
                    throw CodexMCPInstallerError.malformedConfiguration
                }
                output.append(character)
                index = next
            }
        }
        guard quote == nil else { throw CodexMCPInstallerError.malformedConfiguration }
        return output
    }

    private static func unquotedEquals(in text: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if let currentQuote = quote {
                if currentQuote == "\"", escaped {
                    escaped = false
                } else if currentQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == currentQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return index
            }
        }
        return nil
    }

    private static func isSupportedTOMLValue(_ source: String) -> Bool {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = value.first, let last = value.last else { return false }
        if first == "\"" || first == "'" {
            let delimiter = String(repeating: first, count: 3)
            if value.hasPrefix(delimiter) {
                return value.count >= 6 && value.hasSuffix(delimiter)
            }
            guard last == first else { return false }
            var quote: Character? = first
            var escaped = false
            for character in value.dropFirst() {
                guard quote != nil else { return false }
                if first == "\"", escaped {
                    escaped = false
                } else if first == "\"", character == "\\" {
                    escaped = true
                } else if character == first {
                    quote = nil
                }
            }
            return quote == nil && !escaped
        }
        if first == "[" { return last == "]" }
        if first == "{" { return last == "}" }
        if value == "true" || value == "false" || value == "inf" || value == "+inf"
            || value == "-inf" || value == "nan" || value == "+nan" || value == "-nan" {
            return true
        }

        let numeric = value.replacingOccurrences(of: "_", with: "")
        if Double(numeric) != nil { return true }
        if numeric.hasPrefix("0x"), UInt64(numeric.dropFirst(2), radix: 16) != nil { return true }
        if numeric.hasPrefix("0o"), UInt64(numeric.dropFirst(2), radix: 8) != nil { return true }
        if numeric.hasPrefix("0b"), UInt64(numeric.dropFirst(2), radix: 2) != nil { return true }

        let dateCharacters = CharacterSet(charactersIn: "0123456789-:.+TZtz ")
        return value.rangeOfCharacter(from: dateCharacters.inverted) == nil
            && (value.contains("-") || value.contains(":"))
    }

    private static func keyPath(_ text: String) throws -> [String] {
        var components: [String] = []
        var component = ""
        var quote: Character?
        var escaped = false

        func appendComponent() throws {
            let value = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw CodexMCPInstallerError.malformedConfiguration }
            if value.first == "\"" || value.first == "'" {
                guard value.count >= 2, value.last == value.first else {
                    throw CodexMCPInstallerError.malformedConfiguration
                }
                if value.first == "\"", value.dropFirst().dropLast().contains("\\") {
                    throw CodexMCPInstallerError.unsupportedConfiguration
                }
                components.append(String(value.dropFirst().dropLast()))
            } else {
                guard value.utf8.allSatisfy({ byte in
                    (48...57).contains(byte) || (65...90).contains(byte)
                        || (97...122).contains(byte) || byte == 45 || byte == 95
                }) else {
                    throw CodexMCPInstallerError.unsupportedConfiguration
                }
                components.append(value)
            }
            component = ""
        }

        for character in text {
            if let currentQuote = quote {
                component.append(character)
                if currentQuote == "\"", escaped {
                    escaped = false
                } else if currentQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == currentQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
                component.append(character)
            } else if character == "." {
                try appendComponent()
            } else {
                component.append(character)
            }
        }
        guard quote == nil else { throw CodexMCPInstallerError.malformedConfiguration }
        try appendComponent()
        return components
    }

    private static func inlineTableDefinesFoundationEvals(_ value: String) -> Bool {
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else {
            return false
        }
        let patterns = ["foundation-evals", "\"foundation-evals\"", "'foundation-evals'"]
        for pattern in patterns {
            var remaining = value.startIndex..<value.endIndex
            while let range = value.range(of: pattern, range: remaining) {
                let suffix = value[range.upperBound...].drop(while: { $0.isWhitespace })
                if suffix.first == "=" { return true }
                remaining = range.upperBound..<value.endIndex
            }
        }
        return false
    }
}
