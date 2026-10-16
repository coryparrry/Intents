import Foundation
import XCTest
import zlib
@testable import IntentsAutomationCore

final class AutomationIPAArchiveTests: XCTestCase {
    func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/ipa-intake-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testActualZIPExtractionPreservesProductBytesAndExecutableMode() async throws {
        let root = try root(), app = root.appendingPathComponent("Payload/Subject.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "example.Archived", "CFBundleExecutable": "Subject", "CFBundleSupportedPlatforms": ["iPhoneOS"]]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        let executable = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1, 0, 0, 0, 0])
        try infoData.write(to: app.appendingPathComponent("Info.plist"))
        try executable.write(to: app.appendingPathComponent("Subject"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("Subject").path)
        let archive = root.appendingPathComponent("Subject.ipa")
        let zip = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-q", "-r", archive.path, "Payload"], directory: root,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: .seconds(30))
        XCTAssertEqual(zip.exitStatus, 0)
        let product = try AutomationIPAArchive.extract(archive, supportRoot: root.appendingPathComponent("support"))
        XCTAssertNotEqual(product.path, app.path)
        XCTAssertEqual(try Data(contentsOf: product.appendingPathComponent("Info.plist")), infoData)
        XCTAssertEqual(try Data(contentsOf: product.appendingPathComponent("Subject")), executable)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: product.appendingPathComponent("Subject").path))
        XCTAssertEqual(try AutomationApplicationIntake.assess(product).candidates.first?.app?.bundleID, "example.Archived")
        XCTAssertTrue(FileManager.default.fileExists(atPath: product.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("import.json").path))
        let appleArchive = root.appendingPathComponent("AppleWriter.ipa")
        let ditto = try await AutomationOwnedCommand().run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--keepParent", root.appendingPathComponent("Payload").path, appleArchive.path],
            directory: root, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: .seconds(30))
        XCTAssertEqual(ditto.exitStatus, 0)
        let appleProduct = try AutomationIPAArchive.extract(appleArchive, supportRoot: root.appendingPathComponent("support"))
        XCTAssertEqual(try Data(contentsOf: appleProduct.appendingPathComponent("Subject")), executable)
    }
    func testRejectsTraversalLinksCollisionsAndFileParentsBeforeExtraction() throws {
        let cases: [[Member]] = [
            [.init("../escape")], [.init("/absolute")], [.init("Payload/../../escape")], [.init("Payload\\escape")],
            [.init("Payload/link", mode: 0o120777)], [.init("Payload/device", mode: 0o020600)],
            [.init("Payload/a"), .init("Payload/A")], [.init("Payload/a"), .init("Payload/a/b")],
            [.init("Payload/e\u{301}"), .init("Payload/é")], [.init("Payload/a"), .init("Payload/a")]
        ]
        for members in cases { XCTAssertThrowsError(try AutomationIPAArchive.inspect(zip(members)), members.map(\.name).joined(separator: ", ")) }
    }
    func testRejectsChecksumDamageAndCleansOnlyItsExtraction() throws {
        let root = try root(), support = root.appendingPathComponent("support")
        let kept = root.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: kept)
        var bytes = zip([.init("Payload/a", content: Data("content".utf8))])
        bytes[30 + "Payload/a".utf8.count] ^= 1
        let archive = root.appendingPathComponent("bad.ipa"); try bytes.write(to: archive)
        XCTAssertThrowsError(try AutomationIPAArchive.extract(archive, supportRoot: support))
        XCTAssertEqual(try Data(contentsOf: kept), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent("ImportedApplications").path), [])
    }
    func testRejectsOverlappingEntriesEncryptedAndOversizedData() throws {
        let original = zip([.init("Payload/a", content: Data("content".utf8))])
        let central = 30 + "Payload/a".utf8.count + 7
        for (offset, value) in [(central + 8, UInt32(1)), (central + 24, UInt32.max), (central + 42, UInt32.max)] {
            var bytes = original
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
            XCTAssertThrowsError(try AutomationIPAArchive.inspect(bytes))
        }
        var overlap = zip([.init("Payload/a"), .init("Payload/b")])
        let secondCentral = 2 * (30 + 9) + 46 + 9
        for index in 0..<4 { overlap[secondCentral + 42 + index] = 0 }
        XCTAssertThrowsError(try AutomationIPAArchive.inspect(overlap))
        XCTAssertThrowsError(try AutomationIPAArchive.inspect(Data(original.dropLast())))
    }
    struct Member {
        let name: String; let content: Data; let mode: Int
        init(_ name: String, content: Data = Data(), mode: Int = 0o100644) { self.name = name; self.content = content; self.mode = mode }
    }
    func zip(_ members: [Member]) -> Data {
        var body = Data(), central = Data()
        func number(_ value: Int, _ count: Int, into data: inout Data) { for index in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (8 * index))) } }
        for member in members {
            let name = Data(member.name.utf8), offset = body.count
            let checksum = Int(member.content.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(member.content.count)) })
            number(0x04034b50, 4, into: &body)
            for value in [20, 0, 0, 0, 0] { number(value, 2, into: &body) }
            for value in [checksum, member.content.count, member.content.count] { number(value, 4, into: &body) }
            number(name.count, 2, into: &body); number(0, 2, into: &body); body.append(name); body.append(member.content)
            number(0x02014b50, 4, into: &central)
            for value in [0x0314, 20, 0, 0, 0, 0] { number(value, 2, into: &central) }
            for value in [checksum, member.content.count, member.content.count] { number(value, 4, into: &central) }
            for value in [name.count, 0, 0, 0, 0] { number(value, 2, into: &central) }
            number(member.mode << 16, 4, into: &central); number(offset, 4, into: &central); central.append(name)
        }
        let start = body.count; body.append(central); number(0x06054b50, 4, into: &body)
        for value in [0, 0, members.count, members.count] { number(value, 2, into: &body) }
        number(central.count, 4, into: &body); number(start, 4, into: &body); number(0, 2, into: &body)
        return body
    }
}
