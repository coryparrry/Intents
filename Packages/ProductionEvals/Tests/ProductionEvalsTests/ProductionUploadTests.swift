import Foundation
import Testing

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
