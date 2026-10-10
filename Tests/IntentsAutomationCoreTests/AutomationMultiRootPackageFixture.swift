import Foundation
@testable import IntentsAutomationCore

enum AutomationMultiRootPackageFixture {
    struct Fixture { let app: URL, shared: URL, leaf: URL, project: URL; let targetID: String }
    static func write(_ root: URL) throws -> Fixture {
        let app = root.appendingPathComponent("App"), shared = root.appendingPathComponent("Packages/Shared"), leaf = root.appendingPathComponent("Packages/Leaf")
        let original = try AutomationMacInputProbeFixture.write(at: app)
        for folder in [shared.appendingPathComponent("Sources/Shared"), shared.appendingPathComponent("Extras"), leaf.appendingPathComponent("Sources/Leaf")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Data("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Shared", products: [.library(name: "Shared", targets: ["Shared"])],
            dependencies: [.package(path: "../Leaf")], targets: [.target(name: "Shared", dependencies: [.product(name: "Leaf", package: "Leaf")])])
        """.utf8).write(to: shared.appendingPathComponent("Package.swift"))
        try Data("import Leaf\npublic enum SharedMarker { public static let value = LeafMarker.value }\n".utf8).write(to: shared.appendingPathComponent("Sources/Shared/Shared.swift"))
        try Data("struct RootScopedEvidence {}\n".utf8).write(to: shared.appendingPathComponent("Extras/Extra.swift"))
        try Data("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Leaf", products: [.library(name: "Leaf", targets: ["Leaf"])], targets: [.target(name: "Leaf")])
        """.utf8).write(to: leaf.appendingPathComponent("Package.swift"))
        try Data("public enum LeafMarker { public static let value = \"owned external fixture\" }\n".utf8).write(to: leaf.appendingPathComponent("Sources/Leaf/Leaf.swift"))
        let source = "import Shared\n" + AutomationMacInputProbeFixture.source.replacingOccurrences(of: "try rejectBusinessDispatch()", with: "_ = SharedMarker.value\n        try rejectBusinessDispatch()")
        try Data(source.utf8).write(to: app.appendingPathComponent("Subject.swift"))
        var project = try PropertyListSerialization.propertyList(from: original.projectData, format: nil) as! [String: Any]
        var objects = project["objects"] as! [String: [String: Any]]
        let projectID = project["rootObject"] as! String, main = objects[projectID]!["mainGroup"] as! String
        let package = "EEEEEEEEEEEEEEEEEEEEEEE1", product = "EEEEEEEEEEEEEEEEEEEEEEE2", link = "EEEEEEEEEEEEEEEEEEEEEEE3"
        let scaffold = "EEEEEEEEEEEEEEEEEEEEEEE4", group = "EEEEEEEEEEEEEEEEEEEEEEE5", file = "EEEEEEEEEEEEEEEEEEEEEEE6", build = "EEEEEEEEEEEEEEEEEEEEEEE7"
        objects[package] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "../Packages/Shared"]
        objects[product] = ["isa": "XCSwiftPackageProductDependency", "productName": "Shared", "package": package]
        objects[link] = ["isa": "PBXBuildFile", "productRef": product]
        objects[scaffold] = ["isa": "PBXGroup", "path": "..", "sourceTree": "<group>", "children": [group]]
        objects[group] = ["isa": "PBXGroup", "path": "Packages/Shared/Extras", "sourceTree": "<group>", "children": [file]]
        objects[file] = ["isa": "PBXFileReference", "path": "Extra.swift", "sourceTree": "<group>", "lastKnownFileType": "sourcecode.swift"]
        objects[build] = ["isa": "PBXBuildFile", "fileRef": file]
        objects[main]!["children"] = (objects[main]!["children"] as! [String]) + [scaffold]
        objects[projectID]!["packageReferences"] = [package]
        objects[original.targetID]!["packageProductDependencies"] = [product]
        for id in objects.keys {
            if objects[id]?["isa"] as? String == "PBXFrameworksBuildPhase" { objects[id]!["files"] = [link] }
            if objects[id]?["isa"] as? String == "PBXSourcesBuildPhase" { objects[id]!["files"] = (objects[id]!["files"] as! [String]) + [build] }
        }
        project["objects"] = objects
        try PropertyListSerialization.data(fromPropertyList: project, format: .xml, options: 0).write(to: original.project.appendingPathComponent("project.pbxproj"))
        return .init(app: app, shared: shared, leaf: leaf, project: original.project, targetID: original.targetID)
    }
}
