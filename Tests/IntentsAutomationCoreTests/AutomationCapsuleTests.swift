import XCTest
@testable import IntentsAutomationCore

final class AutomationCapsuleTests: XCTestCase {
    private func frozen() throws -> AutomationFrozenCase {
        try .init(plan: .init(id: "synthetic", app: .init(logicalID: "fixture", bundleID: "example.Fixture", platform: "ios"),
            target: .init(id: "fixture", kind: .simulator), environmentID: "unit-synthetic",
            execution: .init(id: "subject", kind: .systemIntent, phase: .subject, operation: "ContractAction")))
    }
    private func destination() -> URL { URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString + ".intentscase") }
    func testReviewedDataOnlyCapsuleImportsAsUnverifiedHistoryWithoutLiveAcceptance() throws {
        let frozen = try frozen(), root = destination(); defer { try? FileManager.default.removeItem(at: root) }
        try AutomationCaseCapsule.export(frozen: frozen, attempts: [], approval: .init(caseDigest: frozen.digest, attemptIDs: [], syntheticDataAndMetadataReviewed: true), to: root)
        let imported = try AutomationCaseCapsule.read(root)
        XCTAssertEqual(imported.frozen, frozen); XCTAssertFalse(imported.liveAccepted); XCTAssertEqual(imported.evidenceTrust, "historicalUnverified")
        XCTAssertTrue(imported.historicalAttempts.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["manifest.json", "plan.json"])
    }
    func testExportRequiresExactReviewedSyntheticSelectionAndDoesNotOverwrite() throws {
        let frozen = try frozen(), root = destination(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try AutomationCaseCapsule.export(frozen: frozen, attempts: [], approval: .init(caseDigest: frozen.digest, attemptIDs: [], syntheticDataAndMetadataReviewed: false), to: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try AutomationCaseCapsule.export(frozen: frozen, attempts: [], approval: .init(caseDigest: frozen.digest, attemptIDs: [], syntheticDataAndMetadataReviewed: true), to: root)
        XCTAssertThrowsError(try AutomationCaseCapsule.export(frozen: frozen, attempts: [], approval: .init(caseDigest: frozen.digest, attemptIDs: [], syntheticDataAndMetadataReviewed: true), to: root))
    }
    func testPathsDuplicatesExecutableEntriesNestingAndSizesFailClosed() throws {
        let digest = String(repeating: "a", count: 64)
        for path in ["../plan.json", "/plan.json", "x/../../plan.json", "a\\plan.json", "file:plan.json", "payload.swift", "payload.js", "a/b/c/d/e/f/g.json"] {
            XCTAssertThrowsError(try AutomationCaseCapsule.validateEntries([.init(path: path, size: 1, sha256: digest)]), path)
        }
        XCTAssertThrowsError(try AutomationCaseCapsule.validateEntries([.init(path: "plan.json", size: 1, sha256: digest), .init(path: "PLAN.json", size: 1, sha256: digest)]))
        XCTAssertThrowsError(try AutomationCaseCapsule.validateEntries([.init(path: "plan.json", size: 2_097_153, sha256: digest)]))
        XCTAssertThrowsError(try AutomationCaseCapsule.validateEntries((0..<20).map { .init(path: "file-\($0).json", size: 2_097_152, sha256: digest) }))
    }
    func testAlteredDataSymlinksAndUnmanifestedFilesAreRejected() throws {
        let frozen = try frozen(), root = destination(); defer { try? FileManager.default.removeItem(at: root) }
        try AutomationCaseCapsule.export(frozen: frozen, attempts: [], approval: .init(caseDigest: frozen.digest, attemptIDs: [], syntheticDataAndMetadataReviewed: true), to: root)
        let plan = root.appendingPathComponent("plan.json"), original = try Data(contentsOf: plan)
        try Data("{}".utf8).write(to: plan); XCTAssertThrowsError(try AutomationCaseCapsule.read(root))
        try original.write(to: plan)
        try Data("do not execute".utf8).write(to: root.appendingPathComponent("payload.js")); XCTAssertThrowsError(try AutomationCaseCapsule.read(root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("payload.js"))
        try FileManager.default.removeItem(at: plan)
        try FileManager.default.createSymbolicLink(at: plan, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try AutomationCaseCapsule.read(root))
    }
    #if canImport(zlib)
    private func compressed() throws -> (URL, AutomationFrozenCase, Data) {
        let value = try frozen(), url = destination()
        try AutomationCaseCapsule.exportCompressed(frozen: value, attempts: [], approval: .init(caseDigest: value.digest, attemptIDs: [], syntheticDataAndMetadataReviewed: true), to: url)
        return (url, value, try Data(contentsOf: url))
    }
    func testCompressedRoundTripKeepsHistoryUnverifiedAndPublishesPrivateFile() throws {
        let (url, value, _) = try compressed(); defer { try? FileManager.default.removeItem(at: url) }
        let imported = try AutomationCaseCapsule.read(url)
        XCTAssertEqual(imported.frozen, value); XCTAssertFalse(imported.liveAccepted)
        XCTAssertEqual(imported.evidenceTrust, "historicalUnverified")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try AutomationCaseCapsule.exportCompressed(frozen: value, attempts: [], approval: .init(caseDigest: value.digest, attemptIDs: [], syntheticDataAndMetadataReviewed: true), to: url))
    }
    func testCompressedExportRequiresReviewAndCannotReplaceDanglingSymlink() throws {
        let value = try frozen(), url = destination(); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try AutomationCaseCapsule.exportCompressed(frozen: value, attempts: [], approval: .init(caseDigest: value.digest, attemptIDs: [], syntheticDataAndMetadataReviewed: false), to: url))
        let absent = destination()
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: absent)
        XCTAssertThrowsError(try AutomationCaseCapsule.exportCompressed(frozen: value, attempts: [], approval: .init(caseDigest: value.digest, attemptIDs: [], syntheticDataAndMetadataReviewed: true), to: url))
        XCTAssertTrue(try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }
    func testCompressedCorruptionTruncationTrailingAndExpansionLimitsFailClosed() throws {
        let (url, _, original) = try compressed(); defer { try? FileManager.default.removeItem(at: url) }
        var variants: [Data] = [Data(original.dropLast()), original + Data([0]), Data(original.prefix(79))]
        var wrongMagic = original; wrongMagic[0] ^= 1; variants.append(wrongMagic)
        var wrongHash = original; wrongHash[16] = wrongHash[16] == 97 ? 98 : 97; variants.append(wrongHash)
        var tooBig = original; tooBig.replaceSubrange(8..<12, with: AutomationCompressedCaseCapsule.countBytes(AutomationCompressedCaseCapsule.maximumBytes + 1)); variants.append(tooBig)
        var bomb = original; bomb.replaceSubrange(8..<12, with: AutomationCompressedCaseCapsule.countBytes(4)); variants.append(bomb)
        var appendedStream = original
        appendedStream.append(original.dropFirst(80))
        appendedStream.replaceSubrange(12..<16, with: AutomationCompressedCaseCapsule.countBytes(appendedStream.count - 80)); variants.append(appendedStream)
        var garbageInStream = original + Data([0])
        garbageInStream.replaceSubrange(12..<16, with: AutomationCompressedCaseCapsule.countBytes(garbageInStream.count - 80)); variants.append(garbageInStream)
        for (index, bytes) in variants.enumerated() { XCTAssertThrowsError(try AutomationCompressedCaseCapsule.decode(bytes), "corruption variant \(index)") }
    }
    func testCompressedManifestCannotSmugglePathsTrustOrExtraRecords() throws {
        let value = try frozen(), plan = try AutomationFrozenCase.canonicalData(value)
        let entry = AutomationCapsuleManifest.Entry(path: "plan.json", size: plan.count, sha256: AutomationArtifactRegistry.digest(plan))
        var manifests = [AutomationCapsuleManifest(caseDigest: value.digest, files: [entry, entry]),
                         AutomationCapsuleManifest(caseDigest: value.digest, files: [.init(path: "../plan.json", size: plan.count, sha256: entry.sha256)]),
                         AutomationCapsuleManifest(caseDigest: value.digest, files: [.init(path: "payload.js", size: plan.count, sha256: entry.sha256)])]
        var promoted = AutomationCapsuleManifest(caseDigest: value.digest, files: [entry]); promoted.evidenceTrust = "liveAccepted"; manifests.append(promoted)
        for manifest in manifests {
            let json = try AutomationFrozenCase.canonicalData(manifest)
            var payload = AutomationCompressedCaseCapsule.countBytes(json.count); payload.append(json); payload.append(plan)
            XCTAssertThrowsError(try AutomationCompressedCaseCapsule.decode(AutomationCompressedCaseCapsule.wrap(payload)))
        }
        let manifest = AutomationCapsuleManifest(caseDigest: value.digest, files: [entry])
        let json = try AutomationFrozenCase.canonicalData(manifest)
        var payload = AutomationCompressedCaseCapsule.countBytes(json.count); payload.append(json); payload.append(plan); payload.append(0)
        XCTAssertThrowsError(try AutomationCompressedCaseCapsule.decode(AutomationCompressedCaseCapsule.wrap(payload)))
    }
    func testCompressedRecordedAttemptSurvivesWithoutAcquiringLiveTrust() throws {
        let value = try frozen(), url = destination(); defer { try? FileManager.default.removeItem(at: url) }
        let result = AutomationAssessment.assess(plan: value.plan, attemptID: "recorded", subjectDispatched: false, subjectCompleted: false, observations: [], termination: .unresolved)
        let report = AutomationAttemptReport(attemptID: "recorded", result: result, receipts: [], resourcesReleased: true)
        let approval = AutomationCapsuleExportApproval(caseDigest: value.digest, attemptIDs: ["recorded"], syntheticDataAndMetadataReviewed: true)
        let support = url.deletingLastPathComponent()
        let exposure = try AutomationEvidenceExposureAuthority(supportRoot: support).reserve(frozen: value, attempts: [report])
        try AutomationCaseCapsule.exportCompressed(frozen: value, attempts: [report], approval: approval, exposure: exposure, to: url)
        let imported = try AutomationCaseCapsule.read(url)
        XCTAssertEqual(imported.historicalAttempts, [report]); XCTAssertFalse(imported.liveAccepted)
        let other = destination(); defer { try? FileManager.default.removeItem(at: other) }
        XCTAssertThrowsError(try AutomationCaseCapsule.exportCompressed(frozen: value, attempts: [report], approval: .init(caseDigest: value.digest, attemptIDs: [], syntheticDataAndMetadataReviewed: true), to: other))
    }
    func testCompressedIncompressibleMaximumRecordAndEntryLimits() throws {
        var state: UInt64 = 1
        let bytes = Data((0..<2_097_152).map { _ -> UInt8 in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17; return UInt8(truncatingIfNeeded: state >> 24)
        })
        let entry = AutomationCapsuleManifest.Entry(path: "plan.json", size: bytes.count, sha256: AutomationArtifactRegistry.digest(bytes))
        let manifest = AutomationCapsuleManifest(caseDigest: String(repeating: "a", count: 64), files: [entry])
        let encoded = try AutomationCompressedCaseCapsule.encode(manifest: manifest, records: [entry.path: bytes])
        let (decoded, records) = try AutomationCompressedCaseCapsule.decode(encoded)
        XCTAssertEqual(decoded, manifest); XCTAssertEqual(records[entry.path], bytes)
        XCTAssertThrowsError(try AutomationCaseCapsule.importRecords(manifest: decoded, records: records))
        XCTAssertThrowsError(try AutomationCaseCapsule.validateEntries((0..<129).map { .init(path: "entry-\($0).json", size: 0, sha256: entry.sha256) }))
        var oversized = entry; oversized.size += 1
        XCTAssertThrowsError(try AutomationCompressedCaseCapsule.encode(manifest: .init(caseDigest: manifest.caseDigest, files: [oversized]), records: [entry.path: bytes]))
    }
    #endif

}
