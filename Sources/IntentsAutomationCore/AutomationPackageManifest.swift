import Foundation

/// A deliberately narrow SwiftPM declaration reader. It never evaluates Swift.
/// Only immutable literal expressions are accepted; unresolved semantics stay gaps.
enum AutomationPackageManifest {
    struct Product { let name: String; let targets: [String] }
    struct PackageDependency { let name: String?; let path: String?; let location: String? }
    struct TargetDependency { let name: String; let platforms: [String] }
    struct ProductDependency {
        let name: String; let package: String; let platforms: [String]?
        init(name: String, package: String, platforms: [String]? = nil) { self.name = name; self.package = package; self.platforms = platforms }
    }
    struct Target {
        let name: String
        let path: String?
        let sources: [String]?
        let exclude: [String]
        let dependencies: [String]
        let conditionalDependencies: [TargetDependency]
        let destinationConditionsAvailable: Bool
        let products: [ProductDependency]
        let gaps: [String]
        let membershipAvailable: Bool
    }
    struct Manifest {
        let products: [Product]; let targets: [Target]
        let dependencies: [PackageDependency]
        let productsByName: [String: Product]; let targetsByName: [String: Target]
    }
    private enum Value {
        case string(String), array([Value]), name(String), call(String, [Argument])
    }
    private struct Argument { let label: String?; let value: Value }
    private enum Token: Equatable { case name(String), string(String), punctuation(UInt8) }
    private struct Unresolved: Error {}

