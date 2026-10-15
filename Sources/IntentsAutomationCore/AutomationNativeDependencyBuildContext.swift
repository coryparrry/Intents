import Foundation

/// Rebinds generated native-tool paths inside the private copy and records transformed inputs.
struct AutomationNativeDependencyBuildContext {
    let arguments: [String]
    var verifiedFiles: [String: String] = [:]

    func verify() throws {
        for (path, digest) in verifiedFiles {
            guard AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(URL(fileURLWithPath: path), maximumBytes: 128 * 1024 * 1024)) == digest else { throw AutomationContractError.conflictingOperation }
        }
    }

    static func prepare(project: AutomationRebasedProject, manifest: AutomationSourceManifest, sdk: String, configuration: String = "Debug") throws -> Self {
        guard manifest.includesDependencies == true else { return .init(arguments: []) }
        let source = project.session.appendingPathComponent("source")
        let config = project.project.deletingLastPathComponent().appendingPathComponent("Flutter/Generated.xcconfig")
        let relative = String(config.path.dropFirst(source.path.count + 1))
        guard let capturedConfig = manifest.files.first(where: { $0.relativePath == relative && $0.symbolicLink == nil }) else { return .init(arguments: []) }
        let bytes = try AutomationReadOnlyFile.read(root: source, relativePath: relative, maximumBytes: 1_048_576)
        guard bytes.count == capturedConfig.bytes, AutomationArtifactRegistry.digest(bytes) == capturedConfig.sha256 else {
            throw AutomationContractError.conflictingOperation
        }
        guard let text = String(data: bytes, encoding: .utf8) else { throw AutomationContractError.invalidIdentity }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        guard let app = values["FLUTTER_APPLICATION_PATH"], let package = values["PACKAGE_CONFIG"] else {
            throw AutomationContractError.missingEvidence("Flutter generated configuration is incomplete")
        }
        // Extension targets may not include Generated.xcconfig themselves.
        // Forward its frozen packaging values to every target in this private build.
        var arguments = ["FLUTTER_APPLICATION_PATH=" + (try rebase(app, manifest: manifest, source: source)).path]
        arguments += try flutterPackagingArguments(values)
        if let path = values["FLUTTER_FRAMEWORK_SWIFT_PACKAGE_PATH"] {
            arguments.append("FLUTTER_FRAMEWORK_SWIFT_PACKAGE_PATH=" + (try rebase(path, manifest: manifest, source: source)).path)
        }
        let originalPackage = try AutomationPath.canonical(URL(fileURLWithPath: package, relativeTo: URL(fileURLWithPath: app, isDirectory: true)))
        let frozenPackage = try rebase(originalPackage.path, manifest: manifest, source: source)
        let packageRelative = String(frozenPackage.path.dropFirst(source.path.count + 1))
        let packageData = try AutomationReadOnlyFile.read(root: source, relativePath: packageRelative, maximumBytes: 16 * 1024 * 1024)
        guard let capturedPackage = manifest.files.first(where: { $0.relativePath == packageRelative && $0.symbolicLink == nil }),
              capturedPackage.bytes == packageData.count, capturedPackage.sha256 == AutomationArtifactRegistry.digest(packageData) else {
            throw AutomationContractError.conflictingOperation
        }
        guard var object = try JSONSerialization.jsonObject(with: packageData) as? [String: Any],
              var packages = object["packages"] as? [[String: Any]], packages.count <= 10_000 else { throw AutomationContractError.invalidIdentity }
        for index in packages.indices {
            try validatePackageURI(packages[index]["packageUri"])
            guard let uri = packages[index]["rootUri"] as? String,
                  let root = URL(string: uri, relativeTo: originalPackage)?.absoluteURL, root.isFileURL else { throw AutomationContractError.invalidIdentity }
            packages[index]["rootUri"] = try rebase(AutomationPath.canonical(root).path, manifest: manifest, source: source).absoluteString
        }
        object["packages"] = packages
        let context = project.session.appendingPathComponent("native-build-context")
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        let isolatedPackage = context.appendingPathComponent("package_config.json")
        let archivedPackage = context.appendingPathComponent("captured-package_config.json")
        try packageData.write(to: archivedPackage, options: .withoutOverwriting)
        let derivedData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try derivedData.write(to: isolatedPackage, options: .withoutOverwriting)
        // Flutter assemble reads this conventional location, ignoring the Xcode PACKAGE_CONFIG setting.
        try derivedData.write(to: frozenPackage, options: .atomic)
        let transformation: [String: String] = ["relativePath": packageRelative, "capturedSHA256": capturedPackage.sha256,
                                               "derivedSHA256": AutomationArtifactRegistry.digest(derivedData)]
        try JSONSerialization.data(withJSONObject: transformation, options: [.sortedKeys]).write(to: context.appendingPathComponent("package-config-transformation.json"), options: .withoutOverwriting)
        arguments.append("PACKAGE_CONFIG=" + isolatedPackage.path)
        var verifiedFiles = [config.path: capturedConfig.sha256, isolatedPackage.path: AutomationArtifactRegistry.digest(derivedData), frozenPackage.path: AutomationArtifactRegistry.digest(derivedData), archivedPackage.path: capturedPackage.sha256]
        if sdk == "iphonesimulator" {
            let mode = (values["FLUTTER_BUILD_MODE"] ?? configuration).lowercased()
            guard mode.contains("debug"), !mode.contains("release"), !mode.contains("profile") else {
                throw AutomationContractError.missingEvidence("Flutter simulator preparation requires a Debug configuration. Choose Debug and approve the build again.")
            }
            guard let sdkPath = values["FLUTTER_ROOT"] else { throw AutomationContractError.missingEvidence("Flutter SDK path is missing from generated configuration") }
            let sdkRoot = try AutomationPath.canonical(URL(fileURLWithPath: sdkPath))
            let slice = sdkRoot.appendingPathComponent("bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator")
            let module = slice.appendingPathComponent("Flutter.framework/Modules/module.modulemap")
            let moduleData = try AutomationReadOnlyFile.read(module, maximumBytes: 1_048_576)
            guard String(decoding: moduleData, as: UTF8.self).contains("framework module Flutter") else { throw AutomationContractError.missingEvidence("Flutter SDK simulator framework module is unavailable") }
            let binary = slice.appendingPathComponent("Flutter.framework/Flutter")
            verifiedFiles[module.path] = AutomationArtifactRegistry.digest(moduleData)
            verifiedFiles[binary.path] = AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(binary, maximumBytes: 128 * 1024 * 1024))
            let escapedSlice = slice.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            arguments.append("FRAMEWORK_SEARCH_PATHS=$(inherited) \"" + escapedSlice + "\"")
        }
        let contextData = try JSONSerialization.data(withJSONObject: verifiedFiles, options: [.sortedKeys])
        try contextData.write(to: context.appendingPathComponent("verified-inputs.json"), options: .withoutOverwriting)
        return .init(arguments: arguments, verifiedFiles: verifiedFiles)
    }

    static func flutterPackagingArguments(_ values: [String: String]) throws -> [String] {
        guard let name = values["FLUTTER_BUILD_NAME"], name.utf8.count <= 64,
              name.range(of: #"\A[0-9]+(\.[0-9]+){0,2}\z"#, options: .regularExpression) != nil,
              let number = values["FLUTTER_BUILD_NUMBER"], number.utf8.count <= 20,
              number.range(of: #"\A[1-9][0-9]*\z"#, options: .regularExpression) != nil else {
            throw AutomationContractError.missingEvidence("Frozen Flutter generated configuration requires a numeric build name and positive integer build number. Regenerate its app configuration before preparing again.")
        }
        return ["FLUTTER_BUILD_NAME=" + name, "FLUTTER_BUILD_NUMBER=" + number]
    }

    static func validatePackageURI(_ value: Any?) throws {
        guard let value else { return }
        guard let uri = value as? String, uri.utf8.count <= 4096,
              let decoded = uri.removingPercentEncoding, !decoded.hasPrefix("/"), !decoded.contains("\\"), !decoded.contains("\0"),
              !decoded.split(separator: "/").contains(".."), let components = URLComponents(string: decoded),
              components.scheme == nil, components.host == nil, components.query == nil, components.fragment == nil else {
            throw AutomationContractError.missingEvidence("Flutter packageUri must be a relative directory within its approved package root")
        }
    }

    static func rebase(_ path: String, manifest: AutomationSourceManifest, source: URL) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(".."),
              manifest.approvedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
              path == manifest.layoutRoot || path.hasPrefix(manifest.layoutRoot + "/") else {
            throw AutomationContractError.missingEvidence("Native dependency configuration refers outside approved source folders: \(path)")
        }
        return source.appendingPathComponent(String(path.dropFirst(manifest.layoutRoot.count + 1)))
    }
}
