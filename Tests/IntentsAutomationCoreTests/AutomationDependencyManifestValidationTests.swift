import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationDependencyManifestValidationTests: XCTestCase {
    private func file(_ path: String, materialized: String? = nil) -> AutomationSourceManifest.File {
        .init(inputPath: "/workspace/" + path, relativePath: path, bytes: 1,
              sha256: String(repeating: "a", count: 64), permissions: 0o600, materializedSourcePath: materialized)
    }
    private func manifest() -> AutomationSourceManifest {
        var value = AutomationSourceManifest(sourceRoot: "/workspace",
            files: [file("alias/nested/value", materialized: "/workspace/packages/inner/value")],
            directories: ["alias", "alias/nested"], excludedPaths: [])
        value.includesDependencies = true
        value.materializedLinks = [
            .init(relativePath: "alias", destination: "packages/outer", resolvedPath: "/workspace/packages/outer", directory: true),
            .init(relativePath: "alias/nested", destination: "packages/inner", resolvedPath: "/workspace/packages/inner", directory: true)
        ]
        return value
    }
    func testNearestDirectoryReceiptWinsRegardlessOfReceiptOrder() throws {
        var value = manifest()
        try value.validateCaptureLayout()
        value.materializedLinks?.reverse()
        try value.validateCaptureLayout()
        value.files[0].materializedSourcePath = "/workspace/packages/outer/nested/value"
        XCTAssertThrowsError(try value.validateCaptureLayout())
    }
    func testExactFileReceiptWinsAndNonDirectoryAncestorDoesNotOwnChildren() throws {
        var value = manifest()
        value.materializedLinks?.append(.init(relativePath: "alias/nested/value", destination: "packages/exact", resolvedPath: "/workspace/packages/exact", directory: false))
        value.files[0].materializedSourcePath = "/workspace/packages/exact"
        try value.validateCaptureLayout()
        value.materializedLinks?.removeLast()
        value.materializedLinks?[1].directory = false
        value.files.append(file("alias/nested"))
        value.files[0].materializedSourcePath = "/workspace/packages/outer/nested/value"
        try value.validateCaptureLayout()
    }
    func testDuplicateReceiptsMissingMembershipAndPrivateOriginsFailClosed() throws {
        var value = manifest()
        let duplicate = value.materializedLinks![0]
        value.materializedLinks?.append(duplicate)
        XCTAssertThrowsError(try value.validateCaptureLayout())
        value = manifest(); value.directories.removeAll()
        XCTAssertThrowsError(try value.validateCaptureLayout())
        value = manifest(); value.materializedLinks?[1].resolvedPath = "/workspace/.aws/private"
        value.files[0].materializedSourcePath = "/workspace/.aws/private/value"
        XCTAssertThrowsError(try value.validateCaptureLayout())
        value = manifest(); value.files[0].materializedSourcePath = "/outside/value"
        XCTAssertThrowsError(try value.validateCaptureLayout())
    }
    func testNodeAliasStillRequiresExactLinkReceiptDigestAndRebasing() throws {
        let path = "node_modules/alias", target = "/workspace/packages/target", destination = "../packages/target"
        var alias = file(path)
        alias.bytes = destination.utf8.count
        alias.sha256 = AutomationArtifactRegistry.digest(Data(destination.utf8))
        alias.symbolicLink = destination
        alias.frozenSymbolicLink = AutomationSourceSnapshot.rebasedLink(relativePath: alias.inputPath, target: target)
        var value = AutomationSourceManifest(sourceRoot: "/workspace", files: [alias], directories: [], excludedPaths: [])
        value.includesDependencies = true
        value.materializedLinks = [.init(relativePath: path, destination: destination, resolvedPath: target, directory: true)]
        try value.validateCaptureLayout()
        value.files[0].sha256 = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try value.validateCaptureLayout())
        value.files[0] = alias; value.files[0].frozenSymbolicLink = "/outside"
        XCTAssertThrowsError(try value.validateCaptureLayout())
        value.files[0] = alias; value.materializedLinks?[0].destination = "other"
        XCTAssertThrowsError(try value.validateCaptureLayout())
    }
}
