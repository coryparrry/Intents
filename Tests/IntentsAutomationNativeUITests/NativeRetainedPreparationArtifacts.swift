#if os(macOS)
import Foundation
@testable import IntentsAutomationCore

/// Intact retained files for saved-case tests; these bytes are not an executable host.
func nativeRetainedPreparation(_ value: AutomationPreparedApplication, bundle: URL, support: URL,
                               saveRecord: Bool = true) throws -> AutomationPreparedApplication {
    var prepared = value
    let session = support.appendingPathComponent("prepare-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let subject = session.appendingPathComponent("Subject.app"), host = session.appendingPathComponent("Owned.app")
    try FileManager.default.copyItem(at: bundle, to: subject)
    try Data((try prepared.source.digest).utf8).write(to: subject.appendingPathComponent("SourceRevision.txt"))
    try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
    try Data((try prepared.source.digest).utf8).write(to: host.appendingPathComponent("payload"))
    prepared.host.app.canonicalBundlePath = subject.path
    prepared.host.app.productDigest = try AutomationProductDigest.compute(bundle: subject, version: prepared.host.app.productDigestVersion)
    prepared.host.subjectProductPath = subject.path; prepared.host.hostBundlePath = host.path
    prepared.host.hostProductDigest = try AutomationProductDigest.compute(bundle: host, version: prepared.host.hostProductDigestVersion)
    let sources = session.appendingPathComponent("generated-host/" + prepared.generatedHost.scheme + "/Sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    var records: [String: String] = [:]
    for file in AutomationHostGenerator.templateFiles {
        let data = Data(("// retained fixture " + file).utf8)
        try data.write(to: sources.appendingPathComponent(file))
        records[file] = AutomationArtifactRegistry.digest(data)
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    prepared.generatedHost.templateDigest = AutomationArtifactRegistry.digest(try encoder.encode(records))
    let xctestrun = session.appendingPathComponent("host.xctestrun"), settings = Data((try prepared.source.digest).utf8)
    try settings.write(to: xctestrun)
    prepared.host.xctestrunPath = xctestrun.path; prepared.host.xctestrunDigest = AutomationArtifactRegistry.digest(settings)
    prepared.buildLogPath = session.appendingPathComponent("build.log").path
    prepared.catalog.app = prepared.host.app
    // Startup restores the original selection without requiring another build.
    if let separator = prepared.host.app.logicalID.lastIndex(of: "#") {
        let project = URL(fileURLWithPath: String(prepared.host.app.logicalID[..<separator]))
        let targetID = String(prepared.host.app.logicalID[prepared.host.app.logicalID.index(after: separator)...])
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let plist: [String: Any] = ["objects": [targetID: ["isa": "PBXNativeTarget", "name": "Subject", "productType": "com.apple.product-type.application", "buildConfigurationList": "CONFIGS"],
            "CONFIGS": ["buildConfigurations": ["DEBUG"]], "DEBUG": ["name": prepared.generatedHost.configuration]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: project.appendingPathComponent("project.pbxproj"))
    }
    if saveRecord {
        let record = session.appendingPathComponent("prepared-application.json")
        try encoder.encode(prepared).write(to: record)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
    }
    try AutomationPreparedCodecAuthority.verify(prepared)
    return prepared
}
#endif
