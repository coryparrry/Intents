import CryptoKit
import Foundation

public struct ProductionUpload: Codable, Sendable, Equatable {
  public var id: UUID
  public var name: String
  public var version: String
  public var sampling: ProductionSampling
  public var productionData: Bool
  public var expectedChunks: Int
  public var expectedBytes: Int
  public var expectedDigest: String
  public var previewed = false
  public var datasetRevision: String?
  /// Declares the exact ordered chunk count, total byte count, and SHA-256 digest of an upload before accepting source bytes.
  public init(
    id: UUID, name: String, version: String, sampling: ProductionSampling = .curated,
    productionData: Bool = false, expectedChunks: Int, expectedBytes: Int, expectedDigest: String
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.sampling = sampling
    self.productionData = productionData
    self.expectedChunks = expectedChunks
    self.expectedBytes = expectedBytes
    self.expectedDigest = expectedDigest
  }
}
private let maximumUploadManifestBytes = 4096

private struct ProductionUploadChunk: Codable {
  var bytes: Int
  var digest: String
}

extension ProductionStorage {
  /// Validates and stores a resumable upload contract, returning prior state for an identical ID and contract.
  /// Accepts 1–1,024 chunks and at most one billion declared bytes, with at most ten pending uploads.
  /// - Throws: Invalid contracts, conflicting/discarded IDs, storage-limit errors, or file errors.
  public func beginUpload(_ upload: ProductionUpload) throws -> ProductionUpload {
    guard !upload.name.isEmpty, upload.name.count <= 200, !upload.version.isEmpty,
      upload.version.count <= 100,
      (1...1024).contains(upload.expectedChunks),
      (1...1_000_000_000).contains(upload.expectedBytes),
      upload.expectedDigest.count == 64,
      upload.expectedDigest.allSatisfy({ "0123456789abcdef".contains($0) }),
      !upload.previewed, upload.datasetRevision == nil
    else { throw ProductionFailure.invalid("Invalid upload contract.") }
    // Reserve the completed-state fields before accepting source bytes. Character
    // limits alone do not bound Unicode strings in the persisted JSON manifest.
    var completed = upload
    completed.previewed = true
    completed.datasetRevision = String(repeating: "0", count: 64)
    guard try ProductionCodec.encode(upload).count <= maximumUploadManifestBytes,
      try ProductionCodec.encode(completed).count <= maximumUploadManifestBytes
    else { throw ProductionFailure.invalid("Upload contract exceeds its storage byte limit.") }
    return try transaction {
      let folder = uploadDirectory(upload.id)
      let manifest = folder.appendingPathComponent("upload.json")
      guard !FileManager.default.fileExists(atPath: discardMarker(upload.id).path) else {
        throw ProductionFailure.invalid(
          "This upload ID was discarded. Use a new ID for new source data.")
      }
      if FileManager.default.fileExists(atPath: manifest.path) {
        var existing = try self.upload(upload.id)
        existing.previewed = false
        existing.datasetRevision = nil
        guard existing == upload else {
          throw ProductionFailure.invalid("Upload ID belongs to different source data.")
        }
        return try self.upload(upload.id)
      }
      let uploads = root.appendingPathComponent("Uploads")
      try FileManager.default.createDirectory(
        at: uploads, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let pending = try FileManager.default.contentsOfDirectory(
        at: uploads, includingPropertiesForKeys: nil
      ).filter { folder in
        guard !folder.lastPathComponent.hasPrefix(".") else { return false }
        return
          (try? ProductionCodec.read(
            ProductionUpload.self, from: folder.appendingPathComponent("upload.json"),
            maximumBytes: maximumUploadManifestBytes))?.datasetRevision == nil
      }
      guard pending.count < 10 else {
        throw ProductionFailure.invalid(
          "Ten pending uploads are already retained. Finish or explicitly discard one first.")
      }
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try ProductionCodec.write(upload, to: manifest, maximumBytes: maximumUploadManifestBytes)
      return upload
    }
  }
  /// Reads a bounded upload manifest, rejecting IDs with a persisted discard tombstone.
  public func upload(_ id: UUID) throws -> ProductionUpload {
    guard !FileManager.default.fileExists(atPath: discardMarker(id).path) else {
      throw ProductionFailure.invalid("This upload ID was discarded. Use a new ID for new source data.")
    }
    return try ProductionCodec.read(
      ProductionUpload.self, from: uploadDirectory(id).appendingPathComponent("upload.json"),
      maximumBytes: maximumUploadManifestBytes)
  }
  /// Returns the declared chunk indices with persisted receipt files; sealing performs byte and digest validation.
  public func uploadStatus(_ id: UUID) throws -> [Int] {
    let value = try upload(id)
    return (0..<value.expectedChunks).filter {
      FileManager.default.fileExists(
        atPath: uploadDirectory(id).appendingPathComponent("\($0).meta").path)
    }
  }
  /// Stores a nonempty chunk of at most 1 MiB and its receipt under the upload transaction.
  /// Repeated identical bytes at an index are accepted; changed bytes, sealed state, and declared-byte overflow are rejected.
  public func appendUpload(_ id: UUID, index: Int, data: Data) throws {
    try transaction {
      let value = try upload(id)
      guard !value.previewed, value.datasetRevision == nil,
        (0..<value.expectedChunks).contains(index), !data.isEmpty, data.count <= 1_048_576
      else {
        throw ProductionFailure.invalid("Chunk is invalid or upload is sealed.")
      }
      let folder = uploadDirectory(id)
      let file = folder.appendingPathComponent("\(index).chunk")
      let metadata = folder.appendingPathComponent("\(index).meta")
      let receipt = ProductionUploadChunk(bytes: data.count, digest: ProductionCodec.digest(data))
      if FileManager.default.fileExists(atPath: file.path) {
        guard try ProductionCodec.fileSize(file) <= 1_048_576, try Data(contentsOf: file) == data
        else { throw ProductionFailure.invalid("Chunk index already contains different bytes.") }
      } else {
        let bytes = try (0..<value.expectedChunks).reduce(0) { count, i in
          let file = folder.appendingPathComponent("\(i).chunk")
          return count
            + (FileManager.default.fileExists(atPath: file.path)
              ? try ProductionCodec.fileSize(file) : 0)
        }
        guard bytes + data.count <= value.expectedBytes else {
          throw ProductionFailure.invalid("Upload exceeds its declared byte count.")
        }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      }
      try ProductionCodec.write(receipt, to: metadata)
    }
  }
  /// Verifies and assembles the complete source, validates up to three examples, and marks the upload previewed.
  /// - Throws: Missing/changed chunk evidence, aggregate digest/size mismatches, invalid examples, or storage errors.
  public func previewUpload(_ id: UUID) throws -> [ProductionExample] {
    let source = try sealUpload(id)
    let preview = try Self.previewExamples(from: source, limit: 3)
    try transaction {
      var value = try upload(id)
      value.previewed = true
      try ProductionCodec.write(
        value, to: uploadDirectory(id).appendingPathComponent("upload.json"), maximumBytes: maximumUploadManifestBytes)
    }
    return preview
  }
  /// Imports the exact previewed source as an immutable dataset and records its revision for repeat completion calls.
  /// - Parameters:
  ///   - previewDigest: Must equal the declared digest of the previewed complete upload.
  ///   - redactionConfirmed: Required for uploads declared as production data.
  /// - Throws: Unpreviewed, changed, invalid, or unconfirmed source evidence, or persistence errors.
  public func finishUpload(_ id: UUID, previewDigest: String, redactionConfirmed: Bool) throws
    -> ProductionDataset
  {
    let value = try upload(id)
    guard value.previewed, previewDigest == value.expectedDigest else {
      throw ProductionFailure.invalid("Preview this exact complete source before importing it.")
    }
    if let revision = value.datasetRevision { return try loadDataset(revision) }
    let source = try sealUpload(id, expected: value)
    let dataset = try importDataset(
      from: source, name: value.name, version: value.version, sampling: value.sampling,
      productionData: value.productionData, redactionConfirmed: redactionConfirmed)
    try transaction {
      var current = try upload(id)
      guard current == value else {
        throw ProductionFailure.invalid(
          "Upload state changed during import. Inspect the immutable dataset before retrying.")
      }
      current.datasetRevision = dataset.revision
      try ProductionCodec.write(
        current, to: uploadDirectory(id).appendingPathComponent("upload.json"), maximumBytes: maximumUploadManifestBytes)
    }
    return dataset
  }
  /// Persists a discard tombstone before removing upload files, allowing retries to finish interrupted cleanup.
  /// The ID remains unavailable for reuse; corrupt or oversized manifests can still be discarded.
  public func discardUpload(_ id: UUID) throws {
    try transaction {
      if !FileManager.default.fileExists(atPath: discardMarker(id).path) {
        // Explicit cleanup must also recover legacy oversized or corrupt manifests.
        // Require the requested upload's manifest, but do not decode its contents.
        guard FileManager.default.fileExists(
          atPath: uploadDirectory(id).appendingPathComponent("upload.json").path)
        else { throw ProductionFailure.invalid("Upload does not exist.") }
        try Data(id.uuidString.utf8).write(to: discardMarker(id), options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: discardMarker(id).path)
      }
      // A persisted tombstone is authoritative even when folder removal was
      // interrupted. Retrying discard must still finish that cleanup.
      if FileManager.default.fileExists(atPath: uploadDirectory(id).path) {
        try FileManager.default.removeItem(at: uploadDirectory(id))
      }
    }
  }
  /// Locates the tombstone that permanently marks an upload ID as discarded.
  private func discardMarker(_ id: UUID) -> URL {
    root.appendingPathComponent("Uploads/.discarded-\(id)")
  }
  /// Locates retained manifest, chunks, receipts, and assembled bytes for one upload ID.
  private func uploadDirectory(_ id: UUID) -> URL {
    root.appendingPathComponent("Uploads/\(id.uuidString)")
  }
  /// Assembles chunks in declared index order after verifying receipt sizes/digests and the complete byte count/digest.
  /// An optional expected manifest detects state changes; temporary assembly is removed on failure.
  private func sealUpload(_ id: UUID, expected: ProductionUpload? = nil) throws -> URL {
    try transaction {
      let value = try upload(id)
      let folder = uploadDirectory(id)
      let assembled = folder.appendingPathComponent("assembled.jsonl")
      if let expected, expected != value {
        throw ProductionFailure.invalid("Upload contract changed after preview.")
      }
      let temporary = folder.appendingPathComponent(".assembling-\(UUID())")
      defer { try? FileManager.default.removeItem(at: temporary) }
      FileManager.default.createFile(
        atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
      let handle = try FileHandle(forWritingTo: temporary)
      defer { try? handle.close() }
      var digest = SHA256()
      var bytes = 0
      for index in 0..<value.expectedChunks {
        let receipt = try ProductionCodec.read(
          ProductionUploadChunk.self, from: folder.appendingPathComponent("\(index).meta"),
          maximumBytes: 4096)
        let chunkURL = folder.appendingPathComponent("\(index).chunk")
        guard try ProductionCodec.fileSize(chunkURL) <= 1_048_576 else {
          throw ProductionFailure.invalid("Chunk exceeds its bound.")
        }
        let chunk = try Data(contentsOf: chunkURL)
        guard chunk.count <= 1_048_576, chunk.count == receipt.bytes,
          ProductionCodec.digest(chunk) == receipt.digest
        else { throw ProductionFailure.invalid("Uploaded chunk changed or exceeds its bound.") }
        bytes += chunk.count
        guard bytes <= value.expectedBytes else {
          throw ProductionFailure.invalid("Upload exceeds declared bytes.")
        }
        digest.update(data: chunk)
        try handle.write(contentsOf: chunk)
      }
      let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
      guard bytes == value.expectedBytes, hash == value.expectedDigest else {
        throw ProductionFailure.invalid(
          "Complete upload does not match its declared digest and bytes.")
      }
      try handle.synchronize()
      if FileManager.default.fileExists(atPath: assembled.path) {
        try FileManager.default.removeItem(at: assembled)
      }
      try FileManager.default.moveItem(at: temporary, to: assembled)
      return assembled
    }
  }
}
