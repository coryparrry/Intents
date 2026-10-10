import Foundation

public struct AutomationGeneratedHost: Codable, Equatable, Sendable {
    public var projectPath: String
    public var scheme: String
    public var targetID: String
    public var bundleID: String
    public var configuration: String
    public var templateDigest: String
    public var includesSiri: Bool? = nil
    public var subjectProductPath: String? = nil
    public var subjectBundleID: String? = nil
}

/// Created only by the verified source rebaser; Xcode may inspect this isolated project before host generation.
struct AutomationRebasedProject: Sendable {
    let session: URL
    let relativePath: String
    let digest: String
    var project: URL { session.appendingPathComponent("source").appendingPathComponent(relativePath) }
}

/// Adds an owned associated UI test target only inside a verified private snapshot.
public enum AutomationHostGenerator {
    static let templateFiles = ["AutomationDateCodec.swift", "AutomationDurationCodec.swift", "AutomationCalendarCodec.swift", "AutomationURLCodec.swift", "AutomationIntentFileCodec.swift", "HostPlan.swift", "HostReceipt.swift", "IntentDefinitionsHost.swift", "SegmentTests.swift", "HostInputAdapterProbePlan.swift", "InputAdapterProbeTests.swift"]
    static let physicalTemplateFiles = templateFiles + ["SiriSubmissionTests.swift"]