    static func read(_ data: Data) throws -> Manifest? {
        guard data.count <= 1_048_576, String(data: data, encoding: .utf8) != nil else { return nil }
        do {
            var parser = try Parser(data)
            return try parser.read()
        } catch is Unresolved { return nil }
    }
    private struct Parser {
        let tokens: [Token]
        var position = 0
        var constants: [String: Value] = [:]
        init(_ data: Data) throws { tokens = try Self.lex(Array(data)) }
        mutating func read() throws -> Manifest {
            var package: Value?
            while position < tokens.count {
                try Task.checkCancellation()
                if take(.name("import")) {
                    guard take(.name("PackageDescription")) else { throw Unresolved() }
                } else {
                    guard take(.name("let")), case .name(let name) = next(), take(.punctuation(61)), constants[name] == nil else { throw Unresolved() }
                    let value = try expression(depth: 0)
                    if name == "package" { guard package == nil else { throw Unresolved() }; package = value }
                    else { guard strings(value) != nil else { throw Unresolved() } }
                    constants[name] = value
                }
                _ = take(.punctuation(59))
            }
            guard case .call("Package", let arguments) = package else { throw Unresolved() }
            let fields = try labels(arguments)
            let rootFields: Set<String> = ["name", "platforms", "products", "dependencies", "targets", "swiftLanguageVersions", "swiftLanguageModes", "cLanguageStandard", "cxxLanguageStandard", "defaultLocalization", "providers", "pkgConfig"]
            guard string(fields["name"])?.isEmpty == false, fields.keys.allSatisfy(rootFields.contains),
                  fields.filter({ $0.key != "products" && $0.key != "targets" }).values.allSatisfy(literalMetadata) else { throw Unresolved() }
            guard case .array(let products) = fields["products"], case .array(let targets) = fields["targets"], products.count <= 1000, targets.count <= 1000 else { throw Unresolved() }
            var resultProducts: [Product] = [], resultTargets: [Target] = []
            var packageDependencies: [PackageDependency] = []
            if let value = fields["dependencies"] {
                guard case .array(let dependencies) = value, dependencies.count <= 256 else { throw Unresolved() }
                for dependency in dependencies {
                    guard case .call(".package", let arguments) = dependency else { throw Unresolved() }
                    let fields = try labels(arguments)
                    let name = string(fields["name"])
                    if Set(fields.keys).isSubset(of: ["name", "path"]), let path = string(fields["path"]),
                       fields["name"] == nil || name != nil {
                        packageDependencies.append(.init(name: name, path: path, location: nil))
                    } else {
                        // Retain remote identity for ambiguity checks; never resolve/fetch it here.
                        packageDependencies.append(.init(name: name, path: nil, location: string(fields["url"])))
                    }
                }
            }
            for product in products {
                guard case .call(let kind, let arguments) = product, kind == ".library" || kind == ".executable" else { throw Unresolved() }
                let fields = try labels(arguments)
                let allowed: Set<String> = kind == ".library" ? ["name", "targets", "type"] : ["name", "targets"]
                guard fields.keys.allSatisfy(allowed.contains), fields["type"].map(libraryType) ?? true,
                      let name = string(fields["name"]), !name.isEmpty, name.utf8.count <= 256,
                      let targets = strings(fields["targets"]), !targets.isEmpty, targets.count <= 256,
                      targets.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { throw Unresolved() }
                resultProducts.append(.init(name: name, targets: targets))
            }
            for target in targets {
                guard case .call(let kind, let arguments) = target else { throw Unresolved() }
                let fields = try labels(arguments)
                guard let name = string(fields["name"]), !name.isEmpty, name.utf8.count <= 256 else { throw Unresolved() }
                var gaps: [String] = [], dependencies: [String] = [], conditionalDependencies: [TargetDependency] = [], products: [ProductDependency] = []
                if kind != ".target" && kind != ".executableTarget" { gaps.append("Target kind requires compiler/package evaluation: " + kind) }
                let supported: Set<String> = ["name", "dependencies", "path", "sources", "exclude"]
                for key in fields.keys where !supported.contains(key) { gaps.append("Target field requires compiler/package evaluation: " + key) }
                if let dependencyValue = fields["dependencies"] {
                    guard case .array(let values) = dependencyValue, values.count <= 256 else { throw Unresolved() }
                    for value in values {
                        if let name = string(value) { dependencies.append(name) }
                        else if case .call(".target", let arguments) = value {
                            let dependency = try labels(arguments)
                            if dependency.count == 1, let name = string(dependency["name"]) { dependencies.append(name) }
                            else if Set(dependency.keys) == ["name", "condition"], let name = string(dependency["name"]),
                                    !name.isEmpty, name.utf8.count <= 256, let platforms = platformCondition(dependency["condition"]) {
                                conditionalDependencies.append(.init(name: name, platforms: platforms))
                            } else { gaps.append("Conditional target dependency is unresolved") }
                        } else if case .call(".product", let arguments) = value {
                            let dependency = try labels(arguments)
                            if Set(dependency.keys) == ["name", "package"] || Set(dependency.keys) == ["name", "package", "condition"],
                               let name = string(dependency["name"]), let package = string(dependency["package"]),
                               !name.isEmpty, name.utf8.count <= 256, !package.isEmpty, package.utf8.count <= 256 {
                                if dependency["condition"] == nil { products.append(.init(name: name, package: package)) }
                                else if let platforms = platformCondition(dependency["condition"]) { products.append(.init(name: name, package: package, platforms: platforms)) }
                                else { gaps.append("Conditional or unowned product dependency is unresolved") }
                            } else { gaps.append("Conditional or unowned product dependency is unresolved") }
                        } else { gaps.append("External product or computed target dependency is unresolved") }
                    }
                }
                guard fields["path"] == nil || string(fields["path"]) != nil,
                      fields["sources"] == nil || strings(fields["sources"]) != nil,
                      fields["exclude"] == nil || strings(fields["exclude"]) != nil,
                      dependencies.count + conditionalDependencies.count + products.count <= 256, (strings(fields["sources"])?.count ?? 0) <= 256,
                      (strings(fields["exclude"])?.count ?? 0) <= 256 else { throw Unresolved() }
                resultTargets.append(.init(name: name, path: string(fields["path"]), sources: fields["sources"].flatMap(strings),
                    exclude: strings(fields["exclude"]) ?? [], dependencies: dependencies, conditionalDependencies: conditionalDependencies,
                    destinationConditionsAvailable: kind == ".target" || kind == ".executableTarget", products: products, gaps: gaps.sorted(),
                    membershipAvailable: (kind == ".target" || kind == ".executableTarget") && fields.keys.allSatisfy(supported.contains)))
            }
            guard Set(resultProducts.map(\.name)).count == resultProducts.count, Set(resultTargets.map(\.name)).count == resultTargets.count else { throw Unresolved() }
            return .init(products: resultProducts, targets: resultTargets, dependencies: packageDependencies,
                productsByName: Dictionary(uniqueKeysWithValues: resultProducts.map { ($0.name, $0) }),
                targetsByName: Dictionary(uniqueKeysWithValues: resultTargets.map { ($0.name, $0) }))
        }
        func platformCondition(_ value: Value?) -> [String]? {
            guard case .call(".when", let arguments) = value, arguments.count == 1,
                  arguments[0].label == "platforms", case .array(let values) = arguments[0].value,
                  (1...16).contains(values.count) else { return nil }
            let known = [".macOS": "macos", ".iOS": "ios", ".tvOS": "tvos", ".watchOS": "watchos", ".visionOS": "visionos", ".macCatalyst": "maccatalyst"]
            let platforms = values.compactMap { value -> String? in
                guard case .name(let name) = value else { return nil }; return known[name]
            }
            guard platforms.count == values.count, Set(platforms).count == platforms.count else { return nil }
            return platforms.sorted()
        }
        func literalMetadata(_ value: Value) -> Bool {
            switch value {
            case .string: return true
            case .name(let name): return name.hasPrefix(".") || ["nil", "true", "false"].contains(name)
            case .array(let values): return values.allSatisfy(literalMetadata)
            case .call(let name, let arguments):
                let constructors: Set<String> = [".macOS", ".iOS", ".tvOS", ".watchOS", ".visionOS", ".macCatalyst", ".driverKit", ".custom", ".package", ".brew", ".apt", ".yum", ".nuget"]
                return constructors.contains(name) && arguments.allSatisfy { literalMetadata($0.value) }
            }
        }
        func libraryType(_ value: Value) -> Bool {
            if case .name(let name) = value { return [".static", ".dynamic", "nil"].contains(name) }
            return false
        }
        func string(_ value: Value?) -> String? { if case .string(let text) = value { return text }; return nil }
        func strings(_ value: Value?) -> [String]? {
            guard case .array(let values) = value else { return nil }
            let result = values.compactMap { string($0) }; return result.count == values.count ? result : nil
        }
        func labels(_ arguments: [Argument]) throws -> [String: Value] {
            var fields: [String: Value] = [:]
            for argument in arguments {
                guard let key = argument.label, fields[key] == nil else { throw Unresolved() }
                fields[key] = argument.value
            }
            return fields
        }
        mutating func expression(depth: Int) throws -> Value {
            guard depth <= 64 else { throw Unresolved() }
            if case .string(let text) = peek() { position += 1; return .string(text) }
            if take(.punctuation(91)) {
                var values: [Value] = []
                while !take(.punctuation(93)) {
                    values.append(try expression(depth: depth + 1))
                    if take(.punctuation(93)) { break }
                    guard take(.punctuation(44)) else { throw Unresolved() }
                }
                return .array(values)
            }
            var name = take(.punctuation(46)) ? "." : ""
            guard case .name(let first) = next() else { throw Unresolved() }; name += first
            while take(.punctuation(46)) { guard case .name(let part) = next() else { throw Unresolved() }; name += "." + part }
            if take(.punctuation(40)) {
                var arguments: [Argument] = []
                while !take(.punctuation(41)) {
                    let label: String?
                    if case .name(let key) = peek(), position + 1 < tokens.count, tokens[position + 1] == .punctuation(58) { label = key; position += 2 }
                    else { label = nil }
                    arguments.append(.init(label: label, value: try expression(depth: depth + 1)))
                    if take(.punctuation(41)) { break }
                    guard take(.punctuation(44)) else { throw Unresolved() }
                }
                return .call(name, arguments)
            }
            return constants[name] ?? .name(name)
        }
        func peek() -> Token? { position < tokens.count ? tokens[position] : nil }
        mutating func next() -> Token? { let token = peek(); if token != nil { position += 1 }; return token }
        mutating func take(_ token: Token) -> Bool { if peek() == token { position += 1; return true }; return false }
        private static func lex(_ bytes: [UInt8]) throws -> [Token] {
            var result: [Token] = [], index = 0
            func identifier(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 }
            while index < bytes.count {
                try Task.checkCancellation()
                guard result.count < 100_000 else { throw Unresolved() }
                let byte = bytes[index]
                if [9, 10, 13, 32].contains(byte) { index += 1; continue }
                if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 47 { index += 2; while index < bytes.count, bytes[index] != 10 { index += 1 }; continue }
                if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 42 {
                    index += 2; var depth = 1
                    while depth > 0, index + 1 < bytes.count {
                        if bytes[index] == 47, bytes[index + 1] == 42 { depth += 1; guard depth <= 64 else { throw Unresolved() }; index += 2 }
                        else if bytes[index] == 42, bytes[index + 1] == 47 { depth -= 1; index += 2 }
                        else { index += 1 }
                    }
                    guard depth == 0 else { throw Unresolved() }; continue
                }
                if byte == 34 {
                    index += 1; let start = index
                    while index < bytes.count, bytes[index] != 34 { guard bytes[index] >= 32, bytes[index] != 92 else { throw Unresolved() }; index += 1 }
                    guard index < bytes.count, index - start <= 4096 else { throw Unresolved() }
                    result.append(.string(String(decoding: bytes[start..<index], as: UTF8.self))); index += 1; continue
                }
                if identifier(byte) {
                    let start = index; while index < bytes.count, identifier(bytes[index]) { index += 1 }
                    guard index - start <= 256 else { throw Unresolved() }
                    result.append(.name(String(decoding: bytes[start..<index], as: UTF8.self))); continue
                }
                guard [40, 41, 44, 46, 58, 59, 61, 91, 93].contains(byte) else { throw Unresolved() }
                result.append(.punctuation(byte)); index += 1
            }
            return result
        }
    }
}
