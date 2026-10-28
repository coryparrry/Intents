import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@testable import ProductionEvals

struct ProductionUploadTests {
  private func storage() throws -> ProductionStorage {
    try ProductionStorage(
      root: FileManager.default.temporaryDirectory.appendingPathComponent("uploads-\(UUID())"))
  }
  private func source(_ count: Int = 1) throws -> Data {
    var data = Data()
    for i in 0..<count {
      data.append(
        try ProductionCodec.encode(
          ProductionExample(id: "case-\(i)", prompt: "Café \(i)", capturedOutput: "original-\(i)")))
      data.append(10)
    }
    return data
  }
  /// Creates a valid captured job from synthetic source bytes for export destination checks.
  private func capturedJob(in storage: ProductionStorage) throws -> ProductionJob {
    let file = storage.root.appendingPathComponent("source.jsonl")
    try source().write(to: file)
    let dataset = try storage.importDataset(from: file, name: "Export fixture", version: "1")
    return try storage.createCapturedJob(name: "Captured", datasetRevision: dataset.revision)
  }
  /// Observes a second open handle to the held lock, proving export passed preflight and reached its blocked transaction.
  private func hasWaitingExportDescriptor(matching descriptor: Int32) throws -> Bool {
    var held = stat()
    guard fstat(descriptor, &held) == 0 else { throw ProductionFailure.unavailable("Cannot inspect test lock.") }
    return try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").contains { name in
      guard let candidate = Int32(name), candidate != descriptor else { return false }
      var value = stat()
      return fstat(candidate, &value) == 0 && value.st_dev == held.st_dev && value.st_ino == held.st_ino
    }
  }
  /// Freezes aliases before lock contention and rejects a frozen parent retargeted into storage before lock acquisition.
  @Test(arguments: [false, true])
  func exportKeepsDestinationSafeWhenAliasesChangeWhileWaiting(retargetCanonicalParent: Bool) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("export-waiting-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let storage = try ProductionStorage(root: base.appendingPathComponent("store"))
    let job = try capturedJob(in: storage)
    let originalPaths = try FileManager.default.subpathsOfDirectory(atPath: storage.root.path).sorted()
    let external = base.appendingPathComponent("external"), alias = base.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: external)
    let descriptor = open(storage.root.appendingPathComponent(".store.lock").path, O_RDWR)
    try #require(descriptor >= 0)
    defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
    try #require(flock(descriptor, LOCK_EX) == 0)
    let export = Task.detached { try storage.exportJob(job.id, to: alias.appendingPathComponent("export")) }
    var reachedLock = false
    do {
      for _ in 0..<500 {
        if try hasWaitingExportDescriptor(matching: descriptor) { reachedLock = true; break }
        try await Task.sleep(for: .milliseconds(10))
      }
      let switched = retargetCanonicalParent ? external : alias
      try FileManager.default.removeItem(at: switched)
      try FileManager.default.createSymbolicLink(at: switched, withDestinationURL: storage.root.appendingPathComponent("Jobs"))
    } catch {
      _ = flock(descriptor, LOCK_UN)
      _ = await export.result
      throw error
    }
    _ = flock(descriptor, LOCK_UN)
    let result = await export.result
    #expect(reachedLock)
    if retargetCanonicalParent {
      if case .failure(let error) = result { #expect(error is ProductionFailure) }
      else { Issue.record("Export accepted a frozen destination retargeted into storage.") }
    } else {
      try result.get()
      #expect(FileManager.default.fileExists(atPath: external.appendingPathComponent("export/report.json").path))
    }
    #expect(try FileManager.default.subpathsOfDirectory(atPath: storage.root.path).sorted() == originalPaths)
    #expect(try storage.jobs().map(\.id) == [job.id])
  }
  /// Rejects every active-store collection and copied source descendant before creating export staging.
  @Test func exportRejectsStoreDescendantsWithoutChangingTheStore() throws {
    let storage = try storage()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let job = try capturedJob(in: storage)
    let paths = try FileManager.default.subpathsOfDirectory(atPath: storage.root.path).sorted()
    let destinations = ["Jobs/export", "Jobs/missing/export", "Datasets/export", "Reviews/export",
      "Schedules/export", "Workers/export", "Jobs/\(job.id)/export", "Datasets/\(job.datasetRevision)/export"]
    for path in destinations {
      #expect(throws: ProductionFailure.self) {
        try storage.exportJob(job.id, to: storage.root.appendingPathComponent(path))
      }
      #expect(try FileManager.default.subpathsOfDirectory(atPath: storage.root.path).sorted() == paths)
      #expect(try storage.jobs().map(\.id) == [job.id])
    }
  }
  /// Resolves destination and storage aliases, including missing parents, traversal, and case aliases where supported.
  @Test(arguments: [false, true])
  func exportRejectsSymlinkAliasesIntoTheStore(aliasedStorage: Bool) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("export-alias-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let original = try ProductionStorage(root: base.appendingPathComponent("store"))
    let alias = base.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original.root)
    let storage = aliasedStorage ? try ProductionStorage(root: alias) : original
    let job = try capturedJob(in: storage)
    let jobAlias = base.appendingPathComponent("job-alias")
    try FileManager.default.createSymbolicLink(at: jobAlias, withDestinationURL: original.jobDirectory(job.id))
    let paths = try FileManager.default.subpathsOfDirectory(atPath: original.root.path).sorted()
    var destinations = [alias.appendingPathComponent("Jobs/export"), alias.appendingPathComponent("Jobs/missing/export"),
      jobAlias.appendingPathComponent("export"), jobAlias.appendingPathComponent("../export"),
      base.appendingPathComponent("missing/../alias/Jobs/export")]
    let caseAlias = base.appendingPathComponent("STORE")
    if FileManager.default.fileExists(atPath: caseAlias.path) {
      destinations.append(caseAlias.appendingPathComponent("Jobs/export"))
      destinations.append(caseAlias.appendingPathComponent("Jobs/missing/export"))
    }
    for destination in destinations {
      #expect(throws: ProductionFailure.self) { try storage.exportJob(job.id, to: destination) }
      #expect(try FileManager.default.subpathsOfDirectory(atPath: original.root.path).sorted() == paths)
      #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("missing").path))
    }
    #expect(try storage.jobs().map(\.id) == [job.id])
  }
  /// Allows an external sibling whose name shares the store prefix and retains a readable evidence bundle.
  @Test func exportAllowsSiblingPrefixOutsideTheStore() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("export-sibling-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let storage = try ProductionStorage(root: base.appendingPathComponent("store"))
    let job = try capturedJob(in: storage)
    let destination = base.appendingPathComponent("store-export/missing/export")
    try storage.exportJob(job.id, to: destination)
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("report.json").path))
    #expect(try Data(contentsOf: destination.appendingPathComponent("Dataset/examples.jsonl"))
      == Data(contentsOf: storage.datasetDirectory(job.datasetRevision).appendingPathComponent("examples.jsonl")))
    #expect(try storage.jobs().map(\.id) == [job.id])
  }
  /// The typed managed API accepts storage-root aliases while keeping bundles in its canonical UUID spool and preserving existing exports.
  @Test(arguments: [false, true])
  func managedExportsUseCanonicalSpoolWithoutWeakeningExternalPolicy(aliasedStorage: Bool) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("managed-export-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let original = try ProductionStorage(root: base.appendingPathComponent("store"))
    let alias = base.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original.root)
    let storage = aliasedStorage ? try ProductionStorage(root: alias) : original
    let job = try capturedJob(in: storage), exportID = UUID()
    let destination = try storage.exportManagedJob(jobID: job.id, exportID: exportID)
    #expect(destination == original.root.resolvingSymlinksInPath().appendingPathComponent("MCPExports/\(exportID)", isDirectory: true))
    let report = destination.appendingPathComponent("report.json"), bytes = try Data(contentsOf: report)
    #expect(try ProductionCodec.decode(ProductionReport.self, bytes).job.id == job.id)
    #expect(throws: ProductionFailure.self) { try storage.exportManagedJob(jobID: job.id, exportID: exportID) }
    #expect(try Data(contentsOf: report) == bytes)
    #expect(throws: ProductionFailure.self) {
      try storage.exportJob(job.id, to: original.root.appendingPathComponent("MCPExports/\(UUID())"))
    }
    #expect(try storage.jobs().map(\.id) == [job.id])
  }
  /// Managed spooling rejects existing live or dangling symlinks before it creates or enumerates through their targets.
  @Test(arguments: ["Jobs", "external", "missing"])
  func managedExportsRejectSymlinkedSpool(target: String) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("managed-spool-link-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let storage = try ProductionStorage(root: base.appendingPathComponent("store")), job = try capturedJob(in: storage)
    let targetURL = target == "Jobs" ? storage.root.appendingPathComponent("Jobs") : base.appendingPathComponent(target)
    if target == "external" { try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: false) }
    try FileManager.default.createSymbolicLink(at: storage.root.appendingPathComponent("MCPExports"), withDestinationURL: targetURL)
    #expect(throws: ProductionFailure.self) { try storage.exportManagedJob(jobID: job.id, exportID: UUID()) }
    #expect(try storage.jobs().map(\.id) == [job.id])
    if target == "missing" { #expect(!FileManager.default.fileExists(atPath: targetURL.path)) }
    if target == "external" { #expect(try FileManager.default.contentsOfDirectory(atPath: targetURL.path).isEmpty) }
  }
  /// A UUID component cannot redirect managed publication through either a live or dangling symlink.
  @Test(arguments: [false, true])
  func managedExportsRejectSymlinkedUUIDDestination(dangling: Bool) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("managed-id-link-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let storage = try ProductionStorage(root: base.appendingPathComponent("store")), job = try capturedJob(in: storage), exportID = UUID()
    let folder = storage.root.appendingPathComponent("MCPExports"), target = base.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    if !dangling { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(exportID.uuidString), withDestinationURL: target)
    #expect(throws: ProductionFailure.self) { try storage.exportManagedJob(jobID: job.id, exportID: exportID) }
    #expect(try storage.jobs().map(\.id) == [job.id])
    if dangling { #expect(!FileManager.default.fileExists(atPath: target.path)) }
    else { #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty) }
  }
  /// The typed spool API preserves the connector's existing retention ceiling under the same transaction as publication.
  @Test func managedExportsEnforceRetentionWithoutPublishingAnotherBundle() throws {
    let storage = try storage()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let job = try capturedJob(in: storage), folder = storage.root.appendingPathComponent("MCPExports"), exportID = UUID()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    for _ in 0..<100 { try FileManager.default.createDirectory(at: folder.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: false) }
    #expect(throws: ProductionFailure.self) { try storage.exportManagedJob(jobID: job.id, exportID: exportID) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 100)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(exportID.uuidString).path))
  }
  /// Refuses corrupted current and compatible legacy revisions without replacing immutable retained evidence.
  @Test(arguments: [false, true], ["examples.jsonl", "offsets.bin"])
  func retainedDatasetImportVerifiesPublishedBytes(legacy: Bool, fileName: String) throws {
    let storage = try storage()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let file = storage.root.appendingPathComponent("source.jsonl")
    try source().write(to: file)
    var dataset = try storage.importDataset(from: file, name: "Retained", version: "1")
    if legacy {
      let fields = [dataset.name, dataset.version, dataset.sampling.rawValue, String(dataset.productionData),
        dataset.dataDigest, dataset.indexDigest, String(dataset.count),
        try ProductionCodec.digest(ProductionCodec.encode(dataset.partitionCounts))]
      let original = try storage.datasetDirectory(dataset.revision)
      dataset.revision = ProductionCodec.digest(Data(fields.joined(separator: "\n").utf8))
      let retained = try storage.datasetDirectory(dataset.revision)
      try FileManager.default.moveItem(at: original, to: retained)
      try ProductionCodec.write(dataset, to: retained.appendingPathComponent("manifest.json"))
    }
    #expect(try storage.importDataset(from: file, name: "Retained", version: "1").revision == dataset.revision)
    let folder = try storage.datasetDirectory(dataset.revision)
    let manifest = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
    let published = folder.appendingPathComponent(fileName), original = try Data(contentsOf: published)
    var corrupted = original
    corrupted[0] ^= 1
    try corrupted.write(to: published)
    #expect(throws: ProductionFailure.self) { try storage.importDataset(from: file, name: "Retained", version: "1") }
    #expect(try Data(contentsOf: published) == corrupted)
    #expect(try Data(contentsOf: folder.appendingPathComponent("manifest.json")) == manifest)
    #expect(try FileManager.default.contentsOfDirectory(atPath: storage.root.appendingPathComponent("Datasets").path)
      == [dataset.revision])
    try original.write(to: published)
    #expect(try storage.importDataset(from: file, name: "Retained", version: "1").revision == dataset.revision)
  }
  /// Refuses successful completion retries when published example or offset bytes no longer match the upload's revision.
  @Test(arguments: ["examples.jsonl", "offsets.bin"])
  func completedUploadRetryVerifiesPublishedDatasetBytes(fileName: String) throws {
    let storage = try storage()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let bytes = try source()
    let upload = ProductionUpload(id: UUID(), name: "Retained upload", version: "1", expectedChunks: 1,
      expectedBytes: bytes.count, expectedDigest: ProductionCodec.digest(bytes))
    _ = try storage.beginUpload(upload)
    try storage.appendUpload(upload.id, index: 0, data: bytes)
    _ = try storage.previewUpload(upload.id)
    let dataset = try storage.finishUpload(upload.id, previewDigest: upload.expectedDigest, redactionConfirmed: false)
    let manifestFile = storage.root.appendingPathComponent("Uploads/\(upload.id)/upload.json")
    let manifest = try Data(contentsOf: manifestFile)
    let published = try storage.datasetDirectory(dataset.revision).appendingPathComponent(fileName)
    let original = try Data(contentsOf: published)
    var corrupted = original
    corrupted[0] ^= 1
    try corrupted.write(to: published)
    #expect(throws: ProductionFailure.self) {
      try storage.finishUpload(upload.id, previewDigest: upload.expectedDigest, redactionConfirmed: false)
    }
    #expect(try Data(contentsOf: published) == corrupted)
    #expect(try Data(contentsOf: manifestFile) == manifest)
    #expect(try storage.upload(upload.id).datasetRevision == dataset.revision)
    try original.write(to: published)
    #expect(try storage.finishUpload(upload.id, previewDigest: upload.expectedDigest, redactionConfirmed: false)
      .revision == dataset.revision)
  }
  @Test(arguments: [false, true])
  func rejectsUnreadableManifestBeforeAdmittingUpload(completionOnly: Bool) throws {
    let storage = try storage()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let bytes = try source()
    var upload = ProductionUpload(
      id: UUID(), name: "a", version: "1", expectedChunks: 1,
      expectedBytes: bytes.count, expectedDigest: ProductionCodec.digest(bytes))
    let target = completionOnly ? 4050 : 4200
    while try ProductionCodec.encode(upload).count < target { upload.name += "\u{0301}" }
    #expect(upload.name.count == 1)
    if completionOnly {
      #expect(try ProductionCodec.encode(upload).count <= 4096)
      var completed = upload
      completed.previewed = true; completed.datasetRevision = String(repeating: "0", count: 64)
      #expect(try ProductionCodec.encode(completed).count > 4096)
    }
    #expect(throws: ProductionFailure.self) { try storage.beginUpload(upload) }
    #expect(!FileManager.default.fileExists(atPath: storage.root.appendingPathComponent("Uploads/\(upload.id)").path))
    // Rejection must not reserve this ID or consume a pending-upload slot.
    upload.name = "Valid"
    #expect(try storage.beginUpload(upload) == upload)
  }

  @Test func boundedUnicodeManifestRemainsReadableThroughCompletion() throws {
    let storage = try storage()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let bytes = try source()
    let upload = ProductionUpload(
      id: UUID(), name: "a" + String(repeating: "\u{0301}", count: 1600), version: "1", expectedChunks: 1,
      expectedBytes: bytes.count, expectedDigest: ProductionCodec.digest(bytes))
    _ = try storage.beginUpload(upload)
    try storage.appendUpload(upload.id, index: 0, data: bytes)
    _ = try storage.previewUpload(upload.id)
    let dataset = try storage.finishUpload(upload.id, previewDigest: upload.expectedDigest, redactionConfirmed: false)
    #expect(try storage.upload(upload.id).datasetRevision == dataset.revision)
    #expect(try storage.beginUpload(upload).datasetRevision == dataset.revision)
  }

  @Test(arguments: [false, true])
  func interruptedDiscardRejectsFurtherUseAndCanFinishCleanup(previewed: Bool) throws {
    let storage = try storage()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let bytes = try source()
    let upload = ProductionUpload(
      id: UUID(), name: "Discarded", version: "1", expectedChunks: 1,
      expectedBytes: bytes.count, expectedDigest: ProductionCodec.digest(bytes))
    _ = try storage.beginUpload(upload)
    try storage.appendUpload(upload.id, index: 0, data: bytes)
    if previewed { _ = try storage.previewUpload(upload.id) }
    let folder = storage.root.appendingPathComponent("Uploads/\(upload.id)")
    let manifest = try Data(contentsOf: folder.appendingPathComponent("upload.json"))
    // Reproduce a crash after the durable tombstone but before directory removal.
    try Data(upload.id.uuidString.utf8).write(to: storage.root.appendingPathComponent("Uploads/.discarded-\(upload.id)"))
    #expect(throws: ProductionFailure.self) { try storage.beginUpload(upload) }
    #expect(throws: ProductionFailure.self) { try storage.uploadStatus(upload.id) }
    #expect(throws: ProductionFailure.self) { try storage.appendUpload(upload.id, index: 0, data: bytes) }
    #expect(throws: ProductionFailure.self) { try storage.previewUpload(upload.id) }
    #expect(throws: ProductionFailure.self) {
      try storage.finishUpload(upload.id, previewDigest: upload.expectedDigest, redactionConfirmed: false)
    }
    #expect(try Data(contentsOf: folder.appendingPathComponent("upload.json")) == manifest)
    #expect(try FileManager.default.contentsOfDirectory(atPath: storage.root.appendingPathComponent("Datasets").path).isEmpty)
    try storage.discardUpload(upload.id)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    try storage.discardUpload(upload.id)
    #expect(throws: ProductionFailure.self) { try storage.beginUpload(upload) }
  }

  @Test(arguments: [false, true])
  func explicitDiscardRecoversUnreadableLegacyManifest(oversized: Bool) throws {
    let storage = try storage()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let bytes = try source()
    let sibling = ProductionUpload(
      id: UUID(), name: "Keep", version: "1", expectedChunks: 1,
      expectedBytes: bytes.count, expectedDigest: ProductionCodec.digest(bytes))
    _ = try storage.beginUpload(sibling)
    let id = UUID(), folder = storage.root.appendingPathComponent("Uploads/\(id)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var legacy = sibling
    legacy.id = id
    legacy.name = "a" + String(repeating: "\u{0301}", count: 2500)
    let manifest = oversized ? try ProductionCodec.encode(legacy) : Data("{interrupted".utf8)
    try manifest.write(to: folder.appendingPathComponent("upload.json"))
    try bytes.write(to: folder.appendingPathComponent("0.chunk"))
    #expect(throws: Error.self) { try storage.upload(id) }
    try storage.discardUpload(id)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(try storage.upload(sibling.id) == sibling)
    legacy.name = "Valid"
    #expect(throws: ProductionFailure.self) { try storage.beginUpload(legacy) }
    try storage.discardUpload(id)
  }

  @Test func discardRejectsUnknownIDsAndDirectoriesWithoutManifest() throws {
    let storage = try storage()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let id = UUID(), folder = storage.root.appendingPathComponent("Uploads/\(id)")
    #expect(throws: ProductionFailure.self) { try storage.discardUpload(id) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let sentinel = folder.appendingPathComponent("unrelated.txt"), bytes = Data("keep".utf8)
    try bytes.write(to: sentinel)
    #expect(throws: ProductionFailure.self) { try storage.discardUpload(id) }
    #expect(try Data(contentsOf: sentinel) == bytes)
    #expect(!FileManager.default.fileExists(atPath: storage.root.appendingPathComponent("Uploads/.discarded-\(id)").path))
  }

  @Test func splitByteChunksSealPreviewAndIdempotentImport() throws {
    let storage = try storage()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let bytes = try source(100)
    let id = UUID()
    let split = bytes.firstIndex(of: 0xc3)! + 1
    let upload = ProductionUpload(
      id: id, name: "100 distinct outputs", version: "1", expectedChunks: 2,
      expectedBytes: bytes.count, expectedDigest: ProductionCodec.digest(bytes))
    _ = try storage.beginUpload(upload)
    try storage.appendUpload(id, index: 0, data: bytes.prefix(split))
    try storage.appendUpload(id, index: 0, data: bytes.prefix(split))
    #expect(throws: Error.self) { try storage.previewUpload(id) }
    #expect(throws: Error.self) {
      try storage.finishUpload(id, previewDigest: upload.expectedDigest, redactionConfirmed: false)
    }
    try storage.appendUpload(id, index: 1, data: bytes.suffix(from: split))
    #expect(try storage.previewUpload(id).count == 3)
    #expect(throws: Error.self) {
      try storage.appendUpload(id, index: 1, data: bytes.suffix(from: split))
    }
    let dataset = try storage.finishUpload(
      id, previewDigest: upload.expectedDigest, redactionConfirmed: false)
    #expect(dataset.count == 100)
    #expect(
      try storage.finishUpload(id, previewDigest: upload.expectedDigest, redactionConfirmed: false)
        .revision == dataset.revision)
    #expect(try storage.beginUpload(upload).datasetRevision == dataset.revision)
    let reader = try ProductionDatasetReader(storage: storage, revision: dataset.revision)
    #expect(try reader.example(at: 99).capturedOutput == "original-99")
  }
  @Test func rejectsConflictsDigestMismatchAndUnconfirmedProductionData() throws {
    let storage = try storage()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let bytes = try source()
    let id = UUID()
    var upload = ProductionUpload(
      id: id, name: "private", version: "1", productionData: true, expectedChunks: 1,
      expectedBytes: bytes.count, expectedDigest: ProductionCodec.digest(bytes))
    _ = try storage.beginUpload(upload)
    try storage.appendUpload(id, index: 0, data: bytes)
    #expect(throws: Error.self) {
      try storage.appendUpload(id, index: 0, data: Data(repeating: 65, count: bytes.count))
    }
    upload.name = "changed"
    #expect(throws: Error.self) { try storage.beginUpload(upload) }
    _ = try storage.previewUpload(id)
    #expect(throws: Error.self) {
      try storage.finishUpload(id, previewDigest: upload.expectedDigest, redactionConfirmed: false)
    }
    #expect(throws: Error.self) {
      try storage.finishUpload(
        id, previewDigest: String(repeating: "0", count: 64), redactionConfirmed: true)
    }
    #expect(
      try storage.finishUpload(id, previewDigest: upload.expectedDigest, redactionConfirmed: true)
        .count == 1)
    let bad = ProductionUpload(
      id: UUID(), name: "bad", version: "1", expectedChunks: 1, expectedBytes: bytes.count,
      expectedDigest: String(repeating: "0", count: 64))
    _ = try storage.beginUpload(bad)
    try storage.appendUpload(bad.id, index: 0, data: bytes)
    #expect(throws: Error.self) { try storage.previewUpload(bad.id) }
  }
  @Test func rejectsOversizedTamperedChunkBeforeDecodeAndJobNameCollision() throws {
    let storage = try storage()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let bytes = try source()
    let id = UUID()
    let upload = ProductionUpload(
      id: id, name: "tamper", version: "1", expectedChunks: 1, expectedBytes: bytes.count,
      expectedDigest: ProductionCodec.digest(bytes))
    _ = try storage.beginUpload(upload)
    try storage.appendUpload(id, index: 0, data: bytes)
    let path = storage.root.appendingPathComponent("Uploads/\(id)/0.chunk")
    try Data(repeating: 65, count: 1_048_577).write(to: path)
    #expect(throws: Error.self) { try storage.previewUpload(id) }
    #expect(throws: Error.self) { try storage.appendUpload(id, index: 0, data: bytes) }
    try storage.discardUpload(id)
    #expect(throws: Error.self) { try storage.beginUpload(upload) }
    var fresh = upload
    fresh.id = UUID()
    _ = try storage.beginUpload(fresh)
    try storage.appendUpload(fresh.id, index: 0, data: bytes)
    _ = try storage.previewUpload(fresh.id)
    let dataset = try storage.finishUpload(
      fresh.id, previewDigest: fresh.expectedDigest, redactionConfirmed: false)
    let job = try storage.createCapturedJob(
      name: "first", datasetRevision: dataset.revision, id: UUID())
    #expect(
      try storage.createCapturedJob(name: "first", datasetRevision: dataset.revision, id: job.id).revision
        == job.revision)
    #expect(throws: Error.self) {
      try storage.createCapturedJob(name: "changed", datasetRevision: dataset.revision, id: job.id)
    }
  }
  @Test func controlAndScheduleRevisionsRejectStaleChangesAndHugeDates() throws {
    let storage = try storage()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let bytes = try source()
    let id = UUID()
    let upload = ProductionUpload(
      id: id, name: "controls", version: "1", expectedChunks: 1, expectedBytes: bytes.count,
      expectedDigest: ProductionCodec.digest(bytes))
    _ = try storage.beginUpload(upload)
    try storage.appendUpload(id, index: 0, data: bytes)
    _ = try storage.previewUpload(id)
    let dataset = try storage.finishUpload(
      id, previewDigest: upload.expectedDigest, redactionConfirmed: false)
    let job = try storage.createCapturedJob(name: "captured", datasetRevision: dataset.revision)
    let original = try storage.controlRevision(job)
    try storage.setControl(jobID: job.id, cancelled: true, expectedControlRevision: original)
    #expect(throws: Error.self) {
      try storage.setControl(jobID: job.id, cancelled: false, expectedControlRevision: original)
    }
    #expect(try storage.control(job).cancelled)
    let schedule = ProductionSchedule(templateJobID: job.id, intervalSeconds: 60)
    try storage.saveSchedule(schedule, expectedRevision: "absent")
    #expect(throws: Error.self) { try storage.saveSchedule(schedule, expectedRevision: "absent") }
    var changed = schedule
    changed.paused = true
    let revision = try ProductionCodec.digest(ProductionCodec.encode(schedule))
    try storage.saveSchedule(changed, expectedRevision: revision)
    #expect(throws: Error.self) { try storage.saveSchedule(schedule, expectedRevision: revision) }
    var huge = schedule
    huge.nextRun = Date(timeIntervalSince1970: 1e27)
    #expect(throws: Error.self) { try storage.saveSchedule(huge) }
  }
}