    static func verifyGeneratedSources(_ generated: AutomationGeneratedHost, sessionRoot: URL) throws {
        let sources = sessionRoot.appendingPathComponent("generated-host/" + generated.scheme + "/Sources")
        let files = generated.includesSiri == true ? physicalTemplateFiles : templateFiles
        guard Set(try FileManager.default.contentsOfDirectory(atPath: sources.path)) == Set(files) else {
            throw AutomationContractError.conflictingOperation
        }
        var records: [String: String] = [:]
        for file in files {
            records[file] = AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: sources, relativePath: file, maximumBytes: 1_048_576))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard AutomationArtifactRegistry.digest(try encoder.encode(records)) == generated.templateDigest else {
            throw AutomationContractError.conflictingOperation
        }
    }

    public static func associate(sessionRoot: URL, projectRelativePath: String, subjectTargetID: String,
                                 configuration: String, subjectPlatform: String, templates: URL) throws -> AutomationGeneratedHost {
        guard subjectPlatform == "ios" else { throw AutomationContractError.missingEvidence("Associated host arrangement is not qualified for this platform") }
        let rebased = try isolateProject(sessionRoot: sessionRoot, projectRelativePath: projectRelativePath)
        return try associate(rebased: rebased, subjectTargetID: subjectTargetID, configuration: configuration,
                             subjectPlatform: subjectPlatform, templates: templates)
    }
    static func isolateProject(sessionRoot: URL, projectRelativePath: String) throws -> AutomationRebasedProject {
        let session = try AutomationPath.canonical(sessionRoot), source = session.appendingPathComponent("source")
        let manifestData = try AutomationReadOnlyFile.read(root: session, relativePath: "source-manifest.json", maximumBytes: 16 * 1024 * 1024)
        let manifest = try JSONDecoder().decode(AutomationSourceManifest.self, from: manifestData)
        try manifest.validateCaptureLayout()
        guard manifest.files.contains(where: { $0.relativePath == projectRelativePath + "/project.pbxproj" }),
              projectRelativePath.hasSuffix(".xcodeproj"), !projectRelativePath.hasPrefix("/"), !projectRelativePath.contains("\0"),
              !projectRelativePath.split(separator: "/").contains("..") else { throw AutomationContractError.invalidIdentity }
        let project = source.appendingPathComponent(projectRelativePath), projectFile = project.appendingPathComponent("project.pbxproj")
        let data = try AutomationReadOnlyFile.read(root: source, relativePath: projectRelativePath + "/project.pbxproj", maximumBytes: 16 * 1024 * 1024)
        guard let entry = manifest.files.first(where: { $0.relativePath == projectRelativePath + "/project.pbxproj" }),
              entry.sha256 == AutomationArtifactRegistry.digest(data),
              var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]], let rootID = plist["rootObject"] as? String,
              let mainGroupID = objects[rootID]?["mainGroup"] as? String else { throw AutomationContractError.invalidIdentity }
        let rebased = try AutomationProjectRebaser.rebase(objects, originalRoot: URL(fileURLWithPath: manifest.layoutRoot), frozenRoot: source,
            projectDirectory: URL(fileURLWithPath: manifest.layoutRoot).appendingPathComponent(projectRelativePath).deletingLastPathComponent(), mainGroupID: mainGroupID, approvedRoots: manifest.approvedRoots.map { URL(fileURLWithPath: $0) })
        plist["objects"] = rebased
        let frozen = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try frozen.write(to: projectFile, options: .atomic)
        try AutomationSourceSnapshot.verifyOriginal(manifest)
        return .init(session: session, relativePath: projectRelativePath, digest: AutomationArtifactRegistry.digest(frozen))
    }
    static func associate(rebased: AutomationRebasedProject, subjectTargetID: String,
                          configuration: String, subjectPlatform: String, templates: URL) throws -> AutomationGeneratedHost {
        guard subjectPlatform == "ios" else { throw AutomationContractError.missingEvidence("Associated host arrangement is not qualified for this platform") }
        return try associate(rebased: rebased, subjectTargetID: subjectTargetID, configuration: configuration,
                             macOS: false, templates: templates)
    }
    static func associate(rebased: AutomationRebasedProject, subjectTargetID: String,
                          configuration: String, platform: AutomationBuildPlatform, templates: URL) throws -> AutomationGeneratedHost {
        let name = try selectedTargetName(rebased: rebased, targetID: subjectTargetID, configuration: configuration)
        guard platform.targetName == name, platform.configuration == configuration,
              platform.projectPath == rebased.project.path,
              platform.supportsIOSSimulator || platform.supportsPhysicalIOS || platform.supportsMacOS else {
            throw AutomationContractError.missingEvidence("Associated host requires the resolved private app target and supported platform")
        }
        return try associate(rebased: rebased, subjectTargetID: subjectTargetID, configuration: configuration,
                             macOS: platform.supportsMacOS, includesSiri: platform.supportsPhysicalIOS, templates: templates)
    }
    private static func associate(rebased: AutomationRebasedProject, subjectTargetID: String,
                                  configuration: String, macOS: Bool, includesSiri: Bool = false, templates: URL) throws -> AutomationGeneratedHost {
        _ = try selectedTargetName(rebased: rebased, targetID: subjectTargetID, configuration: configuration)
        let session = rebased.session, source = session.appendingPathComponent("source"), project = rebased.project
        let projectFile = project.appendingPathComponent("project.pbxproj")
        let manifestData = try AutomationReadOnlyFile.read(root: session, relativePath: "source-manifest.json", maximumBytes: 16 * 1024 * 1024)
        let manifest = try JSONDecoder().decode(AutomationSourceManifest.self, from: manifestData)
        let data = try AutomationReadOnlyFile.read(root: source, relativePath: rebased.relativePath + "/project.pbxproj", maximumBytes: 16 * 1024 * 1024)
        guard AutomationArtifactRegistry.digest(data) == rebased.digest,
              var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var objects = plist["objects"] as? [String: [String: Any]], let rootID = plist["rootObject"] as? String,
              var root = objects[rootID], let mainGroupID = root["mainGroup"] as? String, var mainGroup = objects[mainGroupID],
              let productGroupID = root["productRefGroup"] as? String, var products = objects[productGroupID],
              let subject = objects[subjectTargetID], subject["isa"] as? String == "PBXNativeTarget",
              subject["productType"] as? String == "com.apple.product-type.application", let subjectName = subject["name"] as? String,
              let listID = subject["buildConfigurationList"] as? String, let configIDs = objects[listID]?["buildConfigurations"] as? [String],
              let selectedConfig = configIDs.compactMap({ objects[$0] }).first(where: { $0["name"] as? String == configuration }) else {
            throw AutomationContractError.invalidPlan("Selected app target/configuration is not in the frozen project")
        }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let name = "IntentsAutomationHost_" + suffix, bundleID = "com.intents.automation.host." + suffix
        let generated = session.appendingPathComponent("generated-host/" + name), sources = generated.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func id() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).uppercased() }
        func insert(_ value: [String: Any]) throws -> String { let key = id(); guard objects[key] == nil else { throw AutomationContractError.conflictingOperation }; objects[key] = value; return key }
        var references: [String] = [], builds: [String] = [], templateRecords: [String: String] = [:]
        for file in includesSiri ? physicalTemplateFiles : templateFiles {
            let bytes = try AutomationReadOnlyFile.read(root: templates, relativePath: file, maximumBytes: 1_048_576)
            try bytes.write(to: sources.appendingPathComponent(file), options: .withoutOverwriting)
            templateRecords[file] = AutomationArtifactRegistry.digest(bytes)
            let reference = try insert(["isa": "PBXFileReference", "lastKnownFileType": "sourcecode.swift", "path": file, "sourceTree": "<group>"])
            references.append(reference); builds.append(try insert(["isa": "PBXBuildFile", "fileRef": reference]))
        }
        let group = try insert(["isa": "PBXGroup", "path": sources.path, "sourceTree": "<absolute>", "children": references])
        let product = try insert(["isa": "PBXFileReference", "explicitFileType": "wrapper.cfbundle", "path": name + ".xctest", "sourceTree": "BUILT_PRODUCTS_DIR"])
        let phase = try insert(["isa": "PBXSourcesBuildPhase", "buildActionMask": 2147483647, "files": builds, "runOnlyForDeploymentPostprocessing": 0])
        let frameworks = try insert(["isa": "PBXFrameworksBuildPhase", "buildActionMask": 2147483647, "files": [String](), "runOnlyForDeploymentPostprocessing": 0])
        let subjectSettings = selectedConfig["buildSettings"] as? [String: Any] ?? [:]
        var settings: [String: Any] = ["SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "27.0", "SWIFT_VERSION": "6.0", "GENERATE_INFOPLIST_FILE": "YES",
            "PRODUCT_BUNDLE_IDENTIFIER": bundleID, "PRODUCT_NAME": "$(TARGET_NAME)", "TARGETED_DEVICE_FAMILY": "1,2", "CODE_SIGN_STYLE": "Automatic",
            "TEST_TARGET_NAME": subjectName, "FRAMEWORK_SEARCH_PATHS": ["$(inherited)", "$(PLATFORM_DIR)/Developer/Library/Frameworks"],
            "OTHER_LDFLAGS": ["$(inherited)", "-framework", "AppIntentsTesting"], "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]]
        if macOS {
            settings["SDKROOT"] = "macosx"
            settings["SUPPORTED_PLATFORMS"] = "macosx"
            settings["MACOSX_DEPLOYMENT_TARGET"] = "27.0"
            settings.removeValue(forKey: "IPHONEOS_DEPLOYMENT_TARGET")
            settings.removeValue(forKey: "TARGETED_DEVICE_FAMILY")
        }
        let rootList = root["buildConfigurationList"] as? String
        let rootConfigs = rootList.flatMap { objects[$0]?["buildConfigurations"] as? [String] } ?? []
        let projectSettings = rootConfigs.compactMap { objects[$0] }.first { $0["name"] as? String == configuration }?["buildSettings"] as? [String: Any] ?? [:]
        if let team = subjectSettings["DEVELOPMENT_TEAM"] ?? projectSettings["DEVELOPMENT_TEAM"] { settings["DEVELOPMENT_TEAM"] = team }
        let config = try insert(["isa": "XCBuildConfiguration", "name": configuration, "buildSettings": settings])
        let list = try insert(["isa": "XCConfigurationList", "buildConfigurations": [config], "defaultConfigurationIsVisible": 0, "defaultConfigurationName": configuration])
        let proxy = try insert(["isa": "PBXContainerItemProxy", "containerPortal": rootID, "proxyType": 1, "remoteGlobalIDString": subjectTargetID, "remoteInfo": subjectName])
        let dependency = try insert(["isa": "PBXTargetDependency", "target": subjectTargetID, "targetProxy": proxy])
        let target = try insert(["isa": "PBXNativeTarget", "name": name, "productName": name, "productReference": product, "productType": "com.apple.product-type.bundle.ui-testing",
                                 "buildConfigurationList": list, "buildPhases": [phase, frameworks], "buildRules": [String](), "dependencies": [dependency]])
        root["targets"] = (root["targets"] as? [String] ?? []) + [target]
        var attributes = root["attributes"] as? [String: Any] ?? [:], targetAttributes = attributes["TargetAttributes"] as? [String: Any] ?? [:]
        targetAttributes[target] = ["TestTargetID": subjectTargetID, "CreatedOnToolsVersion": "27.0"]; attributes["TargetAttributes"] = targetAttributes; root["attributes"] = attributes
        mainGroup["children"] = (mainGroup["children"] as? [String] ?? []) + [group]
        products["children"] = (products["children"] as? [String] ?? []) + [product]
        objects[rootID] = root; objects[mainGroupID] = mainGroup; objects[productGroupID] = products; plist["objects"] = objects
        let scheme = "<?xml version=\"1.0\"?><Scheme version=\"1.7\"><BuildAction><BuildActionEntries><BuildActionEntry buildForTesting=\"YES\" buildForRunning=\"NO\" buildForProfiling=\"NO\" buildForArchiving=\"NO\" buildForAnalyzing=\"YES\">\(reference(target, name, project.lastPathComponent))</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration=\"\(escape(configuration))\" shouldUseLaunchSchemeArgsEnv=\"YES\"><Testables><TestableReference skipped=\"NO\">\(reference(target, name, project.lastPathComponent))</TestableReference></Testables></TestAction></Scheme>"
        let schemes = project.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        try Data(scheme.utf8).write(to: schemes.appendingPathComponent(name + ".xcscheme"), options: .withoutOverwriting)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: projectFile, options: .atomic)
        try AutomationSourceSnapshot.verifyOriginal(manifest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .init(projectPath: project.path, scheme: name, targetID: target, bundleID: bundleID + ".xctrunner", configuration: configuration,
                     templateDigest: AutomationArtifactRegistry.digest(try encoder.encode(templateRecords)), includesSiri: includesSiri ? true : nil)
    }
    static func selectedTargetName(rebased: AutomationRebasedProject, targetID: String, configuration: String) throws -> String {
        let bytes = try AutomationReadOnlyFile.read(root: rebased.session.appendingPathComponent("source"),
            relativePath: rebased.relativePath + "/project.pbxproj", maximumBytes: 16 * 1024 * 1024)
        guard AutomationArtifactRegistry.digest(bytes) == rebased.digest,
              let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]], let target = objects[targetID],
              target["isa"] as? String == "PBXNativeTarget", target["productType"] as? String == "com.apple.product-type.application",
              let name = target["name"] as? String, !name.isEmpty, name.utf16.count <= 1024, !name.contains("\0"),
              objects.values.filter({ $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == name }).count == 1,
              let listID = target["buildConfigurationList"] as? String,
              let configs = objects[listID]?["buildConfigurations"] as? [String],
              configs.compactMap({ objects[$0] }).filter({ $0["name"] as? String == configuration }).count == 1 else {
            throw AutomationContractError.invalidPlan("Selected target/configuration is missing, ambiguous or changed in the isolated project")
        }
        return name
    }
    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
    private static func reference(_ target: String, _ name: String, _ project: String) -> String {
        "<BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"\(target)\" BuildableName=\"\(name).xctest\" BlueprintName=\"\(name)\" ReferencedContainer=\"container:\(escape(project))\"/>"
    }
}
